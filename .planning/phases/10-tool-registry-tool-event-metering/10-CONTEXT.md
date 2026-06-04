# Phase 10: Tool Registry & Tool-Event Metering - Context

**Gathered:** 2026-06-04
**Status:** Ready for planning

<domain>
## Phase Boundary

Make agent **tool usage** observable in Revenium. Two new mechanisms layered onto the existing `report.sh` cron/metering pipeline:

1. **Tool registry** (`revenium tools create`) — agent tools appear in Revenium's tool registry (TOOLEV-01).
2. **Tool-event metering** (`revenium meter tool-event`) — each tool invocation is metered as a discrete tool-event so per-tool usage (count, duration, success) is observable (TOOLEV-02).

This is purely **additive** observability: it does **not** change how completions are metered today, must **not** double-count against the existing `meter completion --operation-type TOOL_CALL` records (TOOLEV-03), and is fully fail-open + ledger-idempotency-gated so re-runs never duplicate registrations or events (TOOLEV-04).

**In scope:** registering tools on first sight; emitting one tool-event per session `toolCall` entry; a registry dedup ledger; reusing the established root-session attribution; all fail-open behind the existing capability-probe + cron-flock model.

**Out of scope (deferred to other phases / backlog):** per-tick guardrail API-poll metering (already deferred); changing the completion metering path; business-outcome reporting (JOUT-01); LLM session-end classifier (JCLASS-01); per-job-type budget rules (JGUARD-01).
</domain>

<decisions>
## Implementation Decisions

### Double-count reconciliation (TOOLEV-03) — the headline
- **D-01:** **Orthogonal — keep both.** The existing `TOOL_CALL` completion record (emitted by `report.sh` when `stopReason=toolUse`, ~line 847) captures the **LLM inference cost** (tokens) of a turn that used tools; a `tool-event` captures the **tool execution** (duration / success). They measure different dimensions, so both coexist. **`report.sh`'s `operation_type` / completion path is unchanged** — Phase 10 adds tool-events alongside, never rewrites the completion logic. (Stakeholder decision; researcher to confirm Revenium renders these as distinct, non-overlapping event classes — see Canonical/Research.)

### Registry scope (TOOLEV-01)
- **D-02:** **Dynamic first-seen.** Register each distinct tool name as it is first observed in session `toolCall` entries — built-ins (e.g. `bash`, `read`, `edit`) **and** MCP tools (e.g. `mcp__server__tool`). Self-maintaining, captures exactly what's used, no hand-curated list to maintain. Each tool registers exactly once (ledger-gated, see D-05).

### Registration lifecycle (TOOLEV-01 / TOOLEV-04)
- **D-03:** **Lazy, in the cron report path.** During the normal `report.sh` cron tick, when a tool is seen for the first time (absent from the registry ledger), register it (`revenium tools create`) then meter its event. One pipeline, ledger-gated, fully fail-open — mirrors the existing jobs-ledger "create-once" pattern in `report.sh`. Pairs with D-02 (dynamic first-seen). No separate setup-time registration step.

### Tool-event granularity & data source (TOOLEV-02)
- **D-04:** **One tool-event per `toolCall` entry, best-effort data.** Full per-tool coverage — every individual invocation becomes one `meter tool-event`. Required fields supplied best-effort:
  - `--duration-ms`: derive from the `toolCall`→`toolResult` timestamp delta when both are present; otherwise `0` (the API accepts zero — confirmed for `meter completion` in Phase 9; researcher to confirm the same for `tool-event`).
  - `--success`: derive from the corresponding tool-result error flag; default `true` when indeterminable.
  - `--error-message`: include when the tool-result indicates failure.
  Missing fields never block emission (fail-open); a tool is still metered even with placeholder timing.

### Attribution (carried forward from Phases 4/6/7)
- **D-05 (carry-forward):** Tool-events carry `--agent "openclaw-<root_session_id>"` using the **same root-session resolution** already in `report.sh`/`common.sh` (`get_root_session_id`, `REVENIUM_AGENT_PREFIX`). Idempotency uses the **same ledger pattern** as jobs/guardrail metering — a new registry ledger keyed per tool-id (register-once) and the existing reported-ledger discipline so a given `toolCall` is metered at-most-once across cron ticks. Fail-open is non-negotiable (TOOLEV-04): tool registry / tool-event work runs as a best-effort addition behind the existing `*_CLI_CAPABLE` capability probe and must never endanger completion metering, job tracking, or the cron tick.

### Claude's Discretion (resolve in research/planning)
- **Tool→agentic-job correlation:** `meter tool-event` has **no `--agentic-job-id` flag** (unlike `meter completion`). Rolling tool usage up under the agentic job (Phases 5–8) must use one of `--workflow-id`, `--usage-metadata` (JSON), or `--trace-id`. **Research item:** determine which field Revenium maps to "agentic job" for tool-events, then reuse the existing root-session open-job lookup to populate it. If none cleanly maps, attribution may stop at `--agent` (root session) for v1.2 — note the choice explicitly.
- **`--tool-type` value + `--tool-id` normalization:** `--tool-type` is required (CLI documents `MCP_SERVER`; valid enum for built-ins unknown). **Research item:** confirm accepted `--tool-type` values; decide the string for built-ins vs MCP tools. Derive a stable, sanitized `--tool-id` (and `--name`) from raw session tool names (kebab/normalize; mirror the id-sanitization discipline from the job-marker work).
- **`--cost-usd`:** Lean **omit** — tools have no token cost and Revenium derives nothing useful from a fabricated value. Planner may revisit if a real per-tool cost source appears.
- **Where the code lives:** Likely a fail-open helper in `report.sh` (it already parses sessions + `toolCall` entries) reusing `common.sh` constants/helpers; planner decides exact placement, consistent with the locked decisions above.
</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase scope & requirements
- `.planning/ROADMAP.md` §"Phase 10: Tool Registry & Tool-Event Metering" — goal, success criteria, the three flagged open design questions (now decided above).
- `.planning/REQUIREMENTS.md` — TOOLEV-01..04 (lines 24–27) and the Out-of-Scope table (per-tick poll metering, per-job-type rules, native hooks).
- `.planning/PROJECT.md` — Core value, key decisions (esp. "Revenium renders completion `operationType` as the transaction type"), v1.2 milestone framing.

### Metering surface being extended (the code Phase 10 modifies/reuses)
- `scripts/report.sh` — the cron metering pipeline. Key spots: TOOL_CALL detection `stopReason==toolUse` → `operation_type=TOOL_CALL` (~line 843–848, **D-01 leaves this untouched**); `post_to_revenium` argv array + exit handling (~lines 229–256); session JSONL `.message.content[] | select(.type=="toolCall")` parsing (~line 534+); jobs-ledger "create-once" + open-job scan pattern (the analog for D-03/D-05 register-once + job correlation).
- `scripts/common.sh` — path constants (`SESSIONS_DIR`, `JOBS_LEDGER_FILE`, `GUARDRAIL_LEDGER_FILE`), `get_root_session_id`, `REVENIUM_AGENT_PREFIX`, info/warn loggers — reuse these; add a new registry-ledger constant here.

### Pattern precedent to mirror (fail-open + ledger idempotency + attribution)
- `.planning/phases/09-guardrail-event-metering/09-CONTEXT.md` — D-10 (transition gate + dedup ledger), D-11 (fail-open: metering after durable writes), attribution decisions. Phase 10 inherits the same fail-open + ledger discipline.
- `.planning/phases/06-*/`, `07-*/`, `08-*/` SUMMARY/CONTEXT (jobs lifecycle, root-session rollup, halt→CANCELLED) — the `JOBS_CLI_CAPABLE` capability-probe model, root-session resolution, and `revenium jobs create`/outcome ledger gating that D-03/D-05 mirror.

### Live CLI surface (verified on test host 172.16.1.247, 2026-06-04)
- `revenium tools create` requires `--name`, `--tool-id`, `--tool-type` (e.g. `MCP_SERVER`); optional `--description`, `--tool-provider`, `--enabled`. Subcommands: list/get/create/update/delete. Supports `--dry-run`.
- `revenium meter tool-event` requires `--tool-id`, `--duration-ms`, `--timestamp`; optional `--success`, `--agent`, `--cost-usd`, `--operation`, `--error-message`, `--trace-id`, `--transaction-id`, `--workflow-id`, `--usage-metadata`, `--organization-name`. Supports `--dry-run`. **Note: no `--agentic-job-id`** (see Discretion: tool→job correlation).
</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `report.sh` session/`toolCall` parsing + `post_to_revenium` argv-array discipline — directly extensible to a `meter tool-event` emitter using the same bash-array pattern.
- `common.sh` `get_root_session_id` + `REVENIUM_AGENT_PREFIX` — reuse verbatim for `--agent` attribution (D-05).
- Jobs-ledger "create-once + 409-as-success + fail-open behind capability probe" logic — the structural template for D-03 (register-once) and D-05 (idempotent tool-event emission).

### Established Patterns
- **Fail-open behind a capability probe** (`*_CLI_CAPABLE`) and the cron flock — every Revenium-touching addition since Phase 6 follows this; TOOLEV-04 requires it.
- **Ledger-keyed idempotency** under `OPENCLAW_HOME` (jobs, guardrail, reported ledgers) — add a tool-registry ledger in the same style.
- **Bash 3.2 portability** (macOS): no `<<<` in subshells, env-passing `<<'PY'` heredocs with no `${}` inside, strict array argv — carried from Phases 8–9.

### Integration Points
- New tool-event emission slots into the per-session loop in `report.sh` (where `toolCall` entries are already iterated), AFTER completion metering so it can never delay or break it.
- Tool→job correlation (if adopted) reuses the existing root-session open-job lookup from the jobs work.
</code_context>

<specifics>
## Specific Ideas

- Stakeholder framing: tool-events and TOOL_CALL completions are **complementary, not redundant** (D-01) — observability layer, not a billing rewrite.
- Validate every new flag against the **live CLI on host 172.16.1.247** the same way Phase 9 did (`--help` + `--dry-run`, optionally one real zero-cost event) before locking the flag set — especially zero-duration acceptance and the correlation field.
</specifics>

<deferred>
## Deferred Ideas

- **Real per-tool cost (`--cost-usd`)** — no cost source exists today; revisit only if Revenium or OpenClaw surfaces per-tool cost.
- **Tool-event-driven budget rules / enforcement** — Phase 10 is observability-only; enforcement stays on the existing `AGENT:STARTS_WITH` rules (consistent with the v1.2 Out-of-Scope table).
- **Backfilling tool-events for historical sessions** — scope is forward-looking from the cron pipeline; no historical replay.

None of the above are blockers; all are out of this phase's scope.
</deferred>

---

*Phase: 10-tool-registry-tool-event-metering*
*Context gathered: 2026-06-04*
