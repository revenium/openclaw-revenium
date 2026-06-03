# Requirements: Revenium OpenClaw Skill

**Milestone:** v1.1 Agentic Job Tracking
**Defined:** 2026-06-03
**Core Value:** Agents never silently blow through token budgets — and every completion is metered and attributed (now by root session, task type, **and agentic job**) so spend and success are observable in Revenium.

> Reference implementation: the `hermes-revenium` skill. v1.1 ports its agentic-job model, **adapted** to OpenClaw's agent-written-marker architecture (Hermes infers jobs via an LLM `on_session_end` classifier plugin — deliberately not adopted here, per v1.0's unconfirmed-hooks decision).

## v1.1 Requirements

### Job Declaration (JOBDEC)

- [x] **JOBDEC-01**: A `job-taxonomy.json` ships with 11 job-type labels (`feature_development`, `bug_fix`, `code_review`, `refactoring`, `research`, `debugging`, `testing`, `documentation`, `devops`, `planning`, `interrupted`), validated against the same snake_case regex as `task-taxonomy.json`, and is installed to the skill runtime location alongside it
- [x] **JOBDEC-02**: SKILL.md includes a `JOB DECLARATION` directive instructing the agent to append a `kind:"job"` marker when a unit of work concludes (mirrors the existing TASK CLASSIFICATION directive; no native-hook dependency)
- [x] **JOBDEC-03**: The marker writer accepts and validates job markers — fields `kind`, `ts`, `sid`, `agentic_job_id`, `job_name`, `job_type`, `status` (SUCCESS/FAILED/CANCELLED) — rejecting unknown `job_type` and malformed records, with the existing flock-protected atomic append
- [x] **JOBDEC-04**: The agent generates a stable, unique `agentic_job_id` (business label + short entropy suffix) and the writer sanitizes it (`:`, `|`, newline → `_`) before any value reaches a CLI argument

### Job Lifecycle (JLIFE)

- [ ] **JLIFE-01**: `report.sh` opens each declared job via `revenium jobs create --agentic-job-id --name --type --environment` exactly once, ledger-gated and idempotent across cron ticks
- [ ] **JLIFE-02**: Every metered completion belonging to a job is stamped with `--agentic-job-id`, `--agentic-job-name`, and `--agentic-job-type` on `revenium meter completion`
- [ ] **JLIFE-03**: `report.sh` reports a terminal outcome via `revenium jobs outcome <id> --result SUCCESS|FAILED|CANCELLED` once per job (ledger-gated), reading the result from the job marker's `status`
- [ ] **JLIFE-04**: Job tracking fails open — any `jobs` CLI error or absent subcommand is caught and logged without blocking task-type metering or guardrail checks
- [ ] **JLIFE-05**: A jobs ledger persists created/closed job IDs so re-runs never duplicate `create` or `outcome` calls

### Root-Session Job Rollup (JROLL)

- [ ] **JROLL-01**: Completions from a subagent session ship the ROOT session's `agentic_job_id` (override), so one job spans the whole agent tree (extends v1.0 root-session resolution)
- [ ] **JROLL-02**: When the root job ID cannot yet be resolved (marker race), the completion omits `--agentic-job-id` and is retried on the next cron tick rather than shipping a wrong or sub-session ID
- [ ] **JROLL-03**: Top-level (root) sessions ship their own declared job; a subagent's internally-declared job markers are not shipped as separate jobs

### Halt → Outcome (JHALT)

- [ ] **JHALT-01**: When a guardrail halt interrupts an in-progress job, that job is closed with outcome `CANCELLED`, wired into the existing halt flow
- [ ] **JHALT-02**: An interrupted job is recorded with `job_type:"interrupted"` and a synthetic `agentic_job_id` (e.g. `guardrail-halt-<hex>`) so halted work still produces a terminal job record

## Future Requirements (deferred)

- **JCLASS-01**: LLM `on_session_end` classifier plugin that infers jobs automatically (Hermes-style), as primary inference with the agent-written marker as backstop — gated on confirming OpenClaw session-end hook support
- **JGUARD-01**: Per-job-type budget rules in `setup-guardrails.sh --interactive` (grouped/scoped by job type), analogous to the existing per-task-type picker
- **JOUT-01**: Business outcome reporting beyond execution result — `--outcome-type CONVERTED`, `--outcome-value`, ROI/conversion-funnel metrics

## Out of Scope

| Feature | Reason |
|---------|--------|
| Classifier-plugin job inference (v1.1) | OpenClaw `on_session_end` hook events unconfirmed; agent-written markers used instead (v1.0 architectural decision) — deferred, not abandoned |
| Per-job-type budget rules (v1.1) | Job tracking is observability-only this milestone; enforcement stays on existing `AGENT:STARTS_WITH` rules with server-side job rollup |
| `meter tool-event` reporting | Out of scope since v1.0; unchanged |
| Native `pre_llm_call`/`pre_tool_call` hooks | Event support unconfirmed in OpenClaw; agent-driven markers remain the mechanism |

## Traceability

Which phases cover which requirements. Filled during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| JOBDEC-01 | Phase 5 | Complete |
| JOBDEC-02 | Phase 5 | Complete |
| JOBDEC-03 | Phase 5 | Complete |
| JOBDEC-04 | Phase 5 | Complete |
| JLIFE-01 | Phase 6 | Pending |
| JLIFE-02 | Phase 6 | Pending |
| JLIFE-03 | Phase 6 | Pending |
| JLIFE-04 | Phase 6 | Pending |
| JLIFE-05 | Phase 6 | Pending |
| JROLL-01 | Phase 7 | Pending |
| JROLL-02 | Phase 7 | Pending |
| JROLL-03 | Phase 7 | Pending |
| JHALT-01 | Phase 8 | Pending |
| JHALT-02 | Phase 8 | Pending |

**Coverage:**
- v1.1 requirements: 14 total
- Mapped to phases: 14 (Phase 5: 4, Phase 6: 5, Phase 7: 3, Phase 8: 2)
- Unmapped: 0 ✓

---
*Requirements defined: 2026-06-03 for milestone v1.1*
