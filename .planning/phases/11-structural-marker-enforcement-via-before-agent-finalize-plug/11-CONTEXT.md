# Phase 11: Structural Marker Enforcement via before_agent_finalize plugin - Context

**Gathered:** 2026-06-04
**Status:** Ready for planning

<domain>
## Phase Boundary

Make per-turn task classification **structurally enforced** instead of LLM-compliance-dependent. Today, even Opus 4.8 reliably drops the end-of-turn `write-marker.sh` gate (~1 of 64 completions marked on the ClawHub host `98.82.34.123`), even though the AGENTS.md directive is present and demonstrably in-context. Directive-wording tuning cannot fix this.

Phase 11 ships two things:

1. **`revenium-marker-gate`** — a typed OpenClaw plugin (new tech surface: TypeScript) that uses the `before_agent_finalize` hook to force the agent to run `write-marker.sh` before it can finalize a substantive turn. It observes `exec` tool calls (no conversation access) to track whether a turn classified, and on an unclassified substantive turn returns `{ action: "revise", retry: {...} }` to send the agent back **one bounded pass**. Fail-open: a hook error/timeout, or a still-unmarked turn after the bounded pass, finalizes anyway and never blocks the user's reply.
2. **`scripts/verify-markers.sh`** — a diagnostic that reports per-session completions-vs-markers so the gap is measurable before/after. Built regardless of plugin progress.

**In scope:** the plugin package (in-repo `plugin/` dir), its `post-install.sh` install + enable automation, the per-turn **task** marker gate, and the `verify-markers.sh` diagnostic.

**Out of scope (deferred — see Deferred Ideas):** `session_end` deterministic job-closure hook; per-turn **job** marker gating; per-job-type budget rules (JGUARD-01); LLM session-end classifier (JCLASS-01); business-outcome reporting (JOUT-01). No change to budget-rule logic, `config.json` `ruleIds`, the `guardrail-status.json` halt/warn contract, or `report.sh`'s `unclassified` default + completion_id correlation.

</domain>

<decisions>
## Implementation Decisions

### Direction (locked by research seed — not re-litigated)
- **D-00 (carry-forward):** Use the typed `before_agent_finalize` plugin hook. Chosen over (a) a `message:sent` file hook and (b) a `report.sh` cron backfill — both only harden the `unclassified` floor that `report.sh` already provides and cannot produce the rich task_type/job signal that needs LLM judgment.

### Plugin home & distribution
- **D-01:** **Same repo, new `plugin/` dir.** The TypeScript plugin lives in a new `plugin/` package inside this repo and versions + ships alongside the bash skill on ClawHub as one unit — one release, one PR surface, kept in lockstep. (Not a separate repo, not flat top-level TS files.)
- **D-02:** **`post-install.sh` automates install + enable.** `post-install.sh` runs `openclaw plugins install` (local path from the skill dir) and writes the `plugins.entries.<id>` enable config — **idempotent**, mirroring the existing AGENTS.md injection pattern. No extra user steps. Rationale: the v1.1 production lesson is that un-automated setup steps silently do not run. (Exact invocation + enable-config shape is a research item — see Canonical/Research.)

### Gate scope & trigger
- **D-03:** **Task marker only.** The gate forces the per-turn `write-marker.sh` (task) marker. It does **not** gate `write-job-marker.sh` per turn — job arcs don't conclude every turn (D-04 soft floor), so per-turn job gating would over-fire and manufacture false job boundaries. Job declaration stays directive-driven; job closure is deferred (see Deferred Ideas).
- **D-04:** **Fire only on turns that ran ≥1 `exec` tool call and produced no `write-marker.sh`.** "Substantive turn" is defined structurally (the plugin has no conversation access): track `exec` tool calls per `ctx.runId`; if the turn invoked at least one `exec` tool and none was `write-marker.sh`, gate finalize. Pure-chat turns (no tools) pass through unforced — avoids needless extra passes on trivial replies.
- **D-05:** **Bounded + fail-open (carry-forward).** `retry.maxAttempts` caps the forced passes (seed proposes `1`); if the agent still doesn't classify, the harness finalizes anyway. A hook error or timeout must never block the user's reply. No `allowConversationAccess` grant — the plugin observes `exec` tool calls only.

### Diagnostic
- **D-06:** **`scripts/verify-markers.sh` built regardless.** Reports, per session, completions vs. markers so the gap is measurable before/after the gate lands. Low-risk; independent of plugin progress.

### Constraints preserved (carry-forward, non-negotiable)
- **D-07:** No change to budget-rule logic, `config.json` `ruleIds`, or the `guardrail-status.json` halt/warn JSON contract. Preserve `report.sh`'s existing atomic-write patterns, completion_id correlation, and `unclassified` default (unmarked turns still ship as metered `unclassified` completions — what the gate recovers is task_type specificity + job association, not the metering floor).

### Claude's Discretion (resolve in research/planning)
- **Packaging / build format:** Research item (user deferred). Determine what package shape `openclaw plugins install` actually consumes (raw `.ts`, prebuilt `.js`, `package.json` with a build step) and pick the **most host-robust** option — strong lean toward a self-contained prebuilt artifact with deps vendored, so a locked-down ClawHub host needs no npm/tsc/build-on-host step (the same v1.1 "un-guaranteed step silently doesn't run" lesson behind D-02).
- **`maxAttempts` value:** Seed proposes `1` (exactly one forced pass). Planner may confirm/tune; keep it minimal to preserve fail-open snappiness.
- **Forced-pass instruction wording + idempotencyKey:** The `retry.instruction` text and `idempotencyKey` (seed: `marker-gate:${ctx.runId}`) are planner/researcher detail, consistent with the locked decisions above.
- **runId stability:** Confirm `ctx.runId` is stable across the `before_tool_call`/`after_tool_call` hooks and the `before_agent_finalize` hook within the same turn (the tracking-set correlation depends on it). Confirm cleanup hook (`agent_end`) name + semantics.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase 11 source-of-truth
- `.planning/research/marker-enforcement-before-agent-finalize.md` — live diagnosis (ClawHub host, opus-4-8, 1-of-64 baseline), the `before_agent_finalize` contract, the proposed `revenium-marker-gate` design, and the open design questions resolved in this CONTEXT.
- `.planning/ROADMAP.md` § "Phase 11: Structural Marker Enforcement" — goal + 5 success criteria.

### OpenClaw plugin SDK (external — researcher to locate/confirm on host)
- OpenClaw `docs/plugins/hooks.md:339` — `before_agent_finalize` contract (runs only when a harness is about to accept a natural final answer; NOT the `/stop` path; does not run on user abort). Return values: `revise` (with `retry.instruction` / `idempotencyKey` / `maxAttempts`), `finalize`, or omit.
- `openclaw/plugin-sdk/plugin-entry` — `definePluginEntry({ id, name, register(api) })`; `api.on(name, handler, { priority, timeoutMs })`. **Research item:** confirm the exact `openclaw plugins install <local-path>` invocation and the `plugins.entries.<id>.hooks` enable-config shape (note: `allowConversationAccess` is NOT needed here).

### Existing skill integration points
- `scripts/post-install.sh` § 7/7b (lines ~502–614) — the idempotent AGENTS.md injection pattern to mirror for plugin install + enable.
- `scripts/write-marker.sh` — the task-marker writer the gate sends the agent back to invoke.
- `scripts/report.sh` (~lines 713–760) — `unclassified` default + completion_id correlation that must be preserved.
- `scripts/common.sh` — shared constants/helpers (root-session resolution etc.) for `verify-markers.sh`.

### Validation
- Memory `[[clawhub-test-host]]` — ClawHub test host `98.82.34.123`, ssh `-i ~/.ssh/agent-sandbox.pem ubuntu@98.82.34.123`, install v0.5.8 on opus-4-8. End-to-end validation target: confirm the revise loop fires, the agent classifies on the forced pass, and finalize proceeds when still unmarked (fail-open), raising marked-completion coverage well above the ~1-in-64 baseline.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `post-install.sh` idempotent-injection pattern (Python heredoc with BEGIN/END sentinels): directly adapt for `openclaw plugins install` + `plugins.entries.<id>` enable-config so re-runs are safe.
- `scripts/common.sh`: root-session resolver + constants `verify-markers.sh` can reuse to map sessions → markers.
- `markers/{sid}.jsonl` + session files (`~/.openclaw/agents/main/sessions/*.jsonl`): the data `verify-markers.sh` diffs (completions vs. markers per session).

### Established Patterns
- Fail-open + idempotency-ledger discipline across the bash skill (jobs/guardrail/tool-event ledgers): the plugin's "structurally enforced but never blocking" contract is the TS-side analog — bounded retry + finalize-anyway.
- `set -euo pipefail` + atomic writes (`mkstemp` + `os.replace`) for any new bash (`verify-markers.sh`).

### Integration Points
- New `plugin/` dir at repo root, bundled into the skill tarball shipped on ClawHub.
- `post-install.sh` gains a new step to install + enable the plugin (after the existing AGENTS.md steps).
- The plugin is purely additive observability/enforcement — it touches no metering/guardrail bash logic; it only changes whether the agent classifies before yielding.

</code_context>

<specifics>
## Specific Ideas

- The plugin design is sketched in the research seed (`register(api)` with `before_tool_call`/`after_tool_call` tracking `markedTaskRuns` by `ctx.runId`, `before_agent_finalize` returning the bounded `revise`, `agent_end` cleanup). Use it as the starting blueprint, adjusted for D-04 (gate only when an `exec` tool ran) and the confirmed SDK hook names.
- Validation must be end-to-end on the ClawHub host (`98.82.34.123`, opus-4-8) — not just unit-level — because the whole premise is a production LLM-compliance failure that only reproduces on a real install.

</specifics>

<deferred>
## Deferred Ideas

- **`session_end` deterministic job-closure hook** — a typed `session_end` hook (reason ∈ new/reset/idle/daily/compaction/deleted/shutdown/restart) to close open jobs CANCELLED/interrupted deterministically. Complements the per-turn task gate but adds a second hook surface + its own test/validation burden to a new-tech phase. Deferred to keep Phase 11 narrow; candidate for its own phase.
- **Per-turn job marker gating** — rejected for Phase 11 (over-fires; job arcs don't conclude every turn). Job declaration stays directive-driven.
- **Carried-forward milestone candidates (unchanged):** JCLASS-01 (LLM session-end classifier plugin), JGUARD-01 (per-job-type budget rules), JOUT-01 (business-outcome reporting), GRDEV-F1 (per-tick guardrail poll-overhead metering).

</deferred>

---

*Phase: 11-structural-marker-enforcement-via-before-agent-finalize-plug*
*Context gathered: 2026-06-04*
