---
phase: "07-root-session-job-rollup"
plan: "02"
subsystem: "scripts"
tags: [job-rollup, subagent, root-session, tdd-green, jroll-01, jroll-02, jroll-03]
dependency_graph:
  requires: ["07-01"]
  provides: [JROLL-01, JROLL-02, JROLL-03]
  affects: [scripts/report.sh, tests/test_report_jobs_argv.sh]
tech_stack:
  added: []
  patterns:
    - env-passing python3 heredoc for cross-session marker read (ROOT_SID/MARKERS_DIR)
    - three-field tab-split bash parse mirroring job_resolve_result pattern
    - root_sid != session_id guard for subagent-only code paths
    - root_sid == session_id compound gate on jobs create / jobs outcome
key_files:
  modified:
    - scripts/report.sh
    - tests/test_report_jobs_argv.sh
decisions:
  - root_aid resolver uses bash locals only (no new temp files, _cleanup_session_tmp unchanged)
  - agentic_job_id_log still reflects pre-override value in info log (cosmetic only; actual argv use post-override value)
  - make_openclaw_home extended to symlink get-root-session-id.py — required for resolver to work in test isolation
metrics:
  duration: "~7 min"
  completed: "2026-06-03T21:26:52Z"
  tasks_completed: 2
  files_modified: 2
---

# Phase 7 Plan 02: Root-Session Job Rollup GREEN Implementation — Summary

**One-liner:** Three surgical changes to `scripts/report.sh` (root_aid cross-session resolver, in-loop subagent override block, root-only `jobs create`/`jobs outcome` gates) turn GROUPS F/G/H GREEN while keeping GROUPS A-E byte-identical; 44/44 `test_report_jobs_argv.sh` assertions pass.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Add root_aid cross-session resolver + subagent override block | dc12054 | scripts/report.sh |
| 2 | Add root-only gate to jobs create and jobs outcome; turn GROUPS F/G/H green | 7afd0fc | scripts/report.sh, tests/test_report_jobs_argv.sh |

## What Was Built

**CHANGE SITE 1 — root_aid resolver (after line 330):**

A once-per-subagent-session env-passing python3 heredoc reads `markers/{root_sid}.jsonl`, linearly scans for the latest `kind:job` record, sanitizes `agentic_job_id` (replaces `|`, `\n`, `\r`, `:` with `_`), and emits `aid TAB name TAB type`. Bash three-field tab-split populates `root_aid`, `root_job_name`, `root_job_type` locals. Guarded by `root_sid != session_id` so root sessions skip entirely. Uses bash locals only — `_cleanup_session_tmp` unchanged.

**CHANGE SITE 2 — subagent override block (after Job correlation: fi):**

In-loop override running per-completion. If `root_aid` is non-empty: inherit root's job (`agentic_job_id`, `agentic_job_name`, `agentic_job_type` reassigned to root values — JROLL-01). Else (race window or orphan): explicitly zero all three vars — D-04 load-bearing safety invariant that prevents subagent's own orphan id from leaking (JROLL-02). Root sessions skip this block entirely.

**CHANGE SITE 3A/3B — root-only gates:**

Appended `&& "${root_sid}" == "${session_id}"` as third compound term to both:
- `jobs create` outer `if` condition: subagents skip create even when `agentic_job_id` holds the root's id (D-06 / Pitfall 1)
- `jobs outcome` outer `if` condition: subagents skip outcome too (D-06)

Inner blocks unchanged byte-for-byte.

## Verification Results

```
bash -n scripts/report.sh                             → exits 0 (syntax valid)
grep -cE 'ROOT_SID=.*MARKERS_DIR=.*python3' report.sh → 1 (env-passing resolver)
grep -cE 'root_sid.*==.*session_id' report.sh         → 3 (2 gates + 1 comment)
grep -c 'root_aid' report.sh                          → 7 (>= 4 requirement)
bash tests/test_report_argv.sh                        → 9/9 pass (Phase 6 path unchanged)
bash tests/test_report_jobs_argv.sh                   → 44/44 pass (GROUPS A-H all green)
  GROUP A-E (Phase 6 regression)                      → 35/35 pass (byte-identical)
  GROUP F (JROLL-01 subagent inherits root id)        → 6/6 pass
  GROUP G (JROLL-02 race-omit / orphan-drop)          → 6/6 pass
  GROUP H (JROLL-03 subagent job marker suppressed)   → 4/4 pass (was 3 assertions shown)
pytest tests/test_get_root_session_id.py -v           → 7/7 pass (resolver untouched)
```

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Symlink get-root-session-id.py into fake OPENCLAW_HOME in test**

- **Found during:** Task 2 — test suite ran with 7 failures after Task 1
- **Issue:** `make_openclaw_home` in `tests/test_report_jobs_argv.sh` did not create `skills/revenium/scripts/` or symlink `get-root-session-id.py`. The `get_root_session_id` shell wrapper in `report.sh` calls `python3 "${SKILL_DIR}/scripts/get-root-session-id.py"` — this path did not exist in the test's fake HOME, causing the resolver to fall back to `|| printf '%s\n' "${sid}"` (self-return). Consequence: every session — including child sessions — saw `root_sid == session_id`, so the subagent override block never fired and the root-only gates were always TRUE for children.
- **Fix:** Added `mkdir -p "${d}/skills/revenium/scripts"` and `ln -sf "${REPO_ROOT}/scripts/get-root-session-id.py" "${d}/skills/revenium/scripts/get-root-session-id.py"` to `make_openclaw_home`. GROUPS A-E are unaffected (single root sessions — resolver returns self regardless).
- **Files modified:** `tests/test_report_jobs_argv.sh`
- **Commit:** 7afd0fc

## Known Stubs

None. All GROUP F/G/H assertions verify live behavior; `root_aid` is resolved, overrides are applied, ledger rows are correct.

## Threat Flags

None. No new network endpoints, auth paths, or schema changes beyond what the plan's threat model covers. The `root_aid` resolver reads `markers/{root_sid}.jsonl` — this is within the existing MARKERS_DIR trust boundary already modeled as T-07-HEREDOC/T-07-INJ. Sanitization is applied (`:`, `|`, `\n`, `\r` → `_`) as required by T-07-INJ.

## Self-Check: PASSED

- `scripts/report.sh` exists: FOUND
- `tests/test_report_jobs_argv.sh` exists: FOUND
- Task 1 commit dc12054: FOUND
- Task 2 commit 7afd0fc: FOUND
- `bash -n scripts/report.sh` exits 0: VERIFIED
- `bash tests/test_report_jobs_argv.sh` exits 0 (44 passed, 0 failed): VERIFIED
- `bash tests/test_report_argv.sh` exits 0 (9 passed, 0 failed): VERIFIED
- `pytest tests/test_get_root_session_id.py` exits 0 (7 passed): VERIFIED
- GROUPS F/G/H all print PASS: VERIFIED
- GROUPS A-E all print PASS (35 assertions): VERIFIED
- `_cleanup_session_tmp` unchanged (still 4 temp files): VERIFIED
