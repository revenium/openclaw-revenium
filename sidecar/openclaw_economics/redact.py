"""Fail-closed redaction and head/tail clamp for turn text.

Every piece of transcript text bound for the turn cache or a model provider
passes through sanitize_turn, which runs three steps in a fixed order:

1. precap: text longer than 64 KiB keeps only its first and last 16 KiB,
   which bounds regex cost on huge pastes. The later clamp drops the cut
   region anyway.
2. redact: an ordered regex pass replaces secret shapes with
   ``[REDACTED:<kind>]``, then an exact-value pass replaces values known on
   this host (the Revenium API key, env-file values, model key files) with
   ``[REDACTED:known]``, longest first.
3. clamp: text longer than 2,100 characters keeps its first and last 1,000.

Redaction runs before the clamp because clamping first can cut a secret so
that the fragment left behind no longer matches its pattern. Any exception
in any step returns ``[turn omitted]`` instead of the text.

All work is on str code points, so a clamp never splits a character. The
patterns avoid nested quantifiers, and the open-ended ones are anchored so
that a long run of token characters is scanned once, not once per position.

The module is silent: it produces no output of any kind, holds no output
handles, and never raises an exception whose message carries text or values.
"""
from __future__ import annotations

import re
from typing import Iterable

PRECAP_CHARS = 65536
PRECAP_KEEP = 16384
CLAMP_HEAD = 1000
CLAMP_TAIL = 1000
CLAMP_SLACK = 100
MIN_KNOWN_VALUE = 8
OMITTED = "[turn omitted]"
KNOWN_MARKER = "[REDACTED:known]"
KNOWN_FILE_LIMIT = 1 << 20

# A token character run is matched only from its first character (the
# lookbehinds), and a key name is length-bounded, so a long run such as
# "eyJeyJeyJ..." or "a-a-a-..." costs linear time instead of quadratic.
_ASSIGNMENT_NAME = (
    r"[A-Z0-9_.-]{0,64}"
    r"(?:api[_-]?key|secret|token|passw(?:or)?d|pwd|credential|private[_-]?key)"
    r"[A-Z0-9_.-]{0,64}"
)

PATTERNS = (
    ("pem", re.compile(
        r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----")),
    ("pem-unterminated", re.compile(r"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*\Z")),
    ("anthropic", re.compile(r"sk-ant-[A-Za-z0-9_-]{16,}")),
    ("openai", re.compile(r"sk-(?:proj-)?[A-Za-z0-9_-]{20,}")),
    ("revenium", re.compile(r"rev_sk[A-Za-z0-9_-]{8,}")),
    ("aws", re.compile(r"(?:AKIA|ASIA)[0-9A-Z]{16}")),
    ("github", re.compile(r"gh[pousr]_[A-Za-z0-9]{36,}")),
    ("github-pat", re.compile(r"github_pat_[A-Za-z0-9_]{22,}")),
    ("slack", re.compile(r"xox[abprs]-[A-Za-z0-9-]{10,}")),
    ("google", re.compile(r"AIza[0-9A-Za-z_-]{35}")),
    ("jwt", re.compile(
        r"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}")),
    ("bearer", re.compile(r"(?i)\bbearer\s+[A-Za-z0-9._~+/-]{8,}=*")),
    ("url-credentials", re.compile(r"(?<=://)[^/\s:@]+:[^/\s@]+(?=@)")),
    ("assignment", re.compile(
        r"\b(" + _ASSIGNMENT_NAME + r")(\s*[:=]\s*)(\"[^\"\n]*\"|'[^'\n]*'|[^\s,;]+)",
        re.IGNORECASE,
    )),
)


def _assignment_replacement(match: "re.Match[str]") -> str:
    return match.group(1) + match.group(2) + "[REDACTED:assignment]"


def precap(text: str) -> str:
    """Keep the first and last PRECAP_KEEP characters of an over-long text."""
    if len(text) <= PRECAP_CHARS:
        return text
    elided = len(text) - 2 * PRECAP_KEEP
    return (
        text[:PRECAP_KEEP]
        + f"\n[… {elided} chars elided before redaction …]\n"
        + text[-PRECAP_KEEP:]
    )


def redact(text: str, known_values: Iterable[str]) -> str:
    """Regex pass, then exact-value pass (longest value first)."""
    for kind, pattern in PATTERNS:
        if kind == "assignment":
            text = pattern.sub(_assignment_replacement, text)
        else:
            text = pattern.sub(f"[REDACTED:{kind}]", text)
    values = sorted(
        {v for v in known_values if isinstance(v, str) and len(v) >= MIN_KNOWN_VALUE},
        key=lambda v: (-len(v), v),
    )
    for value in values:
        text = text.replace(value, KNOWN_MARKER)
    return text


def clamp(text: str) -> str:
    """Keep the first CLAMP_HEAD and last CLAMP_TAIL characters of long text."""
    if len(text) <= CLAMP_HEAD + CLAMP_TAIL + CLAMP_SLACK:
        return text
    elided = len(text) - CLAMP_HEAD - CLAMP_TAIL
    return text[:CLAMP_HEAD] + f"\n[… {elided} chars elided …]\n" + text[-CLAMP_TAIL:]


def sanitize_turn(text: str, known_values: Iterable[str]) -> tuple[str, bool]:
    """Return (sanitized text, omitted). Any failure yields (OMITTED, True).

    Only Exception is caught. The stage deadline is a BaseException and
    passes through: a turn cut off by the deadline was not redacted, it was
    interrupted, and caching it as omitted would lose it for good.
    """
    try:
        if not isinstance(text, str):
            raise TypeError("text must be str")
        out = precap(text)
        out = redact(out, known_values)
        out = clamp(out)
        # JSON-decoded transcripts can carry lone surrogates, which do not
        # encode to UTF-8; replace them so every result is encodable.
        out = out.encode("utf-8", errors="replace").decode("utf-8")
        return out, False
    except Exception:  # noqa: BLE001 - fail closed, never surface the text
        return OMITTED, True


def _read_small(path: str) -> str | None:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read(KNOWN_FILE_LIMIT)
    except (OSError, UnicodeDecodeError, ValueError):
        return None


def _unquote(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        value = value[1:-1]
    return value


def load_known_values(
    *,
    config_yaml: str | None = None,
    env_files: Iterable[str] = (),
    key_files: Iterable[str] = (),
) -> tuple[str, ...]:
    """Collect host-known secret values for the exact-value pass.

    Reads the ``api-key:`` value from the revenium config YAML, every value
    from ``KEY=VALUE`` lines in the env files (``export`` prefix and quotes
    removed) and the stripped content of each key file. Unreadable files are
    skipped. Values shorter than MIN_KNOWN_VALUE are dropped; the result is
    deduplicated and sorted longest first.
    """
    found: set[str] = set()

    if config_yaml:
        content = _read_small(config_yaml)
        for line in (content or "").splitlines():
            key, sep, value = line.partition(":")
            if sep and key.strip() == "api-key":
                found.add(_unquote(value))

    for path in env_files:
        content = _read_small(path)
        for line in (content or "").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("export "):
                line = line[len("export "):].lstrip()
            key, sep, value = line.partition("=")
            if sep and key.strip():
                found.add(_unquote(value))

    for path in key_files:
        content = _read_small(path)
        if content is not None:
            found.add(content.strip())

    return tuple(sorted((v for v in found if len(v) >= MIN_KNOWN_VALUE), key=lambda v: (-len(v), v)))
