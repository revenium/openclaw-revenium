"""Subprocess client for the session store's executed-mode verbs.

The sidecar never opens the OpenClaw SQLite store itself. Every read goes
through ``bash scripts/session-store.sh <verb>``, which owns the read-only
connection, the busy timeout and the store path allowlist. This client runs
the verbs from the host clone with OPENCLAW_HOME pointed at the arm's home:

- ``list-sessions-strict``: ``<sid>`` 0x1F ``<key>`` 0x1F ``<created_via>``
  0x1F ``<updated_at>`` per line;
- ``max-seq-strict <sid>``: one integer, -1 for a session with no events;
- ``max-seq-all-strict``: ``<sid>`` 0x1F ``<max seq>`` 0x1F ``<max readable
  seq>`` per session that has events, possibly once per store;
- ``session-events-seq-strict <sid> <after>``: ``<seq>`` 0x1F
  ``<event_json>`` per line, in seq order;
- ``null-event-count <sid>``: one integer.

The lenient verbs report.sh uses exit 0 even when SQLite fails, printing an
empty or partial answer. Cursors and the install baseline must never move on
such an answer, so every read that decides a cursor uses a ``-strict`` verb,
which exits 0 only when every candidate store answered completely and exits
non-zero (with no output) otherwise. Those methods return None on failure,
so "empty" and "failed" stay distinct. ``null-event-count`` only feeds a
counter, so the lenient verb is enough there.

Every session id is checked against the store's own id pattern before a
subprocess starts, and it is passed as an argv element, never through a
shell string. A timeout, a launch error or a non-zero exit counts one
failure, so a store problem can never raise into the infer stage. Output is
decoded with replacement characters, so invalid UTF-8 in event JSON cannot
raise either.
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


def _rows(out: str) -> list[str]:
    """Split verb output into rows on the newline character only.

    The verbs replace char(10) inside event_json, so the newline character
    is the only row separator they emit. Node's JSON.stringify writes
    U+2028, U+2029 and U+0085 raw inside strings, and a split that also
    breaks on every other Unicode line boundary would cut such a turn in
    two: its head fails to parse, its tail has no seq and is dropped, and
    the cursor still moves past the row, so the turn is lost for good.
    """
    return out.split("\n")


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

    def _call(self, verb: str, *args: str) -> str | None:
        """Verb stdout, or None when the call failed (counted in failures)."""
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
            # The stage deadline is a BaseException, so it is not counted
            # here as a store failure; it stops the stage instead.
            self.failures += 1
            return None
        if proc.returncode != 0:
            self.failures += 1
            return None
        out = proc.stdout
        if isinstance(out, bytes):
            return out.decode("utf-8", errors="replace")
        return out if isinstance(out, str) else ""

    def list_sessions(self) -> list[SessionRow] | None:
        """Every non-cron session across all stores, or None if any store failed."""
        out = self._call("list-sessions-strict")
        if out is None:
            return None
        rows: list[SessionRow] = []
        for line in out.splitlines():
            parts = line.split(_FIELD_SEP)
            if len(parts) != 4 or not valid_session_id(parts[0]):
                continue
            rows.append(SessionRow(parts[0], parts[1], parts[2], parts[3].strip()))
        return rows

    def max_seq(self, sid: str) -> int | None:
        """Highest seq across all stores (-1 when none), or None on failure."""
        if not valid_session_id(sid):
            return None
        out = self._call("max-seq-strict", sid)
        return None if out is None else _parse_int(out)

    def max_seq_all(self) -> dict[str, tuple[int, int]] | None:
        """(max seq, max readable seq) per session across all stores.

        None when any store failed. A session missing from the result has no
        events; "readable" leaves out compacted rows, which
        session-events-seq-strict never returns.
        """
        out = self._call("max-seq-all-strict")
        if out is None:
            return None
        tops: dict[str, tuple[int, int]] = {}
        for line in out.splitlines():
            parts = line.split(_FIELD_SEP)
            if len(parts) != 3 or not valid_session_id(parts[0]):
                continue
            top, readable = _parse_int(parts[1]), _parse_int(parts[2])
            if top is None or readable is None:
                continue
            seen = tops.get(parts[0], (top, readable))
            tops[parts[0]] = (max(top, seen[0]), max(readable, seen[1]))
        return tops

    def events_since(self, sid: str, after_seq: int) -> list[tuple[int, str]] | None:
        """Rows with seq > after_seq in seq order, or None on failure."""
        if not valid_session_id(sid) or not isinstance(after_seq, int):
            return None
        out = self._call("session-events-seq-strict", sid, str(after_seq))
        if out is None:
            return None
        rows: list[tuple[int, str]] = []
        for line in _rows(out):
            seq_text, sep, event_json = line.partition(_FIELD_SEP)
            seq = _parse_int(seq_text) if sep else None
            if seq is None:
                continue
            rows.append((seq, event_json))
        return rows

    def null_event_count(self, sid: str) -> int:
        if not valid_session_id(sid):
            return 0
        value = _parse_int(self._call("null-event-count", sid) or "")
        return value if value is not None and value >= 0 else 0
