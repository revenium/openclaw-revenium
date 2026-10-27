#!/usr/bin/env bash
# =============================================================================
# economics.sh — Cron entry point for the agent-economics sidecar.
#
# EXECUTED (not sourced). scripts/cron.sh runs `deliver` inside the metering
# lock (before report.sh and after guardrail-check.sh) and launches `infer`
# detached after the lock. This shim checks paths and the runtime, takes the
# infer lock, runs the sidecar under a wall-clock bound, and publishes a
# scalar-only heartbeat the agent can read. It never downloads or installs
# anything: provisioning happens only in post-install.
#
# Usage:
#   economics.sh infer --openclaw-home DIR
#   economics.sh deliver --phase pre|post --openclaw-home DIR
#
# Environment (cron.sh passes only these, through `env -i`):
#   HOME, PATH, LANG, REVENIUM_SIDECAR_HOME, REVENIUM_ECON_STATE_DIR,
#   XDG_STATE_HOME, REVENIUM_TICK_INTERVAL_MINUTES
#   REVENIUM_ECON_INFER_BUDGET_SECONDS (tests only; integer 1-600)
#
# Files:
#   <state>/heartbeat.state, <state>/revenium-economics.log,
#   <state>/infer.lock or <state>/infer.lock.d, <state>/infer.started,
#   <state>/OPENCLAW_HOME (standalone only),
#   ${OPENCLAW_HOME}/skills/revenium/economics-status.json (agent-visible)
#
# Exit codes: always 0. A sidecar problem becomes a heartbeat reason, never a
#   failed tick.
#
# SECURITY: the state dir must be owned by the user, mode 0700 and outside
#   OPENCLAW_HOME (which the agent can read and, on NemoClaw, write); anything
#   else is refused before a byte is written inside it. Runtime files are
#   parsed with econ_read_kv, never sourced. Python runs from an absolute
#   interpreter path with a scrubbed environment and `-E -s -B`. The agent
#   heartbeat carries only enum-validated reasons and regex-validated
#   timestamps.
# =============================================================================
# NOTE: `set -uo pipefail` without `-e`: every failure has to be turned into a
# heartbeat reason before exiting 0, and -e would exit early on the first
# non-zero status instead.
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# The clone this script lives in, never ${OPENCLAW_HOME}/skills/revenium: on
# NemoClaw that path is the agent-writable SSHFS mount.
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"

log() {
  local level="$1"; shift
  printf '%s\n' "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${level}] [revenium-economics] $*"
}
# bounded-run.sh calls warn() for its portable-watchdog notice; define it first
# so the notice lands in the sidecar log.
warn() { log "WARN " "$@"; }

# shellcheck source=bounded-run.sh
. "${SCRIPT_DIR}/bounded-run.sh"
# shellcheck source=economics-paths.sh
. "${SCRIPT_DIR}/economics-paths.sh"
# shellcheck source=rotate-log.sh
. "${SCRIPT_DIR}/rotate-log.sh"

STAGE=""
PHASE=""
OC_HOME=""
STATE_DIR=""
RUNTIME_DIR=""
ECON_ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

# ---------------------------------------------------------------------------
# econ_write_agent_heartbeat <reason> <detail> <updated_at> <outage_id>
# Write ${OPENCLAW_HOME}/skills/revenium/economics-status.json from validated
# scalars only. Skipped when the skill dir does not exist (not installed).
# ---------------------------------------------------------------------------
econ_write_agent_heartbeat() {
  local reason="$1" detail="$2" updated="$3" outage="$4"
  local dir="${OC_HOME}/skills/revenium" state="off" max_age="" interval tmp
  [[ -d "${dir}" ]] || return 0
  econ_valid_enum "${reason}" "${ECON_REASONS}" || return 0
  econ_valid_enum "${detail}" "${ECON_PROVISION_REASONS}" || detail=""
  [[ "${updated}" =~ ${ECON_ISO_RE} ]] || return 0
  if [[ -n "${outage}" && "${outage}" != "unsafe_state_dir" ]] && ! [[ "${outage}" =~ ${ECON_ISO_RE} ]]; then
    outage=""
  fi
  [[ "${reason}" == "ok" ]] && state="ok"
  interval="${REVENIUM_TICK_INTERVAL_MINUTES:-}"
  if [[ "${interval}" =~ ^[0-9]{1,2}$ ]] && (( 10#${interval} >= 1 && 10#${interval} <= 59 )); then
    max_age=",\"_maxAgeSeconds\":$(( 10#${interval} * 180 ))"
  fi
  tmp="$(mktemp "${dir}/.economics-status.XXXXXX" 2>/dev/null)" || return 0
  if printf '{"state":"%s","reason":"%s","detail":"%s","updatedAt":"%s","outageId":"%s"%s}\n' \
      "${state}" "${reason}" "${detail}" "${updated}" "${outage}" "${max_age}" > "${tmp}" \
    && chmod 644 "${tmp}" \
    && mv -f "${tmp}" "${dir}/${ECON_HEARTBEAT_NAME}"; then
    return 0
  fi
  rm -f "${tmp}" 2>/dev/null
  return 0
}

# ---------------------------------------------------------------------------
# econ_record_infer_result <reason> <detail>
# Track outages in <state>/heartbeat.state, then publish the agent heartbeat.
# outage_id is the last healthy time: set on the first non-ok result after a
# healthy run, kept through the outage, cleared by the next healthy run. The
# agent keys its one-shot notice on it, so each outage gets a new id and a
# never-healthy install never gets one.
# ---------------------------------------------------------------------------
econ_record_infer_result() {
  local reason="$1" detail="${2:-}" hb="${STATE_DIR}/heartbeat.state"
  local now prev_reason last_healthy outage
  now="$(econ_now_iso)"
  prev_reason="$(econ_read_kv "${hb}" reason)"
  last_healthy="$(econ_read_kv "${hb}" last_healthy_at)"
  outage="$(econ_read_kv "${hb}" outage_id)"
  [[ "${last_healthy}" =~ ${ECON_ISO_RE} ]] || last_healthy=""
  [[ "${outage}" =~ ${ECON_ISO_RE} ]] || outage=""
  econ_valid_enum "${detail}" "${ECON_PROVISION_REASONS}" || detail=""

  if [[ "${reason}" == "ok" ]]; then
    last_healthy="${now}"
    outage=""
  elif [[ -z "${outage}" && -n "${last_healthy}" ]]; then
    outage="${last_healthy}"
  fi

  if [[ "${reason}" != "${prev_reason}" ]]; then
    log "INFO " "infer status: ${reason}${detail:+ (${detail})}"
  fi
  econ_write_kv "${hb}" "reason=${reason}" "detail=${detail}" "updated_at=${now}" \
    "last_healthy_at=${last_healthy}" "outage_id=${outage}" \
    || log "WARN " "could not write ${hb}"
  econ_write_agent_heartbeat "${reason}" "${detail}" "${now}" "${outage}"
}

econ_reason_for_rc() {
  case "$1" in
    0)   printf 'ok\n' ;;
    3)   printf 'runtime_missing\n' ;;
    4)   printf 'unsafe_state_dir\n' ;;
    124) printf 'timeout\n' ;;
    *)   printf 'crashing\n' ;;
  esac
}

# ---------------------------------------------------------------------------
# econ_runtime_reason — print the reason the runtime cannot run, then its
# detail on a second line; print nothing when it is runnable.
# ---------------------------------------------------------------------------
econ_runtime_reason() {
  local detail
  if [[ "${RUNTIME_DIR}" != /* ]]; then
    printf 'unsafe_runtime_dir\n\n'
    return 0
  fi
  if [[ -e "${RUNTIME_DIR}" ]]; then
    if ! econ_dir_not_shared_writable "${RUNTIME_DIR}" || econ_is_under "${RUNTIME_DIR}" "${OC_HOME}"; then
      printf 'unsafe_runtime_dir\n\n'
      return 0
    fi
  fi
  if [[ ! -f "${RUNTIME_DIR}/INSTALLED" ]]; then
    detail="$(econ_read_kv "${RUNTIME_DIR}/PROVISION_STATUS" reason)"
    econ_valid_enum "${detail}" "${ECON_PROVISION_REASONS}" || detail=""
    printf 'not_provisioned\n%s\n' "${detail}"
    return 0
  fi
  if [[ ! -f "${RUNTIME_DIR}/venv/bin/python" || ! -x "${RUNTIME_DIR}/venv/bin/python" ]]; then
    printf 'runtime_missing\n\n'
  fi
  return 0
}

# ---------------------------------------------------------------------------
# econ_run_python <budget> <stage> [args...] — run the sidecar under
# bounded_run with a scrubbed environment. Python gets the budget minus five
# seconds as its own deadline so it can stop cleanly before the hard bound.
# fd 8 (the infer lock) is closed so an orphaned child cannot hold it.
# ---------------------------------------------------------------------------
econ_run_python() {
  local budget="$1" inner
  shift
  inner=$(( budget - 5 ))
  (( inner < 1 )) && inner=1
  bounded_run "${budget}" /usr/bin/env -i HOME="${HOME}" PATH="${PATH}" LANG=C \
    "${RUNTIME_DIR}/venv/bin/python" -E -s -B -X utf8 "${SKILL_DIR}/sidecar/run.py" "$@" \
    --state-dir "${STATE_DIR}" --openclaw-home "${OC_HOME}" --skill-dir "${SKILL_DIR}" \
    --runtime-dir "${RUNTIME_DIR}" --budget-seconds "${inner}" </dev/null 8>&-
}

econ_infer() {
  local rt rt_reason rt_detail budget age rc=0 reason
  rt="$(econ_runtime_reason)"
  rt_reason="${rt%%$'\n'*}"
  rt_detail=""
  [[ "${rt}" == *$'\n'* ]] && rt_detail="${rt#*$'\n'}"
  if [[ -n "${rt_reason}" ]]; then
    econ_record_infer_result "${rt_reason}" "${rt_detail}"
    return 0
  fi

  budget="${REVENIUM_ECON_INFER_BUDGET_SECONDS:-}"
  if ! [[ "${budget}" =~ ^[0-9]{1,3}$ ]] || (( 10#${budget} < 1 || 10#${budget} > 600 )); then
    budget="${ECON_INFER_BUDGET_DEFAULT}"
  fi
  budget=$(( 10#${budget} ))

  if ! econ_lock_acquire "${STATE_DIR}" "${budget}"; then
    age="$(econ_lock_holder_age "${STATE_DIR}")"
    if [[ "${age}" =~ ^[0-9]+$ ]] && (( age > budget + ECON_LOCK_GRACE_SECONDS )); then
      log "WARN " "infer lock held for ${age}s (budget ${budget}s)"
      econ_record_infer_result stuck ""
    fi
    return 0
  fi
  trap 'econ_lock_release "${STATE_DIR}"' EXIT

  econ_run_python "${budget}" infer || rc=$?
  reason="$(econ_reason_for_rc "${rc}")"
  [[ "${rc}" -eq 0 ]] || log "WARN " "infer exited rc=${rc} (${reason})"
  econ_record_infer_result "${reason}" ""
  return 0
}

econ_deliver() {
  local rt budget rc=0
  rt="$(econ_runtime_reason)"
  [[ -z "${rt}" ]] || return 0
  if [[ "${PHASE}" == "pre" ]]; then
    budget="${ECON_DELIVER_PRE_BUDGET}"
  else
    budget="${ECON_DELIVER_POST_BUDGET}"
  fi
  econ_run_python "${budget}" deliver --phase "${PHASE}" || rc=$?
  if [[ "${rc}" -ne 0 ]]; then
    log "WARN " "deliver ${PHASE} exited rc=${rc} ($(econ_reason_for_rc "${rc}"))"
  fi
  return 0
}

econ_main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      infer|deliver) STAGE="$1"; shift ;;
      --phase)         PHASE="${2:-}"; shift 2 || shift ;;
      --openclaw-home) OC_HOME="${2:-}"; shift 2 || shift ;;
      *)
        printf '%s\n' "economics.sh: ignoring run, unknown argument: ${1:0:64}" >&2
        return 0
        ;;
    esac
  done
  if [[ -z "${STAGE}" ]]; then
    printf '%s\n' "economics.sh: ignoring run, no stage (infer|deliver)" >&2
    return 0
  fi
  if [[ "${STAGE}" == "deliver" && "${PHASE}" != "pre" && "${PHASE}" != "post" ]]; then
    printf '%s\n' "economics.sh: ignoring deliver, --phase must be pre or post" >&2
    return 0
  fi
  [[ -n "${OC_HOME}" && -d "${OC_HOME}" ]] || return 0
  OC_HOME="$(econ_real_dir "${OC_HOME}")" || return 0

  STATE_DIR="$(econ_resolve_state_dir "${OC_HOME}")"
  # Check the location before creating anything, then check the created dir
  # again: the first check stops a mkdir inside OPENCLAW_HOME, the second
  # catches a pre-existing dir that is shared, foreign-owned or a symlink.
  if econ_is_under "${STATE_DIR}" "${OC_HOME}" \
    || ! econ_ensure_private_dir "${STATE_DIR}" \
    || ! econ_state_dir_is_safe "${STATE_DIR}" "${OC_HOME}"; then
    printf '%s\n' "economics.sh: refusing unsafe sidecar state dir (must be owned, mode 0700, outside OPENCLAW_HOME)" >&2
    if [[ "${STAGE}" == "infer" ]]; then
      econ_write_agent_heartbeat unsafe_state_dir "" "$(econ_now_iso)" unsafe_state_dir
    fi
    return 0
  fi
  STATE_DIR="$(econ_real_dir "${STATE_DIR}")" || return 0

  rotate_log_if_large "${STATE_DIR}/revenium-economics.log"
  exec >>"${STATE_DIR}/revenium-economics.log" 2>&1
  if [[ -z "${REVENIUM_ECON_STATE_DIR:-}" && ! -f "${STATE_DIR}/OPENCLAW_HOME" ]]; then
    printf '%s\n' "${OC_HOME}" > "${STATE_DIR}/OPENCLAW_HOME" 2>/dev/null || true
  fi

  RUNTIME_DIR="$(econ_runtime_dir)"
  if [[ "${STAGE}" == "infer" ]]; then
    econ_infer
  else
    econ_deliver
  fi
  return 0
}

# Run in a subshell so that even an unexpected `set -u` abort inside it still
# leaves this script exiting 0; the EXIT trap that releases the lock fires
# when the subshell ends.
( econ_main "$@" )
exit 0
