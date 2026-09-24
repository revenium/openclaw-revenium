# Architecture Research — OpenClaw 2.0 Cut-Over

**Domain:** Integration architecture for migrating an existing OpenClaw skill (bash + a TypeScript conversation-hook plugin) onto a new OpenClaw runtime
**Researched:** 2026-09-23
**Confidence:** MEDIUM overall — HIGH on "does 2.0 exist" and "what changed structurally"; MEDIUM/LOW on exact plugin-permission and session-export mechanics, which should be re-verified live against a provisioned 2.0 host before Phase 1 execution (the proof bar this milestone already requires).

---

## 0. CRITICAL FIRST FINDING — Does OpenClaw 2.0 exist?

**Yes, confirmed with citations — but it is not what "2.0" usually implies, and this changes how the milestone's "2.0-only, drop CalVer" framing should be read.**

- OpenClaw shipped a release on **2026-08-30** versioned **`2026.8.1`**, which the project itself branded "OpenClaw 2.0" in its own announcement blog post and release notes. [[docs.openclaw.ai/releases/2026.8.1]](https://docs.openclaw.ai/releases/2026.8.1) [[openclaw.ai/blog/openclaw-2-accidentally]](https://openclaw.ai/blog/openclaw-2-accidentally) [[marktechpost.com]](https://www.marktechpost.com/2026/08/30/openclaw-releases-openclaw-2-0-guided-model-setup-575-ms-control-ui-startup-and-one-trust-boundary-per-gateway/amp/) [[cybersecuritynews.com]](https://cybersecuritynews.com/openclaw-2-0-released/) [[infoq.com]](https://www.infoq.com/news/2026/09/openclaw-2-release/)
- **"2.0" is a marketing nickname for a CalVer release, not a new versioning line.** OpenClaw kept shipping CalVer releases after it: `2026.8.2`, `2026.9.1`, `2026.9.2`, `2026.9.3`, `2026.9.4`, and `2026.9.5` (the latest as of this research, 2026-09-23) all exist and are documented as ordinary point releases building on the "2.0" base. [[docs.openclaw.ai/releases]](https://docs.openclaw.ai/releases)
- **Implication for the milestone's "2.0 only, drop CalVer" decision:** there is no separate semver `2.x` line to gate on. The only meaningful gate is **"CalVer ≥ `2026.8.1`"** (the release that introduced the SQLite session migration, the plugin-permission changes, and the other breaking changes below). "Drop CalVer support" should be read as *"drop support for CalVer releases prior to `2026.8.1`,"* not "CalVer no longer applies." The version-gating logic in §6 is written against this corrected understanding. **The requirements/roadmap should restate the target as `>= 2026.8.1` explicitly**, and probably track the latest `2026.9.x` patch as the actual live-validation target per the milestone's proof bar (a host "actually running 2.0" most naturally means the newest available `2026.9.x`, not the first `2026.8.1` cut).
- This is treated as the load-bearing fact for the rest of this document. Every subsequent claim about 2.0 behavior is sourced; anything not directly confirmed in official docs is labeled **UNVERIFIED**.

---

## 1. Existing Architecture — Ground Truth From the Codebase

Read directly (not from PROJECT.md) at `/Users/johndemic/Development/projects/revenium/openclaw-revenium`:
`scripts/install.sh`, `scripts/post-install.sh`, `scripts/post-install-nemoclaw.sh`, `scripts/report.sh`, `scripts/guardrail-check.sh`, `scripts/common.sh`, `scripts/cron.sh`, `SKILL.md`, `plugin/src/index.ts`, `plugin/src/gate.js`, `plugin/openclaw.plugin.json`, `plugin/package.json`, `plugin-nemoclaw/src/index.ts`, `plugin-nemoclaw/openclaw.plugin.json`, `plugin-nemoclaw/package.json`.

### 1.1 Two install paths, one dispatcher

```
scripts/install.sh (dispatcher, D-03 routing)
  ├── standalone → scripts/post-install.sh
  │      → Docker sandbox bind mounts, AGENTS.md injection, revenium-marker-gate plugin
  └── NemoClaw   → scripts/post-install-nemoclaw.sh
         → egress presets, in-sandbox CLI, SSHFS mount, revenium-enforcement plugin,
           host-side cron (install-nemoclaw-cron.sh → cron.sh with OPENCLAW_HOME=<mount>)
```

Both paths converge on the **same three shared scripts** (`cron.sh`, `report.sh`, `guardrail-check.sh`) — standalone runs them via `OPENCLAW_HOME=~/.openclaw` (host), NemoClaw runs the identical, unmodified scripts via `OPENCLAW_HOME=<SSHFS mount>` (host, reading sandbox state through the mount). This "one shared metering core, two provisioning shells" design is the single most important existing invariant and should be preserved through the cut-over.

### 1.2 Current version coupling (confirmed in source, not assumed)

Both plugin manifests already declare a floor:

```json
"peerDependencies": { "openclaw": ">=2026.6.1" }
```
(`plugin/package.json:14`, `plugin-nemoclaw/package.json:14`)

And live-validation notes in `PROJECT.md`/`SKILL.md` history confirm the project has already tracked runtime drift closely: Gate A/B probes were rewritten for OpenClaw `2026.5.22` output-shape changes, and `2026.6.6` silently vetoed `before_agent_finalize` revise actions on tool-using turns, which is *why* `before_prompt_build` injection (not the finalize-revise loop) is today's actual compliance mechanism (`plugin/src/gate.js:79-96`, `plugin-nemoclaw/src/index.ts:49-63`). This project has direct, hard-won evidence that OpenClaw's hook *behavior* (not just its version number) drifts between CalVer points — which is exactly the risk this milestone's "version canary" item is meant to catch going forward.

### 1.3 Session JSONL contract as currently implemented

`scripts/report.sh` reads `${OPENCLAW_HOME}/agents/main/sessions/*.jsonl` directly (`report.sh:28`, `common.sh:68`) with `jq`/`python3`, tracking a byte/line **offset** per session file in `revenium-offsets.json` (`report.sh:33,176-212`). It parses:
- `.type=="message"`, `.message.role`, `.message.usage.{input,output,cacheRead,cacheWrite,totalTokens}` (and the Anthropic snake_case fallback), `.message.model`, `.message.provider`, `.message.api`, `.message.stopReason`, `.id`, `.parentId`, `.timestamp` (`report.sh:783-836`)
- `.message.content[].type=="toolCall"` / a paired `role=="toolResult"` message keyed by `toolCallId`, for the tool-registry/tool-event scan (`report.sh:1156-1227`, added Phase 10)

This is a **direct on-disk file format dependency** — the single most exposed surface to a runtime upgrade, and exactly what question 2 asks about.

### 1.4 Plugin architecture (both are structurally identical; only the injected content differs)

Both `plugin/` (standalone) and `plugin-nemoclaw/` (`revenium-enforcement`) are hand-built TypeScript with **committed pre-built `dist/`** (no build step at install time — `plugin/package.json` / `plugin-nemoclaw/package.json` `scripts.build: "tsc && ..."` runs only at dev time). Both register the same four hooks via `definePluginEntry` from `openclaw/plugin-sdk/plugin-entry`:

| Hook | Purpose in this codebase | Conversation hook? |
|---|---|---|
| `before_prompt_build` | Prepend metering/guardrail directive text every turn — **the actual compliance mechanism today** | No (per current 2.0 docs — see §3) |
| `before_tool_call` | Observe `exec`/`bash` (and, since 2026-06-13, any non-read-only tool) to mark a run "substantive" | No |
| `before_agent_finalize` | Return a bounded `revise` action if substantive + unmarked (now largely inert on tool-using turns per the `2026.6.6` veto, but still registered as a backstop) | **Yes** — requires `allowConversationAccess: true` |
| `agent_end` | Clear per-run tracking state / delete run-state file | **Yes** — requires `allowConversationAccess: true` |

Both manifests are minimal `openclaw.plugin.json` (`id`, `name`, `description`, `version`, `activation`, `contracts.tools: []`, `configSchema`) plus `package.json` `openclaw.extensions: ["./dist/index.js"]`. Install/enable is done imperatively by the install scripts: `openclaw plugins install <dir> --force` then `openclaw config patch --stdin` with `{plugins:{entries:{"<id>":{enabled:true,hooks:{allowConversationAccess:true}}}}}`, followed by a gateway restart (standalone) or `nemoclaw <sandbox> recover` (NemoClaw).

---

## 2. Which components break, modify, or carry over — by filename

| File | Status on 2.0 | Why |
|---|---|---|
| `scripts/install.sh` | **Modify** | Add the version-gate check (§6) before dispatch; routing logic (D-03) itself is runtime-version-agnostic and carries over |
| `scripts/post-install.sh` | **Modify** | §7c plugin-install/patch block needs the `allowPromptInjection` addition (§3) and the `plugins inspect` gate text may need to switch to `--json` parsing (§3); Docker sandbox bind-mount logic (§3 of the script) is UNVERIFIED against 2.0's security changes (see §5) and needs a live smoke test, not a rewrite by assumption |
| `scripts/post-install-nemoclaw.sh` | **Modify (significant)** | Gate A/B parsing already brittle to `openclaw agent --json`/`plugins inspect` output-shape drift (documented in-repo as a `2026.5.22` casualty); NemoClaw's own `0.0.127`/`0.0.128` releases moved plugin/gateway lifecycle ownership *back* to OpenClaw and retired the device-auth bypass (§5) — several `nemoclaw exec ... openclaw ...` indirections may now have a direct-`openclaw`-on-host equivalent |
| `scripts/report.sh` | **Modify (core rewrite of the session-read path)** | Direct JSONL parsing of `agents/main/sessions/*.jsonl` is reading a file that 2.0 treats as an **archived migration artifact, not a runtime source** (§4). Everything downstream of session-line acquisition (marker correlation, job lifecycle, tool-event scan, offset tracking) is decoupled from the read mechanism and can carry over close to as-is once line acquisition is fixed |
| `scripts/guardrail-check.sh` | **Unchanged** (high confidence) | Talks only to the `revenium` CLI and `guardrail-status.json`; touches `SESSIONS_DIR` only to find the newest session id for `--agent` attribution (`guardrail-check.sh:494-498`) — same fix needed there as in `report.sh`, but otherwise zero OpenClaw-runtime coupling |
| `scripts/common.sh` | **Modify (small, contained)** | `SESSIONS_DIR` constant + `OPENCLAW_HOME` sandbox-normalization logic is the natural place to also resolve/gate the SQLite path (§4); everything else (`STATE_DIR`, ledgers, `get_root_session_id` wrapper) is unaffected |
| `scripts/cron.sh` | **Unchanged** | Pure process orchestration (flock, timeout, calls `report.sh`/`guardrail-check.sh`); no OpenClaw API surface at all |
| `scripts/get-root-session-id.py` | **Modify** | Currently walks `childSessionKey` across JSONL files under `SESSIONS_DIR` — same underlying data-source problem as `report.sh` |
| `scripts/write-marker.sh` / `write-job-marker.sh` | **Unchanged if Branch B (port as-is), retired if Branch A** — see §5 | These are agent-invoked writers into `${SKILL_DIR}/markers/{sid}.jsonl`, a **skill-owned** file, not an OpenClaw-owned file — untouched by the SQLite migration either way |
| `SKILL.md` | **Modify (compliance-mechanism wording)**, **retired sections if Branch A** | The HALT CHECK / TASK CLASSIFICATION / JOB DECLARATION sections describe the agent-self-report contract; if Branch A is taken, these sections shrink to "the platform handles this," but the guardrail HALT CHECK (reads `guardrail-status.json`) stays regardless because guardrail enforcement is not an OpenClaw hook concern |
| `plugin/` (`revenium-marker-gate`) | **Modify + rebuild `dist/`** | See §3 |
| `plugin-nemoclaw/` (`revenium-enforcement`) | **Modify + rebuild `dist/`** | See §3 and §5 |
| `~/.openclaw/workspace/AGENTS.md` injection (`post-install.sh` §7/§7b) | **Unchanged mechanism, content unchanged if Branch B; retired if Branch A** | AGENTS.md is a workspace file the agent reads on every turn — this is not an OpenClaw plugin-API surface, so the injection mechanism itself is 2.0-agnostic |
| `scripts/setup-guardrails.sh`, `clear-halt.sh`, `install-cron.sh`, `uninstall-cron.sh` | **Unchanged** | Talk only to the `revenium` CLI / cron / `config.json`; no OpenClaw coupling |
| `scripts/install-nemoclaw-cron.sh`, `uninstall-nemoclaw-cron.sh`, `nemoclaw-cron-tick.sh` | **Unchanged, modulo NemoClaw's own CLI changes** | SSHFS mount + crontab management; coupling is to `nemoclaw`, not `openclaw`, directly — see §5 for whether `nemoclaw share mount` itself is stable |
| `scripts/probe-host-compat.sh` | **Unchanged** | OS/Docker/RAM preflight, no OpenClaw coupling |

**Bottom line on Q1:** the break is concentrated and structural, not diffuse — it is almost entirely **"how do I read agent session/usage data"** (`report.sh`, `get-root-session-id.py`, `common.sh`'s `SESSIONS_DIR`, and `guardrail-check.sh`'s one `ls` of the sessions dir) plus **"how do I register a conversation-hook plugin"** (`allowConversationAccess`/`allowPromptInjection`, manifest peer version, gate-script output parsing). Everything downstream of session-line acquisition — ledgers, offset tracking, job lifecycle, tool registry, guardrail polling, cron orchestration, the `revenium` CLI calls themselves — is untouched by the 2.0 change set as documented.

---

## 3. Session JSONL contract — what changed, and what report.sh needs to become

**HIGH confidence, directly sourced from OpenClaw's own docs and its migration-tooling GitHub issues.**

- `2026.8.1` ("2.0") moved session storage from per-session JSONL files to **SQLite**: *"Runtime session rows and transcripts live in SQLite, by default at `~/.openclaw/agents/<agentId>/agent/openclaw-agent.sqlite`."* [[docs.openclaw.ai/cli/doctor/sqlite-maintenance]](https://docs.openclaw.ai/cli/doctor/sqlite-maintenance)
- The **legacy JSONL files at `~/.openclaw/agents/<agent>/sessions/*.jsonl` are archived, not read at runtime**, after a one-time migration: *"Hot transcript JSONL files are imported and archived after successful import; archive-tier JSONL files remain support artifacts, not runtime fallbacks."* and *"runtime reads use only canonical SQLite state."* [[docs.openclaw.ai/cli/doctor/sqlite-maintenance]](https://docs.openclaw.ai/cli/doctor/sqlite-maintenance)
- **This confirms report.sh's core read path is dead on arrival on a real `2026.8.1`+ host.** `SESSIONS_DIR="${OPENCLAW_HOME}/agents/main/sessions"` (`common.sh:68`) will, after the one-time migration runs, contain only stale archived files that stop receiving new writes — `report.sh` would silently stop seeing new completions with no error (fail-open behavior masking a total metering blackout). This is the single highest-priority break in the whole cut-over.
- **No direct JSONL-shaped export replacement is confirmed to exist.** I found and then had to retract a plausible-sounding `openclaw sessions export <session-key> > session.jsonl` command surfaced by an AI-generated web summary; fetching the actual CLI reference doc (`docs/cli/sessions.md`, both via `docs.openclaw.ai/cli/sessions` and the raw GitHub source) shows the real `openclaw sessions` subcommand family is: `list`, `archive`, `delete`, `tail`, `export-trajectory`, `cleanup`, `compact` — **there is no plain `export` subcommand.** [[docs.openclaw.ai/cli/sessions]](https://docs.openclaw.ai/cli/sessions) [[github.com/openclaw/openclaw/blob/main/docs/cli/sessions.md]](https://github.com/openclaw/openclaw/blob/main/docs/cli/sessions.md) — **the earlier claim is explicitly wrong and should not be trusted; treat it as UNVERIFIED-and-refuted.**
- What **does** exist and is confirmed:
  - `openclaw sessions --all-agents --json` / `openclaw sessions list --json` — lists session rows with `agentId`, `key`, `model`, and (per the docs' description of the human table) approximate token counts, but the documented JSON shape shown (`docs/cli/sessions.md`) is metadata-level (`key`, `model`, `color`), **not** proven to include per-message `usage`/`stopReason`/`toolCall` detail. UNVERIFIED whether `--json` carries full per-message granularity.
  - `openclaw sessions export-trajectory --session-key "<key>" --workspace .` — writes a bundle into `.openclaw/trajectory-exports/<dir>/` on disk, used by the `/export-trajectory` slash command. This is a real, confirmed export mechanism, but it is designed for human bug-report bundling (via an *owner-approved exec request*), not a per-minute cron-polled telemetry feed — schema, incrementality, and approval-gating are all open questions.
  - A `session_end` hook payload carries `sessionId`, `sessionKey`, `messageCount`, `durationMs`, `reason`, `sessionFile`, `transcriptArchived` — but an **open, unresolved GitHub issue confirms the payload carries no message content for SQLite-backed sessions, and `sessionFile` points at a JSONL path that no longer exists**: *"un-retained turns are silently lost on `/new` and `/reset`"* is the reported real-world impact on a comparable third-party plugin (`@vectorize-io/hindsight-openclaw`). [[github.com/openclaw/openclaw/issues/155696]](https://github.com/openclaw/openclaw/issues/155696) This is direct evidence that **OpenClaw's own hook contract for reading transcript content is currently broken/incomplete post-migration**, not just a documentation gap.
  - `openclaw doctor --session-sqlite inspect [--session-sqlite-all-agents] [--json]` exists for **migration diagnostics**, not for ongoing telemetry consumption; its output schema is undocumented in the fetched pages.

**Recommendation (what `report.sh` needs to become) — three candidate designs, in order of preference, to be validated on a live 2.0 host in Phase 1 before committing:**

1. **Preferred, if it survives live verification: read the SQLite file directly** (`~/.openclaw/agents/<agentId>/agent/openclaw-agent.sqlite`) with `sqlite3`/Python's stdlib `sqlite3` module instead of `jq` over JSONL. This preserves the "poll every cron tick, track an offset" model almost exactly — swap the offset unit from "line count in a JSONL file" to "row id / rowid high-water-mark in a SQLite table," which is a *more* natural incremental-read primitive than the current line-offset hack. Risk: the schema is **not publicly documented** (no `docs.openclaw.ai` page enumerates table/column names); this requires either (a) inspecting a live `2026.9.x` host's actual `.sqlite` file with `sqlite3 .schema`, or (b) treating this as an unsupported/unstable internal format subject to change without notice (the same risk direct-JSONL-parsing already carried, arguably worse since there's no doc contract at all). **A version canary (§8) must assert this schema hasn't drifted, tick-over-tick.**
2. **Fallback: `openclaw sessions export-trajectory`** per session, parsing whatever schema the bundle contains, run once per new/updated session per cron tick. Requires confirming (live) that trajectory-export bundles carry token usage, model, stopReason, and toolCall detail at the fidelity `report.sh` needs — the docs only confirm a Markdown "summary.md" + "metadata.json" + "transcript.jsonl" style bundle exists via the *adjacent* `openclaw transcripts path <session> --transcript` command (a different feature — meeting transcripts, not agent chat sessions — so do not conflate the two even though the CLI naming is confusingly similar). Also needs confirming the "owner-approved exec request" gating referenced in the docs doesn't require interactive approval when invoked from an unattended cron job.
3. **Last resort, and the one to explicitly avoid committing to without a live host:** treat the archived `sessions/*.jsonl` files as still readable for a **transition window** (the docs mention "archive-tier JSONL files remain support artifacts") and accept that new completions never land there after the one-time migration — i.e., this reads only pre-migration history and gives *zero* live metering, which does not meet the milestone's proof bar. Included here only to name it and rule it out.

**Decision point for the roadmap:** this is a genuine "spike before plan" item. The plan should not lock in option 1 vs 2 without a Phase 0/1 spike against a real `2026.9.x` host that (a) inspects the live SQLite schema with `sqlite3 <path> .schema`, and (b) runs `openclaw sessions export-trajectory` once to see the bundle contents. Both are cheap, fast, half-day-or-less spikes and should gate the `report.sh` rewrite plan rather than being discovered mid-implementation.

---

## 4. Plugin migration — what the TypeScript plugin needs to become a 2.0 plugin

**MEDIUM-HIGH confidence.** Sourced from `docs.openclaw.ai/plugins/hooks`, `docs.openclaw.ai/plugins/hooks/reference`, and `docs.openclaw.ai/releases/2026.8.1/plugins-and-integrations`.

### 4.1 Hook names — good news, no renames for the hooks this plugin uses

The 2.0 hook reference still lists `before_prompt_build`, `before_tool_call`, `after_tool_call` (new — see §4.3), `before_agent_finalize`, and `agent_end` by the exact same names the existing plugins already use. [[docs.openclaw.ai/plugins/hooks/reference]](https://docs.openclaw.ai/plugins/hooks/reference) None of the four hooks this codebase registers were renamed or removed. This directly answers "hook renames" — **there are none for this plugin's hook set.**

### 4.2 `allowConversationAccess` — still the gate, but likely no longer sufficient alone for `before_prompt_build`

- `allowConversationAccess` remains the permission for the eight "conversation" hooks: `before_model_resolve`, `agent_turn_prepare`, `before_prompt_build`, `before_agent_reply`, `llm_input`, `llm_output`, `before_agent_finalize`, `agent_end`, `before_agent_run`. [[docs.openclaw.ai/plugins/hooks]](https://docs.openclaw.ai/plugins/hooks) — this is broader than the existing code assumed (the comments in `index.ts` for both plugins explicitly say `before_prompt_build` is "NOT a conversation hook — no allowConversationAccess needed," which the current docs contradict for 2.0).
- **A second, separate gate now exists: `allowPromptInjection`**, gating four *prompt-mutation* hooks — `agent_turn_prepare`, `before_prompt_build`, `heartbeat_prompt_contribution`, and durable injections — and the docs state *"Prompt hooks require **both** permissions if non-bundled."* [[docs.openclaw.ai/plugins/hooks]](https://docs.openclaw.ai/plugins/hooks)
- **This is the single most concrete, actionable, high-confidence finding in this document for the plugin-migration question.** Both `post-install.sh` (§7c) and `post-install-nemoclaw.sh`'s `install_enforcement_plugin()` patch only `{hooks: {allowConversationAccess: true}}`. If 2.0 genuinely enforces the `allowPromptInjection` gate as documented, **`before_prompt_build` — the sole surviving compliance mechanism after the `2026.6.6` finalize-revise veto — silently stops injecting the metering/guardrail directive on 2.0**, exactly the class of silent breakage this milestone exists to get ahead of. The config patch must become:
  ```json
  {"plugins":{"entries":{"<plugin-id>":{"enabled":true,"hooks":{"allowConversationAccess":true,"allowPromptInjection":true}}}}}
  ```
  This must be **live-verified** (not just patched speculatively) — see the version-canary design in §8, which should assert `promptChars` elevation exactly like the existing Gate A already does, so a missing `allowPromptInjection` grant is caught the same way the existing NemoClaw install already catches injection failures.

### 4.3 New hook available: `after_tool_call`

2.0 adds `after_tool_call` — *"Observe tool results, errors, and duration"* — which did not exist in the CalVer version this plugin was built against. [[docs.openclaw.ai/plugins/hooks/reference]](https://docs.openclaw.ai/plugins/hooks/reference) Today's plugin infers "did an exec happen" from `before_tool_call` alone (call-time only, no result/duration), which is one of the reasons the Nemotron `tool_search_code` indirection (B-05, tracked in-repo) was hard to observe structurally and had to be patched with an ad hoc transcript-scan fallback (`gate.js` `scanTranscriptForExec`). `after_tool_call` is a legitimate structural upgrade opportunity (see §5 fork discussion) but is **not** a hook-name migration requirement — it's optional hardening.

### 4.4 SDK / manifest / build changes

- `peerDependencies: { "openclaw": ">=2026.6.1" }` should be bumped to reflect the real floor, e.g. `>=2026.8.1` (per §0's corrected understanding of what "2.0" means) or, if the milestone wants to track the currently-live patch, `>=2026.9.x`.
- 2.0's plugin SDK release notes explicitly call out breaking cleanup: *"Retire[d] August Plugin SDK compatibility paths"* and *"Retire[d] deprecated Plugin SDK imports and deactivate hook alias, replacing the `deactivate` hook with `gateway_stop`."* [[docs.openclaw.ai/releases/2026.8.1/plugins-and-integrations]](https://docs.openclaw.ai/releases/2026.8.1/plugins-and-integrations) — this codebase's plugins do not use `deactivate`/`gateway_stop`, so this specific item does not require a code change, but it is direct evidence the SDK *did* break other plugins' hook names across this exact release, reinforcing that a canary (§8) is warranted rather than a one-time manual check.
- A **"beta.5 session-store bridge remains available through October 12, 2026"** for plugins relying on pre-2.0 session-store shapes [[docs.openclaw.ai/releases/2026.8.1/plugins-and-integrations]](https://docs.openclaw.ai/releases/2026.8.1/plugins-and-integrations) — this is a real, dated compatibility cliff. If the cut-over slips past **2026-10-12**, whatever grace period this bridge provided for session-shape compatibility is gone; this is a hard scheduling constraint worth surfacing to the roadmap directly.
- Install/inspect verbs are confirmed still present and largely stable: `openclaw plugins install --link ./path --force` (local dev), `openclaw plugins inspect <id> --runtime --json` (now explicitly documented with a `--json` flag), `openclaw plugins reload <id>` (**new** — applies code changes without a full gateway restart). [[docs.openclaw.ai/plugins/hooks]](https://docs.openclaw.ai/plugins/hooks) The existing Gate B in `post-install-nemoclaw.sh` (`install_enforcement_plugin`) parses the **text** output of `openclaw plugins inspect` for `Status: loaded` / `allowConversationAccess: true`; since `--json` is now documented, the gate should probably switch to `--json` + a real JSON field check (more robust than grep, and should also assert `allowPromptInjection: true` per §4.2).
- `openclaw plugins install --force` (no `--link`) continues to be the mechanism both install scripts already use for a non-dev, committed-`dist/` install — nothing in the fetched docs suggests this specific verb changed.

### 4.5 Rebuild `dist/`

Yes — required regardless of which branch (§5) is taken, because (a) the `openclaw` peer import path (`openclaw/plugin-sdk/plugin-entry`) needs re-resolving against the 2.0 SDK to catch any type/shape drift at compile time rather than at hook-call time, and (b) if `allowPromptInjection` handling changes anything about how `prependContext` responses are read, that should surface as a compile-time or unit-test failure, not a silent runtime no-op. The project's own `node_modules`/committed-`dist/` pattern (no host-side `tsc`) means this is a **local build + commit** step, not something `post-install.sh` can do at install time — this should be an explicit, early build-order item (§9).

---

## 5. The attribution-core fork — both branches, concretely, with a decision criterion

**This is the section the roadmapper most needs to be unambiguous about. Both branches are laid out below; the research finding is that Branch B applies today, based on currently published docs — but the decision criterion is written so the planner (or a Phase 0 spike) can re-evaluate it against a live host rather than trust this document blindly.**

### Decision criterion

> **Take Branch A (replace) if and only if a live-tested 2.0 hook can deliver, without an agent self-report step, a semantic label equivalent to today's 8-label `task_type` / 11-label `job_type` taxonomies — i.e., either (a) OpenClaw itself exposes a built-in turn-classification/intent primitive callable from a hook, or (b) a hook's payload is rich enough (full transcript + tool results + timing, reliably, for both Claude and Nemotron-routed exec) that a **plugin-side LLM call** made synchronously inside the hook can derive the label without agent cooperation, AND that plugin-side call's cost/latency is acceptable to run on every turn.
> **Otherwise, take Branch B (port as-is).**

### Research finding against that criterion

The fetched 2.0 hook reference (`docs.openclaw.ai/plugins/hooks/reference`) lists **no classification, intent-detection, or "ask the model a side question" primitive** anywhere in its hook catalog — the closest candidates are:
- `llm_input`/`llm_output` — *observe* provider input/output, not classify it
- `after_tool_call` — richer tool-result observation than today, but still purely structural (tool name, params, result, duration), not semantic
- `session_start`/`session_end` — lifecycle boundaries, and `session_end`'s payload is **confirmed broken** for message content on SQLite-backed sessions (§3, GitHub issue #155696) — so even the structural upgrade this hook could offer is not currently usable
- `tool_result_persist`/`before_message_write` — can rewrite/observe a message before it's persisted, useful for *enforcement* (e.g., blocking a turn from finalizing) but not a source of a semantic task-type label

None of these give a plugin a semantic `task_type`/`job_type` for free. **Criterion (a) is not met** — no built-in classifier hook exists. **Criterion (b) is theoretically constructible** (a plugin could call an LLM itself inside `before_agent_finalize` or `after_tool_call`) but this is a **new capability the project would be building itself**, not something "2.0's hooks" hand over — and it is exactly the `JCLASS-01` item (*"LLM `on_session_end` classifier plugin for automatic job/task inference"*) that `PROJECT.md` already tracks as explicitly deferred/out-of-scope pending further research. Building it now would be a scope expansion beyond "cut over to 2.0," not a consequence of the cut-over itself.

**Conclusion: Branch B (port as-is) is the applicable branch today**, per currently published OpenClaw 2.0 docs. This should be re-confirmed against a live `2026.9.x` host early in execution (the hook reference doc could be incomplete, or a classification primitive could exist under a name not surfaced by the fetches performed here), but the planner should default to scoping Branch B and treat Branch A as a stretch item gated on that live re-check — not the other way around.

### Branch A — if 2.0 offers real code-side classification (not confirmed; contingency plan only)

What gets deleted/replaced:
- `scripts/write-marker.sh`, `scripts/write-job-marker.sh` — retired; no more agent-invoked marker writers
- The `markers/` directory and its whole correlation engine in `report.sh` (completion_id-exact-match + timestamp-fallback lookup, ~400 lines across `process_session`) — retired, replaced by whatever the classification hook/plugin writes directly into a Revenium-bound structure (or directly calls `revenium meter completion --task-type ...` / `revenium jobs create` from inside the hook, moving that call from cron-batch to hook-synchronous)
- The AGENTS.md metering-directive injection (`post-install.sh` §7b, `references/agents-metering-directives.md`) — retired; the classification is no longer something the agent is asked to do
- The `before_agent_finalize` revise-and-force-marker-write gate in both plugins' `gate.js` — retired; replaced by whatever hook now carries the classification decision
- SKILL.md's "TASK CLASSIFICATION" and "JOB DECLARATION" sections — retired or radically shrunk to documentation-only ("this happens automatically")
- What's **kept unchanged**: guardrail HALT CHECK (guardrail enforcement is a Revenium-CLI/cron concern, not an OpenClaw classification concern), `guardrail-check.sh`, ledger-based idempotency patterns, the `revenium jobs create`/`outcome` CLI call shapes
- New component: a classification hook handler (likely inside the existing plugin, registered on `after_tool_call` + `session_end`/`before_agent_finalize`) that derives `task_type`/`job_type` and writes/calls Revenium directly or into a new intermediate file `report.sh` reads instead of `markers/*.jsonl`

### Branch B — port as-is (the applicable branch per this research)

What changes, concretely, versus a byte-for-byte port:
1. **`report.sh`'s session-read layer is rewritten** (§3) — SQLite read or `export-trajectory` polling replaces direct JSONL `jq`. This is *not optional* even under "port as-is" — the marker/classification architecture is unaffected, but the completions it correlates against have to come from *somewhere real* on 2.0.
2. **`get-root-session-id.py`** gets the same session-source fix, since it also walks JSONL today.
3. **Plugin manifests/config patches gain `allowPromptInjection: true`** (§4.2) — required for the existing `before_prompt_build` mechanism to keep working at all; without this the port is not actually "as-is," it's silently broken.
4. **Everything else is unchanged**: `write-marker.sh`, `write-job-marker.sh`, the markers directory, the completion_id/timestamp correlation engine in `report.sh`, AGENTS.md injection, SKILL.md's TASK CLASSIFICATION/JOB DECLARATION sections, both plugins' `gate.js` marker-detection regex and revise-action logic, the `before_agent_finalize` backstop (registered, mostly inert on tool-using turns, kept for the turns where it still fires), guardrail enforcement end-to-end.
5. **Optional (not required) hardening within Branch B**: swap the `before_tool_call`-only exec observation for `before_tool_call` + `after_tool_call` (§4.3) to get real duration/error data without the transcript-scan hack for the *structural* "did exec happen" signal — this does not touch the semantic classification question, only makes the existing exec-observation more reliable. Worth scoping as a small, separable improvement, not a prerequisite for the cut-over itself.

---

## 6. NemoClaw path — does the sandbox architecture still hold?

**MEDIUM confidence — the core SSHFS/host-cron/in-sandbox-CLI pattern is architecturally unaffected by OpenClaw 2.0 per se, but NemoClaw's own concurrent evolution (not OpenClaw's) changes several command-level details that `post-install-nemoclaw.sh` depends on.**

- The **shared-scripts-run-on-host-over-a-mount** pattern (`cron.sh`/`report.sh`/`guardrail-check.sh` running on the host with `OPENCLAW_HOME=<SSHFS mount>`) is unaffected by the OpenClaw session-storage migration *in principle* — but it inherits the exact same §3 fix, because the mount just gives host-side access to the in-sandbox `~/.openclaw` tree, and that tree now holds a SQLite file, not `sessions/*.jsonl`. **Reading the mounted SQLite file from the host with a host-side `sqlite3`/`python3 sqlite3` is architecturally straightforward** (SQLite is a single-file format with no server process, so a mount-and-read pattern works the same way JSONL mount-and-read did) — this is actually a point in favor of the SQLite approach for the NemoClaw path specifically, since it avoids needing a second `nemoclaw exec` round-trip just to read data.
- **NemoClaw's own release notes (a separate NVIDIA product, versioned independently of OpenClaw) show concurrent, relevant changes**:
  - *"OpenClaw 2026.9.1 retired the bypass, so NemoClaw does not emit a device-auth bypass key and changing this input does not skip pairing."* [[docs.nvidia.com/nemoclaw/user-guide/openclaw/release-notes]](https://docs.nvidia.com/nemoclaw/user-guide/openclaw/release-notes) — device-auth/pairing flow changed; this affects the initial in-sandbox `openclaw` provisioning/pairing step that `post-install-nemoclaw.sh` relies on being either non-interactive or bypassable. **Needs a live check** of whether the current install flow ever depended on that bypass key implicitly.
  - *"OpenClaw and Hermes now own their native gateway processes, plugins, packages, child processes, hooks, and background work after onboarding"* (NemoClaw `0.0.127`, 2026-09-17) [[docs.nvidia.com/nemoclaw/user-guide/openclaw/release-notes]](https://docs.nvidia.com/nemoclaw/user-guide/openclaw/release-notes) — this is a real architecture shift in how NemoClaw delegates plugin/gateway lifecycle to `openclaw` itself, which directly touches `install_enforcement_plugin()`'s current pattern of driving everything through `nemoclaw <sandbox> exec -- openclaw ...` and `nemoclaw <sandbox> recover`. It's plausible (UNVERIFIED without a live host) that plugin install/enable/reload can now be driven more directly and that `nemoclaw recover` is no longer the only way to load a newly-installed plugin (2.0's `openclaw plugins reload <id>` — §4.4 — may now work in-sandbox too, avoiding a full sandbox recover cycle).
  - Managed NemoClaw images track OpenClaw versions explicitly (`v0.0.128`, 2026-09-22: *"Managed images now include OpenClaw 2026.9.1"*) [[docs.nvidia.com/nemoclaw/user-guide/openclaw/release-notes]](https://docs.nvidia.com/nemoclaw/user-guide/openclaw/release-notes) — confirming NemoClaw does support and ship OpenClaw versions past "2.0," directly answering the milestone's open risk ("If ... NemoClaw does not support it, the milestone shrinks") — **it does support it; the milestone does not need to shrink on this account.**
- **Egress presets (`revenium-policy.yaml`, `gh-release-policy.yaml`), the SSHFS `ensure_mount` pattern, the CLI-delivery-via-CDN-tarball pattern, and the ledger-gated provisioning steps are all NemoClaw/OpenShell concerns, not OpenClaw concerns** — nothing in the OpenClaw 2.0 research surfaced any reason these change. They carry over unchanged.
- **What needs a live re-verification pass specifically because of the NemoClaw-side changes** (not the OpenClaw-side ones already covered in §2-§4): the exact `nemoclaw <sandbox> exec -- openclaw ...` call sequence in `install_enforcement_plugin()` (trust-install, config-patch, recover) — given NemoClaw `0.0.127`'s ownership handback, some of these steps may have simpler or different equivalents, and the Gate A/B output-parsing (already twice-patched for CalVer drift, per §1.2) should be assumed fragile until re-verified.

---

## 7. Version gating — where it lives, and how it refuses

**Follows the project's existing convention exactly** (the macOS refusal in `install.sh:75-85`: check-then-`fail()` with a specific, actionable multi-line message, never a silent no-op).

**Placement: `scripts/install.sh`, as a new gate immediately after the macOS refusal and before the routing dispatch (both `standalone` and `nemoclaw` targets need it).** Rationale: `install.sh` is already the single chokepoint both paths pass through, it already owns exactly this kind of hard-refusal precedent, and gating here means neither `post-install.sh` nor `post-install-nemoclaw.sh` needs to duplicate the check. A secondary, defense-in-depth copy of the same check belongs in `post-install.sh`/`post-install-nemoclaw.sh` directly too, since they're documented as independently runnable (`bash ~/.openclaw/skills/revenium/scripts/post-install.sh`) and a user could invoke either without going through `install.sh` — but `install.sh` is the primary gate.

**What it checks:** `openclaw --version` (or equivalent version-reporting subcommand — confirm exact invocation live; `openclaw agent --json` and `openclaw plugins inspect` are both confirmed JSON-emitting commands already used in this codebase, so a `--version`-style probe is very likely present but should be confirmed against a live host rather than assumed) parsed against the corrected floor from §0: **`>= 2026.8.1`** (not a fictitious "2.0.0").

**How it refuses (mirroring the macOS block's shape and tone):**

```bash
# ---------------------------------------------------------------------------
# OpenClaw version gate — this skill supports OpenClaw >= 2026.8.1 only
# (the CalVer release the project branded "OpenClaw 2.0"). Older CalVer
# releases changed their session-storage format and plugin permission model
# incompatibly; this skill does not dual-maintain both.
# ---------------------------------------------------------------------------
_oc_version="$(openclaw --version 2>/dev/null | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' | head -1 || true)"
if [[ -z "${_oc_version}" ]]; then
    fail "Could not determine the installed OpenClaw version (openclaw --version
  produced no parseable output). This skill requires OpenClaw 2026.8.1 or
  later. Install/upgrade OpenClaw and re-run: https://docs.openclaw.ai"
fi
if ! printf '%s\n2026.8.1\n' "${_oc_version}" | sort -C -V; then
    fail "OpenClaw ${_oc_version} is too old for this skill.

  This skill requires OpenClaw 2026.8.1 (\"OpenClaw 2.0\") or later — it no
  longer supports CalVer releases before the 2026.8.1 session-storage and
  plugin-permission changes. Upgrade OpenClaw and re-run:
  https://docs.openclaw.ai/releases"
fi
```

(`sort -C -V` version-compare is portable bash/coreutils, consistent with this codebase's existing preference for POSIX-ish tooling over a hard Python/jq dependency at this early a gate point; adjust to whatever `openclaw --version`'s actual output format turns out to be once confirmed live.)

**Where it does *not* belong:** the plugin manifest (`openclaw.plugin.json`) is not a gate the *install script* can act on — `peerDependencies` in `package.json` (§4.4) is the plugin-loader's own version contract, enforced by OpenClaw itself at plugin-install time, and is a **second, independent** layer of the same protection (defense in depth), not a substitute for the install-script-level gate — OpenClaw's own peer-version enforcement, if any, would only fire *after* a user has already gone through the whole provisioning flow, which is too late for the "refuse explicitly, never silently no-op" convention this project has already established.

---

## 8. Version canaries — design

**Placement: a new, dedicated script (`scripts/version-canary.sh` or similar), invoked from two places — not folded into an existing script.**

Rationale for "separate script, called from two places" over the alternatives:
- **Not a cron stage**: the failure mode this item targets ("a runtime upgrade voids a hook contract") is a *point-in-time* event (an operator ran `openclaw update` or a host got a new managed image), not a per-minute drift — running it every cron tick adds constant overhead (an `openclaw agent --json` round-trip, per the existing Gate A pattern, costs real tokens/latency) for a check that only needs to catch *changes*, not steady-state. The existing Gate A/B pattern already proves this: those gates run once, at install time, not every tick.
- **Not folded into install-time-only**: a canary that only runs at install time can't catch the specific failure mode the milestone names — *"a runtime upgrade voids a hook contract"* implies the upgrade happens **after** install, while the skill is already running. A canary needs to be re-runnable on demand and ideally on a low-frequency schedule (e.g., daily, or on `openclaw update` completion if such a hook/event exists — UNVERIFIED whether one does), not just once.
- **Separate script** keeps it independently invocable from both `install.sh` (as a final post-install assertion, reusing the exact same checks Gate A/B in `post-install-nemoclaw.sh` already prove work) and from a **new, low-frequency cron entry** (e.g., once daily, added by `install-cron.sh` as a second crontab line distinct from the once-a-minute metering tick) — reusing `cron.sh`'s existing flock/timeout scaffolding would conflate a fast, frequent metering job with a slow, rare structural-assertion job, which is exactly the kind of coupling this codebase has consistently avoided (see how tool-event ledgers were deliberately kept separate from the completion ledger to avoid coupling, `common.sh:78-85`).

**What it asserts** (each item traceable to a concrete break this research surfaced, not speculative):
1. **OpenClaw version is still within the supported range** — same check as §7, re-run so a live *upgrade past* whatever the install-time floor was doesn't go unnoticed if the milestone later wants an upper-bound gate too.
2. **`before_prompt_build` injection is actually firing** — reuse the existing, already-proven Gate A pattern (`post-install-nemoclaw.sh:313-349`): run a live agent turn and assert `promptChars` exceeds a threshold consistent with the directive being injected. This is the single most important assertion given §4.2's finding that `allowPromptInjection` may now be required and its absence would silently zero out the entire compliance mechanism.
3. **Plugin is loaded and both permission grants are active** — `openclaw plugins inspect <id> --json` (switching from the current text-grep Gate B to structured JSON per §4.4) asserting both `allowConversationAccess: true` and `allowPromptInjection: true`.
4. **Session data is actually reachable via whichever mechanism §3 lands on** — e.g., the SQLite file exists at the expected path and is openable/has the expected table(s), or `export-trajectory` succeeds for a known session key. This is the assertion that would have caught the JSONL-to-SQLite migration itself, had it existed before this milestone — which is precisely the point of a canary.
5. **`revenium jobs`/`revenium tools`/`revenium meter tool-event` CLI capability probes** — these already exist as `JOBS_CLI_CAPABLE`/`TOOLS_CLI_CAPABLE` runtime probes inside `report.sh` (`report.sh:1657-1681`) and fail open by design; the canary should promote a *change* in either probe's result (capable → not capable) from a silent fail-open into a loud, actionable warning, since today's fail-open behavior is correct for cron (never block metering) but wrong for a canary (whose entire job is to be loud).

**How it runs / fails:** loud, non-zero-exit, actionable-message-on-stderr, matching this project's `fail()` convention — but **only from its own dedicated invocation points**, never from inside `cron.sh`'s per-minute tick (which must stay fail-open per the project's own established design principle, restated across `report.sh`, `guardrail-check.sh`, and `common.sh` consistently). If wired into a low-frequency cron entry, that entry's failure should be surfaced via the same `openclaw message send` notification channel `guardrail-check.sh` already uses for halt notifications (`guardrail-check.sh:427-445`), reusing an existing, proven notification path rather than inventing a new one.

---

## 9. Suggested build order (with dependencies)

```
Phase 0 — Spike / confirm-before-plan (blocks everything else)
  0a. Provision a live host on OpenClaw >= 2026.8.1 (standalone) — REQUIRED, the milestone's
      own proof bar already demands this.
  0b. Inspect the live SQLite session file schema (sqlite3 <path> .schema) — resolves §3's
      open question (option 1 vs 2).
  0c. Confirm/refute the allowPromptInjection requirement live (patch a trivial test plugin,
      observe whether before_prompt_build fires without it) — resolves §4.2, the single
      highest-value fact to nail down before writing any plugin code.
  0d. Re-confirm the Branch A/B decision criterion (§5) against the live host's actual hook
      catalog, not just the fetched docs — cheap, and this document's Branch B conclusion
      should not be trusted blindly past this point.
  0e. Provision (or reuse) a NemoClaw host on a managed image tracking OpenClaw >= 2026.8.1,
      re-verify the nemoclaw exec/recover/pairing changes noted in §6.

Phase 1 — Version gate + canary scaffolding (small, low-risk, unblocks safe iteration)
  Depends on: 0a (need a real version string/format to gate against), 0c-partial (canary
  design references the allowPromptInjection assertion from §8, but the script skeleton
  and the install.sh gate itself do not depend on 0c's answer).
  - scripts/install.sh version gate (§7)
  - scripts/version-canary.sh skeleton + version check + plugin-inspect check (§8 items 1, 3)
  - Wire canary invocation into install.sh (post-provisioning assertion)

Phase 2 — report.sh session-read rewrite (the critical path — blocks standalone AND NemoClaw
  live validation, since both paths share this script)
  Depends on: 0b (schema/mechanism decided).
  - Rewrite session-line acquisition in report.sh + get-root-session-id.py + common.sh's
    SESSIONS_DIR/guardrail-check.sh's session lookup
  - Everything downstream (marker correlation, job lifecycle, tool-event scan, offset
    tracking) should require minimal changes if the rewrite preserves "iterate sessions,
    get new lines/rows since last checkpoint" as its contract
  - Add canary assertion for session-data reachability (§8 item 4)
  - This is the item most likely to reveal that Branch A/B (§5) needs revisiting, since a
    SQLite-native read path opens new possibilities (e.g., a SQL trigger or a richer query)
    that a naive port might not consider — but do not let this block Phase 2 on a Branch A
    decision; ship the Branch B rewrite first, revisit Branch A as a follow-on if 0d reverses
    the finding.

Phase 3 — Plugin migration (standalone: plugin/; can run in parallel with Phase 2 once 0c
  is answered, since it touches disjoint files)
  Depends on: 0c (allowPromptInjection answer), 4.4's SDK bump.
  - Bump peerDependencies, rebuild dist/ against the 2.0 SDK
  - Add allowPromptInjection to post-install.sh's config patch (§4.2)
  - Switch Gate B-equivalent inspection to --json parsing (§4.4)
  - (Optional hardening, not blocking) add after_tool_call observation (§4.3)
  - Add canary assertions for injection-firing + permission-grants (§8 items 2, 3)

Phase 4 — NemoClaw path (plugin-nemoclaw/ + post-install-nemoclaw.sh)
  Depends on: Phase 2 (report.sh rewrite — NemoClaw's cron runs the SAME report.sh over the
  mount), Phase 3's plugin-build pattern (plugin-nemoclaw/ mirrors plugin/'s hook wiring),
  0e (NemoClaw-specific re-verification).
  - Re-verify/update the nemoclaw exec -- openclaw ... call sequence in
    install_enforcement_plugin() against NemoClaw 0.0.127+'s lifecycle-ownership handback (§6)
  - Re-verify Gate A/B parsing against 2.0's actual openclaw agent --json / plugins inspect
    output shapes (already twice-patched historically for CalVer drift — expect a third patch)
  - Confirm device-auth/pairing bypass retirement doesn't block unattended provisioning (§6)

Phase 5 — Attribution-core fork resolution (only if 0d reverses this document's Branch B
  finding; otherwise this phase is "confirm Branch B, no additional work beyond Phases 2-4")
  Depends on: 0d.
  - If Branch A: net-new classification-hook design + deletion of markers/AGENTS.md
    injection/revise-gate (§5's Branch A component list) — treat as its own sub-milestone
    given the scope, not a drop-in inside Phase 2-4

Phase 6 — Hard HALT live validation (independent of the 2.0 cut-over technically, but the
  milestone bundles it — can run in parallel with Phase 2-4 once a 2.0 host is up, since
  guardrail-check.sh/cron.sh are confirmed unchanged by 2.0)
  Depends on: 0a only (needs a live 2.0 host, not the report.sh rewrite, since guardrail
  enforcement reads guardrail-status.json + the revenium CLI, not session data).

Phase 7 — ClawHub release
  Depends on: all prior phases green on a live 2.0 host per the milestone's proof bar.
```

**Critical-path summary:** `0a → 0b/0c/0d/0e (parallel spikes) → Phase 2 (report.sh) → Phase 4 (NemoClaw, which reuses Phase 2's output) → Phase 7 (release)`, with Phase 1 (gating), Phase 3 (standalone plugin), and Phase 6 (HALT validation) running in parallel branches once their respective spike answers land.

---

## Sources

- [OpenClaw v2026.8.1 release notes](https://docs.openclaw.ai/releases/2026.8.1)
- [OpenClaw releases index](https://docs.openclaw.ai/releases)
- [OpenClaw 2.0, Accidentally (official blog)](https://openclaw.ai/blog/openclaw-2-accidentally)
- [MarkTechPost: OpenClaw Releases OpenClaw 2.0](https://www.marktechpost.com/2026/08/30/openclaw-releases-openclaw-2-0-guided-model-setup-575-ms-control-ui-startup-and-one-trust-boundary-per-gateway/amp/)
- [CyberSecurityNews: OpenClaw 2.0 Released With Major Security Upgrades](https://cybersecuritynews.com/openclaw-2-0-released/)
- [InfoQ: OpenClaw 2.0 Releases with Simplified Setup and Collaborative Agents](https://www.infoq.com/news/2026/09/openclaw-2-release/)
- [OpenClaw v2026.8.1: Plugins and Integrations](https://docs.openclaw.ai/releases/2026.8.1/plugins-and-integrations)
- [OpenClaw Plugin hooks](https://docs.openclaw.ai/plugins/hooks)
- [OpenClaw Hook reference](https://docs.openclaw.ai/plugins/hooks/reference)
- [OpenClaw CLI: Sessions](https://docs.openclaw.ai/cli/sessions)
- [openclaw/openclaw docs/cli/sessions.md (raw source)](https://github.com/openclaw/openclaw/blob/main/docs/cli/sessions.md)
- [OpenClaw CLI: Transcripts](https://docs.openclaw.ai/cli/transcripts)
- [OpenClaw CLI: SQLite maintenance and session migration](https://docs.openclaw.ai/cli/doctor/sqlite-maintenance)
- [GitHub issue #155696 — session_end hook payload carries no messages for SQLite-backed sessions](https://github.com/openclaw/openclaw/issues/155696)
- [NVIDIA NemoClaw release notes](https://docs.nvidia.com/nemoclaw/user-guide/openclaw/release-notes)
- [NVIDIA NemoClaw architecture reference](https://docs.nvidia.com/nemoclaw/latest/reference/architecture)
- In-repo, read directly for this research: `scripts/install.sh`, `scripts/post-install.sh`, `scripts/post-install-nemoclaw.sh`, `scripts/report.sh`, `scripts/guardrail-check.sh`, `scripts/common.sh`, `scripts/cron.sh`, `SKILL.md`, `plugin/src/index.ts`, `plugin/src/gate.js`, `plugin/openclaw.plugin.json`, `plugin/package.json`, `plugin-nemoclaw/src/index.ts`, `plugin-nemoclaw/openclaw.plugin.json`, `plugin-nemoclaw/package.json`, `.planning/PROJECT.md`

---
*Architecture research for: OpenClaw 2.0 cut-over (v2.0 milestone), Revenium OpenClaw skill*
*Researched: 2026-09-23*
