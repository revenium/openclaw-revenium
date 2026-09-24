#!/usr/bin/env bash
# =============================================================================
# test_doctor_gate.sh — Hermetic tests for the standalone post-install.sh
# defense-in-depth runtime version gate (GATE-01/GATE-02/GATE-04) and the
# `openclaw doctor --fix` health step (GATE-03).
#
# EXPECTED RESULT BEFORE PLAN 18-02 TASK 2:
#   This test FAILS RED — scripts/post-install.sh has no runtime version gate
#   and no doctor step yet. Exits non-zero with FAIL > 0. Goes GREEN once
#   Task 2 adds the gate + run_openclaw_doctor to scripts/post-install.sh.
#   Do NOT stub post-install.sh or weaken assertions to make it pass now.
#
# SECURITY: This test never eval's or string-interpolates captured output
#   into shell commands. Assertions use grep -qF (fixed-string) throughout.
#   --skip-prereqs is passed on every invocation so a missing revenium/jq/
#   python3 becomes an explicit fail() instead of a real `brew install` call
#   (T-18-06) — this test never invokes brew.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
POST_INSTALL_SH="${REPO_ROOT}/scripts/post-install.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Cleanup: track all tmp HOMEs/bin-dirs globally and clean up on exit
# ---------------------------------------------------------------------------
declare -a TMP_HOMES=()

cleanup() {
  for d in "${TMP_HOMES[@]+"${TMP_HOMES[@]}"}"; do
    rm -rf "${d}" 2>/dev/null || true
  done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# make_home — create an isolated tmp HOME.
# ---------------------------------------------------------------------------
make_home() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-dg-home.XXXXXX")
  TMP_HOMES+=("${d}")
  echo "${d}"
}

# ---------------------------------------------------------------------------
# stub_bin — create a tmp dir with tests/stub-openclaw.sh symlinked in as
# `openclaw`, and echo the dir so callers can prepend it to PATH. The doctor
# step (run_openclaw_doctor, added by Task 2) shells out to the real
# `openclaw doctor --fix --non-interactive` command, so it needs this stub
# resolvable on PATH — unlike require_openclaw_version/require_node_version,
# which read their STUB_* env-var overrides directly without needing a
# binary on PATH at all.
# ---------------------------------------------------------------------------
stub_bin() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-dg-bin.XXXXXX")
  TMP_HOMES+=("${d}")
  ln -sf "${REPO_ROOT}/tests/stub-openclaw.sh" "${d}/openclaw"
  echo "${d}"
}

# ---------------------------------------------------------------------------
# run_post_install <home_dir>
#   Invoke post-install.sh --skip-prereqs with the stub openclaw on PATH and
#   an isolated HOME. Returns stdout+stderr combined. Passing --skip-prereqs
#   is mandatory: without it, post-install.sh calls Homebrew for a missing
#   `revenium` CLI — a real mutation this hermetic test must never perform.
#
#   Version-gate and doctor overrides come from the caller's environment
#   (the STUB_X:-default idiom mirrors run_install() in
#   test_install_dispatcher.sh) — a group that does not set a given STUB_*
#   var gets a passing default, so it exercises only the behavior under test.
# ---------------------------------------------------------------------------
run_post_install() {
  local home_dir="$1"
  local bindir
  bindir="$(stub_bin)"
  PATH="${bindir}:${PATH}" \
  HOME="${home_dir}" \
  STUB_OPENCLAW_VERSION_OUTPUT="${STUB_OPENCLAW_VERSION_OUTPUT:-OpenClaw 2026.9.6 (eb377ac)}" \
  STUB_NODE_VERSION="${STUB_NODE_VERSION:-v24.21.0}" \
  STUB_OPENCLAW_DOCTOR_RC="${STUB_OPENCLAW_DOCTOR_RC:-0}" \
  STUB_OPENCLAW_DOCTOR_OUTPUT="${STUB_OPENCLAW_DOCTOR_OUTPUT:-Doctor: all checks passed.}" \
  BOUNDED_RUN_FORCE_PORTABLE="${BOUNDED_RUN_FORCE_PORTABLE:-}" \
  DOCTOR_TIMEOUT_SECONDS="${DOCTOR_TIMEOUT_SECONDS:-}" \
  STUB_OPENCLAW_DOCTOR_SLEEP_SECONDS="${STUB_OPENCLAW_DOCTOR_SLEEP_SECONDS:-}" \
      bash "${POST_INSTALL_SH}" --skip-prereqs 2>&1
}

# ---------------------------------------------------------------------------
# Guard: post-install.sh must exist.
# ---------------------------------------------------------------------------
if [[ ! -f "${POST_INSTALL_SH}" ]]; then
  echo ""
  echo "=== POST-INSTALL.SH MISSING ==="
  fail "post-install-script-exists: ${POST_INSTALL_SH} not found"
fi

# ===========================================================================
# GROUP DG-A: GATE-03, operator visibility + ordering.
#   Passing OpenClaw/Node, doctor exits 0 with a sentinel. Assert the
#   sentinel is printed AND appears before "Checking prerequisites".
# ===========================================================================
echo ""
echo "--- GROUP DG-A: GATE-03 operator visibility + ordering ---"

home_a="$(make_home)"
output_a=$(STUB_OPENCLAW_DOCTOR_OUTPUT="DOCTOR_STUB_SENTINEL_OK" \
    STUB_OPENCLAW_DOCTOR_RC=0 \
    run_post_install "${home_a}") || true

if echo "${output_a}" | grep -qF "DOCTOR_STUB_SENTINEL_OK"; then
  pass "DG-A: doctor output visible to operator"
else
  fail "DG-A: doctor output ('DOCTOR_STUB_SENTINEL_OK') NOT visible in captured output"
fi

_dga_doctor_line=$(printf '%s\n' "${output_a}" | grep -n -F "DOCTOR_STUB_SENTINEL_OK" | head -1 | cut -d: -f1)
_dga_prereq_line=$(printf '%s\n' "${output_a}" | grep -n -F "Checking prerequisites" | head -1 | cut -d: -f1)

if [[ -n "${_dga_doctor_line:-}" && -n "${_dga_prereq_line:-}" && "${_dga_doctor_line}" -lt "${_dga_prereq_line}" ]]; then
  pass "DG-A: doctor output line precedes 'Checking prerequisites' line"
else
  fail "DG-A: doctor output does not precede 'Checking prerequisites' (doctor_line=${_dga_doctor_line:-<none>} prereq_line=${_dga_prereq_line:-<none>})"
fi

# ===========================================================================
# GROUP DG-B: GATE-03, non-blocking. Doctor exits 1 with a finding sentinel.
#   Assert the sentinel and the "exited 1" warn text are printed, and the
#   install still reaches "Checking prerequisites" (did not abort).
# ===========================================================================
echo ""
echo "--- GROUP DG-B: GATE-03 non-blocking on doctor failure ---"

home_b="$(make_home)"
output_b=$(STUB_OPENCLAW_DOCTOR_RC=1 \
    STUB_OPENCLAW_DOCTOR_OUTPUT="DOCTOR_STUB_SENTINEL_FINDING" \
    run_post_install "${home_b}") || true

if echo "${output_b}" | grep -qF "DOCTOR_STUB_SENTINEL_FINDING"; then
  pass "DG-B: doctor finding output visible to operator"
else
  fail "DG-B: doctor finding output ('DOCTOR_STUB_SENTINEL_FINDING') NOT visible"
fi

if echo "${output_b}" | grep -qF "doctor --fix exited 1"; then
  pass "DG-B: non-zero doctor exit is reported ('doctor --fix exited 1')"
else
  fail "DG-B: 'doctor --fix exited 1' NOT found in output"
fi

if echo "${output_b}" | grep -qF "Checking prerequisites"; then
  pass "DG-B: install continued to 'Checking prerequisites' despite non-zero doctor exit"
else
  fail "DG-B: install did NOT reach 'Checking prerequisites' — a non-zero doctor exit must not abort the install"
fi

# ===========================================================================
# GROUP DG-C: GATE-01 defense-in-depth. Below-floor OpenClaw.
#   Assert exit non-zero, both versions named, and provisioning never started.
# ===========================================================================
echo ""
echo "--- GROUP DG-C: GATE-01 defense-in-depth (below-floor OpenClaw) ---"

home_c="$(make_home)"
exit_code_c=0
output_c=$(STUB_OPENCLAW_VERSION_OUTPUT="OpenClaw 2026.7.1 (deadbee)" \
    run_post_install "${home_c}") || exit_code_c=$?

if [[ "${exit_code_c}" -ne 0 ]]; then
  pass "DG-C: below-floor OpenClaw exits non-zero"
else
  fail "DG-C: below-floor OpenClaw exited 0 (exit=${exit_code_c})"
fi

if echo "${output_c}" | grep -qF "2026.7.1"; then
  pass "DG-C: output names the detected version 2026.7.1"
else
  fail "DG-C: output does not contain detected version 2026.7.1"
fi

if echo "${output_c}" | grep -qF "2026.8.1"; then
  pass "DG-C: output names the required floor 2026.8.1"
else
  fail "DG-C: output does not contain required floor 2026.8.1"
fi

if echo "${output_c}" | grep -qF "Checking prerequisites"; then
  fail "DG-C: 'Checking prerequisites' present — refusal did not precede every provisioning step"
else
  pass "DG-C: 'Checking prerequisites' correctly absent — refusal preceded every provisioning step"
fi

# ===========================================================================
# GROUP DG-D: GATE-04 defense-in-depth. Passing OpenClaw, excluded-major Node.
#   Assert exit non-zero and both the detected version and the range printed.
# ===========================================================================
echo ""
echo "--- GROUP DG-D: GATE-04 defense-in-depth (excluded-major Node) ---"

home_d="$(make_home)"
exit_code_d=0
output_d=$(STUB_NODE_VERSION="v25.0.0" \
    run_post_install "${home_d}") || exit_code_d=$?

if [[ "${exit_code_d}" -ne 0 ]]; then
  pass "DG-D: excluded-major Node exits non-zero"
else
  fail "DG-D: excluded-major Node exited 0 (exit=${exit_code_d})"
fi

if echo "${output_d}" | grep -qF "v25.0.0"; then
  pass "DG-D: output names the detected Node version v25.0.0"
else
  fail "DG-D: output does not contain detected Node version v25.0.0"
fi

if echo "${output_d}" | grep -qF ">=24.16.0 <25.0.0, or >=26.1.0"; then
  pass "DG-D: output names the required Node range"
else
  fail "DG-D: output does not contain the required Node range"
fi

# ===========================================================================
# GROUP DG-E: GATE-03 ordering vs the gate. Below-floor OpenClaw AND a
#   doctor sentinel configured. Assert the doctor sentinel NEVER appears —
#   doctor must never run against a wrong-version OpenClaw.
# ===========================================================================
echo ""
echo "--- GROUP DG-E: doctor never runs against a wrong-version OpenClaw ---"

home_e="$(make_home)"
output_e=$(STUB_OPENCLAW_VERSION_OUTPUT="OpenClaw 2026.7.1 (deadbee)" \
    STUB_OPENCLAW_DOCTOR_OUTPUT="DOCTOR_STUB_SENTINEL_OK" \
    run_post_install "${home_e}") || true

if echo "${output_e}" | grep -qF "DOCTOR_STUB_SENTINEL_OK"; then
  fail "DG-E: doctor sentinel present — doctor ran against a wrong-version OpenClaw"
else
  pass "DG-E: doctor sentinel correctly absent — doctor did not run against a wrong-version OpenClaw"
fi

# ===========================================================================
# GROUP DG-F: portable time-bound engaged, doctor still surfaced (18-06,
#   18-VERIFICATION gap #2 / 18-REVIEW CR-03). Force the portable mechanism
#   with a fast doctor stub. Assert the disclosure notice, the doctor
#   sentinel, and ordering all still hold.
# ===========================================================================
echo ""
echo "--- GROUP DG-F: portable time-bound engaged, doctor still surfaced ---"

home_f="$(make_home)"
output_f=$(BOUNDED_RUN_FORCE_PORTABLE=1 \
    STUB_OPENCLAW_DOCTOR_OUTPUT="DOCTOR_STUB_SENTINEL_DGF" \
    STUB_OPENCLAW_DOCTOR_RC=0 \
    run_post_install "${home_f}") || true

if echo "${output_f}" | grep -qF "portable bash time-bound"; then
  pass "DG-F: portable time-bound disclosure notice present"
else
  fail "DG-F: portable time-bound disclosure notice ('portable bash time-bound') NOT found"
fi

if echo "${output_f}" | grep -qF "DOCTOR_STUB_SENTINEL_DGF"; then
  pass "DG-F: doctor sentinel still visible with portable time-bound engaged"
else
  fail "DG-F: doctor sentinel NOT visible with portable time-bound engaged"
fi

if echo "${output_f}" | grep -qF "Checking prerequisites"; then
  pass "DG-F: install still reaches 'Checking prerequisites' with portable time-bound engaged"
else
  fail "DG-F: install did NOT reach 'Checking prerequisites' with portable time-bound engaged"
fi

# ===========================================================================
# GROUP DG-G: portable time-bound actually fires (18-06). A doctor stub that
#   sleeps past a short ceiling. Assert the timeout is reported, the install
#   still continues, and — the load-bearing assertion — the elapsed wall
#   clock proves the 25s sleep was actually killed rather than waited out.
# ===========================================================================
echo ""
echo "--- GROUP DG-G: portable time-bound actually fires ---"

home_g="$(make_home)"
_dgg_start=$SECONDS
output_g=$(BOUNDED_RUN_FORCE_PORTABLE=1 \
    DOCTOR_TIMEOUT_SECONDS=2 \
    STUB_OPENCLAW_DOCTOR_SLEEP_SECONDS=25 \
    run_post_install "${home_g}") || true
_dgg_elapsed=$((SECONDS - _dgg_start))

if echo "${output_g}" | grep -qF "timed out after"; then
  pass "DG-G: timeout is reported ('timed out after')"
else
  fail "DG-G: 'timed out after' NOT found in output"
fi

if echo "${output_g}" | grep -qF "Checking prerequisites"; then
  pass "DG-G: install still reaches 'Checking prerequisites' after a portable-path timeout"
else
  fail "DG-G: install did NOT reach 'Checking prerequisites' after a portable-path timeout — a timeout must not abort the install"
fi

if [[ "${_dgg_elapsed}" -lt 15 ]]; then
  pass "DG-G: measured elapsed ${_dgg_elapsed}s is under 15s — the ceiling actually killed the 25s doctor"
else
  fail "DG-G: measured elapsed ${_dgg_elapsed}s is NOT under 15s — the ceiling did not actually kill the doctor (would pass against a fully unbounded call)"
fi

# ===========================================================================
# GROUP DG-H: portable path does not delay a fast doctor (18-06). Integration
#   guard against a watchdog holding the caller's command-substitution pipe.
# ===========================================================================
echo ""
echo "--- GROUP DG-H: portable path does not delay a fast doctor ---"

home_h="$(make_home)"
_dgh_start=$SECONDS
output_h=$(BOUNDED_RUN_FORCE_PORTABLE=1 \
    DOCTOR_TIMEOUT_SECONDS=30 \
    run_post_install "${home_h}") || true
_dgh_elapsed=$((SECONDS - _dgh_start))

if [[ "${_dgh_elapsed}" -lt 10 ]]; then
  pass "DG-H: measured elapsed ${_dgh_elapsed}s is under 10s — portable path did not delay a fast doctor"
else
  fail "DG-H: measured elapsed ${_dgh_elapsed}s is NOT under 10s — portable path delayed a fast doctor"
fi

if echo "${output_h}" | grep -qF "openclaw doctor --fix completed (exit 0)"; then
  pass "DG-H: doctor reported completed with exit 0, not a timeout"
else
  fail "DG-H: doctor did not report completed with exit 0"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
echo ""
echo "NOTE: This test FAILS RED before plan 18-02 Task 2 adds the version gate"
echo "      and run_openclaw_doctor to scripts/post-install.sh. Goes GREEN once"
echo "      Task 2 lands. GROUPs DG-A..DG-E: 5 groups, 11 assertions total."
echo "      GROUPs DG-F..DG-H (plan 18-06): 3 groups, 8 assertions — prove the"
echo "      doctor time-bound holds with no GNU 'timeout' on PATH, that a real"
echo "      ceiling expiry is observed (not merely reported), and that the"
echo "      portable path does not delay a fast doctor."
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
