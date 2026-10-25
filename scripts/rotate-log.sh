#!/usr/bin/env bash
# =============================================================================
# rotate-log.sh — size-capped single rotation for the metering logs.
#
# SOURCED (not executed) by scripts/cron.sh and scripts/nemoclaw-cron-tick.sh.
# The cron appends to these logs every tick (every minute by default), so
# without a cap they grow for the life of the install.
#
# Usage:
#   . "${SKILL_DIR}/scripts/rotate-log.sh"
#   rotate_log_if_large "${HOME}/.openclaw/revenium-metering.log"
# =============================================================================

# 5 MiB live + 5 MiB in .1 bounds each log at ~10 MiB.
ROTATE_LOG_MAX_BYTES="${ROTATE_LOG_MAX_BYTES:-5242880}"

# rotate_log_if_large <file> — once <file> reaches ROTATE_LOG_MAX_BYTES, move it
# to <file>.1 (replacing any older .1). A writer still holding the old file open
# (cron's own `>>` redirect for this tick) keeps appending to .1; the next tick
# opens a fresh file. Never fails the caller.
rotate_log_if_large() {
  local file="$1" size
  [[ -f "${file}" ]] || return 0
  size=$(wc -c < "${file}" 2>/dev/null | tr -d ' ') || return 0
  [[ "${size}" =~ ^[0-9]+$ ]] || return 0
  if (( size >= ROTATE_LOG_MAX_BYTES )); then
    mv -f "${file}" "${file}.1" 2>/dev/null || true
  fi
  return 0
}
