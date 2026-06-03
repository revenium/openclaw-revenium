---
phase: 04-task-metering-attribution
plan: "02"
subsystem: marker-producer-and-attribution
tags: [meter-02, meter-03, trace-01, trace-02, write-marker, report-sh, tdd, timestamp-precedence, agent-attribution]
dependency_graph:
  requires:
    - 04-01 (task-taxonomy.json, common.sh Phase-4 constants + get_root_session_id, tests/stub-revenium.sh, fixtures)
  provides:
    - scripts/write-marker.sh (taxonomy-validated ISO8601 marker writer, METER-02)
    - scripts/report.sh (task-type correlation + --agent openclaw-{root} + --task-type, METER-03/TRACE-01/02)
    - tests/test_write_marker.sh (10-case marker writer integration tests)
    - tests/test_report_argv.sh (6-case argv-capture integration test for report.sh)
  affects:
    - plans 04-03 to 04-04 (consume report.sh --task-type/--agent wiring for setup-guardrails picker + SKILL.md)
tech_stack:
  added: []
  patterns:
    - NP-1: Timestamp-precedence correlation (marker cache read once per session, per-line bisect)
    - NP-3: write-marker.sh bash+python heredoc — env-passing, no ${VAR} inside <<'PY'
    - flock append (fcntl.LOCK_EX + O_APPEND) for concurrent turn safety
    - HOME override in integration test to control PATH after report.sh's brew/system dir prepend loop
key_files:
  created:
    - scripts/write-marker.sh (taxonomy-validated marker producer, METER-02/D-03)
    - tests/test_write_marker.sh (10-case integration test suite)
    - tests/test_report_argv.sh (6-case argv-capture integration test suite)
  modified:
    - scripts/report.sh (4 changes: MARKERS_DIR/REVENIUM_AGENT_PREFIX/get_root_session_id inline; root_sid once per session; task_type NP-1 lookup; --agent openclaw-{root} + --task-type always-present)
decisions:
  - "HOME override in test_report_argv.sh: report.sh's PATH loop prepends /opt/homebrew/bin (static), which beats a TMP_BIN stub. Setting HOME to a temp dir makes ~/.local/bin (last-prepended = first on PATH) point to the stub."
  - "Inline constants in report.sh (not source common.sh): avoids double-definition of log/info/warn and PATH block between the two scripts."
  - "Marker cache (temp file per session) for NP-1: avoids per-completion python3 cold-start (Pitfall 3); mirrors report.sh's existing msg_meta_file caching pattern."
metrics:
  duration: "~8 minutes"
  completed: "2026-06-03"
  tasks_completed: 2
  files_created: 3
  files_modified: 1
---

# Phase 4 Plan 02: Marker Producer & Attribution Summary

**One-liner:** write-marker.sh (taxonomy-allowlist + ISO8601 + flock, METER-02) and report.sh NP-1 timestamp-precedence task-type correlation + --agent openclaw-{root} + --task-type always-present (METER-03/TRACE-01/02), with TDD-green integration tests for both.

## What Was Built

### Task 1: write-marker.sh — taxonomy validate + ISO8601 marker append (TDD)

**RED commit:** `73929e9` — 10-case test suite written first (fails with exit 127 — script not yet created).

**GREEN commit:** `610b930` — `scripts/write-marker.sh` implemented:

- Validates `$1` against `task-taxonomy.json` `labels` set (ASVS V5 / T-04-04)
- Resolves current sid: reads `sessions.json` to exclude `agent:main:cron:*` keys (Pitfall 5); takes freshest non-cron `*.jsonl` by mtime; falls back to `pseudo-<epoch>` if no candidates
- Sid charset guard `[0-9a-fA-F-]+|pseudo-[0-9]+` before any path construction (path-traversal, T-04-06)
- Creates `markers/` dir mode `0700` (ASVS V4 / T-04-07)
- Appends `{"ts":"<ISO8601Z>","task_type":"<label>"}` under `fcntl.LOCK_EX` + `O_APPEND` — compact `json.dumps` separators so no raw label bytes hit the file unescaped (T-04-04)
- Env-passing heredoc (`<<'PY'`), no `${VAR}` interpolation (T-04-09)
- Prints `marker written: <path>` on success; non-zero exit on unknown/unsafe label

**All 10 tests pass:**
1. Valid label exits 0
2. Valid label prints `marker written:`
3. Marker file created at expected path (`markers/<sid>.jsonl`)
4. Marker file has exactly 1 line after first invocation
5. Marker line has ISO8601 ts and correct `task_type`
6. `markers/` dir is mode 0700
7. Unknown label exits non-zero (exit 1)
8. Unknown label writes no marker line
9. Two rapid invocations yield exactly 2 lines
10. All 2 lines are valid JSON with `ts` and `task_type`

### Task 2: report.sh — task-type correlation + --agent/--task-type wiring (TDD)

**RED commit:** `800743f` — 6-case argv-capture test suite written first (fails — report.sh lacks --task-type/--agent openclaw-).

**GREEN commit:** `bd4bb4c` — `scripts/report.sh` modified with 4 changes:

**Change 1 — inline constants** (after existing path constants block):
- `MARKERS_DIR`, `REVENIUM_AGENT_PREFIX` (openclaw-), `get_root_session_id()` wrapper added inline — chosen over `source common.sh` to avoid double-definition with report.sh's own `log/info/warn` (tee-based) and PATH block.

**Change 2 — resolve root once per session** (before the line loop):
- `root_sid=$(get_root_session_id "${session_id}")` + `root_sid="${root_sid:-${session_id}}"` (belt-and-suspenders fail-open, D-05)
- Marker cache: `_MARKER_FILE="${marker_file}" python3 <<'PY'` parses + sorts marker JSONL into `<ts>\t<task_type>` temp file ONCE per session (NP-1 performance, Pitfall 3)

**Change 3 — per-line task_type lookup** (after `timestamp` extracted):
- NP-1 precedence: scan sorted cache for latest marker `ts <= completion_ts`; default `unclassified` (A4)
- Per-line `try/except` for malformed lines (T-04-05); 64-char truncation for log injection (T-04-08)

**Change 4 — `post_to_revenium` signature + call site**:
- Added `root_sid` and `task_type` params (positions 20-21)
- `--agent "OpenClaw"` → `--agent "${REVENIUM_AGENT_PREFIX}${root_sid}"` (D-07)
- `--task-type "${task_type:-unclassified}"` added always-present (METER-03, A4)
- No `--agentic-job-*` tokens (verified; anti-pattern dropped per RESEARCH)

**All 6 tests pass:**
1. `--task-type research` for completion between T1 (research marker) and T2 (generation marker)
2. `--task-type generation` for completion after T2 marker
3. `--task-type unclassified` for session with no marker file
4. `--task-type` present in all 3 meter completion calls (always-present invariant)
5. `--agent` value has `openclaw-` prefix (TRACE-02)
6. No `--agentic-job-*` tokens in captured argv

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] HOME override required in test_report_argv.sh for revenium stub to win PATH race**
- **Found during:** Task 2 GREEN phase
- **Issue:** report.sh's PATH expansion loop prepends static system dirs including `/opt/homebrew/bin` (unconditional, separate from brew --prefix). The real `revenium` at `/opt/homebrew/bin/revenium` is prepended LAST (first on PATH) by the loop, beating any TMP_BIN stub set by the test before invocation.
- **Fix:** Use `HOME="${TMP_FAKE_HOME}"` in the test invocation. report.sh's loop prepends `${HOME}/.local/bin` LAST (so it ends up FIRST on PATH after the loop). With HOME set to a temp dir containing our stub at `.local/bin/revenium`, the stub wins.
- **Files modified:** `tests/test_report_argv.sh`
- **No change to report.sh** — the PATH expansion behavior is correct for production use.

## TDD Gate Compliance

### Task 1 (write-marker.sh)
- RED gate: `test(04-02)` commit `73929e9` — 10 tests written before implementation, all fail (exit 127, script missing)
- GREEN gate: `feat(04-02)` commit `610b930` — script created, all 10 tests pass
- REFACTOR: not needed

### Task 2 (report.sh)
- RED gate: `test(04-02)` commit `800743f` — 6 tests written before implementation, all fail (--task-type missing from captured argv)
- GREEN gate: `feat(04-02)` commit `bd4bb4c` — report.sh modified, all 6 tests pass
- REFACTOR: not needed

## Known Stubs

None. All files deliver their full intended behavior.

## Threat Flags

No new security-relevant surface beyond what the plan's threat model covers. All STRIDE threats from the plan register addressed:

| Threat ID | Status |
|-----------|--------|
| T-04-04 | Mitigated: allowlist validation + json.dumps compact separators in write-marker.sh |
| T-04-05 | Mitigated: per-line try/except in NP-1 cache-read + per-line correlation; default unclassified |
| T-04-06 | Mitigated: sid charset guard `[0-9a-fA-F-]+|pseudo-[0-9]+` with SystemExit before path construction |
| T-04-07 | Mitigated: fcntl.LOCK_EX + O_APPEND; markers/ dir mode 0700 |
| T-04-08 | Mitigated: 64-char truncation on marker-derived values in log lines |
| T-04-09 | Mitigated: env-passing `<<'PY'` heredocs; no ${VAR} interpolation inside heredocs |

## Self-Check: PASSED

| Item | Status |
|------|--------|
| scripts/write-marker.sh | FOUND |
| tests/test_write_marker.sh | FOUND |
| scripts/report.sh (modified) | FOUND |
| tests/test_report_argv.sh | FOUND |
| commit 73929e9 (RED Task 1) | FOUND |
| commit 610b930 (GREEN Task 1) | FOUND |
| commit 800743f (RED Task 2) | FOUND |
| commit bd4bb4c (GREEN Task 2) | FOUND |
| test_write_marker.sh: 10 passed, 0 failed | VERIFIED |
| test_report_argv.sh: 6 passed, 0 failed | VERIFIED |
| No --agentic-job-* in report.sh | VERIFIED |
