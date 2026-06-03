#!/usr/bin/env bash
# stub-meta-check.sh — Self-check for tests/stub-revenium.sh
#
# Asserts all Phase 6 stub behaviors described in 06-01-PLAN.md Task 1.
# Exits 0 only when all checks pass.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STUB="${SCRIPT_DIR}/stub-revenium.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# ---------------------------------------------------------------------------
# 1. Valid bash
# ---------------------------------------------------------------------------
if bash -n "${STUB}" 2>/dev/null; then
  pass "bash -n stub-revenium.sh (valid bash)"
else
  fail "bash -n stub-revenium.sh (syntax error)"
fi

# ---------------------------------------------------------------------------
# 2. meter completion --help prints --agentic-job-id and exits 0
# ---------------------------------------------------------------------------
help_out=$(bash "${STUB}" meter completion --help 2>&1)
help_rc=$?
if [[ "${help_rc}" -eq 0 ]] && echo "${help_out}" | grep -q -- "--agentic-job-id"; then
  pass "meter completion --help prints --agentic-job-id and exits 0"
else
  fail "meter completion --help: rc=${help_rc}, output='${help_out}'"
fi

# ---------------------------------------------------------------------------
# 3. jobs --help exits 0 without STUB_REVENIUM_NO_JOBS
# ---------------------------------------------------------------------------
bash "${STUB}" jobs --help >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
  pass "jobs --help exits 0 (normal path)"
else
  fail "jobs --help did not exit 0 (normal path)"
fi

# ---------------------------------------------------------------------------
# 4. jobs --help exits non-zero with STUB_REVENIUM_NO_JOBS=1
# ---------------------------------------------------------------------------
STUB_REVENIUM_NO_JOBS=1 bash "${STUB}" jobs --help >/dev/null 2>&1
if [[ $? -ne 0 ]]; then
  pass "jobs --help exits non-zero with STUB_REVENIUM_NO_JOBS=1"
else
  fail "jobs --help should exit non-zero with STUB_REVENIUM_NO_JOBS=1 but exited 0"
fi

# ---------------------------------------------------------------------------
# 5. STUB_REVENIUM_409_FOR: jobs create emits conflict string and exits non-zero
# ---------------------------------------------------------------------------
conflict_stderr=$(STUB_REVENIUM_409_FOR=abc bash "${STUB}" jobs create --agentic-job-id abc 2>&1 >/dev/null)
conflict_rc=$?
if [[ "${conflict_rc}" -ne 0 ]] && echo "${conflict_stderr}" | grep -qi "conflict"; then
  pass "STUB_REVENIUM_409_FOR: jobs create emits 409-style conflict to stderr and exits non-zero"
else
  fail "STUB_REVENIUM_409_FOR: rc=${conflict_rc}, stderr='${conflict_stderr}'"
fi

# ---------------------------------------------------------------------------
# 6. STUB_REVENIUM_JOBS_FAIL: jobs create emits NON-409 error and exits non-zero
# ---------------------------------------------------------------------------
fail_stderr=$(STUB_REVENIUM_JOBS_FAIL=1 bash "${STUB}" jobs create --agentic-job-id abc 2>&1 >/dev/null)
fail_rc=$?
if [[ "${fail_rc}" -ne 0 ]] && ! echo "${fail_stderr}" | grep -qi "409\|already.exist\|conflict"; then
  pass "STUB_REVENIUM_JOBS_FAIL: jobs create emits non-409 error and exits non-zero"
else
  fail "STUB_REVENIUM_JOBS_FAIL: rc=${fail_rc}, stderr='${fail_stderr}' (should be non-zero non-409)"
fi

# ---------------------------------------------------------------------------
# 7. STUB_REVENIUM_JOBS_FAIL does NOT affect meter completion (exits 0)
# ---------------------------------------------------------------------------
STUB_REVENIUM_JOBS_FAIL=1 bash "${STUB}" meter completion --agentic-job-id x >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
  pass "STUB_REVENIUM_JOBS_FAIL: meter completion still exits 0 (scoped to jobs only)"
else
  fail "STUB_REVENIUM_JOBS_FAIL: meter completion should exit 0 but did not"
fi

# ---------------------------------------------------------------------------
# 8. STUB_REVENIUM_JOBS_FAIL does NOT affect config show (exits 0)
# ---------------------------------------------------------------------------
STUB_REVENIUM_JOBS_FAIL=1 bash "${STUB}" config show >/dev/null 2>&1
if [[ $? -eq 0 ]]; then
  pass "STUB_REVENIUM_JOBS_FAIL: config show still exits 0 (scoped to jobs only)"
else
  fail "STUB_REVENIUM_JOBS_FAIL: config show should exit 0 but did not"
fi

# ---------------------------------------------------------------------------
# 9. Normal meter completion does NOT print --agentic-job-id on stdout
# ---------------------------------------------------------------------------
meter_out=$(bash "${STUB}" meter completion --agentic-job-id x 2>/dev/null)
if ! echo "${meter_out}" | grep -q -- "--agentic-job-id"; then
  pass "meter completion (non-help) does NOT print --agentic-job-id on stdout"
else
  fail "meter completion (non-help) printed --agentic-job-id on stdout: '${meter_out}'"
fi

# ---------------------------------------------------------------------------
# 10. Argv-capture block is unchanged (tokens appended one-per-line)
# ---------------------------------------------------------------------------
CAPTURE_FILE=$(mktemp "${TMPDIR:-/tmp}/stub-meta-check-argv.XXXXXX")
STUB_REVENIUM_ARGV_FILE="${CAPTURE_FILE}" bash "${STUB}" meter completion --agentic-job-id x >/dev/null 2>&1
captured=$(cat "${CAPTURE_FILE}" 2>/dev/null)
rm -f "${CAPTURE_FILE}"

if echo "${captured}" | grep -q "^meter$" && echo "${captured}" | grep -q "^completion$" && echo "${captured}" | grep -q "^--agentic-job-id$" && echo "${captured}" | grep -q "^x$"; then
  pass "argv-capture: tokens appended one-per-line (meter completion --agentic-job-id x all captured)"
else
  fail "argv-capture: expected tokens not found. captured='$(echo "${captured}" | tr '\n' '|')'"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
