"""Per-session turn cache and read cursors in the sidecar state dir.

``<state>/turns/<session_id>.jsonl`` holds one JSON object per line with the
keys ``seq``, ``id``, ``parentId``, ``role``, ``ts``, ``text`` (already
redacted and clamped) and ``tools`` (validated tool names). Lines are UTF-8
JSON written with ``ensure_ascii=False``, so the size of a file on disk is
its size in bytes. The directory is 0700 and every file 0600.

``<state>/cursors.json`` records, per session, the highest store seq the
sidecar has consumed and the store ``updated_at`` seen at that time::

    {"version": 1, "baselinedAt": "<iso>",
     "sessions": {"<sid>": {"cursor": <int>, "updatedAt": "<text>"}}}

Cursors are JSON integers, so any 64-bit seq round-trips exactly.

Write order: records are appended and fsynced before the cursor that covers
them is saved. A crash in between leaves the cursor behind the cache, the
next run re-reads those rows, and append drops every seq at or below the
file's last seq, so nothing is cached twice.
"""
from __future__ import annotations

import json
import os
from typing import Iterable

from .status import atomic_write_json, utc_now_iso
from .store import valid_session_id

TURNS_DIR = "turns"
CURSORS_FILE = "cursors.json"
CURSORS_VERSION = 1
TAIL_READ_BYTES = 65536


def _encode(record: dict) -> bytes:
    line = json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n"
    return line.encode("utf-8", errors="replace")


def _record_seq(raw: bytes) -> int | None:
    try:
        record = json.loads(raw.decode("utf-8", errors="replace"))
    except ValueError:
        return None
    if not isinstance(record, dict):
        return None
    seq = record.get("seq")
    if isinstance(seq, int) and not isinstance(seq, bool):
        return seq
    return None


class TurnCache:
    def __init__(self, state_dir: str) -> None:
        self.state_dir = state_dir
        self.dir = os.path.join(state_dir, TURNS_DIR)

    def path(self, sid: str) -> str:
        if not valid_session_id(sid):
            raise ValueError("invalid session id")
        return os.path.join(self.dir, sid + ".jsonl")

    def _ensure_dir(self) -> None:
        if not os.path.isdir(self.dir):
            os.mkdir(self.dir, 0o700)
        os.chmod(self.dir, 0o700)

    def _tail(self, path: str) -> bytes:
        try:
            with open(path, "rb") as handle:
                handle.seek(0, os.SEEK_END)
                size = handle.tell()
                handle.seek(max(0, size - TAIL_READ_BYTES))
                return handle.read()
        except OSError:
            return b""

    def last_seq(self, sid: str) -> int:
        """Seq of the last complete record, or -1 when there is none."""
        tail = self._tail(self.path(sid))
        for raw in reversed(tail.split(b"\n")):
            if raw.strip():
                seq = _record_seq(raw)
                if seq is not None:
                    return seq
        return -1

    def append(self, sid: str, records: Iterable[dict]) -> int:
        """Append records newer than the file's last seq; return the count."""
        path = self.path(sid)
        last = self.last_seq(sid)
        fresh = []
        for record in records:
            seq = record.get("seq")
            if isinstance(seq, int) and seq > last:
                fresh.append(record)
                last = seq
        if not fresh:
            return 0
        self._ensure_dir()
        payload = b"".join(_encode(r) for r in fresh)
        tail = self._tail(path)
        if tail and not tail.endswith(b"\n"):
            # A torn final line from an interrupted write: end it so the new
            # records start on their own lines.
            payload = b"\n" + payload
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            os.fchmod(fd, 0o600)
            view = memoryview(payload)
            while view:
                written = os.write(fd, view)
                view = view[written:]
            os.fsync(fd)
        finally:
            os.close(fd)
        return len(fresh)

    def read(self, sid: str) -> list[dict]:
        try:
            with open(self.path(sid), "rb") as handle:
                data = handle.read()
        except OSError:
            return []
        records = []
        for raw in data.split(b"\n"):
            if not raw.strip():
                continue
            try:
                record = json.loads(raw.decode("utf-8", errors="replace"))
            except ValueError:
                continue
            if isinstance(record, dict):
                records.append(record)
        return records


class Cursors:
    def __init__(self, state_dir: str) -> None:
        self.path = os.path.join(state_dir, CURSORS_FILE)
        self.baseline_needed = True
        self.baselined_at = ""
        self.sessions: dict[str, dict] = {}

    @classmethod
    def load(cls, state_dir: str) -> "Cursors":
        cursors = cls(state_dir)
        try:
            with open(cursors.path, encoding="utf-8") as handle:
                doc = json.load(handle)
        except (OSError, ValueError):
            return cursors
        if not isinstance(doc, dict) or not isinstance(doc.get("sessions"), dict):
            return cursors
        for sid, entry in doc["sessions"].items():
            if not valid_session_id(sid) or not isinstance(entry, dict):
                continue
            cursor = entry.get("cursor")
            if not isinstance(cursor, int) or isinstance(cursor, bool):
                continue
            updated = entry.get("updatedAt")
            cursors.sessions[sid] = {
                "cursor": cursor,
                "updatedAt": updated if isinstance(updated, str) else "",
            }
        baselined = doc.get("baselinedAt")
        cursors.baselined_at = baselined if isinstance(baselined, str) else ""
        cursors.baseline_needed = False
        return cursors

    def get(self, sid: str) -> dict | None:
        return self.sessions.get(sid)

    def set(self, sid: str, cursor: int, updated_at: str) -> None:
        self.sessions[sid] = {"cursor": int(cursor), "updatedAt": str(updated_at)}

    def mark_baselined(self) -> None:
        self.baselined_at = utc_now_iso()
        self.baseline_needed = False

    def save(self) -> None:
        atomic_write_json(
            self.path,
            {
                "version": CURSORS_VERSION,
                "baselinedAt": self.baselined_at,
                "sessions": self.sessions,
            },
        )
