# Phase 8: Halt → CANCELLED Outcome - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-03
**Phase:** 8-Halt → CANCELLED Outcome
**Areas discussed:** Wiring point / single writer, JHALT-01 vs JHALT-02 shape, In-progress job resolution, Synthetic id + idempotency + fail-open

---

## Wiring Point / Single Writer

| Option | Description | Selected |
|--------|-------------|----------|
| report.sh reads halt state | guardrail-check.sh stays jobs-blind (writes only guardrail-status.json); report.sh reads it each tick and drives CANCELLED+interrupted through its existing ledger-gated/fail-open path. One writer, ~1 tick latency. | ✓ |
| guardrail-check.sh calls jobs directly | Lower latency but forks the lifecycle into a 2nd writer; must duplicate ledger gate + JOBS_CLI_CAPABLE + 409 logic. | |
| Hybrid: marker drop + report.sh | guardrail-check.sh writes an interrupted marker; report.sh picks it up. But guardrail-check.sh has no session → needs a synthetic markers location. | |

**User's choice:** report.sh reads halt state (→ D-01)
**Notes:** Preserves the Phase 6 single-writer + idempotency invariants; keeps the halt notification path fully decoupled; ~1-tick latency acceptable since cron runs every minute regardless of the agent halt.

### Follow-ups
| Question | Selected |
|----------|----------|
| When in the tick should the handler run? | Once per tick, **after the session loop** (account-level step) → D-02 |
| How to avoid re-processing the same halt every halted tick? | **Ledger key on `haltedAt`** (`JOB:halt:<haltedAt>`) → D-03 |

---

## JHALT-01 vs JHALT-02 Shape

| Question | Options | Selected |
|----------|---------|----------|
| Real declared job open at halt? | (a) Close the real job's **own id** CANCELLED · (b) always use synthetic id | (a) → D-04 |
| No declared job open at halt? | (a) **Yes — synthetic interrupted job as fallback** · (b) always mint synthetic too (two records) · (c) no — do nothing | (a) → D-05 |

**User's choice:** Close real job's own id CANCELLED (JHALT-01); synthetic `guardrail-halt-<hex>` only as fallback when nothing declared (JHALT-02).
**Notes:** Exactly one terminal record per halt — identity preserved when a real job was open; synthetic record guarantees halted undeclared work still yields a terminal record.

---

## In-Progress Job Resolution

| Question | Options | Selected |
|----------|---------|----------|
| Source of truth for "open job"? | (a) **Jobs ledger: created-without-outcome** · (b) latest non-terminal kind:job marker · (c) both | (a) → D-06 |
| Whose open job (halt is account-scoped)? | (a) **Any open job in the jobs ledger (already root-owned)** · (b) resolve current root session first | (a) → D-07 |
| If multiple jobs open? | (a) **Close ALL open jobs CANCELLED** · (b) close only the latest | (a) → D-08 |

**User's choice:** Ledger is the source of truth; already root-only by Phase 7 D-06 so no session lookup; close ALL open jobs CANCELLED, synthetic only when zero were open.
**Notes:** Markers can lead the ledger (declared-but-not-created) and would re-introduce a race the ledger gate already handles. A machine-wide halt should leave no job dangling.

---

## Synthetic Id + Idempotency + Fail-Open

| Question | Options | Selected |
|----------|---------|----------|
| Synthetic id generation? | (a) **Deterministic from haltedAt** (`sha1(haltedAt)[:4]`) · (b) random 4-hex each mint | (a) → D-09 |
| Fail-open enforcement? | (a) **JOBS_CLI_CAPABLE probe + isolated non-fatal handler** · (b) best-effort but abort tick on hard error | (a) → D-10 |

**User's choice:** Deterministic synthetic id (stable per-halt, idempotent independent of the gate); handler behind JOBS_CLI_CAPABLE, any failure warn-logged and non-fatal.
**Notes:** guardrail-check.sh stays jobs-blind, so halt status write, agent halt message, and clear-halt are unaffected by any jobs failure.

---

## Claude's Discretion

- Exact placement of the handler step in report.sh and helper factoring (close-all loop vs. synthetic create+outcome fallback).
- Whether synthetic create/outcome are direct `revenium jobs` calls or via a helper (must stay ledger-gated + 409-as-success).
- `job_name` wording on the synthetic record (`job_type:"interrupted"` fixed); optional embedding of `haltedRule.name` for dashboard context.
- Log/warn wording for close-all and synthetic-fallback paths.
- Test strategy: open-job→CANCELLED, no-job→synthetic, multi-open→all-cancelled, idempotent-across-ticks, fail-open when JOBS_CLI not capable.

## Deferred Ideas

- Embedding rich halted-rule context into the interrupted job's metadata — follow-on if dashboards need it.
- Reopening/resuming a CANCELLED job after clear-halt — out of scope; CANCELLED is terminal.
- Real-time (same-tick) halt→close — rejected in favor of single-writer/~1-tick-latency.
- Per-job-type budget rules (JGUARD-01), business-outcome reporting (JOUT-01), classifier-plugin inference (JCLASS-01) — future milestones.
