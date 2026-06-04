# Phase 10: Tool Registry & Tool-Event Metering - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-04
**Phase:** 10-tool-registry-tool-event-metering
**Areas discussed:** Double-count reconciliation, Registry scope & tool-type, Registration lifecycle, Event granularity & data source

---

## Double-count reconciliation (TOOLEV-03)

| Option | Description | Selected |
|--------|-------------|----------|
| Orthogonal — keep both | TOOL_CALL completion = inference cost (tokens); tool-event = tool execution (duration/success). Both coexist, report.sh completion path unchanged. | ✓ |
| Tool-events replace TOOL_CALL tag | Revert tool-using completions to CHAT; "tool" lives only in tool-events. | |
| Emit both, correlate via IDs | Emit both, tie via trace-id/transaction-id/workflow-id, let Revenium dedupe. | |

**User's choice:** Orthogonal — keep both.
**Notes:** Tool-events are additive observability, not a billing rewrite. report.sh's operation_type logic is untouched. Researcher to confirm Revenium treats them as distinct event classes.

---

## Registry scope & tool-type (TOOLEV-01)

| Option | Description | Selected |
|--------|-------------|----------|
| Dynamic first-seen | Register each distinct tool name as observed in session toolCall entries (built-ins + MCP), ledger-gated once. | ✓ |
| Static curated set | Hand-maintained built-in list registered at setup. | |
| Hybrid | Static built-ins at setup + dynamic first-seen for the rest. | |

**User's choice:** Dynamic first-seen.
**Notes:** Self-maintaining, captures exactly what's used, no curation. `--tool-type` enum value + tool-id normalization left as a research/discretion item (CLI documents MCP_SERVER; valid set for built-ins unknown).

---

## Registration lifecycle (TOOLEV-01 / TOOLEV-04)

| Option | Description | Selected |
|--------|-------------|----------|
| Lazy in cron report | Register on first-sight during report.sh cron tick, ledger-gated, fail-open; mirrors jobs-ledger create-once. | ✓ |
| One-time at setup | Register the set during setup/post-install, ledger-gated. | |
| You decide | Defer timing to planner. | |

**User's choice:** Lazy in cron report.
**Notes:** Pairs naturally with dynamic first-seen — one pipeline, register-then-meter, fully fail-open.

---

## Event granularity & data source (TOOLEV-02)

| Option | Description | Selected |
|--------|-------------|----------|
| Every call, best-effort data | One event per toolCall; derive duration from toolCall→toolResult timestamps (else 0); derive success from tool-result error flag (else true). | ✓ |
| Every call, placeholder data | One event per toolCall, always duration 0 / success true. | |
| Only fully-instrumented calls | Meter only calls with real duration AND success; skip the rest. | |

**User's choice:** Every call, best-effort data.
**Notes:** Full per-tool coverage prioritized; fail-open on missing fields. Researcher must confirm what the OpenClaw JSONL actually records (per-tool duration, tool-result error flag) and that zero-duration is accepted by `meter tool-event`.

---

## Claude's Discretion

- Tool→agentic-job correlation field (`--workflow-id` vs `--usage-metadata` vs `--trace-id`), since `meter tool-event` has no `--agentic-job-id`. Research which Revenium maps to "agentic job"; reuse the existing root-session open-job lookup. May stop at `--agent` for v1.2 if none maps cleanly.
- `--tool-type` accepted enum + stable `--tool-id`/`--name` normalization from raw session tool names.
- `--cost-usd` — lean omit (no per-tool cost source).
- Exact code placement (likely a fail-open helper in report.sh reusing common.sh).

## Deferred Ideas

- Real per-tool cost (`--cost-usd`) — no source today.
- Tool-event-driven budget rules / enforcement — observability-only this phase.
- Backfilling tool-events for historical sessions — forward-looking only.
