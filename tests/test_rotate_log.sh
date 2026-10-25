#!/usr/bin/env bash
# =============================================================================
# test_rotate_log.sh — Hermetic unit suite for scripts/rotate-log.sh, plus a
# check that cron.sh rotates both standalone metering logs on a tick.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROTATE_SH="${REPO_ROOT}/scripts/rotate-log.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-rotate-log.XXXXXX")
trap 'rm -rf "${TMP}"' EXIT

# shellcheck source=/dev/null
. "${ROTATE_SH}"
ROTATE_LOG_MAX_BYTES=100

echo ""
echo "--- GROUP RL-A: rotate_log_if_large ---"

LOG="${TMP}/a.log"
head -c 50 /dev/zero > "${LOG}"
rotate_log_if_large "${LOG}"
if [[ -f "${LOG}" && ! -e "${LOG}.1" ]]; then
  pass "RL-A: log under the cap is left in place"
else
  fail "RL-A: log under the cap was rotated"
fi

head -c 150 /dev/zero > "${LOG}"
echo "older" > "${LOG}.1"
rotate_log_if_large "${LOG}"
if [[ ! -e "${LOG}" && "$(wc -c < "${LOG}.1" | tr -d ' ')" == "150" ]]; then
  pass "RL-A: log at or over the cap moves to .1, replacing the older .1"
else
  fail "RL-A: oversized log was not rotated into .1"
fi

if rotate_log_if_large "${TMP}/missing.log"; then
  pass "RL-A: missing log is a no-op and returns 0"
else
  fail "RL-A: missing log returned non-zero"
fi

LOG_OPEN="${TMP}/open.log"
head -c 150 /dev/zero > "${LOG_OPEN}"
exec 7>>"${LOG_OPEN}"
rotate_log_if_large "${LOG_OPEN}"
printf 'held-writer-line\n' >&7
exec 7>&-
printf 'next-tick-line\n' >> "${LOG_OPEN}"
if grep -q 'held-writer-line' "${LOG_OPEN}.1" && ! grep -q 'held-writer-line' "${LOG_OPEN}" \
   && grep -q 'next-tick-line' "${LOG_OPEN}" && ! grep -q 'next-tick-line' "${LOG_OPEN}.1"; then
  pass "RL-A: a writer holding the log open keeps writing to .1; the next open writes the live file"
else
  fail "RL-A: output was lost or misplaced across a rotation with an open writer"
fi

echo ""
echo "--- GROUP RL-B: cron.sh rotates both standalone logs ---"

HOME_B="${TMP}/home"
OC="${HOME_B}/.openclaw"
mkdir -p "${OC}/agents" "${OC}/skills/revenium"
head -c 200 /dev/zero > "${OC}/revenium-metering.log"
head -c 200 /dev/zero > "${OC}/skills/revenium/revenium-metering.log"
HOME="${HOME_B}" OPENCLAW_HOME="${OC}" ROTATE_LOG_MAX_BYTES=100 PATH="/usr/bin:/bin" \
  bash "${REPO_ROOT}/scripts/cron.sh" >/dev/null 2>&1 || true
if [[ -f "${OC}/revenium-metering.log.1" && -f "${OC}/skills/revenium/revenium-metering.log.1" ]]; then
  pass "RL-B: cron tick rotated the cron-output log and the skill warn log"
else
  fail "RL-B: cron tick did not rotate both metering logs"
fi

HOME_C="${TMP}/home-c"
OC_C="${TMP}/elsewhere/.openclaw"
mkdir -p "${HOME_C}/.openclaw" "${OC_C}/agents" "${OC_C}/skills/revenium"
head -c 200 /dev/zero > "${HOME_C}/.openclaw/revenium-metering.log"
HOME="${HOME_C}" OPENCLAW_HOME="${OC_C}" ROTATE_LOG_MAX_BYTES=100 PATH="/usr/bin:/bin" \
  bash "${REPO_ROOT}/scripts/cron.sh" >/dev/null 2>&1 || true
if [[ -f "${HOME_C}/.openclaw/revenium-metering.log.1" ]]; then
  pass "RL-B: with OPENCLAW_HOME overridden, the installed cron's redirect target still rotates"
else
  fail "RL-B: OPENCLAW_HOME override left \${HOME}/.openclaw/revenium-metering.log unrotated"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
