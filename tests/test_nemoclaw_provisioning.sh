#!/usr/bin/env bash
# =============================================================================
# test_nemoclaw_provisioning.sh — Hermetic tests for post-install-nemoclaw.sh
# provisioning functions (NCEGRESS-01, NCCLI-01, NCCLI-02)
#
# Strategy:
#   Symlink tests/stub-nemoclaw.sh as `nemoclaw` onto a tmp .local/bin PATH,
#   prepended so it intercepts all nemoclaw invocations.
#   Override LEDGER_FILE, HOME, REVENIUM_SANDBOX_NAME, REVENIUM_API_KEY via env.
#   Capture combined stdout+stderr from scripts/post-install-nemoclaw.sh.
#   Assert against output and ledger contents with grep -qi / grep -qF.
#
# GROUP map → requirement:
#   GROUP A: NCEGRESS-01 SC2 — proxy block (HTTP=000) → policy-gap error
#   GROUP B: NCEGRESS-01 SC2 — open egress (HTTP=403) → egress confirmed
#   GROUP C: NCCLI-01       — sha256 mismatch → install aborted non-zero
#   GROUP D: NCCLI-01       — sha256 match   → CLI delivered, ledger updated
#   GROUP E: NCCLI-01       — cli-delivered already in ledger → skip
#   GROUP F: NCCLI-02       — meter-probe-passed in ledger → probe skipped
#   GROUP G: all SC         — full success run → all 5 ledger keys present
#
# EXPECTED RESULT BEFORE PLAN 02:
#   This test runs and produces a "Results:" summary, but MOST GROUPs will
#   FAIL — scripts/post-install-nemoclaw.sh only has Phase 12 stubs (no real
#   provisioning functions). That RED state is correct for Wave 0 (Plan 01).
#   The harness goes GREEN when Plan 02 implements the provisioning functions.
#   Do NOT weaken assertions to make groups pass before Plan 02.
#
# SECURITY: This test never `eval`s or string-interpolates captured output
#   into shell commands. Assertions use grep -qF (fixed-string) or grep -qi.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROVISION_SH="${REPO_ROOT}/scripts/post-install-nemoclaw.sh"
STUB_SH="${SCRIPT_DIR}/stub-nemoclaw.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# ---------------------------------------------------------------------------
# Cleanup: track all tmp HOMEs and clean up on exit
# ---------------------------------------------------------------------------
declare -a TMP_HOMES=()

cleanup() {
  for d in "${TMP_HOMES[@]+"${TMP_HOMES[@]}"}"; do
    rm -rf "${d}" 2>/dev/null || true
  done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Guard: required files must exist
# ---------------------------------------------------------------------------
if [[ ! -f "${PROVISION_SH}" ]]; then
  echo ""
  echo "=== PROVISION SCRIPT MISSING ==="
  echo "scripts/post-install-nemoclaw.sh does not exist."
  fail "provision-script-exists: ${PROVISION_SH} not found"
fi

if [[ ! -f "${STUB_SH}" ]]; then
  echo ""
  echo "=== STUB MISSING ==="
  echo "tests/stub-nemoclaw.sh does not exist."
  fail "stub-nemoclaw-exists: ${STUB_SH} not found"
fi

# ---------------------------------------------------------------------------
# make_home — create an isolated tmp HOME with .nemoclaw/ and stub on PATH
#
#   Creates:
#     <home>/.nemoclaw/         — ledger directory
#     <home>/.local/bin/        — tmp PATH dir with nemoclaw symlink
#     <home>/.local/bin/nemoclaw — symlink to stub-nemoclaw.sh
#   Returns: the home path (printed to stdout)
# ---------------------------------------------------------------------------
make_home() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-nemo-prov.XXXXXX")
  TMP_HOMES+=("${d}")
  mkdir -p "${d}/.nemoclaw" "${d}/.local/bin"
  # Symlink stub-nemoclaw.sh as `nemoclaw` onto the tmp PATH
  ln -sf "${SCRIPT_DIR}/stub-nemoclaw.sh" "${d}/.local/bin/nemoclaw"
  # Create a stub probe-host-compat.sh that always passes.
  # The real probe gates hard on the OS (Linux-only), which blocks testing on
  # macOS dev machines. PROBE_SCRIPT is overridden in run_provision() to point
  # here, so production runs continue to use the real probe-host-compat.sh.
  cat > "${d}/stub-probe-host-compat.sh" << 'EOF'
#!/usr/bin/env bash
echo "  ✓ [stub] host compatibility preflight passed (test mode)"
exit 0
EOF
  chmod +x "${d}/stub-probe-host-compat.sh"
  echo "${d}"
}

# ---------------------------------------------------------------------------
# run_provision <home> <argv_file> [stub_env...]
#   Invoke scripts/post-install-nemoclaw.sh with stub nemoclaw on PATH and
#   isolated HOME/ledger/sandbox env. Captures combined stdout+stderr.
#   Extra stub env vars (STUB_NEMOCLAW_*) are passed as prefixed env.
# ---------------------------------------------------------------------------
run_provision() {
  local home_dir="$1"
  local argv_file="$2"
  shift 2

  # Build ledger path and standard env
  local ledger_file="${home_dir}/.nemoclaw/revenium-nemoclaw.ledger"
  # Override PROBE_SCRIPT to use the stub probe created in make_home().
  # This allows the hermetic tests to run on macOS dev machines where the real
  # probe-host-compat.sh would fail the OS gate (Linux-only). Production runs
  # are always invoked via install.sh on Linux — the real probe runs there.
  local stub_probe="${home_dir}/stub-probe-host-compat.sh"

  STUB_NEMOCLAW_ARGV_FILE="${argv_file}" \
  LEDGER_FILE="${ledger_file}" \
  HOME="${home_dir}" \
  PATH="${home_dir}/.local/bin:${PATH}" \
  REVENIUM_SANDBOX_NAME="${REVENIUM_SANDBOX_NAME:-test-sandbox}" \
  REVENIUM_API_KEY="${REVENIUM_API_KEY:-test-key}" \
  PROBE_SCRIPT="${stub_probe}" \
  "$@" \
  bash "${PROVISION_SH}" 2>&1
}

# ===========================================================================
# GROUP A: NCEGRESS-01 SC2 — proxy block
#   STUB_NEMOCLAW_CURL_HTTP_CODE=000 → output contains "api.revenium.ai"
#   AND "policy" (policy-gap message); run exits non-zero.
# ===========================================================================
echo ""
echo "--- GROUP A: NCEGRESS-01 SC2 proxy block (HTTP=000 → policy-gap error) ---"

TMP_HOME_A=$(make_home)
ARGV_A=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-a.XXXXXX")
TMP_HOMES+=("${ARGV_A}")

exit_code_a=0
output_a=$(STUB_NEMOCLAW_CURL_HTTP_CODE=000 \
           run_provision "${TMP_HOME_A}" "${ARGV_A}" 2>&1) || exit_code_a=$?

# Assert: output mentions api.revenium.ai
if echo "${output_a}" | grep -qi "api.revenium.ai"; then
  pass "GROUP-A: output mentions api.revenium.ai on proxy block"
else
  fail "GROUP-A: api.revenium.ai NOT in output on proxy block (Phase 12 stub active — expected RED)"
fi

# Assert: output mentions "policy"
if echo "${output_a}" | grep -qi "policy"; then
  pass "GROUP-A: output mentions 'policy' on proxy block (policy-gap message)"
else
  fail "GROUP-A: 'policy' NOT in output on proxy block (provisioning not yet implemented)"
fi

# Assert: run exits non-zero
if [[ "${exit_code_a}" -ne 0 ]]; then
  pass "GROUP-A: run exits non-zero on proxy block"
else
  fail "GROUP-A: run exited 0 on proxy block — expected non-zero (install should abort)"
fi

# ===========================================================================
# GROUP B: NCEGRESS-01 SC2 — open egress
#   STUB_NEMOCLAW_CURL_HTTP_CODE=403 (default) → output does NOT contain the
#   policy-gap failure wording; egress is reported confirmed.
# ===========================================================================
echo ""
echo "--- GROUP B: NCEGRESS-01 SC2 open egress (HTTP=403 → egress confirmed) ---"

TMP_HOME_B=$(make_home)
ARGV_B=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-b.XXXXXX")
TMP_HOMES+=("${ARGV_B}")

exit_code_b=0
output_b=$(STUB_NEMOCLAW_CURL_HTTP_CODE=403 \
           run_provision "${TMP_HOME_B}" "${ARGV_B}" 2>&1) || exit_code_b=$?

# Assert: output does NOT contain the policy-gap failure wording on open egress
if echo "${output_b}" | grep -qi "policy gap\|policy-gap\|cannot reach api.revenium.ai"; then
  fail "GROUP-B: policy-gap failure wording present — should NOT fire on HTTP=403 (open egress)"
else
  pass "GROUP-B: policy-gap failure wording correctly absent on HTTP=403"
fi

# Assert: output mentions egress confirmed
if echo "${output_b}" | grep -qi "egress\|confirmed\|api.revenium.ai"; then
  pass "GROUP-B: output mentions egress confirmation (api.revenium.ai or 'confirmed')"
else
  fail "GROUP-B: egress confirmation NOT in output on HTTP=403 (provisioning not yet implemented)"
fi

# ===========================================================================
# GROUP C: NCCLI-01 — sha256 mismatch aborts install
#   STUB_NEMOCLAW_SHA256_MATCH=0 → output contains "sha256"/"checksum"
#   mismatch wording; run exits non-zero.
# ===========================================================================
echo ""
echo "--- GROUP C: NCCLI-01 sha256 mismatch → install aborted ---"

TMP_HOME_C=$(make_home)
ARGV_C=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-c.XXXXXX")
TMP_HOMES+=("${ARGV_C}")

exit_code_c=0
output_c=$(STUB_NEMOCLAW_SHA256_MATCH=0 \
           run_provision "${TMP_HOME_C}" "${ARGV_C}" 2>&1) || exit_code_c=$?

# Assert: output mentions sha256 or checksum mismatch
if echo "${output_c}" | grep -qi "sha256\|checksum\|mismatch"; then
  pass "GROUP-C: output contains sha256/checksum mismatch wording"
else
  fail "GROUP-C: sha256/checksum mismatch wording NOT in output (provisioning not yet implemented)"
fi

# Assert: run exits non-zero
if [[ "${exit_code_c}" -ne 0 ]]; then
  pass "GROUP-C: run exits non-zero on sha256 mismatch"
else
  fail "GROUP-C: run exited 0 on sha256 mismatch — expected non-zero (install should abort)"
fi

# ===========================================================================
# GROUP D: NCCLI-01 — sha256 match → CLI delivery proceeds; ledger updated
#   STUB_NEMOCLAW_SHA256_MATCH=1 (default) → CLI delivery proceeds;
#   ledger gains cli-delivered entry.
# ===========================================================================
echo ""
echo "--- GROUP D: NCCLI-01 sha256 match → CLI delivered, ledger updated ---"

TMP_HOME_D=$(make_home)
ARGV_D=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-d.XXXXXX")
TMP_HOMES+=("${ARGV_D}")
LEDGER_D="${TMP_HOME_D}/.nemoclaw/revenium-nemoclaw.ledger"

exit_code_d=0
output_d=$(STUB_NEMOCLAW_SHA256_MATCH=1 \
           run_provision "${TMP_HOME_D}" "${ARGV_D}" 2>&1) || exit_code_d=$?

# Assert: ledger gains cli-delivered entry
if [[ -f "${LEDGER_D}" ]] && grep -qF 'cli-delivered' "${LEDGER_D}" 2>/dev/null; then
  pass "GROUP-D: ledger contains cli-delivered entry after sha256-match delivery"
else
  fail "GROUP-D: ledger does NOT contain cli-delivered (provisioning not yet implemented)"
fi

# ===========================================================================
# GROUP E: NCCLI-01 — cli-delivered already in ledger → re-run skips delivery
#   Pre-populate LEDGER_FILE with cli-delivered=v1.2.0:<sha256>;
#   re-run should skip delivery (output mentions "skipping" for CLI step).
# ===========================================================================
echo ""
echo "--- GROUP E: NCCLI-01 cli-delivered in ledger → skips delivery ---"

TMP_HOME_E=$(make_home)
ARGV_E=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-e.XXXXXX")
TMP_HOMES+=("${ARGV_E}")
LEDGER_E="${TMP_HOME_E}/.nemoclaw/revenium-nemoclaw.ledger"

# Pre-populate ledger with cli-delivered
echo "cli-delivered=v1.2.0:cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67" \
  > "${LEDGER_E}"

exit_code_e=0
output_e=$(run_provision "${TMP_HOME_E}" "${ARGV_E}" 2>&1) || exit_code_e=$?

# Assert: output mentions skipping for the CLI delivery step
if echo "${output_e}" | grep -qi "skip"; then
  pass "GROUP-E: output mentions 'skipping' when cli-delivered already in ledger"
else
  fail "GROUP-E: 'skipping' NOT in output with cli-delivered pre-populated (provisioning not yet implemented)"
fi

# ===========================================================================
# GROUP F: NCCLI-02 — meter-probe-passed in ledger → probe skipped
#   Pre-populate LEDGER_FILE with meter-probe-passed=1;
#   re-run should not emit a new meter-completion exec in ARGV_FILE.
# ===========================================================================
echo ""
echo "--- GROUP F: NCCLI-02 meter-probe-passed in ledger → probe skipped ---"

TMP_HOME_F=$(make_home)
ARGV_F=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-f.XXXXXX")
TMP_HOMES+=("${ARGV_F}")
LEDGER_F="${TMP_HOME_F}/.nemoclaw/revenium-nemoclaw.ledger"

# Pre-populate ledger with meter-probe-passed
echo "meter-probe-passed=1" > "${LEDGER_F}"

exit_code_f=0
output_f=$(run_provision "${TMP_HOME_F}" "${ARGV_F}" 2>&1) || exit_code_f=$?

# Assert: no new meter completion exec captured in ARGV_FILE for this run
# (meter completion would appear as "meter" AND "completion" in the argv file)
if [[ -f "${ARGV_F}" ]] && grep -qF "meter" "${ARGV_F}" 2>/dev/null && \
   grep -qF "completion" "${ARGV_F}" 2>/dev/null; then
  fail "GROUP-F: meter completion args found in ARGV_FILE — probe should be skipped when ledger key present"
else
  pass "GROUP-F: no meter completion exec in ARGV_FILE when meter-probe-passed pre-populated in ledger"
fi

# ===========================================================================
# GROUP G: all SC — full success run → all five ledger keys present
#   All switches default/success; after a full run the ledger should contain
#   all five keys: revenium-policy-applied, gh-release-policy-applied,
#   cli-delivered, creds-written, meter-probe-passed.
# ===========================================================================
echo ""
echo "--- GROUP G: all SC full success run → all 5 ledger keys ---"

TMP_HOME_G=$(make_home)
ARGV_G=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-g.XXXXXX")
TMP_HOMES+=("${ARGV_G}")
LEDGER_G="${TMP_HOME_G}/.nemoclaw/revenium-nemoclaw.ledger"

exit_code_g=0
output_g=$(run_provision "${TMP_HOME_G}" "${ARGV_G}" 2>&1) || exit_code_g=$?

# Assert all five ledger keys present
for key in revenium-policy-applied gh-release-policy-applied cli-delivered creds-written meter-probe-passed; do
  # Anchor to '^key=' so a malformed/partial entry cannot satisfy the check (IN-01).
  if [[ -f "${LEDGER_G}" ]] && grep -qE "^${key}=" "${LEDGER_G}" 2>/dev/null; then
    pass "GROUP-G: ledger key '${key}' present after full success run"
  else
    fail "GROUP-G: ledger key '${key}' NOT in ledger after full success run (provisioning not yet implemented)"
  fi
done

# IN-01: assert the cli-delivered VALUE (version:sha256), not just key presence.
if [[ -f "${LEDGER_G}" ]] && grep -qE '^cli-delivered=v1\.2\.0:cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67$' "${LEDGER_G}" 2>/dev/null; then
  pass "GROUP-G: cli-delivered ledger value is the pinned version:sha256"
else
  fail "GROUP-G: cli-delivered ledger value is not the pinned version:sha256"
fi

# ===========================================================================
# GROUP H: NCCLI-02 — creds config.yaml uses the `api-key:` field the CLI reads
#   The revenium CLI reads the API key from `api-key:` in ~/.config/revenium/
#   config.yaml; a bare `key:` field is SILENTLY IGNORED (Phase 13 live-smoke
#   finding — `config show` reported "API Key: (not set)" with a `key:` line,
#   while still reading team-id from the same file). Decode the base64 creds
#   payload captured in GROUP-G's argv and assert the field name.
# ===========================================================================
echo ""
echo "--- GROUP H: NCCLI-02 creds use api-key: field (decoded from exec payload) ---"

creds_b64=$(grep -aF 'base64 -d' "${ARGV_G}" 2>/dev/null \
  | grep -aF '/sandbox/.config/revenium/config.yaml' \
  | sed -n "s/.*printf '%s' '\([A-Za-z0-9+/=]*\)'.*/\1/p" | head -1)
if [[ -z "${creds_b64}" ]]; then
  fail "GROUP-H: could not locate base64 creds payload in captured argv (creds write not implemented as expected)"
else
  creds_decoded=$(printf '%s' "${creds_b64}" | base64 -d 2>/dev/null)
  if printf '%s\n' "${creds_decoded}" | grep -qE '^api-key: '; then
    pass "GROUP-H: config.yaml uses 'api-key:' field (the field the revenium CLI reads)"
  else
    fail "GROUP-H: config.yaml missing 'api-key:' field — CLI would report 'API Key: (not set)'"
  fi
  if printf '%s\n' "${creds_decoded}" | grep -qE '^key: '; then
    fail "GROUP-H: config.yaml uses bare 'key:' field — silently ignored by the revenium CLI"
  else
    pass "GROUP-H: config.yaml does not use the ignored bare 'key:' field"
  fi
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
echo ""
echo "NOTE: This harness is in the expected RED state before Plan 02 implements"
echo "      the provisioning functions in scripts/post-install-nemoclaw.sh."
echo "      GROUP A-G exercise functions that do not yet exist — those FAILs are"
echo "      correct for Wave 0 (Plan 01). The harness goes GREEN in Wave 2."
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
