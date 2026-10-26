"""Turn extraction from stored transcript events.

extract turns one ``transcript_events.event_json`` row into a Message, or
None when the row holds nothing the classifier may see. Only ``message``
events whose role is ``user`` or ``assistant`` are kept. Tool results,
system rows and ``custom`` rows are dropped whole, because their bodies are
tool output and tool input, which never leave the store.

Event shapes handled:

- ``message.content`` is either a plain string (user rows and custom rows on
  both arms) or a list of items. From a list, only ``text`` items are kept,
  joined with newlines; ``thinking`` and every other item type are ignored.
- A ``toolCall`` item contributes only its name, checked against
  TOOL_NAME_RE; any other name is kept as "" and rendered ``[tool]``. Tool
  arguments are never read, with one narrow exception below.
- Progressive tool disclosure: newer OpenClaw builds route most calls
  through a meta-tool named ``tool_call``, whose arguments carry the real
  tool as ``{"id": "openclaw:core:<tool>", "args": {...}}``. The name
  ``tool_call`` says nothing about what ran, so for that one name the
  ``id`` string is read and its last ``:`` segment becomes the tool name
  when both pass TOOL_NAME_RE. ``args`` and every other argument value are
  never read. The nested execution is also recorded as a separate
  ``custom`` row; dropping custom rows keeps it from being counted twice.
- User text can carry the directive blocks the Revenium plugins and the
  AGENTS.md injection prepend each turn. Those blocks are stripped before
  the text is redacted, so directive text never reaches the cache.

Ids and timestamps pass through status.sanitize_token. Text is returned
as found; the caller redacts and clamps it.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass
from typing import Any, Iterable

from .status import sanitize_token

TOOL_NAME_RE = re.compile(r"[A-Za-z0-9_.:-]{1,64}")
META_TOOL_NAME = "tool_call"
MAX_TOOLS_PER_TURN = 64

DIRECTIVE_PATTERNS = (
    re.compile(r"<revenium-guard>.*?</revenium-guard>", re.DOTALL),
    re.compile(r"<revenium-metering>.*?</revenium-metering>", re.DOTALL),
    re.compile(
        r"<!-- BEGIN revenium-metering-directives -->.*?"
        r"<!-- END revenium-metering-directives -->",
        re.DOTALL,
    ),
)

ROLES = ("user", "assistant")


@dataclass(frozen=True)
class Message:
    seq: int
    event_id: str
    parent_id: str
    role: str
    ts: str
    text: str
    tools: tuple[str, ...]


def valid_tool_name(value: Any) -> bool:
    return isinstance(value, str) and TOOL_NAME_RE.fullmatch(value) is not None


def _token(value: Any) -> str:
    if value is None:
        return ""
    # A JSON "\ud800" escape decodes to a lone surrogate, which cannot be
    # written as UTF-8; replace it here so a cache line always encodes.
    return sanitize_token(value).encode("utf-8", errors="replace").decode("utf-8")


def _tool_name(item: dict) -> str:
    name = item.get("name")
    if not valid_tool_name(name):
        return ""
    if name == META_TOOL_NAME:
        arguments = item.get("arguments")
        if isinstance(arguments, dict):
            wrapped = arguments.get("id")
            if valid_tool_name(wrapped):
                real = wrapped.rpartition(":")[2]
                if valid_tool_name(real):
                    return real
    return name


def strip_directives(text: str) -> str:
    for pattern in DIRECTIVE_PATTERNS:
        text = pattern.sub("", text)
    return text


def extract(seq: int, event_json: str) -> Message | None:
    """Return the Message carried by one event row, or None."""
    try:
        event = json.loads(event_json)
    except (TypeError, ValueError, RecursionError):
        return None
    if not isinstance(event, dict) or event.get("type") != "message":
        return None
    message = event.get("message")
    if not isinstance(message, dict):
        return None
    role = message.get("role")
    if role not in ROLES:
        return None

    content = message.get("content")
    parts: list[str] = []
    tools: list[str] = []
    if isinstance(content, str):
        parts.append(content)
    elif isinstance(content, list):
        for item in content:
            if not isinstance(item, dict):
                continue
            kind = item.get("type")
            if kind == "text" and isinstance(item.get("text"), str):
                parts.append(item["text"])
            elif kind == "toolCall" and len(tools) < MAX_TOOLS_PER_TURN:
                tools.append(_tool_name(item))

    text = "\n".join(parts)
    if role == "user":
        text = strip_directives(text)
    text = text.strip()
    if not text and not tools:
        return None

    return Message(
        seq=seq,
        event_id=_token(event.get("id")),
        parent_id=_token(event.get("parentId")),
        role=role,
        ts=_token(event.get("timestamp")),
        text=text,
        tools=tuple(tools),
    )


def tool_markers(tools: Iterable[str]) -> list[str]:
    """``[tool: <name>]`` per valid name, ``[tool]`` for anything else."""
    return [f"[tool: {name}]" if valid_tool_name(name) else "[tool]" for name in tools]
