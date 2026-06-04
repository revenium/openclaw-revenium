# Phase 5: Job Declaration Foundation - Context

**Gathered:** 2026-06-03
**Status:** Ready for planning

<domain>
## Phase Boundary

The agent can declare a unit of work as an **agentic job** by appending a validated `kind:"job"` marker, backed by a shipped 11-label job taxonomy and a safe, unique `agentic_job_id`.

**In scope (JOBDEC-01..04):**
- `job-taxonomy.json` with the 11 fixed labels, installed to the skill runtime location alongside `task-taxonomy.json`, validated against the same snake_case rule.
- A `JOB DECLARATION` directive in SKILL.md instructing the agent when and how to write a job marker.
- A marker writer that accepts and validates a well-formed job marker and rejects unknown `job_type` / malformed records, using the existing flock-protected atomic append.
- Agent-minted, sanitized `agentic_job_id`.

**Explicitly NOT in this phase (later phases):**
- `report.sh` wiring: `jobs create`, `--agentic-job-*` on `meter completion`, `jobs outcome`, the jobs ledger — **Phase 6 (JLIFE)**.
- Root-session job rollup / subagent override — **Phase 7 (JROLL)**.
- Halt → CANCELLED interrupted-job record — **Phase 8 (JHALT)**.

</domain>

<decisions>
## Implementation Decisions

### Declaration Trigger Model (JOBDEC-02 — the SKILL.md directive)
- **D-01:** Job declaration is **arc-boundary triggered** (Hermes model), not every-substantive-turn. A job = a goal-arc. The agent declares it when the arc concludes: completed-and-self-verified, definitively failed, or abandoned/cancelled. This is a *primary* agent action (we have no classifier plugin — unlike Hermes, where this directive is only a backstop).
- **D-02:** **Status bar ported verbatim from Hermes** (`references/job-declaration.md`): `SUCCESS` requires positive, self-verified evidence (tests passed / build green / question fully answered — no user sign-off required, but "made the change but couldn't verify" is **not** SUCCESS). `FAILED` is a narrow definitive-negative terminal state. `CANCELLED` is the catch-all and the **uncertainty-bias default** (when in doubt → CANCELLED).
- **D-03:** **Pivot-cancel rule included:** when the user pivots to a new goal before the current arc was declared, the agent first writes a `CANCELLED` job marker for the abandoned arc (prevents attribution leakage into the next job), then begins the new arc. This is agent-driven and needs no session-end hook.
- **D-04:** **Granularity floor is a SOFT guideline only.** Hermes guarantees ≥1 job/session via a session-end plugin we do not have. The directive states the agent should aim for at least one job per session, but does **not** claim hard enforcement. A session with no clear arc completion may legitimately produce zero jobs.
- **D-05:** Directive sits within the guard-first SKILL.md ordering, modeled structurally on the existing `TASK CLASSIFICATION` section (mandatory-action framing, but arc-boundary trigger rather than per-turn).

### Marker-Writer Interface (JOBDEC-03, JOBDEC-04)
- **D-06:** **New dedicated `scripts/write-job-marker.sh`** — does NOT extend `write-marker.sh`. Reuses `common.sh` (`MARKERS_DIR`, sid resolution, flock + `O_APPEND` pattern, env-passing Python heredoc idiom). Rationale: keeps the proven v1.0 task-marker path untouched (zero regression risk) and keeps each writer's validation path simple.
- **D-07:** **Named flags** for field passing: `--job-id`, `--job-name`, `--job-type`, `--status`, and optional `--failure-reason`. Self-documenting, order-independent, each value arrives as a discrete arg the writer sanitizes individually (mirrors how the `revenium jobs` CLI itself takes flags). Not positional, not a single JSON blob.
- **D-08:** **`agentic_job_id` format = Hermes-style kebab-slug + 4-hex** (e.g. `add-pagination-endpoint-3b1e`): a short kebab-case slug of the goal plus a 4-char hex entropy suffix. The **agent mints the full ID** (so it can reference it again within the same turn if needed). The directive is prescriptive about this format.
- **D-09:** **Writer sanitizes every field** before it lands in the marker: `:`, `|`, newline → `_` (JOBDEC-04), and applies a defensive length cap. Sanitization is the safety net regardless of agent-supplied format. (Forward note: these values reach a CLI arg in Phase 6, so sanitization here is the load-bearing defense.)

### Marker Schema & Task Discriminator (JOBDEC-03)
- **D-10:** **`ts` is ISO8601 string** (`time.strftime('%Y-%m-%dT%H:%M:%SZ')`) — identical to the existing task-marker `ts`. Deliberately diverges from Hermes' `unix_float` so there is ONE timestamp convention across both marker kinds in our `markers/` dir (keeps Phase 6 `report.sh` ordering/correlation uniform). We are not sharing Hermes' reader, so matching Hermes buys nothing.
- **D-11:** **Discriminator = `kind:"job"`; absence-of-`kind` means task.** Existing task markers (no `kind` field) and the existing `write-marker.sh` are **left untouched**. Phase 6 `report.sh` branches on `kind == "job"`; any marker without `kind` is treated as a task marker. No retrofit of `kind:"task"` onto the task writer.
- **D-12:** **Job marker field set:** `kind` (= `"job"`), `ts` (ISO8601), `sid` (recorded **in** the marker record, unlike task markers where sid is only the filename), `agentic_job_id`, `job_name`, `job_type`, `status` (`SUCCESS`|`FAILED`|`CANCELLED`). These 7 are mandatory.
- **D-13:** **`failure_reason` included now** — optional, **FAILED-only** (omitted entirely for SUCCESS/CANCELLED; absent key = no-op for readers). Makes the schema forward-complete for Phase 6's `jobs outcome --metadata` so Phase 6 won't need to churn back into the writer or directive. JOBDEC-03's 7 fields remain mandatory; `failure_reason` is the 8th, optional field.

### Validation rules (JOBDEC-03)
- **D-14:** Writer **rejects** records with an unknown `job_type` (validate against `job-taxonomy.json` allowlist, same pattern as `write-marker.sh`'s task-type allowlist check), a missing mandatory field, or an invalid `status` value. Reject = no marker written, non-zero exit, logged — matching `write-marker.sh`'s fail-loud-but-don't-block contract.

### Claude's Discretion
- Exact `job-taxonomy.json` install path constant in `common.sh` (parallel to `TAXONOMY_FILE` → e.g. a `JOB_TAXONOMY_FILE` constant pointing at `${STATE_DIR}/job-taxonomy.json`). Follow the established `task-taxonomy.json` precedent.
- The precise snake_case validation regex and where it lives — match whatever `task-taxonomy.json` is held to (researcher: confirm whether a regex is enforced today or only an allowlist membership check; JOBDEC-01 says "same snake_case regex").
- Length-cap value for sanitized fields and the exact log/error wording.
- Exact placement/anchoring of the JOB DECLARATION section within SKILL.md relative to TASK CLASSIFICATION and the guard sections.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements & roadmap (this repo)
- `.planning/REQUIREMENTS.md` §"Job Declaration (JOBDEC)" — JOBDEC-01..04, the locked requirement text. Authoritative on field list and the 11 labels.
- `.planning/ROADMAP.md` §"Phase 5: Job Declaration Foundation" — goal + 4 success criteria.

### Existing OpenClaw code to extend / mirror (this repo)
- `scripts/write-marker.sh` — the v1.0 task-marker writer. The structural template for `write-job-marker.sh`: env-passing Python heredoc (never interpolate user values), taxonomy allowlist validation, sid resolution (newest non-cron session), `fcntl.flock(LOCK_EX)` + `O_APPEND`, path-traversal sid guard, markers dir mode 0700. **Reuse the idioms; do not modify this file.**
- `scripts/common.sh` — path constants (`MARKERS_DIR`, `TAXONOMY_FILE`, `STATE_DIR`, `SESSIONS_DIR`). Add the new `JOB_TAXONOMY_FILE` constant here.
- `task-taxonomy.json` — shape precedent for `job-taxonomy.json` (`{"labels": {"<label>": {"description","examples"}}}`).
- `SKILL.md` §"TASK CLASSIFICATION" (lines ~63–140) — structural model for the new JOB DECLARATION directive (mandatory-action framing, Step 1 pick label / Step 2 call writer, confirmation/error handling, "why this matters").
- `tests/test_write_marker.sh` — test precedent for the new writer's tests.

### Hermes reference (design source — sibling repo, read-only)
- `../hermes-revenium/skills/revenium/job-taxonomy.json` — **the exact 11 labels to port** (`feature_development`, `bug_fix`, `code_review`, `refactoring`, `research`, `debugging`, `testing`, `documentation`, `devops`, `planning`, `interrupted`) with descriptions/examples.
- `../hermes-revenium/skills/revenium/references/job-declaration.md` — **the arc-boundary model, status bar (SUCCESS/FAILED/CANCELLED criteria), pivot-cancel rule, granularity floor, and worked examples** to port into the SKILL.md directive (D-01..D-05).
- `../hermes-revenium/skills/revenium/SKILL.md` §"FINAL ACTION — JOB DECLARATION" — the marker-shape reference (note: Hermes uses `unix_float` ts and treats this as a backstop; **we diverge** — ISO8601 ts (D-10), primary action (D-01)).

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/common.sh`: `MARKERS_DIR`, `TAXONOMY_FILE`, `SESSIONS_DIR`, `STATE_DIR`, `log/info/warn/error`, sid-resolution-by-newest-non-cron-session logic (in `write-marker.sh`). The new writer should source `common.sh` and add a sibling `JOB_TAXONOMY_FILE` constant.
- `scripts/write-marker.sh`: a near-complete blueprint — copy its security idioms (env-passing heredoc, allowlist validation, flock+O_APPEND, sid traversal guard, 0700 markers dir). The job writer differs by: more fields (named flags), `kind:"job"` + in-record `sid`, optional `failure_reason`, and sanitization of `:`/`|`/newline.

### Established Patterns
- **Agent-driven markers, not native hooks / classifier plugin** (PROJECT.md decision, carried into v1.1) — job declaration is an agent action via a writer script, exactly like task classification.
- **Fail-loud-but-don't-block** marker writes: unknown label → non-zero exit + log, no marker; the SKILL.md directive tells the agent to log the error but not block its response.
- **Guard-first SKILL.md ordering** (Phase 1 decision) — the JOB DECLARATION directive must not displace the guardrail-check primacy at the top of SKILL.md.
- **Markers correlate to completions in Phase 6** by `completion_id` + marker-after fallback (Phase 4 decision). The same correlation concern applies to job markers; relevant to Phase 6, not Phase 5, but the schema choice (ISO8601 ts) keeps it uniform.

### Integration Points
- `job-taxonomy.json` installs to the skill runtime location alongside `task-taxonomy.json` (confirm the install/copy mechanism the skill uses — researcher).
- The new writer writes into the same `markers/{sid}.jsonl` files as `write-marker.sh`; Phase 6 `report.sh` will read both kinds from those files and split on `kind`.

</code_context>

<specifics>
## Specific Ideas

- `agentic_job_id` example to anchor the directive: `add-pagination-endpoint-3b1e` (kebab goal-slug + 4-hex).
- The agent-facing directive should read structurally like the existing TASK CLASSIFICATION section so an OpenClaw agent encounters a familiar "pick a label, call a script" shape — lowers the chance of malformed markers.
- Port Hermes' worked examples (SUCCESS vs CANCELLED-because-unverified, FAILED-definitive, pivot-cancel) into the OpenClaw directive / a `references/job-declaration.md`, adapted to our writer command.

</specifics>

<deferred>
## Deferred Ideas

- **Per-job-type budget rules / guardrails** — out of scope for v1.1 entirely (observability-only milestone; see PROJECT.md Out of Scope, future req JGUARD-01).
- **Classifier-plugin job inference** (`on_session_end`) — future milestone, gated on confirming OpenClaw session-end hooks (future req JCLASS-01).
- **Business-outcome reporting** beyond execution result (`--outcome-type CONVERTED`, ROI) — future req JOUT-01.
- **Hard session-end enforcement of the one-job-per-session floor** — impossible without a session-end hook; intentionally left soft (D-04).

None of the above are Phase 5 work — discussion stayed within the declaration-foundation boundary.

</deferred>

---

*Phase: 5-Job Declaration Foundation*
*Context gathered: 2026-06-03*
