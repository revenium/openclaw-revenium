"""Tests for the sidecar launcher, its path validation and status files.

TestPaths covers build_context: a private state dir is accepted; a 0755
state dir, a state dir inside OPENCLAW_HOME, a symlink outside the home that
resolves inside it, a 0777 runtime dir and a skill dir without
scripts/session-store.sh are refused with UnsafePathError.

TestStatus covers atomic_write_json (mode 0600, valid JSON, no temp files
left, the previous file intact when os.replace fails) and read_manifest
(junk lines ignored, control characters stripped).

TestRunMain drives run.main in-process: the ok, runtime_missing, unsafe
path, crash and deadline exits, the status file each one writes, and that a
crash records the exception type name and never its message.

TestShimEndToEnd runs scripts/economics.sh against a real runtime
(SIDECAR_TEST_RUNTIME, a venv holding the vendored library) and checks the
whole tick: infer-status.json, the agent heartbeat and deliver-status.json.
tests/run-sidecar-tests.sh provisions that runtime and fails on any skip.
"""
from __future__ import annotations

import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent
_SIDECAR_DIR = _REPO_ROOT / "sidecar"
if str(_SIDECAR_DIR) not in sys.path:
    sys.path.insert(0, str(_SIDECAR_DIR))

import run  # noqa: E402
from openclaw_economics import paths, status  # noqa: E402

_ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def _private_tmpdir(test: unittest.TestCase) -> str:
    path = tempfile.mkdtemp(prefix="sidecar-test-")
    os.chmod(path, 0o700)
    test.addCleanup(_rmtree, path)
    return path


def _rmtree(path: str) -> None:
    for root, dirs, files in os.walk(path, topdown=False):
        for name in files:
            try:
                os.unlink(os.path.join(root, name))
            except OSError:
                pass
        for name in dirs:
            full = os.path.join(root, name)
            try:
                if os.path.islink(full):
                    os.unlink(full)
                else:
                    os.chmod(full, 0o700)
                    os.rmdir(full)
            except OSError:
                pass
    try:
        os.rmdir(path)
    except OSError:
        pass


def _mkdir(path: str, mode: int = 0o700) -> str:
    os.makedirs(path, exist_ok=True)
    os.chmod(path, mode)
    return path


class _Layout:
    """A temp OPENCLAW_HOME, private state dir and runtime dir."""

    def __init__(self, test: unittest.TestCase) -> None:
        self.base = _private_tmpdir(test)
        self.home = _mkdir(os.path.join(self.base, "openclaw"))
        self.state = _mkdir(os.path.join(self.base, "state"))
        self.runtime = _mkdir(os.path.join(self.base, "runtime"))
        self.skill = str(_REPO_ROOT)

    def args(self, **overrides) -> SimpleNamespace:
        values = {
            "state_dir": self.state,
            "openclaw_home": self.home,
            "skill_dir": self.skill,
            "runtime_dir": self.runtime,
            "budget_seconds": 10,
        }
        values.update(overrides)
        return SimpleNamespace(**values)

    def argv(self, stage: str = "infer", *extra: str, **overrides) -> list:
        a = self.args(**overrides)
        argv = [stage, *extra]
        argv += ["--state-dir", a.state_dir, "--openclaw-home", a.openclaw_home]
        argv += ["--skill-dir", a.skill_dir, "--runtime-dir", a.runtime_dir]
        argv += ["--budget-seconds", str(a.budget_seconds)]
        return argv


class TestPaths(unittest.TestCase):
    def setUp(self) -> None:
        self.lay = _Layout(self)

    def assertRefused(self, args, code: str) -> None:
        with self.assertRaises(paths.UnsafePathError) as cm:
            paths.build_context(args)
        self.assertEqual(cm.exception.code, code)

    def test_private_state_dir_is_accepted(self) -> None:
        ctx = paths.build_context(self.lay.args())
        self.assertEqual(ctx.state_dir, os.path.realpath(self.lay.state))
        self.assertEqual(ctx.budget_seconds, 10)
        self.assertTrue(ctx.store_script.endswith(os.path.join("scripts", "session-store.sh")))

    def test_group_readable_state_dir_is_refused(self) -> None:
        os.chmod(self.lay.state, 0o755)
        self.assertRefused(self.lay.args(), "state_dir_not_private")

    def test_state_dir_inside_openclaw_home_is_refused(self) -> None:
        inside = _mkdir(os.path.join(self.lay.home, "skills", "revenium", "state"))
        self.assertRefused(self.lay.args(state_dir=inside), "state_dir_in_openclaw_home")

    def test_symlink_resolving_inside_openclaw_home_is_refused(self) -> None:
        inside = _mkdir(os.path.join(self.lay.home, "hidden-state"))
        link = os.path.join(self.lay.base, "state-link")
        os.symlink(inside, link)
        self.assertRefused(self.lay.args(state_dir=link), "state_dir_in_openclaw_home")

    def test_world_writable_runtime_dir_is_refused(self) -> None:
        os.chmod(self.lay.runtime, 0o777)
        self.assertRefused(self.lay.args(), "runtime_dir_shared_writable")

    def test_runtime_dir_inside_openclaw_home_is_refused(self) -> None:
        inside = _mkdir(os.path.join(self.lay.home, "runtime"))
        self.assertRefused(self.lay.args(runtime_dir=inside), "runtime_dir_in_openclaw_home")

    def test_skill_dir_without_store_script_is_refused(self) -> None:
        fake_skill = _mkdir(os.path.join(self.lay.base, "skill"))
        _mkdir(os.path.join(fake_skill, "scripts"))
        self.assertRefused(self.lay.args(skill_dir=fake_skill), "store_script_missing")

    def test_budget_below_one_is_refused(self) -> None:
        self.assertRefused(self.lay.args(budget_seconds=0), "budget_too_small")

    def test_is_under_rejects_shared_prefix_sibling(self) -> None:
        sibling = _mkdir(self.lay.home + "-sibling")
        self.assertFalse(paths.is_under(sibling, self.lay.home))


class TestStatus(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = _private_tmpdir(self)

    def _leftovers(self) -> list:
        return [n for n in os.listdir(self.dir) if n.endswith(".tmp")]

    def test_atomic_write_is_private_valid_json_without_temp_files(self) -> None:
        target = os.path.join(self.dir, "x.json")
        status.atomic_write_json(target, {"b": 1, "a": [1, 2]})
        self.assertEqual(stat.S_IMODE(os.stat(target).st_mode), 0o600)
        with open(target, encoding="utf-8") as handle:
            self.assertEqual(json.load(handle), {"a": [1, 2], "b": 1})
        self.assertEqual(self._leftovers(), [])

    def test_failed_replace_keeps_previous_content(self) -> None:
        target = os.path.join(self.dir, "x.json")
        status.atomic_write_json(target, {"v": "old"})
        with mock.patch.object(status.os, "replace", side_effect=OSError("boom")):
            with self.assertRaises(OSError):
                status.atomic_write_json(target, {"v": "new"})
        with open(target, encoding="utf-8") as handle:
            self.assertEqual(json.load(handle), {"v": "old"})
        self.assertEqual(self._leftovers(), [])
        self.assertEqual(os.listdir(self.dir), ["x.json"])

    def test_read_manifest_ignores_junk_and_strips_control_characters(self) -> None:
        with open(os.path.join(self.dir, "INSTALLED"), "w", encoding="utf-8") as handle:
            handle.write("library_sha=abc\x1b[31mdef\x07\n")
            handle.write("this line has no separator\n")
            handle.write("=no-key\n")
            handle.write("bad key=value\n")
            handle.write("wheel_sha256=" + "f" * 200 + "\n")
        manifest = status.read_manifest(self.dir)
        self.assertEqual(manifest["library_sha"], "abc[31mdef")
        self.assertEqual(len(manifest["wheel_sha256"]), 128)
        self.assertEqual(set(manifest), {"library_sha", "wheel_sha256"})

    def test_read_manifest_missing_file_is_empty(self) -> None:
        self.assertEqual(status.read_manifest(self.dir), {})

    def test_sanitize_token_drops_control_characters_and_cuts(self) -> None:
        self.assertEqual(status.sanitize_token("Va\x00lue\x7fError\n"), "ValueError")
        self.assertEqual(len(status.sanitize_token("x" * 100)), 64)


class TestRunMain(unittest.TestCase):
    def setUp(self) -> None:
        self.lay = _Layout(self)
        with open(os.path.join(self.lay.runtime, "INSTALLED"), "w", encoding="utf-8") as handle:
            handle.write("library_sha=5c7fba352cda25d68613f46bd8729740fc74827a\n")

    def _status(self, stage: str = "infer") -> dict:
        with open(os.path.join(self.lay.state, f"{stage}-status.json"), encoding="utf-8") as handle:
            return json.load(handle)

    def test_healthy_infer_writes_ok_status(self) -> None:
        rc = run.main(self.lay.argv(), find_library=lambda: True)
        self.assertEqual(rc, run.EXIT_OK)
        doc = self._status()
        self.assertEqual(doc["reason"], "ok")
        self.assertEqual(doc["schema"], 1)
        self.assertEqual(doc["stage"], "infer")
        self.assertRegex(doc["updatedAt"], _ISO_RE)
        self.assertEqual(doc["library"]["sha"], "5c7fba352cda25d68613f46bd8729740fc74827a")
        self.assertIsInstance(doc["durationMs"], int)
        self.assertNotIn("error", doc)
        path = os.path.join(self.lay.state, "infer-status.json")
        self.assertEqual(stat.S_IMODE(os.stat(path).st_mode), 0o600)

    def test_healthy_deliver_post_writes_ok_status(self) -> None:
        rc = run.main(self.lay.argv("deliver", "--phase", "post"), find_library=lambda: True)
        self.assertEqual(rc, run.EXIT_OK)
        self.assertEqual(self._status("deliver")["reason"], "ok")

    def test_missing_library_returns_runtime_missing(self) -> None:
        rc = run.main(self.lay.argv(), find_library=lambda: False)
        self.assertEqual(rc, run.EXIT_RUNTIME_MISSING)
        self.assertEqual(rc, 3)
        self.assertEqual(self._status()["reason"], "runtime_missing")

    def test_unsafe_state_dir_returns_4_and_writes_nothing(self) -> None:
        os.chmod(self.lay.state, 0o755)
        rc = run.main(self.lay.argv(), find_library=lambda: True)
        self.assertEqual(rc, run.EXIT_UNSAFE_PATHS)
        self.assertEqual(rc, 4)
        self.assertEqual(os.listdir(self.lay.state), [])

    def test_stage_exception_records_type_name_only(self) -> None:
        def boom(ctx):
            raise ValueError("planted-secret-message")

        with mock.patch.object(run, "run_infer", boom):
            rc = run.main(self.lay.argv(), find_library=lambda: True)
        self.assertEqual(rc, run.EXIT_CRASH)
        doc = self._status()
        self.assertEqual(doc["reason"], "crashing")
        self.assertEqual(doc["error"], "ValueError")
        with open(os.path.join(self.lay.state, "infer-status.json"), encoding="utf-8") as handle:
            self.assertNotIn("planted-secret-message", handle.read())

    def test_budget_deadline_returns_124(self) -> None:
        def slow(ctx):
            time.sleep(3)
            return {}

        with mock.patch.object(run, "run_infer", slow):
            began = time.monotonic()
            rc = run.main(self.lay.argv(budget_seconds=1), find_library=lambda: True)
            elapsed = time.monotonic() - began
        self.assertEqual(rc, run.EXIT_DEADLINE)
        self.assertEqual(self._status()["reason"], "timeout")
        self.assertLess(elapsed, 2.5)


def _pycache_dirs() -> set:
    found = set()
    for root, dirs, _files in os.walk(_SIDECAR_DIR):
        for name in dirs:
            if name == "__pycache__":
                found.add(os.path.join(root, name))
    return found


@unittest.skipUnless(
    os.environ.get("SIDECAR_TEST_RUNTIME"),
    "SIDECAR_TEST_RUNTIME not set (run tests/run-sidecar-tests.sh)",
)
class TestShimEndToEnd(unittest.TestCase):
    def setUp(self) -> None:
        self.base = _private_tmpdir(self)
        self.home_dir = _mkdir(os.path.join(self.base, "home"))
        self.oc_home = _mkdir(os.path.join(self.base, "openclaw"))
        _mkdir(os.path.join(self.oc_home, "skills", "revenium"), 0o755)
        self.state = _mkdir(os.path.join(self.base, "state"))
        self.env = {
            "HOME": self.home_dir,
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "REVENIUM_SIDECAR_HOME": os.environ["SIDECAR_TEST_RUNTIME"],
            "REVENIUM_ECON_STATE_DIR": self.state,
        }

    def _shim(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            ["bash", str(_REPO_ROOT / "scripts" / "economics.sh"), *args,
             "--openclaw-home", self.oc_home],
            env=self.env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=120,
        )

    def _json(self, path: str) -> dict:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)

    def _log_tail(self) -> str:
        try:
            with open(os.path.join(self.state, "revenium-economics.log"), encoding="utf-8") as handle:
                return handle.read()[-2000:]
        except OSError:
            return "<no log>"

    def test_tick_runs_python_stage_end_to_end(self) -> None:
        before = _pycache_dirs()

        proc = self._shim("infer")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        infer_status = os.path.join(self.state, "infer-status.json")
        self.assertTrue(os.path.isfile(infer_status), self._log_tail())
        self.assertEqual(self._json(infer_status)["reason"], "ok", self._log_tail())
        heartbeat = self._json(os.path.join(self.oc_home, "skills", "revenium", "economics-status.json"))
        self.assertEqual(heartbeat["state"], "ok", self._log_tail())
        self.assertEqual(heartbeat["outageId"], "")

        proc = self._shim("deliver", "--phase", "post")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        deliver_status = os.path.join(self.state, "deliver-status.json")
        self.assertTrue(os.path.isfile(deliver_status), self._log_tail())
        self.assertEqual(self._json(deliver_status)["reason"], "ok")

        self.assertEqual(_pycache_dirs() - before, set(), "sidecar run wrote __pycache__")


if __name__ == "__main__":
    unittest.main()
