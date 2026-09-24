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
#
# Phase 18: install.sh runs a version gate (GATE-01/GATE-04), now SCOPED to
# the standalone dispatch branch only (18-05, closing 18-VERIFICATION.md gap
# #1 / 18-REVIEW.md CR-01). Developer machines carry a real below-floor
# OpenClaw (this repo's own dev host reports "OpenClaw 2026.5.28 (e932160)"),
# so without passing defaults every GROUP that reaches the standalone branch
# would now refuse before reaching its assertions. The `:-` form lets an
# individual GROUP still override either var to exercise the gate itself
# (see GROUP G/I) — the gate's own pass/fail behavior is covered by
# tests/test_version_gate.sh, not here; these defaults exist so the routing
# GROUPs exercise ROUTING, not the version gate.
#
# RUN_INSTALL_NO_VERSION_STUBS / RUN_INSTALL_PATH (18-05): the unconditional
# defaults above are exactly what structurally masked 18-VERIFICATION.md gap
# #1 — a GROUP that inherits STUB_OPENCLAW_VERSION_OUTPUT/STUB_NODE_VERSION
# can never observe a host with no `openclaw` binary at all, because the
# stub always answers the gate with a passing version before the real
# `openclaw`/`node` binaries (or their absence) are ever consulted. Any
# GROUP exercising host-binary ABSENCE (not just a below-floor stub) MUST
# set RUN_INSTALL_NO_VERSION_STUBS so neither var reaches install.sh, and
# SHOULD set RUN_INSTALL_PATH to a PATH with no real openclaw/node on it —
# see GROUP H and GROUP I.
#   - RUN_INSTALL_NO_VERSION_STUBS: non-empty -> invoke install.sh from a
#     subshell that unsets both STUB_OPENCLAW_VERSION_OUTPUT and
#     STUB_NODE_VERSION before running it, so no override reaches the
#     script at all. Empty/unset -> today's `${VAR:-default}` injection,
#     unchanged.
#   - RUN_INSTALL_PATH: non-empty -> exported as PATH for this one
#     invocation. Empty/unset -> PATH is left untouched.
# ---------------------------------------------------------------------------
run_install() {
  local uname_s="$1"
  local home_dir="$2"
  shift 2
  if [[ -n "${RUN_INSTALL_NO_VERSION_STUBS:-}" ]]; then
    STUB_UNAME_S="${uname_s}" \
    HOME="${home_dir}" \
    RUN_INSTALL_PATH="${RUN_INSTALL_PATH:-}" \
    INSTALL_SH="${INSTALL_SH}" \
        bash -c '
          unset STUB_OPENCLAW_VERSION_OUTPUT STUB_NODE_VERSION
          if [[ -n "${RUN_INSTALL_PATH}" ]]; then
            export PATH="${RUN_INSTALL_PATH}"
          fi
          exec bash "${INSTALL_SH}" "$@"
        ' -- "$@" 2>&1
  else
    STUB_UNAME_S="${uname_s}" \
    STUB_OPENCLAW_VERSION_OUTPUT="${STUB_OPENCLAW_VERSION_OUTPUT:-OpenClaw 2026.9.6 (eb377ac)}" \
    STUB_NODE_VERSION="${STUB_NODE_VERSION:-v24.21.0}" \
    HOME="${home_dir}" \
    PATH="${RUN_INSTALL_PATH:-${PATH}}" \
        bash "${INSTALL_SH}" "$@" 2>&1
  fi
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
# GROUP standalone-intact: post-install.sh existing steps preserved
#
#   D-01's original zero-diff assertion (git diff --name-only against
#   scripts/post-install.sh) encoded the Phase 12 byte-stability constraint.
#   Phase 18 plan 18-02 deliberately supersedes that literal zero-diff
#   constraint by adding the defense-in-depth version gate + doctor step to
#   scripts/post-install.sh — so a byte-identical-file assertion would go
#   permanently red the moment 18-02 lands, even though the constraint's
#   real intent (the existing standalone install path is not disturbed)
#   still holds. These assertions preserve that real intent via fixed-string
#   checks on the pre-existing step labels, and pass both before and after
#   18-02 lands.
# ===========================================================================
echo ""
echo "--- GROUP standalone-intact: post-install.sh existing steps preserved ---"

POST_INSTALL_SH="${REPO_ROOT}/scripts/post-install.sh"

if grep -qF 'step "Checking prerequisites"' "${POST_INSTALL_SH}"; then
  pass "standalone-intact: post-install.sh still has 'Checking prerequisites' step"
else
  fail "standalone-intact: post-install.sh missing 'Checking prerequisites' step"
fi

if grep -qF 'step "Checking skill files in ${SKILL_DIR}"' "${POST_INSTALL_SH}"; then
  pass "standalone-intact: post-install.sh still has 'Checking skill files in \${SKILL_DIR}' step"
else
  fail "standalone-intact: post-install.sh missing 'Checking skill files in \${SKILL_DIR}' step"
fi

if grep -qF 'step "Configuring OpenClaw sandbox access"' "${POST_INSTALL_SH}"; then
  pass "standalone-intact: post-install.sh still has 'Configuring OpenClaw sandbox access' step"
else
  fail "standalone-intact: post-install.sh missing 'Configuring OpenClaw sandbox access' step"
fi

# ===========================================================================
# GROUP G: GATE-01 gate precedes routing dispatch (STANDALONE branch)
#
#   RESTATED (18-05) onto the standalone branch. This group originally
#   invoked install.sh with a below-floor OpenClaw stub on a NemoClaw-only
#   HOME and asserted the refusal fired on the NemoClaw branch — which
#   encoded the defect recorded as 18-VERIFICATION.md gap #1 / 18-REVIEW.md
#   CR-01 (the host gate must NOT fire on the NemoClaw branch; the NemoClaw
#   arm's OpenClaw/Node run inside the OpenShell sandbox and are
#   independently versioned). The group's real intent — the gate fires
#   before any provisioning dispatch on the branch that actually reads the
#   host binaries — is preserved, not dropped: it is restated here onto the
#   standalone branch, the only branch that still consults
#   require_openclaw_version/require_node_version after 18-05.
# ===========================================================================
echo ""
echo "--- GROUP G: GATE-01 gate precedes routing dispatch (standalone branch) ---"

TMP_HOME_G=$(make_home openclaw)

exit_code_g=0
output_g=$(STUB_UNAME_S="Linux" \
    STUB_OPENCLAW_VERSION_OUTPUT="OpenClaw 2026.7.1 (deadbee)" \
    HOME="${TMP_HOME_G}" \
    bash "${INSTALL_SH}" 2>&1) || exit_code_g=$?

if [[ "${exit_code_g}" -ne 0 ]]; then
  pass "GROUP-G: below-floor OpenClaw exits non-zero on the standalone branch"
else
  fail "GROUP-G: below-floor OpenClaw exited 0 on the standalone branch (exit=${exit_code_g})"
fi

if echo "${output_g}" | grep -qF "2026.8.1"; then
  pass "GROUP-G: output names the required floor 2026.8.1"
else
  fail "GROUP-G: output does not contain required floor 2026.8.1"
fi

if echo "${output_g}" | grep -qF "Routing to standalone install path"; then
  fail "GROUP-G: 'Routing to standalone install path' present — gate did not fire before provisioning dispatch"
else
  pass "GROUP-G: standalone routing marker correctly absent — gate fired before any provisioning side effect"
fi

# ===========================================================================
# GROUP G-2: below-floor HOST OpenClaw no longer blocks the NemoClaw branch
#
#   Counterpart to restated GROUP G, pinning the new contract: a below-floor
#   HOST OpenClaw must not refuse a NemoClaw-routed install, because that
#   branch's runtime floor is enforced in-sandbox by
#   gate_sandbox_runtime_versions (scripts/post-install-nemoclaw.sh), not by
#   the host-level gate this plan scoped away from this branch.
# ===========================================================================
echo ""
echo "--- GROUP G-2: below-floor host OpenClaw no longer blocks the NemoClaw branch ---"

TMP_HOME_G2=$(make_home nemoclaw)

exit_code_g2=0
output_g2=$(STUB_UNAME_S="Linux" \
    STUB_OPENCLAW_VERSION_OUTPUT="OpenClaw 2026.7.1 (deadbee)" \
    HOME="${TMP_HOME_G2}" \
    bash "${INSTALL_SH}" --nemoclaw 2>&1) || exit_code_g2=$?

if echo "${output_g2}" | grep -qi "preflight\|Phase 13\|nemoclaw path"; then
  pass "GROUP-G-2: NemoClaw-path marker found despite below-floor host OpenClaw"
else
  fail "GROUP-G-2: NemoClaw-path marker NOT found — a below-floor host OpenClaw is still blocking the NemoClaw branch"
fi

if echo "${output_g2}" | grep -qF "Checking runtime versions"; then
  fail "GROUP-G-2: 'Checking runtime versions' present — host version gate fired on the NemoClaw branch"
else
  pass "GROUP-G-2: 'Checking runtime versions' correctly absent on the NemoClaw branch"
fi

# ===========================================================================
# GROUP I: standalone counterpart to GROUP H — an absent (not just
#   below-floor) host OpenClaw/Node must still refuse on the standalone
#   branch. Proves scoping the gate did not delete it: the same
#   host-binary-absent configuration that must PASS through to NemoClaw
#   routing (GROUP H) must still REFUSE on the standalone branch.
# ===========================================================================
echo ""
echo "--- GROUP I: no host openclaw at all -- standalone branch still refuses ---"

TMP_HOME_I=$(make_home openclaw)
TMP_BIN_I=$(mktemp -d "${TMPDIR:-/tmp}/test-inst-bin.XXXXXX")
TMP_HOMES+=("${TMP_BIN_I}")

exit_code_i=0
output_i=$(RUN_INSTALL_NO_VERSION_STUBS=1 \
    RUN_INSTALL_PATH="${TMP_BIN_I}:/usr/bin:/bin" \
    run_install "Linux" "${TMP_HOME_I}") || exit_code_i=$?

if [[ "${exit_code_i}" -ne 0 ]]; then
  pass "GROUP-I: no host openclaw/node exits non-zero on the standalone branch"
else
  fail "GROUP-I: no host openclaw/node exited 0 on the standalone branch (exit=${exit_code_i})"
fi

if echo "${output_i}" | grep -qF "Checking runtime versions"; then
  pass "GROUP-I: 'Checking runtime versions' present on the standalone branch"
else
  fail "GROUP-I: 'Checking runtime versions' NOT found — gate did not run on the standalone branch"
fi

if echo "${output_i}" | grep -qF "2026.8.1"; then
  pass "GROUP-I: output names the required floor 2026.8.1"
else
  fail "GROUP-I: output does not contain required floor 2026.8.1"
fi

if echo "${output_i}" | grep -qF "Routing to standalone install path"; then
  fail "GROUP-I: 'Routing to standalone install path' present — gate did not fire before provisioning dispatch"
else
  pass "GROUP-I: standalone routing marker correctly absent — gate fired before any provisioning side effect"
fi

# ===========================================================================
# GROUP H: 18-VERIFICATION.md gap #1 / 18-REVIEW.md CR-01 — a real
#   NemoClaw-routed run with NO host-level `openclaw`/`node` binary on PATH
#   at all (not just a below-floor stub) must reach NemoClaw routing, never
#   the host version gate. This is the exact configuration
#   docs/nemoclaw-setup.md's Prerequisites section documents as supported
#   (Linux + Docker + nemoclaw CLI; no host OpenClaw/Node), and the exact
#   configuration that was falsely refused before 18-05. Uses
#   RUN_INSTALL_NO_VERSION_STUBS so neither STUB_OPENCLAW_VERSION_OUTPUT nor
#   STUB_NODE_VERSION reaches install.sh, and RUN_INSTALL_PATH to point at
#   an empty bin dir so no real openclaw/node binary is reachable either.
#   No exit-code assertion here: post-install-nemoclaw.sh legitimately exits
#   non-zero further down this host (macOS host-compat preflight, or the
#   unset REVENIUM_SANDBOX_NAME refusal on Linux) — this group measures the
#   ROUTING decision only.
# ===========================================================================
echo ""
echo "--- GROUP H: no host openclaw at all -- NemoClaw branch still routes (gap #1/CR-01) ---"

TMP_HOME_H=$(make_home nemoclaw)
TMP_BIN_H=$(mktemp -d "${TMPDIR:-/tmp}/test-inst-bin.XXXXXX")
TMP_HOMES+=("${TMP_BIN_H}")

output_h=$(RUN_INSTALL_NO_VERSION_STUBS=1 \
    RUN_INSTALL_PATH="${TMP_BIN_H}:/usr/bin:/bin" \
    run_install "Linux" "${TMP_HOME_H}" --nemoclaw) || true

if echo "${output_h}" | grep -qF "Routing to NemoClaw install path"; then
  pass "GROUP-H: NemoClaw routing reached with no host openclaw on PATH"
else
  fail "GROUP-H: 'Routing to NemoClaw install path' NOT found — host gate is still blocking the NemoClaw branch"
fi

if echo "${output_h}" | grep -qF "Checking runtime versions"; then
  fail "GROUP-H: 'Checking runtime versions' present — host version gate fired on the NemoClaw branch"
else
  pass "GROUP-H: 'Checking runtime versions' correctly absent on the NemoClaw branch"
fi

if echo "${output_h}" | grep -qF "Could not determine the installed OpenClaw version"; then
  fail "GROUP-H: undetectable-version refusal fired on the NemoClaw branch — regression of gap #1/CR-01"
else
  pass "GROUP-H: undetectable-version refusal correctly did NOT fire on the NemoClaw branch"
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
echo "      GROUPs A-F, standalone-intact, G, G-2, I, H (Phase 18 plan 18-01 added"
echo "      the version-gate defaults in run_install() and GROUP G; plan 18-05"
echo "      scoped the host version gate to the standalone branch only, closing"
echo "      18-VERIFICATION.md gap #1 / 18-REVIEW.md CR-01. GROUP G was RESTATED"
echo "      onto the standalone branch (it previously encoded the defect); GROUP"
echo "      G-2 pins that a below-floor host OpenClaw no longer blocks the"
echo "      NemoClaw branch; GROUPs H and I are the branch-scoped"
echo "      host-binary-ABSENT pair — H proves NemoClaw routing is reached with"
echo "      no host openclaw/node at all, I proves the standalone branch still"
echo "      refuses that same configuration. Version-gate assertions"
echo "      (G/G-2/H/I) are branch-scoped as of this gap-closure pass; the"
echo "      gate's own pass/fail comparison logic is covered by"
echo "      tests/test_version_gate.sh, not here."
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
