# Phase 5: Job Declaration Foundation - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-03
**Phase:** 5-Job Declaration Foundation
**Areas discussed:** Declaration trigger model, Marker-writer interface, Marker schema & task discriminator, failure_reason field

---

## Declaration Trigger Model

### When should the agent write a `kind:"job"` marker?

| Option | Description | Selected |
|--------|-------------|----------|
| Arc-boundary (Hermes model) | Declare only when a goal-arc concludes; goal-continuity judgment; ≥1 job/session floor | ✓ |
| Every substantive turn | Mirror TASK CLASSIFICATION's binary per-turn trigger | |
| Arc-boundary + session-end floor | Arc-boundary primary, guarantee ≥1 job/session | |

**User's choice:** Arc-boundary (Hermes model)
**Notes:** Job = arc; the Revenium-native concept. No classifier plugin, so the agent is the primary author (Hermes treats this as a backstop).

### Port Hermes' strict SUCCESS/FAILED/CANCELLED status bar?

| Option | Description | Selected |
|--------|-------------|----------|
| Port verbatim | Exact Hermes criteria; CANCELLED as when-in-doubt default; SUCCESS needs self-verification | ✓ |
| Simplify to three labels | Plain outcomes without the strict bar | |

**User's choice:** Port verbatim
**Notes:** Keeps outcome data meaningful; agent won't inflate SUCCESS.

### Pivot handling + granularity floor

| Option | Description | Selected |
|--------|-------------|----------|
| Port pivot-cancel; floor as soft guideline | CANCELLED for abandoned arc on pivot; ≥1/session as guideline, not hard-enforced | ✓ |
| Port pivot-cancel only | Drop floor language entirely | |
| Defer both, basic arc trigger only | Core completion trigger only; pivot+floor deferred | |

**User's choice:** Port pivot-cancel; floor as soft guideline
**Notes:** Pivot-cancel works agent-side without a hook. Floor can't be hard-enforced without a session-end hook, so it's stated as an aim only.

---

## Marker-Writer Interface

### Structure relative to existing write-marker.sh?

| Option | Description | Selected |
|--------|-------------|----------|
| Separate write-job-marker.sh | New script reusing common.sh idioms; leaves task writer untouched | ✓ |
| Extend write-marker.sh with a job subcommand | One writer, shared code, more complex arg parser + two validation paths | |

**User's choice:** Separate write-job-marker.sh
**Notes:** Zero regression risk to the proven v1.0 task path; each writer stays simple.

### How does the agent pass the job fields?

| Option | Description | Selected |
|--------|-------------|----------|
| Named flags | `--job-id --job-name --job-type --status [--failure-reason]`; each sanitized individually | ✓ |
| Positional args | Terse but fragile with spaces/quotes and optional fields | |
| Single JSON blob | Compact but inline-JSON quoting hazards; hides per-arg sanitization | |

**User's choice:** Named flags
**Notes:** Self-documenting, order-independent, matches the `revenium jobs` CLI flag style.

### How prescriptive about `agentic_job_id` format?

| Option | Description | Selected |
|--------|-------------|----------|
| Hermes-style: kebab-slug + 4-hex | e.g. `add-pagination-endpoint-3b1e`; agent mints; writer sanitizes | ✓ |
| Specify shape, not exact format | "descriptive label + random suffix, lowercase" with latitude | |
| Writer generates the suffix | Agent supplies label only; writer appends entropy | |

**User's choice:** Hermes-style: kebab-slug + 4-hex
**Notes:** Agent mints the full ID so it can reference it again same-turn; writer still sanitizes + length-caps.

---

## Marker Schema & Task Discriminator

### `ts` format for job markers?

| Option | Description | Selected |
|--------|-------------|----------|
| ISO8601 string (match task markers) | One ts convention across both marker kinds | ✓ |
| unix_float (match Hermes) | Matches reference but adds a second ts format for report.sh to handle | |

**User's choice:** ISO8601 string (match task markers)
**Notes:** Consistency within our codebase wins; we don't share Hermes' reader.

### How does report.sh distinguish job vs task markers — touch the task writer?

| Option | Description | Selected |
|--------|-------------|----------|
| Absence = task (no back-compat change) | Only `kind:"job"` lines are jobs; existing task writer/markers untouched | ✓ |
| Add kind:"task" to task writer too | Explicitly type every marker, but modifies the proven path and still needs the fallback | |

**User's choice:** Absence = task (no back-compat change)
**Notes:** Zero regression to v1.0; report.sh branches on `kind == "job"`.

---

## failure_reason field

### Include failure_reason in the Phase 5 schema now?

| Option | Description | Selected |
|--------|-------------|----------|
| Include now (optional, FAILED-only) | `--failure-reason` flag + field, FAILED-only; forward-complete for Phase 6 `jobs outcome --metadata` | ✓ |
| Defer to Phase 6 | Ship only the 7 JOBDEC-03 fields; add later | |

**User's choice:** Include now (optional, FAILED-only)
**Notes:** Avoids re-opening the writer + directive in Phase 6. The 7 JOBDEC-03 fields stay mandatory; failure_reason is the optional 8th.

---

## Claude's Discretion

- `JOB_TAXONOMY_FILE` constant location in `common.sh` (parallel to `TAXONOMY_FILE`).
- Exact snake_case validation regex vs allowlist-membership check (researcher to confirm what `task-taxonomy.json` is held to today).
- Length-cap value for sanitized fields; exact log/error wording.
- Placement/anchoring of the JOB DECLARATION section within SKILL.md.

## Deferred Ideas

- Per-job-type budget rules/guardrails (v1.1 out of scope; future JGUARD-01).
- Classifier-plugin job inference via `on_session_end` (future JCLASS-01).
- Business-outcome reporting (`--outcome-type CONVERTED`, ROI; future JOUT-01).
- Hard session-end enforcement of the one-job-per-session floor (no hook available).
