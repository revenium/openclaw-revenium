# Phase 7: Root-Session Job Rollup - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-03
**Phase:** 7-Root-Session Job Rollup
**Areas discussed:** Marker-race policy, Multi-job root pick, Orphan subagent job, Root-job lookup source

---

## Marker-race policy (JROLL-02)

| Option | Description | Selected |
|--------|-------------|----------|
| Ship now, job-less (best-effort) | Ship the completion immediately without `--agentic-job-id`; `--agent` root rollup attributes spend server-side. Consistent with Phase 6 D-01/D-02; matches Hermes' "omit the flag" comment. | ✓ |
| Defer the completion until root job resolves | Hold the completion (don't advance TX offset) until the root job marker exists, then ship with the explicit id. Literal JROLL-02 reading, but fights the CR-02 offset model and risks wedging completions. | |

**User's choice:** Ship now, job-less (best-effort)
**Notes:** Aligns with the Phase 6 precedent (don't fight the `TX:` ledger) and the Hermes design source. Captured as D-03/D-04.

---

## Multi-job root pick

| Option | Description | Selected |
|--------|-------------|----------|
| Latest root job marker wins | Most recently declared job in the root's markers file, regardless of timing. Exactly Hermes' `latest_aid`. Simple; can mis-attribute if root opened a new job after the subagent finished. | ✓ |
| Timestamp-active root job | Pick the root job whose arc temporally contains the completion's ts. More correct for multi-job roots but fragile — arc-close markers land after the arc. | |

**User's choice:** Latest root job marker wins
**Notes:** Observability-only milestone; simpler and Hermes-proven. Captured as D-05. Timestamp-active matching deferred.

---

## Orphan subagent job (JROLL-03)

| Option | Description | Selected |
|--------|-------------|----------|
| Ship job-less (drop the orphan) | If the root declared no job, the subagent's completions ship with no `--agentic-job-id`; spend rolls up via `--agent`. Never ship a sub-session id. Hermes behavior, JROLL-02/03 intent. | ✓ |
| Fall back to the subagent's own job | Let the subagent's own marker drive create/outcome and stamp its completions. Preserves more records but violates JROLL-03 and fragments one arc. | |

**User's choice:** Ship job-less (drop the orphan)
**Notes:** Same safety invariant as the race policy — never ship a sub-session job id. Captured as D-06/D-07.

---

## Root-job lookup source

| Option | Description | Selected |
|--------|-------------|----------|
| Root's markers file (live) | Read `markers/{root_sid}.jsonl` directly (Hermes `root_aid`). Sees jobs at declaration, carries name/type/ts. New cross-session read in Phase 7. | ✓ |
| Jobs ledger (created-only) | Resolve from `revenium-jobs.ledger` `JOB:<id>:created` rows. Guarantees the id exists server-side but lags and carries no name/type. | |
| You decide (planner's discretion) | Leave the source choice to research/planning. | |

**User's choice:** Root's markers file (live)
**Notes:** Carries the `job_name`/`job_type` the stamping needs and matches Hermes' resolver. Captured as D-08/D-09.

---

## Claude's Discretion

- Exact placement of the `root_aid` resolution block in `process_session` and the threading into `post_to_revenium`'s existing `--agentic-job-*` slots.
- Reuse vs sibling Python read for the cross-session `root_aid` lookup (env-passing heredoc discipline applies).
- Implementation shape of the root-only create/outcome gate (wrapper vs inline guard).
- Log/warn wording for omit-on-race and orphan-drop paths.
- Test strategy and `sessions_spawn`-linked fixture construction.

## Deferred Ideas

- Timestamp-active root-job matching (vs latest-wins) — rejected D-05, revisit only on material misattribution.
- Holding/deferring subagent completions until the root job resolves — rejected D-03.
- Halt → CANCELLED interrupted-job record — Phase 8 (JHALT).
- Per-completion full-arc backfill / restamp — rejected Phase 6 D-02.
- `--outcome-type CONVERTED` / business outcomes — JOUT-01, future milestone.
- Per-job-type budget rules — JGUARD-01, future milestone.
