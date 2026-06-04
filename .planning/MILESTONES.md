# Milestones

## v1.2 Metering Completeness (Shipped: 2026-06-04)

**Phases completed:** 2 phases, 6 plans, 10 tasks
**Git range:** v1.1..HEAD — 45 commits, 38 files changed (+8,054 / −179)

**Delivered:** Close the metering-visibility gaps found while debugging v1.1 in production — guardrail enforcement and tool usage are now observable as first-class Revenium transactions (`GUARDRAIL` / tool-events), not just `CHAT`/`TOOL_CALL` completions, so spend has no blind spots.

**Key accomplishments:**

- **Phase 9 — Guardrail Event Metering:** every halt / warn / shadow-mode breach emits exactly one `GUARDRAIL` transaction (`meter completion --operation-type GUARDRAIL`, zero-token), transition-gated (`state=='warn'`, `HALTED_AT`/`WARN_TRANSITIONS` emit) and ledger-deduped so repeated cron ticks never re-emit; attributed to the root agent + open `--agentic-job-id`. Section M `_emit_guardrail_event` is fully fail-open. Dead `GUARDRAIL` operation-type heuristic deleted from `report.sh` (GRDEV-06). 18/18 guardrail-argv tests + GRDEV-06 assertion green.
- **Phase 10 — Tool Registry & Tool-Event Metering:** `TOOLS_CLI_CAPABLE` probe, `normalize_tool_id`/`classify_tool_type` helpers, and `_register_tool` create-once into `revenium-tools.ledger` (TOOLEV-01/04); `_meter_tool_event` + `toolCall` scan loop in `process_session` emit one `revenium meter tool-event` per call with explicit `--success` and at-most-once ledger dedup, without double-counting the existing `TOOL_CALL` completions (TOOLEV-02/03). Anchored ledger dedup to prevent prefix false-matches; valid tool-type enum (CUSTOM, not BUILTIN). Fully fail-open.
- **Test infrastructure:** hermetic argv-capture harnesses (`test_guardrail_argv.sh`, `test_report_tool_argv.sh`) plus `stub-revenium.sh` extended with guardrails / tools / `meter tool-event` switches and failure injection — full RED→GREEN coverage of every argv contract; all three live CLI questions resolved with no fallbacks.

**Known deferred items at close:** 2 (see STATE.md → Deferred Items). Phase 9 UAT left 1 pending scenario and verification `human_needed` — both gated on a live guardrail-halt test on host 172.16.1.247, deferred in favor of validation through production use on the test host.

---

## v1.1 Agentic Job Tracking (Shipped: 2026-06-04)

**Phases completed:** 4 phases, 10 plans, 14 tasks

**Delivered:** Group an OpenClaw agent's work into Revenium *agentic jobs* — every completion attributed to a job, jobs opened and closed with a terminal outcome — ported from the hermes-revenium job model onto OpenClaw's agent-written-marker architecture (no native-hook dependency).

**Key accomplishments:**

- **Phase 5 — Job Declaration Foundation:** 11-label `job-taxonomy.json` + `write-job-marker.sh` (sanitization → allowlist → flock atomic append) + `JOB DECLARATION` directive in SKILL.md; 18/18 writer tests.
- **Phase 6 — Job Lifecycle Wiring:** `report.sh` `JOBS_LEDGER_FILE` + `JOBS_CLI_CAPABLE` probe, per-completion correlation, `--agentic-job-id/-name/-type` stamping, ledger-gated `jobs create`/`jobs outcome` with 409-as-success and fail-open; 28/28 hermetic tests.
- **Phase 7 — Root-Session Job Rollup:** subagent completions inherit the ROOT session's `agentic_job_id` (race-omit on unresolved root); root-only gates prevent duplicate/sub-session jobs; 44+9+7 tests green.
- **Phase 8 — Halt → CANCELLED Outcome:** `handle_halt()` closes open jobs `CANCELLED` or mints a synthetic `guardrail-halt-<hex>` `interrupted` job on a budget halt; 71/71 cumulative tests.
- **Post-ship production fix:** live debugging on the test host found the agent-written-marker pipeline never fired in practice — OpenClaw loads `SKILL.md` on-demand, so the "classify/declare every turn" directives were never in the agent's context. Fixed by injecting hardened Task Classification + Job Declaration **completion-gates** into `AGENTS.md` via `post-install.sh`; validated end-to-end (agent self-wrote markers → cron → job created + closed `SUCCESS` in Revenium).

**Known deferred items at close:** 3 (see STATE.md → Deferred Items / `v1.1-MILESTONE-AUDIT.md`). Phase 6 left `human_needed` on two live-API checks (server 409-conflict string; CR-01 transient-failure job retry durability), plus one quick-task flagged "missing" covering the report.sh offset-gate. All three are carried into **v1.2** — Phase 9 directly touches the CR-01/offset area.

---

## v1.0 Budget Guardrails & Metering (Shipped: 2026-06-03)

**Phases completed:** 4 phases, 14 plans, 26 tasks

**Delivered:** A skill suite that turns every OpenClaw agent on the machine into a guardrail-enforced, task-metered agent — budget rules block runaway spend, and every completion is attributed by root session and task type in Revenium.

**Key accomplishments:**

- **Phase 1 — Skill Scaffolding:** SKILL.md with single-line JSON metadata, binary gating via `requires.bins`, and a guard-first body skeleton, installed to the OpenClaw skills directory.
- **Phase 2 — Setup Flow:** Agent-guided first-time configuration of the Revenium API key, budget alert, and anomaly-ID persistence with idempotent re-run behavior.
- **Phase 3 — Guardrail Engine:** Replaced the legacy budget-alert model with first-class guardrail rules — `common.sh` infrastructure, `setup-guardrails.sh` (two-mode dispatch + ASVS V5 input validation), `guardrail-check.sh` (silent-exit guard, shadow exclusion, transition-only notifications, atomic status writes), and a guardrail-native SKILL.md/BUDGET-GUARD.md HALT flow.
- **Phase 4 — Task Metering & Attribution:** 8-label task taxonomy, mandatory TASK CLASSIFICATION directive in SKILL.md, `--task-type` on every `meter completion`, and subagent spend rollup under the root session via `--agent openclaw-<root_session_id>` (D-07 `AGENT:STARTS_WITH` budget-rule scheme + per-task-type picker).
- **Post-ship hardening:** Code review fixed 2 critical + 7 warning findings (timestamp-injection, silent metering loss, marker mis-attribution); a `pipefail`+SIGPIPE race that randomly skipped the per-task picker was root-caused and fixed; and the task-type correlation was redesigned (completion_id keying) after live debugging showed markers are written after the completions they classify.

**Known deferred items at close:** 4 (see STATE.md → Deferred Items). Phase 4 UAT accepted with 2 caveats (in-skill legacy-notice firing unverified; subagent→root rollup not exercised end-to-end), Phases 1 & 3 verification left `human_needed` (in production use), and one quick task flagged "missing" that is actually complete.

---
