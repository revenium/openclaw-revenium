#!/usr/bin/env bash
# =============================================================================
# test_nemoclaw_cron.sh — Nyquist test harness for Phase 14 host-side metering loop
#
# Targets three Wave-2 scripts:
#   scripts/nemoclaw-cron-tick.sh
#   scripts/install-nemoclaw-cron.sh
#   scripts/uninstall-nemoclaw-cron.sh
#
# Strategy:
#   Build an isolated tmp HOME with .nemoclaw/ and a tmp bin dir containing:
#     stub-mount-env.sh as mountpoint, crontab, sshfs, fusermount, umount
#     stub-nemoclaw.sh  as nemoclaw
#   Prepend tmp bin dir to PATH so no real crontab/sshfs/nemoclaw is ever called.
#   Assert against exit codes, file contents, and captured argv files.
#
# GROUP map → decision/SC:
#   GROUP A (D-03/SC3): tick mount-down + remount FAIL → exit 3, no status write
#   GROUP B (D-03):     tick mount-down + remount OK  → nemoclaw share mount called
#   GROUP C (SC4):      cron.sh/report.sh/guardrail-check.sh byte-identical to baseline
#   GROUP D (D-02):     install writes revenium-host.env mode 600; key not in crontab/argv
#   GROUP E (D-07):     install idempotent — exactly ONE marker line; standalone coexists
#   GROUP F (D-04):     install with no sshfs → exits non-zero, no cron entry written
#   GROUP G (D-08):     --interval 5 → */5 schedule; out-of-range exits 2
#   GROUP H (uninstall):uninstall removes only per-sandbox entry, standalone untouched
#   GROUP I (D-06 TTL): healthy tick over UP mount adds _maxAgeSeconds to status file
#
# EXPECTED RESULT IN WAVE 1:
#   The Wave-2 scripts do not yet exist. All GROUPs that depend on them record FAIL.
#   That RED state is correct. Do NOT weaken assertions. The harness goes GREEN when
#   Wave 2 implements the three scripts. Running this harness exits non-zero in Wave 1.
#
# SECURITY (T-14-02): this harness never executes or string-interpolates captured output.
#   Assertions use grep -qF (fixed-string) or case. No shell-exec of captured strings.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TICK_SH="${REPO_ROOT}/scripts/nemoclaw-cron-tick.sh"
INSTALL_SH="${REPO_ROOT}/scripts/install-nemoclaw-cron.sh"
UNINSTALL_SH="${REPO_ROOT}/scripts/uninstall-nemoclaw-cron.sh"
CRON_SH="${REPO_ROOT}/scripts/cron.sh"
REPORT_SH="${REPO_ROOT}/scripts/report.sh"
GUARDRAIL_SH="${REPO_ROOT}/scripts/guardrail-check.sh"

STUB_MOUNT_SH="${SCRIPT_DIR}/stub-mount-env.sh"
STUB_NEMOCLAW_SH="${SCRIPT_DIR}/stub-nemoclaw.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# ---------------------------------------------------------------------------
# SC4 Baseline sha256 constants (do NOT modify — GROUP C enforces these).
# Captured from live files 2026-06-08 (shasum -a 256):
#   scripts/cron.sh            = 78124b27a78595821f9914c7c79211934da236aa5aa37c21261de34fa82ecaff
#   scripts/report.sh          = 238a08bf151d1ae4446f20d1ff20c382ec2ed18b482e6b8094b5c6147eb1741f
#   scripts/guardrail-check.sh = 7a0f842d3ecc86246fb968ea2e7bc3a9d0a295fbc1c0ca94c60f1f7ae0dc8659
# ---------------------------------------------------------------------------
SC4_CRON_SHA="78124b27a78595821f9914c7c79211934da236aa5aa37c21261de34fa82ecaff"
SC4_REPORT_SHA="238a08bf151d1ae4446f20d1ff20c382ec2ed18b482e6b8094b5c6147eb1741f"
SC4_GUARDRAIL_SHA="7a0f842d3ecc86246fb968ea2e7bc3a9d0a295fbc1c0ca94c60f1f7ae0dc8659"

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
# Guard: required stubs must exist
# ---------------------------------------------------------------------------
if [[ ! -f "${STUB_MOUNT_SH}" ]]; then
  echo ""
  echo "=== STUB MISSING ==="
  echo "tests/stub-mount-env.sh does not exist."
  fail "stub-mount-env-exists: ${STUB_MOUNT_SH} not found"
fi

if [[ ! -f "${STUB_NEMOCLAW_SH}" ]]; then
  echo ""
  echo "=== STUB MISSING ==="
  echo "tests/stub-nemoclaw.sh does not exist."
  fail "stub-nemoclaw-exists: ${STUB_NEMOCLAW_SH} not found"
fi

# ---------------------------------------------------------------------------
# make_home — create an isolated tmp HOME with nemoclaw dir and stubs on PATH
#
# Creates:
#   <home>/.nemoclaw/          — host env dir
#   <home>/.local/bin/         — tmp PATH dir with stub symlinks
#   <home>/.local/bin/{mountpoint,crontab,sshfs,fusermount,umount} → stub-mount-env.sh
#   <home>/.local/bin/nemoclaw → stub-nemoclaw.sh
# Returns the home path (printed to stdout)
# ---------------------------------------------------------------------------
make_home() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-nemo-cron.XXXXXX")
  TMP_HOMES+=("${d}")
  mkdir -p "${d}/.nemoclaw" "${d}/.local/bin"
  # Symlink stub-mount-env.sh as each host-side tool
  for cmd in mountpoint crontab sshfs fusermount umount; do
    ln -sf "${STUB_MOUNT_SH}" "${d}/.local/bin/${cmd}"
  done
  # Symlink stub-nemoclaw.sh as nemoclaw
  ln -sf "${STUB_NEMOCLAW_SH}" "${d}/.local/bin/nemoclaw"
  echo "${d}"
}

# ---------------------------------------------------------------------------
# run_tick <home> <nemoclaw_argv_file> <mount_argv_file> [extra_env...]
#   Invoke nemoclaw-cron-tick.sh with stub tools on PATH and isolated HOME.
#   Captures combined stdout+stderr. Returns the exit code.
# ---------------------------------------------------------------------------
run_tick() {
  local home_dir="$1"
  local nemo_argv="$2"
  local mount_argv="$3"
  shift 3

  STUB_NEMOCLAW_ARGV_FILE="${nemo_argv}" \
  STUB_MOUNT_ENV_ARGV_FILE="${mount_argv}" \
  HOME="${home_dir}" \
  PATH="${home_dir}/.local/bin:${PATH}" \
  REVENIUM_SANDBOX_NAME="${REVENIUM_SANDBOX_NAME:-revenium-spike}" \
  REVENIUM_API_KEY="${REVENIUM_API_KEY:-test-api-key-not-real}" \
  "$@" \
  bash "${TICK_SH}" 2>&1
}

# ---------------------------------------------------------------------------
# run_install <home> <mount_argv_file> [extra_env...]
#   Invoke install-nemoclaw-cron.sh with stub tools on PATH and isolated HOME.
# ---------------------------------------------------------------------------
run_install() {
  local home_dir="$1"
  local mount_argv="$2"
  shift 2

  local ctab_file="${home_dir}/.nemoclaw/stub-crontab"
  touch "${ctab_file}"

  STUB_MOUNT_ENV_ARGV_FILE="${mount_argv}" \
  STUB_CRONTAB_FILE="${ctab_file}" \
  HOME="${home_dir}" \
  PATH="${home_dir}/.local/bin:${PATH}" \
  REVENIUM_SANDBOX_NAME="${REVENIUM_SANDBOX_NAME:-revenium-spike}" \
  REVENIUM_API_KEY="${REVENIUM_API_KEY:-test-api-key-not-real}" \
  "$@" \
  bash "${INSTALL_SH}" --sandbox "${REVENIUM_SANDBOX_NAME:-revenium-spike}" 2>&1
}

# ---------------------------------------------------------------------------
# run_uninstall <home> <sandbox_name>
#   Invoke uninstall-nemoclaw-cron.sh with stub tools on PATH and isolated HOME.
# ---------------------------------------------------------------------------
run_uninstall() {
  local home_dir="$1"
  local sandbox="$2"
  shift 2

  local ctab_file="${home_dir}/.nemoclaw/stub-crontab"

  STUB_CRONTAB_FILE="${ctab_file}" \
  HOME="${home_dir}" \
  PATH="${home_dir}/.local/bin:${PATH}" \
  REVENIUM_SANDBOX_NAME="${sandbox}" \
  "$@" \
  bash "${UNINSTALL_SH}" "${sandbox}" 2>&1
}

# ===========================================================================
# GROUP A (D-03/SC3): tick with mount DOWN + remount FAIL → exits 3, no status write
#   STUB_MOUNT_UP=0 → mountpoint exits non-zero (mount down)
#   STUB_SSHFS_RC=1 → sshfs (remount attempt) fails
#   Expected: tick exits 3, guardrail-status.json NOT created/modified
# ===========================================================================
echo ""
echo "--- GROUP A (D-03/SC3): tick mount-down + remount FAIL → exit 3, no status write ---"

if [[ ! -f "${TICK_SH}" ]]; then
  fail "GROUP-A: tick script missing (${TICK_SH}) — RED state in Wave 1"
else
  TMP_HOME_A=$(make_home)
  NEMO_A=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-a.XXXXXX")
  MOUNT_A=$(mktemp "${TMPDIR:-/tmp}/test-mount-argv-a.XXXXXX")
  TMP_HOMES+=("${NEMO_A}" "${MOUNT_A}")

  # Pre-create a fake mount dir with skills/ to assert nothing is written
  MNT_A="${TMP_HOME_A}/sbx-openclaw-revenium-spike"
  mkdir -p "${MNT_A}/skills/revenium"
  STATUS_A="${MNT_A}/skills/revenium/guardrail-status.json"
  STATUS_MTIME_BEFORE=""

  rc_a=0
  output_a=$(STUB_MOUNT_UP=0 STUB_SSHFS_RC=1 run_tick "${TMP_HOME_A}" "${NEMO_A}" "${MOUNT_A}" 2>&1) || rc_a=$?

  # Assert exit 3
  if [[ "${rc_a}" -eq 3 ]]; then
    pass "GROUP-A: tick exits 3 on mount-down + remount-fail (SC3)"
  else
    fail "GROUP-A: tick exited ${rc_a} (expected 3) on mount-down + remount-fail"
  fi

  # Assert status file was NOT written (D-05)
  if [[ -f "${STATUS_A}" ]]; then
    fail "GROUP-A: guardrail-status.json was written on mount failure (violates D-05)"
  else
    pass "GROUP-A: guardrail-status.json NOT written on mount failure (D-05 ok)"
  fi
fi

# ===========================================================================
# GROUP B (D-03): tick mount-down + remount SUCCESS → nemoclaw share mount called
#   STUB_MOUNT_UP=0 → mountpoint exits non-zero (mount down)
#   STUB_SSHFS_RC=0 (default) → nemoclaw remount call succeeds
#   Expected: tick exits 0, nemoclaw argv contains "share" and "mount"
# ===========================================================================
echo ""
echo "--- GROUP B (D-03): tick mount-down + remount OK → nemoclaw share mount invoked ---"

if [[ ! -f "${TICK_SH}" ]]; then
  fail "GROUP-B: tick script missing — RED state in Wave 1"
else
  TMP_HOME_B=$(make_home)
  NEMO_B=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-b.XXXXXX")
  MOUNT_B=$(mktemp "${TMPDIR:-/tmp}/test-mount-argv-b.XXXXXX")
  TMP_HOMES+=("${NEMO_B}" "${MOUNT_B}")

  # Pre-create fake mount dir so cron.sh delegation doesn't hard-fail on missing dirs
  MNT_B="${TMP_HOME_B}/sbx-openclaw-revenium-spike"
  mkdir -p "${MNT_B}/skills/revenium" "${MNT_B}/agents/main/sessions"

  rc_b=0
  output_b=$(STUB_MOUNT_UP=0 STUB_SSHFS_RC=0 run_tick "${TMP_HOME_B}" "${NEMO_B}" "${MOUNT_B}" 2>&1) || rc_b=$?

  # Assert nemoclaw was called with share mount args
  if [[ -f "${NEMO_B}" ]] && grep -qF "share" "${NEMO_B}" && grep -qF "mount" "${NEMO_B}"; then
    pass "GROUP-B: nemoclaw argv contains 'share' and 'mount' after remount attempt"
  else
    fail "GROUP-B: nemoclaw share mount NOT found in argv (tick does not attempt remount)"
  fi

  # Assert sandbox name was part of the nemoclaw call
  if [[ -f "${NEMO_B}" ]] && grep -qF "revenium-spike" "${NEMO_B}"; then
    pass "GROUP-B: nemoclaw argv contains sandbox name 'revenium-spike'"
  else
    fail "GROUP-B: sandbox name not found in nemoclaw argv"
  fi
fi

# ===========================================================================
# GROUP C (SC4): cron.sh / report.sh / guardrail-check.sh are byte-identical to baseline
#   These shared workhorse scripts must not be modified by Phase 14.
#   Assert current sha256 == pinned constant.
# ===========================================================================
echo ""
echo "--- GROUP C (SC4): shared scripts byte-identical to pinned baseline ---"

_check_sha() {
  local label="$1"
  local file="$2"
  local expected="$3"
  if [[ ! -f "${file}" ]]; then
    fail "GROUP-C: ${label} not found at ${file}"
    return
  fi
  local actual
  actual=$(shasum -a 256 "${file}" | awk '{print $1}')
  if [[ "${actual}" == "${expected}" ]]; then
    pass "GROUP-C: ${label} sha256 matches SC4 baseline"
  else
    fail "GROUP-C: ${label} sha256 MISMATCH — file was modified (violates SC4)"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
  fi
}

_check_sha "scripts/cron.sh"            "${CRON_SH}"      "${SC4_CRON_SHA}"
_check_sha "scripts/report.sh"          "${REPORT_SH}"    "${SC4_REPORT_SHA}"
_check_sha "scripts/guardrail-check.sh" "${GUARDRAIL_SH}" "${SC4_GUARDRAIL_SHA}"

# ===========================================================================
# GROUP D (D-02): install writes ~/.nemoclaw/revenium-host.env with mode 600
#   and the key value never appears in the crontab line or any captured argv.
# ===========================================================================
echo ""
echo "--- GROUP D (D-02): install writes revenium-host.env 600, key not in argv/crontab ---"

if [[ ! -f "${INSTALL_SH}" ]]; then
  fail "GROUP-D: install script missing — RED state in Wave 1"
else
  TMP_HOME_D=$(make_home)
  MOUNT_D=$(mktemp "${TMPDIR:-/tmp}/test-mount-argv-d.XXXXXX")
  TMP_HOMES+=("${MOUNT_D}")
  CTAB_D="${TMP_HOME_D}/.nemoclaw/stub-crontab"
  touch "${CTAB_D}"

  _TEST_KEY="supersecret-api-key-D-02-test"

  rc_d=0
  output_d=$(REVENIUM_API_KEY="${_TEST_KEY}" \
             STUB_CRONTAB_FILE="${CTAB_D}" \
             STUB_MOUNT_ENV_ARGV_FILE="${MOUNT_D}" \
             HOME="${TMP_HOME_D}" \
             PATH="${TMP_HOME_D}/.local/bin:${PATH}" \
             REVENIUM_SANDBOX_NAME="revenium-spike" \
             bash "${INSTALL_SH}" --sandbox "revenium-spike" 2>&1) || rc_d=$?

  ENV_FILE="${TMP_HOME_D}/.nemoclaw/revenium-host.env"

  # Assert env file exists
  if [[ -f "${ENV_FILE}" ]]; then
    pass "GROUP-D: revenium-host.env was created"
  else
    fail "GROUP-D: revenium-host.env NOT created by install"
  fi

  # Assert mode 600
  if [[ -f "${ENV_FILE}" ]]; then
    _mode=$(stat -c '%a' "${ENV_FILE}" 2>/dev/null || stat -f '%A' "${ENV_FILE}" 2>/dev/null || echo "unknown")
    if [[ "${_mode}" == "600" ]]; then
      pass "GROUP-D: revenium-host.env mode is 600"
    else
      fail "GROUP-D: revenium-host.env mode is ${_mode} (expected 600)"
    fi
  fi

  # Assert key contains REVENIUM_API_KEY
  if [[ -f "${ENV_FILE}" ]] && grep -qF "REVENIUM_API_KEY" "${ENV_FILE}"; then
    pass "GROUP-D: revenium-host.env contains REVENIUM_API_KEY"
  else
    fail "GROUP-D: REVENIUM_API_KEY not found in revenium-host.env"
  fi

  # Assert key value NOT in crontab line (T-14-03)
  if [[ -f "${CTAB_D}" ]] && grep -qF "${_TEST_KEY}" "${CTAB_D}" 2>/dev/null; then
    fail "GROUP-D: API key appears in crontab (T-14-03 — key must not be in cron line)"
  else
    pass "GROUP-D: API key NOT in crontab line"
  fi

  # Assert key value NOT in captured mount argv (T-14-03)
  if [[ -f "${MOUNT_D}" ]] && grep -qF "${_TEST_KEY}" "${MOUNT_D}" 2>/dev/null; then
    fail "GROUP-D: API key appears in captured argv (T-14-03 — secret in argv/logs)"
  else
    pass "GROUP-D: API key NOT in captured argv"
  fi
fi

# ===========================================================================
# GROUP E (D-07): install idempotency — exactly ONE per-sandbox marker line;
#   pre-existing standalone "# revenium-metering" line preserved untouched.
# ===========================================================================
echo ""
echo "--- GROUP E (D-07): install idempotent; standalone cron coexists ---"

if [[ ! -f "${INSTALL_SH}" ]]; then
  fail "GROUP-E: install script missing — RED state in Wave 1"
else
  TMP_HOME_E=$(make_home)
  MOUNT_E=$(mktemp "${TMPDIR:-/tmp}/test-mount-argv-e.XXXXXX")
  TMP_HOMES+=("${MOUNT_E}")
  CTAB_E="${TMP_HOME_E}/.nemoclaw/stub-crontab"

  # Pre-populate with standalone entry
  printf '* * * * * /standalone/cron # revenium-metering\n' > "${CTAB_E}"

  _run_install_e() {
    REVENIUM_API_KEY="test-key-e" \
    STUB_CRONTAB_FILE="${CTAB_E}" \
    STUB_MOUNT_ENV_ARGV_FILE="${MOUNT_E}" \
    HOME="${TMP_HOME_E}" \
    PATH="${TMP_HOME_E}/.local/bin:${PATH}" \
    REVENIUM_SANDBOX_NAME="revenium-spike" \
    bash "${INSTALL_SH}" --sandbox "revenium-spike" 2>&1
  }

  # Run install twice
  rc_e1=0; output_e1=$(_run_install_e) || rc_e1=$?
  rc_e2=0; output_e2=$(_run_install_e) || rc_e2=$?

  # Assert exactly ONE per-sandbox marker line
  _marker_count=$(grep -cF "# revenium-metering-nemoclaw:revenium-spike" "${CTAB_E}" 2>/dev/null || echo 0)
  if [[ "${_marker_count}" -eq 1 ]]; then
    pass "GROUP-E: exactly ONE nemoclaw marker line after two installs (idempotent)"
  else
    fail "GROUP-E: expected 1 nemoclaw marker line, found ${_marker_count}"
  fi

  # Assert standalone entry is preserved
  if grep -qF "# revenium-metering" "${CTAB_E}" 2>/dev/null && \
     grep -vF "nemoclaw" "${CTAB_E}" | grep -qF "# revenium-metering"; then
    pass "GROUP-E: standalone '# revenium-metering' entry preserved after nemoclaw install"
  else
    fail "GROUP-E: standalone '# revenium-metering' entry missing or overwritten"
  fi
fi

# ===========================================================================
# GROUP F (D-04): install with no sshfs on PATH → exits non-zero, message
#   contains "sshfs", no crontab entry written.
# ===========================================================================
echo ""
echo "--- GROUP F (D-04): install without sshfs → exits non-zero, no cron entry ---"

if [[ ! -f "${INSTALL_SH}" ]]; then
  fail "GROUP-F: install script missing — RED state in Wave 1"
else
  TMP_HOME_F=$(make_home)
  CTAB_F="${TMP_HOME_F}/.nemoclaw/stub-crontab"
  touch "${CTAB_F}"

  # Build a PATH that excludes sshfs (remove the tmp bin dir's sshfs symlink)
  rm -f "${TMP_HOME_F}/.local/bin/sshfs"
  # Also, disable auto-install by ensuring neither apt-get nor dnf exists on PATH.
  # We achieve this by using only the stub bin dir (no system commands).

  # Add a no-op apt-get and dnf stub that fails (simulates no package manager)
  printf '#!/bin/bash\nexit 1\n' > "${TMP_HOME_F}/.local/bin/apt-get"
  printf '#!/bin/bash\nexit 1\n' > "${TMP_HOME_F}/.local/bin/dnf"
  chmod +x "${TMP_HOME_F}/.local/bin/apt-get" "${TMP_HOME_F}/.local/bin/dnf"

  rc_f=0
  output_f=$(REVENIUM_API_KEY="test-key-f" \
             STUB_CRONTAB_FILE="${CTAB_F}" \
             HOME="${TMP_HOME_F}" \
             PATH="${TMP_HOME_F}/.local/bin" \
             REVENIUM_SANDBOX_NAME="revenium-spike" \
             bash "${INSTALL_SH}" --sandbox "revenium-spike" 2>&1) || rc_f=$?

  # Assert non-zero exit
  if [[ "${rc_f}" -ne 0 ]]; then
    pass "GROUP-F: install exits non-zero when sshfs absent"
  else
    fail "GROUP-F: install exited 0 with no sshfs (should abort)"
  fi

  # Assert output mentions sshfs
  if echo "${output_f}" | grep -qi "sshfs"; then
    pass "GROUP-F: output mentions 'sshfs' when sshfs absent"
  else
    fail "GROUP-F: output does not mention 'sshfs' on missing sshfs"
  fi

  # Assert no crontab entry was written
  if [[ -f "${CTAB_F}" ]] && grep -qF "revenium-metering-nemoclaw" "${CTAB_F}" 2>/dev/null; then
    fail "GROUP-F: crontab entry was written despite sshfs being absent"
  else
    pass "GROUP-F: no crontab entry written when sshfs absent"
  fi
fi

# ===========================================================================
# GROUP G (D-08): interval handling
#   --interval 5  → cron schedule is */5 * * * *
#   --interval 0  → exits 2 (out of range)
#   --interval 60 → exits 2 (out of range)
# ===========================================================================
echo ""
echo "--- GROUP G (D-08): interval --interval 5 → */5 schedule; out-of-range exits 2 ---"

if [[ ! -f "${INSTALL_SH}" ]]; then
  fail "GROUP-G: install script missing — RED state in Wave 1"
else
  TMP_HOME_G=$(make_home)
  CTAB_G="${TMP_HOME_G}/.nemoclaw/stub-crontab"
  touch "${CTAB_G}"

  # Test --interval 5
  rc_g5=0
  output_g5=$(REVENIUM_API_KEY="test-key-g" \
              STUB_CRONTAB_FILE="${CTAB_G}" \
              HOME="${TMP_HOME_G}" \
              PATH="${TMP_HOME_G}/.local/bin:${PATH}" \
              REVENIUM_SANDBOX_NAME="revenium-spike" \
              bash "${INSTALL_SH}" --sandbox "revenium-spike" --interval 5 2>&1) || rc_g5=$?

  if [[ -f "${CTAB_G}" ]] && grep -qF "*/5 * * * *" "${CTAB_G}" 2>/dev/null; then
    pass "GROUP-G: --interval 5 produces */5 * * * * schedule"
  else
    fail "GROUP-G: */5 * * * * NOT found in crontab after --interval 5"
  fi

  # Test --interval 0 → exits 2
  rc_g0=0
  output_g0=$(REVENIUM_API_KEY="test-key-g" \
              HOME="${TMP_HOME_G}" \
              PATH="${TMP_HOME_G}/.local/bin:${PATH}" \
              REVENIUM_SANDBOX_NAME="revenium-spike" \
              bash "${INSTALL_SH}" --sandbox "revenium-spike" --interval 0 2>&1) || rc_g0=$?

  if [[ "${rc_g0}" -eq 2 ]]; then
    pass "GROUP-G: --interval 0 exits 2 (out of range)"
  else
    fail "GROUP-G: --interval 0 exited ${rc_g0} (expected 2)"
  fi

  # Test --interval 60 → exits 2
  rc_g60=0
  output_g60=$(REVENIUM_API_KEY="test-key-g" \
               HOME="${TMP_HOME_G}" \
               PATH="${TMP_HOME_G}/.local/bin:${PATH}" \
               REVENIUM_SANDBOX_NAME="revenium-spike" \
               bash "${INSTALL_SH}" --sandbox "revenium-spike" --interval 60 2>&1) || rc_g60=$?

  if [[ "${rc_g60}" -eq 2 ]]; then
    pass "GROUP-G: --interval 60 exits 2 (out of range)"
  else
    fail "GROUP-G: --interval 60 exited ${rc_g60} (expected 2)"
  fi
fi

# ===========================================================================
# GROUP H (uninstall): after install, uninstall removes ONLY the sandbox marker;
#   a standalone "# revenium-metering" line is left intact.
# ===========================================================================
echo ""
echo "--- GROUP H (uninstall): uninstall removes per-sandbox entry, standalone preserved ---"

if [[ ! -f "${INSTALL_SH}" ]] || [[ ! -f "${UNINSTALL_SH}" ]]; then
  fail "GROUP-H: install or uninstall script missing — RED state in Wave 1"
else
  TMP_HOME_H=$(make_home)
  CTAB_H="${TMP_HOME_H}/.nemoclaw/stub-crontab"

  # Pre-populate with standalone entry
  printf '* * * * * /standalone/cron # revenium-metering\n' > "${CTAB_H}"

  # Install for revenium-spike
  rc_h_install=0
  output_h_install=$(REVENIUM_API_KEY="test-key-h" \
                     STUB_CRONTAB_FILE="${CTAB_H}" \
                     HOME="${TMP_HOME_H}" \
                     PATH="${TMP_HOME_H}/.local/bin:${PATH}" \
                     REVENIUM_SANDBOX_NAME="revenium-spike" \
                     bash "${INSTALL_SH}" --sandbox "revenium-spike" 2>&1) || rc_h_install=$?

  # Uninstall for revenium-spike
  rc_h_uninst=0
  output_h_uninst=$(STUB_CRONTAB_FILE="${CTAB_H}" \
                    HOME="${TMP_HOME_H}" \
                    PATH="${TMP_HOME_H}/.local/bin:${PATH}" \
                    bash "${UNINSTALL_SH}" "revenium-spike" 2>&1) || rc_h_uninst=$?

  # Assert nemoclaw marker is gone
  if [[ -f "${CTAB_H}" ]] && grep -qF "# revenium-metering-nemoclaw:revenium-spike" "${CTAB_H}" 2>/dev/null; then
    fail "GROUP-H: nemoclaw marker still present after uninstall"
  else
    pass "GROUP-H: nemoclaw marker removed by uninstall"
  fi

  # Assert standalone entry is still present
  if [[ -f "${CTAB_H}" ]] && grep -qF "# revenium-metering" "${CTAB_H}" 2>/dev/null && \
     grep -vF "nemoclaw" "${CTAB_H}" | grep -qF "# revenium-metering"; then
    pass "GROUP-H: standalone '# revenium-metering' preserved after uninstall"
  else
    fail "GROUP-H: standalone '# revenium-metering' removed or missing after uninstall"
  fi
fi

# ===========================================================================
# GROUP I (D-06 TTL stamp): healthy tick over UP mount → status file gets
#   _maxAgeSeconds key written post-cron.sh by the tick wrapper.
#   Pre-position a fake guardrail-status.json, run tick with STUB_MOUNT_UP=1
#   (mount is up), assert _maxAgeSeconds appears in the status file after tick.
# ===========================================================================
echo ""
echo "--- GROUP I (D-06 TTL stamp): healthy tick → _maxAgeSeconds in status file ---"

if [[ ! -f "${TICK_SH}" ]]; then
  fail "GROUP-I: tick script missing — RED state in Wave 1"
else
  TMP_HOME_I=$(make_home)
  NEMO_I=$(mktemp "${TMPDIR:-/tmp}/test-nemo-argv-i.XXXXXX")
  MOUNT_I=$(mktemp "${TMPDIR:-/tmp}/test-mount-argv-i.XXXXXX")
  TMP_HOMES+=("${NEMO_I}" "${MOUNT_I}")

  # Pre-create fake mount dir and a minimal guardrail-status.json
  MNT_I="${TMP_HOME_I}/sbx-openclaw-revenium-spike"
  mkdir -p "${MNT_I}/skills/revenium" "${MNT_I}/agents/main/sessions"
  STATUS_I="${MNT_I}/skills/revenium/guardrail-status.json"
  printf '{"halted":false,"warned":false,"lastChecked":"2026-06-08T00:00:00Z","rules":[]}\n' \
    > "${STATUS_I}"

  rc_i=0
  output_i=$(STUB_MOUNT_UP=1 run_tick "${TMP_HOME_I}" "${NEMO_I}" "${MOUNT_I}" 2>&1) || rc_i=$?

  # Assert _maxAgeSeconds field in status file
  if [[ -f "${STATUS_I}" ]] && grep -qF "_maxAgeSeconds" "${STATUS_I}"; then
    pass "GROUP-I: _maxAgeSeconds present in guardrail-status.json after healthy tick (D-06)"
  else
    fail "GROUP-I: _maxAgeSeconds NOT found in guardrail-status.json after tick (D-06 TTL stamp missing)"
  fi
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Results: PASS=${PASS} FAIL=${FAIL}"
echo ""
echo "NOTE: In Wave 1 (scripts absent) FAIL>0 is the expected RED state."
echo "      GROUP A/B/D/E/F/G/H/I depend on Wave-2 scripts; GROUP C always runs."
echo "      Do NOT weaken assertions — RED is correct until Wave 2 ships the scripts."
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
