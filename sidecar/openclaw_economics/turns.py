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
- A tool name is model-written text, so it gets the same redaction as turn
  text: the regex pass and the host-known-value pass. A name that redaction
  would change, or that looks like a random token, is replaced with "" and
  never cached. Redacting part of a name would leave a fragment beside the
  marker; dropping the whole name loses only a label.
- Progressive tool disclosure: newer OpenClaw builds route most calls
  through a meta-tool named ``tool_call``, whose arguments carry the real
  tool as ``{"id": "openclaw:core:<tool>", "args": {...}}``. The name
  ``tool_call`` says nothing about what ran, so for that one name the
  ``id`` string is read and its last ``:`` segment becomes the tool name
  when both pass TOOL_NAME_RE. The whole ``id`` must first pass the regex
  and host-known-value redaction passes unchanged, or the call is recorded
  as ``[tool]``: a value that contains ``:``, or a ``name:value``
  assignment such as ``api_key:<value>``, would otherwise leave its tail
  behind as a clean-looking tool name. The token-shape check runs on the
  kept segment only, so a hashed namespace segment does not drop a real
  name. ``args`` and every other argument value are never read. The
  nested execution is also recorded as a separate ``custom`` row;
  dropping custom rows keeps it from being counted twice.
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

from . import redact
from .status import sanitize_token

TOOL_NAME_RE = re.compile(r"[A-Za-z0-9_.:-]{1,64}")
META_TOOL_NAME = "tool_call"
MAX_TOOLS_PER_TURN = 64

# Real tool names are words joined by separators (exec, web_search,
# mcp__github__create_issue). An unbroken alphanumeric run this long, or a
# shorter one mixing letters with several digits, is an id or a key, which
# the regex pass does not know when the issuer uses no fixed prefix.
_TOKEN_RUN_RE = re.compile(r"[A-Za-z0-9]{16,}")
TOKEN_RUN_ALWAYS = 32
TOKEN_RUN_MIN_DIGITS = 3

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


def _secret_shaped(name: str) -> bool:
    for run in _TOKEN_RUN_RE.findall(name):
        if len(run) >= TOKEN_RUN_ALWAYS:
            return True
        digits = sum(ch.isdigit() for ch in run)
        if digits >= TOKEN_RUN_MIN_DIGITS and digits < len(run):
            return True
    return False


def _unchanged_by_redaction(value: str, known_values: Iterable[str]) -> bool:
    """True when the regex and exact-value passes leave value as it is.

    Only Exception counts as a failure, and it fails closed. The stage
    deadline is a BaseException and passes through.
    """
    try:
        return redact.redact(value, known_values) == value
    except Exception:  # noqa: BLE001 - fail closed: an unchecked name is dropped
        return False


def clean_tool_name(name: Any, known_values: Iterable[str] = ()) -> str:
    """Return name when it is a valid, secret-free tool name, else ""."""
    if not valid_tool_name(name) or _secret_shaped(name):
        return ""
    return name if _unchanged_by_redaction(name, known_values) else ""


def _tool_name(item: dict, known_values: Iterable[str]) -> str:
    name = item.get("name")
    if not valid_tool_name(name):
        return ""
    if name == META_TOOL_NAME:
        arguments = item.get("arguments")
        if isinstance(arguments, dict):
            wrapped = arguments.get("id")
            if valid_tool_name(wrapped):
                if not _unchanged_by_redaction(wrapped, known_values):
                    return ""
                real = wrapped.rpartition(":")[2]
                if valid_tool_name(real):
                    return clean_tool_name(real, known_values)
    return clean_tool_name(name, known_values)


def strip_directives(text: str) -> str:
    for pattern in DIRECTIVE_PATTERNS:
        text = pattern.sub("", text)
    return text


def extract(seq: int, event_json: str, known_values: Iterable[str] = ()) -> Message | None:
    """Return the Message carried by one event row, or None.

    known_values feeds the exact-value pass applied to tool names; text is
    returned unredacted for the caller's sanitize_turn.
    """
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
                tools.append(_tool_name(item, known_values))

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
    """``[tool: <name>]`` per clean name, ``[tool]`` for anything else.

    The regex and shape checks run again here, so a cache line written
    before names were checked cannot put a secret into a sample.
    """
    markers = []
    for name in tools:
        clean = clean_tool_name(name)
        markers.append(f"[tool: {clean}]" if clean else "[tool]")
    return markers
