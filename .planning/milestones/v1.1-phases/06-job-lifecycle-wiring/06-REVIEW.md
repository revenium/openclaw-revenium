---
phase: 06-job-lifecycle-wiring
reviewed: 2026-06-03T20:20:00Z
depth: standard
files_reviewed: 4
files_reviewed_list:
  - scripts/report.sh
  - tests/stub-meta-check.sh
  - tests/stub-revenium.sh
  - tests/test_report_jobs_argv.sh
findings:
  critical: 2
  warning: 3
  info: 3
  total: 8
status: issues_found
---

# Phase 6: Code Review Report

**Reviewed:** 2026-06-03T20:20:00Z
**Depth:** standard
**Files Reviewed:** 4
**Status:** issues_found

## Summary

Phase 6 wires agentic-job lifecycle (`jobs create` / `jobs outcome` / `--agentic-job-id` stamping) into the existing Revenium metering reporter, plus an argv-capturing test stub and an integration test harness. The decoupling discipline (jobs failures must not wedge completion metering) is well implemented and the test suite passes 28/28 + 10/10. However, two real correctness defects exist that the tests do not exercise:

1. The documented "retry next tick" guarantee for failed `jobs create`/`outcome` is broken whenever completion metering succeeds — the offset advances past the line and the job work is never retried (CR-01).
2. Newlines (and tabs) in agent-supplied marker fields corrupt the TSV correlation caches, splitting one job/task row into bogus rows that can mis-attribute or fabricate correlations (CR-02).

Both stem from the same area as the author's already-fixed concerns (WR-04 regex-literal IDs, T-04-09 untrusted input), so they are in keeping with the threat model the author already accepted — they were just not carried through to the new job code.

## Critical Issues

### CR-01: Failed `jobs create`/`outcome` is never retried once the completion is metered (broken "retry next tick")

**File:** `scripts/report.sh:416-419`, `699-727`, `856-905`, `918-922`
**Issue:**
The offset gate at the top of `process_session` short-circuits an entire session once its lines are consumed:

```bash
if [[ "${offset}" -ge "${total_lines}" ]]; then
  _cleanup_session_tmp
  return 0
fi
```

The offset only advances when `failed_count == 0` (line 918), and `failed_count` is driven exclusively by `post_to_revenium` (the completion). Job create/outcome are deliberately decoupled (D-12): a failed `jobs create` (lines 718-725) or deferred/failed outcome (lines 868, 902) logs `warn "... retry next tick"` but does **not** touch `failed_count`.

Consequence: in the normal case where the completion meters successfully but the jobs CLI is transiently down, `failed_count` is 0, so the offset advances to `total_lines`. On the next tick the session is skipped at line 416 before the read loop ever runs, so the create/outcome are **never** retried. The job row is permanently absent from `revenium-jobs.ledger`, contradicting the warnings at lines 724 ("metering continues"), 868 ("retry next tick"), and 902 ("retries next tick").

GROUP D in the test only asserts the offset advanced and that no JOB row exists after the failing run — it never asserts the job is eventually created on a later (jobs-healthy) retry, so the suite is green while the guarantee is broken.

Additionally, the outcome block (line 864) sits *after* the TX-already-reported `continue` (lines 831-833), while the create block (line 699) sits *before* it. So even within a session that does get re-read (because some other completion failed), an already-ledgered completion `continue`s before reaching the outcome retry — create and outcome retry paths are asymmetric.

**Fix:**
Decide on the intended durability semantics and make the offset gate respect pending job work. One option — track a separate `job_work_pending` flag and refuse to advance the offset (or persist a per-job retry queue) when a job create/outcome was attempted and did not succeed:

```bash
# inside the loop, on jobs create/outcome failure (not 409):
job_work_pending=1   # declared/reset per session alongside failed_count

# at end of process_session:
if [[ "${failed_count}" -eq 0 && "${job_work_pending:-0}" -eq 0 ]]; then
  set_offset "${session_id}" "${total_lines}"
else
  warn "Session ${session_id}: deferring offset (failures or pending job work) — retry next tick"
fi
```

Note this re-meters succeeded completions on retry, which the TX: ledger already dedups (the design's stated safety net), so it is consistent with CR-02's existing rationale. Also move the outcome block above the TX `continue`, or gate the `continue` so outcome retries still run for already-ledgered completions.

### CR-02: Newline/tab in agent-supplied marker fields corrupts the job/task correlation TSV caches

**File:** `scripts/report.sh:395-400` (job cache write), `360-401` (cache builder), and the task-cache write at `397`
**Issue:**
The Python cache builder writes one TSV line per marker:

```python
with open(jobs_out, 'a', encoding='utf-8') as f:
    for ts, jid, jname, jtype, status, fr, cid in job_rows:
        f.write(f"{ts}\t{jid}\t{jname}\t{jtype}\t{status}\t{fr}\t{cid}\n")
```

`fr` (failure_reason), `jname` (job_name), `jtype`, and `jid` come straight from agent-written marker JSON. After `json.loads`, an escaped `\n` in any of these becomes a real newline. Because the consumer reads the cache **line by line** (`for line in fh:` at line 627 / 553), a value containing a newline splits one logical row into two physical lines. Verified:

```
input fr = "line1\nline2"  (FAILED job marker)
cache row -> 't\tj1\tn\tty\tFAILED\tline1\nline2\tc1\n'
parsed line 1 -> ['t','j1','n','ty','FAILED','line1']        # failure_reason truncated to "line1"
parsed line 2 -> ['line2','c1']  (len 2, passes the len<2 guard)  # PHANTOM job row: agentic_job_id="c1"
```

Impact:
- failure_reason / job metadata is silently truncated at the first newline.
- The phantom second row survives the `if len(parts) < 2: continue` guard (len is 2) and becomes a bogus job row whose `agentic_job_id` is the leaked tail (`c1` above). With `JOBS_CLI_CAPABLE=true` this can trigger a spurious `revenium jobs create --agentic-job-id <garbage>` and a ledger row for a non-existent job.
- The identical flaw applies to the **task cache** (`f.write(f"{ts}\t{tt}\t{cid}\n")` at line 397) for `task_type`/`completion_id`.

This is the same "untrusted session/marker text" threat the author already guards against elsewhere (T-04-09 env-passing, T-04-08 64-char log truncation); it was not carried into the cache serialization.

**Fix:**
Serialize the caches in a format that cannot be split by embedded newlines/tabs — e.g. write each row as a single JSON object and parse with `json.loads`, or escape control chars before writing:

```python
import json
with open(jobs_out, 'a', encoding='utf-8') as f:
    for ts, jid, jname, jtype, status, fr, cid in job_rows:
        f.write(json.dumps([ts, jid, jname, jtype, status, fr, cid]) + "\n")
# consumer:
#   parts = json.loads(line)
```

Alternatively strip/replace `\n` and `\t` in every field before the `f.write` (e.g. `fr.replace('\n',' ').replace('\t',' ')`), accepting lossy metadata but preventing row corruption and phantom rows.

## Warnings

### WR-01: Ledger gate greps interpolate IDs as BRE regexes, not fixed strings

**File:** `scripts/report.sh:700`, `831`, `865`, `867`
**Issue:**
`agentic_job_id` and `tx_id` are interpolated directly into `grep` patterns:

```bash
grep -q "^JOB:${agentic_job_id}:created:" "${JOBS_LEDGER_FILE}"
grep -q "^TX:${tx_id}$" "${LEDGER_FILE}"
grep -q "^JOB:${agentic_job_id}:outcome:" "${JOBS_LEDGER_FILE}"
```

These IDs originate from marker/session JSON written by the agent and may contain BRE metacharacters (`.`, `*`, `[`, `\`). A `.` matches any char and `^...:created:` is unanchored on the right, so a crafted/garbled id can match the wrong ledger row — causing a missed idempotency skip (duplicate `jobs create`) or a false-positive skip (job never created). This is the exact defect class the author already fixed for `meta_lookup` (WR-04: "IDs from .id/.parentId could contain regex metacharacters"); the fix was not applied to the new ledger gates.

**Fix:** Use fixed-string matching with full-line anchoring. For the JOB gates add a trailing delimiter and use `-F` via `grep -F` on a fully-delimited key, or switch to `awk` exact compare:

```bash
# created gate
if grep -qxF "JOB:${agentic_job_id}:created" <(cut -d: -f1-3 "${JOBS_LEDGER_FILE}"); then ...
# or, simplest robust form:
awk -F: -v id="${agentic_job_id}" '$1=="JOB" && $2==id && $3=="created"{found=1} END{exit !found}' "${JOBS_LEDGER_FILE}"
```

### WR-02: Empty job `status` produces `jobs outcome --result ""`

**File:** `scripts/report.sh:870`, marker parse at `384` / cache write `399`
**Issue:**
A job marker with `status` absent or empty yields `job_status=""`. The outcome command is built unconditionally once the create gate passes:

```bash
local outcome_cmd=( revenium jobs outcome "${agentic_job_id}" --result "${job_status}" --quiet )
```

This ships `--result ""` to the CLI. Depending on CLI behavior this is either a hard error (then the outcome is retried forever — see CR-01 it actually is dropped) or, worse, accepted as an empty/invalid outcome. There is no guard that `job_status` is one of the expected enum values (SUCCESS/FAILED/CANCELLED).

**Fix:** Skip (or defer with a warn) when `job_status` is empty or not in the allowed set:

```bash
case "${job_status}" in
  SUCCESS|FAILED|CANCELLED) ;;
  *) warn "skipping outcome for ${agentic_job_id_log}: invalid/empty status='${job_status}'"; job_status="" ;;
esac
[[ -n "${job_status}" ]] && { ... build and run outcome_cmd ... }
```

### WR-03: `total_tokens` assigned without `local`, leaks to function/global scope

**File:** `scripts/report.sh:506`
**Issue:**
Inside `process_session`, every other per-line field is declared `local` (lines 482-484), but `total_tokens` is assigned bare at line 506 with no `local`. It therefore persists in `process_session`'s scope across iterations and, because it is never declared local anywhere in `process_session`, behaves as a function-leaked variable. It happens to be reassigned every iteration so no incorrect value is observed today, but it is an inconsistency that invites a future stale-value bug (e.g., if a later edit reads it before assignment in some branch). It also shadows nothing today only by luck.

**Fix:** Add it to the local declaration block:

```bash
local input_tokens output_tokens cache_read cache_create total_tokens
```

## Info

### IN-01: Dead variable `task_type_log`

**File:** `scripts/report.sh:597`
**Issue:** `local task_type_log="${task_type:0:64}"` is computed for "log injection mitigation" but never referenced anywhere (the analogous `agentic_job_id_log` is used; `task_type_log` is not). Dead code.
**Fix:** Remove the line, or actually use `${task_type_log}` in the correlation log message if log-truncation was intended for task_type too.

### IN-02: `already.exist` 409 matcher uses `.` as a wildcard

**File:** `scripts/report.sh:714`, `892`
**Issue:** `grep -qi "409\|already.exist\|conflict"` — the `.` between "already" and "exist" is a regex any-char, so it also matches `alreadyXexist`. Cosmetically imprecise; harmless in practice but slightly over-broad for a success-classification decision on CLI stderr.
**Fix:** Escape it: `"409\|already.\?exist\|already exist\|conflict"` or use a fixed-string list with `grep -iF`.

### IN-03: Redundant `:-unclassified` default on already-defaulted `task_type`

**File:** `scripts/report.sh:255`, `847` (and local default at `529`)
**Issue:** `task_type` is initialized to `"unclassified"` (line 529) and can only be reassigned to a non-empty marker value, yet both `post_to_revenium`'s `--task-type "${task_type:-unclassified}"` (line 255) and the call site arg `"${task_type:-unclassified}"` (line 847) re-default it. Harmless redundancy that obscures the single source of truth.
**Fix:** Pass `"${task_type}"` directly; rely on the line 529 default.

---

_Reviewed: 2026-06-03T20:20:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
