# Feature Research

**Domain:** OpenClaw 2.0 cut-over — plugin/hook API, skill format, CLI, session storage, telemetry, for a metering/guardrail skill
**Researched:** 2026-09-23
**Confidence:** MEDIUM — findings are grounded in official `docs.openclaw.ai` pages and `github.com/openclaw/openclaw` issues/PRs (fetched directly), but the fetch mechanism available in this session (`WebSearch`/`WebFetch`, no `context7`/`exa`/doc-specific MCP tool) is itself scored LOW by the project's `classify-confidence` seam regardless of source authority. Treat HIGH-confidence-looking claims below as **MEDIUM at best** until corroborated by a live 2.0 host, and treat anything marked **UNVERIFIED** as needing a live-host spike before requirements are locked in.

---

## Critical Findings (read this first)

### 1. Does OpenClaw 2.0 exist? — YES, confirmed.

OpenClaw 2.0 is the branding name for release **v2026.8.1**, shipped **2026-08-30**, after the team paused its normal rapid CalVer cadence for ~7 weeks. It touched installation, messaging, memory, skills, models, automations, apps, plugins, and security. Scale: ~933–987 contributors (sources disagree on the exact figure), 16,000+ pull requests.

- Official release notes: "v2026.8.1 (AKA OpenClaw 2.0)" — https://docs.openclaw.ai/releases/2026.8.1
- Release index: https://docs.openclaw.ai/releases
- Team retrospective: "OpenClaw 2.0, Accidentally" — https://openclaw.ai/blog/openclaw-2-accidentally
- Press coverage: https://cybersecuritynews.com/openclaw-2-0-released/ , https://www.infoq.com/news/2026/09/openclaw-2-release/ , https://www.marktechpost.com/2026/08/30/openclaw-releases-openclaw-2-0-guided-model-setup-575-ms-control-ui-startup-and-one-trust-boundary-per-gateway/amp/

**Important nuance for requirements:** "2.0" is **not** a new, frozen version string. CalVer numbering continues after it — NemoClaw's Sept 22, 2026 release notes reference bundling **OpenClaw 2026.9.1**, and open GitHub issues reference **2026.9.5** (https://docs.nvidia.com/nemoclaw/user-guide/openclaw/release-notes, https://github.com/openclaw/openclaw/issues/155340). "2.0" is best understood as *the release generation beginning at 2026.8.1* (post-SQLite-migration, post-unified-skills). PROJECT.md's framing ("drop CalVer, target 2.0") should be corrected in requirements to: **target `>=2026.8.1`**, not a single non-CalVer version identifier — reinforcing why this milestone already plans a version-canary smoke check.

### 2. Lifecycle/plugin hooks — THE critical question. Verdict: hooks did NOT get better at semantic classification; they DID get more numerous and more structurally documented; the specific veto bug is NOT confirmed fixed.

Full typed hook catalog confirmed at https://docs.openclaw.ai/plugins/hooks and https://docs.openclaw.ai/plugins/hooks/reference. Relevant facts:

- **`before_agent_finalize` still exists**, same three-way contract (`revise` / `finalize` / omit), still gated by `allowConversationAccess: true`, embedded runner still caps revisions at **3 per run** (was framed around `retry.maxAttempts` in the shipped plugin). No hook rename, no removal.
- **The revise-veto/drop failure mode is NOT confirmed fixed in 2.0.** A closely related bug — `before_agent_finalize` requesting a `revise` retry that itself independently produces `NO_REPLY`, silently dropping the turn — is tracked as **openclaw/openclaw#128314**, opened 2026-08-23 (one week before the 2.0 release) and **still open** as of this research, labeled P1, "needs maintainer review and product decision." A second, related-looking PR about tool-heavy turns losing completed work to a "replay veto" — **openclaw/openclaw#147611** — is **unmerged**, dated September 2026, targeting `main` (i.e., post-2.0 development, not yet shipped). Neither confirms the exact 2026.6.6 behavior this project already worked around is resolved. **Recommendation: do not revert to trusting `before_agent_finalize` revise as the sole compliance mechanism.** Keep the per-turn `before_prompt_build` injection that the project's own post-ship session already proved is the only reliable driver.
- **There is no `on_session_end` hook.** The real hook is **`session_end`** (observe-only, fires with a `reason` enum of nine values: `new`, `reset`, `idle`, `daily`, `compaction`, `deleted`, `shutdown`, `restart`, `unknown`). It cannot modify, block, or classify anything — it only tells you a session ended and why. This corrects the naming used in PROJECT.md's parked item **JCLASS-01** ("`on_session_end` classifier plugin").
- **There is no `pre_llm_call`/`post_llm_call` by that name.** The closest equivalents are:
  - `llm_input` / `llm_output` — observe-only, fire around each provider call; `llm_output` exposes the model's `usage` object and the resolved `contextTokenBudget`.
  - `model_call_started` / `model_call_ended` — observe-only, timing + outcome + a bounded request-id hash, **no raw prompt/response content**.
  - None of these can be used to derive **semantic** task-type (the 8-label taxonomy) or job classification — that is inherently a judgment call about intent, not a mechanical property these hooks expose. **The milestone's stated condition ("replace markers if and only if 2.0's hooks support code-side task-type/job classification") is NOT met by the lifecycle-hook set as documented.** Plan to port the marker architecture as-is for task-type/job *classification* specifically, not replace it — see the Anti-Features and Differentiators sections below for a different, more promising angle (`command-dispatch: tool`).
- **New and genuinely useful for the *attribution-plumbing* problem (not classification):** `subagent_spawned` (exposes `resolvedModel`, `resolvedProvider`, `childSessionKey`) and `subagent_ended` (exposes `targetSessionKey`, `targetKind`, `reason`, `runId`, `accountId`) are now typed, documented hooks. Today the skill discovers root-session/subagent relationships by scanning marker files across sessions (Phase 7, JROLL) via a Python heuristic. These hooks could let a plugin **structurally** record the session hierarchy the moment a subagent spawns, instead of inferring it after the fact — a real simplification candidate, not a full elimination of file-based state (the skill's cron runs out-of-process, so a hook handler would still need to write a small sidecar file for cron to read). Flagged as a differentiator, not a table-stakes item, and not proven — needs a live-host spike.
- All conversation-access hooks still require **`allowConversationAccess: true`** in the plugin's `hooks` config — same setting name as today, no successor found.

### 3. Native usage/token/cost telemetry — YES it exists now, and it is a differentiator to *consider*, not a reason to drop Revenium.

OpenClaw 2.0 ships real native usage/cost surfaces:
- Chat commands `/status`, `/usage tokens|full|cost`, `/context list|detail`.
- CLI: `openclaw status --usage`, `openclaw channels list` (normalized provider quota windows).
- An in-process diagnostic event, **`model.usage`** — "a trusted, in-process diagnostic event, not a JSONL log record" — carrying tokens, cost, duration, context, provider/model/channel, and session ids.
- A **bundled-but-disabled-by-default** `diagnostics-otel` plugin that exports traces/metrics/logs over OTLP/HTTP, including token usage, cost, context size, run duration, and queue depth.
- Docs: https://docs.openclaw.ai/reference/token-use , https://docs.openclaw.ai/gateway/opentelemetry , https://docs.openclaw.ai/gateway/opentelemetry/spans-and-events

**This does not replace this project.** It is local/session-scoped display plus an optional OTel export pipe — there is no OpenClaw-native budget-rule enforcement, no cross-session/root-session rollup product, no job/task attribution model, no tool registry, and no hosted metering API. Revenium remains the system of record for everything this skill does. The genuinely interesting angle is narrower: **`llm_output`'s `usage` payload or the OTel exporter could become an *alternate observation source* for completions**, reducing this skill's dependence on parsing raw session storage — see Differentiators.

### 4. Skill format — the AGENTS.md workaround is STILL necessary; 2.0 does not supersede it.

- Skills now discover/snapshot **eligible** skills **at session start** rather than being resolvable mid-session on demand: "OpenClaw snapshots eligible skills when a session starts and reuses that list until a refresh trigger." (https://docs.openclaw.ai/tools/skills) This changes *availability* semantics, not confirmed to change *per-turn context injection* of SKILL.md body content — that remains **UNVERIFIED** from docs alone.
- Separately, and decisively: the bootstrap-context files (`AGENTS.md`, `SOUL.md`, `IDENTITY.md`, `USER.md`, `BOOTSTRAP.md`, `MEMORY.md`) are injected **"on the first turn of a new session"** — https://docs.openclaw.ai/concepts/agent. **AGENTS.md is still session-start-only in 2.0, not re-injected every turn.** This is the exact root cause the v1.1 post-ship fix worked around (directives never reaching the agent on later turns). **2.0 does not fix this at the bootstrap-file layer.** The project's `before_prompt_build` per-turn injection plugin remains necessary — it is not superseded by anything documented in 2.0's skill system.
- `requires.bins` / `requires.anyBins` gating: unchanged as documented (`metadata.openclaw.requires.bins`, list of PATH binaries; `requires.anyBins` = at least one). Low risk — re-verify, don't expect to rebuild.
- Frontmatter parsing: "YAML first; falls back to single-line-only parser" (https://docs.openclaw.ai/tools/creating-skills). The project's existing single-line-JSON-metadata workaround (Key Decision: "OpenClaw silently drops multi-line/colon-space metadata") may no longer be strictly required if proper YAML frontmatter now parses correctly — worth testing on a live host, but keep the single-line form as the safe fallback since it's still explicitly supported.
- **New optional frontmatter fields**: `disable-model-invocation` (prevents the model from self-selecting a skill) and **`command-dispatch: tool`** (dispatches a skill directly as a tool call, bypassing model judgment entirely). This second field is the most promising lead in this entire research pass for the milestone's stated "replace markers if hooks support code-side classification" condition — not because it classifies anything, but because it could let marker-writing or guardrail-check invocation be dispatched deterministically rather than depend on the model choosing to comply. **Needs a dedicated live-host spike before the requirements phase decides the attribution-core question.**
- Full schema reference not fetched in depth this pass: https://github.com/openclaw/clawhub/blob/main/docs/skill-format.md — read during requirements/planning.

### 5. CLI surface changes.

- `openclaw plugins install/list/inspect/enable/disable`: install supports `--link`, `--force`, `--pin`, `--accept-capabilities`. Untrusted plugin sources now require `--force` **and** explicit capability consent shown pre-install (new security UX) — the project's existing `post-install.sh` already uses `--force` for idempotent installs, so this is a compatible pattern, not a break. Native plugins ship `openclaw.plugin.json` with an inline JSON Schema `configSchema`. (https://docs.openclaw.ai/cli/plugins)
- `allowConversationAccess`: confirmed unchanged name and still required per-hook for the conversation-access hook set. No successor/rename found.
- `openclaw skills install/update/verify/workshop list`: a new "Workshop" concept for agent-drafted skill proposals exists (`skill_proposal_evaluate`/`skill_proposal_changed`/`skill_changed` hooks) — not relevant to this skill's own install path, but worth knowing it exists.
- `openclaw doctor --fix`: **mandatory migration step.** Any host with pre-2.0 session state must run this (Gateway stopped, state backed up) to import `sessions.json` rows and hot transcript JSONL history into SQLite before restart. Once migrated, "the Gateway no longer reads JSON files directly." (https://docs.openclaw.ai/cli/doctor/sqlite-maintenance)
- `openclaw doctor session-sqlite {inspect, dry-run, import, validate, compact, recover}` with `--session-sqlite-all-agents`, `--json`, `--session-sqlite-agent` — diagnostic/maintenance surface for the new store.
- `openclaw sessions export-trajectory --session-key --output --json`: a **documented, versioned CLI export path** for a single session's data as JSON. This is the leading candidate to replace this skill's direct-file-parse approach — see Table Stakes item 2. (https://docs.openclaw.ai/cli/sessions)
- `openclaw status --usage`, `openclaw security audit`: minor new operator-facing commands, optional documentation polish.
- Numerous open GitHub issues (`#156060`, `#153654`, `#156382`, `#156145`, `#155340`) titled "Session SQLite migration recovery report" confirm the migration is real, in active production use, and has rough edges with an established recovery flow — worth knowing before writing install/upgrade docs.

### 6. Session/config layout — the single highest-impact, breaking finding of this entire research pass.

**CONFIRMED, HIGH severity:** OpenClaw 2.0 migrated session storage from **per-agent JSONL files** to a **per-agent SQLite database**, effective around 2026-09-01:

> "Runtime session rows and transcripts live in SQLite by default at `~/.openclaw/agents/<agentId>/agent/openclaw-agent.sqlite`... Since the migration, OpenClaw no longer writes any `.jsonl` files under `~/.openclaw/agents/`."
> — https://docs.openclaw.ai/reference/session-management-compaction/store , https://docs.openclaw.ai/cli/doctor/sqlite-maintenance

Legacy JSONL now lives (if at all) at the deprecated `~/.openclaw/agents/<agentId>/sessions/` path and is only relevant as one-time migration input via `openclaw doctor --fix`.

**This directly breaks the skill's core read path.** `report.sh` and `get-root-session-id.py` currently read `~/.openclaw/agents/main/sessions/*.jsonl` directly for completions, toolCalls, and root-session resolution. On a 2.0 host this path will not exist and will not update. **Nothing in this milestone works until this is solved — it is the true "table stakes #1" of the whole cut-over**, ahead of everything else in PROJECT.md's target-feature list.

Two remediation paths surfaced, both requiring a live-host spike before requirements lock in an approach:
- **(a) Read `openclaw-agent.sqlite` directly.** Schema is described only at a conceptual level (`sessionKey -> SessionEntry` key-value table; append-only tree-structured transcript events with `id`/`parentId`) — exact table/column names are **UNVERIFIED**, not published in docs. Risk: WAL/locking contention with a live Gateway process holding the DB open, and no documented cross-release schema-stability guarantee. This risk compounds badly for the NemoClaw path, where the file would be read over an SSHFS mount — SQLite over a network filesystem is a well-known reliability trap independent of OpenClaw.
- **(b) Use the documented CLI export surface instead** — `openclaw sessions export-trajectory --session-key <k> --output <path> --json` and/or `openclaw doctor session-sqlite inspect --json`. Slower per cron tick (subprocess invocation vs. direct file read) but far more likely to remain stable across point releases, and avoids the NemoClaw SSHFS/SQLite-locking risk entirely by shifting the read into an in-sandbox/in-Gateway CLI call. **This is the recommended default** pending a live-host timing/reliability spike.

Session/agent id semantics otherwise appear conceptually stable (root vs. subagent session hierarchy still exists; `subagent_spawned`/`subagent_ended` now formalize it structurally) but exact identifier-format continuity with the 2026.5–2026.6 CalVer line used by `get-root-session-id.py` is **UNVERIFIED** — confirm on a live 2.0 host. One confirmed unrelated change: `/dock-*` channel-docking commands were removed and `resetByType` now uses `direct` instead of legacy `dm` — low relevance to this skill. (https://docs.openclaw.ai/concepts/session)

---

## Feature Landscape

### Table Stakes (must-have for the cut-over)

| Feature | Why Required | Complexity | Notes |
|---------|--------------|------------|-------|
| Port session read path off JSONL onto SQLite/CLI export | Skill cannot meter, attribute, or resolve root sessions at all on 2.0 without this — `report.sh` and `get-root-session-id.py` read `.jsonl` directly today | HIGH | Depends on: `report.sh`, `get-root-session-id.py`, JROLL (Phase 7), tool-registry scan (Phase 10), guardrail-event correlation (Phase 9). Recommend `openclaw sessions export-trajectory`/`openclaw doctor session-sqlite inspect --json` over raw SQLite file access; needs a live-host spike to pick and time the approach |
| Target `>=2026.8.1`, not a single frozen "2.0" string | "2.0" is a branding label for a release generation that keeps incrementing CalVer (2026.9.1 confirmed) | LOW | Corrects PROJECT.md framing; feeds directly into the milestone's already-planned version-canary item |
| Add/require `openclaw doctor --fix` in install/upgrade path | Any pre-2.0 host must migrate session state into SQLite before the Gateway will read its history; skipping this silently breaks metering with no obvious symptom | MEDIUM | Applies to both `install.sh`/`post-install.sh` (standalone) and `post-install-nemoclaw.sh` upgrade scenarios |
| Re-verify `requires.bins` / SKILL.md loading under the new eager, session-start skill snapshot model | Skills now snapshot "eligible skills" at session start rather than resolving on demand — behavior change, low risk but unverified for this skill specifically | LOW–MEDIUM | Depends on Phase 1 (SKAF-01..04); likely just a re-test, not a rebuild |
| Re-verify hook registration (`allowConversationAccess`, `before_agent_finalize`, `before_prompt_build`, `before_tool_call`) under 2.0's plugin capability-consent UX | Plugin install now shows capability/source/version consent before enabling; hook names and permission flag are unchanged but the install-time UX around them changed | MEDIUM | Depends on Phase 11 (`revenium-marker-gate` plugin), the post-ship `before_prompt_build` directive plugin, `post-install.sh` §7c |
| Port NemoClaw host-side SSHFS metering loop off JSONL reads | Phase 14's design (`NCMETER-01`) explicitly avoids per-tick `nemoclaw exec` by reading JSONL over the mount — that assumption breaks with SQLite storage | HIGH | Depends on Phase 13 (provisioning), Phase 14 (host-cron mount loop); likely forces a design change back toward in-sandbox CLI invocation (`nemoclaw exec` + `openclaw sessions export-trajectory`), which the milestone should explicitly revisit rather than silently port |
| Confirm NemoClaw's OpenClaw-2.0-line support | NemoClaw's Sept 22, 2026 release notes bundle OpenClaw 2026.9.1, implying 2.0-line support exists, but no explicit "OpenClaw 2.0" or SQLite-migration mention was found in NemoClaw's own release notes | LOW (verification only) | Blocks the entire NemoClaw/OpenShell install path (Phases 12–16) if unconfirmed on a live host |
| Version canary / hook-contract smoke check | Already a named milestone goal; this research reinforces why — hook names are stable but revise/veto reliability is not confirmed, and CalVer keeps moving under the "2.0" label | MEDIUM | New component; hooks into install + cron; no direct code dependency on existing components beyond needing to know which hook/behavior to probe |

### Differentiators (2.0 capabilities worth adopting)

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| `command-dispatch: tool` SKILL.md frontmatter field | Dispatches a skill directly as a tool call, bypassing model judgment — the most promising lead found for the milestone's "replace markers with code-side mechanism" condition, though it dispatches rather than classifies | HIGH | Needs a dedicated live-host spike before the requirements phase decides the attribution-core question; not proven, not documented in depth in the pages fetched this pass |
| `subagent_spawned` / `subagent_ended` hooks for root-session hierarchy | Structurally records parent/child session relationships the moment a subagent spawns, instead of inferring it after the fact via cross-session marker scanning | MEDIUM–HIGH | Would replace/simplify Phase 7's `root_aid` cross-session resolver; still requires a small hook-written sidecar file since the skill's cron runs out-of-process — not a full elimination of file-based state |
| `openclaw sessions export-trajectory` as the primary session-read implementation | Documented, versioned CLI surface vs. hand-rolled SQLite schema parsing; avoids WAL/locking and cross-release schema-fragility risk | MEDIUM | Directly implements the recommended choice in Table Stakes item 1; especially valuable for the NemoClaw SSHFS path where raw SQLite access is risky |
| `llm_output` usage hook / bundled `diagnostics-otel` OTLP export as a corroborating completion-observation source | Native, in-process token/cost/timing data could reduce reliance on parsing session storage for guardrail-event/tool-event correlation | HIGH | New dependency chain: requires enabling a disabled-by-default plugin and building an OTLP receiver/mapper back to root-session/task-type; does not replace Revenium's API surface (budget rules, jobs, tool registry) — recommend deferring to a future milestone rather than this cut-over |
| Plugin capability-consent / `--force` UX alignment | 2.0's install-time capability consent screen matches the project's existing idempotent `--force` install pattern | LOW | No action beyond re-verification; a nice signal the existing pattern already fits 2.0's security model |
| `openclaw security audit` CLI command | New operator diagnostic worth surfacing in troubleshooting docs | LOW | Optional polish, no dependency |

### Anti-Features (2.0 things to deliberately NOT adopt this milestone)

| Feature | Why It Looks Appealing | Why Problematic | Alternative |
|---------|------------------------|------------------|-------------|
| Treating native OpenClaw usage/cost telemetry as a Revenium replacement | 2.0 now has real token/cost tracking (`/usage`, `model.usage` event, OTel export) | It's session/local-scoped display plus an optional OTel pipe — no budget-rule enforcement, no cross-session rollup, no job/task attribution model, no tool registry, no hosted metering API | Keep Revenium as the system of record this milestone; revisit OTel as a corroborating signal in a future milestone |
| Reverting to `before_agent_finalize` revise as the sole compliance mechanism | It's a real, typed hook with clean revise/finalize semantics | The exact class of bug this project already worked around (revise silently dropped/vetoed on certain turns) has an open, unresolved GitHub issue (`#128314`, opened days before the 2.0 release, still open) and an unmerged related PR (`#147611`) — not confirmed fixed | Keep the per-turn `before_prompt_build` injection mitigation already proven in production |
| Pinning to a single fixed "OpenClaw 2.0" version string | Feels like the natural reading of "cut over to 2.0" | CalVer numbering continues past 2026.8.1 (2026.9.1, 2026.9.5 observed); a fixed pin will fall behind or false-negative on the version canary | Target `>=2026.8.1` plus the version-canary smoke check |
| Reading `openclaw-agent.sqlite` directly as the first implementation choice | Feels faster than shelling out to a CLI every cron tick | Undocumented table/column names, no compatibility guarantee across releases, WAL/locking risk — especially severe over the NemoClaw SSHFS mount (SQLite-over-network-filesystem is a known reliability trap) | Default to `openclaw sessions export-trajectory` / `openclaw doctor session-sqlite inspect --json`; only fall back to raw file access if a live-host spike proves the CLI path too slow for per-minute polling |
| Skipping `openclaw doctor --fix` on upgrade | Upgrades "should just work" | Existing v1.4-era hosts have pre-2.0 JSONL session state; skipping the migration means the Gateway silently never reads that history, and metering appears to "just stop" with no obvious cause | Make the migration step explicit and gated in install/upgrade docs and scripts |

## Feature Dependencies

```
[SQLite/CLI session read path]
    └──requires──> [live-host schema/CLI-timing spike]

[report.sh port]
    └──requires──> [SQLite/CLI session read path]

[get-root-session-id.py port]
    └──requires──> [SQLite/CLI session read path]
    └──enhances──> [subagent_spawned/ended hook sidecar]  (differentiator, optional)

[NemoClaw host-side metering loop port (Phase 14)]
    └──requires──> [SQLite/CLI session read path]
    └──requires──> [NemoClaw OpenClaw-2.0-line confirmation]

[hook re-registration re-verify]
    └──requires──> [allowConversationAccess re-verify]

[version canary]
    └──enhances──> [all table-stakes items above]  (detects drift early)

[attribution-core replacement via lifecycle hooks]
    └──conflicts──> [keeping agent-written markers]
    (research finding: this milestone's own stated condition is NOT met by the
     documented lifecycle-hook set — session_end/agent_end/llm_output/model_call_ended
     are observe-only and cannot classify. Port markers as-is for classification.)

[attribution-core hardening via command-dispatch: tool]
    └──requires──> [dedicated live-host spike]
    (distinct from the hooks question above — a genuinely new, unproven lead)
```

### Dependency Notes

- **Session read path is the root dependency for almost everything else.** Every existing component that touches completions, tool calls, or root-session resolution (`report.sh`, `get-root-session-id.py`, Phase 7 JROLL, Phase 9 guardrail-event correlation, Phase 10 tool-event scan, Phase 14 NemoClaw host-cron loop) sits downstream of this one decision. Resolve it first; sequence the roadmap so this is Phase 1 of the milestone, not a late-phase cleanup.
- **Attribution-core replacement conflicts with keeping markers**, but the research does not support flipping that switch via lifecycle hooks as originally hoped — the milestone's own conditional ("if and only if 2.0's hooks support it") resolves to **no** for classification, based on what's documented. The `command-dispatch: tool` frontmatter field is a separate, unproven lead worth its own spike, not a hooks-API answer.
- **NemoClaw path has a compounded dependency**: it needs both the general session-read-path fix and independent confirmation that NemoClaw itself supports the 2.0 generation — if either is unconfirmed, the NemoClaw portion of the milestone should shrink or slip, per PROJECT.md's own stated open risk.

## MVP Definition

Framed for an infrastructure cut-over rather than a new product — "MVP" here means the minimum required to prove the skill functions end-to-end on a 2.0 host.

### Launch With (cut-over must-ship)

- [ ] Session read path ported off JSONL — nothing else works without this
- [ ] `openclaw doctor --fix` migration step added to install/upgrade
- [ ] Hook registration re-verified end-to-end on a live 2.0 host (not just docs-confirmed)
- [ ] Version targeting corrected to `>=2026.8.1` with a version-canary smoke check
- [ ] NemoClaw 2.0-line support explicitly confirmed or the NemoClaw scope explicitly shrunk

### Add After Validation (justified for this milestone once the above is proven)

- [ ] `openclaw sessions export-trajectory` adopted as the primary read implementation (vs. raw SQLite) if the timing spike supports it
- [ ] NemoClaw host-side metering loop redesigned around the confirmed read path

### Future Consideration (defer past this milestone)

- [ ] `subagent_spawned`/`subagent_ended` hook-based root-session resolution (replaces Phase 7 heuristic)
- [ ] `command-dispatch: tool` spike for attribution-core hardening
- [ ] `diagnostics-otel` / `llm_output` usage as a corroborating completion-observation source

## Feature Prioritization Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|----------------------|----------|
| Session read path port (SQLite/CLI) | HIGH | HIGH | P1 |
| `openclaw doctor --fix` migration step | HIGH | MEDIUM | P1 |
| Hook re-registration re-verify | HIGH | MEDIUM | P1 |
| Version targeting correction + canary | HIGH | MEDIUM | P1 |
| NemoClaw 2.0-line confirmation | HIGH | LOW | P1 |
| NemoClaw host-metering-loop redesign | HIGH | HIGH | P1 (blocks NemoClaw path) |
| `export-trajectory` adoption over raw SQLite | MEDIUM | MEDIUM | P2 |
| `subagent_spawned`/`ended` root-session hook | MEDIUM | HIGH | P3 |
| `command-dispatch: tool` attribution spike | MEDIUM–HIGH (unproven) | HIGH | P3 |
| `diagnostics-otel`/`llm_output` corroboration | LOW–MEDIUM this milestone | HIGH | P3 |

**Priority key:**
- P1: Must have for the cut-over to work at all
- P2: Should have, strengthens the cut-over's stability
- P3: Nice to have, candidate for a future milestone

## Competitor Feature Analysis

Not applicable in the usual sense — this is a platform-version cut-over, not a competitive feature landscape. The relevant "competitor" comparison is OpenClaw 2.0's own native telemetry vs. this skill's Revenium-backed metering, covered in Critical Finding 3 and the Anti-Features table above.

## Sources

**Official OpenClaw documentation (primary, fetched directly):**
- https://docs.openclaw.ai/releases/2026.8.1
- https://docs.openclaw.ai/releases
- https://docs.openclaw.ai/plugins/hooks
- https://docs.openclaw.ai/plugins/hooks/prompt-and-session
- https://docs.openclaw.ai/plugins/hooks/reference
- https://docs.openclaw.ai/automation/hooks
- https://docs.openclaw.ai/reference/token-use
- https://docs.openclaw.ai/reference/session-management-compaction/store
- https://docs.openclaw.ai/concepts/session
- https://docs.openclaw.ai/concepts/agent
- https://docs.openclaw.ai/reference/templates/AGENTS
- https://docs.openclaw.ai/tools/skills
- https://docs.openclaw.ai/tools/creating-skills
- https://docs.openclaw.ai/cli/plugins
- https://docs.openclaw.ai/cli/doctor/sqlite-maintenance
- https://docs.openclaw.ai/cli/sessions
- https://docs.openclaw.ai/gateway/opentelemetry
- https://docs.openclaw.ai/gateway/opentelemetry/spans-and-events (referenced via search summary, not independently re-fetched — treat as MEDIUM confidence)

**OpenClaw team communication:**
- https://openclaw.ai/blog/openclaw-2-accidentally

**Press coverage (secondary, corroborating):**
- https://cybersecuritynews.com/openclaw-2-0-released/
- https://www.infoq.com/news/2026/09/openclaw-2-release/
- https://www.marktechpost.com/2026/08/30/openclaw-releases-openclaw-2-0-guided-model-setup-575-ms-control-ui-startup-and-one-trust-boundary-per-gateway/amp/

**GitHub (primary, fetched directly):**
- https://github.com/openclaw/openclaw/issues/128314 — open, unresolved `before_agent_finalize` retry/NO_REPLY drop
- https://github.com/openclaw/openclaw/pull/147611 — unmerged, tool-heavy turn "replay veto" fix
- https://github.com/openclaw/openclaw/pull/126618 — unmerged, Tool Search wrapping native `read`/`exec` (possible B-05-adjacent fix, NOT confirmed shipped)
- https://github.com/openclaw/clawhub/blob/main/docs/skill-format.md — referenced, not deeply fetched this pass; read during requirements/planning
- Session-SQLite-migration recovery reports (evidence the migration is real and in production use): https://github.com/openclaw/openclaw/issues/156060 , /153654 , /156382 , /156145 , /155340

**NemoClaw (primary, fetched directly):**
- https://docs.nvidia.com/nemoclaw/user-guide/openclaw/release-notes — confirms OpenClaw 2026.9.1 bundled as of 2026-09-22; does **not** explicitly mention "OpenClaw 2.0" or the SQLite migration by name
- https://github.com/NVIDIA/NemoClaw/issues/6691 — referenced via search only, not deeply fetched; NemoClaw's own candidate-compatibility test harness for OpenClaw/OpenShell version pairs

**UNVERIFIED items requiring a live 2.0 host before requirements lock in:**
- Exact `openclaw-agent.sqlite` table/column schema
- Whether SKILL.md body content is injected into every turn's context or only when the model chooses to invoke it
- Whether `openclaw sessions export-trajectory` is fast/stable enough for per-minute cron polling
- Whether the exact 2026.6.6 `before_agent_finalize` revise-veto-on-tool-using-turns behavior is present, changed, or absent on 2026.8.1+
- Whether `get-root-session-id.py`'s session/agent id parsing assumptions still hold under the new store
- Whether `command-dispatch: tool` can be used to force deterministic marker-writing/guardrail-check dispatch

---
*Feature research for: OpenClaw 2.0 cut-over (Revenium OpenClaw skill, v2.0 milestone)*
*Researched: 2026-09-23*
