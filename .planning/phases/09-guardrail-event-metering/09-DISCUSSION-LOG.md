# Phase 9: Guardrail Event Metering — Discussion Log

**Date:** 2026-06-04
**Mode:** discuss (default)

> Human-reference audit trail. Not consumed by downstream agents — see `09-CONTEXT.md` for the decisions that drive research/planning.

## Area 1 — Warn semantics (GRDEV-02 ambiguity)

**Options presented:** soft warn-threshold (`state='warn'`) | non-autonomous hard-block (`warned`) | both (distinct task_types)
**Selected:** Soft warn-threshold (`state='warn'`).
**Notes:** guardrail-check.sh computes per-rule `state` but emits no warn-onset transition today — must be added (mirror `shadow_transitions`). Non-autonomous "warned" deferred.

## Area 2 — Metering location

**Options presented:** directly from guardrail-check.sh | hand off to report.sh
**Selected:** Directly from guardrail-check.sh.
**Notes:** keeps the transition detector and emitter together; must reimplement attribution + fail-open + ledger locally (patterns mirrored from report.sh).

## Area 3 — Attribution

**Options presented:** open job(s) + recent root session | account-level only | one per open job
**Selected:** Open job(s) + recent root session (single event).
**Follow-up — multi-job tiebreak:** options = most-recently-opened job | omit when ambiguous | root session's own job. **Selected:** Most-recently-opened job. (Omit `--agentic-job-id` only when zero jobs open.)

## Area 4 — Synthetic completion fields

**Options presented:** descriptive constants | mirror the halted rule | reuse last real completion's model
**Selected:** Descriptive constants (e.g. `--provider revenium --model guardrail-enforcement`), zero tokens/cost.

## Deferred ideas

- Non-autonomous hard-block ("warned") as a distinct `budget_guardrail_blocked` transaction.
- Per-tick API-poll overhead metering (GRDEV-F1).
- One-per-open-job guardrail events.
- Tool registry + tool-event metering (Phase 10).

## Claude's discretion (noted in CONTEXT)

- Exact constant strings for model/provider; ledger onset-marker format for warn/shadow; synthetic request-duration/timestamps; shared `_emit_guardrail_event` helper shape.
