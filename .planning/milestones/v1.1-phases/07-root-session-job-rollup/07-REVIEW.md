---
phase: 07-root-session-job-rollup
reviewed: 2026-06-03T21:35:00Z
depth: standard
files_reviewed: 2
files_reviewed_list:
  - scripts/report.sh
  - tests/test_report_jobs_argv.sh
findings:
  critical: 0
  warning: 5
  info: 4
  total: 9
status: issues_found
---

# Phase 7: Code Review Report

**Reviewed:** 2026-06-03T21:35:00Z
**Depth:** standard
**Files Reviewed:** 2
**Status:** issues_found

## Summary

The phase ports a Hermes-style root-session job rollup into `scripts/report.sh`: a once-per-subagent root-job resolver (lines 332-387), an in-loop subagent override that inherits the root's job values or zeroes them on race/orphan (lines 749-769), and a `&& root_sid == session_id` gate appended to both the `jobs create` (line 778-779) and `jobs outcome` (line 944-945) conditions. The test file adds integration GROUPS F/G/H.

I ran the full suite: **44 passed, 0 failed**, and confirmed GROUPS A-E remain byte-identical (standalone root sessions never hit `root_sid != session_id`, so the three new blocks are skipped entirely). The fail-open / race-window behavior matches the stated invariants for the fixtures exercised.

However, the suite only covers happy-path fixtures with single, well-ordered job markers and well-formed ids. Tracing the resolver against the codebase's *own* per-completion correlation engine surfaces several real correctness and consistency defects that the tests do not exercise: an ordering mismatch between "latest by file order" and "latest by timestamp," a sanitization asymmetry that can desync the subagent's inherited id from the root's created id, and TAB-injection field corruption. None rise to a security/data-loss BLOCKER (the ledger TX dedup and fail-open posture contain the blast radius), but several are correctness WARNINGs that should be fixed before this ships.

No structural-findings substrate was provided with this review.

## Narrative Findings (AI reviewer)

## Warnings

### WR-01: Resolver "latest wins" uses file order, but the root's own correlation uses timestamp order — subagent can be attributed to a different job than the root

**File:** `scripts/report.sh:338,355-377` (resolver) vs `scripts/report.sh:450-451,704-720` (per-completion correlation)

**Issue:** The comment at line 338 states "Latest kind:job wins (D-05 — linear scan, no sort)." The resolver loop (lines 355-377) overwrites `latest_aid` on every `kind:job` line, so it selects the **last job marker in file order**. Meanwhile the root's own per-completion job correlation sorts `job_rows` by `ts` (line 451) and then selects by completion_id-exact or earliest-ts-fallback (lines 704-720). When a root session declares **more than one** job marker, these two paths can disagree:

- If markers are appended out of timestamp order (the writer guarantees append, not chronological order), the resolver's last-in-file marker may not be the latest-by-ts marker.
- Even with in-order markers, the root attributes each of *its own* completions to the marker whose ts is >= that completion's ts (potentially job-A for an early completion), while every subagent completion is uniformly stamped with the file-last job (job-B). The root's spend and the subagent's spend then roll up to *different* `agentic_job_id`s.

Reproduced: with two markers (`job-B` ts=10:00 appended first, `job-A` ts=09:00 appended second) the resolver returns `job-A` (file-last) while the ts-sorted correlation engine would prefer `job-B`. The single-marker fixtures in GROUPS F/H never expose this.

**Fix:** Make the resolver use the same ordering as the correlation engine. Sort by `ts` and pick the max, rather than relying on file order:
```python
best_ts = None
for line in fh:
    ...
    if rec.get('kind') == 'job':
        aid = rec.get('agentic_job_id') or ''
        if isinstance(aid, str) and aid:
            ts = rec.get('ts', '')
            if best_ts is None or ts >= best_ts:
                best_ts = ts
                for _bad in ('|', '\n', '\r', ':'):
                    aid = aid.replace(_bad, '_')
                latest_aid, latest_name, latest_type = aid, str(rec.get('job_name','')), str(rec.get('job_type',''))
```
Either way, document explicitly that "latest" means latest-by-ts and keep it consistent with the correlation engine.

### WR-02: Colon sanitization asymmetry desyncs the subagent's inherited id from the root's created/ledgered id

**File:** `scripts/report.sh:369-370` (resolver sanitizes `:`) vs `scripts/report.sh:434-443` (jobs_cache path does NOT sanitize)

**Issue:** The resolver sanitizes the inherited aid by replacing `|`, `\n`, `\r`, and `:` with `_` (lines 369-370). The root's own correlation path that reads the jobs cache (lines 434-443, populated at 455-457) performs **no** such replacement, so the root ships and ledgers the **raw** id. Consequences when a root `agentic_job_id` contains a colon:

- The **root** calls `jobs create --agentic-job-id "foo:bar"` and writes ledger row `JOB:foo:bar:created:`.
- The **subagent** inherits the sanitized `foo_bar` and ships `meter completion --agentic-job-id foo_bar`.
- The two never correlate in Revenium, and the subagent's inherited id has no matching `:created:` row.

Verified: `grep -q "^JOB:foo_bar:created:"` does not match a ledger containing `JOB:foo:bar:created:`. (Colons in ids are independently problematic for the `JOB:<id>:created:` ledger grammar on the root path, so the safest fix is to sanitize consistently in *both* paths.)

**Fix:** Apply the same `(' |', '\n', '\r', ':')` replacement in the jobs_cache python (lines 434-457) so the root and subagent derive identical ids from the same marker, or move sanitization to a single shared helper. At minimum, both paths must agree.

### WR-03: TAB inside `job_name` corrupts bash field-splitting of the resolver output

**File:** `scripts/report.sh:377` (python prints TAB-separated) and `scripts/report.sh:380-386` (bash splits on `$'\t'`)

**Issue:** The resolver emits `f"{latest_aid}\t{latest_name}\t{latest_type}"`. `latest_name`/`latest_type` come from `str(rec.get(...))` with **no** sanitization of TAB, and the aid sanitization (lines 369-370) also omits TAB. The bash parser at lines 380-386 splits on `$'\t'`:
```
root_job_name="${_rr2%%$'\t'*}"
root_job_type="${_rr2#*$'\t'}"
```
A TAB embedded in `job_name` shifts the boundaries: reproduced with `job_name="Add\tFeature"`, the parse yields `name=[Add] type=[Feature<TAB>feature]` — the name is truncated and the type absorbs the spillover. `job_name`/`job_type` originate from agent-authored markers, so a stray tab is plausible.

**Fix:** Sanitize TAB (and ideally newline) out of all three fields in the resolver before printing, mirroring the aid sanitization:
```python
def _clean(s):
    for _bad in ('|', '\n', '\r', '\t', ':'):
        s = s.replace(_bad, '_')
    return s
latest_aid  = _clean(aid)
latest_name = _clean(str(rec.get('job_name','')))
latest_type = _clean(str(rec.get('job_type','')))
```

### WR-04: python3-absent path treats subagents as roots, defeating the D-04 orphan-suppression invariant

**File:** `scripts/report.sh:50-58` (`get_root_session_id`) interacting with `scripts/report.sh:339,752`

**Issue:** When `python3` is unavailable, `get_root_session_id` fails open and returns the **input** sid (line 54). That makes `root_sid == session_id`, so both the resolver block (line 339) and the override block (line 752) are skipped — the subagent is treated as its own root. The same-session correlation then ships and (if `JOBS_CLI_CAPABLE`) creates the subagent's **own** orphan job id. This directly violates the stated D-04 safety invariant ("NEVER substitute the subagent's own orphan id"), which the whole rollup depends on the resolver to enforce. The phase's correctness is silently conditional on python3 being present; the fail-open posture of the dependency inverts the safety guarantee.

While `get_root_session_id`'s fail-open is pre-existing, this phase newly *relies* on it for a safety invariant. The tests symlink the resolver and assume python3, so this regression path is unexercised.

**Fix:** When the rollup relies on root resolution for a safety invariant, the create/outcome and override gates should additionally key off whether the session was *confirmed* a root, not merely `root_sid == session_id` by fail-open coincidence. Consider a tri-state from the resolver (root | subagent | unresolved) and suppress job creation on `unresolved` rather than defaulting to root behavior. At minimum, document that subagent orphan suppression is void without python3 and gate accordingly.

### WR-05: Subagent's own orphan/job id is logged before it is zeroed (info-log leak of the suppressed id)

**File:** `scripts/report.sh:744-746` (logs subagent's own id) vs `scripts/report.sh:752-769` (zeroes it afterward)

**Issue:** The per-completion correlation at lines 662-747 resolves and logs the subagent's *own* job id via `info "Job correlation: tx_id=... agentic_job_id=${agentic_job_id_log}"` (line 745) **before** the Phase-7 override at line 752 zeroes it for race/orphan subagents. Confirmed in the test run output for GROUP G: `Job correlation: tx_id=comp-child-g001 agentic_job_id=orphan-job-7x7x` is emitted even though the orphan id is correctly dropped from argv. The id that the invariant says must "never ship" still lands in the metering log, partially defeating the suppression intent and creating confusing operator-facing log lines.

**Fix:** Suppress or defer the line-745 correlation log for subagent sessions, or move the per-completion job correlation behind the `root_sid == session_id` check so subagent sessions never compute/log their own id in the first place (they discard it unconditionally anyway).

## Info

### IN-01: Processing-order hazard — subagent may meter against a job id not yet created

**File:** `scripts/report.sh:752-769` (inherit) vs `scripts/report.sh:778-807` (root-only create)

**Issue:** Subagent completions inherit `root_aid` by reading the root marker file directly, independent of session processing order, but the root's `jobs create` only fires when the **root** session is processed. `find` (line 1029) yields files in inode order, so a subagent processed before its root will ship `meter completion --agentic-job-id <root-job>` before the job is created in Revenium. The stub accepts any argv, so tests never expose this; against the live API a completion referencing an uncreated job may be orphaned or rejected. Out of strict scope (ordering/timing), recorded for awareness.

**Fix:** If the API requires create-before-reference, consider processing root sessions before subagent sessions (sort the file list so roots sort first), or rely on Revenium's lazy-create semantics if guaranteed.

### IN-02: Redundant `[[ -n "${root_aid}" ]]` test in the override block

**File:** `scripts/report.sh:753-768`

**Issue:** The override checks `[[ -n "${root_aid}" ]]` at line 753 to choose inherit-vs-zero, then re-checks the identical condition at line 765 solely to emit the info log. The second check can be folded into the first branch.

**Fix:** Move the `info "Subagent job rollup: ..."` line inside the line-753 `if [[ -n "${root_aid}" ]]` branch and delete the duplicate guard at 765-768.

### IN-03: Resolver field-extraction silently absorbs extra TAB-delimited fields

**File:** `scripts/report.sh:383-385`

**Issue:** `root_job_type="${_rr2#*$'\t'}"` uses remove-shortest-prefix, so if the resolver ever emits more than three fields (e.g., via the WR-03 tab corruption), `root_job_type` absorbs all trailing content rather than failing loudly. This is the downstream symptom of WR-03; once WR-03 sanitizes tabs it is harmless, but the parser is inherently non-defensive against extra delimiters.

**Fix:** After fixing WR-03, this is moot. Alternatively read the three fields with a single `IFS=$'\t' read -r root_aid root_job_name root_job_type <<< "${_root_resolve}"` which bounds the split.

### IN-04: `info` correlation log fires for subagent-own ids in GROUP F/H too (test-confirmed noise)

**File:** `scripts/report.sh:745`

**Issue:** Related to WR-05: in GROUP F the log shows `Job correlation: ... agentic_job_id=child-job-9z9z` immediately followed by `Subagent job rollup: ... root_aid=root-job-1a2b`. The first line records a value that is never used. Pure log noise, but it can mislead an operator grepping logs for which job a completion was attributed to.

**Fix:** Same as WR-05 — gate the per-completion job correlation/log on `root_sid == session_id`.

---

_Reviewed: 2026-06-03T21:35:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
