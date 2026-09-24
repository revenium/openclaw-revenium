#!/usr/bin/env bash
# Spike 011 (SPIKE-04): per-minute concurrency-soak tick.
#
# Reuses scripts/cron.sh's flock + bounded-timeout discipline (one lock, a
# bounded per-tick timeout, no unbounded wait) rather than building a new
# cron harness, per RESEARCH.md's "Concurrency Soak Design Inputs" and
# CONVENTIONS.md's "host-side, never per-tick `nemoclaw exec`" pattern.
#
# The read under test is a SINGLE `sqlite3 file:<path>?mode=ro` invocation
# with an explicit `PRAGMA busy_timeout` and NO retry, backoff, or
# sleep-and-reread wrapper around it — a silent retry would convert the
# exact failure this soak measures (SQLITE_BUSY / lock contention against a
# live writer) into an invisible stall, defeating D-04's "zero lock errors"
# bar. A lock/busy error is recorded, never swallowed.
#
# Ground truth is derived from a DIFFERENT mechanism than the read under
# test: the plan 17-04 sidecar plugin (probe-sidecar-plugin/, registering
# `llm_output`) maintains its own independent append-only completion count
# in ~/.openclaw/revenium-sidecar-capture.jsonl. Per D-04/RESEARCH.md: "the
# mechanism SPIKE-01 did NOT select can still serve as SPIKE-04's
# independent ground-truth cross-check" — deriving both counts from the same
# mechanism would make a miss self-confirming, which D-04 explicitly rejects.
#
# Env vars (all required except LOG_FILE/LOCK_FILE/TICK_TIMEOUT_SECS):
#   CELL               - "HOST-LOCAL" or "SSHFS" (soak-log.txt cell= field)
#   SQLITE_PATH         - path to openclaw-agent.sqlite for this cell
#   GROUND_TRUTH_FILE   - path to the sidecar plugin's capture .jsonl
#   LOG_FILE            - soak-log.txt path (default: alongside this script)
#   LOCK_FILE           - flock target (default: derived from CELL)
#   TICK_TIMEOUT_SECS   - bounded per-tick wall-clock cap (default: 30)
#
# Usage (one tick; invoked every minute by cron):
#   CELL=HOST-LOCAL \
#   SQLITE_PATH="$HOME/.openclaw/agents/dev/agent/openclaw-agent.sqlite" \
#   GROUND_TRUTH_FILE="$HOME/.openclaw/revenium-sidecar-capture.jsonl" \
#   LOG_FILE="$HOME/soak-log.txt" \
#   bash soak-tick.sh
set -uo pipefail

CELL="${CELL:?ERROR: CELL must be set (HOST-LOCAL or SSHFS)}"
SQLITE_PATH="${SQLITE_PATH:?ERROR: SQLITE_PATH must be set}"
GROUND_TRUTH_FILE="${GROUND_TRUTH_FILE:?ERROR: GROUND_TRUTH_FILE must be set}"
LOG_FILE="${LOG_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/soak-log.txt}"
LOCK_FILE="${LOCK_FILE:-${LOG_FILE}.${CELL}.lock}"
TICK_TIMEOUT_SECS="${TICK_TIMEOUT_SECS:-30}"

run_tick() {
  local start_ms end_ms duration_ms out err_file err_text rc completions lock_errors ground_truth load seq

  # Nanosecond epoch (plain %N, no field-width modifier — %3N is not
  # portable across `date` builds and was observed live to produce a
  # 19-digit garbage value on this host's GNU date; %N alone is clean).
  start_ns=$(date +%s%N)

  # THE READ UNDER TEST — one invocation, read-only URI, explicit busy
  # timeout, no loop/retry around it.
  err_file=$(mktemp)
  out=$(timeout "${TICK_TIMEOUT_SECS}" sqlite3 -cmd "PRAGMA busy_timeout=5000;" \
    "file:${SQLITE_PATH}?mode=ro" \
    "SELECT count(*) FROM transcript_events WHERE json_extract(event_json,'\$.message.role')='assistant';" \
    2>"${err_file}")
  rc=$?
  err_text=$(cat "${err_file}" 2>/dev/null || true)
  rm -f "${err_file}"

  end_ns=$(date +%s%N)
  duration_ms=$(( (end_ns - start_ns) / 1000000 ))

  # This sqlite3 build's -cmd batch mode echoes the PRAGMA setter's own
  # value (observed live: "5000" on its own line) ahead of the SELECT
  # result — take the LAST non-empty output line as the actual count,
  # never the first, so that echo never gets misread as the completions
  # value.
  completions=0
  last_line=$(printf '%s\n' "${out}" | tail -n1)
  if [[ ${rc} -eq 0 && "${last_line}" =~ ^[0-9]+$ ]]; then
    completions="${last_line}"
  fi

  lock_errors=0
  if [[ ${rc} -ne 0 ]] || printf '%s' "${err_text}" | grep -qiE 'busy|locked'; then
    lock_errors=1
  fi

  ground_truth=0
  if [[ -f "${GROUND_TRUTH_FILE}" ]]; then
    ground_truth=$(grep -c '"hook":"llm_output"' "${GROUND_TRUTH_FILE}" 2>/dev/null || echo 0)
  fi

  load=$(cut -d' ' -f1 /proc/loadavg 2>/dev/null || echo "n/a")

  seq=$(( $(grep -c '^tick ' "${LOG_FILE}" 2>/dev/null || echo 0) + 1 ))

  echo "tick ${seq} cell=${CELL} ts=$(date -u +%FT%TZ) completions=${completions} ground_truth=${ground_truth} lock_errors=${lock_errors} rc=${rc} duration_ms=${duration_ms} load=${load}" >> "${LOG_FILE}"
}

# flock discipline mirrors scripts/cron.sh exactly: -n so an overlapping tick
# skips rather than queues, portable mkdir-lock fallback where flock is
# absent.
if command -v flock &>/dev/null; then
  (
    flock -n 9 || exit 0
    run_tick
  ) 9>"${LOCK_FILE}"
else
  LOCK_DIR="${LOCK_FILE}.d"
  if [[ -d "${LOCK_DIR}" ]] && [[ -n "$(find "${LOCK_DIR}" -prune -mmin +10 2>/dev/null)" ]]; then
    rmdir "${LOCK_DIR}" 2>/dev/null || true
  fi
  if mkdir "${LOCK_DIR}" 2>/dev/null; then
    trap 'rmdir "${LOCK_DIR}" 2>/dev/null || true' EXIT
    run_tick
  else
    exit 0
  fi
fi
