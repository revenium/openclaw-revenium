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
import os
import signal
import stat
import sys
import time

from openclaw_economics import cli_probe, redact, turns
from openclaw_economics.cache import MISSES_BEFORE_DROP, Cursors, TurnCache
from openclaw_economics.paths import Context, UnsafePathError, build_context
from openclaw_economics.status import read_manifest, sanitize_token, write_stage_status
from openclaw_economics.store import StoreClient

EXIT_OK = 0
EXIT_CRASH = 1
EXIT_RUNTIME_MISSING = 3
EXIT_UNSAFE_PATHS = 4
EXIT_DEADLINE = 124

# Infer stops starting new sessions this long before its budget runs out, so
# it can save cursors and status before the hard SIGALRM deadline.
SOFT_MARGIN_SECONDS = 5

LIBRARY_MODULE = "revenium_agent_economics"


# A temp file in the state dir older than this was left by a write that a
# kill interrupted. Every stage budget is far shorter, so no live write (the
# deliver stage can run at the same time as infer) is ever this old.
STALE_TMP_SECONDS = 600


class DeadlineExceeded(BaseException):
    """Raised by the SIGALRM handler when the stage budget runs out.

    A BaseException, so the ``except Exception`` handlers that keep a store
    or redaction problem from failing the stage cannot swallow it. Swallowed,
    it would let a turn interrupted mid-redaction be cached as omitted with
    its cursor moved past it, and the one-shot alarm would never fire again.
    """


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


def _known_values(ctx: Context) -> tuple[str, ...]:
    home = os.path.expanduser("~")
    return redact.load_known_values(
        config_yaml=os.path.join(home, ".config", "revenium", "config.yaml"),
        env_files=[
            os.path.join(ctx.openclaw_home, "revenium.env"),
            os.path.join(home, ".nemoclaw", "revenium-host.env"),
        ],
        key_files=[os.path.join(ctx.state_dir, "model.key")],
    )


def _sweep_stale_tmp(state_dir: str, now: float) -> None:
    """Remove ``.<name>.<random>.tmp`` files a killed write left behind."""
    try:
        names = os.listdir(state_dir)
    except OSError:
        return
    for name in names:
        if not (name.startswith(".") and name.endswith(".tmp")):
            continue
        path = os.path.join(state_dir, name)
        try:
            st = os.lstat(path)
            if stat.S_ISREG(st.st_mode) and now - st.st_mtime > STALE_TMP_SECONDS:
                os.unlink(path)
        except OSError:
            pass


def _record(msg: turns.Message, text: str) -> dict:
    return {
        "seq": msg.seq,
        "id": msg.event_id,
        "parentId": msg.parent_id,
        "role": msg.role,
        "ts": msg.ts,
        "text": text,
        "tools": list(msg.tools),
    }


def run_infer(ctx: Context, *, clock=time.monotonic) -> dict:
    """Read new turns from the store into the redacted turn cache.

    Returns the counters infer-status.json records. The first run (no
    cursors.json) only baselines every listed session at its current max
    seq, so history from before install is never read. A session first
    listed after the baseline starts at -1, so its first turn is kept.
    A session whose store updated_at has not moved is not read at all,
    which keeps quiet sessions off a slow SSHFS mount.
    """
    began = clock()
    budget = ctx.budget_seconds
    soft_deadline = began + max(budget - SOFT_MARGIN_SECONDS, budget / 2)
    counters = {
        "sessionsSeen": 0,
        "sessionsRead": 0,
        "sessionsSkippedUnchanged": 0,
        "sessionsDeferred": 0,
        "baselined": 0,
        "turnsCached": 0,
        "redactionOmitted": 0,
        "eventsSkipped": 0,
        "storeFailures": 0,
        "compactedUnread": 0,
    }
    _sweep_stale_tmp(ctx.state_dir, time.time())
    client = StoreClient(ctx.store_script, ctx.openclaw_home)
    known = _known_values(ctx)
    cursors = Cursors.load(ctx.state_dir)
    cache = TurnCache(ctx.state_dir)

    listed = client.list_sessions()
    # None means at least one store did not answer: the listing is not
    # complete, so it can neither baseline nor show that a session is gone.
    listing_ok = listed is not None
    sessions = listed or []
    counters["sessionsSeen"] = len(sessions)

    if cursors.baseline_needed:
        # A baseline built from a failed or partial read would leave some
        # sessions without a cursor, and each of them would be read from its
        # first turn once the store answers. Wait for a complete read.
        # One query per store, not one subprocess per session, so the
        # baseline fits the stage budget on a store with many sessions.
        tops = client.max_seq_all() if listing_ok else None
        if tops is not None:
            for row in sessions:
                cursors.set(row.session_id, tops.get(row.session_id, -1), row.updated_at)
            counters["baselined"] = len(sessions)
            cursors.mark_baselined()
            cursors.save()
        counters["storeFailures"] = client.failures
        return counters

    for index, row in enumerate(sessions):
        if clock() >= soft_deadline:
            counters["sessionsDeferred"] = len(sessions) - index
            break
        sid = row.session_id
        entry = cursors.get(sid)
        if entry is not None and entry["updatedAt"] == row.updated_at:
            counters["sessionsSkippedUnchanged"] += 1
            continue
        after = entry["cursor"] if entry else -1
        events = client.events_since(sid, after)
        if events is None:
            # Keep the old cursor and updatedAt so the next tick retries.
            continue
        counters["sessionsRead"] += 1
        last = after
        batch = []
        for seq, event_json in events:
            if seq <= after:
                continue
            last = max(last, seq)
            msg = turns.extract(seq, event_json, known)
            if msg is None:
                counters["eventsSkipped"] += 1
                continue
            text, omitted = redact.sanitize_turn(msg.text, known)
            if omitted:
                counters["redactionOmitted"] += 1
            batch.append(_record(msg, text))
        counters["turnsCached"] += cache.append(sid, batch)
        counters["compactedUnread"] += client.null_event_count(sid)
        cursors.set(sid, last, row.updated_at)
        cursors.save()

    cache.prune(time.time())

    # Only a complete, non-empty listing says which sessions are gone. A
    # dropped cursor makes a returning session be read from its first turn,
    # so a cursor goes only after several such listings in a row have missed
    # its session and its cache file has aged out.
    if listing_ok and sessions:
        listed = {row.session_id for row in sessions}
        changed = False
        for sid in list(cursors.sessions):
            if sid in listed:
                changed = cursors.clear_miss(sid) or changed
                continue
            changed = cursors.bump_miss(sid) or changed
            if cursors.misses(sid) >= MISSES_BEFORE_DROP and not os.path.exists(cache.path(sid)):
                cursors.drop(sid)
                changed = True
        if changed:
            cursors.save()

    counters["storeFailures"] = client.failures
    return counters


def run_deliver(ctx: Context, phase: str) -> tuple[dict, dict]:
    """Run the deliver stage; return (counters, extra status fields).

    Phase ``pre`` refreshes the revenium CLI capability record. A probe
    failure never fails the stage: it is recorded as ``capable: false`` with
    the exception type name. The deadline still propagates, so the stage
    stops at its budget.
    """
    if phase != "pre":
        return {}, {}
    try:
        result = cli_probe.load_or_probe(ctx.state_dir)
    except DeadlineExceeded:
        raise
    except Exception as exc:  # noqa: BLE001 - fail-open by contract
        result = {"capable": False, "error": sanitize_token(type(exc).__name__)}
    return {}, {"cli": result}


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
