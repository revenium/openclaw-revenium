#!/usr/bin/env bash
# =============================================================================
# test_economics_shim.sh — Hermetic suite for scripts/economics.sh, the
# sidecar wiring in scripts/cron.sh and scripts/nemoclaw-cron-tick.sh, and the
# helpers in scripts/economics-paths.sh.
#
# Pins the fail-open contract (every run exits 0, a tick with no runtime
# publishes a not_provisioned heartbeat), the host-local state location and
# its 0700/0600 modes, and the heartbeat fields the agent reads.
#
# Every case runs with a temp HOME and a stub `revenium` on PATH, so no real
# install, runtime or Revenium API is touched.
#
# SECURITY: never eval's or string-interpolates captured output into shell
#   commands. JSON is read by python3 with the path passed as an argument.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ECON_SH="${REPO_ROOT}/scripts/economics.sh"
PATHS_SH="${REPO_ROOT}/scripts/economics-paths.sh"
CRON_SH="${REPO_ROOT}/scripts/cron.sh"
STUB_REVENIUM_SH="${SCRIPT_DIR}/stub-revenium.sh"

# The developer's own sidecar settings must not leak into a case.
unset REVENIUM_SIDECAR_HOME REVENIUM_ECON_STATE_DIR XDG_STATE_HOME \
  REVENIUM_TICK_INTERVAL_MINUTES REVENIUM_ECON_INFER_BUDGET_SECONDS OPENCLAW_HOME

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
skip() { echo "SKIP: $1"; }

# ---------------------------------------------------------------------------
# Cleanup: track all tmp files/dirs globally and clean up on exit.
# ---------------------------------------------------------------------------
declare -a TMP_HOMES=()

cleanup() {
  for d in "${TMP_HOMES[@]+"${TMP_HOMES[@]}"}"; do
    rm -rf "${d}" 2>/dev/null || true
  done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Guard: the scripts under test must exist.
# ---------------------------------------------------------------------------
for f in "${ECON_SH}" "${PATHS_SH}"; do
  if [[ ! -f "${f}" ]]; then
    fail "script-exists: ${f} not found"
    echo ""
    echo "Results: ${PASS} passed, ${FAIL} failed"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# wait_for_file <path> <seconds> — poll until <path> exists.
wait_for_file() {
  local path="$1" tries=$(( $2 * 5 ))
  while (( tries > 0 )); do
    [[ -e "${path}" ]] && return 0
    sleep 0.2
    tries=$(( tries - 1 ))
  done
  [[ -e "${path}" ]]
}

# json_get <file> <key> — print a top-level value; __MISSING__ when absent,
# __INVALID__ when the file does not parse.
json_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    print("__INVALID__")
    sys.exit(0)
value = data.get(sys.argv[2], "__MISSING__") if isinstance(data, dict) else "__INVALID__"
print(value)
PY
}

# perms <path> — the first ten characters of the `ls -ld` mode field.
perms() {
  local out
  out="$(ls -ld -- "$1" 2>/dev/null)" || return 0
  out="${out%% *}"
  printf '%s\n' "${out:0:10}"
}

# make_home — temp HOME with an OpenClaw layout and a stub revenium on PATH.
make_home() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-econ.XXXXXX")
  TMP_HOMES+=("${d}")
  mkdir -p "${d}/.openclaw/agents" "${d}/.openclaw/skills/revenium" "${d}/bin"
  ln -sf "${STUB_REVENIUM_SH}" "${d}/bin/revenium"
  echo "${d}"
}

# make_runtime <dir> — an empty, private runtime dir.
make_runtime() {
  mkdir -p "$1"
  chmod 700 "$1"
}

# expected_state_dir <home> — the standalone state dir economics-paths.sh
# computes for <home>/.openclaw with no XDG or state-dir override.
expected_state_dir() {
  (
    unset XDG_STATE_HOME REVENIUM_ECON_STATE_DIR
    HOME="$1"
    # shellcheck source=../scripts/economics-paths.sh
    . "${PATHS_SH}"
    econ_standalone_state_dir "$1/.openclaw"
  )
}

# run_cron <home> [NAME=VALUE ...] — one standalone tick.
run_cron() {
  local home="$1"
  shift
  env HOME="${home}" PATH="${home}/bin:${PATH}" "$@" bash "${CRON_SH}" >/dev/null 2>&1
}

# run_econ <home> [NAME=VALUE ...] <stage> [args...] — call the shim the way
# cron.sh does: scrubbed env, --openclaw-home <home>/.openclaw.
run_econ() {
  local home="$1"
  shift
  local envs=()
  while [[ $# -gt 0 && "$1" == *=* ]]; do
    envs+=("$1")
    shift
  done
  env -i HOME="${home}" PATH="/usr/bin:/bin" LANG=C ${envs[@]+"${envs[@]}"} \
    bash "${ECON_SH}" "$@" --openclaw-home "${home}/.openclaw" >/dev/null 2>&1
}

# ===========================================================================
# GROUP SH-A: a standalone tick with no runtime publishes not_provisioned and
# keeps state in a private host-local dir.
# ===========================================================================
echo ""
echo "--- GROUP SH-A: standalone tick, no runtime ---"

HOME_A=$(make_home)
RT_A="${HOME_A}/rt-empty"
make_runtime "${RT_A}"
HB_A="${HOME_A}/.openclaw/skills/revenium/economics-status.json"
rc_a=0
run_cron "${HOME_A}" REVENIUM_SIDECAR_HOME="${RT_A}" REVENIUM_TICK_INTERVAL_MINUTES=2 || rc_a=$?
if [[ "${rc_a}" -eq 0 ]]; then
  pass "SH-A: cron.sh exits 0 with no sidecar runtime"
else
  fail "SH-A: cron.sh exited ${rc_a}"
fi
if wait_for_file "${HB_A}" 15; then
  pass "SH-A: economics-status.json published within 15s"
else
  fail "SH-A: economics-status.json not published"
fi
if [[ "$(json_get "${HB_A}" state)" == "off" \
  && "$(json_get "${HB_A}" reason)" == "not_provisioned" \
  && "$(json_get "${HB_A}" outageId)" == "" ]]; then
  pass "SH-A: heartbeat is state off, reason not_provisioned, empty outageId"
else
  fail "SH-A: heartbeat fields wrong: $(cat "${HB_A}" 2>/dev/null)"
fi
if [[ "$(json_get "${HB_A}" _maxAgeSeconds)" == "360" ]]; then
  pass "SH-A: _maxAgeSeconds is 3 x 2 min x 60 = 360"
else
  fail "SH-A: _maxAgeSeconds is $(json_get "${HB_A}" _maxAgeSeconds), expected 360"
fi
SD_A="$(expected_state_dir "${HOME_A}")"
if [[ -d "${SD_A}" && "$(perms "${SD_A}")" == "drwx------" && "${SD_A}" != "${HOME_A}/.openclaw"* ]]; then
  pass "SH-A: standalone state dir is drwx------ and outside OPENCLAW_HOME"
else
  fail "SH-A: state dir ${SD_A} missing, wrong mode ($(perms "${SD_A}")) or inside OPENCLAW_HOME"
fi
if [[ "$(perms "${SD_A}/heartbeat.state")" == "-rw-------" ]]; then
  pass "SH-A: heartbeat.state is -rw-------"
else
  fail "SH-A: heartbeat.state mode is '$(perms "${SD_A}/heartbeat.state")'"
fi

# ===========================================================================
# GROUP SH-B: no interval exported → no _maxAgeSeconds.
# ===========================================================================
echo ""
echo "--- GROUP SH-B: no interval, no TTL ---"

HOME_B=$(make_home)
RT_B="${HOME_B}/rt-empty"
make_runtime "${RT_B}"
HB_B="${HOME_B}/.openclaw/skills/revenium/economics-status.json"
run_cron "${HOME_B}" REVENIUM_SIDECAR_HOME="${RT_B}" || true
wait_for_file "${HB_B}" 15 || true
if [[ "$(json_get "${HB_B}" reason)" == "not_provisioned" && "$(json_get "${HB_B}" _maxAgeSeconds)" == "__MISSING__" ]]; then
  pass "SH-B: heartbeat has no _maxAgeSeconds when the interval is not exported"
else
  fail "SH-B: unexpected heartbeat: $(cat "${HB_B}" 2>/dev/null)"
fi

# ===========================================================================
# GROUP SH-C: direct invocations always exit 0.
# ===========================================================================
echo ""
echo "--- GROUP SH-C: direct invocations exit 0 ---"

HOME_C=$(make_home)
RT_C="${HOME_C}/rt-empty"
make_runtime "${RT_C}"
rc_c=0
run_econ "${HOME_C}" REVENIUM_SIDECAR_HOME="${RT_C}" infer || rc_c=$?
[[ "${rc_c}" -eq 0 ]] && pass "SH-C: infer exits 0" || fail "SH-C: infer exited ${rc_c}"
rc_c=0
run_econ "${HOME_C}" REVENIUM_SIDECAR_HOME="${RT_C}" deliver --phase pre || rc_c=$?
[[ "${rc_c}" -eq 0 ]] && pass "SH-C: deliver --phase pre exits 0" || fail "SH-C: deliver exited ${rc_c}"
rc_c=0
run_econ "${HOME_C}" REVENIUM_SIDECAR_HOME="${RT_C}" bogus-stage || rc_c=$?
[[ "${rc_c}" -eq 0 ]] && pass "SH-C: unknown stage exits 0" || fail "SH-C: unknown stage exited ${rc_c}"
rc_c=0
env -i HOME="${HOME_C}" PATH="/usr/bin:/bin" bash "${ECON_SH}" infer >/dev/null 2>&1 || rc_c=$?
[[ "${rc_c}" -eq 0 ]] && pass "SH-C: missing --openclaw-home exits 0" || fail "SH-C: missing --openclaw-home exited ${rc_c}"

# ===========================================================================
# GROUP SH-D: a failed provision reason is carried as detail.
# ===========================================================================
echo ""
echo "--- GROUP SH-D: provision failure detail ---"

HOME_D=$(make_home)
RT_D="${HOME_D}/rt-failed"
make_runtime "${RT_D}"
printf 'reason=download_failed\n' > "${RT_D}/PROVISION_STATUS"
HB_D="${HOME_D}/.openclaw/skills/revenium/economics-status.json"
run_econ "${HOME_D}" REVENIUM_SIDECAR_HOME="${RT_D}" infer || true
if [[ "$(json_get "${HB_D}" reason)" == "not_provisioned" && "$(json_get "${HB_D}" detail)" == "download_failed" ]]; then
  pass "SH-D: not_provisioned with detail download_failed"
else
  fail "SH-D: unexpected heartbeat: $(cat "${HB_D}" 2>/dev/null)"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
