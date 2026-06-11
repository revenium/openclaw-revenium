#!/usr/bin/env bash
# =============================================================================
# common.sh — Shared helpers for the OpenClaw Revenium skill.
#
# SOURCED (not executed). Defines path constants and helper functions used by
# guardrail-check.sh, setup-guardrails.sh, and any other skill scripts.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${SCRIPT_DIR}/common.sh"
# =============================================================================
# NOTE: No `set -e` here — this is a sourced library. Callers that set -e will
# keep it. Adding -e here would cause unexpected exits in the caller's context
# on any sub-expression that evaluates to non-zero.
set -uo pipefail

# ---------------------------------------------------------------------------
# OPENCLAW_HOME discovery — multi-candidate probe.
# Honors OPENCLAW_HOME override from the environment (e.g., sandbox where
# $HOME != host home). Falls back to the first candidate whose agents/
# directory exists, or ${HOME}/.openclaw if none found.
# ---------------------------------------------------------------------------
if [[ -z "${OPENCLAW_HOME:-}" ]]; then
  _oc_home=""
  for _candidate in "${HOME}/.openclaw" "/home/ubuntu/.openclaw"; do
    if [[ -d "${_candidate}/agents" ]]; then
      _oc_home="${_candidate}"
      break
    fi
  done
  OPENCLAW_HOME="${_oc_home:-${HOME}/.openclaw}"
  unset _oc_home _candidate
fi

# Sandbox normalization (NemoClaw/OpenShell). OpenClaw running inside an OpenShell
# sandbox sets OPENCLAW_HOME to the parent (e.g. /sandbox) with the real data dir
# at $OPENCLAW_HOME/.openclaw, whereas standalone OpenClaw points OPENCLAW_HOME at
# the .openclaw dir itself. If the configured OPENCLAW_HOME does not directly hold
# the openclaw layout (no agents/) but a nested .openclaw/ does, descend into it so
# STATE_DIR / SESSIONS_DIR / ledgers resolve correctly in-sandbox. This is a no-op
# for standalone (its OPENCLAW_HOME already contains agents/).
if [[ ! -d "${OPENCLAW_HOME}/agents" && -d "${OPENCLAW_HOME}/.openclaw/agents" ]]; then
  OPENCLAW_HOME="${OPENCLAW_HOME}/.openclaw"
fi

# ---------------------------------------------------------------------------
# Path constants (OpenClaw collapsed model: STATE_DIR == skill directory).
# Unlike Hermes which separates ~/.hermes/skills/revenium/ from
# ~/.hermes/state/revenium/, OpenClaw collapses both into
# ~/.openclaw/skills/revenium/.
# ---------------------------------------------------------------------------
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${OPENCLAW_HOME}/skills/revenium"
CONFIG_FILE="${STATE_DIR}/config.json"
GUARDRAIL_STATUS_FILE="${STATE_DIR}/guardrail-status.json"
LOCK_FILE="${STATE_DIR}/revenium-metering.lock"
LOG_FILE="${STATE_DIR}/revenium-metering.log"
RULES_LOCK_FILE="${STATE_DIR}/rules.lock"

# Phase 4 path constants (METER-01 / D-07).
# TAXONOMY_FILE: 8-label task vocabulary for write-marker.sh + setup-guardrails.sh.
# JOB_TAXONOMY_FILE: 11-label job vocabulary for write-job-marker.sh (v1.1 / JOBDEC-01).
# MARKERS_DIR: per-session marker JSONL files (appended by write-marker.sh).
# SESSIONS_DIR: OpenClaw agent session JSONL directory (read by resolver + report.sh).
TAXONOMY_FILE="${STATE_DIR}/task-taxonomy.json"
JOB_TAXONOMY_FILE="${STATE_DIR}/job-taxonomy.json"
MARKERS_DIR="${STATE_DIR}/markers"
SESSIONS_DIR="${OPENCLAW_HOME}/agents/main/sessions"

# Phase 9 path constants (GRDEV-01..05).
# GUARDRAIL_LEDGER_FILE: append-only dedup ledger for guardrail event metering.
# JOBS_LEDGER_FILE: read-only consumer from guardrail-check.sh for open-job attribution.
#   Identical path to report.sh's JOBS_LEDGER_FILE (must stay in sync).
GUARDRAIL_LEDGER_FILE="${OPENCLAW_HOME}/revenium-guardrail.ledger"
JOBS_LEDGER_FILE="${REVENIUM_JOBS_LEDGER_FILE:-${OPENCLAW_HOME}/revenium-jobs.ledger}"

# Phase 10 path constants (TOOLEV-01/04).
# TOOL_REGISTRY_LEDGER_FILE: append-only dedup ledger for tool registration.
#   Key format: TOOL:<tool_id>:<unix_ts>
# TOOL_EVENTS_LEDGER_FILE: append-only dedup ledger for per-invocation tool-events.
#   Key format: TOOLEV:<toolcall_id>
#   Kept separate from LEDGER_FILE (revenium-reported.ledger) to avoid coupling
#   with the CR-02 offset-advance gate in report.sh (RESEARCH.md Open Question 2).
TOOL_REGISTRY_LEDGER_FILE="${OPENCLAW_HOME}/revenium-tools.ledger"
TOOL_EVENTS_LEDGER_FILE="${OPENCLAW_HOME}/revenium-tool-events.ledger"

# Agent name constant: defaults to "OpenClaw". Override via env to scope
# guardrail rule filters when multiple distinct installs share one API key.
# Used for --filter AGENT:IS:${REVENIUM_AGENT_NAME} in setup-guardrails.sh
# and for --agent in report.sh (Phase 4 concern; constant established here).
REVENIUM_AGENT_NAME="${REVENIUM_AGENT_NAME:-OpenClaw}"

# D-07: metering/filter scheme. report.sh ships --agent "${REVENIUM_AGENT_PREFIX}${root_sid}";
# base budget rule filters AGENT:STARTS_WITH:${REVENIUM_AGENT_PREFIX}. Supersedes the static
# AGENT:IS:${REVENIUM_AGENT_NAME} model (Phase 3 D-23) for filtering/rollup.
REVENIUM_AGENT_PREFIX="${REVENIUM_AGENT_PREFIX:-openclaw-}"

# Ensure STATE_DIR exists (idempotent).
mkdir -p "${STATE_DIR}"

# ---------------------------------------------------------------------------
# ensure_path — extend PATH to include common package manager locations.
# Cron runs with a minimal PATH; this adds brew/system bin dirs so revenium
# and openclaw CLIs are found without hardcoding absolute paths.
# ---------------------------------------------------------------------------
ensure_path() {
  local brew_prefix=""
  if command -v brew >/dev/null 2>&1; then
    brew_prefix="$(brew --prefix 2>/dev/null || true)"
  fi
  for p in \
    "${brew_prefix:+${brew_prefix}/bin}" \
    "${brew_prefix:+${brew_prefix}/sbin}" \
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
  # Always succeed: the loop's last iteration is `[[ -d ... ]] && export`, which
  # returns non-zero when the final candidate dir is absent (e.g. ~/.local/bin on
  # a clean host). Without this, a `set -e` caller (guardrail-check.sh,
  # setup-guardrails.sh) aborts the moment ensure_path returns — before polling,
  # logging, or rule creation. Pin the return code so PATH-extension is best-effort.
  return 0
}

# ---------------------------------------------------------------------------
# log — single-source log writer.
# Always appends one line to LOG_FILE; mirrors to stderr only when the caller
# is interactive (TTY detected via `[ -t 2 ]`).
#
# Why not `tee -a "${LOG_FILE}" >&2`? Cron invokes the pipeline with
# `>> ${LOG_FILE} 2>&1`, which captures stderr back into LOG_FILE. The
# tee+stderr combo therefore writes every line to LOG_FILE twice under cron.
# The TTY guard preserves the interactive UX while keeping cron's log clean.
#
# Usage: log "LEVEL" "message ..."
# ---------------------------------------------------------------------------
log() {
  local level="$1"; shift
  local line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${level}] [revenium] $*"
  mkdir -p "${STATE_DIR}"
  printf '%s\n' "${line}" >> "${LOG_FILE}"
  if [[ -t 2 ]]; then
    printf '%s\n' "${line}" >&2
  fi
}

info()  { log "INFO " "$@"; }
warn()  { log "WARN " "$@"; }
error() { log "ERROR" "$@"; }

# ---------------------------------------------------------------------------
# has_guardrails_cli — two-subcommand probe for revenium guardrails CLI.
# Returns 0 if both subcommand families exist, non-zero otherwise.
# Callers MUST warn + exit 0 on failure; this helper never logs or exits.
# Verified against revenium 1.1.2 on 2026-05-31.
# ---------------------------------------------------------------------------
has_guardrails_cli() {
  revenium guardrails budget-rules --help >/dev/null 2>&1 && \
  revenium guardrails enforcement-events --help >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# get_root_session_id — bash wrapper around get-root-session-id.py sidecar.
# Resolves a child session id to its root via JSONL childSessionKey walk.
# Fail-open (D-05/D-06): if python3 is absent or the sidecar fails, prints
# the input sid and returns 0 (never blocks the caller).
#
# Source: adapted from ../hermes-revenium/skills/revenium/scripts/common.sh:96-106
#
# Usage:
#   root_sid=$(get_root_session_id "${session_id}")
# ---------------------------------------------------------------------------
get_root_session_id() {
  local sid="${1:-}"
  [[ -z "${sid}" ]] && return 0
  if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "${sid}"; return 0
  fi
  OPENCLAW_HOME="${OPENCLAW_HOME}" python3 "${SKILL_DIR}/scripts/get-root-session-id.py" "${sid}" 2>/dev/null \
    || printf '%s\n' "${sid}"
}
