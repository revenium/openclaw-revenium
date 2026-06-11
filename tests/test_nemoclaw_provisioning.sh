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
# GROUP I: NCDEPLOY-01 — SKILL.md guard + ✓ ready assertion
#
#   I-a: SKILL.md absent from resolved skill dir → non-zero exit + "SKILL.md not found"
#   I-b: SKILL.md present but STUB_NEMOCLAW_SKILL_NOT_READY set → non-zero + "NOT ready"
#   I-c: SKILL.md present + default ready output → exits 0 + skill-installed-nemoclaw ledger key
#
# Note on I-a: the script resolves skill_dir from ${SCRIPT_DIR}/.. (the real repo
# root, where SKILL.md DOES exist). To force the guard to fire we override the
# resolved dir via REVENIUM_SKILL_DIR pointing at a tmp dir with no SKILL.md.
#
# Note on pre-seeding: install_skill_nemoclaw() is gated by install_metering_loop()
# which requires sshfs (not available in the hermetic test env). To exercise only
# install_skill_nemoclaw() we pre-populate Phase 13 + Phase 14 ledger keys so the
# earlier steps are skipped via their ledger gates.
# ===========================================================================
echo ""
echo "--- GROUP I: NCDEPLOY-01 SKILL.md guard + ✓ ready assertion ---"

# Helper: pre-seed a ledger so all Phase 13 + Phase 14 steps are already done.
# This lets the test runner reach install_skill_nemoclaw() in the hermetic env.
_seed_phase13_14_ledger() {
  local ledger_file="$1"
  cat >> "${ledger_file}" << 'SEED'
revenium-policy-applied=1
gh-release-policy-applied=1
cli-delivered=v1.2.0:cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67
creds-written=1
meter-probe-passed=1
metering-loop-installed=1
SEED
}

# --- GROUP I-a: SKILL.md absent → fail hard with actionable message ---
echo ""
echo "  -- I-a: SKILL.md absent from skill dir --"

TMP_HOME_Ia=$(make_home)
ARGV_Ia=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-ia.XXXXXX")
TMP_HOMES+=("${ARGV_Ia}")
LEDGER_Ia="${TMP_HOME_Ia}/.nemoclaw/revenium-nemoclaw.ledger"
_seed_phase13_14_ledger "${LEDGER_Ia}"
# Point skill_dir at a tmp dir that has NO SKILL.md
NO_SKILL_MD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-nemo-noskillmd.XXXXXX")
TMP_HOMES+=("${NO_SKILL_MD_DIR}")

exit_code_ia=0
output_ia=$(REVENIUM_SKILL_DIR="${NO_SKILL_MD_DIR}" \
            run_provision "${TMP_HOME_Ia}" "${ARGV_Ia}" 2>&1) || exit_code_ia=$?

# Assert: exits non-zero
if [[ "${exit_code_ia}" -ne 0 ]]; then
  pass "GROUP-I-a: exits non-zero when SKILL.md absent"
else
  fail "GROUP-I-a: exited 0 — expected non-zero (SKILL.md guard not yet implemented)"
fi

# Assert: output mentions "SKILL.md not found"
if echo "${output_ia}" | grep -qi "SKILL.md not found"; then
  pass "GROUP-I-a: output contains 'SKILL.md not found' actionable message"
else
  fail "GROUP-I-a: 'SKILL.md not found' NOT in output (SKILL.md guard not yet implemented)"
fi

# --- GROUP I-b: SKILL.md present, NOT ready → fail hard with "NOT ready" message ---
echo ""
echo "  -- I-b: SKILL.md present, skill not ready --"

TMP_HOME_Ib=$(make_home)
ARGV_Ib=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-ib.XXXXXX")
TMP_HOMES+=("${ARGV_Ib}")
LEDGER_Ib="${TMP_HOME_Ib}/.nemoclaw/revenium-nemoclaw.ledger"
_seed_phase13_14_ledger "${LEDGER_Ib}"

exit_code_ib=0
output_ib=$(STUB_NEMOCLAW_SKILL_NOT_READY=1 \
            run_provision "${TMP_HOME_Ib}" "${ARGV_Ib}" 2>&1) || exit_code_ib=$?

# Assert: exits non-zero
if [[ "${exit_code_ib}" -ne 0 ]]; then
  pass "GROUP-I-b: exits non-zero when skill is NOT ready"
else
  fail "GROUP-I-b: exited 0 — expected non-zero (✓ ready assertion not yet implemented)"
fi

# Assert: output mentions "NOT ready"
if echo "${output_ib}" | grep -qi "NOT ready"; then
  pass "GROUP-I-b: output contains 'NOT ready' message"
else
  fail "GROUP-I-b: 'NOT ready' NOT in output (✓ ready assertion not yet implemented)"
fi

# --- GROUP I-c: SKILL.md present + default ready output → passes + ledger key written ---
echo ""
echo "  -- I-c: SKILL.md present, ready output → happy path --"

TMP_HOME_Ic=$(make_home)
ARGV_Ic=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-ic.XXXXXX")
TMP_HOMES+=("${ARGV_Ic}")
LEDGER_Ic="${TMP_HOME_Ic}/.nemoclaw/revenium-nemoclaw.ledger"
_seed_phase13_14_ledger "${LEDGER_Ic}"
# Also pre-seed enforcement-plugin-installed so the script doesn't fail on
# the mount/plugin gate (which requires a live sandbox in hermetic tests).
echo "enforcement-plugin-installed=1" >> "${LEDGER_Ic}"

exit_code_ic=0
output_ic=$(run_provision "${TMP_HOME_Ic}" "${ARGV_Ic}" 2>&1) || exit_code_ic=$?

# Assert: ledger key skill-installed-nemoclaw present
if [[ -f "${LEDGER_Ic}" ]] && grep -qE "^skill-installed-nemoclaw=" "${LEDGER_Ic}" 2>/dev/null; then
  pass "GROUP-I-c: skill-installed-nemoclaw ledger key written on happy path"
else
  fail "GROUP-I-c: skill-installed-nemoclaw NOT in ledger (✓ ready assertion not yet implemented)"
fi

# --- GROUP I-d: not-ready substring in skills-list output → assertion must FAIL (CR-01 regression) ---
# This test exercises the exact false-positive that CR-01 documents: a revenium
# line containing "not-ready" satisfies the OLD unanchored `grep -q "ready"` but
# must FAIL the fixed anchored `grep -Eq '(^|[[:space:]])ready([[:space:]]|$)'`.
echo ""
echo "  -- I-d: skills-list contains 'not-ready revenium' → ready assertion must reject (CR-01 regression) --"

TMP_HOME_Id=$(make_home)
ARGV_Id=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-id.XXXXXX")
TMP_HOMES+=("${ARGV_Id}")
LEDGER_Id="${TMP_HOME_Id}/.nemoclaw/revenium-nemoclaw.ledger"
_seed_phase13_14_ledger "${LEDGER_Id}"

exit_code_id=0
output_id=$(STUB_NEMOCLAW_SKILLS_LIST_OUTPUT='✗ not-ready  💰 revenium' \
            run_provision "${TMP_HOME_Id}" "${ARGV_Id}" 2>&1) || exit_code_id=$?

# Assert: exits non-zero (the gate must fire on a not-ready line)
if [[ "${exit_code_id}" -ne 0 ]]; then
  pass "GROUP-I-d: exits non-zero when skills-list shows 'not-ready' for revenium (CR-01 regression)"
else
  fail "GROUP-I-d: exited 0 — 'not-ready' substring incorrectly accepted as ready (CR-01 unanchored grep regression)"
fi

# Assert: output mentions "NOT ready" (confirms the assertion fired, not some other error)
if echo "${output_id}" | grep -qi "NOT ready"; then
  pass "GROUP-I-d: output contains 'NOT ready' message (assertion fired correctly)"
else
  fail "GROUP-I-d: 'NOT ready' NOT in output — wrong failure mode"
fi

# --- GROUP I-e: anchored ready match — '✓ ready  💰 revenium' line passes assertion ---
echo ""
echo "  -- I-e: skills-list contains '✓ ready 💰 revenium' → assertion passes (anchor happy-path) --"

TMP_HOME_Ie=$(make_home)
ARGV_Ie=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-ie.XXXXXX")
TMP_HOMES+=("${ARGV_Ie}")
LEDGER_Ie="${TMP_HOME_Ie}/.nemoclaw/revenium-nemoclaw.ledger"
_seed_phase13_14_ledger "${LEDGER_Ie}"
echo "enforcement-plugin-installed=1" >> "${LEDGER_Ie}"

exit_code_ie=0
output_ie=$(STUB_NEMOCLAW_SKILLS_LIST_OUTPUT='│ ✓ ready  │ 💰 revenium │' \
            run_provision "${TMP_HOME_Ie}" "${ARGV_Ie}" 2>&1) || exit_code_ie=$?

# Assert: exits 0 (the anchored ready pattern matches the table-row format)
if [[ "${exit_code_ie}" -eq 0 ]]; then
  pass "GROUP-I-e: exits 0 when skills-list shows table-row '✓ ready' for revenium"
else
  fail "GROUP-I-e: exited ${exit_code_ie} — anchored ready regex incorrectly rejected genuine ready line"
fi

# Assert: ledger key skill-installed-nemoclaw present (confirms the function ran to completion)
if [[ -f "${LEDGER_Ie}" ]] && grep -qE "^skill-installed-nemoclaw=" "${LEDGER_Ie}" 2>/dev/null; then
  pass "GROUP-I-e: skill-installed-nemoclaw ledger key written (function completed)"
else
  fail "GROUP-I-e: skill-installed-nemoclaw NOT in ledger — function did not complete"
fi

# ===========================================================================
# GROUP J: idempotency — openclaw plugins install is invoked with --force
#
#   J-a: The captured argv for the enforcement-plugin install step contains
#        "--force" on the openclaw plugins install line, proving the fix is
#        present (not just that the step exits 0).
#   J-b: Re-running install_enforcement_plugin() on a sandbox where the
#        enforcement-plugin-installed ledger key is ABSENT (even if a plugin
#        dir was previously placed by step 2 of the same function) succeeds —
#        exits 0 and writes the ledger key — because --force allows replace.
#        This simulates the "plugin already exists" scenario that caused
#        exit 1 before the fix (Re-run 2 evidence, 16-VALIDATION.md).
#
# The stub's default exec handler exits 0 for the openclaw plugins install
# payload (no specific dispatch needed for --force; the real semantics are
# tested live).  The share mount handler also exits 0 by default.  We seed
# all Phase 13 + metering-loop + skill-installed-nemoclaw ledger keys so the
# function-under-test is reached without touching the live-sandbox gates.
# ===========================================================================
echo ""
echo "--- GROUP J: idempotency — openclaw plugins install invoked with --force ---"

# Helper: seed ALL ledger keys needed to reach install_enforcement_plugin()
_seed_through_skill() {
  local ledger_file="$1"
  cat >> "${ledger_file}" << 'SEED_J'
revenium-policy-applied=1
gh-release-policy-applied=1
cli-delivered=v1.2.0:cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67
creds-written=1
meter-probe-passed=1
metering-loop-installed=1
skill-installed-nemoclaw=1
SEED_J
}

# --- GROUP J-a: --force present in captured argv ---
echo ""
echo "  -- J-a: --force present in captured argv for openclaw plugins install --"

TMP_HOME_Ja=$(make_home)
ARGV_Ja=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-ja.XXXXXX")
TMP_HOMES+=("${ARGV_Ja}")
LEDGER_Ja="${TMP_HOME_Ja}/.nemoclaw/revenium-nemoclaw.ledger"
_seed_through_skill "${LEDGER_Ja}"
# Create the SSHFS mount point subdirectories that the install steps require.
# In the hermetic env the mount is a plain dir (not a real SSHFS mount); the
# share mount stub exits 0, but cp dst requires extensions/ and Gate D requires
# a pre-existing stub marker .jsonl in markers/ (write-marker.sh runs in-sandbox
# and cannot write to the host-side mount in the hermetic suite).
_MNT_Ja="${TMP_HOME_Ja}/sbx-openclaw-${REVENIUM_SANDBOX_NAME:-test-sandbox}"
mkdir -p "${_MNT_Ja}/extensions" "${_MNT_Ja}/skills/revenium/markers"
touch "${_MNT_Ja}/skills/revenium/markers/stub-gate-d-test.jsonl"

exit_code_ja=0
output_ja=$(run_provision "${TMP_HOME_Ja}" "${ARGV_Ja}" 2>&1) || exit_code_ja=$?

# Assert: "--force" appears in the captured argv file
if [[ -f "${ARGV_Ja}" ]] && grep -qF -- "--force" "${ARGV_Ja}" 2>/dev/null; then
  pass "GROUP-J-a: '--force' found in captured argv for openclaw plugins install"
else
  fail "GROUP-J-a: '--force' NOT found in captured argv — openclaw plugins install missing --force flag"
fi

# Also assert "plugins" and "install" appear (confirms it's the right call, not unrelated --force)
if [[ -f "${ARGV_Ja}" ]] && grep -qF "plugins" "${ARGV_Ja}" 2>/dev/null && \
   grep -qF "install" "${ARGV_Ja}" 2>/dev/null; then
  pass "GROUP-J-a: 'plugins' and 'install' also present in captured argv (correct call site)"
else
  fail "GROUP-J-a: 'plugins' or 'install' NOT found in captured argv — unexpected call site"
fi

# --- GROUP J-b: re-install on existing plugin dir succeeds (exit 0, ledger written) ---
echo ""
echo "  -- J-b: re-install with pre-existing plugin dir exits 0 (idempotent) --"

TMP_HOME_Jb=$(make_home)
ARGV_Jb=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-jb.XXXXXX")
TMP_HOMES+=("${ARGV_Jb}")
LEDGER_Jb="${TMP_HOME_Jb}/.nemoclaw/revenium-nemoclaw.ledger"
_seed_through_skill "${LEDGER_Jb}"
# Do NOT seed enforcement-plugin-installed — we want install_enforcement_plugin()
# to run from scratch (simulating re-run with pre-existing plugin dir).
# Create the SSHFS mount point subdirectories that cp -r and Gate D require.
_MNT_Jb="${TMP_HOME_Jb}/sbx-openclaw-${REVENIUM_SANDBOX_NAME:-test-sandbox}"
mkdir -p "${_MNT_Jb}/extensions" "${_MNT_Jb}/skills/revenium/markers"
touch "${_MNT_Jb}/skills/revenium/markers/stub-gate-d-test.jsonl"

exit_code_jb=0
output_jb=$(run_provision "${TMP_HOME_Jb}" "${ARGV_Jb}" 2>&1) || exit_code_jb=$?

# Assert: exit 0 (install succeeds end-to-end, not aborted at plugins install)
if [[ "${exit_code_jb}" -eq 0 ]]; then
  pass "GROUP-J-b: re-install exits 0 — openclaw plugins install --force is idempotent"
else
  fail "GROUP-J-b: re-install exited ${exit_code_jb} — expected 0 (--force should allow replace)"
fi

# Assert: enforcement-plugin-installed ledger key written
if [[ -f "${LEDGER_Jb}" ]] && grep -qE "^enforcement-plugin-installed=" "${LEDGER_Jb}" 2>/dev/null; then
  pass "GROUP-J-b: enforcement-plugin-installed ledger key written after idempotent re-install"
else
  fail "GROUP-J-b: enforcement-plugin-installed NOT in ledger after re-install"
fi

# ===========================================================================
# GROUP K: enforcement-plugin Gate A/B (v2026.5.22 probe-shape fixes, NCENF-01)
#
#   K-a: Gate A passes the default agent via --agent (routing target) so
#        `openclaw agent --json` runs on v2026.5.22 (without --agent it errors
#        "No target session selected" and the probe false-fails). Assert
#        "--agent" appears in the captured argv for the agent probe, and the
#        install completes (enforcement-plugin-installed ledger key written —
#        Gate A + Gate B both pass with the v2026.5.22 stub shapes).
#   K-b: Gate A fails closed when promptChars is below the 1500 threshold
#        (no-injection baseline) — install exits non-zero.
#   K-c: Gate B fails closed when `plugins inspect` does not show Status: loaded.
#   K-d: Gate B fails closed when allowConversationAccess is not true.
#
# All reach install_enforcement_plugin() via _seed_through_skill + mount dirs.
# ===========================================================================
echo ""
echo "--- GROUP K: enforcement-plugin Gate A/B (v2026.5.22 probe-shape fixes) ---"

# --- GROUP K-a: Gate A uses --agent routing target; install completes ---
echo ""
echo "  -- K-a: Gate A probe uses --agent routing target (v2026.5.22 fix) --"

TMP_HOME_Ka=$(make_home)
ARGV_Ka=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-ka.XXXXXX")
TMP_HOMES+=("${ARGV_Ka}")
LEDGER_Ka="${TMP_HOME_Ka}/.nemoclaw/revenium-nemoclaw.ledger"
_seed_through_skill "${LEDGER_Ka}"
_MNT_Ka="${TMP_HOME_Ka}/sbx-openclaw-${REVENIUM_SANDBOX_NAME:-test-sandbox}"
mkdir -p "${_MNT_Ka}/extensions" "${_MNT_Ka}/skills/revenium/markers"
touch "${_MNT_Ka}/skills/revenium/markers/stub-gate-d-test.jsonl"

exit_code_ka=0
output_ka=$(run_provision "${TMP_HOME_Ka}" "${ARGV_Ka}" 2>&1) || exit_code_ka=$?

# Assert: "--agent" present on the openclaw agent --json probe in captured argv
if [[ -f "${ARGV_Ka}" ]] && grep -qF -- "--agent" "${ARGV_Ka}" 2>/dev/null \
   && grep -qF "openclaw agent" "${ARGV_Ka}" 2>/dev/null \
   && grep -qF -- "--json" "${ARGV_Ka}" 2>/dev/null; then
  pass "GROUP-K-a: Gate A probe passes --agent routing target (no 'No target session' false-fail)"
else
  fail "GROUP-K-a: '--agent' NOT in captured argv for openclaw agent --json — Gate A would false-fail on v2026.5.22"
fi

# Assert: install completes (enforcement-plugin-installed ledger key written)
if [[ "${exit_code_ka}" -eq 0 ]] && grep -qE "^enforcement-plugin-installed=" "${LEDGER_Ka}" 2>/dev/null; then
  pass "GROUP-K-a: install completes — Gate A + Gate B pass with v2026.5.22 probe shapes"
else
  fail "GROUP-K-a: install did not complete (exit ${exit_code_ka}) — gates failed against v2026.5.22 stub"
fi

# --- GROUP K-b: Gate A fails closed when promptChars below threshold ---
echo ""
echo "  -- K-b: Gate A fails closed when promptChars < 1500 (no-injection baseline) --"

TMP_HOME_Kb=$(make_home)
ARGV_Kb=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-kb.XXXXXX")
TMP_HOMES+=("${ARGV_Kb}")
LEDGER_Kb="${TMP_HOME_Kb}/.nemoclaw/revenium-nemoclaw.ledger"
_seed_through_skill "${LEDGER_Kb}"
_MNT_Kb="${TMP_HOME_Kb}/sbx-openclaw-${REVENIUM_SANDBOX_NAME:-test-sandbox}"
mkdir -p "${_MNT_Kb}/extensions" "${_MNT_Kb}/skills/revenium/markers"
touch "${_MNT_Kb}/skills/revenium/markers/stub-gate-d-test.jsonl"

exit_code_kb=0
output_kb=$(STUB_NEMOCLAW_PROMPT_CHARS=649 \
            run_provision "${TMP_HOME_Kb}" "${ARGV_Kb}" 2>&1) || exit_code_kb=$?

if [[ "${exit_code_kb}" -ne 0 ]] && echo "${output_kb}" | grep -qi "promptChars=649"; then
  pass "GROUP-K-b: Gate A fails closed (non-zero) when promptChars below threshold"
else
  fail "GROUP-K-b: Gate A did not fail closed on sub-threshold promptChars (exit ${exit_code_kb})"
fi

# --- GROUP K-c: Gate B fails closed when plugin not loaded ---
echo ""
echo "  -- K-c: Gate B fails closed when plugins inspect lacks 'Status: loaded' --"

TMP_HOME_Kc=$(make_home)
ARGV_Kc=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-kc.XXXXXX")
TMP_HOMES+=("${ARGV_Kc}")
LEDGER_Kc="${TMP_HOME_Kc}/.nemoclaw/revenium-nemoclaw.ledger"
_seed_through_skill "${LEDGER_Kc}"
_MNT_Kc="${TMP_HOME_Kc}/sbx-openclaw-${REVENIUM_SANDBOX_NAME:-test-sandbox}"
mkdir -p "${_MNT_Kc}/extensions" "${_MNT_Kc}/skills/revenium/markers"
touch "${_MNT_Kc}/skills/revenium/markers/stub-gate-d-test.jsonl"

exit_code_kc=0
output_kc=$(STUB_NEMOCLAW_PLUGIN_STATUS=error \
            run_provision "${TMP_HOME_Kc}" "${ARGV_Kc}" 2>&1) || exit_code_kc=$?

if [[ "${exit_code_kc}" -ne 0 ]] && echo "${output_kc}" | grep -qi "NOT loaded"; then
  pass "GROUP-K-c: Gate B fails closed (non-zero) when plugin not loaded"
else
  fail "GROUP-K-c: Gate B did not fail closed when 'Status: loaded' absent (exit ${exit_code_kc})"
fi

# --- GROUP K-d: Gate B fails closed when allowConversationAccess not true ---
echo ""
echo "  -- K-d: Gate B fails closed when allowConversationAccess != true --"

TMP_HOME_Kd=$(make_home)
ARGV_Kd=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-kd.XXXXXX")
TMP_HOMES+=("${ARGV_Kd}")
LEDGER_Kd="${TMP_HOME_Kd}/.nemoclaw/revenium-nemoclaw.ledger"
_seed_through_skill "${LEDGER_Kd}"
_MNT_Kd="${TMP_HOME_Kd}/sbx-openclaw-${REVENIUM_SANDBOX_NAME:-test-sandbox}"
mkdir -p "${_MNT_Kd}/extensions" "${_MNT_Kd}/skills/revenium/markers"
touch "${_MNT_Kd}/skills/revenium/markers/stub-gate-d-test.jsonl"

exit_code_kd=0
output_kd=$(STUB_NEMOCLAW_PLUGIN_CONV_ACCESS=false \
            run_provision "${TMP_HOME_Kd}" "${ARGV_Kd}" 2>&1) || exit_code_kd=$?

if [[ "${exit_code_kd}" -ne 0 ]] && echo "${output_kd}" | grep -qi "allowConversationAccess not applied"; then
  pass "GROUP-K-d: Gate B fails closed (non-zero) when allowConversationAccess != true"
else
  fail "GROUP-K-d: Gate B did not fail closed when allowConversationAccess false (exit ${exit_code_kd})"
fi

# ===========================================================================
# GROUP L: host-side revenium CLI delivery (metering cron prerequisite, NCMETER)
#
#   The NemoClaw metering loop runs report.sh ON THE HOST and calls `revenium`.
#   deliver_revenium_cli_host() installs the CLI on the host PATH (~/.local/bin)
#   so the cron does not log "revenium CLI not found on PATH — skipping metering".
#
#   L-a: revenium already on host PATH → skip (no clobber) + ledger written.
#   L-b: revenium absent → fetch+verify+install to ~/.local/bin + ledger written
#        (stub curl writes a fixture tarball; stub sha256sum echoes the pinned sha).
#   L-c: sha256 mismatch → abort non-zero, ledger NOT written.
#
# Seeds all prior ledger keys so only deliver_revenium_cli_host() runs (the
# metering-loop/skill/enforcement gates are pre-satisfied to avoid live-sandbox deps).
# ===========================================================================
echo ""
echo "--- GROUP L: host-side revenium CLI delivery (metering cron prerequisite) ---"

PINNED_SHA="cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67"

# Seed every ledger key except cli-delivered-host so only the host CLI step runs.
_seed_all_but_host() {
  local ledger_file="$1"
  cat >> "${ledger_file}" << 'SEED_L'
revenium-policy-applied=1
gh-release-policy-applied=1
cli-delivered=v1.2.0:cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67
creds-written=1
meter-probe-passed=1
metering-loop-installed=1
skill-installed-nemoclaw=1
enforcement-plugin-installed=1
SEED_L
}

# Build a fixture tarball containing a top-level `revenium` file (mirrors the real
# revenium-cli_*_linux_amd64.tar.gz layout that `tar xzf` + `install ./revenium` expect).
FIXTURE_TGZ=$(mktemp "${TMPDIR:-/tmp}/test-nemo-revcli.XXXXXX.tgz")
TMP_HOMES+=("${FIXTURE_TGZ}")
_fix_dir=$(mktemp -d "${TMPDIR:-/tmp}/test-nemo-revcli-src.XXXXXX")
TMP_HOMES+=("${_fix_dir}")
printf '#!/bin/sh\necho stub-revenium\n' > "${_fix_dir}/revenium"
chmod +x "${_fix_dir}/revenium"
tar czf "${FIXTURE_TGZ}" -C "${_fix_dir}" revenium

# Drop stub curl + sha256sum into a home's .local/bin (first on PATH) so the host
# fetch+verify runs network-free. curl copies STUB_CURL_FIXTURE to its -o target;
# sha256sum echoes STUB_SHA256_VALUE.
_install_host_cli_stubs() {
  local bindir="$1"
  cat > "${bindir}/curl" << 'CURL_STUB'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
[ -n "${out}" ] && cp "${STUB_CURL_FIXTURE}" "${out}"
exit 0
CURL_STUB
  cat > "${bindir}/sha256sum" << 'SHA_STUB'
#!/usr/bin/env bash
echo "${STUB_SHA256_VALUE}  ${1:-rev.tgz}"
SHA_STUB
  chmod +x "${bindir}/curl" "${bindir}/sha256sum"
}

# --- GROUP L-a: revenium already on host PATH → skip, ledger written ---
echo ""
echo "  -- L-a: revenium already on host PATH → skip (no clobber) --"

TMP_HOME_La=$(make_home)
ARGV_La=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-la.XXXXXX")
TMP_HOMES+=("${ARGV_La}")
LEDGER_La="${TMP_HOME_La}/.nemoclaw/revenium-nemoclaw.ledger"
_seed_all_but_host "${LEDGER_La}"
# Pre-place a fake revenium on the host PATH (the make_home .local/bin dir).
printf '#!/bin/sh\nexit 0\n' > "${TMP_HOME_La}/.local/bin/revenium"
chmod +x "${TMP_HOME_La}/.local/bin/revenium"

exit_code_la=0
output_la=$(run_provision "${TMP_HOME_La}" "${ARGV_La}" 2>&1) || exit_code_la=$?

if [[ "${exit_code_la}" -eq 0 ]] && echo "${output_la}" | grep -qi "already on host PATH"; then
  pass "GROUP-L-a: host CLI step skips when revenium already on PATH (no clobber)"
else
  fail "GROUP-L-a: did not skip on pre-existing host revenium (exit ${exit_code_la})"
fi
if grep -qE "^cli-delivered-host=" "${LEDGER_La}" 2>/dev/null; then
  pass "GROUP-L-a: cli-delivered-host ledger key written on skip path"
else
  fail "GROUP-L-a: cli-delivered-host ledger key NOT written on skip path"
fi

# --- GROUP L-b: revenium absent → fetch+verify+install to ~/.local/bin ---
echo ""
echo "  -- L-b: revenium absent → host install to ~/.local/bin (stubbed curl/sha) --"

TMP_HOME_Lb=$(make_home)
ARGV_Lb=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-lb.XXXXXX")
TMP_HOMES+=("${ARGV_Lb}")
LEDGER_Lb="${TMP_HOME_Lb}/.nemoclaw/revenium-nemoclaw.ledger"
_seed_all_but_host "${LEDGER_Lb}"
_install_host_cli_stubs "${TMP_HOME_Lb}/.local/bin"   # no revenium present → triggers fetch

exit_code_lb=0
# Restrict PATH (as a literal prefix so run_provision's own ${PATH} picks it up) to
# the stub dir + system bins, so `command -v revenium` reflects the absent-on-host
# scenario — the dev machine's real PATH may already have a revenium, which would
# wrongly take the skip path. (PATH via run_provision's "$@" is NOT recognized as an
# assignment — bash only honors literal assignment prefixes.)
output_lb=$(STUB_CURL_FIXTURE="${FIXTURE_TGZ}" STUB_SHA256_VALUE="${PINNED_SHA}" \
            PATH="${TMP_HOME_Lb}/.local/bin:/usr/bin:/bin" \
            run_provision "${TMP_HOME_Lb}" "${ARGV_Lb}" 2>&1) || exit_code_lb=$?

if [[ "${exit_code_lb}" -eq 0 ]] && [[ -x "${TMP_HOME_Lb}/.local/bin/revenium" ]]; then
  pass "GROUP-L-b: revenium installed to host ~/.local/bin when absent"
else
  fail "GROUP-L-b: revenium NOT installed to host ~/.local/bin (exit ${exit_code_lb})"
fi
if grep -qE "^cli-delivered-host=v1\.2\.0:${PINNED_SHA}$" "${LEDGER_Lb}" 2>/dev/null; then
  pass "GROUP-L-b: cli-delivered-host ledger value is the pinned version:sha256"
else
  fail "GROUP-L-b: cli-delivered-host ledger value missing/incorrect"
fi

# --- GROUP L-c: sha256 mismatch → abort non-zero, ledger NOT written ---
echo ""
echo "  -- L-c: host tarball sha256 mismatch → abort --"

TMP_HOME_Lc=$(make_home)
ARGV_Lc=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-lc.XXXXXX")
TMP_HOMES+=("${ARGV_Lc}")
LEDGER_Lc="${TMP_HOME_Lc}/.nemoclaw/revenium-nemoclaw.ledger"
_seed_all_but_host "${LEDGER_Lc}"
_install_host_cli_stubs "${TMP_HOME_Lc}/.local/bin"

exit_code_lc=0
output_lc=$(STUB_CURL_FIXTURE="${FIXTURE_TGZ}" STUB_SHA256_VALUE="deadbeefbadhash" \
            PATH="${TMP_HOME_Lc}/.local/bin:/usr/bin:/bin" \
            run_provision "${TMP_HOME_Lc}" "${ARGV_Lc}" 2>&1) || exit_code_lc=$?

if [[ "${exit_code_lc}" -ne 0 ]] && echo "${output_lc}" | grep -qi "sha256 mismatch"; then
  pass "GROUP-L-c: host CLI install aborts on sha256 mismatch"
else
  fail "GROUP-L-c: did not abort on sha256 mismatch (exit ${exit_code_lc})"
fi
if ! grep -qE "^cli-delivered-host=" "${LEDGER_Lc}" 2>/dev/null; then
  pass "GROUP-L-c: cli-delivered-host ledger NOT written on sha mismatch"
else
  fail "GROUP-L-c: cli-delivered-host ledger wrongly written despite sha mismatch"
fi

# ===========================================================================
# GROUP M: per-sandbox-instance ledger scoping (multi-sandbox correctness)
#
#   The provisioning ledger is scoped to the sandbox's UUID (from
#   `nemoclaw <name> status`), so a second/recreated sandbox is NOT skipped by a
#   stale host-global ledger. Verified WITHOUT an explicit LEDGER_FILE override so
#   the script computes the per-sandbox path itself.
#
#   M-a: UUID-A + a fully-seeded per-UUID-A ledger → idempotent skip; the
#        host-global revenium-nemoclaw.ledger is NOT created (isolation).
#   M-b: a DIFFERENT UUID-B + its own seeded ledger → skip via the UUID-B ledger
#        (proves the ledger filename tracks the sandbox UUID).
#   M-c: no Id in status → fall back to scoping by sandbox NAME.
# ===========================================================================
echo ""
echo "--- GROUP M: per-sandbox-instance ledger scoping ---"

# run_provision variant that does NOT set LEDGER_FILE, so the script resolves the
# per-sandbox ledger path itself (the behavior under test).
run_provision_no_ledger() {
  local home_dir="$1"
  local argv_file="$2"
  shift 2
  local stub_probe="${home_dir}/stub-probe-host-compat.sh"
  STUB_NEMOCLAW_ARGV_FILE="${argv_file}" \
  HOME="${home_dir}" \
  PATH="${home_dir}/.local/bin:${PATH}" \
  REVENIUM_SANDBOX_NAME="${REVENIUM_SANDBOX_NAME:-test-sandbox}" \
  REVENIUM_API_KEY="${REVENIUM_API_KEY:-test-key}" \
  PROBE_SCRIPT="${stub_probe}" \
  "$@" \
  bash "${PROVISION_SH}" 2>&1
}

_seed_full() {
  cat >> "$1" << 'SEED_FULL'
revenium-policy-applied=1
gh-release-policy-applied=1
cli-delivered=v1.2.0:cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67
creds-written=1
meter-probe-passed=1
cli-delivered-host=v1.2.0:cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67
metering-loop-installed=1
skill-installed-nemoclaw=1
enforcement-plugin-installed=1
SEED_FULL
}

# --- GROUP M-a: per-UUID ledger honored; global ledger not used ---
echo ""
echo "  -- M-a: ledger scoped to sandbox UUID-A (seeded → idempotent skip) --"

UUID_A="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
TMP_HOME_Ma=$(make_home)
ARGV_Ma=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-ma.XXXXXX")
TMP_HOMES+=("${ARGV_Ma}")
_seed_full "${TMP_HOME_Ma}/.nemoclaw/revenium-nemoclaw-${UUID_A}.ledger"

exit_code_ma=0
output_ma=$(STUB_NEMOCLAW_SANDBOX_UUID="${UUID_A}" \
            run_provision_no_ledger "${TMP_HOME_Ma}" "${ARGV_Ma}" 2>&1) || exit_code_ma=$?

if [[ "${exit_code_ma}" -eq 0 ]] \
   && echo "${output_ma}" | grep -qi "already provisioned" \
   && echo "${output_ma}" | grep -qiF "scoped to sandbox instance ${UUID_A}"; then
  pass "GROUP-M-a: ledger scoped to sandbox UUID; seeded per-UUID ledger → idempotent skip"
else
  fail "GROUP-M-a: per-UUID ledger not honored (exit ${exit_code_ma})"
fi
if [[ ! -f "${TMP_HOME_Ma}/.nemoclaw/revenium-nemoclaw.ledger" ]]; then
  pass "GROUP-M-a: host-global revenium-nemoclaw.ledger NOT created (per-sandbox isolation)"
else
  fail "GROUP-M-a: host-global ledger was created — per-sandbox scoping not applied"
fi

# --- GROUP M-b: a different UUID maps to a different ledger file ---
echo ""
echo "  -- M-b: different sandbox UUID-B → its own ledger (filename tracks UUID) --"

UUID_B="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
TMP_HOME_Mb=$(make_home)
ARGV_Mb=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-mb.XXXXXX")
TMP_HOMES+=("${ARGV_Mb}")
_seed_full "${TMP_HOME_Mb}/.nemoclaw/revenium-nemoclaw-${UUID_B}.ledger"

exit_code_mb=0
output_mb=$(STUB_NEMOCLAW_SANDBOX_UUID="${UUID_B}" \
            run_provision_no_ledger "${TMP_HOME_Mb}" "${ARGV_Mb}" 2>&1) || exit_code_mb=$?

if [[ "${exit_code_mb}" -eq 0 ]] \
   && echo "${output_mb}" | grep -qiF "scoped to sandbox instance ${UUID_B}" \
   && [[ -f "${TMP_HOME_Mb}/.nemoclaw/revenium-nemoclaw-${UUID_B}.ledger" ]]; then
  pass "GROUP-M-b: ledger filename tracks the sandbox UUID (B != A)"
else
  fail "GROUP-M-b: ledger did not track UUID-B (exit ${exit_code_mb})"
fi

# --- GROUP M-c: no Id in status → fall back to scoping by sandbox name ---
echo ""
echo "  -- M-c: status has no Id → ledger scoped by sandbox name (fallback) --"

TMP_HOME_Mc=$(make_home)
ARGV_Mc=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-mc.XXXXXX")
TMP_HOMES+=("${ARGV_Mc}")
# Default sandbox name in run_provision_no_ledger is "test-sandbox".
_seed_full "${TMP_HOME_Mc}/.nemoclaw/revenium-nemoclaw-test-sandbox.ledger"

exit_code_mc=0
output_mc=$(STUB_NEMOCLAW_STATUS_NO_ID=1 \
            run_provision_no_ledger "${TMP_HOME_Mc}" "${ARGV_Mc}" 2>&1) || exit_code_mc=$?

if [[ "${exit_code_mc}" -eq 0 ]] \
   && echo "${output_mc}" | grep -qi "scoping the ledger by name" \
   && [[ -f "${TMP_HOME_Mc}/.nemoclaw/revenium-nemoclaw-test-sandbox.ledger" ]]; then
  pass "GROUP-M-c: falls back to name-scoped ledger when no sandbox id is available"
else
  fail "GROUP-M-c: name fallback not applied (exit ${exit_code_mc})"
fi

# ===========================================================================
# GROUP N: budget guardrail provisioning gate (env-driven)
#
#   provision_budget_guardrails() creates the Revenium budget rule + writes the
#   in-sandbox config.json ONLY when REVENIUM_BUDGET_LIMIT + REVENIUM_BUDGET_PERIOD
#   are set. Without them it must skip cleanly (no rule, no ledger key) and tell
#   the operator how to set a budget — metering is unaffected.
#
#   N-a: no budget env → skips with guidance, budget-rules-created NOT written.
#   (The create path is covered by live validation — it requires a real/stubbed
#    `revenium guardrails budget-rules create`; see the host live-verify.)
# ===========================================================================
echo ""
echo "--- GROUP N: budget guardrail provisioning gate (env-driven) ---"

echo ""
echo "  -- N-a: no REVENIUM_BUDGET_* → budget step skips cleanly --"

TMP_HOME_Na=$(make_home)
ARGV_Na=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-na.XXXXXX")
TMP_HOMES+=("${ARGV_Na}")
LEDGER_Na="${TMP_HOME_Na}/.nemoclaw/revenium-nemoclaw.ledger"
# Seed everything through the enforcement plugin so the run reaches
# provision_budget_guardrails; budget-rules-created is intentionally NOT seeded.
_seed_full "${LEDGER_Na}"

exit_code_na=0
output_na=$(run_provision "${TMP_HOME_Na}" "${ARGV_Na}" 2>&1) || exit_code_na=$?

if [[ "${exit_code_na}" -eq 0 ]] && echo "${output_na}" | grep -qi "Budget guardrails not auto-created"; then
  pass "GROUP-N-a: budget step skips with guidance when REVENIUM_BUDGET_* unset"
else
  fail "GROUP-N-a: budget step did not skip cleanly without budget env (exit ${exit_code_na})"
fi
if ! grep -qE "^budget-rules-created=" "${LEDGER_Na}" 2>/dev/null; then
  pass "GROUP-N-a: budget-rules-created ledger key NOT written on skip"
else
  fail "GROUP-N-a: budget-rules-created wrongly written when no budget configured"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
echo ""
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
