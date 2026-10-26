"""Transcript samples built from the redacted turn cache.

build_messages turns cached records into the ``(role, content)`` pairs the
library expects: the record's text first, then one ``[tool: <name>]`` (or
``[tool]``) marker per tool call, joined with newlines and with empty parts
dropped. build_sample hands those pairs to the library's sample_transcript
with its default budgets and returns the excerpt text.

The cache already holds only redacted, clamped text, so the sample can
contain nothing the cache does not. The clamp in redact is a pre-cap on each
turn; the library's own per-message and total budgets decide what a sample
keeps.
"""
from __future__ import annotations

from typing import Iterable

from .cache import TurnCache
from .turns import ROLES, tool_markers


def build_messages(records: Iterable[dict]) -> list[tuple[str, str]]:
    messages: list[tuple[str, str]] = []
    for record in records:
        role = record.get("role")
        if role not in ROLES:
            continue
        text = record.get("text")
        tools = record.get("tools")
        parts = [text] if isinstance(text, str) and text else []
        if isinstance(tools, list):
            parts.extend(tool_markers(tools))
        messages.append((role, "\n".join(parts)))
    return messages


def build_sample(cache: TurnCache, sid: str) -> str:
    # Imported here so the package still imports when the runtime lacks the
    # library; the launcher reports that case as runtime_missing.
    from revenium_agent_economics import sample_transcript

    return sample_transcript(build_messages(cache.read(sid))).text
