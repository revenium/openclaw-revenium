#!/usr/bin/env bash
# =============================================================================
# Revenium Cron Runner
# Called by crontab every minute by default (interval set in install-cron.sh).
# Sources revenium config before running.
# =============================================================================

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Allow OPENCLAW_HOME override via env (e.g. sandbox where $HOME != host home).
OPENCLAW_HOME="${OPENCLAW_HOME:-}"
if [[ -z "${OPENCLAW_HOME}" ]]; then
  for candidate in "${HOME}/.openclaw" "/home/ubuntu/.openclaw"; do
    if [[ -d "${candidate}/agents" ]]; then
      OPENCLAW_HOME="${candidate}"
      break
    fi
  done
  OPENCLAW_HOME="${OPENCLAW_HOME:-${HOME}/.openclaw}"
fi

# Source environment from revenium.env if it exists
ENV_FILE="${OPENCLAW_HOME}/revenium.env"
if [[ -f "${ENV_FILE}" ]]; then
  set -o allexport
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +o allexport
fi

# Ensure revenium CLI is on PATH.
# Cron runs with a minimal PATH, so we add common package manager locations.
# Try dynamic detection first (brew --prefix), fall back to well-known paths.
BREW_PREFIX=""
if command -v brew &>/dev/null; then
  BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
fi

for p in \
  "${BREW_PREFIX:+${BREW_PREFIX}/bin}" \
  "${BREW_PREFIX:+${BREW_PREFIX}/sbin}" \
  /home/linuxbrew/.linuxbrew/bin \
  /home/linuxbrew/.linuxbrew/sbin \
  /opt/homebrew/bin \
  /opt/homebrew/sbin \
  /usr/local/bin \
  /usr/bin \
  "${HOME}/go/bin" \
  "${HOME}/.local/bin"; do
  [[ -n "${p}" && -d "${p}" ]] && export PATH="${p}:${PATH}"
done

# Run report.sh with a wall-clock cap so a hung reporter can never block
# the halt check. Prefers GNU `timeout` (Linux default, macOS via coreutils
# as `gtimeout`); degrades to an unbounded run if neither is available.
run_report() {
  if command -v timeout &>/dev/null; then
    timeout 120 bash "${SKILL_DIR}/scripts/report.sh" "$@"
  elif command -v gtimeout &>/dev/null; then
    gtimeout 120 bash "${SKILL_DIR}/scripts/report.sh" "$@"
  else
    bash "${SKILL_DIR}/scripts/report.sh" "$@"
  fi
}

# Run the metering + guardrail-check pass under a mutual-exclusion lock so two
# overlapping cron ticks can't race on the offsets/status files and double-meter.
# This matters at short intervals: the cron can run as often as every minute,
# while report.sh is allowed up to 120s, so a run may still be active when the
# next tick fires. Prefer `flock` (util-linux; auto-releases on process death);
# fall back to a portable atomic `mkdir` lock where flock is absent (e.g. macOS),
# mirroring the timeout/gtimeout degradation above.
# D-04: markers directory for per-session marker JSONL files.
# Inlined rather than sourcing common.sh to keep cron.sh self-contained.
# MARKERS_DIR lives under the skill state directory (OpenClaw collapsed model).
MARKERS_DIR="${OPENCLAW_HOME}/skills/revenium/markers"

# D-04: prune_markers — delete marker files older than ~7 days.
# Fail-open: prune failure MUST NOT block the tick (T-04-17).
# Uses find -mtime +7 (BSD/GNU portable, mirrors -mmin usage at line 88).
# Runs AFTER report.sh + guardrail-check.sh so it cannot starve enforcement.
prune_markers() {
  find "${MARKERS_DIR}" -name '*.jsonl' -mtime +7 -delete 2>/dev/null
}

LOCK_FILE="${OPENCLAW_HOME:-${HOME}/.openclaw}/revenium-metering.lock"
if command -v flock &>/dev/null; then
  (
    flock -n 9 || exit 0
    run_report "$@" || true
    bash "${SKILL_DIR}/scripts/guardrail-check.sh" || true
    prune_markers || true
  ) 9>"${LOCK_FILE}"
else
  # No flock (e.g. macOS): atomic mkdir lock. `mkdir` fails if the dir exists,
  # giving us flock -n semantics. A trap releases it on normal exit; reclaim a
  # stale lock left by a killed run (>10 min old) so the cron can't wedge
  # permanently. `find -mmin` is portable across macOS (BSD) and GNU find.
  LOCK_DIR="${LOCK_FILE}.d"
  if [[ -d "${LOCK_DIR}" ]] && [[ -n "$(find "${LOCK_DIR}" -prune -mmin +10 2>/dev/null)" ]]; then
    rmdir "${LOCK_DIR}" 2>/dev/null || true
  fi
  if mkdir "${LOCK_DIR}" 2>/dev/null; then
    trap 'rmdir "${LOCK_DIR}" 2>/dev/null || true' EXIT
    run_report "$@" || true
    bash "${SKILL_DIR}/scripts/guardrail-check.sh" || true
    prune_markers || true
  else
    # Another run holds the lock — skip this tick (matches flock -n behavior).
    exit 0
  fi
fi
