# Requirements: Revenium OpenClaw Skill

**Milestone:** v1.2 Metering Completeness
**Defined:** 2026-06-04
**Core Value:** Agents never silently blow through token budgets — and every cost-incurring activity (agent completions, **guardrail enforcement events**, and **tool usage**) is metered and attributed so spend is fully observable in Revenium, with no blind spots.

> Origin: gaps found while debugging v1.1 in production on the test host. Revenium renders a completion's `operationType` as the transaction "type" column (CHAT→Chat, TOOL_CALL→Tool Call, GUARDRAIL→Guardrail) — confirmed with stakeholder.

## v1.2 Requirements

### Guardrail Event Metering (GRDEV) — Phase 9

- [x] **GRDEV-01**: A guardrail **halt** transition emits exactly one Revenium GUARDRAIL transaction (`meter completion --operation-type GUARDRAIL --task-type budget_guardrail_halt`, zero-token, `--stop-reason COST_LIMIT`), deduped via a ledger so repeated cron ticks during the same halt never re-emit
- [x] **GRDEV-02**: A guardrail **warn** transition (a rule entering the warn/blocked-in-non-autonomous state) emits exactly one GUARDRAIL transaction (`--task-type budget_guardrail_warn`), transition-gated so it fires once per warn onset — not every tick while warned
- [x] **GRDEV-03**: A **shadow-mode** would-have-halted transition emits exactly one GUARDRAIL transaction (`--task-type budget_guardrail_shadow`), once per shadow breach
- [x] **GRDEV-04**: Each guardrail transaction is attributed to the agent (root session, `--agent openclaw-<root_session_id>`) and carries the open `--agentic-job-id` when a job is in progress
- [x] **GRDEV-05**: Guardrail-event metering is fully **fail-open** — any metering error never blocks guardrail enforcement (status write, halt/warn/shadow notification) or the cron tick
- [ ] **GRDEV-06**: The dead/buggy operation-type `GUARDRAIL` heuristic is **removed** from `report.sh` (it greps tool-call args for the wrong filename and would tag every turn) so normal completions are only ever `CHAT` or `TOOL_CALL`

### Tool Registry & Tool-Event Metering (TOOLEV) — Phase 10

> Provisional — requires its own `/gsd-discuss-phase 10` / spec before planning. `meter tool-event` was explicitly out-of-scope in v1.1.

- [ ] **TOOLEV-01**: The skill registers tools in Revenium via `revenium tools create` so agent tools appear in the Revenium tool registry
- [ ] **TOOLEV-02**: Tool invocations are metered via `revenium meter tool-event` so per-tool usage is observable in Revenium
- [ ] **TOOLEV-03**: Tool-event metering does **not** double-count against the existing `meter completion --operation-type TOOL_CALL` records
- [ ] **TOOLEV-04**: Tool registry + tool-event work is fail-open and idempotency/ledger-gated so re-runs never duplicate registrations or events

## Future Requirements (deferred)

- **GRDEV-F1**: Meter per-tick guardrail API-poll overhead (the `enforcement-rules get` / `budget-rules list` / `enforcement-events list` calls) as aggregated enforcement cost — deferred for volume/noise reasons
- **JCLASS-01**: LLM `on_session_end` classifier plugin for automatic job/task inference — gated on confirming OpenClaw session-end hook support (carried from v1.1)
- **JGUARD-01**: Per-job-type budget rules in `setup-guardrails.sh --interactive` (carried from v1.1)
- **JOUT-01**: Business-outcome reporting (`--outcome-type CONVERTED`, ROI/conversion metrics) (carried from v1.1)

## Out of Scope

| Feature | Reason |
|---------|--------|
| Per-tick API-poll metering (one transaction per cron poll) | ~1,440 transactions/day — noise; v1.2 meters discrete enforcement *events*, not every poll |
| Per-job-type budget rules/guardrails | Tracking stays observability-only; enforcement stays on `AGENT:STARTS_WITH` rules |
| Native `pre_llm_call`/`pre_tool_call`/`on_session_end` hooks | Event support unconfirmed in OpenClaw; agent-driven markers + cron pipeline remain the mechanism |

## Traceability

Which phases cover which requirements. Filled during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| GRDEV-01 | Phase 9 | Planned |
| GRDEV-02 | Phase 9 | Planned |
| GRDEV-03 | Phase 9 | Planned |
| GRDEV-04 | Phase 9 | Planned |
| GRDEV-05 | Phase 9 | Planned |
| GRDEV-06 | Phase 9 | Planned |
| TOOLEV-01 | Phase 10 | Planned |
| TOOLEV-02 | Phase 10 | Planned |
| TOOLEV-03 | Phase 10 | Planned |
| TOOLEV-04 | Phase 10 | Planned |

**Coverage:**
- v1.2 requirements: 10 total
- Mapped to phases: 10 (Phase 9: 6, Phase 10: 4)
- Unmapped: 0 ✓

---
*Requirements defined: 2026-06-04 for milestone v1.2*
