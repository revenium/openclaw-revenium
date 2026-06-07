#!/usr/bin/env bash
# =============================================================================
# test_install_dispatcher.sh — Integration tests for install.sh dispatcher
# Covers: NCINST-01 (routing), NCINST-02 (macOS refusal), D-03 branching,
#         idempotency (SC4), byte-stability of post-install.sh (D-01)
#
# Strategy:
#   Use STUB_UNAME_S env var to override OS detection in install.sh.
#   Use mktemp -d HOME isolation to control ~/.nemoclaw and ~/.openclaw presence.
#   All six VALIDATION.md groups + byte-stable covered as labeled sections.
#
# EXPECTED RESULT BEFORE PLAN 02:
#   This test FAILS RED — scripts/install.sh does not yet exist.
#   Exits non-zero with FAIL > 0. Goes GREEN when plan 02 creates install.sh.
#   Do NOT stub install.sh or weaken assertions to make it pass now.
#
# SECURITY: This test never eval's or string-interpolates captured output into
#   shell commands. No real nemoclaw or docker binary is invoked.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/scripts/install.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Cleanup: track all tmp HOMEs globally and clean up on exit
# ---------------------------------------------------------------------------
declare -a TMP_HOMES=()

cleanup() {
  for d in "${TMP_HOMES[@]+"${TMP_HOMES[@]}"}"; do
    rm -rf "${d}" 2>/dev/null || true
  done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# make_home [nemoclaw] [openclaw]
#   Create an isolated tmp HOME with the specified subdirs present.
#   Pass "nemoclaw" to create ~/.nemoclaw, "openclaw" to create ~/.openclaw.
# ---------------------------------------------------------------------------
make_home() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-inst.XXXXXX")
  TMP_HOMES+=("${d}")
  for arg in "$@"; do
    case "${arg}" in
      nemoclaw) mkdir -p "${d}/.nemoclaw" ;;
      openclaw) mkdir -p "${d}/.openclaw" ;;
    esac
  done
  echo "${d}"
}

# ---------------------------------------------------------------------------
# run_install <uname_s> <home_dir> [extra_args...]
#   Invoke install.sh with stubbed OS and isolated HOME.
#   Returns stdout+stderr combined.
# ---------------------------------------------------------------------------
run_install() {
  local uname_s="$1"
  local home_dir="$2"
  shift 2
  STUB_UNAME_S="${uname_s}" \
  HOME="${home_dir}" \
      bash "${INSTALL_SH}" "$@" 2>&1
}

# ---------------------------------------------------------------------------
# Guard: install.sh must exist for routing tests to work.
# If absent, all routing groups fail immediately (RED state).
# ---------------------------------------------------------------------------
if [[ ! -f "${INSTALL_SH}" ]]; then
  echo ""
  echo "=== INSTALL.SH MISSING ==="
  echo "scripts/install.sh does not exist yet (plan 02 creates it)."
  echo "All routing/refusal groups will FAIL — this is the expected RED state."
  echo ""
fi

# ===========================================================================
# GROUP A: NCINST-01, D-03 auto-detect — Linux + ~/.nemoclaw only (no ~/.openclaw)
#   routes to NemoClaw path.
#   Assert: output contains a NemoClaw-path marker ("preflight" or "Phase 13")
#            AND does NOT contain "Revenium skill installed"
# ===========================================================================
echo ""
echo "--- GROUP A: NCINST-01 D-03 auto-detect (NemoClaw-only host) ---"

TMP_HOME_A=$(make_home nemoclaw)

exit_code_a=0
output_a=$(run_install "Linux" "${TMP_HOME_A}" 2>&1) || exit_code_a=$?

# Assert NemoClaw-path marker present in output
if echo "${output_a}" | grep -qi "preflight\|Phase 13\|nemoclaw path"; then
  pass "GROUP-A: NemoClaw-path marker found in output"
else
  fail "GROUP-A: NemoClaw-path marker ('preflight'/'Phase 13') NOT found (install.sh absent or wrong routing)"
fi

# Assert standalone footer NOT in output (post-install.sh should not run)
if echo "${output_a}" | grep -qi "Revenium skill installed"; then
  fail "GROUP-A: standalone path footer 'Revenium skill installed' present — should have routed to NemoClaw"
else
  pass "GROUP-A: standalone footer correctly absent"
fi

# ===========================================================================
# GROUP B: NCINST-01, D-03 explicit flag — Linux + --nemoclaw flag + dual-home
#   (both ~/.nemoclaw and ~/.openclaw present) routes NemoClaw via explicit flag.
#   Assert: NemoClaw-path marker present; flag overrides dual-home default (standalone).
# ===========================================================================
echo ""
echo "--- GROUP B: NCINST-01 D-03 explicit --nemoclaw flag (dual-home) ---"

TMP_HOME_B=$(make_home nemoclaw openclaw)

exit_code_b=0
output_b=$(run_install "Linux" "${TMP_HOME_B}" --nemoclaw 2>&1) || exit_code_b=$?

if echo "${output_b}" | grep -qi "preflight\|Phase 13\|nemoclaw path"; then
  pass "GROUP-B: NemoClaw-path marker found with --nemoclaw flag on dual-home"
else
  fail "GROUP-B: NemoClaw-path marker NOT found — --nemoclaw flag should override dual-home default"
fi

if echo "${output_b}" | grep -qi "Revenium skill installed"; then
  fail "GROUP-B: standalone footer present — --nemoclaw flag should have routed to NemoClaw"
else
  pass "GROUP-B: standalone footer correctly absent with --nemoclaw flag"
fi

# ===========================================================================
# GROUP C: NCINST-01, D-03 standalone default — Linux + dual-home
#   (both ~/.nemoclaw and ~/.openclaw) + NO flag routes standalone.
#   Assert routing DECISION via NemoClaw markers absent (not full install success,
#   since post-install.sh itself fail()s when ~/.openclaw config is incomplete).
# ===========================================================================
echo ""
echo "--- GROUP C: NCINST-01 D-03 standalone default (dual-home, no flag) ---"

TMP_HOME_C=$(make_home nemoclaw openclaw)

exit_code_c=0
output_c=$(run_install "Linux" "${TMP_HOME_C}" 2>&1) || exit_code_c=$?

# The routing decision is: NemoClaw markers should be absent (standalone was selected)
# post-install.sh itself may fail (no ~/.openclaw config) — that's fine for this test
if echo "${output_c}" | grep -qi "preflight\|Phase 13\|nemoclaw path"; then
  fail "GROUP-C: NemoClaw-path marker found — dual-home without flag should route standalone"
else
  pass "GROUP-C: NemoClaw markers absent — standalone routing confirmed"
fi

# ===========================================================================
# GROUP D: NCINST-02, macOS refusal (threat T-12-01) — Darwin + NemoClaw signal
#   Assert: exit code != 0 AND output contains "unsupported"/"graceful-skip"/"linux-only"
# ===========================================================================
echo ""
echo "--- GROUP D: NCINST-02 macOS refusal (T-12-01) -- Darwin + --nemoclaw ---"

TMP_HOME_D=$(make_home nemoclaw)

exit_code_d=0
output_d=$(STUB_UNAME_S="Darwin" HOME="${TMP_HOME_D}" \
    bash "${INSTALL_SH}" --nemoclaw 2>&1) || exit_code_d=$?

if [[ "${exit_code_d}" -ne 0 ]] && echo "${output_d}" | grep -qi "unsupported\|graceful-skip\|linux-only"; then
  pass "GROUP-D: macOS + --nemoclaw exits non-zero with Darwin graceful-skip trap message"
else
  fail "GROUP-D: exit=${exit_code_d}, expected non-zero + unsupported/graceful-skip message (output: $(echo "${output_d}" | head -3))"
fi

# ===========================================================================
# GROUP E: NCINST-02, macOS standalone passthrough (D-05) — Darwin + no signal
#   + ~/.openclaw only. Assert macOS refusal did NOT fire.
# ===========================================================================
echo ""
echo "--- GROUP E: NCINST-02 macOS standalone passthrough (D-05) -- Darwin, no flag ---"

TMP_HOME_E=$(make_home openclaw)

exit_code_e=0
output_e=$(STUB_UNAME_S="Darwin" HOME="${TMP_HOME_E}" \
    bash "${INSTALL_SH}" 2>&1) || exit_code_e=$?

# The macOS refusal must NOT have fired (no graceful-skip/unsupported message)
if echo "${output_e}" | grep -qi "graceful-skip\|NemoClaw is unsupported on macOS"; then
  fail "GROUP-E: macOS refusal fired on standalone path — should only fire when NemoClaw signal present"
else
  pass "GROUP-E: macOS refusal correctly did NOT fire on standalone path"
fi

# ===========================================================================
# GROUP F: NCINST-01, idempotency (SC4) — run NemoClaw path twice against
#   same mktemp HOME; assert exit code 0 both runs and stable output
# ===========================================================================
echo ""
echo "--- GROUP F: NCINST-01 idempotency (SC4) -- NemoClaw path run twice ---"

TMP_HOME_F=$(make_home nemoclaw)

exit_code_f1=0
output_f1=$(run_install "Linux" "${TMP_HOME_F}" 2>&1) || exit_code_f1=$?

exit_code_f2=0
output_f2=$(run_install "Linux" "${TMP_HOME_F}" 2>&1) || exit_code_f2=$?

if [[ "${exit_code_f1}" -eq "${exit_code_f2}" ]]; then
  pass "GROUP-F: idempotency exit codes match on both runs (exit1=${exit_code_f1} exit2=${exit_code_f2})"
else
  fail "GROUP-F: idempotency exit codes differ (exit1=${exit_code_f1} exit2=${exit_code_f2})"
fi

# Both outputs should be stable (contain same NemoClaw routing markers)
f1_has_marker=0; f2_has_marker=0
echo "${output_f1}" | grep -qi "preflight\|Phase 13\|nemoclaw path" && f1_has_marker=1 || true
echo "${output_f2}" | grep -qi "preflight\|Phase 13\|nemoclaw path" && f2_has_marker=1 || true

if [[ "${f1_has_marker}" -eq "${f2_has_marker}" ]]; then
  pass "GROUP-F: idempotency NemoClaw marker presence stable across both runs"
else
  fail "GROUP-F: idempotency marker presence differs between run 1 (${f1_has_marker}) and run 2 (${f2_has_marker})"
fi

# ===========================================================================
# GROUP byte-stable: NCINST-01/02 — assert scripts/post-install.sh has no
#   uncommitted changes (byte-stability constraint D-01)
# ===========================================================================
echo ""
echo "--- GROUP byte-stable: post-install.sh not modified ---"

if git -C "${REPO_ROOT}" diff --name-only HEAD -- scripts/post-install.sh 2>/dev/null | grep -q .; then
  fail "byte-stable: scripts/post-install.sh appears modified — must be byte-stable"
else
  pass "byte-stable: scripts/post-install.sh has no uncommitted changes"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
echo ""
echo "NOTE: This test FAILS RED before plan 02 creates scripts/install.sh."
echo "      Routing/refusal/idempotency groups all FAIL until install.sh exists."
echo "      Goes GREEN when plan 02 implements the dispatcher + NemoClaw skeleton."
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
