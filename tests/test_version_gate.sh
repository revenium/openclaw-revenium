#!/usr/bin/env bash
# =============================================================================
# test_version_gate.sh — Hermetic tests for scripts/version-gate.sh
# Covers: GATE-01 (OpenClaw floor refusal), GATE-02 (numeric CalVer
#         comparison), GATE-04 (Node floor refusal, added in plan 18-01 Task 2),
#         READ-04 (sqlite3 CLI presence gate, added in plan 19-02)
#
# Strategy:
#   GROUP VG-A/VG-E: source scripts/version-gate.sh directly in a subshell and
#     unit-test the comparison functions (version_ge / node_version_ok).
#   GROUP VG-B/VG-C/VG-D/VG-F: invoke scripts/install.sh end-to-end with
#     STUB_OPENCLAW_VERSION_OUTPUT / STUB_NODE_VERSION overrides and mktemp -d
#     HOME isolation, and assert on exit code + combined output.
#   GROUP VG-G: source scripts/version-gate.sh directly in a subshell and
#     unit-test require_sqlite3 / sqlite3_detected. The absent-binary case
#     uses a restricted PATH (a tmp bin dir holding only symlinked grep/head)
#     rather than relying on the host lacking sqlite3 — unlike openclaw/node,
#     sqlite3 is commonly present on both dev machines and CI images, so the
#     STUB-only idiom used by VG-B..VG-D would not actually exercise the
#     absent-binary path. The present-binary case uses
#     STUB_SQLITE3_VERSION_OUTPUT instead, mirroring VG-A..VG-F.
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
# EXPECTED RESULT BEFORE PLAN 19-02 TASK 2:
#   GROUP VG-G is RED — require_sqlite3/sqlite3_detected do not exist yet in
#   scripts/version-gate.sh. Goes GREEN when Task 2 adds them and wires
#   require_sqlite3 into both scripts/post-install.sh and
#   scripts/post-install-nemoclaw.sh.
#
# NOTE (expected totals): 9+ passed after Task 1 (VG-A..VG-D); 19+ passed
#   after Task 2 (VG-A..VG-F); 21 passed with GROUP VG-G RED (plan 19-02
#   Task 1); 30 passed, 0 failed once GROUP VG-G goes GREEN (plan 19-02
#   Task 2).
#
# SECURITY: This test never eval's or string-interpolates captured output
#   into shell commands. No real openclaw or node binary is required — every
#   assertion runs through the STUB_OPENCLAW_VERSION_OUTPUT / STUB_NODE_VERSION
#   env-var overrides. GROUP VG-G's restricted-PATH tmp dir holds only
#   symlinks to real, already-resolved system binaries (grep/head) — no
#   downloaded or fabricated binaries are placed on PATH.
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
# GROUP VG-E: GATE-04 node_version_ok direct unit
# ===========================================================================
echo ""
echo "--- GROUP VG-E: GATE-04 node_version_ok direct unit ---"

if (. "${VERSION_GATE_SH}" 2>/dev/null; node_version_ok "v24.21.0"); then
  pass "VG-E: node_version_ok v24.21.0 returns 0"
else
  fail "VG-E: node_version_ok v24.21.0 should return 0"
fi

if (. "${VERSION_GATE_SH}" 2>/dev/null; node_version_ok "v24.15.9"); then
  fail "VG-E: node_version_ok v24.15.9 should return non-zero (below 24.16.0)"
else
  pass "VG-E: node_version_ok v24.15.9 correctly returns non-zero"
fi

if (. "${VERSION_GATE_SH}" 2>/dev/null; node_version_ok "v25.0.0"); then
  fail "VG-E: node_version_ok v25.0.0 should return non-zero (excluded major)"
else
  pass "VG-E: node_version_ok v25.0.0 correctly returns non-zero"
fi

if (. "${VERSION_GATE_SH}" 2>/dev/null; node_version_ok "v26.0.9"); then
  fail "VG-E: node_version_ok v26.0.9 should return non-zero (below 26.1.0)"
else
  pass "VG-E: node_version_ok v26.0.9 correctly returns non-zero"
fi

if (. "${VERSION_GATE_SH}" 2>/dev/null; node_version_ok "v26.1.0"); then
  pass "VG-E: node_version_ok v26.1.0 returns 0"
else
  fail "VG-E: node_version_ok v26.1.0 should return 0"
fi

if (. "${VERSION_GATE_SH}" 2>/dev/null; node_version_ok "v23.11.0"); then
  fail "VG-E: node_version_ok v23.11.0 should return non-zero (major below 24)"
else
  pass "VG-E: node_version_ok v23.11.0 correctly returns non-zero"
fi

# ===========================================================================
# GROUP VG-F: GATE-04 end-to-end refusal — below-floor Node
# ===========================================================================
echo ""
echo "--- GROUP VG-F: GATE-04 end-to-end refusal below floor Node ---"

TMP_HOME_VGF=$(make_home openclaw)
exit_code_vgf=0
output_vgf=$(STUB_OPENCLAW_VERSION_OUTPUT="OpenClaw 2026.9.6 (eb377ac)" \
    STUB_NODE_VERSION="v22.14.0" HOME="${TMP_HOME_VGF}" \
    bash "${INSTALL_SH}" 2>&1) || exit_code_vgf=$?

if [[ "${exit_code_vgf}" -ne 0 ]]; then
  pass "VG-F: install.sh exits non-zero on below-floor Node"
else
  fail "VG-F: install.sh exited 0 on below-floor Node (exit=${exit_code_vgf})"
fi

if echo "${output_vgf}" | grep -qF "v22.14.0"; then
  pass "VG-F: output names the detected Node version v22.14.0"
else
  fail "VG-F: output does not contain detected Node version v22.14.0"
fi

if echo "${output_vgf}" | grep -qF ">=24.16.0 <25.0.0, or >=26.1.0"; then
  pass "VG-F: output names the required Node range"
else
  fail "VG-F: output does not contain the required Node range"
fi

if echo "${output_vgf}" | grep -qF "Routing to standalone install path"; then
  fail "VG-F: output reached routing dispatch — Node gate did not stop install before dispatch"
else
  pass "VG-F: output does not reach routing dispatch (Node gate fired first)"
fi

# ===========================================================================
# GROUP VG-G: READ-04 sqlite3 dependency gate (require_sqlite3/sqlite3_detected)
# ===========================================================================
echo ""
echo "--- GROUP VG-G: READ-04 sqlite3 dependency gate ---"

# Restricted PATH containing only the binaries the gate legitimately needs
# (grep, head — used internally by sqlite3_detected's extraction pipeline).
# Deliberately excludes sqlite3 itself so the absent-binary case is genuine
# even on hosts (like this dev machine, and many CI images) that have a real
# sqlite3 CLI reachable on the normal PATH.
TMP_BIN_VGG=$(mktemp -d "${TMPDIR:-/tmp}/test-vgate-bin.XXXXXX")
TMP_HOMES+=("${TMP_BIN_VGG}")
for _vgg_bin in grep head; do
  _vgg_real="$(command -v "${_vgg_bin}" 2>/dev/null || true)"
  [[ -n "${_vgg_real}" ]] && ln -sf "${_vgg_real}" "${TMP_BIN_VGG}/${_vgg_bin}"
done
# Resolve bash's own absolute path BEFORE restricting PATH below — a bare
# "bash" word in the PATH-prefixed invocation would itself fail to resolve
# once PATH points only at TMP_BIN_VGG (bash is not one of the two binaries
# symlinked into it), independent of whether sqlite3 is present.
BASH_BIN_VGG="$(command -v bash)"

# --- Absent case: require_sqlite3 refuses (non-zero exit, actionable message) ---
rc_vgg1=0
out_vgg1=$(PATH="${TMP_BIN_VGG}" "${BASH_BIN_VGG}" -c ". ${VERSION_GATE_SH} 2>/dev/null; require_sqlite3" 2>&1) || rc_vgg1=$?

if [[ "${rc_vgg1}" -ne 0 ]]; then
  pass "VG-G: require_sqlite3 exits non-zero when sqlite3 is absent from PATH"
else
  fail "VG-G: require_sqlite3 exited 0 with sqlite3 absent from PATH"
fi

if echo "${out_vgg1}" | grep -qi "sqlite3"; then
  pass "VG-G: refusal message names sqlite3"
else
  fail "VG-G: refusal message does not name sqlite3"
fi

if echo "${out_vgg1}" | grep -qiE "session store|metering"; then
  pass "VG-G: refusal message names the reason (session store / metering read path)"
else
  fail "VG-G: refusal message does not explain why sqlite3 is needed (mentions sqlite3)"
fi

if echo "${out_vgg1}" | grep -qiE "apt(-get)? install"; then
  pass "VG-G: refusal message carries an apt-style install command"
else
  fail "VG-G: refusal message missing an apt-style install command (mentions sqlite3)"
fi

if echo "${out_vgg1}" | grep -qiE "brew install"; then
  pass "VG-G: refusal message carries a Homebrew-style install command"
else
  fail "VG-G: refusal message missing a Homebrew-style install command (mentions sqlite3)"
fi

# --- Present case (via STUB override — no PATH restriction needed) ---
rc_vgg3=0
stdout_vgg3=$( (. "${VERSION_GATE_SH}" 2>/dev/null; STUB_SQLITE3_VERSION_OUTPUT="3.46.1" require_sqlite3) 2>/dev/null ) || rc_vgg3=$?

if [[ "${rc_vgg3}" -eq 0 ]]; then
  pass "VG-G: require_sqlite3 returns 0 when sqlite3 is present (STUB_SQLITE3_VERSION_OUTPUT)"
else
  fail "VG-G: require_sqlite3 returned non-zero (${rc_vgg3}) with sqlite3 present (STUB_SQLITE3_VERSION_OUTPUT, sqlite3)"
fi

if [[ -z "${stdout_vgg3}" ]]; then
  pass "VG-G: require_sqlite3 prints nothing to stdout when sqlite3 is present"
else
  fail "VG-G: require_sqlite3 printed to stdout when sqlite3 is present (sqlite3): '${stdout_vgg3}'"
fi

# --- sqlite3_detected: STUB override honored, stdout purity (no stderr contamination) ---
STDERR_FILE_VGG=$(mktemp "${TMPDIR:-/tmp}/test-vgate-stderr.XXXXXX")
TMP_HOMES+=("${STDERR_FILE_VGG}")
detected_vgg=$( (. "${VERSION_GATE_SH}" 2>/dev/null; STUB_SQLITE3_VERSION_OUTPUT="3.46.1" sqlite3_detected) 2>"${STDERR_FILE_VGG}" )
stderr_vgg="$(cat "${STDERR_FILE_VGG}" 2>/dev/null || true)"

if [[ "${detected_vgg}" == "3.46.1" ]]; then
  pass "VG-G: sqlite3_detected honors STUB_SQLITE3_VERSION_OUTPUT and returns exactly '3.46.1' on stdout"
else
  fail "VG-G: sqlite3_detected with STUB_SQLITE3_VERSION_OUTPUT returned '${detected_vgg}' (sqlite3), expected '3.46.1'"
fi

if echo "${stderr_vgg}" | grep -qi "STUB_SQLITE3_VERSION_OUTPUT"; then
  pass "VG-G: sqlite3_detected warns to stderr when the STUB override is in effect"
else
  fail "VG-G: sqlite3_detected did not warn to stderr about the STUB_SQLITE3_VERSION_OUTPUT override (sqlite3)"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
echo ""
echo "NOTE: expected total after Task 1+2: 19+ passed (VG-A..VG-F), 0 failed."
echo "NOTE: expected total after plan 19-02: 30 passed (VG-A..VG-G), 0 failed."
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
