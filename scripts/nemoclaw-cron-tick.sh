#!/usr/bin/env bash
# =============================================================================
# Revenium NemoClaw Cron Tick
# Host-side metering loop for the NemoClaw/OpenShell install path.
#
# This wrapper checks SSHFS mount health, self-heals a dropped mount via
# `nemoclaw <sandbox> share mount`, sources host-side auth (D-02), then
# delegates entirely to the unmodified cron.sh with OPENCLAW_HOME pointed at
# the mount (D-01, SC1).
#
# On any mount failure: log the error + exit 3. Write nothing to guardrail-
# status.json (D-05, SC3). cron.sh/guardrail-check.sh remain unmodified (SC4).
# SC2: no per-tick subcommand-exec calls — SSHFS file I/O only.
# =============================================================================

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# Required: sandbox name exported by the crontab line.
# ---------------------------------------------------------------------------
SANDBOX_NAME="${REVENIUM_SANDBOX_NAME:?ERROR: REVENIUM_SANDBOX_NAME must be set}"

# ---------------------------------------------------------------------------
# Paths.
# ---------------------------------------------------------------------------
MNT="${HOME}/sbx-openclaw-${SANDBOX_NAME}"
LOG_FILE="${HOME}/.nemoclaw/revenium-nemoclaw-metering.log"
mkdir -p "${HOME}/.nemoclaw"

# ---------------------------------------------------------------------------
# Internal logging helper: ISO-8601 prefix + tag.
# ---------------------------------------------------------------------------
log() {
  echo "$(date -u +%FT%TZ) [nemoclaw-tick] $*" >> "${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Step 1: Mount-health check + self-heal (D-03, SC3, D-05).
#   Must run BEFORE auth sourcing or cron.sh delegation so a dead mount
#   never triggers a guardrail-status.json write.
# ---------------------------------------------------------------------------
# Health = in the mount table AND the mountpoint ROOT stats OK. Stat the root, not a
# subdir — a transient SSHFS subdir cache-lag must not look broken or trigger a
# teardown of a healthy mount. Only (re)mount when not healthy.
if ! { grep -qsF " ${MNT} " /proc/mounts 2>/dev/null && stat "${MNT}" >/dev/null 2>&1; }; then
  log "mount not healthy — (re)mounting: ${SANDBOX_NAME}"
  # Dead/stale (listed but root won't stat — backing SSH connection dropped) blocks
  # `share mount` with "permission denied creating the directory". Clear it first.
  if grep -qsF " ${MNT} " /proc/mounts 2>/dev/null; then
    log "clearing stale mount at ${MNT}"
    fusermount -u "${MNT}" 2>>"${LOG_FILE}" || umount -l "${MNT}" 2>>"${LOG_FILE}" || true
    sleep 1
  fi
  mkdir -p "${MNT}" 2>/dev/null || true
  # "already mounted/exists" is not a failure; verify the end state below.
  nemoclaw "${SANDBOX_NAME}" share mount /sandbox/.openclaw "${MNT}" >>"${LOG_FILE}" 2>&1 || true
  if ! { grep -qsF " ${MNT} " /proc/mounts 2>/dev/null && stat "${MNT}" >/dev/null 2>&1; }; then
    log "remount failed — skipping tick (rc=3)"
    exit 3
  fi
fi

# ---------------------------------------------------------------------------
# Step 2: Source host-side auth (D-02).
#   Use the host key from ~/.nemoclaw/revenium-host.env — NOT the mount's
#   revenium.env which would resolve to the sandbox key under OPENCLAW_HOME.
# ---------------------------------------------------------------------------
HOST_ENV_FILE="${HOME}/.nemoclaw/revenium-host.env"
if [[ -f "${HOST_ENV_FILE}" ]]; then
  set -o allexport
  # shellcheck source=/dev/null
  source "${HOST_ENV_FILE}"
  set +o allexport
fi

# ---------------------------------------------------------------------------
# Step 3: Delegate to cron.sh (D-01, SC1, SC4).
#   Set OPENCLAW_HOME to the mount so cron.sh resolves session logs,
#   config.json, and guardrail-status.json through the SSHFS mount.
#   cron.sh runs report.sh + guardrail-check.sh and writes guardrail-status.json.
#   This wrapper writes NONE of it.
# ---------------------------------------------------------------------------
OPENCLAW_HOME="${MNT}" bash "${SKILL_DIR}/scripts/cron.sh" || {
  log "cron.sh exited non-zero (rc=$?) — check host env"
}

# ---------------------------------------------------------------------------
# Step 4: D-06 TTL hint — stamp _maxAgeSeconds into guardrail-status.json.
#   AFTER cron.sh returns; post-write best-effort (failure cannot fail the tick).
#   REVENIUM_TICK_INTERVAL_MINUTES is exported by the crontab line; default 1.
#   MAX_AGE_SECONDS = interval * 60 * 3 (3× the tick interval).
# ---------------------------------------------------------------------------
INTERVAL="${REVENIUM_TICK_INTERVAL_MINUTES:-1}"
MAX_AGE_SECONDS=$(( INTERVAL * 60 * 3 ))
python3 - <<PY || true
import json, os
p = "${MNT}/skills/revenium/guardrail-status.json"
try:
    d = json.loads(open(p).read())
    d['_maxAgeSeconds'] = ${MAX_AGE_SECONDS}
    open(p, 'w').write(json.dumps(d, indent=2) + '\n')
except Exception:
    pass
PY

# ---------------------------------------------------------------------------
# Step 5: Append history line.
# ---------------------------------------------------------------------------
log "sandbox=${SANDBOX_NAME} rc=$?"
