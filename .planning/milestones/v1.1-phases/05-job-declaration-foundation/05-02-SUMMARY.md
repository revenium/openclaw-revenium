---
phase: 05-job-declaration-foundation
plan: "02"
subsystem: job-marker-writer
tags: [job-declaration, sanitization, allowlist, flock, green, tdd]
dependency_graph:
  requires:
    - job-taxonomy.json (05-01)
    - JOB_TAXONOMY_FILE constant in common.sh (05-01)
    - tests/test_write_job_marker.sh RED harness (05-01)
  provides:
    - scripts/write-job-marker.sh named-flag job marker writer (JOBDEC-03, JOBDEC-04)
    - sanitize() defense boundary: :, |, newline -> _ before CLI-arg reach (Phase 6)
  affects:
    - markers/{sid}.jsonl (appended at arc boundaries)
tech_stack:
  added: []
  patterns:
    - env-passing Python heredoc <<'PY' (T-05-03 shell-interpolation defense)
    - sanitize()-before-allowlist ordering (D-09, Pitfall 2)
    - fcntl.flock(LOCK_EX) + O_APPEND atomic append (T-05-06)
    - verbatim sid-resolution from write-marker.sh (newest non-cron session)
    - FAILED-only failure_reason field (D-13, Pitfall 3)
key_files:
  created:
    - scripts/write-job-marker.sh
  modified: []
decisions:
  - "sanitize() applied to all 5 user fields before any allowlist check (Pitfall 2 ordering — sanitized value reaches allowlist, not raw value)"
  - "failure_reason gated by status == 'FAILED' and non-empty failure_reason (Pitfall 3 — absent from SUCCESS and CANCELLED records entirely)"
  - "sid-resolution block copied verbatim from write-marker.sh lines 66-169 including completion_id extraction (harmless, keeps selection logic intact)"
  - "write-marker.sh untouched (D-06 isolation verified by git diff empty output)"
metrics:
  duration: "~6 minutes"
  completed: "2026-06-03"
  tasks_completed: 1
  tasks_total: 1
  files_created: 1
  files_modified: 0
---

# Phase 5 Plan 02: Job Marker Writer Summary

Implemented `scripts/write-job-marker.sh` — named-flag job marker writer with inline sanitization, taxonomy + status allowlist validation, and flock-protected atomic O_APPEND; turns `tests/test_write_job_marker.sh` fully GREEN (18/18 assertions).

## What Was Built

### Task 1: Implement write-job-marker.sh (9f969f8)

Created `scripts/write-job-marker.sh` as a new dedicated writer (D-06 — does not extend `write-marker.sh`). Structure mirrors `write-marker.sh` exactly except for the divergences mandated by D-07/D-09/D-11/D-12/D-13.

**Bash wrapper layer:**
- Named-flag `while/case` parser for `--job-id`, `--job-name`, `--job-type`, `--status`, `--failure-reason`
- Unknown arguments rejected via `warn` + `exit 1`
- Mandatory-presence check at bash level: any missing `--job-id`/`--job-name`/`--job-type`/`--status` exits 1 before Python runs
- Log-injection mitigation: `JOB_TYPE_LOG="${JOB_TYPE_ARG:0:64}"` before `info` call (T-05-07)
- Env-passing heredoc `python3 - <<'PY'` (single-quoted delimiter) — 9 discrete env vars; no `${JOB_*_ARG}` interpolated inside the Python body (T-05-03)

**Python heredoc layer:**
- All 5 user values read from `os.environ`
- `sanitize(value, maxlen=256)` defined immediately after env reads: `re.sub(r'[:\|\n\r]', '_', str(value))[:maxlen]`
- `sanitize()` applied to all 5 fields (`job_id`, `job_name`, `job_type`, `status`, `failure_reason`) BEFORE the allowlist check (D-09, Pitfall 2 ordering)
- Taxonomy allowlist: `json.load(JOB_TAXONOMY_FILE)` → membership check on sanitized `job_type`
- Status allowlist: `{'SUCCESS', 'FAILED', 'CANCELLED'}` → membership check on sanitized `status`
- Sid-resolution block: verbatim copy from `write-marker.sh` lines 66-169 (newest non-cron session by assistant completion timestamp, mtime fallback, `pseudo-{int(time.time())}` last resort)
- Path-traversal sid guard: `re.fullmatch(r'[0-9a-fA-F-]+|pseudo-[0-9]+', sid)` (T-05-05)
- `os.makedirs(markers_dir, mode=0o700, exist_ok=True)` (T-05-06)
- Record: `kind:"job"`, `ts` (ISO8601 via `time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())`), in-record `sid`, `agentic_job_id`, `job_name`, `job_type`, `status` — all 7 mandatory fields (D-11, D-12)
- `failure_reason` added to record only when `status == "FAILED" and failure_reason` (D-13, Pitfall 3)
- `open(path, 'ab', buffering=0)` + `fcntl.flock(fh, fcntl.LOCK_EX)` + write (T-05-06)

**Test results:**
- `bash tests/test_write_job_marker.sh`: **18/18 PASS** (GREEN gate — all 12 verification-map assertions including 6 sub-assertions)
- `bash tests/test_write_marker.sh`: **12/12 PASS** (zero regression, D-06/D-11)
- `git diff -- scripts/write-marker.sh`: empty (byte-for-byte unchanged)

## Decisions Made

- **sanitize()-before-allowlist ordering**: Sanitized value reaches the allowlist check — this is intentional and correct. If a raw value containing `:` matched a label after sanitization, it still passes (a benign widening), but the written record contains the sanitized value. This is safer than the alternative (sanitize after allowlist would let unsanitized values land in the JSONL).
- **failure_reason guard**: `status == "FAILED" and failure_reason` — the `and failure_reason` clause means passing `--failure-reason ""` still omits the field. This matches the test harness expectation and Pitfall 3 guidance.
- **completion_id not included in job records**: The sid-resolution block computes `completion_id` but the job record build does not use it (only `sid` is included per D-12). This is intentional — the `completion_id` field belongs to task markers only.

## Deviations from Plan

None — plan executed exactly as written.

## Known Stubs

None — all 7 mandatory fields are written with real values; no placeholders.

## Threat Flags

None — `write-job-marker.sh` operates at the same trust boundary as `write-marker.sh` (agent/CLI args → writer → markers JSONL). No new network endpoints, auth paths, or schema changes introduced. The T-05-04 partial-mitigation note (`;`, `&&`, `$()` not stripped — Phase 6 MUST use env-passing for CLI invocation) is carried forward per the plan's threat register.

## Self-Check

### Files exist:
- `scripts/write-job-marker.sh`: FOUND

### Commits exist:
- 9f969f8 (feat(05-02)): FOUND

## Self-Check: PASSED
