---
phase: 7
slug: root-session-job-rollup
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-06-03
---

# Phase 7 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash integration tests (no external framework) + pytest for the resolver |
| **Config file** | none — tests are standalone shell scripts |
| **Quick run command** | `bash tests/test_report_jobs_argv.sh` |
| **Full suite command** | `bash tests/test_report_argv.sh && bash tests/test_report_jobs_argv.sh && python3 -m pytest tests/test_get_root_session_id.py -v` |
| **Estimated runtime** | ~20 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test_report_jobs_argv.sh`
- **After every plan wave:** Run the full suite command above
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** ~20 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| (planner assigns) | — | 0 | JROLL-01/02/03 | — | N/A (observability) | integration | `bash tests/test_report_jobs_argv.sh` | ❌ W0 (GROUPS F/G/H to add) | ⬜ pending |
| (planner assigns) | — | 1 | JROLL-01 | — | Subagent ships ROOT's `agentic_job_id` | integration | `bash tests/test_report_jobs_argv.sh` (GROUP F) | ❌ W0 | ⬜ pending |
| (planner assigns) | — | 1 | JROLL-02 | — | Race → omit `--agentic-job-id`, never ship wrong id | integration | `bash tests/test_report_jobs_argv.sh` (GROUP G) | ❌ W0 | ⬜ pending |
| (planner assigns) | — | 1 | JROLL-03 | — | Subagent job markers suppressed (no create/outcome) | integration | `bash tests/test_report_jobs_argv.sh` (GROUP H) | ❌ W0 | ⬜ pending |
| (planner assigns) | — | 1 | Phase 6 regression | — | Root path byte-identical (Groups A–E) | integration | `bash tests/test_report_jobs_argv.sh` | ✅ exists | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

*Note: this is a bash/shell phase — "secure behavior" maps to correct rollup/suppression behavior, not auth. The planner fills exact Task IDs and plan/wave assignments at plan time.*

---

## Wave 0 Requirements

- [ ] `tests/test_report_jobs_argv.sh` — add **GROUP F** (subagent inherits root `agentic_job_id` — JROLL-01)
- [ ] `tests/test_report_jobs_argv.sh` — add **GROUP G** (race window → omit `--agentic-job-id`, orphan id not leaked — JROLL-02)
- [ ] `tests/test_report_jobs_argv.sh` — add **GROUP H** (subagent job markers suppressed; root still creates once — JROLL-03)
- [ ] `tests/fixtures/sessions/{ROOT_UUID}.jsonl` — root session JSONL with `sessions_spawn` tool result linking `details.childSessionKey` → child (REQUIRED so `get-root-session-id.py` resolves child→root; without it every session looks like a root and subagent detection never fires)
- [ ] `tests/fixtures/sessions/{CHILD_UUID}.jsonl` — subagent session JSONL with one completion
- [ ] `tests/fixtures/markers/{ROOT_UUID}.jsonl` — root job marker (`kind:"job"`, `agentic_job_id`, `job_name`, `job_type`, `status`)
- [ ] `tests/fixtures/markers/{CHILD_UUID}.jsonl` — subagent's own `kind:"job"` marker (different id, to prove it is NOT shipped)
- [ ] `tests/stub-revenium.sh` — extend if needed to capture `create`/`outcome` token counts per session pass

*Existing infrastructure (`tests/test_report_argv.sh`, `tests/test_get_root_session_id.py`, Groups A–E of `test_report_jobs_argv.sh`) covers Phase 6 regression and runs unchanged.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Live multi-job-root "latest wins" (D-05) on real Claude Code agent tree | JROLL-01 | Requires a real spawned-subagent session producing multiple root job markers across ticks; hard to reproduce deterministically in CI | Run a real agent tree that declares two jobs in the root, spawn a subagent, confirm the subagent's completion attributes to the latest root job id |

*All four primary Phase 7 behaviors (inherit / race-omit / suppress / orphan-drop) have automated integration coverage via GROUPS F/G/H. Only the live "latest-wins across ticks" edge is manual.*

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references (GROUPS F/G/H + fixtures)
- [ ] No watch-mode flags
- [ ] Feedback latency < 20s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
