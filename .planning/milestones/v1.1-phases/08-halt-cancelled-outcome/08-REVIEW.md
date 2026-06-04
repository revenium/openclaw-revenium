---
phase: 08-halt-cancelled-outcome
reviewed: 2026-06-03T00:00:00Z
depth: standard
files_reviewed: 3
files_reviewed_list:
  - scripts/report.sh
  - tests/stub-revenium.sh
  - tests/test_report_jobs_argv.sh
findings:
  critical: 0
  warning: 5
  info: 4
  total: 9
status: issues_found
---

# Phase 8: Code Review Report

**Reviewed:** 2026-06-03T00:00:00Z
**Depth:** standard
**Files Reviewed:** 3
**Status:** issues_found

## Summary

Reviewed the Phase 8 account-level halt handler (`handle_halt()` in `scripts/report.sh`),
the halt-specific stub failure switch in `tests/stub-revenium.sh`, and the GROUP I–M
RED→GREEN tests in `tests/test_report_jobs_argv.sh`.

Overall the implementation is careful and follows the established discipline well:
shell-array argv construction (`cmd=(... "$val")`, never `eval`), env-passing python3
heredocs with single-quoted `<<'PY'` delimiters (no `${VAR}` interpolation into program
text), the ledger-gated 409-as-success idiom is reused correctly, and `halt_ok`
propagation correctly withholds the `JOB:halt:<haltedAt>` gate on hard failure so the
halt retries next tick. The non-fatal/fail-open contract (`handle_halt || warn`, whole
handler gated on `JOBS_CLI_CAPABLE`) is sound. I found **no BLOCKER-level** injection or
data-loss defects — argv is never eval'd and untrusted timestamps never reach a python
program string.

The findings below are robustness/quality concerns. The two most material are: (1)
untrusted `HALTED_AT` and ledger-derived `open_job_id` are interpolated into `grep`
**regex** patterns rather than matched as fixed strings (`grep -F`), and (2) a degraded
synthetic-id collision when `python3` is unavailable. Neither corrupts billing in normal
operation because of the per-`haltedAt` gate and the 409-as-success backstop, but both
should be hardened.

## Warnings

### WR-01: `HALTED_AT` interpolated into grep regex instead of fixed-string match

**File:** `scripts/report.sh:1063`, `scripts/report.sh:1200`
**Issue:** The exactly-once gate uses
`grep -q "^JOB:halt:${HALTED_AT}$" "${JOBS_LEDGER_FILE}"`. `HALTED_AT` is read from
`guardrail-status.json` (written by the guardrail engine) and is treated as a regex, not a
literal. ISO timestamps contain `.` (a regex wildcard) and `:`. Two distinct `haltedAt`
values that differ only at a `.` position would collide (e.g. a stored
`...00.000Z` gate would match a probe for `...00X000Z`), causing the handler to wrongly
believe a *different* halt was already processed and skip closing jobs. More broadly, any
non-`[A-Za-z0-9._:-]` character that the engine ever emits in `haltedAt` becomes an active
regex metacharacter. The codebase elsewhere already mandates literal matching for
untrusted ids (see `meta_lookup` WR-04 note at line 504-507 using `awk $1==id`).
**Fix:** Use fixed-string matching for both the gate probe and keep the append as-is:
```bash
# Step 3 gate
if grep -qF -- "JOB:halt:${HALTED_AT}" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
  return 0
fi
```
(If you need the full-line anchor, prefer `grep -qxF -- "JOB:halt:${HALTED_AT}"`.)

### WR-02: `open_job_id` (from ledger) interpolated into grep regex

**File:** `scripts/report.sh:1120`
**Issue:** The per-job idempotency re-check
`grep -q "^JOB:${open_job_id}:outcome:" "${JOBS_LEDGER_FILE}"` interpolates the job id —
which originates from `agentic_job_id` marker values — into a regex. Although markers are
sanitized for `|`, newline, `:` upstream (line 369), `agentic_job_id` values are NOT
sanitized for regex metacharacters like `.`, `*`, `[`, `+`, `(`. A crafted or accidental
id containing such characters could cause the "already closed" check to false-positive
(skipping a needed CANCELLED close) or false-negative. Same class of bug as WR-01.
**Fix:** Match the ledger key as a fixed string with an explicit delimiter:
```bash
if grep -qF -- "JOB:${open_job_id}:outcome:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
  continue
fi
```
Apply the same `-F` treatment to the synthetic-id greps at lines 1149, 1173, 1174 for
consistency (synthetic ids are `[a-f0-9]{4}`-suffixed and currently safe, but `-F` makes
the intent explicit and future-proof).

### WR-03: Synthetic id collapses to `guardrail-halt-` when python3 is unavailable

**File:** `scripts/report.sh:1069-1079`
**Issue:** `HALT_HEX` is computed by a python3 heredoc with only `|| true` as a fallback.
If `python3` is absent or fails, `HALT_HEX=""` and `synth_id="guardrail-halt-"` (empty
hex). Every distinct halt that takes the synthetic-fallback path (open-count == 0) then
mints/closes a job under the *same* degenerate id `guardrail-halt-`, conflating unrelated
interruption events into one Revenium job. Unlike the rest of report.sh (e.g. lines 572,
800, `get_offset` line 182), this derivation has no meaningful degraded-mode fallback. The
per-`haltedAt` gate still prevents re-processing the *same* halt, so billing is not
duplicated, but cross-halt attribution is corrupted.
**Fix:** Guard against an empty hex and fall back to a deterministic non-empty token:
```bash
if [[ -z "${HALT_HEX}" ]]; then
  # Deterministic fallback: derive a short token from HALTED_AT without python.
  HALT_HEX=$(printf '%s' "${HALTED_AT}" | cksum | cut -d' ' -f1)
  HALT_HEX="${HALT_HEX:0:8}"
fi
local synth_id="guardrail-halt-${HALT_HEX}"
```
At minimum, abort the synthetic-fallback path (leave `halt_ok=false`, do not write the
gate) when `HALT_HEX` is empty so the next tick retries once python3 is back.

### WR-04: Halt log lines lack the 64-char log-injection truncation used elsewhere

**File:** `scripts/report.sh:1136`, `scripts/report.sh:1138`
**Issue:** Throughout report.sh, job ids are truncated to 64 chars before logging to
mitigate log injection (e.g. `agentic_job_id_log="${agentic_job_id:0:64}"` at lines 743,
766, and the T-04-08 note). In `handle_halt`, `open_job_id` is logged raw:
`info "Halt: closed job CANCELLED: id=${open_job_id}"` and
`warn "Halt: outcome CANCELLED failed: id=${open_job_id} ..."`. `open_job_id` comes from
ledger lines derived from marker `agentic_job_id` values, which are only sanitized for
`|`/newline/`:` — not bounded in length and not stripped of other control bytes. This
breaks parity with the established log-hardening convention.
**Fix:** Truncate before logging, mirroring the existing idiom:
```bash
local open_job_id_log="${open_job_id:0:64}"
info "Halt: closed job CANCELLED: id=${open_job_id_log}"
...
warn "Halt: outcome CANCELLED failed: id=${open_job_id_log} exit=${halt_outcome_exit} — will retry next tick"
```

### WR-05: `run_report` helper mishandles extra-env args (latent test trap)

**File:** `tests/test_report_jobs_argv.sh:98-108`
**Issue:** `run_report` accepts trailing args as `extra_env=("$@")` and expands them as
`"${extra_env[@]+"${extra_env[@]}"}"` positioned *after* the inline `VAR=val` assignments
and *before* `bash`. Bash treats a leading `FOO=bar` token in command position (after the
assignment-prefix list ends) as a **command name**, not an env assignment — so passing
extra env via `run_report ... FOO=bar` produces `FOO=bar: command not found` rather than
exporting `FOO`. None of the Phase 8 halt tests trigger this (GROUP I/J/K/L call
`run_report` with no extra env; M1/M2 deliberately bypass the helper with a direct `bash`
invocation), so it is latent — but it is a trap that will silently mis-run any future
test that tries to pass env through this helper, and the no-op `|| true` would mask the
"command not found" failure.
**Fix:** Either document that `run_report` takes no extra env (and drop the unused
`extra_env` plumbing), or pass extra env through `env`:
```bash
run_report() {
  local openclaw_home="$1" _argv_file="$2"; shift 2
  env STUB_REVENIUM_ARGV_FILE="${_argv_file}" \
      OPENCLAW_HOME="${openclaw_home}" \
      HOME="${TMP_FAKE_HOME}" \
      "$@" \
      bash "${REPORT_SH}" 2>&1 || true
}
```

## Info

### IN-01: Empty-`OPEN_JOBS` here-string relies on guarded counter

**File:** `scripts/report.sh:1109-1111`
**Issue:** When no jobs are open, `OPEN_JOBS=""` and `<<< "${OPEN_JOBS}"` feeds the loop a
single empty line, so the loop body executes once. Correctness is preserved only because
`[[ -n "${open_job_id}" ]] && ((open_count++)) || true` guards the increment. This works
but is fragile: any future edit that drops the `-n` guard would count a phantom job and
take the wrong branch (CANCELLED-loop with one empty id vs. synthetic fallback). The
identical empty-here-string pattern also appears at the Step 6a loop (line 1117) where the
`[[ -z ... ]] && continue` guard is the only protection.
**Fix:** Consider skipping the loop entirely on empty input for clarity:
`[[ -n "${OPEN_JOBS}" ]] && while ...; done <<< "${OPEN_JOBS}"`, or document the
empty-line invariant inline.

### IN-02: `((open_count++))` returns non-zero on first increment (masked, but noted)

**File:** `scripts/report.sh:1110`
**Issue:** `((open_count++))` post-increment evaluates to the old value; when `open_count`
is 0 the arithmetic command returns exit status 1. Under `set -uo pipefail` this would be
a problem if it were the last command on a `set -e` path, but it is correctly defused by
the trailing `|| true`. No action required; flagged for awareness since the same idiom is
used consistently across the file.

### IN-03: Stub `CANCELLED`/`guardrail-halt-` substring match can over-trigger

**File:** `tests/stub-revenium.sh:109-115`
**Issue:** `STUB_REVENIUM_HALT_JOBS_FAIL` fails any `jobs create`/`jobs outcome` whose
argv contains the substring `CANCELLED` or `guardrail-halt-` anywhere. This is intentional
per the header docs, but it means a future per-session fixture that legitimately closes a
real job with `--result CANCELLED` (like GROUP A's J3) would be incorrectly failed if that
fixture were ever combined with `STUB_REVENIUM_HALT_JOBS_FAIL=1`. The current GROUP M2
fixture has no per-session CANCELLED job, so it is safe today.
**Fix:** No change required for Phase 8. If broader combinations are added later, tighten
the halt-fail detection to require *both* a halt-shaped id *and* a CANCELLED result, or key
off the synthetic-id prefix only.

### IN-04: Phase 8 python3 heredocs in `handle_halt` silently swallow all errors

**File:** `scripts/report.sh:1031-1050`, `1086-1105`
**Issue:** The halt-status read and open-jobs resolution both end in `2>/dev/null || true`,
so a malformed `guardrail-status.json` or an unreadable ledger produces empty output that
is interpreted as "not halted" / "no open jobs" — fail-open by design (matches the stated
contract). This is correct, but means genuine misconfiguration (e.g. a corrupt status
file) is invisible. Consider a single `warn` when the status read yields no `HALTED=` line
at all, to aid operability without changing fail-open behavior.
**Fix:** Optional: emit a debug/warn log when `HALT_STATUS` is empty but
`${SKILL_DIR}/guardrail-status.json` exists and is non-empty.

---

_Reviewed: 2026-06-03T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
