#!/usr/bin/env bash
# =============================================================================
# test_uninstall_sidecar.sh — Hermetic suite for scripts/uninstall-sidecar.sh.
#
# Every case runs with a throwaway HOME, XDG_STATE_HOME and
# REVENIUM_SIDECAR_HOME unset (unless the case sets them), and a stub
# `crontab` first on PATH that prints a fixture file, so the operator's real
# runtime, state and crontab are never read or touched.
#
#   US-A: no runtime → exit 0, "No economics sidecar runtime found."
#   US-B: runtime + standalone and NemoClaw state → runtime removed, every
#         state file byte-identical
#   US-C: marker-free REVENIUM_SIDECAR_HOME → exit 1, sentinel intact
#   US-D: REVENIUM_SIDECAR_HOME=$HOME → exit 1, nothing removed
#   US-E: crontab still lists revenium-metering → not-provisioned warning
#   US-F: second run after US-B → exit 0, nothing to remove
#   US-G: --purge-cache → only each state dir's turns/ removed
#   US-H: more than one NemoClaw sandbox → shared-runtime warning
#
# SECURITY: never eval's or string-interpolates captured output into shell
#   commands.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
UNINSTALL_SH="${REPO_ROOT}/scripts/uninstall-sidecar.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

declare -a TMP_HOMES=()

cleanup() {
  for d in "${TMP_HOMES[@]+"${TMP_HOMES[@]}"}"; do
    rm -rf "${d}" 2>/dev/null || true
  done
}
trap cleanup EXIT

if [[ ! -f "${UNINSTALL_SH}" ]]; then
  fail "uninstall-sidecar-exists: ${UNINSTALL_SH} not found"
  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  exit 1
fi

# ---------------------------------------------------------------------------
# make_home — throwaway HOME with a stub crontab in <home>/stubbin that
# prints <home>/crontab.fixture for `crontab -l`.
# ---------------------------------------------------------------------------
make_home() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-uninst-sidecar.XXXXXX")
  TMP_HOMES+=("${d}")
  mkdir -p "${d}/stubbin"
  : > "${d}/crontab.fixture"
  cat > "${d}/stubbin/crontab" << EOF
#!/usr/bin/env bash
[ "\${1:-}" = "-l" ] && cat "${d}/crontab.fixture"
exit 0
EOF
  chmod +x "${d}/stubbin/crontab"
  echo "${d}"
}

# mk_runtime <dir> — a provisioned runtime: markers, bin/uv and a venv.
mk_runtime() {
  mkdir -p "$1/bin" "$1/venv/bin"
  printf 'uv_version=0.12.19\n' > "$1/INSTALLED"
  printf 'reason=ok\n' > "$1/PROVISION_STATUS"
  printf '#!/bin/sh\n' > "$1/bin/uv"
  printf '#!/bin/sh\n' > "$1/venv/bin/python"
}

# mk_state <dir> — a state dir as the sidecar leaves it.
mk_state() {
  ( umask 077 && mkdir -p "$1/turns" )
  printf 'last_healthy_at=2026-10-25T00:00:00Z\n' > "$1/heartbeat.state"
  printf '{"s1": 4}\n' > "$1/cursors.json"
  printf 'sk-test-model-key\n' > "$1/model.key"
  printf 'job-1\n' > "$1/revenium-jobs.ledger"
  printf '{"seq":1,"text":"[REDACTED]"}\n' > "$1/turns/s1.jsonl"
}

# snapshot <dir> [exclude-turns] — sorted path + cksum of every file.
snapshot() {
  local dir="$1" skip_turns="${2:-}"
  ( cd "${dir}" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
      if [[ -n "${skip_turns}" && "${f}" == */turns/* ]]; then continue; fi
      printf '%s %s\n' "${f}" "$(cksum < "${f}")"
    done )
}

# run_uninstall <home> [args...] — combined output; exit code in RUN_RC.
RUN_RC=0
run_uninstall() {
  local home_dir="$1"
  shift
  RUN_RC=0
  env -u XDG_STATE_HOME -u REVENIUM_SIDECAR_HOME -u REVENIUM_ECON_STATE_DIR \
    HOME="${home_dir}" PATH="${home_dir}/stubbin:${PATH}" \
    "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" \
    bash "${UNINSTALL_SH}" "$@" 2>&1 || RUN_RC=$?
}
declare -a EXTRA_ENV=()

STANDALONE_REL=".local/state/revenium-economics/standalone-0123456789ab"
NEMO_REL=".nemoclaw/revenium-economics/sbx1"
RUNTIME_REL=".local/share/revenium-sidecar"

# ===========================================================================
echo ""
echo "--- US-A: no runtime ---"
H_A=$(make_home)
out_a=$(run_uninstall "${H_A}"; echo "rc=${RUN_RC}")
if echo "${out_a}" | grep -qx "rc=0" \
   && echo "${out_a}" | grep -qF "No economics sidecar runtime found."; then
  pass "US-A: no runtime → exit 0 and 'No economics sidecar runtime found.'"
else
  fail "US-A: unexpected result: ${out_a}"
fi

# ===========================================================================
echo ""
echo "--- US-B: runtime removed, state kept byte-identical ---"
H_B=$(make_home)
mk_runtime "${H_B}/${RUNTIME_REL}"
mk_state "${H_B}/${STANDALONE_REL}"
mk_state "${H_B}/${NEMO_REL}"
snap_b_before="$(snapshot "${H_B}/.local/state")
$(snapshot "${H_B}/.nemoclaw")"
out_b=$(run_uninstall "${H_B}"; echo "rc=${RUN_RC}")
snap_b_after="$(snapshot "${H_B}/.local/state")
$(snapshot "${H_B}/.nemoclaw")"
if echo "${out_b}" | grep -qx "rc=0" && [[ ! -e "${H_B}/${RUNTIME_REL}" ]]; then
  pass "US-B: runtime removed with exit 0"
else
  fail "US-B: runtime not removed: ${out_b}"
fi
if [[ "${snap_b_before}" == "${snap_b_after}" ]] \
   && [[ -f "${H_B}/${STANDALONE_REL}/revenium-jobs.ledger" && -f "${H_B}/${NEMO_REL}/heartbeat.state" ]]; then
  pass "US-B: every standalone and NemoClaw state file is byte-identical"
else
  fail "US-B: state changed. Before: ${snap_b_before} After: ${snap_b_after}"
fi
if echo "${out_b}" | grep -qF "${H_B}/.local/state/revenium-economics" \
   && echo "${out_b}" | grep -qF "${H_B}/.nemoclaw/revenium-economics" \
   && echo "${out_b}" | grep -qF "nothing is sent to Revenium twice"; then
  pass "US-B: kept state locations and the reinstall explanation are reported"
else
  fail "US-B: kept-state report missing: ${out_b}"
fi

# ===========================================================================
echo ""
echo "--- US-C: marker-free REVENIUM_SIDECAR_HOME is refused ---"
H_C=$(make_home)
mkdir -p "${H_C}/not-a-runtime"
printf 'keep me\n' > "${H_C}/not-a-runtime/sentinel"
EXTRA_ENV=("REVENIUM_SIDECAR_HOME=${H_C}/not-a-runtime")
out_c=$(run_uninstall "${H_C}"; echo "rc=${RUN_RC}")
EXTRA_ENV=()
if echo "${out_c}" | grep -qx "rc=1" \
   && [[ "$(cat "${H_C}/not-a-runtime/sentinel" 2>/dev/null)" == "keep me" ]]; then
  pass "US-C: marker-free runtime dir refused with exit 1 and sentinel intact"
else
  fail "US-C: marker-free dir not refused: ${out_c}"
fi

# ===========================================================================
echo ""
echo "--- US-D: REVENIUM_SIDECAR_HOME=\$HOME is refused ---"
H_D=$(make_home)
# Plant every marker in HOME, so only the $HOME check can stop the removal.
mk_runtime "${H_D}"
printf 'keep me\n' > "${H_D}/sentinel"
EXTRA_ENV=("REVENIUM_SIDECAR_HOME=${H_D}")
out_d=$(run_uninstall "${H_D}"; echo "rc=${RUN_RC}")
EXTRA_ENV=()
if echo "${out_d}" | grep -qx "rc=1" && [[ -f "${H_D}/sentinel" && -f "${H_D}/INSTALLED" ]]; then
  pass "US-D: runtime equal to \$HOME refused with exit 1, nothing removed"
else
  fail "US-D: \$HOME not refused: ${out_d}"
fi

# ===========================================================================
echo ""
echo "--- US-E: cron still installed → not-provisioned warning ---"
H_E=$(make_home)
mk_runtime "${H_E}/${RUNTIME_REL}"
printf '* * * * * bash cron.sh # revenium-metering\n' > "${H_E}/crontab.fixture"
out_e=$(run_uninstall "${H_E}"; echo "rc=${RUN_RC}")
if echo "${out_e}" | grep -qx "rc=0" && echo "${out_e}" | grep -qF "not provisioned"; then
  pass "US-E: crontab with revenium-metering → ticks will report not provisioned"
else
  fail "US-E: cron warning missing: ${out_e}"
fi
H_E2=$(make_home)
mk_runtime "${H_E2}/${RUNTIME_REL}"
out_e2=$(run_uninstall "${H_E2}"; echo "rc=${RUN_RC}")
if ! echo "${out_e2}" | grep -qF "not provisioned"; then
  pass "US-E: no cron entry → no not-provisioned warning"
else
  fail "US-E: warning printed without a cron entry: ${out_e2}"
fi

# ===========================================================================
echo ""
echo "--- US-F: second run is a no-op ---"
out_f=$(run_uninstall "${H_B}"; echo "rc=${RUN_RC}")
snap_f="$(snapshot "${H_B}/.local/state")
$(snapshot "${H_B}/.nemoclaw")"
if echo "${out_f}" | grep -qx "rc=0" \
   && echo "${out_f}" | grep -qF "No economics sidecar runtime found." \
   && [[ "${snap_f}" == "${snap_b_before}" ]]; then
  pass "US-F: second run exits 0 with nothing to remove and state untouched"
else
  fail "US-F: second run not idempotent: ${out_f}"
fi

# ===========================================================================
echo ""
echo "--- US-G: --purge-cache removes only turns/ ---"
H_G=$(make_home)
mk_runtime "${H_G}/${RUNTIME_REL}"
mk_state "${H_G}/${STANDALONE_REL}"
mk_state "${H_G}/${NEMO_REL}"
snap_g_before="$(snapshot "${H_G}/.local/state" skip-turns)
$(snapshot "${H_G}/.nemoclaw" skip-turns)"
out_g=$(run_uninstall "${H_G}" --purge-cache; echo "rc=${RUN_RC}")
snap_g_after="$(snapshot "${H_G}/.local/state")
$(snapshot "${H_G}/.nemoclaw")"
if echo "${out_g}" | grep -qx "rc=0" \
   && [[ ! -e "${H_G}/${STANDALONE_REL}/turns" && ! -e "${H_G}/${NEMO_REL}/turns" ]]; then
  pass "US-G: --purge-cache removed each state dir's turns/"
else
  fail "US-G: turns/ not removed: ${out_g}"
fi
if [[ "${snap_g_before}" == "${snap_g_after}" ]]; then
  pass "US-G: cursors.json, heartbeat.state, model.key and the ledger stay byte-identical"
else
  fail "US-G: non-cache state changed. Before: ${snap_g_before} After: ${snap_g_after}"
fi

# ===========================================================================
echo ""
echo "--- US-H: shared runtime across NemoClaw sandboxes ---"
H_H=$(make_home)
mk_runtime "${H_H}/${RUNTIME_REL}"
mk_state "${H_H}/.nemoclaw/revenium-economics/sbx1"
mk_state "${H_H}/.nemoclaw/revenium-economics/sbx2"
out_h=$(run_uninstall "${H_H}"; echo "rc=${RUN_RC}")
if echo "${out_h}" | grep -qx "rc=0" && echo "${out_h}" | grep -qF "shared by 2 NemoClaw sandboxes"; then
  pass "US-H: more than one sandbox → shared-runtime warning"
else
  fail "US-H: shared-runtime warning missing: ${out_h}"
fi

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
echo ""
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
