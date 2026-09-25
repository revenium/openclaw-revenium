#!/usr/bin/env python3
"""Resolve a subagent session id to its root session id.

READ-03 / PLUG-04 root-session resolution for OpenClaw 2.0. The prior
implementation scanned transcript JSONL files for a spawn tool result
carrying `details.childSessionKey`. On a 2.0 host, transcripts are
archive-only and that linkage no longer exists; this version resolves
against OpenClaw 2.0's SQLite session store and the plugin's sidecar
instead, preserving the resolver's public contract byte-for-byte (D-09).

Two resolution sources, consulted in a fixed priority order (D-08):
  1. PRIMARY -- the plugin-maintained sidecar recording child-to-parent
     session-KEY edges (plugin/src/gate.js :: appendSidecarEdge /
     readSidecarEdges, plan 19-03).
  2. FALLBACK -- the SQLite store's own parentage columns
     (session_windows.parent_session_key/spawned_by,
     session_nodes.parent_session_key/spawned_by/fork_source_session_key),
     queried once per hop ONLY when the sidecar holds no edge for that hop.
     These columns are present in the captured live schema but have never
     been observed populated for a real parent/child pair -- exactly why
     they are the fallback, not the primary path.

The sidecar and this resolver's own contract speak different id spaces:
the sidecar's edges are session KEYS (e.g. "agent:dev:subagent:<uuid>"),
while this function's signature and its four existing callers operate on
session IDS (UUIDs). The walk below operates entirely in KEY space and
translates to/from ID space exactly once, at the top and bottom, via
scripts/session-store.sh's `session-key-for-id`/`session-id-for-key` verbs
(D-02) -- never comparing a key against an id (RESEARCH Pitfall 2).

Production callers shell in via the bash wrapper in scripts/common.sh:
    root_sid="$(get_root_session_id "${sid}")"

Tests import get_root_session_id directly and pass openclaw_home=<tempdir>.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
from typing import Optional

# ---------------------------------------------------------------------------
# Test-only injection points (never set outside tests). Allow a test to
# redirect the store CLI subprocess at a stub script and/or shrink its
# timeout, so a hanging- or failing-CLI property case can exercise the real
# subprocess timeout/exit-code path without a real 15-second wait and
# without monkeypatching subprocess itself.
# ---------------------------------------------------------------------------
_STORE_SCRIPT_OVERRIDE_ENV = "_REVENIUM_GRSID_STORE_SCRIPT"
_STORE_CLI_TIMEOUT_ENV = "_REVENIUM_GRSID_STORE_TIMEOUT"

# Records which source answered the most recent get_root_session_id() call:
# "sidecar", "store", "none" (no edge found by either source), or "error"
# (the blanket fail-open guard fired). Printed to stderr by the CLI form
# only when a second, non-empty argv argument (a diagnostic flag) is given
# -- stdout always stays exactly one line, because scripts/common.sh's
# wrapper captures stdout through command substitution and any extra line
# would corrupt the agent attribution value (the same failure mode Phase 18
# fixed in the version gate, in a different file). Set to the source of the
# FIRST hop that produced a parent -- a later hop in the same walk does not
# override it.
RESOLUTION_SOURCE = "none"

# Relative path components of the sidecar under an OpenClaw home directory.
# Mirrors plugin/src/gate.js :: resolveSidecarPath exactly (plan 19-03) --
# the skill's state directory, not the plugin's run-state directory.
_SIDECAR_RELATIVE_PARTS = ("skills", "revenium", "subagent-edges.jsonl")


def _resolve_base(openclaw_home: Optional[str]) -> str:
    """Resolve the OpenClaw home directory: the `openclaw_home` kwarg, else
    the OPENCLAW_HOME environment variable, else the expanded default --
    the same order scripts/common.sh uses."""
    if openclaw_home:
        return openclaw_home
    env_home = os.environ.get("OPENCLAW_HOME")
    if env_home:
        return env_home
    return os.path.expanduser("~/.openclaw")


def _read_sidecar_edges(base: str) -> dict:
    """Python mirror of plugin/src/gate.js :: readSidecarEdges.

    Reads the rotated `.1` sibling first, then the live
    subagent-edges.jsonl file, so a later edge overwrites an earlier one
    (last write wins on a duplicate childSessionKey -- idempotency). Skips
    blank lines and any line that fails to parse -- this is what makes a
    concurrently-appended partial final line harmless to a reader. Keeps
    only "spawned" records carrying non-empty child/parent session key
    strings. Returns an empty dict on any OS error (fail-open).
    """
    result: dict = {}
    try:
        live_path = os.path.join(base, *_SIDECAR_RELATIVE_PARTS)
        for path in (live_path + ".1", live_path):
            try:
                with open(path, encoding="utf-8") as fh:
                    content = fh.read()
            except OSError:
                continue  # file may not exist, or be unreadable -- skip
            for line in content.split("\n"):
                if not line.strip():
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue  # unparseable/partial line -- skip
                if not isinstance(rec, dict) or rec.get("event") != "spawned":
                    continue
                child_key = rec.get("childSessionKey")
                parent_key = rec.get("parentSessionKey")
                if (
                    isinstance(child_key, str)
                    and child_key
                    and isinstance(parent_key, str)
                    and parent_key
                ):
                    result[child_key] = parent_key
    except Exception:
        return {}
    return result


def _store_cli(base: str, verb: str, *args: str) -> str:
    """The single subprocess entry point into scripts/session-store.sh's
    executed-mode CLI (D-02). Resolved relative to THIS file's own
    directory, never a skill-directory constant, so tests running straight
    out of the repository checkout find it.

    Returns stripped stdout, or an empty string on any exception including
    the timeout -- this resolver is called once per session per metering
    tick and once per guardrail check, so an unbounded subprocess would
    convert a store problem into a hung tick.
    """
    script_path = os.environ.get(_STORE_SCRIPT_OVERRIDE_ENV) or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "session-store.sh"
    )
    try:
        timeout = float(os.environ.get(_STORE_CLI_TIMEOUT_ENV, "15"))
    except ValueError:
        timeout = 15.0
    env = dict(os.environ)
    env["OPENCLAW_HOME"] = base
    try:
        proc = subprocess.run(
            ["bash", script_path, verb, *args],
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            timeout=timeout,
        )
        return proc.stdout.decode("utf-8", errors="replace").strip()
    except Exception:
        return ""


def _session_key_for_id(base: str, sid: str) -> str:
    if not sid:
        return ""
    return _store_cli(base, "session-key-for-id", sid)


def _session_id_for_key(base: str, key: str) -> str:
    if not key:
        return ""
    return _store_cli(base, "session-id-for-key", key)


def _parent_key_for_key(base: str, key: str) -> str:
    """Store-parentage FALLBACK for one hop (D-08: consulted only when the
    sidecar has no edge for `key`, and never pre-fetched for a hop the
    sidecar already answers). plan 19-01's `parent-session-id` verb takes
    and returns session IDS, so this translates key -> id, asks for the
    parent id, then translates that back to a key. Returning empty at any
    step means no parent.

    NOTE (D-08/D-17): the parentage columns this ultimately reads
    (session_windows.parent_session_key/spawned_by,
    session_nodes.parent_session_key/spawned_by/fork_source_session_key)
    are present in the captured live schema but have never been observed
    populated for a real parent/child pair -- exactly why this is the
    fallback, not the primary path, and why plan 19-07's live verification
    must record whether they ever answer.
    """
    sid = _session_id_for_key(base, key)
    if not sid:
        return ""
    parent_sid = _store_cli(base, "parent-session-id", sid)
    if not parent_sid:
        return ""
    return _session_key_for_id(base, parent_sid)


def get_root_session_id(
    sid: str,
    sessions_dir: Optional[str] = None,
    max_depth: int = 10,
    *,
    openclaw_home: Optional[str] = None,
) -> str:
    """Walk a subagent session id to its root via the sidecar and the store.

    Returns the input sid on any error path: an id the store does not
    recognize, an unreadable sidecar, a failing or hanging store CLI
    subprocess, or a walk that exceeds max_depth. Never raises (D-09
    fail-open invariant) -- four existing callers depend on this, one of
    them (guardrail-check.sh) running under `set -euo pipefail` where a
    raise would abort the guardrail gate.

    Args:
        sid: Session id to resolve. Empty string returns empty string
            immediately, without touching disk.
        sessions_dir: LEGACY parameter naming the pre-2.0 transcript
            directory. It is no longer consulted -- kept only so any
            existing caller that still passes it does not break (a
            documented inert parameter, not a silent trap). Callers wanting
            to redirect resolution at a fixture should pass `openclaw_home`
            instead.
        max_depth: Maximum walk depth to guard against cycles. Default 10.
        openclaw_home: OpenClaw home directory to resolve the sidecar and
            store against. Defaults to the OPENCLAW_HOME environment
            variable, then the expanded ~/.openclaw default -- the same
            order scripts/common.sh uses.

    Returns:
        Root session id string, or the input sid on any failure.
    """
    global RESOLUTION_SOURCE
    if not sid:
        RESOLUTION_SOURCE = "none"
        return sid

    base = _resolve_base(openclaw_home)

    try:
        sidecar_edges = _read_sidecar_edges(base)

        # Translate id -> key ONCE at the top; the walk itself operates
        # entirely in key space (RESEARCH Pitfall 2) and is translated back
        # to id space once at the bottom.
        current_key = _session_key_for_id(base, sid)
        if not current_key:
            RESOLUTION_SOURCE = "none"
            return sid  # an id the store does not know at all -- nothing to walk

        source = "none"
        for _ in range(max_depth):
            parent_key = sidecar_edges.get(current_key)
            hop_source = "sidecar" if parent_key else None
            if not parent_key:
                # D-08: the store fallback is consulted ONLY when the
                # sidecar has no entry for this hop -- never pre-fetched.
                parent_key = _parent_key_for_key(base, current_key)
                if parent_key:
                    hop_source = "store"
            if not parent_key:
                break  # current_key is the root
            if source == "none":
                # RESOLUTION_SOURCE reflects the FIRST hop that produced a
                # parent -- a later hop in the same walk never overrides it.
                source = hop_source
            current_key = parent_key

        RESOLUTION_SOURCE = source
        if source == "none":
            return sid  # no linkage found by either source

        result_id = _session_id_for_key(base, current_key)
        return result_id or sid

    except Exception:
        RESOLUTION_SOURCE = "error"
        return sid  # blanket guard, never raises


if __name__ == "__main__":
    if len(sys.argv) < 2 or not sys.argv[1]:
        sys.exit(0)
    _resolved = get_root_session_id(sys.argv[1])
    print(_resolved)
    if len(sys.argv) > 2 and sys.argv[2]:
        # Diagnostic flag: name the resolved source on STDERR only. Stdout
        # stays exactly one line in every case (see RESOLUTION_SOURCE doc).
        print(RESOLUTION_SOURCE, file=sys.stderr)
