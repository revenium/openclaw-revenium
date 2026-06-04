# Phase 6: Job Lifecycle Wiring - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-03
**Phase:** 6-Job Lifecycle Wiring
**Areas discussed:** Completion attribution, Job environment value, Outcome type, Jobs ledger storage

---

## Completion → Job Attribution

| Option | Description | Selected |
|--------|-------------|----------|
| Best-effort + server rollup | Stamp `--agentic-job-id` only on completions still unshipped when the closing marker is seen; rely on `--agent` rollup for the rest. Accepts partial per-completion stamping as inherent to arc-close markers. | ✓ |
| Backfill the whole arc | Re-emit/stamp all of an arc's completions once the marker closes it — guarantee every line carries the job id. Requires defeating `TX:` ledger dedup (double-billing risk); fights the offset+ledger model. | |

**User's choice:** Best-effort + server rollup
**Notes:** Job markers are arc-close while metering runs every tick, so most completions are already shipped before the closing marker appears. The job is still fully tracked (create + terminal outcome); the unshipped final completion(s) get the explicit id, the rest roll up server-side via `--agent "openclaw-<root_sid>"`.

---

## Job Environment Value (`--environment` on `jobs create`)

| Option | Description | Selected |
|--------|-------------|----------|
| Omit `--environment` | Don't pass the flag (no meaningful OpenClaw value; Hermes omits when its source column is empty). Revenium default applies. | ✓ |
| Hardcode "openclaw" | Tag every job's origin to distinguish from other integrations. | |
| Use hostname | Segment jobs per-machine. | |

**User's choice:** Omit `--environment`
**Notes:** JLIFE-01 names the flag, but populating it is optional; OpenClaw has no Hermes-style session "source"/deployment-environment column to feed it.

---

## Outcome Type (`jobs outcome`)

| Option | Description | Selected |
|--------|-------------|----------|
| Execution-result-only | Send only `--result SUCCESS\|FAILED\|CANCELLED`, never `--outcome-type`. Stays inside the observability-only / JOUT-01-deferred scope. | ✓ |
| Port Hermes CONVERTED mapping | Send `--outcome-type CONVERTED` on SUCCESS so Outcome Type isn't left PENDING. Pulls a slice of JOUT-01 forward. | |

**User's choice:** Execution-result-only
**Notes:** PROJECT.md explicitly defers business-outcome reporting (JOUT-01). Phase 6 deliberately diverges from Hermes' SUCCESS→CONVERTED mapping. `failure_reason` still rides via `--metadata` for FAILED arcs.

---

## Jobs Ledger Storage

| Option | Description | Selected |
|--------|-------------|----------|
| Separate jobs ledger file | New `revenium-jobs.ledger` with Hermes `JOB:<id>:created:<ts>` / `JOB:<id>:outcome:<ts>:<status>` rows. Keeps the `TX:` completion ledger untouched and single-purpose. | ✓ |
| Reuse `revenium-reported.ledger` | Fold `JOB:` rows into the existing completion ledger with distinct prefixes. One file, but mixes completion-dedup and job-lifecycle state in the hot path. | |

**User's choice:** Separate jobs ledger file
**Notes:** Matches the design source exactly; keeps the hot-path completion-dedup ledger single-purpose.

---

## Claude's Discretion

- Placement of the job-marker read + per-completion job resolution inside `process_session` (extend the existing markers-cache read vs. sibling read).
- In-loop vs. pre-scan `jobs create` (OpenClaw's single-session arc-close model likely needs only in-loop).
- `--agentic-job-name`/`--agentic-job-type` plumbing through `post_to_revenium`.
- Log/warn wording, `unix_ts` precision, stale-job warn threshold (`REVENIUM_JOBS_STALE_SECONDS`).
- Test strategy: extend `tests/stub-revenium.sh` + add a `report.sh` job-lifecycle test.

## Deferred Ideas

- Full-arc per-completion stamping / backfill — rejected for Phase 6 (double-billing risk); revisit only if server-side rollup proves insufficient.
- Root-session job rollup (`owning_job_id` resolution) — Phase 7 (JROLL).
- Halt → CANCELLED interrupted-job record — Phase 8 (JHALT).
- `--outcome-type CONVERTED` / business-outcome metrics — JOUT-01, future milestone.
- Per-job-type budget rules — JGUARD-01, future milestone.
