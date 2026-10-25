"""Sidecar launcher: the Python side of scripts/economics.sh.

Usage (from the cron shim only):
    python -E -s -B -X utf8 sidecar/run.py infer \\
        --state-dir S --openclaw-home O --skill-dir K --runtime-dir R \\
        --budget-seconds N
    python -E -s -B -X utf8 sidecar/run.py deliver --phase pre|post \\
        --state-dir S --openclaw-home O --skill-dir K --runtime-dir R \\
        --budget-seconds N

Exit codes (the shim maps each to a heartbeat reason):
    0    ok, the stage ran and wrote ``<state>/<stage>-status.json``
    1    crashing, an exception escaped the stage; its type name (never its
         message) is recorded in the status file
    3    runtime_missing, revenium_agent_economics is not importable
    4    unsafe_state_dir, a path failed validation; nothing is written
    124  timeout, the stage hit its own ``--budget-seconds`` deadline

Why ``-E -s`` and not ``-I``: ``-I`` implies ``-P``, which drops this
script's directory from ``sys.path`` and makes the ``openclaw_economics``
package beside it unimportable. ``-E`` already ignores every PYTHON*
variable and ``-s`` the user site directory; ``-B`` keeps ``__pycache__``
out of the skill tree.

Diagnostics go to stderr (the shim's log) as one line naming an exception
type or a fixed check code, never an exception message, which could carry
transcript text or secrets.
"""
from __future__ import annotations

import argparse
import importlib.util
import signal
import sys
import time

from openclaw_economics.paths import Context, UnsafePathError, build_context
from openclaw_economics.status import read_manifest, sanitize_token, write_stage_status

EXIT_OK = 0
EXIT_CRASH = 1
EXIT_RUNTIME_MISSING = 3
EXIT_UNSAFE_PATHS = 4
EXIT_DEADLINE = 124

LIBRARY_MODULE = "revenium_agent_economics"


class DeadlineExceeded(Exception):
    """Raised by the SIGALRM handler when the stage budget runs out."""


def _library_available() -> bool:
    try:
        return importlib.util.find_spec(LIBRARY_MODULE) is not None
    except (ImportError, ValueError):
        return False


def _diag(message: str) -> None:
    try:
        sys.stderr.write(f"[revenium-sidecar] {message}\n")
        sys.stderr.flush()
    except (OSError, ValueError):
        pass


def _on_deadline(signum, frame):  # noqa: ARG001 - signal handler signature
    raise DeadlineExceeded()


def run_infer(ctx: Context) -> dict:
    """Run the infer stage and return the counters for infer-status.json."""
    return {}


def run_deliver(ctx: Context, phase: str) -> tuple[dict, dict]:
    """Run the deliver stage; return (counters, extra status fields)."""
    return {}, {}


def _parse_args(argv):
    parser = argparse.ArgumentParser(prog="run.py", add_help=True)
    parser.add_argument("stage", choices=("infer", "deliver"))
    parser.add_argument("--phase", choices=("pre", "post"))
    parser.add_argument("--state-dir", required=True)
    parser.add_argument("--openclaw-home", required=True)
    parser.add_argument("--skill-dir", required=True)
    parser.add_argument("--runtime-dir", required=True)
    parser.add_argument("--budget-seconds", type=int, required=True)
    args = parser.parse_args(argv)
    if args.stage == "deliver" and args.phase is None:
        parser.error("deliver requires --phase pre|post")
    if args.stage == "infer" and args.phase is not None:
        parser.error("--phase applies to deliver only")
    return args


def _write_status(ctx, stage, reason, manifest, started, counters=None, extra=None) -> None:
    try:
        write_stage_status(
            ctx.state_dir,
            stage,
            reason=reason,
            counters=counters,
            extra=extra,
            manifest=manifest,
            started=started,
        )
    except Exception as exc:  # noqa: BLE001 - a status write must not mask the exit code
        _diag(f"{stage}: status write failed ({sanitize_token(type(exc).__name__)})")


def main(argv=None, *, find_library=_library_available) -> int:
    started = time.monotonic()
    args = _parse_args(argv)
    stage = args.stage
    ctx = None
    manifest: dict = {}

    previous_handler = signal.signal(signal.SIGALRM, _on_deadline)
    if isinstance(args.budget_seconds, int) and args.budget_seconds >= 1:
        signal.alarm(args.budget_seconds)
    try:
        try:
            ctx = build_context(args)
        except UnsafePathError as exc:
            signal.alarm(0)
            _diag(f"{stage}: refusing unsafe paths ({exc.code})")
            return EXIT_UNSAFE_PATHS

        manifest = read_manifest(ctx.runtime_dir)
        if not find_library():
            signal.alarm(0)
            _write_status(ctx, stage, "runtime_missing", manifest, started)
            return EXIT_RUNTIME_MISSING

        if stage == "infer":
            counters, extra = run_infer(ctx), {}
        else:
            counters, extra = run_deliver(ctx, args.phase)
        signal.alarm(0)
        _write_status(ctx, stage, "ok", manifest, started, counters, extra)
        return EXIT_OK
    except DeadlineExceeded:
        signal.alarm(0)
        _diag(f"{stage}: budget of {args.budget_seconds}s exceeded")
        if ctx is not None:
            _write_status(ctx, stage, "timeout", manifest, started)
        return EXIT_DEADLINE
    except Exception as exc:  # noqa: BLE001 - any stage failure becomes a reason
        signal.alarm(0)
        name = sanitize_token(type(exc).__name__)
        _diag(f"{stage}: crashed ({name})")
        if ctx is not None:
            _write_status(ctx, stage, "crashing", manifest, started, extra={"error": name})
        return EXIT_CRASH
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, previous_handler)


if __name__ == "__main__":
    sys.exit(main())
