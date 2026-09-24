#!/usr/bin/env bash
# =============================================================================
# test_bounded_run.sh — Hermetic unit suite for scripts/bounded-run.sh
# (GATE-03 gap-closure, 18-VERIFICATION gap #2 / 18-REVIEW CR-03).
#
# Pins exit-status fidelity, stdout purity, promptness, real ceiling expiry,
# function-bypass (no recursion into a same-named shell function), and the
# once-per-process notice stream/frequency.
#
# SECURITY: never eval's or string-interpolates captured output into shell
#   commands.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BOUNDED_RUN_SH="${REPO_ROOT}/scripts/bounded-run.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
skip() { echo "SKIP: $1"; }

# ---------------------------------------------------------------------------
# Cleanup: track all tmp files/dirs globally and clean up on exit.
# ---------------------------------------------------------------------------
declare -a TMP_HOMES=()

cleanup() {
  for d in "${TMP_HOMES[@]+"${TMP_HOMES[@]}"}"; do
    rm -rf "${d}" 2>/dev/null || true
  done
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Guard: scripts/bounded-run.sh must exist.
# ---------------------------------------------------------------------------
if [[ ! -f "${BOUNDED_RUN_SH}" ]]; then
  echo ""
  echo "=== BOUNDED-RUN.SH MISSING ==="
  fail "bounded-run-script-exists: ${BOUNDED_RUN_SH} not found"
  echo ""
  echo "Results: ${PASS} passed, ${FAIL} failed"
  exit 1
fi

# ===========================================================================
# GROUP BR-A: native path passthrough (only when GNU `timeout` is on PATH).
# ===========================================================================
echo ""
echo "--- GROUP BR-A: native path passthrough ---"

if command -v timeout >/dev/null 2>&1; then
  out_a=$(. "${BOUNDED_RUN_SH}"; bounded_run 30 echo BR_A_SENTINEL 2>/dev/null)
  rc_a=$?
  if [[ "${out_a}" == "BR_A_SENTINEL" && "${rc_a}" -eq 0 ]]; then
    pass "BR-A: native path captures exact stdout and returns 0"
  else
    fail "BR-A: native path stdout/rc mismatch (out=${out_a} rc=${rc_a})"
  fi

  (. "${BOUNDED_RUN_SH}"; bounded_run 2 sleep 20) >/dev/null 2>&1
  rc_a2=$?
  if [[ "${rc_a2}" -eq 124 ]]; then
    pass "BR-A: native path returns 124 on ceiling expiry"
  else
    fail "BR-A: native path expiry rc=${rc_a2}, expected 124"
  fi
else
  skip "BR-A: native path passthrough (host has no GNU 'timeout' on PATH)"
  skip "BR-A: native path expiry (host has no GNU 'timeout' on PATH)"
fi

# ===========================================================================
# GROUP BR-B: portable path passthrough — stdout purity + promptness.
# ===========================================================================
echo ""
echo "--- GROUP BR-B: portable path passthrough ---"

_br_b_start=$SECONDS
out_b=$(BOUNDED_RUN_FORCE_PORTABLE=1 bash -c ". '${BOUNDED_RUN_SH}'; bounded_run 30 echo BR_B_SENTINEL 2>/dev/null")
rc_b=$?
_br_b_elapsed=$((SECONDS - _br_b_start))

if [[ "${out_b}" == "BR_B_SENTINEL" ]]; then
  pass "BR-B: portable path captures exact stdout with no notice text mixed in"
else
  fail "BR-B: portable path stdout mismatch (out=${out_b})"
fi

if [[ "${rc_b}" -eq 0 ]]; then
  pass "BR-B: portable path returns 0 for a successful fast command"
else
  fail "BR-B: portable path rc=${rc_b}, expected 0"
fi

if [[ "${_br_b_elapsed}" -lt 5 ]]; then
  pass "BR-B: portable path completes in under 5s (elapsed=${_br_b_elapsed}) — pipe not held open"
else
  fail "BR-B: portable path took ${_br_b_elapsed}s (>=5s) — watchdog may be holding the pipe open"
fi

# ===========================================================================
# GROUP BR-C: portable path exit-status fidelity.
# ===========================================================================
echo ""
echo "--- GROUP BR-C: portable path exit-status fidelity ---"

(BOUNDED_RUN_FORCE_PORTABLE=1 bash -c ". '${BOUNDED_RUN_SH}'; bounded_run 30 sh -c 'exit 7'") >/dev/null 2>&1
rc_c=$?
if [[ "${rc_c}" -eq 7 ]]; then
  pass "BR-C: portable path returns the child's own exit status (7), not its own or the watchdog's"
else
  fail "BR-C: portable path rc=${rc_c}, expected 7"
fi

# ===========================================================================
# GROUP BR-D: portable path ceiling expiry.
# ===========================================================================
echo ""
echo "--- GROUP BR-D: portable path ceiling expiry ---"

_br_d_start=$SECONDS
(BOUNDED_RUN_FORCE_PORTABLE=1 bash -c ". '${BOUNDED_RUN_SH}'; bounded_run 2 sleep 30") >/dev/null 2>&1
rc_d=$?
_br_d_elapsed=$((SECONDS - _br_d_start))

if [[ "${rc_d}" -eq 124 ]]; then
  pass "BR-D: portable path returns 124 on ceiling expiry"
else
  fail "BR-D: portable path expiry rc=${rc_d}, expected 124"
fi

if [[ "${_br_d_elapsed}" -lt 10 ]]; then
  pass "BR-D: portable path expiry completes in under 10s (elapsed=${_br_d_elapsed})"
else
  fail "BR-D: portable path expiry took ${_br_d_elapsed}s (>=10s) — ceiling did not actually kill the child"
fi

# ===========================================================================
# GROUP BR-E: function bypass — bounded_run must dispatch via `command`,
# never re-entering a shell function that shadows the binary name.
# ===========================================================================
echo ""
echo "--- GROUP BR-E: function bypass (command builtin dispatch) ---"

out_e=$(BOUNDED_RUN_FORCE_PORTABLE=1 bash -c "
  . '${BOUNDED_RUN_SH}'
  date() { echo BR_E_SHADOW; }
  bounded_run 10 date 2>/dev/null
")
if echo "${out_e}" | grep -qF "BR_E_SHADOW"; then
  fail "BR-E: shadow sentinel present — bounded_run re-entered the shadowing shell function instead of the real binary"
else
  pass "BR-E: shadow sentinel absent — bounded_run dispatched through 'command', bypassing the shadowing function"
fi

# ===========================================================================
# GROUP BR-F: notice stream + once-per-process.
# ===========================================================================
echo ""
echo "--- GROUP BR-F: notice stream and once-per-process ---"

_br_f_stdout="$(mktemp "${TMPDIR:-/tmp}/test-br-f-stdout.XXXXXX")"
_br_f_stderr="$(mktemp "${TMPDIR:-/tmp}/test-br-f-stderr.XXXXXX")"
TMP_HOMES+=("${_br_f_stdout}" "${_br_f_stderr}")

BOUNDED_RUN_FORCE_PORTABLE=1 bash -c "
  . '${BOUNDED_RUN_SH}'
  bounded_run 30 echo BR_F_FIRST
  bounded_run 30 echo BR_F_SECOND
" >"${_br_f_stdout}" 2>"${_br_f_stderr}"

if grep -qF "portable bash time-bound" "${_br_f_stderr}"; then
  pass "BR-F: stderr contains the fixed notice substring"
else
  fail "BR-F: stderr missing the fixed notice substring 'portable bash time-bound'"
fi

if grep -qF "portable bash time-bound" "${_br_f_stdout}"; then
  fail "BR-F: stdout unexpectedly contains the notice substring"
else
  pass "BR-F: stdout does not contain the notice substring"
fi

_br_f_notice_count=$(grep -cF "portable bash time-bound" "${_br_f_stderr}")
if [[ "${_br_f_notice_count}" -eq 1 ]]; then
  pass "BR-F: notice printed exactly once across two bounded_run calls in one process"
else
  fail "BR-F: notice printed ${_br_f_notice_count} times, expected exactly 1"
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
echo ""
echo "NOTE: GROUPs BR-A..BR-F. BR-A groups SKIP on hosts without GNU 'timeout'"
echo "      on PATH (e.g. stock macOS) — this is expected, not a failure."
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
