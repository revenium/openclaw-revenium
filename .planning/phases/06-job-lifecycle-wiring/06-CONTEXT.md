# Phase 6: Job Lifecycle Wiring - Context

**Gathered:** 2026-06-03
**Status:** Ready for planning

<domain>
## Phase Boundary

`report.sh` runs each agent-declared job through the **full Revenium lifecycle**, driven idempotently by a jobs ledger and fail-open so existing metering/guardrails never break:

1. **`jobs create`** — a declared job is opened in Revenium exactly once, even across cron ticks (JLIFE-01).
2. **`--agentic-job-*` stamping** — completions belonging to a job ship `--agentic-job-id`, `--agentic-job-name`, `--agentic-job-type` on `meter completion` (JLIFE-02).
3. **`jobs outcome`** — the job is closed exactly once with `--result SUCCESS|FAILED|CANCELLED`, read from the marker's `status` (JLIFE-03).
4. **Fail-open** — any `jobs` CLI error / absent subcommand is caught and logged; task-type metering and guardrail checks continue (JLIFE-04).
5. **Jobs ledger** — created/closed job IDs persist so re-runs never re-issue `create` or `outcome` (JLIFE-05).

**In scope (JLIFE-01..05):** wiring the lifecycle into `report.sh` reading `kind:"job"` markers from `markers/{sid}.jsonl`; the jobs ledger; the CLI-capability probe; fail-open discipline.

**Explicitly NOT in this phase (later phases):**
- **Root-session job rollup** / subagent → root `agentic_job_id` override — **Phase 7 (JROLL)**. Phase 6 is single-session: a session's completions correlate only to job markers in that same session file.
- **Halt → CANCELLED** interrupted-job record on guardrail halt — **Phase 8 (JHALT)**.
- **Business-outcome reporting** (`--outcome-type`, ROI) — deferred (JOUT-01).
- **Per-job-type budget rules** — deferred (JGUARD-01); observability-only milestone.

</domain>

<decisions>
## Implementation Decisions

### Completion → Job Attribution (JLIFE-02)
- **D-01: Best-effort stamping + server-side rollup.** Job markers are written at **arc close** (Phase 5 D-01), but completions are metered and `TX:`-ledgered every cron tick *while the arc is still in progress*. By the time the closing marker appears, most of the arc's completions are already shipped and cannot be re-stamped. Phase 6 therefore stamps `--agentic-job-id/-name/-type` **only on completions still unshipped when the closing marker is seen** (typically the arc's final tick, matched via the marker's `completion_id` exact-match, with timestamp fallback — the same correlation mechanism as task-type). The remainder of the arc's spend is still attributed to the job **server-side** via the existing `--agent "openclaw-<root_sid>"` rollup (Phase 4 D-07).
- **D-02: Do NOT fight the `TX:` ledger / offset model.** No backfill, no re-metering of already-shipped completions to retro-stamp them. The completion ledger and offset arithmetic in `report.sh` stay untouched; the partial per-completion stamping is accepted as inherent to arc-close markers. The job itself is still fully tracked (create + terminal outcome), which is the primary deliverable.
- **D-03: A job marker with no stampable same-tick completion still fires create + outcome.** If the marker's `completion_id` points to a completion shipped on a prior tick, zero completions in the current tick get the job id — that is expected; the job is still created and closed, and its spend rolls up via `--agent`.

### Jobs Create (JLIFE-01)
- **D-04: Omit `--environment`.** OpenClaw has no Hermes-style session "source"/deployment-environment column to populate it. The flag is named in JLIFE-01 but populating it is optional — omit it entirely and let the Revenium default apply (mirrors how Hermes omits it when its source column is empty). `jobs create` ships `--agentic-job-id --name --type --quiet` only.
- **D-05: `--name` ← marker `job_name`, `--type` ← marker `job_type`** (already taxonomy-validated by `write-job-marker.sh` at write time).
- **D-06: Idempotency = ledger-gated + 409-as-success.** Skip `create` if the jobs ledger already has `JOB:<id>:created:`. Treat CLI exit 0 **and** HTTP-409/"already exists"/"conflict" in output as success-equivalent before writing the ledger row (ports Hermes' idempotency pattern — the create row guards against re-issue across ticks).

### Jobs Outcome (JLIFE-03)
- **D-07: Execution-result-only.** Send `jobs outcome <id> --result SUCCESS|FAILED|CANCELLED` (read from the marker's `status`). **Never** send `--outcome-type` — business-outcome reporting (`--outcome-type CONVERTED`, ROI) is explicitly deferred to JOUT-01 / a future milestone, so Phase 6 deliberately diverges from Hermes' SUCCESS→CONVERTED mapping. This keeps Phase 6 inside the "observability-only" boundary.
- **D-08: `failure_reason` rides via `--metadata`** (FAILED only). The Phase 5 marker schema already carries an optional `failure_reason` (FAILED-only). When present, attach it as `--metadata '{"failure_reason":"..."}'` (json.dumps for safe quoting). Omit `--metadata` entirely otherwise.
- **D-09: Outcome is gated on create being confirmed.** Skip outcome if `JOB:<id>:created:` is not yet in the ledger (re-attempt next tick); skip + idempotent if `JOB:<id>:outcome:` already present. Same 409-as-success rule as create. Within a single tick the natural order is **create → (stamp same-tick completion) → outcome** so the job exists server-side before it is closed.

### Jobs Ledger (JLIFE-05)
- **D-10: Separate ledger file `revenium-jobs.ledger`** (sibling to `revenium-reported.ledger` under `OPENCLAW_HOME`). Keeps the hot-path `TX:` completion-dedup ledger single-purpose and untouched. Row format ports Hermes verbatim:
  - `JOB:<agentic_job_id>:created:<unix_ts>`
  - `JOB:<agentic_job_id>:outcome:<unix_ts>:<STATUS>`
  - `grep -q "^JOB:<id>:created:"` / `"^JOB:<id>:outcome:"` are the idempotency gates. `touch` the file at startup like the existing ledger.

### Fail-Open (JLIFE-04)
- **D-11: One-time CLI capability probe per tick** (`JOBS_CLI_CAPABLE`). Port Hermes' D-05 probe: at startup run `revenium jobs --help` AND `revenium meter completion --help | grep -- '--agentic-job-id'`; both must pass. If either fails, log once and skip **all** job work — metering ships byte-identical to v1.0 (no `--agentic-job-*` flags appended). Cache the boolean for the whole tick.
- **D-12: All job CLI calls are best-effort, never abort.** Capture output + exit code, `warn` on failure, never `exit`/`return` out of the session loop or block a `meter completion` call. A `jobs` failure must not advance/block the `TX:` offset logic (that gate stays driven solely by completion-post success, per existing CR-02).

### Claude's Discretion
- Exact placement of the job-marker read + per-completion job resolution inside `process_session` (parallel to the existing two-phase task_type lookup in the markers-cache block). Researcher/planner: decide whether to extend the existing single markers-cache Python read to also emit job rows, or add a sibling read.
- Whether `jobs create` fires in-loop when the closing marker is encountered vs. a pre-scan pass (Hermes does both; OpenClaw's single-session, arc-close model likely needs only the in-loop path).
- Exact `--agentic-job-name`/`--agentic-job-type` plumbing through `post_to_revenium` (new params appended to the existing positional arg list, conditionally added to the `cmd` array only when non-empty and `JOBS_CLI_CAPABLE`).
- Log/warn wording, `unix_ts` precision (Hermes uses `%.3f`), and the stale-job warn threshold (Hermes `REVENIUM_JOBS_STALE_SECONDS=600`) — adopt or simplify.
- Test strategy: extend `tests/stub-revenium.sh` to fake `jobs create`/`jobs outcome` and add a `report.sh` job-lifecycle test alongside `tests/test_report_argv.sh`.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements & roadmap (this repo)
- `.planning/REQUIREMENTS.md` §"Job Lifecycle (JLIFE)" — JLIFE-01..05, the locked requirement text (authoritative on CLI flag names and idempotency).
- `.planning/ROADMAP.md` §"Phase 6: Job Lifecycle Wiring" — goal + 5 success criteria.
- `.planning/phases/05-job-declaration-foundation/05-CONTEXT.md` — the marker schema, `completion_id` correlation, and arc-close trigger this phase consumes.

### Existing OpenClaw code to extend (this repo)
- `scripts/report.sh` — **the file Phase 6 modifies.** Key landmarks: `post_to_revenium()` (build the `meter completion` cmd array — add `--agentic-job-*` here); `process_session()` markers-cache Python block (~lines 332–360, currently filters `ts && task_type` — must also collect `kind:"job"` markers); the two-phase task_type lookup (~lines 487–552, the correlation pattern to mirror); the `LEDGER_FILE`/offset model (do NOT disturb — CR-02 fail-on-error offset gate at ~693).
- `scripts/write-job-marker.sh` — the writer Phase 6 reads downstream. Marker fields: `kind:"job"`, `ts` (ISO8601), `sid`, `agentic_job_id`, `job_name`, `job_type`, `status`, optional `failure_reason`, optional `completion_id`.
- `scripts/common.sh` — `MARKERS_DIR`, `JOB_TAXONOMY_FILE`, `STATE_DIR`, `OPENCLAW_HOME`, `log/info/warn/error`. (Note: `report.sh` defines its own `LEDGER_FILE`/paths at top, not via `common.sh` — the new `revenium-jobs.ledger` path goes there.)
- `tests/stub-revenium.sh`, `tests/test_report_argv.sh`, `tests/test_write_job_marker.sh` — test precedents to extend for the jobs lifecycle.

### Hermes reference (design source — sibling repo `../hermes-revenium`, read-only)
- `../hermes-revenium/skills/revenium/scripts/hermes-report.sh` — **the proven lifecycle implementation to port (adapted, not copied):**
  - lines ~37–49: `JOBS_CLI_CAPABLE` dual-probe + fail-open warn (→ D-11).
  - lines ~878–920: `jobs create` cmd array, 409-as-success, `JOB:<id>:created:<ts>` ledger write (→ D-04, D-06, D-10).
  - lines ~1167–1275: `jobs outcome` stage — ledger-gated, create-confirmed gate, enum validation, `--result`, `--metadata`, `JOB:<id>:outcome:<ts>:<status>` (→ D-07, D-08, D-09). **Note OpenClaw diverges: NO `--outcome-type CONVERTED`** (D-07).
  - **Caveat:** Hermes' `owning_job_id` deferred-resolution machinery (root rollup) is **Phase 7**, not Phase 6 — do not port it here. Hermes splits create (arc-open) from outcome (arc-close); OpenClaw fires both from one arc-close marker (D-09).

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`report.sh` `post_to_revenium()`** — the single chokepoint for the `meter completion` cmd array. The three `--agentic-job-*` flags get appended here, conditionally, exactly like the existing `--trace-id`/`--organization-name`/`--is-streamed` optional-flag blocks.
- **The markers-cache Python read in `process_session()`** — already reads `markers/{sid}.jsonl` once per session, sorts by `ts`, and emits `ts\ttask_type\tcompletion_id`. Job markers live in the **same files**; extend this read to also surface `kind:"job"` rows (they have no `task_type`, so the current filter drops them today).
- **The two-phase (exact `completion_id` → timestamp fallback) task_type lookup** — the exact correlation pattern to reuse for matching the closing job marker to its same-tick completion.
- **`tests/stub-revenium.sh`** — already stubs the `revenium` CLI for argv assertions; extend to fake `jobs create` / `jobs outcome` (including a 409 path).

### Established Patterns
- **Fail-loud-but-don't-block** (Phase 4/5) — job-CLI errors `warn` and continue; never block metering or guardrails (JLIFE-04 / D-12).
- **Ledger-gated idempotency** — `report.sh` already uses `grep -q "^TX:<id>$"` for completion dedup; the jobs ledger uses the same idiom with `JOB:<id>:created`/`:outcome` keys.
- **409-as-success** — Hermes treats HTTP 409 / "already exists" as success-equivalent for both create and outcome, the load-bearing idempotency net beyond the local ledger (covers a ledger-write crash between API call and ledger append).
- **Offset advance gated on completion-post success only** (CR-02) — job-CLI outcomes must stay **out** of that gate so a `jobs` failure never re-meters or wedges completions.
- **Env-passing Python heredoc discipline (T-04-09)** — any new inline Python (marker parse, metadata json) passes untrusted values via env, never string-interpolated.

### Integration Points
- New `LEDGER_FILE`-sibling path `revenium-jobs.ledger` declared in `report.sh`'s config block (alongside `LEDGER_FILE`, `OFFSETS_FILE`), `touch`ed at startup after the existing guards.
- The `--agentic-job-*` values flow from the closing job marker (read in `process_session`) → through `post_to_revenium`'s arg list → into the `cmd` array, only when `JOBS_CLI_CAPABLE=true` and the values are non-empty.
- `jobs create` + `jobs outcome` invocations sit inside `process_session` (single-session scope); the jobs ledger is the cross-tick memory.

</code_context>

<specifics>
## Specific Ideas

- Worked timeline anchoring the best-effort model (user-confirmed): `meter completion (TX:abc)` ships on tick N with no job id; on tick N+1 a second completion `def` ships *and* the closing job marker (`completion_id=def`) appears → `def` is stamped with `--agentic-job-id`, the job is `create`d then `outcome`d; `abc` is attributed to the job only via `--agent` server-side rollup. Both completions count toward the job's spend in Revenium; only `def` carries the explicit id.
- Ledger row shapes to implement verbatim: `JOB:add-pagination-3b1e:created:1717430400.123` and `JOB:add-pagination-3b1e:outcome:1717430460.456:SUCCESS`.
- `jobs create` wire shape: `revenium jobs create --agentic-job-id X --name "..." --type "..." --quiet` (no `--environment`).
- `jobs outcome` wire shapes: `--result SUCCESS --quiet`; `--result FAILED --quiet --metadata '{"failure_reason":"..."}'`; `--result CANCELLED --quiet`.

</specifics>

<deferred>
## Deferred Ideas

- **Full-arc per-completion stamping / backfill** — capturing `--agentic-job-id` on *every* completion of an arc (not just same-tick ones) would require defeating the `TX:` ledger dedup or a server-side restamp/update path. Considered and explicitly rejected for Phase 6 (D-02); revisit only if server-side `--agent` rollup proves insufficient.
- **Root-session job rollup** (subagent completions ship the root's `agentic_job_id`) — **Phase 7 (JROLL)**; do not implement the Hermes `owning_job_id` resolution here.
- **Halt → CANCELLED interrupted-job record** — **Phase 8 (JHALT)**.
- **`--outcome-type CONVERTED` / business-outcome metrics** — JOUT-01, future milestone.
- **Per-job-type budget rules** — JGUARD-01, future milestone (observability-only this milestone).

</deferred>

---

*Phase: 6-Job Lifecycle Wiring*
*Context gathered: 2026-06-03*
