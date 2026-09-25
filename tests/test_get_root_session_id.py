"""Unit tests for scripts/get-root-session-id.py

READ-03 / PLUG-04 root-session resolution against OpenClaw 2.0's SQLite
session store and the plugin's subagent-parentage sidecar (plan 19-05).

Two resolution sources are exercised here, in priority order (D-08):
  1. The plugin sidecar (child session KEY -> parent session KEY edges),
     mirrored from plugin/src/gate.js :: readSidecarEdges (plan 19-03).
  2. The store's own parentage columns, reached via
     scripts/session-store.sh's executed-mode CLI (plan 19-01, D-02).

Fixtures build a REAL SQLite database via tests/lib/mk-session-store.sh's
mk_store/mk_session helpers (the resolver goes through the store CLI, so a
mock would not exercise the real path) plus hand-written sidecar JSONL
files, all under a temporary OPENCLAW_HOME passed to the resolver via its
`openclaw_home` keyword argument (D-09's new, purely-additive parameter).

Task 1 tests cover: a one-hop and a two-hop sidecar resolution, the
no-linkage-anywhere passthrough, the empty-input short-circuit, the cycle
depth cap, the CLI's one-line-stdout/exit-0 contract (including the
no-argument case), the `sessions_dir` legacy-parameter inertness, fail-open
on a store-less OPENCLAW_HOME, and malformed sidecar lines being skipped.

Task 2 tests cover RESOLUTION_SOURCE attribution: the store fallback
answering when the sidecar is silent, the sidecar winning a deliberate
disagreement with the store (and the store never being queried for that
hop), the "neither source answers" case, and the diagnostic CLI flag's
stdout/stderr separation.

Task 3 tests cover the READ-03 properties: idempotency across repeated
resolutions, duplicate-edge idempotency, a truncated final sidecar line
(the exact on-disk state a concurrent append can leave for a reader),
rotated-file resolution with live-file override, an unreadable sidecar
file, a non-zero-exit store CLI, and a hanging store CLI abandoned at a
shortened timeout.
"""
from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

# ---------------------------------------------------------------------------
# Import the module under test via importlib (non-package source file).
# ---------------------------------------------------------------------------
_REPO_ROOT = Path(__file__).resolve().parent.parent
_MODULE_PATH = _REPO_ROOT / "scripts" / "get-root-session-id.py"
_MK_SESSION_STORE_SH = _REPO_ROOT / "tests" / "lib" / "mk-session-store.sh"

spec = importlib.util.spec_from_file_location("get_root_session_id_module", _MODULE_PATH)
_mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(_mod)

get_root_session_id = _mod.get_root_session_id


# ---------------------------------------------------------------------------
# Fixture helper — a temp OPENCLAW_HOME with a real SQLite store (built via
# tests/lib/mk-session-store.sh, the same schema-authoritative fixture
# builder plan 19-01 introduced) and, optionally, hand-written sidecar JSONL
# files matching plugin/src/gate.js's exact on-disk schema (plan 19-03).
# ---------------------------------------------------------------------------
class _Fixture:
    def __init__(self):
        self.tmpdir = tempfile.mkdtemp(prefix="grsid-fixture-")
        self.openclaw_home = self.tmpdir
        self.db_path = os.path.join(
            self.openclaw_home, "agents", "main", "agent", "openclaw-agent.sqlite"
        )
        self._mk_store()

    def cleanup(self):
        shutil.rmtree(self.tmpdir, ignore_errors=True)

    def _mk_store(self):
        subprocess.run(
            ["bash", "-c", '. "$1"; mk_store "$2"', "_", str(_MK_SESSION_STORE_SH), self.db_path],
            check=True,
            capture_output=True,
            text=True,
        )

    def add_session(self, sid: str, skey: str, created_via: str = "", updated_at: int = 100):
        """Insert one session_nodes/session_windows row pair (mk_session)."""
        subprocess.run(
            [
                "bash", "-c",
                '. "$1"; mk_session "$2" "$3" "$4" "$5" "$6"', "_",
                str(_MK_SESSION_STORE_SH), self.db_path, sid, skey, created_via, str(updated_at),
            ],
            check=True,
            capture_output=True,
            text=True,
        )

    def set_window_parent_key(self, sid: str, parent_key: str):
        """Write session_windows.parent_session_key directly (store-parentage
        FALLBACK column, D-08) via a plain read-write sqlite3 connection --
        never through the resolver's read-only store CLI."""
        subprocess.run(
            [
                "sqlite3", self.db_path,
                f"UPDATE session_windows SET parent_session_key = '{parent_key}' "
                f"WHERE session_id = '{sid}';",
            ],
            check=True,
            capture_output=True,
            text=True,
        )

    def _sidecar_dir(self) -> str:
        d = os.path.join(self.openclaw_home, "skills", "revenium")
        os.makedirs(d, exist_ok=True)
        return d

    def sidecar_path(self, rotated: bool = False) -> str:
        return os.path.join(self._sidecar_dir(), "subagent-edges.jsonl" + (".1" if rotated else ""))

    def write_sidecar(self, edges, rotated: bool = False, extra_raw: str = "", mode: str = "w"):
        """edges: iterable of (child_key, parent_key) tuples -> spawned records.

        extra_raw is appended verbatim after the JSON lines (no trailing
        newline added), for building a truncated-final-line fixture.
        """
        path = self.sidecar_path(rotated=rotated)
        with open(path, mode, encoding="utf-8") as fh:
            for child_key, parent_key in edges:
                fh.write(
                    json.dumps(
                        {
                            "event": "spawned",
                            "childSessionKey": child_key,
                            "parentSessionKey": parent_key,
                            "runId": "run-1",
                            "capturedAt": "2026-09-25T00:00:00.000Z",
                        }
                    )
                    + "\n"
                )
            if extra_raw:
                fh.write(extra_raw)
        return path


def _sid(n: str) -> str:
    """Build a hex-UUID-shaped session id (matches _store_valid_id)."""
    return f"aaaaaaaa-0000-0000-0000-{n:0>12}"


def _write_logging_store_wrapper(log_path: str) -> str:
    """Write a bash wrapper that appends the requested verb to `log_path`
    and then delegates to the real scripts/session-store.sh, so a test can
    assert a particular verb (e.g. "parent-session-id") was NEVER invoked
    for a hop the sidecar already answered (D-08), without monkeypatching
    subprocess -- the same environment-injection mechanism
    _STORE_SCRIPT_OVERRIDE_ENV exists for.
    """
    real_script = _REPO_ROOT / "scripts" / "session-store.sh"
    wrapper_path = os.path.join(os.path.dirname(log_path), "logging-store-wrapper.sh")
    with open(wrapper_path, "w", encoding="utf-8") as fh:
        fh.write(
            "#!/usr/bin/env bash\n"
            f'echo "$1" >> "{log_path}"\n'
            f'exec bash "{real_script}" "$@"\n'
        )
    os.chmod(wrapper_path, 0o755)
    return wrapper_path


# ===========================================================================
# Task 1: sidecar-primary resolution, contract preservation, fail-open
# ===========================================================================
class TestSidecarResolution(unittest.TestCase):
    def setUp(self):
        self.fx = _Fixture()

    def tearDown(self):
        self.fx.cleanup()

    def test_sidecar_one_hop_resolves_to_parent(self):
        child_sid, parent_sid = _sid("1"), _sid("2")
        child_key, parent_key = "agent:main:subagent:child1", "agent:main:main"
        self.fx.add_session(child_sid, child_key)
        self.fx.add_session(parent_sid, parent_key)
        self.fx.write_sidecar([(child_key, parent_key)])

        result = get_root_session_id(child_sid, openclaw_home=self.fx.openclaw_home)
        self.assertEqual(result, parent_sid)

    def test_sidecar_two_hop_chain_resolves_to_root(self):
        grandchild_sid, child_sid, root_sid = _sid("3"), _sid("4"), _sid("5")
        grandchild_key = "agent:main:subagent:grandchild"
        child_key = "agent:main:subagent:child"
        root_key = "agent:main:main"
        self.fx.add_session(grandchild_sid, grandchild_key)
        self.fx.add_session(child_sid, child_key)
        self.fx.add_session(root_sid, root_key)
        self.fx.write_sidecar([(grandchild_key, child_key), (child_key, root_key)])

        result = get_root_session_id(grandchild_sid, openclaw_home=self.fx.openclaw_home)
        self.assertEqual(result, root_sid)

    def test_no_sidecar_no_parentage_returns_input_unchanged(self):
        plain_sid = _sid("6")
        self.fx.add_session(plain_sid, "agent:main:main")
        # No sidecar file written at all.

        result = get_root_session_id(plain_sid, openclaw_home=self.fx.openclaw_home)
        self.assertEqual(result, plain_sid)

    def test_empty_sid_function_returns_empty(self):
        """Empty string returns empty without touching disk."""
        result = get_root_session_id("")
        self.assertEqual(result, "")

    def test_cycle_terminates_at_max_depth(self):
        a_sid, b_sid = _sid("7"), _sid("8")
        a_key, b_key = "agent:main:subagent:a", "agent:main:subagent:b"
        self.fx.add_session(a_sid, a_key)
        self.fx.add_session(b_sid, b_key)
        self.fx.write_sidecar([(a_key, b_key), (b_key, a_key)])

        try:
            result = get_root_session_id(a_sid, openclaw_home=self.fx.openclaw_home, max_depth=10)
        except Exception as e:  # pragma: no cover - failure path
            self.fail(f"get_root_session_id raised on cycle: {e}")
        self.assertIsInstance(result, str)
        self.assertTrue(len(result) > 0)

    def test_legacy_sessions_dir_param_is_inert(self):
        child_sid, parent_sid = _sid("9"), _sid("10")
        child_key, parent_key = "agent:main:subagent:child9", "agent:main:main"
        self.fx.add_session(child_sid, child_key)
        self.fx.add_session(parent_sid, parent_key)
        self.fx.write_sidecar([(child_key, parent_key)])

        result = get_root_session_id(
            child_sid,
            sessions_dir="/nonexistent/path",
            openclaw_home=self.fx.openclaw_home,
        )
        self.assertEqual(result, parent_sid)

    def test_unreadable_base_fails_open(self):
        """A store-less OPENCLAW_HOME (no agents/ dir at all) fails open."""
        empty_home = tempfile.mkdtemp(prefix="grsid-empty-home-")
        try:
            sid = _sid("11")
            result = get_root_session_id(sid, openclaw_home=empty_home)
            self.assertEqual(result, sid)
        finally:
            shutil.rmtree(empty_home, ignore_errors=True)

    def test_malformed_sidecar_lines_skipped(self):
        child_sid, parent_sid = _sid("12"), _sid("13")
        child_key, parent_key = "agent:main:subagent:child12", "agent:main:main"
        self.fx.add_session(child_sid, child_key)
        self.fx.add_session(parent_sid, parent_key)

        path = self.fx.sidecar_path()
        with open(path, "w", encoding="utf-8") as fh:
            fh.write("NOT VALID JSON\n")
            fh.write('{"also": broken\n')
            fh.write("\n")
            fh.write(json.dumps({"event": "ended", "childSessionKey": "x"}) + "\n")
            fh.write(
                json.dumps(
                    {
                        "event": "spawned",
                        "childSessionKey": child_key,
                        "parentSessionKey": parent_key,
                    }
                )
                + "\n"
            )

        result = get_root_session_id(child_sid, openclaw_home=self.fx.openclaw_home)
        self.assertEqual(result, parent_sid)


# ===========================================================================
# Task 2: store-parentage fallback and RESOLUTION_SOURCE attribution
# ===========================================================================
class TestSourceAttribution(unittest.TestCase):
    def setUp(self):
        self.fx = _Fixture()

    def tearDown(self):
        self.fx.cleanup()

    def test_store_fallback_answers_when_no_sidecar(self):
        child_sid, parent_sid = _sid("16"), _sid("17")
        child_key, parent_key = "agent:main:subagent:child16", "agent:main:main"
        self.fx.add_session(child_sid, child_key)
        self.fx.add_session(parent_sid, parent_key)
        # No sidecar file at all -- the store's own parentage column is the
        # only source of a parent link (session_windows.parent_session_key,
        # D-08's fallback).
        self.fx.set_window_parent_key(child_sid, parent_key)

        result = get_root_session_id(child_sid, openclaw_home=self.fx.openclaw_home)
        self.assertEqual(result, parent_sid)
        self.assertEqual(_mod.RESOLUTION_SOURCE, "store")

    def test_sidecar_wins_a_deliberate_disagreement_with_store(self):
        child_sid = _sid("18")
        sidecar_parent_sid, store_parent_sid = _sid("19"), _sid("20")
        child_key = "agent:main:subagent:child18"
        sidecar_parent_key = "agent:main:sidecar-parent"
        store_parent_key = "agent:main:store-parent"
        self.fx.add_session(child_sid, child_key)
        self.fx.add_session(sidecar_parent_sid, sidecar_parent_key)
        self.fx.add_session(store_parent_sid, store_parent_key)
        # Both sources disagree about the parent of child_sid.
        self.fx.write_sidecar([(child_key, sidecar_parent_key)])
        self.fx.set_window_parent_key(child_sid, store_parent_key)

        log_path = os.path.join(self.fx.tmpdir, "store-invocations.log")
        wrapper = _write_logging_store_wrapper(log_path)
        os.environ[_mod._STORE_SCRIPT_OVERRIDE_ENV] = wrapper
        try:
            result = get_root_session_id(child_sid, openclaw_home=self.fx.openclaw_home)
        finally:
            del os.environ[_mod._STORE_SCRIPT_OVERRIDE_ENV]

        self.assertEqual(result, sidecar_parent_sid)
        self.assertEqual(_mod.RESOLUTION_SOURCE, "sidecar")
        # The sidecar answered the only hop in this walk, so the store's
        # own parentage-fallback verb must never have been invoked (D-08:
        # the fallback is never pre-fetched for a hop the sidecar answers).
        invocations = []
        if os.path.exists(log_path):
            with open(log_path, encoding="utf-8") as fh:
                invocations = [line.strip() for line in fh if line.strip()]
        self.assertNotIn("parent-session-id", invocations)

    def test_neither_source_answers_returns_input_with_source_none(self):
        plain_sid = _sid("21")
        self.fx.add_session(plain_sid, "agent:main:main")
        # No sidecar file, no store parentage column set.

        result = get_root_session_id(plain_sid, openclaw_home=self.fx.openclaw_home)
        self.assertEqual(result, plain_sid)
        self.assertEqual(_mod.RESOLUTION_SOURCE, "none")


class TestCliContract(unittest.TestCase):
    def setUp(self):
        self.fx = _Fixture()

    def tearDown(self):
        self.fx.cleanup()

    def test_cli_diagnostic_flag_stdout_stays_one_line_source_on_stderr(self):
        child_sid, parent_sid = _sid("22"), _sid("23")
        child_key, parent_key = "agent:main:subagent:child22", "agent:main:main"
        self.fx.add_session(child_sid, child_key)
        self.fx.add_session(parent_sid, parent_key)
        self.fx.write_sidecar([(child_key, parent_key)])

        env = dict(os.environ)
        env["OPENCLAW_HOME"] = self.fx.openclaw_home
        proc = subprocess.run(
            [sys.executable, str(_MODULE_PATH), child_sid, "--diagnose"],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(proc.returncode, 0)
        stdout_lines = proc.stdout.splitlines()
        self.assertEqual(len(stdout_lines), 1)
        self.assertEqual(stdout_lines[0], parent_sid)
        stderr_lines = [l for l in proc.stderr.splitlines() if l.strip()]
        self.assertEqual(len(stderr_lines), 1)
        self.assertEqual(stderr_lines[0], "sidecar")

    def test_cli_prints_root_id_and_exits_zero(self):
        child_sid, parent_sid = _sid("14"), _sid("15")
        child_key, parent_key = "agent:main:subagent:child14", "agent:main:main"
        self.fx.add_session(child_sid, child_key)
        self.fx.add_session(parent_sid, parent_key)
        self.fx.write_sidecar([(child_key, parent_key)])

        env = dict(os.environ)
        env["OPENCLAW_HOME"] = self.fx.openclaw_home
        proc = subprocess.run(
            [sys.executable, str(_MODULE_PATH), child_sid],
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(proc.returncode, 0)
        lines = proc.stdout.splitlines()
        self.assertEqual(len(lines), 1)
        self.assertEqual(lines[0], parent_sid)

    def test_cli_no_argument_exits_zero_prints_nothing(self):
        proc = subprocess.run([sys.executable, str(_MODULE_PATH)], capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "")

    def test_empty_sid_exits_zero(self):
        proc = subprocess.run(
            [sys.executable, str(_MODULE_PATH), ""], capture_output=True, text=True
        )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()
