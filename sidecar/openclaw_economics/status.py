"""Atomic JSON writes and per-stage status files.

Every file the sidecar writes into its state dir goes through
atomic_write_json: a temp file in the target's directory, chmod, fsync, then
os.replace, so a reader never sees a partial document and a failed write
leaves the previous file intact.

Stage status files are ``<state>/<stage>-status.json`` with the keys
``schema``, ``stage``, ``reason``, ``updatedAt``, ``durationMs``,
``counters``, ``library`` (``sha``, ``version``) and, when present, ``error``
(an exception type name, never a message) and ``cli`` (deliver only).

The runtime manifest ``<runtime>/INSTALLED`` is parsed as ``key=value``
lines, never executed, and every value is stripped of control characters and
length-capped before use.
"""
from __future__ import annotations

import json
import os
import tempfile
import time
from datetime import datetime, timezone
from typing import Any

from . import STATUS_SCHEMA

LIBRARY_DIST = "revenium-agent-economics"
MANIFEST_NAME = "INSTALLED"


def utc_now_iso() -> str:
    """Current UTC time as ``YYYY-MM-DDTHH:MM:SSZ``."""
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sanitize_token(value: Any, limit: int = 64) -> str:
    """Drop control characters (below 0x20, and 0x7f), then cut to ``limit``."""
    text = value if isinstance(value, str) else str(value)
    return "".join(ch for ch in text if ord(ch) >= 0x20 and ch != "\x7f")[:limit]


def atomic_write_json(path: str, data: Any, *, mode: int = 0o600) -> None:
    """Write ``data`` as JSON to ``path`` atomically with permission ``mode``."""
    directory = os.path.dirname(os.path.abspath(path))
    fd, tmp_path = tempfile.mkstemp(
        dir=directory, prefix="." + os.path.basename(path) + ".", suffix=".tmp"
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(json.dumps(data, sort_keys=True, indent=2) + "\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp_path, path)
    finally:
        if os.path.exists(tmp_path):
            try:
                os.unlink(tmp_path)
            except OSError:
                pass


def read_manifest(runtime_dir: str) -> dict:
    """Parse ``<runtime>/INSTALLED``; a missing or unreadable file gives ``{}``."""
    result: dict = {}
    try:
        with open(
            os.path.join(runtime_dir, MANIFEST_NAME), encoding="utf-8", errors="replace"
        ) as handle:
            lines = handle.read(65536).splitlines()
    except OSError:
        return result
    for line in lines:
        key, sep, value = line.partition("=")
        key = key.strip()
        if not sep or not key or not key.replace("_", "").isalnum():
            continue
        if key not in result:
            result[key] = sanitize_token(value, limit=128)
    return result


def _library_version() -> str:
    try:
        from importlib import metadata

        return sanitize_token(metadata.version(LIBRARY_DIST))
    except Exception:  # noqa: BLE001 - version is informational only
        return ""


def write_stage_status(
    state_dir: str,
    stage: str,
    *,
    reason: str,
    counters: dict | None = None,
    extra: dict | None = None,
    manifest: dict | None = None,
    started: float | None = None,
) -> str:
    """Write ``<state>/<stage>-status.json`` and return its path.

    ``started`` is a ``time.monotonic()`` reading taken when the stage began.
    """
    duration_ms = 0
    if started is not None:
        duration_ms = max(0, int((time.monotonic() - started) * 1000))
    clean_counters = {}
    for key, value in (counters or {}).items():
        if isinstance(value, int) and not isinstance(value, bool):
            clean_counters[sanitize_token(key)] = value
    manifest = manifest or {}
    data: dict = {
        "schema": STATUS_SCHEMA,
        "stage": stage,
        "reason": reason,
        "updatedAt": utc_now_iso(),
        "durationMs": duration_ms,
        "counters": clean_counters,
        "library": {
            "sha": manifest.get("library_sha", ""),
            "version": _library_version(),
        },
    }
    for key, value in (extra or {}).items():
        if key == "error":
            data["error"] = sanitize_token(value)
        elif key == "cli":
            data["cli"] = value
    path = os.path.join(state_dir, f"{stage}-status.json")
    atomic_write_json(path, data)
    return path
