# Revenium OpenClaw Skill

## What This Is

A global OpenClaw skill that uses the `revenium` CLI to **enforce token-budget guardrails** and **meter agent usage** for every OpenClaw agent on the machine. It provides agent-guided setup (API key, guardrail budget rules), a hard enforcement loop (a cron stage polls guardrail state and the agent halts or warn-and-asks when a rule blocks), and per-completion metering that attributes spend by **root session** (`--agent openclaw-<root_session_id>`) and **task type** (an 8-label taxonomy classified before each substantive turn).

## Core Value

Agents never silently blow through token budgets — every turn is guardrail-checked and the user retains control over continuing past a threshold — **and** every completion is metered and attributed (by root session + task type) so spend is observable in Revenium.

## Current State

**Shipped v1.3 Reliable Attribution (2026-06-05)** — task/job marker attribution no longer depends on the LLM remembering an end-of-turn directive. A typed OpenClaw `before_agent_finalize` plugin (`revenium-marker-gate`) structurally forces the agent to run `write-marker.sh` before it can finalize a substantive turn — bounded (`retry.maxAttempts: 1`) and fail-open (never blocks the reply), with the fail-open boundary hardened + throw-path tested (CR-01). Shipped with `scripts/verify-markers.sh`, a read-only completions-vs-markers coverage diagnostic, and an idempotent `post-install.sh` install/enable/inspect step (sets `allowConversationAccess` and warns if `before_agent_finalize` is not in hookNames). Validated end-to-end on the live ClawHub host (98.82.34.123, opus-4-8): the revise loop fires, the agent classifies on the forced pass, unmarked turns still finalize, and attribution flows on the Revenium side — fixing the ~1-in-64 marked-completion baseline diagnosed in production.

**Shipped v1.2 Metering Completeness (2026-06-04)** — guardrail enforcement events and tool usage are now first-class Revenium transactions (`GUARDRAIL` / tool-events), closing the metering-visibility blind spots found while debugging v1.1 in production. Combined with v1.0 (guardrails + completion metering) and v1.1 (agentic job tracking), the skill now meters **every cost-incurring activity** — agent completions, guardrail enforcement events, and tool invocations — attributed by root session, task type, and agentic job.

**Status:** v1.4 NemoClaw/OpenShell Support — in planning.

**Open follow-up:** Phase 9 live guardrail-halt UAT/verification on host 172.16.1.247 deferred (validated through production use; see STATE.md → Deferred Items).

## Current Milestone: v1.4 NemoClaw/OpenShell Support

**Goal:** Let the Revenium skill optionally run under NemoClaw inside an OpenShell sandbox — a parallel install path that leaves the existing standalone OpenClaw + Docker path untouched.

**Target features:**
- Linux/NemoClaw detection + parallel install path (gate to Linux+Docker; refuse off-Linux explicitly — no silent no-op)
- Sandbox egress policy — ship + apply a host-scoped `revenium` network-policy preset for `api.revenium.ai`
- revenium CLI in-sandbox — prebuilt-binary delivery (not brew bottle), `SSL_CERT_FILE` → OpenShell CA bundle, `REVENIUM_*` injection
- Host-side metering loop — host cron + `nemoclaw share mount` refreshing `guardrail-status.json` (not per-tick `exec`, not in-sandbox cron)
- Per-turn enforcement plugin — OpenClaw `before_prompt_build` plugin delivering the mandatory guardrail directive (authored from the official scaffold)
- Skill deploy via `nemoclaw skill install`

**Basis:** 6 spikes in `.planning/spikes/` (4 VALIDATED, 2 PARTIAL with known build paths) + the `spike-findings-openclaw-revenium` skill. Feasibility proven end-to-end on live host 34.224.27.67. macOS unsupported.

### Next Milestone Goals (candidates)

Carried-forward / deferred requirements that could seed the next milestone:
- **GRDEV-F1** — meter per-tick guardrail API-poll overhead as aggregated enforcement cost (deferred v1.2 for volume/noise)
- **JCLASS-01** — LLM `on_session_end` classifier plugin for automatic job/task inference (gated on confirming OpenClaw session-end hook support)
- **JGUARD-01** — per-job-type budget rules in `setup-guardrails.sh --interactive`
- **JOUT-01** — business-outcome reporting (`--outcome-type CONVERTED`, ROI/conversion metrics)

## Requirements

### Validated

- ✓ Skill loads in OpenClaw with valid single-line JSON metadata and is gated on the `revenium` binary via `requires.bins` — v1.0 (Phase 1, SKAF-01..04)
- ✓ Agent-guided first-time setup: API key config + budget rule creation + idempotent re-run — v1.0 (Phase 2, SETUP-01..08)
- ✓ Guardrails-native enforcement: `setup-guardrails.sh` creates `budget-rules`, `guardrail-check.sh` polls enforcement state and writes `guardrail-status.json` atomically each cron tick — v1.0 (Phase 3, GUARD-01..06)
- ✓ Halt + warn-and-ask flow: SKILL.md reads `guardrail-status.json`/`haltedRule`; blocking rules in autonomous mode emit the verbatim halt string; warned rules trigger warn-and-ask — v1.0 (Phase 3)
- ✓ Task-type metering: 8-label `task-taxonomy.json`, mandatory TASK CLASSIFICATION directive, `--task-type` on every `meter completion` (default `unclassified`) — v1.0 (Phase 4, METER-01..03)
- ✓ Root-session attribution: `report.sh` resolves the root session and passes `--agent "openclaw-<root_session_id>"`; budget rules scope via `AGENT:STARTS_WITH:openclaw-` (D-07) — v1.0 (Phase 4, TRACE-01..02)
- ✓ Optional per-task-type budget rules offered by `setup-guardrails.sh --interactive` — v1.0 (Phase 4)
- ✓ Job declaration foundation: 11-label `job-taxonomy.json` (snake_case, installed + seeded via `post-install.sh`), `scripts/write-job-marker.sh` validated `kind:"job"` marker writer (sanitize-before-allowlist, flock+O_APPEND, completion_id correlation, safe kebab+4-hex job IDs), and the arc-boundary JOB DECLARATION directive in SKILL.md + `references/job-declaration.md` — v1.1 (Phase 5, JOBDEC-01..04)
- ✓ Job lifecycle wiring: `report.sh` opens each declared job once via `revenium jobs create`, stamps `--agentic-job-id/-name/-type` on every belonging `meter completion`, and closes it once via `revenium jobs outcome --result SUCCESS|FAILED|CANCELLED` — all ledger-gated (idempotent), 409-as-success, and fully fail-open behind a `JOBS_CLI_CAPABLE` capability probe so existing task-type metering is never endangered — v1.1 (Phase 6, JLIFE-01..05). Two human-verification follow-ups open: live 409 conflict-string confirmation and the CR-01 transient-failure retry-durability decision (see `06-HUMAN-UAT.md`).
- ✓ Root-session job rollup: a job spans the entire agent tree — `report.sh` resolves the root session once per subagent session (`root_aid` cross-session resolver reading `markers/{root_sid}.jsonl`), overrides each subagent completion with the root's `--agentic-job-*` values (or omits them on marker race / orphan), and gates `jobs create`/`jobs outcome` to root sessions only so subagent job markers never ship as separate jobs — v1.1 (Phase 7, JROLL-01..03). 5 advisory hardening warnings logged in `07-REVIEW.md` (multi-marker ordering, colon/tab id sanitization, python3-absent fail-open, log noise) — candidates for a follow-on, non-blocking.
- ✓ Halt → CANCELLED outcome: a guardrail halt still produces a terminal job record — `report.sh`'s account-level `handle_halt()` runs once per tick after the per-session loop (behind `JOBS_CLI_CAPABLE`), reads `guardrail-status.json`, and on a newly-recorded halt closes every open job CANCELLED under its own id (JHALT-01) or mints+closes a synthetic `guardrail-halt-<hex>` `interrupted` job when none were open (JHALT-02), gated exactly-once via a `JOB:halt:<haltedAt>` ledger marker and fully fail-open — v1.1 (Phase 8, JHALT-01..02). 5 advisory warnings in `08-REVIEW.md` (most notably `grep` regex vs fixed-string matching of untrusted `haltedAt`/job-id, and empty-hex collapse if python3 is absent) — candidates for a follow-on, non-blocking.
- ✓ Tool registry + tool-event metering: `report.sh` runs a `TOOLS_CLI_CAPABLE` dual-probe (`tools --help` + `meter tool-event --help`), and a toolCall scan loop (after the completion loop in `process_session`) registers each tool once via `revenium tools create --tool-id/--tool-type` (BUILTIN vs MCP_SERVER via the `__` convention; ids normalized URL-safe + lowercased via `tr`) and emits one `revenium meter tool-event --tool-id --duration-ms --timestamp --agent openclaw-<root_sid>` per toolCall with an explicit `--success` flag (no-default-false), never touching `meter completion`/`--operation-type` so existing TOOL_CALL completions are not double-counted — both helpers fully fail-open and idempotency-gated via `revenium-tools.ledger`/`revenium-tool-events.ledger` with anchored, prefix-safe dedup — v1.2 (Phase 10, TOOLEV-01..04). Two code-review BLOCKERs (unanchored ledger dedup causing prefix false-matches, e.g. `read` vs `read-file`) were fixed and locked with a prefix-collision regression test; 2 advisory warnings remain in `10-REVIEW.md` (WR-02 newline sanitization in error text, WR-04 bare mktemp) — non-blocking.
- ✓ Guardrail-event metering: `guardrail-check.sh` adds warn-onset transition detection to its Python state block (mirroring the shadow loop, gated `state=='warn'` & not shadowMode) and a fail-open Section M (strictly last, after the status write + notifications) that emits one zero-token `meter completion --operation-type GUARDRAIL --task-type budget_guardrail_<halt|warn|shadow> --stop-reason COST_LIMIT` per halt/warn/shadow onset — attributed to the root session (`--agent openclaw-<root_sid>`) + most-recent open job (`--agentic-job-id`), deduped exactly-once via `revenium-guardrail.ledger`; and `report.sh`'s dead `budget-status.json` GUARDRAIL heuristic is removed so completions are only ever CHAT/TOOL_CALL — v1.2 (Phase 9, GRDEV-01..06). Live CLI flag set confirmed against host 172.16.1.247 (transaction-id optional, zero tokens + COST_LIMIT + operation-type GUARDRAIL all accepted). 5 advisory warnings in `09-REVIEW.md` (WR-01 onset-tick event loss on meter failure, WR-02 `grep -qF`→`-qxF`) — non-blocking; live E2E tracked in `09-HUMAN-UAT.md`.

- ✓ Structural marker enforcement: a typed OpenClaw `before_agent_finalize` plugin (`revenium-marker-gate`, TypeScript + committed pre-built `dist/`) detects that a substantive (exec-running) turn produced no task marker and returns a bounded (`retry.maxAttempts: 1`) revise action forcing the agent to run `write-marker.sh` before it can finalize — fail-open (any gate throw resolves to pass-through, hardened at the host boundary in `index.ts` + throw-path tested per CR-01), marker detection tightened to actual invocation (not bare substring, WR-02), and exec observation done via `before_tool_call` without reading conversation content (privacy preserved). Wired into installs via an idempotent `post-install.sh` §7c step (`openclaw plugins install --force` + config patch enabling `allowConversationAccess` + `plugins inspect` hook-registration check + restart note, all `command_exists`-guarded and warn-and-continue). Plus `scripts/verify-markers.sh`, a genuinely read-only (WR-01) per-session completions-vs-markers coverage diagnostic. — v1.3 (Phase 11, SC-1..SC-5) — host E2E user-confirmed working (coverage rose above the ~1/64 baseline; exact before/after % waived — terminal history cleared, tracked in `11-HUMAN-UAT.md`). 8 advisory findings deferred in `11-REVIEW.md` (WR-03..WR-06, IN-01..IN-04) — non-blocking.

### Active

No active milestone — v1.3 shipped. Run `/gsd-new-milestone` to scope the next one (candidates listed under **Current State → Next Milestone Goals**).

**Open UAT follow-ups carried across milestones:**
- Phase 9 (v1.2): live guardrail-halt E2E on host 172.16.1.247 — confirm a `GUARDRAIL` transaction lands in Revenium (UAT/verification `human_needed`, deferred).
- Phase 10 (v1.2): live tool-registry / tool-event E2E confirmation against host 172.16.1.247.

**v1.1 post-ship fix (validated live):** the agent-written-marker pipeline (task classification + job declaration) never fired in production because OpenClaw loads `SKILL.md` on-demand — the "every turn" directives were never in the agent's context. Fixed by injecting hardened completion-gate directives into `~/.openclaw/workspace/AGENTS.md` via `post-install.sh`; end-to-end verified (agent self-writes markers → cron → job created + closed SUCCESS in Revenium).

### Out of Scope

- ~~**Agentic Job tracking**~~ — promoted into scope for **v1.1** (see Current Milestone)
- Code-side classifier *plugin* + OpenClaw `pre_llm_call`/`pre_tool_call`/`on_session_end` hooks — agent-driven marker write remains the classification mechanism; v1.3 added a `before_agent_finalize` *enforcement* plugin (confirmed working — the agent still writes markers, the plugin just forces it to) but full code-side *inference* (deriving the classification without the agent) and `on_session_end` job inference remain deferred to a future milestone
- **Per-job-type budget rules/guardrails** — job tracking is observability-only; enforcement stays on existing `AGENT:STARTS_WITH` rules with server-side job rollup
- ~~Tool-event reporting (`meter tool-event`)~~ — promoted into scope for **v1.2** (Phase 10)
- Per-tick guardrail API-poll overhead metering — high volume/noise; v1.2 meters discrete enforcement *events*, not every poll
- Mobile/desktop companion app — CLI/agent-level skill only
- Multi-agent budget splitting — single shared budget per machine; rollup is per root session
- Token counting/estimation — Revenium platform handles actual metering
- Bundling the `revenium` binary — user installs it to PATH themselves

## Context

- **Shipped v1.0** (2026-06-03): 4 phases, 14 plans, 26 tasks, ~81-day calendar span, 107 feat/fix/docs commits. ~39 automated tests (bash + python) across `tests/`.
- **Shipped v1.1** (2026-06-04): 4 phases (5–8), 10 plans, 14 tasks — agentic job tracking ported onto the agent-written-marker architecture; 71/71 cumulative hermetic tests.
- **Shipped v1.2** (2026-06-04): 2 phases (9–10), 6 plans, 10 tasks, 45 commits, +8,054/−179 across 38 files — guardrail-event + tool-registry/tool-event metering. New hermetic argv harnesses (`test_guardrail_argv.sh`, `test_report_tool_argv.sh`) + extended `stub-revenium.sh`.
- **Tech stack:** bash scripts + a small Python sidecar (`get-root-session-id.py`), JSON config/taxonomy, markdown agent instructions (SKILL.md). No build system; `set -euo pipefail` discipline; atomic writes via `tempfile.mkstemp` + `os.replace`.
- **`revenium` CLI:** config at `~/.config/revenium/config.yaml`; env overrides `REVENIUM_API_KEY`/`REVENIUM_TEAM_ID`/`REVENIUM_API_URL`. Key commands used: `config show`, `guardrails budget-rules {create,list,get,update}`, `guardrails enforcement-rules get`, `meter completion` (with `--task-type`/`--agent`).
- **OpenClaw integration:** skill installed at `~/.openclaw/skills/revenium/`; sessions at `~/.openclaw/agents/main/sessions/*.jsonl`; cron (`cron.sh`) runs `report.sh` + `guardrail-check.sh` every minute; markers at `~/.openclaw/skills/revenium/markers/{sid}.jsonl`.
- **Known caveats at ship (see STATE.md → Deferred Items):** in-skill D-08 legacy-filter notice firing not independently verified (the rule was reconfigured directly); subagent→root spend rollup verified at the resolver/unit level but not end-to-end with live subagents.

## Constraints

- **Binary dependency:** `revenium` must be on PATH — skill won't load without it (`requires.bins`)
- **API key required:** must be configured before any CLI commands work
- **Single-process pipeline:** metering/enforcement run as cron stages; no daemon
- **OpenClaw skill format:** YAML/JSON frontmatter + markdown body
- **Network latency:** guardrail polling and metering are network round-trips to the Revenium API

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Global install (~/.openclaw/skills/) | Available to all agents on the machine, not project-specific | ✓ Good |
| Expect `revenium` on PATH | Simpler distribution; user manages their own binary | ✓ Good |
| Single-line JSON metadata in SKILL.md | OpenClaw silently drops multi-line/colon-space metadata | ✓ Good (Phase 1) |
| Guard-first body ordering in SKILL.md | Maximize LLM instruction compliance | ✓ Good (Phase 1) |
| Guardrails-native enforcement (replace alert model) | First-class `budget-rules` + enforcement state vs legacy `alerts budget` polling | ✓ Good — superseded the original anomaly-ID/alert design (Phase 3) |
| No auto-migration of legacy installs | Legacy alertId-only installs treated as "setup not complete" | ✓ Good (Phase 3, D-02) |
| Atomic status writes (mkstemp + os.replace) | Prevent torn reads of guardrail-status.json | ✓ Good (Phase 3) |
| `AGENT:STARTS_WITH:openclaw-` attribution (D-07) | Per-root-session rollup; supersedes static `AGENT:IS:OpenClaw` | ✓ Good (Phase 4) |
| Agent-driven marker write (not native hooks) | OpenClaw `pre_llm_call` hook events unconfirmed | ⚠️ Revisit — markers land after the turn's completion; correlation reworked to completion_id keying |
| Task-type correlation by `completion_id` + marker-after fallback | Timestamp-precedence (marker before completion) never matched in practice | ✓ Good (post-Phase-4 debug fix) |
| Defer Agentic Job tracking to a future milestone | Per-session `--agent` rollup sufficient for v1.0 | ✓ Promoted to v1.1 |
| Agent-written `kind:"job"` markers (not classifier plugin) for v1.1 | Consistent with v1.0 task-type architecture; avoids unconfirmed OpenClaw session-end hook dependency | ✓ Foundation shipped (Phase 5) |
| Dedicated `write-job-marker.sh` (D-06: new writer, not an extension of `write-marker.sh`) | Keep task-type writer untouched; job writer diverges on named flags + 7 mandatory fields | ✓ Good (Phase 5 — write-marker.sh byte-for-byte unchanged) |
| Marker directives belong in `AGENTS.md`, not `SKILL.md` (v1.1 post-ship) | OpenClaw loads SKILL.md on-demand, so "classify/declare every turn" directives never reached the agent; AGENTS.md is read before every response. Soft wording was skipped too — only a hard *completion-gate* framing works | ✓ Good — agent reliably writes task/job markers (validated live); injected via post-install.sh |
| Revenium renders completion `operationType` as the transaction "type" (CHAT/TOOL_CALL/GUARDRAIL) | Confirmed with stakeholder; basis for v1.2 guardrail-event metering | ✓ Good (drove v1.2 Phase 9) |
| Guardrail-event metering lives in `guardrail-check.sh` Section M, strictly last + fail-open | Enforcement (status write + notifications) must never be blocked by a metering round-trip | ✓ Good (Phase 9) |
| Tool registry/tool-event metering in `report.sh` scan loop, never touching `meter completion`/`--operation-type` | Keeps tool-events fully separate from the existing `TOOL_CALL` completions → no double-counting | ✓ Good (Phase 10, TOOLEV-03) |
| Anchored, prefix-safe ledger dedup for tools/events (`grep -qxF`-style exact match) | Unanchored dedup false-matched prefixes (`read` vs `read-file`); two code-review BLOCKERs | ✓ Good — fixed + regression-locked (Phase 10) |
| `revenium tools create --tool-type` is a strict server-side enum (use CUSTOM/MCP_SERVER, not BUILTIN) | BUILTIN rejected live; dry-run does not catch it — probed against the real host | ✓ Good (Phase 10 post-ship fix, commit 7e5b9f9) |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-06-07 — started v1.4 NemoClaw/OpenShell Support milestone (parallel install path), scoped from 6 spikes proven on live host 34.224.27.67.*
