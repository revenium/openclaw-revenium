# Roadmap: Revenium OpenClaw Skill

## Milestones

- ✅ **v1.0 Budget Guardrails & Metering** — Phases 1–4 (shipped 2026-06-03)
- 🚧 **v1.1 Agentic Job Tracking** — Phases 5–8 (in progress)

## Phases

<details>
<summary>✅ v1.0 Budget Guardrails & Metering (Phases 1–4) — SHIPPED 2026-06-03</summary>

Full details archived in [`milestones/v1.0-ROADMAP.md`](milestones/v1.0-ROADMAP.md).

- [x] **Phase 1: Skill Scaffolding** (1/1 plans) — completed 2026-03-14 — valid SKILL.md that loads in OpenClaw and gates on the `revenium` binary
- [x] **Phase 2: Setup Flow** (1/1 plans) — completed 2026-05-29 — agent-guided first-time config of API key, budget, and anomaly-ID persistence
- [x] **Phase 3: Guardrail Engine** (8/8 plans) — completed 2026-05-31 — guardrails-native enforcement (common.sh, setup-guardrails.sh, guardrail-check.sh, cron pipeline, halt flow)
- [x] **Phase 4: Task Metering & Attribution** (4/4 plans) — completed 2026-06-03 — task-type taxonomy, TASK CLASSIFICATION directive, `--task-type` metering, and root-session attribution

</details>

### 🚧 v1.1 Agentic Job Tracking (In Progress)

**Milestone Goal:** Group an OpenClaw agent's work into Revenium *agentic jobs* — every completion attributed to a job, jobs opened and closed with a terminal outcome — so spend and success are observable at the job level, not just per session/task-type. Ports the `hermes-revenium` job model onto OpenClaw's agent-written-marker architecture (no native-hook dependency).

- [x] **Phase 5: Job Declaration Foundation** - Agent declares jobs via validated `kind:"job"` markers backed by an 11-label job taxonomy (completed 2026-06-03)
- [x] **Phase 6: Job Lifecycle Wiring** - `report.sh` opens, meters under, and closes each declared job idempotently via the jobs ledger (completed 2026-06-03)
- [x] **Phase 7: Root-Session Job Rollup** - Subagent completions roll up under the root session's job so one job spans the whole agent tree (completed 2026-06-03)
- [ ] **Phase 8: Halt → CANCELLED Outcome** - A guardrail halt closes the in-progress job CANCELLED with a terminal interrupted job record

## Phase Details

### Phase 5: Job Declaration Foundation

**Goal**: The agent can declare a unit of work as an agentic job by appending a validated marker, backed by a shipped job-type taxonomy and a safe, unique job ID.
**Depends on**: Phase 4 (extends the v1.0 marker writer and TASK CLASSIFICATION pattern)
**Requirements**: JOBDEC-01, JOBDEC-02, JOBDEC-03, JOBDEC-04
**Success Criteria** (what must be TRUE):

  1. A `job-taxonomy.json` with the 11 job-type labels installs to the skill runtime location and validates against the same snake_case regex as `task-taxonomy.json`
  2. SKILL.md contains a JOB DECLARATION directive that tells the agent to append a `kind:"job"` marker when a unit of work concludes
  3. The marker writer accepts a well-formed job marker (kind, ts, sid, agentic_job_id, job_name, job_type, status) via flock-protected atomic append, and rejects records with an unknown `job_type` or missing/malformed fields
  4. A job marker carries a stable, unique `agentic_job_id` (business label + entropy suffix) that is sanitized (`:`, `|`, newline → `_`) before any value can reach a CLI argument**Plans**: 3 plans

**Wave 1**

  - [x] 05-01-PLAN.md — job-taxonomy.json (11 labels) + common.sh JOB_TAXONOMY_FILE + post-install seeding/chmod + Wave 0 RED test harness (JOBDEC-01)

**Wave 2** *(blocked on Wave 1 completion)*

  - [x] 05-02-PLAN.md — write-job-marker.sh: named-flag writer with sanitization, allowlist validation, flock append; turns the test harness green (JOBDEC-03, JOBDEC-04)

**Wave 3** *(blocked on Wave 2 completion)*

  - [x] 05-03-PLAN.md — SKILL.md JOB DECLARATION directive + references/job-declaration.md operational detail (JOBDEC-02)

### Phase 6: Job Lifecycle Wiring

**Goal**: Each declared job runs the full Revenium lifecycle — created once, every belonging completion stamped to it, and closed once with a terminal outcome — driven idempotently by `report.sh` and a jobs ledger, without endangering existing metering.
**Depends on**: Phase 5
**Requirements**: JLIFE-01, JLIFE-02, JLIFE-03, JLIFE-04, JLIFE-05
**Success Criteria** (what must be TRUE):

  1. A declared job appears in Revenium exactly once via `jobs create` even when `report.sh` runs across multiple cron ticks
  2. Every completion belonging to a job ships with `--agentic-job-id`, `--agentic-job-name`, and `--agentic-job-type` on `meter completion`
  3. A job is closed exactly once with `jobs outcome <id> --result SUCCESS|FAILED|CANCELLED`, reading the result from the marker's `status`
  4. A `jobs` CLI error or absent subcommand is caught and logged, and task-type metering plus guardrail checks continue to run (fail-open)
  5. The jobs ledger persists created and closed job IDs so re-runs never re-issue a `create` or `outcome` for the same job

**Plans**: 3 plans

**Wave 1**

  - [x] 06-01-PLAN.md — Wave 0 test scaffolding: extend stub-revenium.sh (jobs fakes + 409 + capability-probe --help) and create test_report_jobs_argv.sh (RED) covering JLIFE-01..05

**Wave 2** *(blocked on Wave 1)*

  - [x] 06-02-PLAN.md — report.sh foundation: JOBS_LEDGER_FILE + JOBS_CLI_CAPABLE probe, markers-cache kind:job rows, correlation, --agentic-job-* stamping (JLIFE-02, JLIFE-04, JLIFE-05)

**Wave 3** *(blocked on Wave 2)*

  - [x] 06-03-PLAN.md — report.sh lifecycle calls: in-loop jobs create + jobs outcome, ledger-gated + 409-as-success, fail-open (JLIFE-01, JLIFE-03, JLIFE-05)

### Phase 7: Root-Session Job Rollup

**Goal**: A job spans the entire agent tree — subagent completions roll up under the root session's job, with no duplicate or mis-attributed jobs when the root ID isn't yet resolvable.
**Depends on**: Phase 6 (extends v1.0 root-session resolution onto the job lifecycle)
**Requirements**: JROLL-01, JROLL-02, JROLL-03
**Success Criteria** (what must be TRUE):

  1. A completion originating in a subagent session ships the ROOT session's `agentic_job_id`, so the whole tree's spend rolls into one job
  2. When the root job ID can't yet be resolved (marker race), the completion omits `--agentic-job-id` and is retried on the next cron tick rather than shipping a wrong or sub-session ID
  3. Only the root session's declared job is shipped as a job; a subagent's internally-declared job markers are not shipped as separate jobs

**Plans**: 2 plans

**Wave 1**

  - [x] 07-01-PLAN.md — Wave 0 RED tests: add GROUP F/G/H to test_report_jobs_argv.sh with inline sessions_spawn + root/child markers (inherit / race-omit+orphan-drop / suppress) covering JROLL-01/02/03

**Wave 2** *(blocked on Wave 1)*

  - [x] 07-02-PLAN.md — report.sh rollup: root_aid cross-session resolver + subagent override (or omit on race) + root-only gates on jobs create/outcome; turns GROUP F/G/H green (JROLL-01, JROLL-02, JROLL-03)

### Phase 8: Halt → CANCELLED Outcome

**Goal**: A guardrail halt that interrupts an in-progress job still produces a terminal job record — the job is closed CANCELLED and an interrupted job is recorded — wired into the existing halt flow.
**Depends on**: Phase 6 (outcome reporting), Phase 7 (root job resolution), and the v1.0 guardrail halt flow
**Requirements**: JHALT-01, JHALT-02
**Success Criteria** (what must be TRUE):

  1. When a guardrail halt interrupts an in-progress job, that job is closed with outcome `CANCELLED` through the existing halt flow
  2. An interrupted job is recorded with `job_type:"interrupted"` and a synthetic `agentic_job_id` (e.g. `guardrail-halt-<hex>`) so halted work still yields a terminal job record

**Plans**: TBD

## Progress

**Execution Order:**
Phases execute in numeric order: 5 → 6 → 7 → 8

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Skill Scaffolding | v1.0 | 1/1 | Complete | 2026-03-14 |
| 2. Setup Flow | v1.0 | 1/1 | Complete | 2026-05-29 |
| 3. Guardrail Engine | v1.0 | 8/8 | Complete | 2026-05-31 |
| 4. Task Metering & Attribution | v1.0 | 4/4 | Complete | 2026-06-03 |
| 5. Job Declaration Foundation | v1.1 | 3/3 | Complete    | 2026-06-03 |
| 6. Job Lifecycle Wiring | v1.1 | 3/3 | Complete    | 2026-06-03 |
| 7. Root-Session Job Rollup | v1.1 | 2/2 | Complete   | 2026-06-03 |
| 8. Halt → CANCELLED Outcome | v1.1 | 0/TBD | Not started | - |
