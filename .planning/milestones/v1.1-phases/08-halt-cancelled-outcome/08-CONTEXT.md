# Phase 8: Halt → CANCELLED Outcome - Context

**Gathered:** 2026-06-03
**Status:** Ready for planning

<domain>
## Phase Boundary

When a guardrail halt interrupts the autonomous agent **mid-job**, the job lifecycle still reaches a terminal state: every open job is closed `CANCELLED`, and — when no job was declared at all — a synthetic `interrupted` job record is produced so the halt still yields a terminal job record. Wired into the **existing** halt + jobs-lifecycle flow.

**In scope (JHALT-01..02):**
- **JHALT-01:** When a guardrail halt interrupts an in-progress job, that job is closed with outcome `CANCELLED`, wired into the existing halt flow.
- **JHALT-02:** An interrupted job is recorded with `job_type:"interrupted"` and a synthetic `agentic_job_id` (`guardrail-halt-<hex>`) so halted work still produces a terminal job record.

**Architectural anchor:** This phase adds the **first bridge between halt-state and the jobs lifecycle**. Today neither cron script bridges the two — `report.sh` never reads `guardrail-status.json`, and `guardrail-check.sh` is account-scoped with no session/jobs awareness. **Hermes has NO JHALT equivalent** — there is no port to copy; these are original decisions grounded in OpenClaw's Phase 6/7 architecture.

**The Phase 6 single-session lifecycle (ledger-gated create/stamp/outcome, 409-as-success, fail-open behind `JOBS_CLI_CAPABLE`) and the Phase 7 root-only gate (only root sessions write `JOB:*` ledger lines) are the invariants this phase builds on — they must not regress, and the per-session metering loop must stay byte-identical.**

**Explicitly NOT in this phase (deferred / future milestones):**
- **Per-job-type budget rules** — JGUARD-01, deferred (observability-only milestone).
- **Business-outcome reporting** (`--outcome-type CONVERTED`, ROI) — JOUT-01, future milestone.
- **Classifier-plugin job inference** (`on_session_end`) — JCLASS-01, future milestone.
- Changing how/when the halt itself is detected or notified — the `guardrail-check.sh` halt-transition + notification path stays as-is (Phase 3 / v1.0).

</domain>

<decisions>
## Implementation Decisions

### Wiring point & single writer (JHALT-01/02)
- **D-01: `report.sh` is the single jobs writer; `guardrail-check.sh` stays jobs-blind.** `guardrail-check.sh` continues to do ONLY what it does today — detect the false→true `HALT_TRANSITION` and write `halted`/`haltedAt`/`haltedRule` to `guardrail-status.json`. It is NOT extended to call `revenium jobs *`. `report.sh` gains a new step that reads `guardrail-status.json` each tick and drives the CANCELLED-close + interrupted-record through its **existing** ledger-gated / fail-open jobs path. Rationale: preserves Phase 6's single-writer + idempotency invariants, avoids forking the lifecycle into a second script, keeps the halt-notification path fully decoupled. Cost: ~1 cron-tick latency between halt and Revenium close (acceptable — cron runs every minute regardless of the agent halt).
- **D-02: Halt handler runs ONCE per tick, after the per-session loop.** The handler is an account-level step that runs after `report.sh`'s normal per-session create/stamp/outcome loop completes. The per-session loop stays byte-identical to Phase 6/7. The handler resolves "open jobs" once from the ledger (no per-session duplication).
- **D-03: Exactly-once across ticks via a `JOB:halt:<haltedAt>` ledger key.** `haltedAt` is stamped once at the false→true transition and preserved (across all subsequent halted ticks) until `clear-halt.sh`. The handler greps the jobs ledger for `JOB:halt:<haltedAt>`; on miss it processes the halt and appends that line; on hit (every later halted tick) it skips. After `clear-halt` + a *new* halt, a new `haltedAt` yields a new key → processed again. Reuses the existing ledger-gate idiom exactly.

### What a halt produces (JHALT-01 vs JHALT-02 shape)
- **D-04: Open declared job → close its OWN id `CANCELLED` (JHALT-01).** When a real declared job is open (in the ledger as `created` without `outcome`), close it via `revenium jobs outcome <real_id> --result CANCELLED` and ledger `JOB:<real_id>:outcome:<ts>:CANCELLED`. Identity is preserved — the dashboard shows the actual job the halt killed, not an anonymous record.
- **D-05: Synthetic `interrupted` job ONLY as fallback (JHALT-02).** When NO job is open at halt time, mint a synthetic `guardrail-halt-<hex>` job with `job_type:"interrupted"`, create it, then close it `CANCELLED` — so the halt still yields a terminal record even for undeclared work. **Exactly one terminal record per halt either way:** real-job-close (D-04) OR synthetic fallback (D-05), never both. (When ≥1 real job was open, no synthetic record is minted — see D-08.)

### "In-progress job" resolution (source of truth)
- **D-06: Source of truth = the jobs ledger.** An open job = the `JOB:<id>:created:<ts>` line(s) with no matching `JOB:<id>:outcome:` line. This is already `report.sh`'s own definition of an open job and is idempotency-correct. Do NOT read markers for this (markers can lead the ledger — "declared but not yet created" — and would re-introduce a race the ledger gate already closes).
- **D-07: No session resolution needed.** Per Phase 7 D-06, only root sessions ever write `JOB:*:created` lines, so every id in the jobs ledger is already root-scoped by construction. The account-scoped halt acts on the account-scoped ledger directly — no `sid`/root lookup at halt time.
- **D-08: Close ALL open jobs `CANCELLED`; synthetic only when open-count was zero.** A halt is account-wide and stops everything, so the handler closes every open `created`-without-`outcome` job CANCELLED this tick (each close independently ledger-gated). The synthetic fallback (D-05) is produced **only when zero jobs were open**. No job is left dangling after a halt.

### Synthetic id, idempotency & fail-open
- **D-09: Synthetic id is deterministic from `haltedAt`.** `hex = sha1(haltedAt)[:4]` → `guardrail-halt-<hex>` (honors the Phase 5 kebab + 4-hex job-id safety floor). Deterministic so the synthetic id is stable per-halt independent of the `JOB:halt:<haltedAt>` gate — its own `create`/`outcome` ledger lines are idempotent even if a tick is interrupted mid-write (belt-and-suspenders with D-03).
- **D-10: Fail-open via `JOBS_CLI_CAPABLE` probe + isolated, non-fatal handler.** The entire halt-handler step sits behind the existing `JOBS_CLI_CAPABLE` probe (skip silently when the CLI can't do jobs) and is wrapped so any failure (CLI error, timeout, 409 handling) is warn-logged and the tick continues — metering and task-type reporting are never endangered. Because `guardrail-check.sh` stays jobs-blind (D-01), the halt-status write, the agent's halt message, and `clear-halt.sh` are already fully decoupled and unaffected by any jobs failure.

### Claude's Discretion
- Exact placement of the halt-handler step within `report.sh` (after the session loop per D-02) and how it factors the "for each open job → outcome CANCELLED" loop vs. the synthetic create+outcome fallback (one shared helper vs. two call sites).
- Whether the synthetic interrupted job's `create` + `outcome` are two direct `revenium jobs` calls or routed through a small helper; either must stay ledger-gated and 409-as-success per Phase 6.
- `job_name` / `job_type` carried on the synthetic record (`job_type:"interrupted"` is fixed by JHALT-02; `job_name` wording — e.g. embedding the `haltedRule.name` — is open) and any `info`/`warn` log wording for the close-all and synthetic-fallback paths.
- Whether to embed the halted rule name/limit into the synthetic record's metadata for dashboard context (nice-to-have, not required by JHALT-02).
- Test strategy: a halt fixture exercising (a) open real job → CANCELLED under its own id, (b) no open job → synthetic `guardrail-halt-<hex>` interrupted/CANCELLED, (c) multiple open jobs → all CANCELLED, (d) idempotent across repeated halted ticks (`JOB:halt:<haltedAt>` gate), (e) fail-open when `JOBS_CLI_CAPABLE` is false / a jobs call errors (metering still ships, halt message/clear-halt unaffected). Extend `tests/stub-revenium.sh` to stub `jobs outcome`/`jobs create` and a `guardrail-status.json` halted fixture.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Requirements & roadmap (this repo)
- `.planning/REQUIREMENTS.md` §"Halt → Outcome (JHALT)" — JHALT-01/02 locked requirement text (authoritative on close-CANCELLED + synthetic-interrupted-record semantics).
- `.planning/ROADMAP.md` — Phase 8 section (goal + two success criteria: in-progress job closed `CANCELLED` through the existing halt flow; interrupted job recorded with `job_type:"interrupted"` + synthetic `guardrail-halt-<hex>` id).
- `.planning/phases/06-job-lifecycle-wiring/06-CONTEXT.md` — the single-session lifecycle (ledger-gated create/stamp/outcome, `JOBS_CLI_CAPABLE` probe, 409-as-success, fail-open) this phase reuses. **Do not regress the root path.**
- `.planning/phases/07-root-session-job-rollup/07-CONTEXT.md` — D-06 (root-only `jobs create`/`outcome`) is why the jobs ledger is already root-scoped (→ D-07 here); the create/outcome gate landmarks Phase 8 extends.
- `.planning/phases/05-job-declaration-foundation/05-CONTEXT.md` — job marker schema + the kebab + 4-hex job-id safety format the synthetic id (D-09) must honor; `interrupted` taxonomy label.

### Existing OpenClaw code to extend (this repo)
- `scripts/report.sh` — **the file Phase 8 modifies.** Landmarks: `JOBS_LEDGER_FILE` (~line 35) and `LEDGER_FILE` (~line 29); the `jobs create` stage (~lines 772–804, ledger key `JOB:<id>:created:<ts>`); the `jobs outcome` stage (~lines 936–980, ledger key `JOB:<id>:outcome:<ts>:<status>`, with the "created-confirmed" gate at ~948); `JOBS_CLI_CAPABLE` probe (Phase 6). New: an account-level halt-handler step **after** the per-session loop (D-02) that reads `guardrail-status.json`, scans the ledger for open jobs (D-06/D-08), and drives CANCELLED-close + synthetic fallback. **`report.sh` does not read `guardrail-status.json` today — this is a new read.**
- `scripts/guardrail-check.sh` — writes `guardrail-status.json` with `halted`/`haltedAt`/`haltedRule` on `HALT_TRANSITION` (~lines 291–322). **Unchanged in Phase 8 (D-01)** — it is the source of `haltedAt` (idempotency key, D-03) and `haltedRule` (optional metadata). Account-scoped; no session/jobs awareness.
- `scripts/clear-halt.sh` — flips `halted:false`, **preserves `haltedRule`/`haltedAt`** as audit trail. Relevant because `haltedAt` is preserved across halted ticks (anchors D-03) and a fresh halt after clear gets a new `haltedAt` → new ledger key. Unchanged in Phase 8.
- `scripts/write-job-marker.sh` — validates `job_type` against the 11-label taxonomy (incl. `interrupted`) and `status` against `SUCCESS|FAILED|CANCELLED`; sanitize-before-allowlist; kebab + 4-hex job-id discipline. Reference for the synthetic record's field validation (the handler may or may not route through a marker — see D-01/Discretion).
- `scripts/common.sh` — `OPENCLAW_HOME`, `MARKERS_DIR`, `SESSIONS_DIR`, `log/info/warn/error`; `guardrail-status.json` lives at `${SKILL_DIR}/guardrail-status.json` (= `~/.openclaw/skills/revenium/guardrail-status.json`).
- `SKILL.md` §"ABSOLUTE FIRST — HALT CHECK" (~lines 7–32) and the job taxonomy/`interrupted` label (~line 152) — the agent's halt behavior (emits ONLY the halt message, cannot write markers during a halt) is WHY the interrupted record must be produced by cron, not the agent.
- `tests/stub-revenium.sh`, `tests/test_report_jobs_argv.sh` — extend to stub `jobs outcome`/`jobs create` and a halted `guardrail-status.json` fixture for the five test cases above.

### Hermes reference (sibling repo `../hermes-revenium`, read-only)
- **No JHALT port exists.** `../hermes-revenium/skills/revenium/scripts/{guardrail-check.sh,clear-halt.sh}` only manage halt *status* (no jobs/interrupted concept). Phase 8 is OpenClaw-original — do not search Hermes for a halt→job mechanism.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **Phase 6 jobs lifecycle in `report.sh`** (create ~772–804, outcome ~936–980) — the ledger-gated, 409-as-success, fail-open `revenium jobs create/outcome` calls the halt handler reuses verbatim for both the real-job CANCELLED close (D-04) and the synthetic create+outcome (D-05).
- **`JOBS_LEDGER_FILE` (`revenium-jobs.ledger`)** — `JOB:<id>:created:` / `JOB:<id>:outcome:` lines are both the open-job source of truth (D-06) and the idempotency surface (D-03/D-09); the new `JOB:halt:<haltedAt>` key lives here too.
- **`JOBS_CLI_CAPABLE` probe + fail-open discipline** (Phase 6 D-11/D-12) — the whole halt handler stays behind it (D-10); metering ships byte-identical to v1.0 when the CLI can't do jobs.
- **`guardrail-status.json` halt fields** (`halted`, `haltedAt`, `haltedRule`) from `guardrail-check.sh` — already durably written each tick; the handler only reads them.

### Established Patterns
- **Ledger-gated idempotency + 409-as-success** (Phase 6) — extended to a new key family (`JOB:halt:<haltedAt>`) and the deterministic synthetic id; no new gating mechanism invented.
- **Root-only jobs ledger** (Phase 7 D-06) — guarantees every ledger id is root-scoped, so the account-scoped halt handler needs no session resolution (D-07).
- **Single jobs writer = `report.sh`** (Phase 6) — preserved by keeping `guardrail-check.sh` jobs-blind (D-01).
- **Cron runs regardless of agent halt** — the agent's halt freezes its responses but `cron.sh` (report.sh + guardrail-check.sh) keeps ticking, which is what makes the ~1-tick-latency design (D-01) reliable.
- **Env-passing Python heredoc discipline (T-04-09)** — any hashing of `haltedAt` (D-09) or status-json read passes values via env, never string-interpolated into the heredoc.

### Integration Points
- **New read:** `report.sh` reads `~/.openclaw/skills/revenium/guardrail-status.json` (first time it touches halt state).
- **New ledger key family:** `JOB:halt:<haltedAt>` (processed-once gate) alongside the existing `JOB:<id>:created/outcome:` lines.
- **New account-level step** in `report.sh` after the per-session loop (D-02) — the per-session loop and Phase 7 rollup stay untouched.
- **Decoupling guarantee:** halt detection/notification (`guardrail-check.sh`), the agent halt message (`SKILL.md`), and `clear-halt.sh` are all independent of the jobs handler (D-01/D-10) — a jobs failure cannot break the halt UX.

</code_context>

<specifics>
## Specific Ideas

- **Worked timeline — open job cancelled (D-04, JHALT-01):** root session R declared+created job `add-auth-9f3c` (ledger: `JOB:add-auth-9f3c:created:T1`, no outcome). At T2 a budget guardrail blocks in autonomous mode → `guardrail-check.sh` writes `halted:true, haltedAt=T2`. Next `report.sh` tick: session loop runs as normal, then the halt handler greps `JOB:halt:T2` → miss; finds `add-auth-9f3c` open → `revenium jobs outcome add-auth-9f3c --result CANCELLED`, ledger `JOB:add-auth-9f3c:outcome:T2b:CANCELLED`; open-count was 1 → no synthetic record; append `JOB:halt:T2`. Ticks T3, T4… still halted → `JOB:halt:T2` hit → skip.
- **Worked timeline — no open job (D-05/D-08, JHALT-02):** halt fires at `haltedAt=T9` with zero open jobs in the ledger. Handler: open-count 0 → `hex=sha1("T9")[:4]="a3f9"` → `revenium jobs create --agentic-job-id guardrail-halt-a3f9` (job_type `interrupted`), then `revenium jobs outcome guardrail-halt-a3f9 --result CANCELLED`; ledger gets `JOB:guardrail-halt-a3f9:created` + `:outcome:…:CANCELLED` + `JOB:halt:T9`.
- **Multi-open (D-08):** ledger open jobs `add-auth-9f3c` and `refactor-api-1b1b` → both closed CANCELLED this tick; no synthetic record.

</specifics>

<deferred>
## Deferred Ideas

- **Embedding rich halted-rule context (rule name, metric, limit) into the interrupted job's metadata** — nice-to-have for dashboard storytelling; not required by JHALT-02. Left to Claude's discretion / a follow-on if dashboards need it.
- **Reopening or resuming a CANCELLED job after `clear-halt`** — out of scope; `CANCELLED` is terminal. Resumed work declares a fresh job arc (normal Phase 5/6 flow). Not a Phase 8 concern.
- **Real-time (same-tick) halt→close** — rejected via D-01 in favor of the single-writer/~1-tick-latency model; revisit only if sub-minute close latency ever becomes a product requirement.
- **Per-job-type budget rules** — JGUARD-01, future milestone (observability-only this milestone).
- **Business-outcome reporting / `--outcome-type CONVERTED`** — JOUT-01, future milestone.
- **Classifier-plugin job inference (`on_session_end`)** — JCLASS-01, future milestone.

None — discussion stayed within phase scope (all of the above are explicit later-phase/future-milestone items, not scope creep introduced here).

</deferred>

---

*Phase: 8-Halt → CANCELLED Outcome*
*Context gathered: 2026-06-03*
