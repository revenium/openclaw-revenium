#!/usr/bin/env bash
# =============================================================================
# test_version_gate.sh — Hermetic tests for scripts/version-gate.sh
# Covers: GATE-01 (OpenClaw floor refusal), GATE-02 (numeric CalVer
#         comparison), GATE-04 (Node floor refusal, added in plan 18-01 Task 2)
#
# Strategy:
#   GROUP VG-A/VG-E: source scripts/version-gate.sh directly in a subshell and
#     unit-test the comparison functions (version_ge / node_version_ok).
#   GROUP VG-B/VG-C/VG-D/VG-F: invoke scripts/install.sh end-to-end with
#     STUB_OPENCLAW_VERSION_OUTPUT / STUB_NODE_VERSION overrides and mktemp -d
#     HOME isolation, and assert on exit code + combined output.
#
# EXPECTED RESULT BEFORE PLAN 18-01 TASK 1:
#   This test FAILS RED — scripts/version-gate.sh does not yet exist and
#   scripts/install.sh has no version gate wired in. Exits non-zero with
#   FAIL > 0. Goes GREEN when Task 1 creates scripts/version-gate.sh and wires
#   require_openclaw_version into install.sh (GROUPs VG-A..VG-D). GROUPs VG-E
#   and VG-F (node_version_ok / require_node_version) go GREEN when Task 2
#   extends the gate to the Node floor.
#   Do NOT stub version-gate.sh or weaken assertions to make it pass now.
#
# NOTE (expected totals): 9+ passed after Task 1 (VG-A..VG-D); 19+ passed
#   after Task 2 (VG-A..VG-F).
#
# SECURITY: This test never eval's or string-interpolates captured output
#   into shell commands. No real openclaw or node binary is required — every
#   assertion runs through the STUB_OPENCLAW_VERSION_OUTPUT / STUB_NODE_VERSION
#   env-var overrides.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/scripts/install.sh"
VERSION_GATE_SH="${REPO_ROOT}/scripts/version-gate.sh"

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
# ---------------------------------------------------------------------------
make_home() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-vgate.XXXXXX")
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
# Guard: scripts/version-gate.sh must exist for GROUP VG-A to source.
# ---------------------------------------------------------------------------
if [[ ! -f "${VERSION_GATE_SH}" ]]; then
  echo ""
  echo "=== VERSION-GATE.SH MISSING ==="
  echo "scripts/version-gate.sh does not exist yet (Task 1 creates it)."
  echo "All GROUPs will FAIL — this is the expected RED state."
  echo ""
fi

# ===========================================================================
# GROUP VG-A: GATE-02 version_ge direct unit (numeric CalVer comparison)
# ===========================================================================
echo ""
echo "--- GROUP VG-A: GATE-02 version_ge direct unit (numeric CalVer comparison) ---"

if (. "${VERSION_GATE_SH}" 2>/dev/null; version_ge "2026.9.6" "2026.8.1"); then
  pass "VG-A: version_ge 2026.9.6 2026.8.1 returns 0 (passing case)"
else
  fail "VG-A: version_ge 2026.9.6 2026.8.1 should return 0"
fi

if (. "${VERSION_GATE_SH}" 2>/dev/null; version_ge "2026.8.9" "2026.8.10"); then
  fail "VG-A: version_ge 2026.8.9 2026.8.10 should return non-zero (adversarial CalVer trap)"
else
  pass "VG-A: version_ge 2026.8.9 2026.8.10 correctly returns non-zero"
fi

if (. "${VERSION_GATE_SH}" 2>/dev/null; version_ge "2026.8.1" "2026.8.1"); then
  pass "VG-A: version_ge 2026.8.1 2026.8.1 (exact equality) returns 0"
else
  fail "VG-A: version_ge 2026.8.1 2026.8.1 should return 0"
fi

if (. "${VERSION_GATE_SH}" 2>/dev/null; version_ge "" "2026.8.1"); then
  fail "VG-A: version_ge \"\" 2026.8.1 should return non-zero (empty fails closed)"
else
  pass "VG-A: version_ge \"\" 2026.8.1 correctly returns non-zero"
fi

# ===========================================================================
# GROUP VG-B: GATE-01 end-to-end refusal — below-floor OpenClaw
# ===========================================================================
echo ""
echo "--- GROUP VG-B: GATE-01 end-to-end refusal below floor OpenClaw ---"

TMP_HOME_VGB=$(make_home openclaw)
exit_code_vgb=0
output_vgb=$(STUB_OPENCLAW_VERSION_OUTPUT="OpenClaw 2026.7.1 (deadbee)" HOME="${TMP_HOME_VGB}" \
    bash "${INSTALL_SH}" 2>&1) || exit_code_vgb=$?

if [[ "${exit_code_vgb}" -ne 0 ]]; then
  pass "VG-B: install.sh exits non-zero on below-floor OpenClaw"
else
  fail "VG-B: install.sh exited 0 on below-floor OpenClaw (exit=${exit_code_vgb})"
fi

if echo "${output_vgb}" | grep -qF "2026.7.1"; then
  pass "VG-B: output names the detected version 2026.7.1"
else
  fail "VG-B: output does not contain detected version 2026.7.1"
fi

if echo "${output_vgb}" | grep -qF "2026.8.1"; then
  pass "VG-B: output names the required floor 2026.8.1"
else
  fail "VG-B: output does not contain required floor 2026.8.1"
fi

if echo "${output_vgb}" | grep -qF "Routing to standalone install path"; then
  fail "VG-B: output reached routing dispatch — gate did not stop install before dispatch"
else
  pass "VG-B: output does not reach routing dispatch (gate fired first)"
fi

# ===========================================================================
# GROUP VG-C: GATE-01 empty-input edge — no parseable openclaw --version output
# ===========================================================================
echo ""
echo "--- GROUP VG-C: GATE-01 empty-input edge (no parseable version output) ---"

TMP_HOME_VGC=$(make_home openclaw)
exit_code_vgc=0
output_vgc=$(STUB_OPENCLAW_VERSION_OUTPUT=" " HOME="${TMP_HOME_VGC}" \
    bash "${INSTALL_SH}" 2>&1) || exit_code_vgc=$?

if [[ "${exit_code_vgc}" -ne 0 ]]; then
  pass "VG-C: install.sh exits non-zero when openclaw --version yields no parseable output"
else
  fail "VG-C: install.sh exited 0 with empty detected version (exit=${exit_code_vgc})"
fi

if echo "${output_vgc}" | grep -qF "2026.8.1"; then
  pass "VG-C: output names the required floor 2026.8.1 on empty-detected refusal"
else
  fail "VG-C: output does not contain required floor 2026.8.1 on empty-detected refusal"
fi

# ===========================================================================
# GROUP VG-D: GATE-01 passing case reaches routing dispatch
# ===========================================================================
echo ""
echo "--- GROUP VG-D: GATE-01 passing case reaches routing dispatch ---"

TMP_HOME_VGD=$(make_home openclaw)
exit_code_vgd=0
output_vgd=$(STUB_OPENCLAW_VERSION_OUTPUT="OpenClaw 2026.9.6 (eb377ac)" HOME="${TMP_HOME_VGD}" \
    bash "${INSTALL_SH}" 2>&1) || exit_code_vgd=$?

if echo "${output_vgd}" | grep -qF "Routing to standalone install path"; then
  pass "VG-D: passing OpenClaw version reaches routing dispatch"
else
  fail "VG-D: passing OpenClaw version did not reach routing dispatch (exit=${exit_code_vgd})"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
echo ""
echo "NOTE: This test FAILS RED before Task 1 creates scripts/version-gate.sh."
echo "      GROUPs VG-E/VG-F (GATE-04, Node floor) are added by Task 2."
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
