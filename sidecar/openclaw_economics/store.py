"""Subprocess client for the session store's executed-mode verbs.

The sidecar never opens the OpenClaw SQLite store itself. Every read goes
through ``bash scripts/session-store.sh <verb>``, which owns the read-only
connection, the busy timeout and the store path allowlist. This client runs
the verbs from the host clone with OPENCLAW_HOME pointed at the arm's home:

- ``list-sessions``: ``<sid>`` 0x1F ``<key>`` 0x1F ``<created_via>`` 0x1F
  ``<updated_at>`` per line;
- ``max-seq <sid>``: one integer, -1 for an empty session;
- ``session-events-seq <sid> <after>``: ``<seq>`` 0x1F ``<event_json>`` per
  line, in seq order;
- ``null-event-count <sid>``: one integer.

Every session id is checked against the store's own id pattern before a
subprocess starts, and it is passed as an argv element, never through a
shell string. A timeout, a launch error or a non-zero exit counts one
failure and yields an empty result, so a store problem can never raise into
the infer stage. Output is decoded with replacement characters, so invalid
UTF-8 in event JSON cannot raise either.
"""
from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass
from typing import Callable

SESSION_ID_RE = re.compile(r"[0-9a-fA-F][0-9a-fA-F-]{7,63}")
_INT_RE = re.compile(r"-?[0-9]{1,20}")
_FIELD_SEP = "\x1f"


@dataclass(frozen=True)
class SessionRow:
    session_id: str
    session_key: str
    created_via: str
    updated_at: str


def valid_session_id(value: object) -> bool:
    return isinstance(value, str) and SESSION_ID_RE.fullmatch(value) is not None


def _parse_int(text: str) -> int | None:
    text = text.strip()
    if _INT_RE.fullmatch(text) is None:
        return None
    return int(text)


class StoreClient:
    """Run session-store.sh verbs; ``failures`` counts calls that failed."""

    def __init__(
        self,
        store_script: str,
        openclaw_home: str,
        *,
        timeout: float = 15.0,
        runner: Callable[..., subprocess.CompletedProcess] = subprocess.run,
    ) -> None:
        self.store_script = store_script
        self.openclaw_home = openclaw_home
        self.timeout = timeout
        self.runner = runner
        self.failures = 0

    def _call(self, verb: str, *args: str) -> str:
        env = dict(os.environ)
        env["OPENCLAW_HOME"] = self.openclaw_home
        try:
            proc = self.runner(
                ["bash", self.store_script, verb, *args],
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=self.timeout,
            )
        except Exception:  # noqa: BLE001 - a store problem must never raise
            self.failures += 1
            return ""
        if proc.returncode != 0:
            self.failures += 1
            return ""
        out = proc.stdout
        if isinstance(out, bytes):
            return out.decode("utf-8", errors="replace")
        return out if isinstance(out, str) else ""

    def list_sessions(self) -> list[SessionRow]:
        rows: list[SessionRow] = []
        for line in self._call("list-sessions").splitlines():
            parts = line.split(_FIELD_SEP)
            if len(parts) != 4 or not valid_session_id(parts[0]):
                continue
            rows.append(SessionRow(parts[0], parts[1], parts[2], parts[3].strip()))
        return rows

    def max_seq(self, sid: str) -> int | None:
        if not valid_session_id(sid):
            return None
        return _parse_int(self._call("max-seq", sid))

    def events_since(self, sid: str, after_seq: int) -> list[tuple[int, str]]:
        if not valid_session_id(sid) or not isinstance(after_seq, int):
            return []
        rows: list[tuple[int, str]] = []
        for line in self._call("session-events-seq", sid, str(after_seq)).splitlines():
            seq_text, sep, event_json = line.partition(_FIELD_SEP)
            seq = _parse_int(seq_text) if sep else None
            if seq is None:
                continue
            rows.append((seq, event_json))
        return rows

    def null_event_count(self, sid: str) -> int:
        if not valid_session_id(sid):
            return 0
        value = _parse_int(self._call("null-event-count", sid))
        return value if value is not None and value >= 0 else 0
