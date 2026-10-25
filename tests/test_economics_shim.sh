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

# make_stub_runtime <dir> <mode> — a provisioned runtime whose venv python is
# a bash stub. The stub reads its mode from <dir>/stub-mode on every run:
# ok exit 0, crash exit 1, rt3 exit 3, rt4 exit 4, hang sleep 30.
make_stub_runtime() {
  local dir="$1"
  mkdir -p "${dir}/venv/bin"
  chmod 700 "${dir}"
  printf 'version=test\n' > "${dir}/INSTALLED"
  cat > "${dir}/venv/bin/python" <<'STUB'
#!/usr/bin/env bash
runtime="$(cd "$(dirname "$0")/../.." && pwd)"
mode="$(cat "${runtime}/stub-mode" 2>/dev/null)"
case "${mode}" in
  ok)    exit 0 ;;
  crash) exit 1 ;;
  rt3)   exit 3 ;;
  rt4)   exit 4 ;;
  hang)  exec sleep 30 ;;
  *)     exit 1 ;;
esac
STUB
  chmod 755 "${dir}/venv/bin/python"
  printf '%s\n' "$2" > "${dir}/stub-mode"
}

# make_state_dir — a private (0700) state dir outside any OPENCLAW_HOME.
make_state_dir() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-econ-state.XXXXXX")
  TMP_HOMES+=("${d}")
  chmod 700 "${d}"
  echo "${d}"
}

# ===========================================================================
# GROUP SH-E: Python exit codes map to reasons; outages re-arm.
# ===========================================================================
echo ""
echo "--- GROUP SH-E: rc matrix and outage ids ---"

HOME_E=$(make_home)
RT_E="${HOME_E}/rt"
make_stub_runtime "${RT_E}" ok
SD_E=$(make_state_dir)
HB_E="${HOME_E}/.openclaw/skills/revenium/economics-status.json"
RC_E_BAD=0

infer_e() {
  local rc=0
  run_econ "${HOME_E}" REVENIUM_SIDECAR_HOME="${RT_E}" REVENIUM_ECON_STATE_DIR="${SD_E}" "$@" infer || rc=$?
  [[ "${rc}" -eq 0 ]] || RC_E_BAD=$(( RC_E_BAD + 1 ))
}
set_mode_e() { printf '%s\n' "$1" > "${RT_E}/stub-mode"; }

infer_e
U1="$(json_get "${HB_E}" updatedAt)"
if [[ "$(json_get "${HB_E}" state)" == "ok" && "$(json_get "${HB_E}" outageId)" == "" ]]; then
  pass "SH-E: rc 0 gives state ok with empty outageId"
else
  fail "SH-E: rc 0 heartbeat: $(cat "${HB_E}" 2>/dev/null)"
fi

set_mode_e crash
infer_e
O1="$(json_get "${HB_E}" outageId)"
if [[ "$(json_get "${HB_E}" state)" == "off" && "$(json_get "${HB_E}" reason)" == "crashing" && "${O1}" == "${U1}" ]]; then
  pass "SH-E: rc 1 gives crashing with outageId = last healthy updatedAt"
else
  fail "SH-E: crash heartbeat (expected outageId ${U1}): $(cat "${HB_E}" 2>/dev/null)"
fi

infer_e
if [[ "$(json_get "${HB_E}" outageId)" == "${O1}" ]]; then
  pass "SH-E: a second crash keeps the same outageId"
else
  fail "SH-E: outageId changed during one outage: $(cat "${HB_E}" 2>/dev/null)"
fi

sleep 1
set_mode_e ok
infer_e
U2="$(json_get "${HB_E}" updatedAt)"
if [[ "$(json_get "${HB_E}" state)" == "ok" && "$(json_get "${HB_E}" outageId)" == "" ]]; then
  pass "SH-E: a healthy run clears outageId"
else
  fail "SH-E: recovery heartbeat: $(cat "${HB_E}" 2>/dev/null)"
fi

sleep 1
set_mode_e crash
infer_e
O2="$(json_get "${HB_E}" outageId)"
if [[ "${O2}" == "${U2}" && "${O2}" != "${O1}" ]]; then
  pass "SH-E: a new outage gets a new outageId (re-arm)"
else
  fail "SH-E: re-armed outageId ${O2} (first ${O1}, last healthy ${U2})"
fi

set_mode_e rt3
infer_e
[[ "$(json_get "${HB_E}" reason)" == "runtime_missing" ]] \
  && pass "SH-E: rc 3 gives runtime_missing" \
  || fail "SH-E: rc 3 gave $(json_get "${HB_E}" reason)"

set_mode_e rt4
infer_e
[[ "$(json_get "${HB_E}" reason)" == "unsafe_state_dir" ]] \
  && pass "SH-E: rc 4 gives unsafe_state_dir" \
  || fail "SH-E: rc 4 gave $(json_get "${HB_E}" reason)"

set_mode_e hang
t0=$(date +%s)
infer_e REVENIUM_ECON_INFER_BUDGET_SECONDS=2
elapsed=$(( $(date +%s) - t0 ))
if [[ "$(json_get "${HB_E}" reason)" == "timeout" && "${elapsed}" -le 12 ]]; then
  pass "SH-E: a hung sidecar gives timeout within 12s (took ${elapsed}s)"
else
  fail "SH-E: hang gave $(json_get "${HB_E}" reason) after ${elapsed}s"
fi

rm -f "${RT_E}/venv/bin/python"
infer_e
[[ "$(json_get "${HB_E}" reason)" == "runtime_missing" ]] \
  && pass "SH-E: a missing venv python gives runtime_missing" \
  || fail "SH-E: missing python gave $(json_get "${HB_E}" reason)"

rm -f "${RT_E}/INSTALLED"
infer_e
if [[ "$(json_get "${HB_E}" reason)" == "not_provisioned" && -n "$(json_get "${HB_E}" outageId)" ]]; then
  pass "SH-E: a removed manifest gives not_provisioned and keeps the outageId (it ran, then stopped)"
else
  fail "SH-E: removed manifest heartbeat: $(cat "${HB_E}" 2>/dev/null)"
fi

[[ "${RC_E_BAD}" -eq 0 ]] \
  && pass "SH-E: every infer invocation exited 0" \
  || fail "SH-E: ${RC_E_BAD} infer invocation(s) exited non-zero"

# ===========================================================================
# GROUP SH-F: the infer lock.
# ===========================================================================
echo ""
echo "--- GROUP SH-F: infer lock ---"

HOME_F=$(make_home)
RT_F="${HOME_F}/rt"
make_stub_runtime "${RT_F}" ok
SD_F=$(make_state_dir)
HB_F="${HOME_F}/.openclaw/skills/revenium/economics-status.json"
run_econ "${HOME_F}" REVENIUM_SIDECAR_HOME="${RT_F}" REVENIUM_ECON_STATE_DIR="${SD_F}" infer || true

printf 'hang\n' > "${RT_F}/stub-mode"
env -i HOME="${HOME_F}" PATH="/usr/bin:/bin" LANG=C REVENIUM_SIDECAR_HOME="${RT_F}" \
  REVENIUM_ECON_STATE_DIR="${SD_F}" REVENIUM_ECON_INFER_BUDGET_SECONDS=20 \
  bash "${ECON_SH}" infer --openclaw-home "${HOME_F}/.openclaw" >/dev/null 2>&1 &
BG_F=$!

if wait_for_file "${SD_F}/infer.started" 10; then
  before_f="$(cksum < "${HB_F}")"
  t0=$(date +%s)
  rc_f=0
  run_econ "${HOME_F}" REVENIUM_SIDECAR_HOME="${RT_F}" REVENIUM_ECON_STATE_DIR="${SD_F}" infer || rc_f=$?
  elapsed=$(( $(date +%s) - t0 ))
  if [[ "${rc_f}" -eq 0 && "${elapsed}" -le 3 && "$(cksum < "${HB_F}")" == "${before_f}" ]]; then
    pass "SH-F: a second infer exits 0 within 3s and leaves the heartbeat untouched"
  else
    fail "SH-F: second infer rc=${rc_f} after ${elapsed}s, heartbeat changed: $(cat "${HB_F}")"
  fi

  printf '%s\n' "$(( $(date +%s) - 1000 ))" > "${SD_F}/infer.started"
  run_econ "${HOME_F}" REVENIUM_SIDECAR_HOME="${RT_F}" REVENIUM_ECON_STATE_DIR="${SD_F}" infer || true
  [[ "$(json_get "${HB_F}" reason)" == "stuck" ]] \
    && pass "SH-F: a holder older than budget + 60s is reported as stuck" \
    || fail "SH-F: old holder gave $(json_get "${HB_F}" reason)"
else
  fail "SH-F: background infer never took the lock"
fi
pkill -TERM -P "${BG_F}" 2>/dev/null || true
kill "${BG_F}" 2>/dev/null || true
wait "${BG_F}" 2>/dev/null || true

# ===========================================================================
# GROUP SH-G: a planted revenium.env cannot redirect state or the runtime.
# ===========================================================================
echo ""
echo "--- GROUP SH-G: trusted paths ---"

HOME_G=$(make_home)
make_stub_runtime "${HOME_G}/.openclaw/evil-rt" ok
cat > "${HOME_G}/.openclaw/revenium.env" <<ENV
REVENIUM_ECON_STATE_DIR=${HOME_G}/.openclaw/evil-state
REVENIUM_SIDECAR_HOME=${HOME_G}/.openclaw/evil-rt
PATH=/nonexistent:/usr/bin:/bin
ENV
HB_G="${HOME_G}/.openclaw/skills/revenium/economics-status.json"
run_cron "${HOME_G}" || true
wait_for_file "${HB_G}" 15 || true
SD_G="$(expected_state_dir "${HOME_G}")"
[[ ! -e "${HOME_G}/.openclaw/evil-state" ]] \
  && pass "SH-G: the planted REVENIUM_ECON_STATE_DIR was never created" \
  || fail "SH-G: ${HOME_G}/.openclaw/evil-state exists"
[[ "$(json_get "${HB_G}" reason)" == "not_provisioned" ]] \
  && pass "SH-G: reason is not_provisioned, so the planted runtime was never consulted" \
  || fail "SH-G: reason $(json_get "${HB_G}" reason) (expected not_provisioned)"
[[ -f "${SD_G}/heartbeat.state" ]] \
  && pass "SH-G: state stayed in the trusted standalone dir" \
  || fail "SH-G: no heartbeat.state in ${SD_G}"

# ===========================================================================
# GROUP SH-H: unsafe state dirs are refused before anything is written.
# ===========================================================================
echo ""
echo "--- GROUP SH-H: unsafe state dir ---"

HOME_H=$(make_home)
RT_H="${HOME_H}/rt"
make_runtime "${RT_H}"
HB_H="${HOME_H}/.openclaw/skills/revenium/economics-status.json"

SD_H=$(make_state_dir)
chmod 755 "${SD_H}"
run_econ "${HOME_H}" REVENIUM_SIDECAR_HOME="${RT_H}" REVENIUM_ECON_STATE_DIR="${SD_H}" infer || true
if [[ "$(json_get "${HB_H}" reason)" == "unsafe_state_dir" && "$(json_get "${HB_H}" outageId)" == "unsafe_state_dir" \
  && ! -e "${SD_H}/heartbeat.state" ]]; then
  pass "SH-H: a 0755 state dir is refused with unsafe_state_dir and left empty"
else
  fail "SH-H: 0755 state dir: $(cat "${HB_H}" 2>/dev/null); contents: $(ls -A "${SD_H}")"
fi

rm -f "${HB_H}"
INSIDE_H="${HOME_H}/.openclaw/sidecar-state"
run_econ "${HOME_H}" REVENIUM_SIDECAR_HOME="${RT_H}" REVENIUM_ECON_STATE_DIR="${INSIDE_H}" infer || true
if [[ "$(json_get "${HB_H}" reason)" == "unsafe_state_dir" && ! -e "${INSIDE_H}" ]]; then
  pass "SH-H: a state dir inside OPENCLAW_HOME is refused and never created"
else
  fail "SH-H: inside-home state dir: $(cat "${HB_H}" 2>/dev/null); exists: $([[ -e "${INSIDE_H}" ]] && echo yes || echo no)"
fi

rm -f "${HB_H}"
mkdir -p "${INSIDE_H}"
chmod 700 "${INSIDE_H}"
run_econ "${HOME_H}" REVENIUM_SIDECAR_HOME="${RT_H}" REVENIUM_ECON_STATE_DIR="${INSIDE_H}" infer || true
if [[ "$(json_get "${HB_H}" reason)" == "unsafe_state_dir" && -z "$(ls -A "${INSIDE_H}")" ]]; then
  pass "SH-H: an existing 0700 dir inside OPENCLAW_HOME is refused and left empty"
else
  fail "SH-H: existing inside-home dir: $(cat "${HB_H}" 2>/dev/null); contents: $(ls -A "${INSIDE_H}")"
fi

# ===========================================================================
# GROUP SH-I: hostile PROVISION_STATUS values never reach the heartbeat.
# ===========================================================================
echo ""
echo "--- GROUP SH-I: injection ---"

HOME_I=$(make_home)
RT_I="${HOME_I}/rt"
make_runtime "${RT_I}"
HB_I="${HOME_I}/.openclaw/skills/revenium/economics-status.json"

printf '%s\n' "reason=\$(touch ${HOME_I}/pwned)" > "${RT_I}/PROVISION_STATUS"
run_econ "${HOME_I}" REVENIUM_SIDECAR_HOME="${RT_I}" infer || true
if [[ "$(json_get "${HB_I}" detail)" == "" && "$(json_get "${HB_I}" state)" == "off" ]]; then
  pass "SH-I: a command-substitution reason is dropped from detail"
else
  fail "SH-I: command-substitution heartbeat: $(cat "${HB_I}" 2>/dev/null)"
fi
[[ ! -e "${HOME_I}/pwned" ]] \
  && pass "SH-I: PROVISION_STATUS is parsed, never executed" \
  || fail "SH-I: ${HOME_I}/pwned was created"

printf '%s\n' 'reason=download_failed","state":"ok' > "${RT_I}/PROVISION_STATUS"
run_econ "${HOME_I}" REVENIUM_SIDECAR_HOME="${RT_I}" infer || true
if [[ "$(json_get "${HB_I}" detail)" == "" && "$(json_get "${HB_I}" state)" == "off" ]]; then
  pass "SH-I: a JSON-breaking reason is dropped and the heartbeat still parses"
else
  fail "SH-I: JSON-injection heartbeat: $(cat "${HB_I}" 2>/dev/null)"
fi

# ===========================================================================
# GROUP SH-J: the NemoClaw tick keeps sidecar state on the host.
# ===========================================================================
echo ""
echo "--- GROUP SH-J: NemoClaw arm ---"

TICK_SH="${REPO_ROOT}/scripts/nemoclaw-cron-tick.sh"
HOME_J=$(mktemp -d "${TMPDIR:-/tmp}/test-econ-nemo.XXXXXX")
TMP_HOMES+=("${HOME_J}")
mkdir -p "${HOME_J}/.nemoclaw" "${HOME_J}/.local/bin"
for cmd in mountpoint crontab sshfs fusermount umount; do
  ln -sf "${SCRIPT_DIR}/stub-mount-env.sh" "${HOME_J}/.local/bin/${cmd}"
done
ln -sf "${SCRIPT_DIR}/stub-nemoclaw.sh" "${HOME_J}/.local/bin/nemoclaw"
ln -sf "${STUB_REVENIUM_SH}" "${HOME_J}/.local/bin/revenium"
MNT_J="${HOME_J}/sbx-openclaw-revenium-spike"
mkdir -p "${MNT_J}/skills/revenium" "${MNT_J}/agents"
printf 'sshfs %s fuse.sshfs rw 0 0\n' "${MNT_J}" > "${HOME_J}/proc-mounts"
HB_J="${MNT_J}/skills/revenium/economics-status.json"

env HOME="${HOME_J}" PATH="${HOME_J}/.local/bin:${PATH}" \
  STUB_MOUNT_UP=1 STUB_PROC_MOUNTS="${HOME_J}/proc-mounts" \
  REVENIUM_SANDBOX_NAME=revenium-spike REVENIUM_TICK_INTERVAL_MINUTES=1 \
  REVENIUM_API_KEY=test-api-key-not-real \
  bash "${TICK_SH}" >/dev/null 2>&1 || true
wait_for_file "${HB_J}" 15 || true
SD_J="${HOME_J}/.nemoclaw/revenium-economics/revenium-spike"
[[ "$(json_get "${HB_J}" reason)" == "not_provisioned" ]] \
  && pass "SH-J: the tick publishes not_provisioned on the mount" \
  || fail "SH-J: mount heartbeat: $(cat "${HB_J}" 2>/dev/null)"
[[ "$(json_get "${HB_J}" _maxAgeSeconds)" == "180" ]] \
  && pass "SH-J: _maxAgeSeconds is 180 for a 1-minute interval" \
  || fail "SH-J: _maxAgeSeconds is $(json_get "${HB_J}" _maxAgeSeconds)"
[[ -d "${SD_J}" && "$(perms "${SD_J}")" == "drwx------" ]] \
  && pass "SH-J: per-sandbox state dir ~/.nemoclaw/revenium-economics/revenium-spike is drwx------" \
  || fail "SH-J: state dir ${SD_J} missing or mode '$(perms "${SD_J}")'"
leaked_j="$(find "${MNT_J}" -name heartbeat.state -o -name 'revenium-economics.log')"
[[ -z "${leaked_j}" ]] \
  && pass "SH-J: no sidecar state or log on the SSHFS mount" \
  || fail "SH-J: sidecar files on the mount: ${leaked_j}"

# ===========================================================================
# GROUP SH-K: economics-paths.sh units.
# ===========================================================================
echo ""
echo "--- GROUP SH-K: paths library ---"

out_k="$( . "${PATHS_SH}"; econ_nemoclaw_state_dir 'bad/../x' )"
rc_k=$?
[[ "${rc_k}" -ne 0 && -z "${out_k}" ]] \
  && pass "SH-K: an invalid sandbox name returns non-zero with no output" \
  || fail "SH-K: econ_nemoclaw_state_dir 'bad/../x' rc=${rc_k} out='${out_k}'"

HOME_K=$(make_home)
mkdir -p "${HOME_K}/other-oc"
k1="$( HOME="${HOME_K}"; unset XDG_STATE_HOME; . "${PATHS_SH}"; econ_standalone_state_dir "${HOME_K}/.openclaw" )"
k2="$( HOME="${HOME_K}"; unset XDG_STATE_HOME; . "${PATHS_SH}"; econ_standalone_state_dir "${HOME_K}/.openclaw" )"
k3="$( HOME="${HOME_K}"; unset XDG_STATE_HOME; . "${PATHS_SH}"; econ_standalone_state_dir "${HOME_K}/other-oc" )"
if [[ -n "${k1}" && "${k1}" == "${k2}" && "${k1}" != "${k3}" ]]; then
  pass "SH-K: one OPENCLAW_HOME maps to one state dir, two homes to two"
else
  fail "SH-K: state dirs ${k1} / ${k2} / ${k3}"
fi
case "${k1}" in
  "${HOME_K}/.local/state/revenium-economics/standalone-"????????????) pass "SH-K: standalone dir is under ~/.local/state with a 12-hex suffix" ;;
  *) fail "SH-K: unexpected standalone dir ${k1}" ;;
esac

( . "${PATHS_SH}"; econ_valid_enum crashing "${ECON_REASONS}" ) \
  && pass "SH-K: econ_valid_enum accepts crashing" \
  || fail "SH-K: econ_valid_enum rejected crashing"
( . "${PATHS_SH}"; econ_valid_enum 'ok;rm' "${ECON_REASONS}" ) \
  && fail "SH-K: econ_valid_enum accepted 'ok;rm'" \
  || pass "SH-K: econ_valid_enum rejects 'ok;rm'"

( . "${PATHS_SH}"; econ_is_under "${HOME_K}/.openclaw2" "${HOME_K}/.openclaw" ) \
  && fail "SH-K: a sibling sharing a name prefix counted as under OPENCLAW_HOME" \
  || pass "SH-K: econ_is_under does not match a sibling with a shared prefix"
( . "${PATHS_SH}"; econ_is_under "${HOME_K}/.openclaw/not/yet/created" "${HOME_K}/.openclaw" ) \
  && pass "SH-K: econ_is_under catches a not-yet-created dir inside OPENCLAW_HOME" \
  || fail "SH-K: econ_is_under missed a missing dir inside OPENCLAW_HOME"
( . "${PATHS_SH}"; econ_real_dir "${HOME_K}/x/../.openclaw" >/dev/null ) \
  && fail "SH-K: econ_real_dir accepted a path with .." \
  || pass "SH-K: econ_real_dir rejects a path with .."

KV_K="${HOME_K}/kv"
printf 'reason=%s\001%s\n' "abc" "$(printf 'x%.0s' $(seq 1 100))" > "${KV_K}"
kv_val="$( . "${PATHS_SH}"; econ_read_kv "${KV_K}" reason )"
[[ "${kv_val}" == abc* && "${#kv_val}" -eq 64 && "${kv_val}" != *$'\001'* ]] \
  && pass "SH-K: econ_read_kv strips control characters and cuts to 64" \
  || fail "SH-K: econ_read_kv returned '${kv_val}' (${#kv_val} chars)"
( . "${PATHS_SH}"; econ_write_kv "${KV_K}" "reason=ok"$'\n'"outage_id=forged" "detail=" )
[[ "$(grep -c '' "${KV_K}")" -eq 2 && "$( . "${PATHS_SH}"; econ_read_kv "${KV_K}" outage_id )" == "" ]] \
  && pass "SH-K: econ_write_kv cannot be made to forge a second key" \
  || fail "SH-K: econ_write_kv wrote: $(cat "${KV_K}")"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
