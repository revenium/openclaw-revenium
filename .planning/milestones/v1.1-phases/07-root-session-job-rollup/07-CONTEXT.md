# Phase 7: Root-Session Job Rollup - Context

**Gathered:** 2026-06-03
**Status:** Ready for planning

<domain>
## Phase Boundary

One agentic job spans the **entire agent tree**. When `report.sh` meters a **subagent** session's completions, those completions ship the **ROOT** session's `agentic_job_id` (override), and the subagent's own job markers never become separate Revenium jobs. Extends the v1.0 root-session resolver (`get-root-session-id.py`, Phase 4 D-07 `--agent` rollup) into the job dimension.

**In scope (JROLL-01..03):**
- **JROLL-01:** Subagent completions ship the root session's `agentic_job_id` (override), so one job spans the whole tree.
- **JROLL-02:** When the root job id can't yet be resolved (marker race), the completion omits `--agentic-job-id` rather than shipping a wrong/sub-session id; spend still rolls up via the existing `--agent` attribution.
- **JROLL-03:** Top-level (root) sessions ship their own declared job; a subagent's internally-declared job markers are NOT shipped as separate jobs (no `jobs create`, no `jobs outcome`).

**Explicitly NOT in this phase (later phases / deferred):**
- **Halt → CANCELLED** interrupted-job record on guardrail halt — **Phase 8 (JHALT)**.
- **Per-completion full-arc backfill** — rejected in Phase 6 (D-02); not reopened here.
- **Business-outcome reporting** (`--outcome-type`, ROI) — deferred (JOUT-01).
- **Per-job-type budget rules** — deferred (JGUARD-01); observability-only milestone.

**The Phase 6 single-session lifecycle (create → stamp same-tick completion → outcome, ledger-gated, fail-open behind `JOBS_CLI_CAPABLE`) is the baseline this phase modifies — it must stay byte-identical for root sessions and never regress task-type metering.**

</domain>

<decisions>
## Implementation Decisions

### Subagent detection & rollup (JROLL-01)
- **D-01: Subagent discriminator = `root_sid != session_id`.** `report.sh` already resolves `root_sid` once per session (line ~329, via `get_root_session_id`). A session is a subagent when its resolved root differs from itself; a top-level session has `root_sid == session_id`. This is the same discriminator Hermes uses for job rollup (`hermes-report.sh:214, 347, 863`) and the same one v1.0 already uses for `--agent` trace rollup.
- **D-02: Subagent completions inherit the ROOT's `agentic_job_id` (override).** When `root_sid != session_id`, every metered completion in that subagent session this tick ships `--agentic-job-id <root_aid>` (plus the root's `--agentic-job-name`/`--agentic-job-type`). This diverges from Phase 6's per-session correlation: a subagent session has no matching job marker of its own, so the override applies to the subagent's completions wholesale (all belong to the root job), NOT via `completion_id` exact-match. Mirrors Hermes' `root_aid` → `m_owning_job_id` inheritance.

### Marker-race policy (JROLL-02)
- **D-03: Ship now, job-less (best-effort) — do NOT defer completions.** When a subagent completion is metered but the root job is not yet resolvable (root arc still in progress, no `kind:"job"` marker in the root's markers file yet), ship the completion **immediately without `--agentic-job-id`**. The completion's spend still rolls up to the root server-side via the existing `--agent "openclaw-<root_sid>"` attribution (Phase 4 D-07). **Rationale:** consistent with Phase 6 D-01/D-02 (do not fight the `TX:` ledger / offset model — no holding, no backfill, no re-metering); matches Hermes' "omit the flag rather than stub or ship the subagent's own orphan id" comment (`hermes-report.sh:204-212`). The "retry next tick" of JROLL-02 is satisfied by idempotent re-resolution for completions still in the unshipped window on a later tick — never by wedging/holding the offset.
- **D-04: Never ship a wrong or sub-session id.** If `root_aid` is empty, the safe action is omission, never substituting the subagent's own (orphan) `agentic_job_id`. This is the load-bearing safety invariant of JROLL-02.

### Which root job a subagent inherits (multi-job roots)
- **D-05: Latest root job marker wins.** When the root session declared multiple jobs over its life, the subagent inherits the **most recently declared** `agentic_job_id` in the root's markers file (last `kind:"job"` line in file order), regardless of timestamp-vs-completion alignment. Ports Hermes' `latest_aid` exactly (`hermes-report.sh:226-247`). Accepted tradeoff: if the root opened a *new* job after the subagent already finished, the subagent's later-shipped completions may attribute to that newer job — acceptable for an observability-only milestone and far simpler than timestamp-active arc matching (which the arc-close marker stream can't cleanly support anyway).

### Subagent job-marker suppression (JROLL-03)
- **D-06: Root-only `jobs create` / `jobs outcome`.** Gate BOTH the `jobs create` and `jobs outcome` stages on `root_sid == session_id`. A subagent session (`root_sid != session_id`) skips both entirely — its own `kind:"job"` markers are never turned into Revenium jobs. The root session's loop remains the single create/outcome path per arc (the Phase 6 lifecycle, unchanged for roots). Mirrors Hermes `hermes-report.sh:347, 863`.
- **D-07: Orphan subagent job → ship job-less (drop the orphan).** If a subagent declared its own job but its root never declared one (`root_aid` empty), the subagent's completions ship with NO `--agentic-job-id` — the subagent's own job id is dropped, not shipped. Spend still rolls up via `--agent`. Same invariant as D-04: never ship a sub-session job id as if it were a real job. Hermes' behavior.

### Root-job lookup source
- **D-08: Resolve `root_aid` from the root's live markers file `markers/{root_sid}.jsonl`** (not the jobs ledger). Reads the latest `kind:"job"` marker's `agentic_job_id` (+ `job_name`, `job_type` for the inherited `--agentic-job-name`/`-type`). Sees the job as soon as the agent declares it (before/independent of `jobs create` running), and carries the name/type the stamping needs. This is a **new cross-session read** in Phase 7 — Phase 6's job cache is per-session-only. Apply the same sanitization the marker reader already uses (`:`/`|`/newline → `_`). Ports Hermes' `root_aid` resolver (`hermes-report.sh:213-254`).
- **D-09: Resolve `root_aid` ONCE per subagent session**, cached for that session's whole completion loop (not re-read per completion). Only performed when `root_sid != session_id` (top-level sessions skip it entirely and take the unchanged Phase 6 path). Matches Hermes' once-per-session resolution.

### Claude's Discretion
- Exact placement of the `root_aid` resolution block in `process_session` (parallel to the existing `root_sid` resolution at ~line 329) and how its values thread into `post_to_revenium`'s arg list (the `--agentic-job-*` block at ~lines 298-301 already exists from Phase 6 — Phase 7 feeds it the root's values for subagents instead of the same-session marker's values).
- Whether to reuse/extend the existing markers-cache Python read or add a small sibling read for the cross-session `root_aid` lookup (Hermes uses a dedicated inline heredoc — the env-passing-heredoc discipline T-04-09 applies: pass `ROOT_SID`/`MARKERS_DIR` via env, never interpolate).
- Whether the root-only gate (D-06) is implemented as an early `if [[ "${root_sid}" == "${sid}" ]]` wrapper around the existing create/outcome blocks, or an inline guard at each stage. Either preserves the Phase 6 root path byte-for-byte.
- Log/warn wording for the omit-on-race path (D-03) and the orphan-drop path (D-07); whether to `info`-log subagent rollup correlations (parallel to the existing `Job correlation:` log at ~line 688).
- Test strategy: extend `tests/stub-revenium.sh` + the report.sh job tests to cover (a) subagent completion inherits root_aid, (b) race → omit `--agentic-job-id`, (c) subagent job marker does NOT trigger create/outcome, (d) orphan subagent (no root job) ships job-less. A fixture with a `sessions_spawn` parent→child JSONL link is needed to exercise `get_root_session_id`.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements & roadmap (this repo)
- `.planning/REQUIREMENTS.md` §"Root-Session Job Rollup (JROLL)" — JROLL-01..03, the locked requirement text (authoritative on override/omit/suppression semantics).
- `.planning/ROADMAP.md` — Phase 7 line (goal: "subagent completions roll up under the root session's job so one job spans the whole agent tree").
- `.planning/phases/06-job-lifecycle-wiring/06-CONTEXT.md` — the single-session lifecycle (create/stamp/outcome, ledger, `JOBS_CLI_CAPABLE`, fail-open) this phase extends. **Do not regress the root path.**
- `.planning/phases/05-job-declaration-foundation/05-CONTEXT.md` — job marker schema (`kind:"job"`, `agentic_job_id`, `job_name`, `job_type`, `status`, in-record `sid`) Phase 7 reads from the root's markers file.

### Existing OpenClaw code to extend (this repo)
- `scripts/report.sh` — **the file Phase 7 modifies.** Key landmarks: `get_root_session_id()` wrapper (~line 50) and the per-session `root_sid` resolution (~lines 328-330) — the discriminator for D-01; `post_to_revenium()` `--agentic-job-*` append block (~lines 298-301, from Phase 6) — feed it the root's values for subagents; the in-loop `jobs create` (~lines 699-724) and `jobs outcome` (~lines 864-902) stages — gate root-only per D-06; the markers-cache Python read in `process_session` (~lines 351-381) — sibling/extension point for the cross-session `root_aid` read.
- `scripts/get-root-session-id.py` — the resolver (reverse `childSessionKey` walk, `max_depth=10`, fail-open to input sid). Phase 7 relies on it being correct for subagent→root mapping; no change expected, but tests must build a `sessions_spawn`-linked fixture.
- `scripts/common.sh` — `MARKERS_DIR`, `SESSIONS_DIR`, `OPENCLAW_HOME`, `log/info/warn/error`. `MARKERS_DIR` is the dir for the new `markers/{root_sid}.jsonl` cross-session read.
- `tests/stub-revenium.sh`, `tests/test_report_argv.sh` (+ the Phase 6 job-lifecycle test) — extend for the four Phase 7 cases above.

### Hermes reference (design source — sibling repo `../hermes-revenium`, read-only) — PORT TARGET FOR THIS PHASE
- `../hermes-revenium/skills/revenium/scripts/hermes-report.sh`:
  - lines ~204-254: **`root_aid` resolution** — once-per-session, only when `root_sid != sid`, reads root's markers file, latest `kind:"job"` `agentic_job_id` wins, sanitizes `:`/`|`/newline, empty-on-race → omit (→ D-02, D-03, D-05, D-08, D-09).
  - lines ~343-347 and ~862-863: **root-only create/outcome gate** (`if [[ "${root_sid}" == "${sid}" ]]`) — subagent sessions skip both (→ D-06).
  - **Caveat:** Hermes ships `--owning-job-id` on a Hermes-specific marker field and uses `unix_float` ts + a SQLite resolver; OpenClaw uses `--agentic-job-id` on the v1.0 `meter completion` path, ISO8601 ts, and the JSONL `childSessionKey` resolver. Port the *logic/structure*, not the literals. OpenClaw also has NO `--outcome-type CONVERTED` (Phase 6 D-07).

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`get_root_session_id()` + per-session `root_sid`** (report.sh ~50, ~328-330) — already resolved every tick for `--agent` rollup; D-01's subagent discriminator and D-08's root markers path both key off it for free.
- **`post_to_revenium()` `--agentic-job-*` block** (report.sh ~298-301, Phase 6) — the stamping chokepoint already exists and is conditional on `JOBS_CLI_CAPABLE` + non-empty id. Phase 7 only changes WHICH values feed it for subagents (root's, not same-session).
- **The markers-cache Python read** (report.sh ~351-381) — env-passing heredoc precedent for the new cross-session `root_aid` read of `markers/{root_sid}.jsonl`.
- **`JOBS_CLI_CAPABLE` probe + fail-open discipline** (Phase 6 D-11/D-12) — unchanged; all Phase 7 job work stays behind it, metering ships byte-identical to v1.0 when the CLI can't do jobs.

### Established Patterns
- **`root_sid != session_id` = subagent** — already the v1.0 trace-rollup discriminator; Phase 7 reuses it verbatim for job rollup (no new detection mechanism).
- **Best-effort + server-side `--agent` rollup** (Phase 4 D-07, Phase 6 D-01/D-02) — the spine of the race policy (D-03): omit the explicit id, let `--agent` carry spend. No backfill, no offset-fighting.
- **Ledger-gated idempotency + 409-as-success** (Phase 6) — create/outcome stay idempotent and root-only; Phase 7 adds no new ledger keys.
- **Env-passing Python heredoc discipline (T-04-09)** — the new cross-session read passes `ROOT_SID`/`MARKERS_DIR` via env, never string-interpolated.
- **Offset advance gated on completion-post success only (CR-02)** — unchanged; the `root_aid` lookup and any job omission must never touch the `TX:` offset gate.

### Integration Points
- New cross-session read: `markers/{root_sid}.jsonl` resolved while processing a subagent session (D-08) — first time Phase pipeline reads another session's markers (Phase 6 was strictly same-session).
- `root_aid` (+ name/type) flows: root markers read → cached per subagent session → into `post_to_revenium`'s existing `--agentic-job-*` arg slots.
- Root-only gate wraps the existing Phase 6 `jobs create` / `jobs outcome` stages — subagent sessions short-circuit past them.

</code_context>

<specifics>
## Specific Ideas

- Worked timeline (anchors D-03/D-05): root session R is mid-arc, no job marker yet; subagent S (child of R) ships completion `tx1` on tick N → `root_aid` empty → `tx1` ships with NO `--agentic-job-id` (spend rolls up via `--agent "openclaw-R"`). On tick N+2 R declares job `add-auth-9f3c` (marker in `markers/R.jsonl`); S ships `tx2` → `root_aid=add-auth-9f3c` resolves → `tx2` ships `--agentic-job-id add-auth-9f3c --agentic-job-name ... --agentic-job-type ...`. S's own `jobs create`/`outcome` never fire (root-only gate). R's loop creates+closes `add-auth-9f3c` once.
- "Latest wins" example (D-05): if `markers/R.jsonl` contains job `a-1111` then later job `b-2222`, a subagent completion resolves `root_aid=b-2222` (last line wins) regardless of which arc was active when the completion happened.

</specifics>

<deferred>
## Deferred Ideas

- **Timestamp-active root-job matching** — picking the root job whose arc temporally contains the subagent completion (vs. latest-wins). Considered and rejected for Phase 7 (D-05): arc-close markers land after the arc, so the marker stream can't cleanly express "active at time T"; latest-wins is the Hermes-proven simplification. Revisit only if multi-job-root misattribution proves material.
- **Holding/deferring subagent completions until the root job resolves** — the literal "retry rather than ship" reading of JROLL-02. Rejected (D-03) as it fights the Phase 6/CR-02 `TX:` offset model and risks wedging completions when a root never declares a job. Server-side `--agent` rollup covers the gap.
- **Halt → CANCELLED interrupted-job record** — **Phase 8 (JHALT)**.
- **Per-completion full-arc backfill / restamp** — rejected in Phase 6 (D-02); not reopened.
- **`--outcome-type CONVERTED` / business-outcome metrics** — JOUT-01, future milestone.
- **Per-job-type budget rules** — JGUARD-01, future milestone (observability-only this milestone).

</deferred>

---

*Phase: 7-Root-Session Job Rollup*
*Context gathered: 2026-06-03*
