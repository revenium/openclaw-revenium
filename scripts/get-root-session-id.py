#!/usr/bin/env python3
"""Resolve a child session id to its root via JSONL childSessionKey reverse walk.

TRACE-01 root-session resolution for OpenClaw. Mirrors the Hermes resolver contract
(max_depth=10 cycle guard, fail-open to input sid, never raises) but scans
JSONL session files for `sessions_spawn` toolResult lines carrying
`details.childSessionKey` instead of walking a SQLite state.db.

Background:
  OpenClaw has no SQLite state.db. The session JSONL header carries only
  type/version/id/timestamp/cwd — no cross-session parent linkage.
  The ONLY cross-session linkage is a `sessions_spawn` toolResult written
  in the PARENT session file with:
      details.childSessionKey = "agent:main:subagent:<child-uuid>"
  Because the linkage is forward (parent declares child) and the resolver
  needs reverse (child → root), we build a child→parent reverse map once
  by scanning all *.jsonl files, then walk to the root.

Production callers shell in via the bash wrapper in scripts/common.sh:
    root_sid="$(get_root_session_id "${sid}")"

Tests import the function directly and pass sessions_dir=<tempdir>.
"""
from __future__ import annotations

import json
import os
import sys
from typing import Optional


def get_root_session_id(
    sid: str,
    sessions_dir: Optional[str] = None,
    max_depth: int = 10,
) -> str:
    """Walk childSessionKey reverse map to the root session id.

    Returns the input sid on any error path: missing sessions_dir, OSError
    reading files, malformed JSON lines, or a cycle that exceeds max_depth.
    Never raises (D-05/D-06 fail-open invariant).

    Args:
        sid: Session id to resolve. Empty string returns empty string.
        sessions_dir: Path to *.jsonl session directory. Defaults to
            OPENCLAW_HOME/agents/main/sessions (expanduser ~/.openclaw fallback).
        max_depth: Maximum walk depth to guard against cycles. Default 10.

    Returns:
        Root session id string, or input sid on any failure.
    """
    if not sid:
        return sid

    if sessions_dir is None:
        sessions_dir = os.path.join(
            os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw")),
            "agents", "main", "sessions",
        )

    try:
        # Build reverse map: child_uuid -> parent_sid.
        # Cheap pre-filter on the raw line string before json.loads so the
        # common (no-subagent) case scans without parsing (NP-2 / Pitfall 3).
        child_to_parent: dict[str, str] = {}
        for fname in os.listdir(sessions_dir):
            if not fname.endswith(".jsonl"):
                continue
            parent_sid = fname[: -len(".jsonl")]
            try:
                with open(os.path.join(sessions_dir, fname), encoding="utf-8") as fh:
                    for line in fh:
                        if '"sessions_spawn"' not in line:
                            continue  # cheap pre-filter
                        try:
                            obj = json.loads(line)
                        except Exception:
                            continue  # T-04-01: skip malformed lines
                        det = (obj.get("message") or {}).get("details") or {}
                        ck = det.get("childSessionKey")
                        if ck:
                            # Strip "agent:main:subagent:" prefix, keep UUID suffix.
                            child_to_parent[ck.rsplit(":", 1)[-1]] = parent_sid
            except OSError:
                continue  # T-04-01: skip unreadable files

        # Walk the reverse map to the root (T-04-02: max_depth cap guards cycles).
        current = sid
        for _ in range(max_depth):
            parent = child_to_parent.get(current)
            if parent is None:
                return current  # current is the root
            current = parent
        return current  # depth cap hit — fail-open to deepest resolved

    except Exception:
        return sid  # T-04-01: blanket guard, never raises


if __name__ == "__main__":
    if len(sys.argv) < 2 or not sys.argv[1]:
        sys.exit(0)
    print(get_root_session_id(sys.argv[1]))
