# Phase 4: Task Metering & Attribution - Context

**Gathered:** 2026-06-03
**Status:** Ready for planning

<domain>
## Phase Boundary

Add task-type metering and subagent attribution to the existing OpenClaw metering pipeline. Deliverables: `task-taxonomy.json` (the standard 8-label vocabulary, copied from Hermes), a mandatory TASK CLASSIFICATION section in SKILL.md that fires before substantive turns and writes a per-session task marker, `report.sh` changes that read the marker and pass `--task-type <label>` (default `unclassified`) plus `--agent "openclaw-{root_session_id}"` on every `revenium meter completion`, a root-session resolver, and an optional per-task-type budget-rule picker added to `setup-guardrails.sh --interactive`.

**In scope:** task taxonomy, classification trigger + marker write path, timestamp-correlated task-type attribution in report.sh, root-session resolution for subagent rollup, the agent-name/filter migration that this requires, and optional per-task-type guardrail rules.

**Out of scope (NOT this phase):** Hermes' jobs / `--agentic-job-id` API, the code-side classifier *plugin* + OpenClaw hooks (unconfirmed — agent-driven marker write is used instead), tool-event reporting, and any rewrite of the Phase 3 guardrail enforcement core.

</domain>

<decisions>
## Implementation Decisions

### Task Marker Mechanism
- **D-01:** Task-type attribution is **timestamp-correlated**, not session-level. Each marker carries a timestamp; `report.sh` tags each metered completion with the `task_type` of the most recent marker whose timestamp precedes that completion. A session that does research then generation reports both labels correctly. (`report.sh` already parses per-line timestamps; this adds ~30 lines to its Python delta loop.)
- **D-02:** Markers are stored as an **append-log**: `markers/<sid>.jsonl`, one JSON line per classification (`{ts, task_type}`). Mirrors the Hermes `markers/` layout (eases the port) and naturally supports timestamp correlation. Marker dir lives under the skill/state dir (`~/.openclaw/skills/revenium/markers/`).
- **D-03:** The agent writes markers via a **helper script** — SKILL.md instructs a single call `bash ~/.openclaw/skills/revenium/scripts/write-marker.sh <task_type>`. The script stamps the ISO timestamp, validates `<task_type>` against `task-taxonomy.json`, resolves the current session id itself, and appends to `markers/<sid>.jsonl`. (Chosen over direct LLM file-append to avoid malformed markers.)
- **D-04:** **Prune in cron.** A cron-path stage (`guardrail-check.sh` or `report.sh`) deletes marker files older than ~7 days on each tick. No separate cron entry, no dedicated prune script. Final age threshold is Claude's discretion.

### Subagent Root Attribution
- **D-05:** **Resolve root now, fail-open.** Build an OpenClaw root-session resolver (analog of Hermes `get-root-session-id.py`) and ship `--agent "openclaw-{root_session_id}"`. If a session's parent/root cannot be resolved, fall back to the session's own id (`openclaw-{sid}`) — it simply becomes its own root. Metering is never blocked by resolution failure.
- **D-06:** **No hard research gate.** The resolver is built with the fail-open fallback baked in regardless of research findings. Research during plan-phase informs *how* the resolver discovers the parent→root linkage in OpenClaw JSONL (the word "subagent" appears in session JSONL — see code_context), but the absence of a clean linkage degrades gracefully rather than blocking the phase. **Open research question:** OpenClaw has **no** SQLite `state.db` with `parent_session_id` (Hermes' mechanism) — sessions are JSONL. The resolver must derive root from JSONL content. STATE.md records this as a Phase 4 blocker to verify.

### Agent-Name / Filter Migration
- **D-07:** Base budget rule(s) filter on **`AGENT:STARTS_WITH:openclaw-`** (catches every session — both `openclaw-{root}` and the `openclaw-{sid}` fallback). Introduce a **`REVENIUM_AGENT_PREFIX="openclaw-"`** constant in `common.sh`. `report.sh` ships `--agent "openclaw-{root}"`. This **supersedes** the Phase 3 D-23 static `--agent "OpenClaw"` / `AGENT:IS:OpenClaw` model. The `REVENIUM_AGENT_NAME` constant from Phase 3 is effectively replaced by the prefix-based scheme for metering/filtering.
- **D-08:** **Detect legacy installs and prompt reconfigure.** Changing `--agent` silently breaks Phase 3 rules that filter `AGENT:IS:OpenClaw` (they stop matching any completion). On `/revenium` (and/or a cron-path check), detect rules still using the legacy `AGENT:IS:OpenClaw` filter — or a version marker in `config.json` — and surface a **one-time** notice: "Your budget rules use the old filter and won't track spend — run reconfigure." **No silent auto-rewrite** (honors Phase 3 D-02 no-migration ethos); the user stays in control. Detection mechanism (live filter inspection vs config version marker) is Claude's discretion.

### Classification Trigger
- **D-09:** SKILL.md uses the **Hermes substantive-turn trigger** verbatim-in-spirit: classify the turn if it called any non-read-only tool **OR** produced > 200 words **OR** answered a multi-step reasoning question; skip only when the entire response is ≤ 2 sentences **AND** zero tools were called. Port wording from Hermes `references/task-classification.md`. When no marker is written, `report.sh` defaults the completion to `--task-type unclassified`.

### Per-Task-Type Guardrail Rules (criterion 5)
- **D-10:** **Port the full Hermes per-task-type picker**, gated on CLI capability. After creating the base rule, `setup-guardrails.sh --interactive` offers to create per-task-type budget rules drawn from the live `task-taxonomy.json`; each such rule filters `AGENT:STARTS_WITH:openclaw-` **AND** a `TASK_TYPE` clause. **Open research question:** confirm the `revenium guardrails budget-rules create` CLI supports a `TASK_TYPE` filter dimension. If unsupported, the picker offer is **skipped gracefully** (log why) — base rule creation still succeeds. (Hermes' picker lives at `setup-guardrails.sh` lines ~700-797, which Phase 3 deliberately omitted; Phase 4 ports it back.)

### Claude's Discretion
- Final marker-prune age threshold (~7 days suggested).
- Legacy-install detection mechanism (live `AGENT:IS:OpenClaw` filter inspection vs a `config.json` version/schema marker).
- Which cron stage owns marker pruning (`report.sh` vs `guardrail-check.sh`).
- Exact root-resolution algorithm over OpenClaw JSONL (subject to research).
- Whether per-task-type rules reuse the base rule's hard-limit prompt flow or ask separately.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Source of truth — Hermes skill to port from
- `../hermes-revenium/skills/revenium/task-taxonomy.json` — the canonical 8-label vocabulary (research, analysis, generation, review, code_review, refactor, planning, debugging); copy to `~/.openclaw/skills/revenium/task-taxonomy.json` (success criterion 1)
- `../hermes-revenium/skills/revenium/scripts/hermes-report.sh` — canonical report.sh with `--task-type` / `--agent` / root-session wiring (lines ~187-209 root walk, ~1016-1088 per-marker meter completion, ~1106-1155 unclassified fallback). Port the task-type + agent logic; **drop** the jobs / `--agentic-job-id` machinery (out of scope)
- `../hermes-revenium/skills/revenium/scripts/get-root-session-id.py` — canonical root-walk sidecar. NOTE: it queries SQLite `state.db.sessions.parent_session_id`, which OpenClaw does **not** have — adapt the algorithm to OpenClaw JSONL (D-05/D-06)
- `../hermes-revenium/skills/revenium/scripts/common.sh` — `get_root_session_id()` bash wrapper (lines ~96-145), taxonomy/markers path constants (lines 16-32); adapt paths to OpenClaw single-dir model
- `../hermes-revenium/skills/revenium/SKILL.md` — TASK CLASSIFICATION FINAL ACTION section (lines ~218-259); port the trigger + marker-write directive (D-09), drop the JOB DECLARATION / classifier-plugin references
- `../hermes-revenium/skills/revenium/references/task-classification.md` — trigger rules, `write_marker` snippet, blocklist, worked examples (D-09 source)
- `../hermes-revenium/skills/revenium/scripts/setup-guardrails.sh` §lines ~700-797 — the per-task-type rule picker to port (D-10)

### Current OpenClaw skill (being modified)
- `scripts/report.sh` — add task-type correlation (D-01) + `--agent "openclaw-{root}"` (D-05); currently ships hardcoded `--agent "OpenClaw"` at line 221 and tracks per-session line offsets (lines 147-176, 286-503)
- `scripts/setup-guardrails.sh` — add per-task-type picker (D-10); change base filter to `AGENT:STARTS_WITH:openclaw-` (D-07); current filter is `AGENT:IS:${REVENIUM_AGENT_NAME}` (lines 270, 289)
- `scripts/common.sh` — add `REVENIUM_AGENT_PREFIX` constant (D-07) + root-session resolver wrapper; currently defines `REVENIUM_AGENT_NAME="OpenClaw"`
- `scripts/cron.sh` — may own the marker-prune stage (D-04)
- `SKILL.md` — add TASK CLASSIFICATION section (D-09) + legacy-install reconfigure notice (D-08)
- `scripts/write-marker.sh` — NEW helper (D-03)

### Phase 3 decisions this phase builds on / supersedes
- `.planning/phases/03-guardrail-engine/03-CONTEXT.md` — D-23 (static `--agent "OpenClaw"`, `AGENT:IS:OpenClaw`) is **superseded** by D-07 here; D-02 no-migration ethos is **honored** by D-08
- `.planning/phases/03-guardrail-engine/03-PATTERNS.md` — Hermes→OpenClaw substitution map, atomic-write / fail-open / bash-3.2-heredoc patterns that also govern Phase 4 scripts

### Roadmap / requirements
- `.planning/ROADMAP.md` §"Phase 4: Task Metering & Attribution" — goal + 5 success criteria (METER-01/02/03, TRACE-01/02)
- `.planning/REQUIREMENTS.md` — note: METER-*/TRACE-* requirement IDs are referenced by the roadmap but not yet enumerated in REQUIREMENTS.md; planner should treat the ROADMAP success criteria as the authoritative requirement list for this phase

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/report.sh` — complete metering reporter; the primary modification target. Already maps providers, cleans model names, maps stop reasons, tracks per-session line offsets (`revenium-offsets.json`), and posts via `revenium meter completion` (the `post_to_revenium` function, line 208+). Task-type + agent changes graft onto the existing per-line delta loop.
- `scripts/common.sh` (Phase 3) — path constants, `ensure_path()`, log helpers, `has_guardrails_cli()`, `REVENIUM_AGENT_NAME`. Extend with the prefix constant and resolver wrapper.
- `scripts/setup-guardrails.sh` (Phase 3) — interactive rule creation with `create_rule`, flock, validation helpers; the picker grafts on after the base-rule path.
- `../hermes-revenium/skills/revenium/task-taxonomy.json` — copy verbatim (labels match the roadmap's required 8 exactly).

### Established Patterns
- Python3 for all JSON manipulation (no `jq` on the enforcement path; `report.sh` does use `jq` for JSONL parsing).
- Atomic writes: temp-file-then-rename (Phase 3 D-14 / PATTERNS "Atomic JSON Write") — apply to any marker/config writes.
- Bash 3.2-safe env-passing heredocs (never interpolate `${VAR}` inside `<<'PY'`).
- Fail-open cron posture: every cron-path failure logs `warn` and `exit 0` — applies to the resolver and prune stages.
- OPENCLAW_HOME multi-candidate probe (in `report.sh` lines 17-26, `common.sh`).
- Hermes→OpenClaw substitution map (03-PATTERNS.md "Key Substitution Map").

### Integration Points
- `~/.openclaw/agents/main/sessions/<sid>.jsonl` — session transcripts. JSONL header line keys: `type, version, id, timestamp, cwd` (no `parentSessionId` in the header). The string "subagent" appears within session JSONL bodies (~15 occurrences observed) — likely where parent/root linkage for D-05 must be derived. **This is the key research target.**
- `~/.openclaw/skills/revenium/config.json` — holds `ruleIds` (Phase 3); D-08 may add a version/schema marker here.
- `~/.openclaw/skills/revenium/markers/<sid>.jsonl` — NEW per-session marker log (D-02).
- `~/.openclaw/skills/revenium/task-taxonomy.json` — NEW, read by `write-marker.sh` (validation) and `setup-guardrails.sh` (picker).
- `revenium meter completion` CLI — already invoked by `report.sh`; confirm `--task-type` and `--agent` flags exist on the installed revenium version (Hermes uses both; verify on OpenClaw's pinned version).
- `revenium guardrails budget-rules create` — confirm a `TASK_TYPE` filter dimension exists (D-10 open question).

</code_context>

<specifics>
## Specific Ideas

- Agent value format: `openclaw-{root_session_id}` (lowercase prefix), filter `AGENT:STARTS_WITH:openclaw-`.
- Marker line shape: `{"ts": "<ISO8601>", "task_type": "<label>"}` appended to `markers/<sid>.jsonl`.
- Marker write call (SKILL.md): `bash ~/.openclaw/skills/revenium/scripts/write-marker.sh <task_type>`.
- 8 taxonomy labels (exact): research, analysis, generation, review, code_review, refactor, planning, debugging.
- Default task type when no marker precedes a completion: `unclassified`.
- Legacy-install notice (one-time): "Your budget rules use the old filter and won't track spend — run reconfigure."
- Marker prune horizon: ~7 days (tunable).

</specifics>

<deferred>
## Deferred Ideas

- Hermes jobs / `--agentic-job-id` arc correlation and `--agentic-job-name`/`--agentic-job-type` — richer than per-session `--agent` rollup; out of scope for v1, possible future milestone.
- Code-side classifier plugin + OpenClaw lifecycle hooks (`pre_llm_call` / `post_tool_call` equivalents) for automatic marker writing — carried over from Phase 3 deferred list; remains blocked on OpenClaw hooks research. Phase 4 uses agent-driven marker writes instead.
- Tool-event-level metering (`tool-event-report.sh` in Hermes) — out of scope.

</deferred>

---

*Phase: 04-task-metering-attribution*
*Context gathered: 2026-06-03*
