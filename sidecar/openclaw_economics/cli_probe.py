"""revenium CLI version floor and capability probe, cached per CLI build.

Outcome-metric delivery needs ``revenium`` 1.7.0 or later with the
``jobs outcome-metrics`` and ``jobs types economics`` commands. This module
finds out whether the CLI on PATH has them and records the answer in
``<state>/cli-capability.json`` with the keys ``cliPath``, ``versionLine``,
``version``, ``floorOk``, ``outcomeMetrics``, ``typesEconomics``,
``capable`` and ``probedAt``.

Capability is read only from help text, never from exit codes: the CLI
prints its parent help and exits 0 for an unknown subcommand, and colours its
help with ANSI sequences even when piped. So the help is ANSI-stripped and a
command counts only when it is listed as a command name in the
``Available Commands:`` block, not when it appears in Examples or in a
wrapped description line.

The only commands run are ``revenium version``, ``revenium jobs --help`` and
``revenium jobs types --help``. The cached record is reused until the
resolved CLI path or the ``revenium version`` line changes, so a steady
state costs one ``revenium version`` call per deliver tick.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from typing import Callable

from .status import atomic_write_json, sanitize_token, utc_now_iso

FLOOR = (1, 7, 0)
CACHE_NAME = "cli-capability.json"
VERSION_ARGV = ("revenium", "version")
JOBS_HELP_ARGV = ("revenium", "jobs", "--help")
TYPES_HELP_ARGV = ("revenium", "jobs", "types", "--help")
OUTPUT_LIMIT = 262144

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
_VERSION_RE = re.compile(r"(\d+)\.(\d+)\.(\d+)")
_COMMANDS_HEADER = "Available Commands:"
_RECORD_KEYS = {
    "cliPath": str,
    "versionLine": str,
    "version": str,
    "floorOk": bool,
    "outcomeMetrics": bool,
    "typesEconomics": bool,
    "capable": bool,
    "probedAt": str,
}

Runner = Callable[..., "tuple[int, str]"]


def strip_ansi(text: str) -> str:
    """Remove ANSI CSI sequences such as ``\\x1b[38;5;255m`` and ``\\x1b[m``."""
    return _ANSI_RE.sub("", text)


def parse_version(text: str) -> tuple[int, int, int] | None:
    """First ``X.Y.Z`` in ``text`` as an int tuple, or None."""
    match = _VERSION_RE.search(text or "")
    if match is None:
        return None
    return int(match.group(1)), int(match.group(2)), int(match.group(3))


def version_meets_floor(version: tuple[int, int, int] | None) -> bool:
    """True when ``version`` is at least FLOOR; tuples compare numerically."""
    return version is not None and version >= FLOOR


def _indent(line: str) -> int:
    return len(line) - len(line.lstrip())


def available_commands(help_text: str) -> set[str]:
    """Command names listed in the ``Available Commands:`` block.

    The block runs from the header line to the next blank line. A command
    line is indented exactly like the block's first entry; deeper-indented
    lines are wrapped descriptions and are ignored.
    """
    names: set[str] = set()
    in_block = False
    command_indent = None
    for raw in strip_ansi(help_text or "").splitlines():
        if not in_block:
            if raw.strip() == _COMMANDS_HEADER:
                in_block = True
            continue
        if not raw.strip():
            break
        indent = _indent(raw)
        if command_indent is None:
            command_indent = indent
        if indent != command_indent:
            continue
        names.add(raw.split()[0])
    return names


def has_command(help_text: str, name: str) -> bool:
    """True when ``name`` is a command in the help's Available Commands block."""
    return name in available_commands(help_text)


def _run(argv, timeout: float = 10.0) -> tuple[int, str]:
    """Run ``argv`` with stdout and stderr merged; (127, "") when it cannot."""
    try:
        proc = subprocess.run(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return 127, ""
    return proc.returncode, proc.stdout[:OUTPUT_LIMIT].decode("utf-8", errors="replace")


def _resolve_cli(which) -> str:
    found = which("revenium")
    if not found:
        return ""
    return os.path.realpath(found)


def _version_line(runner: Runner) -> str:
    _rc, output = runner(list(VERSION_ARGV))
    for line in strip_ansi(output or "").splitlines():
        if line.strip():
            return sanitize_token(line.strip(), limit=128)
    return ""


def _record(cli_path: str, version_line: str, runner: Runner) -> dict:
    version = parse_version(version_line) if version_line else None
    floor_ok = version_meets_floor(version)
    outcome_metrics = False
    types_economics = False
    if cli_path and version_line:
        _rc, jobs_help = runner(list(JOBS_HELP_ARGV))
        outcome_metrics = has_command(jobs_help, "outcome-metrics")
        _rc, types_help = runner(list(TYPES_HELP_ARGV))
        types_economics = has_command(types_help, "economics")
    return {
        "cliPath": cli_path,
        "versionLine": version_line,
        "version": ".".join(str(part) for part in version) if version else "",
        "floorOk": floor_ok,
        "outcomeMetrics": outcome_metrics,
        "typesEconomics": types_economics,
        "capable": floor_ok and outcome_metrics and types_economics,
        "probedAt": utc_now_iso(),
    }


def probe(*, runner: Runner = _run, which=shutil.which) -> dict:
    """Probe the CLI on PATH from scratch and return a capability record."""
    cli_path = _resolve_cli(which)
    version_line = _version_line(runner) if cli_path else ""
    return _record(cli_path, version_line, runner)


def _load_cache(path: str) -> dict | None:
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    for key, kind in _RECORD_KEYS.items():
        if not isinstance(data.get(key), kind):
            return None
    return {key: data[key] for key in _RECORD_KEYS}


def load_or_probe(state_dir: str, *, runner: Runner = _run, which=shutil.which) -> dict:
    """Return the cached record when the CLI path and version line match.

    Otherwise probe the help texts and rewrite ``<state>/cli-capability.json``.
    """
    cli_path = _resolve_cli(which)
    version_line = _version_line(runner) if cli_path else ""
    cache_path = os.path.join(state_dir, CACHE_NAME)
    cached = _load_cache(cache_path)
    if (
        cached is not None
        and cached["cliPath"] == cli_path
        and cached["versionLine"] == version_line
    ):
        return cached
    record = _record(cli_path, version_line, runner)
    atomic_write_json(cache_path, record)
    return record
