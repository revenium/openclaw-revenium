# Phase 17: Live-Host Fact-Finding Spike - Research

**Researched:** 2026-09-24
**Domain:** Live-host protocol verification (SQLite session store, OpenClaw/NemoClaw plugin hooks, skill command-dispatch) — no production code is written this phase
**Confidence:** MEDIUM — host connectivity and package-registry facts were verified live this session; OpenClaw/NemoClaw behavioral facts (schema, hook firing, command-dispatch scope) rest on official docs fetched this session (CITED) but NOT YET re-verified against the live target host, which is exactly what Phase 17 itself must do

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** SPIKE-01 exercises **all three** candidate read paths on the live host and ranks them: (a) direct `sqlite3` against `~/.openclaw/agents/<agentId>/agent/openclaw-agent.sqlite`, read-only and WAL-aware; (b) the real `openclaw sessions` subcommands (`sessions export` confirmed **not to exist**); (c) a plugin-hook sidecar in which the skill captures completions itself into a format we own. The sidecar is included deliberately — it is the only candidate immune to OpenClaw changing its storage again.
- **D-02:** The ranking criterion is **data fidelity first** — the winner is whichever mechanism yields per-completion token usage, model id, toolCalls, and session parentage with zero loss. Performance and drift-resistance break ties only.
- **D-03:** SPIKE-01 returns **two** determinations — content reading *and* current-session-id resolution. `write-marker.sh:66`, `write-job-marker.sh:132`, `verify-markers.sh:91`, and `guardrail-check.sh:496` resolve "which session am I in right now" by globbing the newest non-cron `*.jsonl` filename and never read message content.
- **D-04:** SPIKE-04's pass bar is a **concurrency soak with zero loss**: a real per-minute cron, over a sustained window, while an agent is actively producing turns, passing only on zero lock/`SQLITE_BUSY` errors and zero missed completions vs. a ground-truth count. Resource metrics may be recorded but are not the bar.
- **D-05:** SPIKE-03 returns "yes" only on **determinism across models** — dispatching on every qualifying turn across at least two models, including one from the class that previously broke observation (Nemotron/`tool_search_code`, B-05), over a run long enough that "the model happened to comply" is not viable.
- **D-06:** The verdict is **binary**. Model-A-works/model-B-doesn't counts as **NO**: ATTR-01 moves to Future Requirements, Phase 21 is deleted, existing marker architecture ports as-is under Phase 20. No three-state verdict. **Reversibility: costly.**
- **D-07:** "Across at least two models" means **both production pairings**: standalone OpenClaw + Claude, and NemoClaw/OpenShell + Nemotron. Applies to SPIKE-02's matrix and SPIKE-03. Consequence: both install paths must be live on the host during Phase 17.
- **D-08:** SPIKE-02's matrix covers **every hook the skill depends on**, fixed in advance: `before_prompt_build`, `after_tool_call`, `before_agent_finalize`, `subagent_spawned`, `subagent_ended`, plus `session_end` **recorded rather than skipped** (issue #155696).
- **D-09:** Determinations live in **`.planning/spikes/007–011/README.md`**, following `.planning/spikes/CONVENTIONS.md`, with `MANIFEST.md` rows added.
- **D-10:** Findings are wrapped into the **re-scoped `spike-findings-openclaw-revenium` skill** (broaden description + CLAUDE.md routing line + new topic reference file).
- **D-11:** The spike hands Phase 19 **throwaway probes plus a verbatim schema capture**, not a reference implementation. Probe scripts stay in spike dirs; artifacts include literal `sqlite3 .schema` output and sample rows. Phase 19 writes production code from scratch.
- **D-12:** Evidence standard: every claim carries the **exact command run, its raw output pasted (trimmed, never paraphrased), the host, the date, and the OpenClaw/NemoClaw/Node versions in effect**.
- **D-13:** **One host, both paths.** `52.90.9.242` carries standalone OpenClaw + Docker *and* NemoClaw/OpenShell. Shared-host risk: every finding must record which context produced it.
- **D-14:** Reproducibility via an **idempotent `provision-2-0-host.sh`** committed under the spike dir — re-runnable, each step gated on a detection check, recording version floors.
- **D-15:** Version policy is **provision at `latest`, record exactly what resolved** — the two install paths will not necessarily run the same OpenClaw; that is expected, not to be normalized away.
- **D-16:** **Real keys, spike-scoped** — a real model key (Anthropic/NVIDIA) and a real Revenium API key, `api.revenium.ai` egress preset applied. Spike transactions land in the normal Revenium tenant; no scratch scope.

### Claude's Discretion

No area was handed to Claude wholesale. Left to the planner within the bars above: soak-window and determinism-run durations, spike-dir numbering granularity (one dir per SPIKE-nn vs. one per question actually asked), whether `MANIFEST.md`'s Requirements section accrues 2.0 constraints as they are found, and the escalation path if no read candidate clears the fidelity bar.

### Deferred Ideas (OUT OF SCOPE)

- **Gate A exit-1 on the NemoClaw install path** (`nemoclaw-install-gate-a-exit1`) — belongs to Phase 20/22, not this fact-finding spike. Remains in `.planning/todos/pending/`.
- **Backfilling archived pre-2.0 JSONL sessions into Revenium** — already Out of Scope in REQUIREMENTS.md.
- `16-review-deferred-findings` — reviewed, not folded (minor docs/test polish, unrelated to this phase's zero-production-code scope).
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SPIKE-00 | Provisioned Linux host: OpenClaw `>=2026.8.1`, Node `>=24.16`, Docker, NemoClaw `>=v0.0.128`, reproducible | Live host probe (this session) confirms starting state; official install-script commands and version floors captured below (`## Host Provisioning`); RAM headroom risk flagged |
| SPIKE-01 | Evidence-backed determination: how to read completions/toolCalls from SQLite session store | `## Session Read Path — Candidate Ranking Inputs`; SQLite schema fields, CLI fidelity gaps (`sessions tail` redacts, `sessions list` lacks per-message usage), WAL concurrency mechanics |
| SPIKE-02 | Per-model hook-firing matrix, live | `## Hook Catalog (confirmed live-docs)`; exact hook list matching D-08, `after_tool_call`/`subagent_spawned`/`subagent_ended` field shapes |
| SPIKE-03 | Yes/no verdict on `command-dispatch: tool` determinism | `## command-dispatch: tool — Critical Scope Finding`; documented scope is **slash-command routing**, not automatic per-turn dispatch — a load-bearing gap the spike must resolve empirically |
| SPIKE-04 | Confirmation the chosen read mechanism sustains per-minute cron polling without host degradation | `## Concurrency Soak Design Inputs`; WAL busy_timeout mechanics, SSHFS+SQLite risk, `verify-markers.sh` as ground-truth counter |
</phase_requirements>

## Summary

This phase produces facts, not code — five written determinations that gate every subsequent v2.0 phase. The research below front-loads everything checkable without the live host (npm registry version floors, official-docs hook/CLI/schema shape, SQLite WAL concurrency mechanics) and everything checkable *with* light live probing already run this session (host reachability, current OS/RAM/tooling state, confirmed absence of openclaw/node/docker/nemoclaw). It deliberately does **not** attempt to answer SPIKE-01 through SPIKE-04 from docs — CONTEXT.md and the milestone's own upstream research (`.planning/research/`) already establish that these are unresolved-by-design and require the live probing this phase exists to do.

The single most important finding this research surfaces beyond what CONTEXT.md already knew: **`command-dispatch: tool` is documented as slash-command routing** ("routes the slash command directly to a tool, bypassing model judgment for that invocation") — it is not documented anywhere as a mechanism for forcing deterministic dispatch of an *agent-invoked, non-slash-command* action like marker-writing on every qualifying turn. SPIKE-03's binary verdict (D-06) may resolve to NO for a reason CONTEXT.md did not anticipate: not "works on Claude, fails on Nemotron," but "the mechanism doesn't apply to this call shape at all." The plan should treat this as the first thing SPIKE-03 checks, before spending soak-window time on cross-model determinism.

The second load-bearing finding: none of the three documented CLI-level session-read surfaces meet D-02's zero-loss fidelity bar as officially documented. `openclaw sessions tail` explicitly redacts tool arguments and prompt text (`{...redacted...}`); `openclaw sessions list --json` carries only session-level metadata (`agentId`, `key`, `model`) with no per-message usage/toolCall detail; `openclaw sessions export-trajectory` is documented as reachable via an owner-approved exec request from the `/export-trajectory` slash command, with unattended/cron-invoked approval-gating unconfirmed. This leaves direct SQLite read and the sidecar-capture candidate (D-01c) as the two mechanisms most likely to survive the fidelity bar — reinforcing D-01's decision to test all three rather than assume the CLI wins on "official surface, therefore safer."

**Primary recommendation:** Sequence the spike as (1) provision via the two official install scripts (which self-provision Node/Docker), recording exact resolved versions; (2) run the `command-dispatch: tool` scope check *first* among the four fact-finding spikes — it is cheap, and a NO here changes how much soak-window time SPIKE-03 needs; (3) run SPIKE-01's three-way read-path bake-off with a `sqlite3 file:<path>?mode=ro` connection string and explicit `PRAGMA busy_timeout`, capturing `.schema` output verbatim per D-12/D-11; (4) run SPIKE-02's hook matrix against both pairings concurrently with the same live agent traffic SPIKE-04's soak needs, so the two spikes share one long-running session instead of two.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Host provisioning (OS, Node, Docker, NemoClaw, OpenClaw) | Host/OS | — | Pure infrastructure; no application tier owns version floors |
| Session completions/toolCalls read mechanism | Database/Storage (SQLite) | API/Backend (CLI export surface) | The data lives in SQLite; the *access path* candidates split between direct storage access and a CLI-mediated backend surface — SPIKE-01 decides which tier owns the read |
| Hook-firing matrix (`before_prompt_build`, `after_tool_call`, etc.) | API/Backend (OpenClaw plugin runtime) | — | Hooks are a runtime/plugin-SDK concern, not a storage or client concern |
| `command-dispatch: tool` dispatch mechanism | API/Backend (skill/command router) | Client (agent turn — what triggers a slash command) | The router lives server-side in the gateway; whether it fires depends on a client-side action (user typing a slash command), which is the crux of the scope gap this research flags |
| Concurrency soak (per-minute cron reading a live-written store) | Database/Storage (SQLite WAL) | Host/OS (cron scheduling) | The failure mode under test (`SQLITE_BUSY`, lock contention) is a storage-engine concern; the cadence that triggers it is a host-scheduling concern |
| Findings artifacts + skill re-scoping | Docs/Meta (not a runtime tier) | — | Not part of the running system; a project documentation/knowledge-transfer concern, included for completeness per D-09/D-10 |

## Host Provisioning

**Live probe run this session** — `ssh -i ~/.ssh/hermes-sandbox.pem ubuntu@52.90.9.242`, 2026-09-24:

```
$ uname -a
Linux ip-172-31-40-178 7.0.0-1006-aws #6-Ubuntu SMP PREEMPT Tue May 26 12:04:34 UTC 2026 x86_64 GNU/Linux
$ lsb_release -a
Distributor ID: Ubuntu
Description:    Ubuntu 26.04 LTS
Release:        26.04
Codename:       resolute
$ free -h
               total        used        free      shared  buff/cache   available
Mem:           7.7Gi        729Mi       697Mi       1.8Mi        6.7Gi       7.0Gi
Swap:             0B          0B          0B
$ df -h /
Filesystem      Size  Used Avail Use% Mounted on
/dev/root       193G  8.0G  185G   5% /
$ nproc
2
$ sudo -n true && echo PASSWORDLESS_SUDO_OK
PASSWORDLESS_SUDO_OK
$ which openclaw nemoclaw docker revenium sshfs node
(all empty)
$ which sqlite3 curl git python3
/usr/bin/sqlite3 /usr/bin/curl /usr/bin/git /usr/bin/python3
$ sqlite3 --version
3.46.1 2024-08-13 09:16:08 ...
$ which nvidia-smi
(empty — no GPU)
```
`[VERIFIED: live ssh probe, ubuntu@52.90.9.242, 2026-09-24]`

**Findings for the provisioning script (SPIKE-00):**

1. **RAM is 7.7 GiB, below the NemoClaw-documented ~8 GB floor, and swap is 0.** `.planning/spikes/CONVENTIONS.md` (established during v1.4 spikes on a different host) already documents this exact risk: *"Min ~8 GB RAM (add swap if below)."* `[VERIFIED: .planning/spikes/CONVENTIONS.md, line "Min ~8 GB RAM (add swap if below)..."]` — `provision-2-0-host.sh` should add a swapfile as an explicit, gated step before NemoClaw install, not assume RAM is sufficient because "close to 8GB."
2. **No GPU** — inference will route to the cloud provider (NVIDIA cloud for NemoClaw/Nemotron, Anthropic API for standalone), consistent with `CONVENTIONS.md`'s "without one, inference is routed to NVIDIA cloud" note from the prior spike host.
3. **`sshfs` is not installed** but is apt-available (`3.7.3-1.1build5`) — required host-side for the NemoClaw metering-mount pattern (D-13, precedent: `.planning/spikes/004-background-metering-loop/`). Install via `sudo apt-get install -y sshfs` as a provisioning step.
4. **`sqlite3` CLI (3.46.1) is already present** — good news for SPIKE-01's direct-read candidate; no install step needed for that probe.
5. **Node is absent.** OpenClaw's own installer self-provisions Node if missing: `[CITED: docs.openclaw.ai/install]` *"detects your OS, installs Node if needed, installs OpenClaw, and launches onboarding."* Recommended command:
   ```bash
   curl -fsSL https://openclaw.ai/install.sh | bash
   ```
   Alternative (manual Node control): `[CITED: docs.openclaw.ai/install]`
   ```bash
   npm install -g openclaw@latest --allow-scripts=openclaw
   openclaw onboard --install-daemon
   ```
6. **Node version floor, confirmed two ways:**
   - `[CITED: docs.openclaw.ai/install/node]` "OpenClaw requires Node 24.16+ or Node 26.1+... Unsupported versions include Node 22, 23, 25, Node 24 before 24.16.0, and Node 26 before 26.1.0." Explicit warning: **"Upgrade Node before updating OpenClaw to avoid SQLite TEXT truncation."**
   - `[VERIFIED: npm registry]` — `npm view openclaw@latest engines --json` run this session returned:
     ```json
     { "node": ">=24.16.0 <25 || >=26.1.0" }
     ```
     This is the package's own declared engine constraint, independently confirming the docs claim.
7. **Current `openclaw` npm state, live-queried this session** `[VERIFIED: npm registry]`:
   ```
   $ npm view openclaw dist-tags --json
   { "beta": "2026.9.6", "extended-stable": "2026.7.35", "latest": "2026.9.6" }
   ```
   `latest` (2026.9.6) clears the `>=2026.8.1` floor comfortably. Per D-15, provisioning at `latest` will resolve to `2026.9.6` (or newer, at execution time) — record the exact resolved version, do not assume it stays 2026.9.6.
8. **`openclaw doctor --fix`** (alias `--repair`) exists and is documented as idempotent and safe to re-run: `[CITED: search-synthesized from docs.openclaw.ai/cli/doctor via kaxo.io/stack-junkie.com secondary summaries — MEDIUM-LOW, re-fetch docs.openclaw.ai/cli/doctor directly at Phase 18 implementation time]`. A `--non-interactive` flag exists for automation. Not required by Phase 17 itself (GATE-03 is Phase 18), but worth confirming during provisioning since a stale/partial state on this fresh host is unlikely to need it — record whether `doctor` reports any issues on first run as a provisioning-script assertion.
9. **NemoClaw non-interactive install**, confirmed shape from prior spike (`CONVENTIONS.md`, validated on a different host in v1.4) `[VERIFIED: .planning/spikes/CONVENTIONS.md install block]`:
   ```bash
   curl -fsSL https://www.nvidia.com/nemoclaw.sh | \
     NEMOCLAW_NON_INTERACTIVE=1 NEMOCLAW_NON_INTERACTIVE_SUDO_MODE=prompt \
     NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 NEMOCLAW_PROVIDER=build \
     NEMOCLAW_SANDBOX_NAME=<name> NEMOCLAW_POLICY_MODE=suggested \
     NVIDIA_API_KEY=nvapi-... bash
   ```
   A fresh login is required between the Docker-group add and onboarding; the prior spike found running detached (`setsid … </dev/null`) dodges an apt SIGTTIN hang under tmux+tee — carry this forward into `provision-2-0-host.sh`.
10. **NemoClaw `v0.0.128` (2026-09-22)** `[ASSUMED — websearch synthesis, not independently confirmed against docs.nvidia.com this session; re-verify live]`: bundles managed images with OpenClaw `2026.9.1` and Hermes `0.21.3`; adds canonical `v1alpha1` config export; "completes more OpenShell lifecycle ownership" handback to OpenClaw/Hermes (continuing the `0.0.127` handback noted in `.planning/research/PITFALLS.md`). Per D-15, this means the NemoClaw-managed OpenClaw (2026.9.1) and the standalone-path `latest` (2026.9.6+) will *not* match — expected and must be recorded per-path, not normalized.
11. **Docker**: not installed; OpenClaw's own Docker install docs point to official images `ghcr.io/openclaw/openclaw` or `openclaw/openclaw` `[CITED: docs.openclaw.ai/install/docker]` — but standalone OpenClaw's *own* runtime does not require Docker unless the skill's Docker-sandbox pattern is in play (this project's `post-install.sh` uses a Docker sandbox for the agent). NemoClaw's installer manages Docker itself per `CONVENTIONS.md`. Provisioning script should install Docker via NemoClaw's installer path (shared dependency) rather than twice.

## Session Read Path — Candidate Ranking Inputs (feeds SPIKE-01)

**Candidate (a) — direct SQLite read.**

- Confirmed file location, two ways: `[CITED: docs.openclaw.ai/cli/doctor/sqlite-maintenance]` *"Runtime session rows and transcripts are stored in SQLite at `~/.openclaw/agents/<agentId>/agent/openclaw-agent.sqlite` by default"* — matches this project's own `.planning/research/ARCHITECTURE.md §3` finding, itself sourced from the same doc.
- **No table/column names are published.** `[CITED: docs.openclaw.ai/reference/session-management-compaction/schema]` documents `SessionEntry` *conceptual* fields (`sessionId`, `sessionKey`, `lastInteractionAt`, `updatedAt`, `inputTokens`/`outputTokens`/`totalTokens`/`contextTokens`, `compactionCount`, `archivedAt`) and transcript event *types* (`session`, `message`, `custom_message`, `compaction`, `reset`, `branch_summary` — append-only, `id`+`parentId` tree) but explicitly does not enumerate SQL table/column names. **This confirms D-11's premise**: the schema is genuinely unverified from docs and must be captured live with `sqlite3 <path> .schema` — there is no shortcut.
- **Concurrency mechanics** (feeds SPIKE-01's tie-break criterion and SPIKE-04 directly): `[CITED: sqlite.org/forum + hynek.me/til/sqlite-read-only-wal-locked, cross-checked against sqlite/sqlite doc/wal-lock.md — classify-confidence: websearch --verified = MEDIUM]`
  - In WAL mode, readers and writers do not block each other in steady state.
  - A reader that has only *read-only* filesystem access to the `-shm` file "never uses blocking locks" and can receive `SQLITE_BUSY` during connection-lifecycle lock windows (e.g., opening/closing on an empty WAL database) — a narrow but real edge case for a cron process that opens a fresh connection every tick.
  - `PRAGMA busy_timeout=<ms>` makes SQLite retry for the given window instead of failing immediately on `SQLITE_BUSY`; Python's stdlib `sqlite3` module defaults to a 5-second busy timeout, but the CLI does not set one implicitly — a probe script should set it explicitly: `sqlite3 'file:<path>?mode=ro' 'PRAGMA busy_timeout=5000; SELECT ...'`.
  - `[CITED: docs.openclaw.ai/cli/doctor/sqlite-maintenance]` — Doctor's own `inspect`/`dry-run`/`validate` modes are documented as **not** acquiring the exclusive maintenance lock and safe to run without stopping the Gateway; only `import`/`compact`/`recover`/`restore` require gateway-stopped exclusivity. This is direct evidence that read-only access to the live SQLite file *while the Gateway is running* is an officially sanctioned pattern for at least the Doctor tooling — a reasonable (not certain) signal that a read-only, `mode=ro`, WAL-aware `sqlite3` connection from `report.sh`-equivalent tooling should be similarly safe, but this must be **empirically confirmed** by SPIKE-04's soak, not inferred from Doctor's own access pattern.
  - **Elevated risk for the NemoClaw path specifically**: reading a live SQLite file over an SSHFS mount compounds the WAL lock-window risk with SSHFS's own caching/consistency behavior (already a known hazard in this project — `CONVENTIONS.md`'s SSHFS-cache-lag note, and `.planning/research/PITFALLS.md` Pitfall 7's "SQLite over a network filesystem is a well-known reliability trap"). SPIKE-01/04 should test the mount-and-read path as its own cell, not assume host-side direct SQLite behavior generalizes to it.

**Candidate (b) — real `openclaw sessions` subcommands.**

- Confirmed subcommand family, matching `.planning/research/ARCHITECTURE.md §3`: `list`, `archive`, `delete`, `tail`, `export-trajectory`, `cleanup`, `compact`. **No plain `export`.**
- `[CITED: docs.openclaw.ai/cli/sessions]` fetched directly this session:
  - `sessions list --json` output shape: `path`, `stores[]`, `allAgents`, `count`, `totalCount`, `limitApplied`, `hasMore`, `activeMinutes`, `sessions[]` with per-session fields `agentId`, `key`, `model`, optional `color`. **No per-message usage, stopReason, or toolCall fields** — this is session-level metadata only and does not meet D-02's fidelity bar on its own.
  - `sessions tail --session-key <key> [--follow] [--tail <n>] [--agent <id>]`: documented as **"intentionally conservative"** — *"omits prompt text and tool arguments... tool calls display the tool name with `{...redacted...}`"*. **This candidate fails the D-02 zero-loss bar by design, as documented** — a load-bearing negative finding: do not plan around `sessions tail` for the metering read path.
  - `sessions export-trajectory --session-key <key> [--workspace <path>] [--output <name>] [--json]`: the one candidate not yet ruled out by documented redaction. Docs describe it as *"used by the `/export-trajectory` slash command after the owner approves the exec request."* **Unconfirmed whether direct CLI invocation from an unattended cron script bypasses that approval gate** — this is exactly the "owner-approved exec request" ambiguity `.planning/research/ARCHITECTURE.md §3` already flagged as needing a live test. Fidelity of the exported bundle (token usage, model, stopReason, toolCalls) is also not documented at the field level — must be captured live and quoted verbatim per D-11/D-12.
  - `openclaw doctor session-sqlite inspect [--session-sqlite-all-agents] [--json]` exists as a migration-diagnostics surface, not an ongoing telemetry feed — output schema undocumented; worth one live probe to see if it happens to expose anything D-02-useful, but not a primary candidate.

**Candidate (c) — plugin-hook sidecar.**

- No new docs finding beyond what CONTEXT.md and `.planning/research/FEATURES.md` already established: `llm_output` exposes a `usage` object per completion (`[CITED: docs.openclaw.ai/reference/token-use]`, corroborated by this project's own `.planning/research/SUMMARY.md`), and `after_tool_call` (confirmed in the hook catalog fetched this session, see below) gives result/error/duration per tool call. A plugin registering both hooks and writing its own append-only capture file (mirroring this project's existing `markers/*.jsonl` pattern) is architecturally straightforward and, as D-01 notes, is the only candidate immune to a future OpenClaw storage change. The main open question is engineering cost/latency of a synchronous hook write on every completion/tool-call — a soak-relevant question that overlaps with SPIKE-04.

**Cross-cutting negative finding for D-03 (current-session-id resolution):** none of the docs fetched this session describe a supported CLI/hook equivalent for "give me the current session id" beyond what `subagent_spawned`/`subagent_ended` structurally provide for *subagent* relationships (see Hook Catalog below). The four scripts' `ls -t *.jsonl | head -1` pattern has no confirmed drop-in replacement documented — this remains a live-host-only question, exactly as D-03 states.

## Hook Catalog (confirmed live-docs, feeds SPIKE-02)

`[CITED: docs.openclaw.ai/plugins/hooks/reference, fetched directly this session]` — full catalog includes (among others) every hook D-08 names:

```
before_model_resolve, agent_turn_prepare, before_prompt_build, before_agent_run,
before_agent_reply, before_agent_finalize, agent_end, heartbeat_prompt_contribution,
model_call_started, model_call_ended, llm_input, llm_output, before_tool_call,
after_tool_call, resolve_exec_env, tool_result_persist, before_message_write,
inbound_claim, channel_pairing_requested, message_received, message_sending,
reply_payload_sending, message_sent, before_dispatch, reply_dispatch,
session_start, session_end, before_compaction, after_compaction, before_reset,
subagent_spawned, subagent_ended, subagent_progress, subagent_delivery_target,
gateway_start, gateway_stop, cron_reconciled, cron_changed, before_install,
skill_proposal_evaluate, skill_proposal_changed, skill_changed
```

Confirms **no rename, no removal** for any of the six hooks D-08's matrix fixes in advance. Per-hook detail relevant to SPIKE-02's live probes:

| Hook | Type | Confirmed detail |
|------|------|-------------------|
| `before_prompt_build` | Modify, 15s default timeout | "Add prompt context, narrow the current turn's submitted tools, or perform authorized post-policy enrichment." On handler failure: "Log and skip the failed handler; retain other successful results." |
| `after_tool_call` | Observe, no documented runner timeout | "Observe tool results, errors, and duration." No documented caveat about execution-path coverage (i.e., docs do not say whether it fires for `tool_search_code`-routed exec, the B-05 case) — **this is exactly the gap SPIKE-02 must close empirically for the Nemotron pairing.** |
| `before_agent_finalize` | Modify, 15s default timeout | "Inspect the natural final answer and request one more model pass." Same fail-and-skip-on-timeout behavior as `before_prompt_build`. |
| `subagent_spawned` | Observe | Includes `resolvedModel`/`resolvedProvider` "when OpenClaw has resolved the child session's native model before launch," plus `childSessionKey`. |
| `subagent_ended` | Observe | Carries `targetSessionKey`, `targetKind`, `reason`, optional `outcome`, error details, timing. **Does not include `agentId`** — correlate via `targetSessionKey` matching `subagent_spawned.childSessionKey`. |
| `session_end` | Observe, 30s default timeout per handler, shared 2s total drain budget across all active sessions | `reason` enum: `new, reset, idle, daily, compaction, deleted, shutdown, restart, unknown` — matches `.planning/research/FEATURES.md`'s finding exactly. Confirmed separately (issue #155696, not re-fetched this session, already HIGH-confidence per prior research) that the payload carries no message content for SQLite-backed sessions. |

**Permission-gate finding relevant to the matrix (a nuance beyond what CONTEXT.md's D-08 anticipated):** `[CITED: docs.openclaw.ai/plugins/hooks, fetched directly this session]` — `allowConversationAccess: true` is required (non-bundled plugins) for `before_model_resolve, agent_turn_prepare, before_prompt_build, before_agent_reply, llm_input, llm_output, before_agent_finalize, agent_end, before_agent_run`. Separately, `allowPromptInjection` gates `agent_turn_prepare, before_prompt_build, heartbeat_prompt_contribution,` and durable next-turn injections, and — the nuance — **it defaults to allowed**: *"It defaults to allowed but does not grant conversation access."* The two prompt-mutation hooks "therefore need both permissions" — but `allowPromptInjection`'s default being *allowed* (not *denied*) is a different picture than `.planning/research/ARCHITECTURE.md §4.2`'s framing, which reads as if the permission must be explicitly granted to work at all. **SPIKE-02's `before_prompt_build` cell should record whether omitting `allowPromptInjection` from the plugin config patch still results in the directive firing** — if the default-allowed behavior holds live, PLUG-02 (Phase 20) may be a smaller change (or a no-op needing only confirmation) than currently assumed. This is squarely a live-host fact, not resolvable from docs alone — flagging it here so the matrix probe captures it as a side observation.

## command-dispatch: tool — Critical Scope Finding (feeds SPIKE-03)

`[CITED: docs.openclaw.ai/tools/creating-skills, fetched directly this session]`:

- `command-dispatch: "tool"` — *"Set to `tool` to route the slash command directly to a tool, circumventing model processing."*
- `command-tool` — names which tool receives the dispatched command when `command-dispatch: tool` is active.
- `command-arg-mode` — defaults `raw`; for tool dispatch, forwards the raw args string to the tool.
- The documented trigger is **the user (or agent) typing the skill's slash command** — *"the routing is deterministic and automatic for every qualifying turn where that slash command is used."*

**This is the single most consequential finding of this research pass.** CONTEXT.md's D-05/D-06 frame SPIKE-03's question as "does `command-dispatch: tool` make marker-writing dispatch deterministic" — but nothing in the documented spec describes `command-dispatch: tool` as applicable to an *agent-initiated, non-slash-command* action such as writing a task-type/job marker mid-turn. The documented mechanism is a **user-facing slash-command router**, not a per-turn agent-behavior enforcer. Two live-host possibilities exist and SPIKE-03 must distinguish them, in order:

1. **The mechanism genuinely does not apply to this call shape.** If marker-writing is not, and cannot be made to be, a slash command the agent (or a wrapper) invokes every qualifying turn, then `command-dispatch: tool` cannot answer SPIKE-03's question at all, and the verdict should be **NO — mechanism inapplicable**, recorded as a documented negative finding rather than a "we tried and it didn't dispatch deterministically" cross-model result. This check is cheap (read the skill's own command definition, or trivially reconfigure SKILL.md to use `command-dispatch: tool` and try to invoke it as a slash command from an agent turn) and should run **before** committing soak-window time to a two-model determinism run.
2. **There is an undocumented adjacent mechanism** (e.g., an agent-triggerable "tool alias" that isn't gated by slash-command typing) that the fetched docs pages didn't surface. If so, D-05's determinism-across-models test proceeds as CONTEXT.md already specifies.

Either way, this reframes the sequencing risk: SPIKE-03 should start with a cheap scope-confirmation probe, not go straight into a long two-model soak, because a NO on scope makes the soak moot.

## Concurrency Soak Design Inputs (feeds SPIKE-04)

- **Ground-truth counter, already in-repo:** `scripts/verify-markers.sh` already implements a "count completions in the session store, count markers, diff" pattern (per CONTEXT.md's canonical-refs table) — this is the natural template for SPIKE-04's "zero missed completions against a ground-truth count" bar, adaptable to whichever read mechanism SPIKE-01 selects.
- **Cron cadence precedent:** `scripts/cron.sh`, `scripts/install-nemoclaw-cron.sh`, and `scripts/nemoclaw-cron-tick.sh` (all read this session) establish the existing per-minute cadence and `flock`/timeout discipline this skill already uses — the soak should reuse this scaffolding rather than build a new cron harness, per the project's own "cron.sh is pure process orchestration, unchanged" finding in `.planning/research/ARCHITECTURE.md §2`.
- **What "zero loss" must be measured against:** D-04 requires comparing SPIKE-01's chosen read path's completion count against a ground truth. The most defensible ground truth is the OpenClaw-native `model.usage` diagnostic event or a completion counter the sidecar candidate (D-01c) would maintain independently — i.e., SPIKE-01 and SPIKE-04 should share instrumentation: whichever mechanism SPIKE-01 does NOT select as primary can still serve as SPIKE-04's independent ground-truth cross-check, which is a stronger design than inventing a fourth counting mechanism.
- **NemoClaw path adds an extra failure surface:** the soak on the NemoClaw pairing must run over the *actual* SSHFS mount (D-13's "both production pairings" applies to SPIKE-04 too, since D-07 explicitly says D-07 "applies to SPIKE-02's matrix as well as SPIKE-03" is the model-pairing point; SPIKE-04's own text says "sustains per-minute cron polling" generally — the planner should confirm with the user whether SPIKE-04 is scoped to one pairing or both, since CONTEXT.md does not say so as explicitly as it does for SPIKE-02/03. Flagging as an open question below rather than assuming.)

## Standard Stack

This phase provisions infrastructure, not application dependencies — there is no new npm/pip/cargo package for the skill itself. The "stack" is the set of CLI tools and version floors being verified.

### Core

| Tool | Version floor | Purpose | Verification this session |
|------|---------------|---------|---------------------------|
| OpenClaw | `>=2026.8.1` (provision at `latest`) | Agent runtime under test | `npm view openclaw dist-tags --json` → `latest: 2026.9.6` `[VERIFIED: npm registry]` |
| Node.js | `>=24.16.0 <25` or `>=26.1.0` | OpenClaw runtime dependency | `npm view openclaw@latest engines --json` → matches docs exactly `[VERIFIED: npm registry]` |
| Docker | latest stable | Standalone-path agent sandbox; NemoClaw's own installer dependency | Not yet installed on target host; installer-managed |
| NemoClaw | `>=v0.0.128` | Orchestration/security layer for the OpenShell path | `[ASSUMED — websearch synthesis]`, re-verify via `nemoclaw --version` live |
| sqlite3 (CLI) | 3.46.1 (already present) | Direct-read candidate (D-01a) tooling | `[VERIFIED: live probe]` — no install step needed |
| sshfs | 3.7.3-1.1build5 (apt-available, not installed) | Host↔sandbox state channel for NemoClaw metering | `[VERIFIED: live probe — apt-cache policy]` |

### Alternatives Considered

| Instead of | Could use | Tradeoff |
|------------|-----------|----------|
| `curl \| bash` OpenClaw installer | `npm install -g openclaw@latest --allow-scripts=openclaw` + `openclaw onboard --install-daemon` | Manual path gives explicit control over Node provisioning but does not self-provision Node — use only if the curl installer's Node auto-provisioning conflicts with a pinned Node version elsewhere on the host |
| Direct SQLite read (D-01a) | `openclaw sessions export-trajectory` (D-01b) | CLI export avoids undocumented-schema risk but has unconfirmed cron-unattended approval gating and unconfirmed field-level fidelity — exactly why D-01 mandates testing both |

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Detecting whether a SQLite read will race a live writer | A custom retry/backoff loop around raw `sqlite3` calls | `PRAGMA busy_timeout=<ms>` + a `mode=ro` URI connection | SQLite's own retry primitive is battle-tested; a hand-rolled retry loop risks papering over a genuine lock-window bug rather than surfacing it, which defeats D-04's "zero `SQLITE_BUSY` errors" bar (you want to *see* the busy error if it happens, not silently retry past it during the soak measurement) |
| Comparing CalVer-style version strings (`2026.9.1` vs `2026.8.1`) | A hand-rolled string-split comparator | `sort -C -V` (already the pattern `.planning/research/ARCHITECTURE.md §7` recommends and this project's `install.sh` macOS-refusal precedent uses) | Portable, already proven in this codebase; a hand-rolled comparator is exactly the kind of thing that breaks on an edge case like `2026.9.1-beta.1` |
| Ground-truth completion counting for the soak | A new counting script | `scripts/verify-markers.sh`'s existing completions-vs-markers accounting, adapted | Already exists, already proven, avoids introducing a fourth source of truth into an already three-way read-path bake-off |

**Key insight:** every "don't hand-roll" item in this phase is about not inventing new plumbing when the project (or SQLite itself) already has a proven primitive — this phase's job is to pick the *existing* mechanism that clears the fidelity/determinism/concurrency bars, not to build a new one.

## Architecture Patterns

### System Architecture Diagram

```
                 ┌─────────────────────────────────────────────┐
                 │              52.90.9.242 (bare Ubuntu)        │
                 │                                               │
   provision-2-0-host.sh                                        │
   (SPIKE-00, idempotent)                                        │
                 │                                               │
     ┌───────────┴────────────┐          ┌──────────────────────┴──┐
     ▼                        ▼          ▼                          │
┌─────────────┐      ┌────────────────┐  │  ┌────────────────────┐ │
│ Standalone   │      │ NemoClaw CLI   │  │  │ OpenShell sandbox   │ │
│ OpenClaw     │      │ (host-side)    │──┼─▶│ (Nemotron agent)     │ │
│ + Docker     │      └────────────────┘  │  └────────┬────────────┘ │
│ (Claude agent)│                          │           │              │
└──────┬───────┘                          │  SSHFS share mount        │
       │                                  │           │              │
       │  writes                         │           │  writes      │
       ▼                                  │           ▼              │
┌─────────────────────┐                  │   /sandbox/.openclaw/     │
│ ~/.openclaw/agents/  │                  │   agents/.../*.sqlite     │
│  <id>/agent/         │                  │           │              │
│  openclaw-agent.sqlite│                 │   (mounted at host path) │
└──────┬───────────────┘                  └───────────┼──────────────┘
       │                                               │
       │        ┌──────────────────────────────────────┘
       ▼        ▼
  ┌───────────────────────────────────────────────────┐
  │   SPIKE-01 three-way read-path bake-off             │
  │   (a) sqlite3 file:<path>?mode=ro direct read        │
  │   (b) openclaw sessions {list,tail,export-trajectory}│
  │   (c) plugin-hook sidecar (llm_output+after_tool_call)│
  └──────────────────┬───────────────────────────────────┘
                      ▼
        ranked by fidelity (D-02) → written determination
                      │
   ┌──────────────────┼────────────────────────────────────┐
   ▼                  ▼                                    ▼
SPIKE-02          SPIKE-03                              SPIKE-04
hook matrix       command-dispatch:tool                  concurrency soak
(both pairings,   scope-check first,                     (per-minute cron,
6 fixed hooks)    then cross-model soak                  live agent traffic,
                  if scope check passes                  zero-loss vs ground truth)
   │                  │                                    │
   └──────────────────┴────────────────────────────────────┘
                      ▼
        .planning/spikes/007-011/README.md (D-09)
                      ▼
        spike-findings-openclaw-revenium skill re-scope (D-10)
                      ▼
              Phases 18-24 (gated on these facts)
```

### Recommended Project Structure (spike artifacts, per D-09/D-11)

```
.planning/spikes/
├── 007-<name>/           # SPIKE-00 host provisioning
│   ├── provision-2-0-host.sh   # idempotent, committed (D-14)
│   └── README.md               # verdict + evidence (D-12)
├── 008-<name>/           # SPIKE-01 session read path
│   ├── probe-sqlite-direct.sh  # throwaway, evidence not code (D-11)
│   ├── probe-cli-export.sh
│   ├── probe-sidecar-plugin/   # if sidecar candidate is tested
│   ├── schema-capture.sql.txt  # verbatim `sqlite3 .schema` output (D-11)
│   └── README.md
├── 009-<name>/           # SPIKE-02 hook matrix
│   └── README.md               # matrix table, both pairings
├── 010-<name>/           # SPIKE-03 command-dispatch:tool
│   └── README.md               # scope-check result + (if applicable) determinism run
└── 011-<name>/           # SPIKE-04 concurrency soak
    └── README.md               # soak log, zero-loss evidence
```
(Numbering/granularity is Claude's Discretion per CONTEXT.md — this is the natural mapping given D-09 names `007–011` for the five requirements, but the planner may split further if a question needs its own dir.)

### Pattern 1: Read-only WAL-aware SQLite probing
**What:** Open the live session SQLite file without risking a write lock or corrupting the running Gateway's state.
**When to use:** Every SPIKE-01(a) and SPIKE-04 probe against `openclaw-agent.sqlite`, on both the standalone host path and the NemoClaw SSHFS-mounted path.
**Example:**
```bash
# Source: mechanics cross-checked from sqlite.org/forum + sqlite/sqlite doc/wal-lock.md
# (websearch --verified = MEDIUM confidence; re-confirm against the live file's
# actual journal_mode before relying on this — 2.0 could conceivably not use WAL).
sqlite3 "file:${SQLITE_PATH}?mode=ro" \
  "PRAGMA busy_timeout=5000; .schema" > schema-capture.sql.txt
```

### Pattern 2: Slash-command scope probe before a multi-model soak
**What:** Before running SPIKE-03's cross-model determinism soak (D-05/D-06), first confirm `command-dispatch: tool` even applies to the call shape in question.
**When to use:** SPIKE-03, as the very first sub-step, per the Critical Scope Finding above.
**Example:**
```yaml
# In a throwaway test skill's frontmatter (not the production SKILL.md):
---
command-dispatch: tool
command-tool: write-marker-test
command-arg-mode: raw
---
```
Then attempt to trigger it from within an agent turn's own tool-call flow (not a human typing the slash command) and observe whether the dispatch fires. A failure to fire this way is evidence for "mechanism inapplicable," not evidence that needs a second model to confirm.

### Anti-Patterns to Avoid
- **Assuming the CLI export path is safe for unattended cron just because it's "the documented surface":** `export-trajectory`'s "owner-approved exec request" language is a real, unconfirmed gate — treat it as guilty until proven innocent live, not innocent because it's official.
- **Running the SPIKE-02 hook matrix and SPIKE-04 soak as fully separate live sessions:** both need sustained live agent traffic across both pairings; running them concurrently against the same traffic saves host time and avoids re-deriving "how do I generate qualifying turns" twice.
- **Treating a `command-dispatch: tool` failure-to-fire on Nemotron as a cross-model determinism finding:** per the Critical Scope Finding, check applicability on *either* model first — a failure on the first model tested could be a scope problem, not a model problem, and conflating the two produces a wrong verdict category in the write-up.

## Package Legitimacy Audit

Not applicable — this phase adds no new npm/pip/cargo dependency for the skill's own codebase. It verifies version floors of four already-established, already-in-use external tools (`openclaw`, `node`, `docker`, `nemoclaw`) and one CLI already present on the host (`sqlite3`). `openclaw`'s registry presence was re-confirmed live this session (`npm view openclaw dist-tags/engines`) as a version-floor check, not a new-package legitimacy check — no `SLOP`/`SUS` classification applies to a package this project has depended on since `plugin/package.json:14`'s existing `peerDependencies` entry.

## Common Pitfalls

### Pitfall 1: Treating `command-dispatch: tool` as a hooks-API answer to attribution
**What goes wrong:** Spending the full cross-model soak window (D-05) on `command-dispatch: tool` before confirming it can even be triggered outside a human-typed slash command, then discovering afterward that the entire premise doesn't apply to agent-initiated marker-writing.
**Why it happens:** CONTEXT.md's own framing ("does `command-dispatch: tool` make marker-writing dispatch deterministic") already assumes applicability; the documented spec (slash-command routing) doesn't confirm that assumption.
**How to avoid:** Run the cheap scope-probe (Pattern 2) first; only proceed to the full determinism soak if it fires for an agent-initiated (not human-typed) trigger.
**Warning signs:** The skill's own command definition has no slash-command surface today (marker-writing is invoked via SKILL.md instructions, not `/write-marker`) — if that's still true when the spike starts, the scope gap is not hypothetical, it's already visible in the existing architecture.

### Pitfall 2: Reading the SQLite file directly without a `mode=ro` + `busy_timeout` connection string
**What goes wrong:** A default `sqlite3 <path>` connection can, under WAL-lock-window edge cases, either wait indefinitely or fail unpredictably depending on the client library's default busy behavior, producing an inconsistent SPIKE-04 soak result that looks like intermittent flakiness rather than a measured, reproducible finding.
**Why it happens:** The CLI does not set a busy timeout by default; only the Python stdlib `sqlite3` module documented in this research sets one (5s) implicitly.
**How to avoid:** Always set `PRAGMA busy_timeout` explicitly and use a `mode=ro` URI, per Pattern 1, in every probe script — not just the "final" one.
**Warning signs:** Soak logs show occasional multi-second stalls with no `SQLITE_BUSY` error recorded — that's the CLI silently waiting, not a clean pass.

### Pitfall 3: Conflating "SSHFS-mounted SQLite" behavior with "host-local SQLite" behavior
**What goes wrong:** SPIKE-01/04 validate the direct-read candidate against the standalone path's local filesystem, generalize the finding to the NemoClaw path, and miss an SSHFS-specific lock/cache issue that only appears over the mount.
**Why it happens:** Both paths use the same underlying SQLite file format, so it's tempting to treat "SQLite reads fine" as a single fact rather than two.
**How to avoid:** Explicitly run every SPIKE-01(a)/SPIKE-04 probe as two cells — host-local and SSHFS-mounted — per D-07's "both production pairings" requirement and this project's own documented SSHFS-cache-lag precedent.
**Warning signs:** The written determination cites only one host path's evidence for a claim that's supposed to cover both install paths.

### Pitfall 4: Reusing a patched/leftover sandbox instead of the fresh `52.90.9.242` provision
**What goes wrong:** Carrying forward unknown pre-2.0 state from a hand-patched host (exactly the trap `.planning/research/PITFALLS.md` Pitfall 9 already names, and this project's own `MEMORY.md` documents happening once already with a stale ClawHub install).
**Why it happens:** Reusing a working sandbox is faster than re-provisioning.
**How to avoid:** `provision-2-0-host.sh` must be run start-to-finish on `52.90.9.242` and the resulting versions recorded — this is also why D-14 requires the script to be re-runnable (Phase 22 and Phase 24 need it again on fresh state).
**Warning signs:** A finding cites a version that doesn't match what the provisioning script's own output recorded.

## Code Examples

### Verified live-host probe commands (already run this session, safe to re-run)
```bash
# Source: live ssh probe, ubuntu@52.90.9.242, 2026-09-24 [VERIFIED]
ssh -i ~/.ssh/hermes-sandbox.pem ubuntu@52.90.9.242 \
  "uname -a; lsb_release -a; free -h; df -h /; nproc; sudo -n true && echo SUDO_OK"
```

### npm registry version-floor check (re-run at provisioning time, not trusted stale)
```bash
# Source: npm registry, live-queried this session [VERIFIED: npm registry]
npm view openclaw dist-tags --json
npm view openclaw@latest engines --json
```

### Read-only WAL-aware schema capture (SPIKE-01a, D-11's literal-capture requirement)
```bash
# Source: mechanics per sqlite.org/forum + sqlite/sqlite doc/wal-lock.md
sqlite3 "file:${HOME}/.openclaw/agents/main/agent/openclaw-agent.sqlite?mode=ro" \
  "PRAGMA busy_timeout=5000; .schema" | tee schema-capture.sql.txt
```

## State of the Art

| Old Approach (pre-2.0, this project) | Current Approach (2.0-era, per docs) | When Changed | Impact |
|--------------------------------------|----------------------------------------|---------------|--------|
| Read `agents/main/sessions/*.jsonl` directly | Session data lives in per-agent SQLite; JSONL archived, not runtime-read | `2026.8.1` (2026-08-30) | `report.sh`/`get-root-session-id.py`/`guardrail-check.sh` read a path that no longer receives writes — this is the reason Phase 17 exists |
| Resolve current session by globbing newest `*.jsonl` | No confirmed CLI/hook equivalent found in docs this session | Unclear — needs live confirmation | D-03's second determination remains genuinely open |
| `command-dispatch` field absent from SKILL.md frontmatter | `command-dispatch: tool` / `command-tool` / `command-arg-mode` fields exist | 2.0-era skill format | Scoped to slash-command routing per docs — see Critical Scope Finding |
| `allowConversationAccess` as the sole hook permission gate | A second gate, `allowPromptInjection`, exists for prompt-mutation hooks — defaults to *allowed* | 2.0-era plugin permission model | May mean PLUG-02's fix is smaller than assumed; needs live confirmation, not doc-inference |

**Deprecated/outdated:**
- Direct JSONL parsing of `agents/main/sessions/*.jsonl` for live data — archived-only after the one-time migration, per `[CITED: docs.openclaw.ai/cli/doctor/sqlite-maintenance]`.
- A plausible-sounding `openclaw sessions export` command — researched by a prior pass and explicitly retracted as nonexistent; do not resurrect it in planning.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | NemoClaw `v0.0.128` bundles managed images with OpenClaw `2026.9.1` and Hermes `0.21.3`, and "completes more OpenShell lifecycle ownership" handback | Host Provisioning, item 10 | Low — this is a descriptive fact about a third-party release, not a design decision; SPIKE-00's live `nemoclaw --version`/`nemoclaw status` probe will confirm or correct it at negligible cost |
| A2 | `openclaw doctor --fix` is idempotent, safe to re-run, and has a `--non-interactive` flag | Host Provisioning, item 8 | Low for Phase 17 (not required this phase); Medium for Phase 18 (GATE-03) if the exact flag behavior differs — re-fetch `docs.openclaw.ai/cli/doctor` directly rather than the secondary-summary sources used this session |
| A3 | The Doctor tool's documented "read-only modes don't need the exclusive lock" pattern generalizes to a third-party (this skill's) read-only SQLite connection made while the Gateway is running | Session Read Path, WAL concurrency bullet | Medium — if wrong, SPIKE-04's soak will surface it directly as `SQLITE_BUSY` errors, so the risk is self-correcting within the phase, not silently carried forward |
| A4 | SPIKE-04's "sustains per-minute cron polling" scope covers only the read mechanism generically, not necessarily both install-path pairings the way SPIKE-02/03 explicitly do | Concurrency Soak Design Inputs | Medium — if the planner assumes single-pairing scope and the user intended both, the soak needs re-running on the second pairing later; flagged as an Open Question below so this gets confirmed before planning locks scope |

## Open Questions

1. **Does `command-dispatch: tool` apply to non-slash-command, agent-initiated actions at all?**
   - What we know: the documented spec is slash-command routing, bypassing model judgment for that invocation.
   - What's unclear: whether an undocumented adjacent mechanism exists, or whether the skill's own marker-writing instruction could be restructured as an agent-invoked slash command to make the mechanism applicable.
   - Recommendation: SPIKE-03 runs the cheap scope-probe (Pattern 2) before the cross-model soak; if scope fails, record verdict as "NO — mechanism inapplicable to this call shape" and let D-06's binary-NO consequences (ATTR-01 → Future Requirements, Phase 21 deleted) follow from that, not from a cross-model comparison that never needed to run.

2. **Is SPIKE-04's soak scoped to one install-path pairing or both?**
   - What we know: D-07 explicitly binds SPIKE-02 and SPIKE-03 to both pairings; SPIKE-04's own REQUIREMENTS.md wording ("sustains per-minute cron polling without degrading the host") doesn't repeat that binding explicitly.
   - What's unclear: whether the user intends the soak proven once (on whichever path is simpler to instrument) or on both paths given the SSHFS-specific risk noted in Pitfall 3.
   - Recommendation: plan for both, since the NemoClaw path's SSHFS+SQLite combination is a materially different risk profile than host-local SQLite reads (per the WAL/SSHFS finding above) — confirm with the user during planning if the extra soak time is not wanted.

3. **What exact table/column names does `openclaw-agent.sqlite` use?**
   - What we know: conceptual `SessionEntry` fields and transcript event *types* are documented; no SQL schema is published.
   - What's unclear: everything at the SQL level — this is D-11's entire reason for existing.
   - Recommendation: capture verbatim via `sqlite3 <path> .schema` on the live host per Pattern 1/Code Examples; do not attempt to guess or infer from the conceptual field list.

4. **Does `openclaw sessions export-trajectory` require interactive owner approval when invoked directly from a script (not via `/export-trajectory`)?**
   - What we know: docs describe it as reachable "after the owner approves the exec request" via the slash command; the CLI's own approval-gating when invoked directly is not documented.
   - What's unclear: whether an unattended cron-driven call would hang waiting for approval, fail outright, or succeed silently.
   - Recommendation: SPIKE-01(b) must test this directly and record the exact behavior — this determines whether candidate (b) is even viable for a per-minute cron at all, independent of its fidelity gaps.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| SSH access to `52.90.9.242` | Every SPIKE-00..04 probe | ✓ (verified live this session) | key `~/.ssh/hermes-sandbox.pem` | — |
| `sqlite3` CLI on target host | SPIKE-01(a), SPIKE-04 | ✓ | 3.46.1 | — |
| `sshfs` on target host | NemoClaw metering-mount pattern (D-13) | ✗ (apt-available: 3.7.3-1.1build5) | — | `sudo apt-get install -y sshfs` as a provisioning step |
| Node.js on target host | OpenClaw runtime | ✗ | — | OpenClaw's own installer self-provisions; no separate fallback needed |
| Docker on target host | Standalone sandbox + NemoClaw dependency | ✗ | — | NemoClaw's installer manages Docker; standalone path may need its own explicit install if provisioned independently |
| `openclaw` CLI on target host | All spikes | ✗ | — | Install via `curl -fsSL https://openclaw.ai/install.sh \| bash` |
| `nemoclaw` CLI on target host | SPIKE-00 (NemoClaw path), SPIKE-02/03/04 Nemotron pairing | ✗ | — | Install via documented non-interactive curl installer (see Host Provisioning item 9) |
| GPU (NVIDIA) on target host | — | ✗ (confirmed `nvidia-smi` absent) | — | Not required — inference for both paths routes to a cloud provider (Anthropic API, NVIDIA cloud) per D-16's real-key requirement |
| Real Anthropic API key | Standalone-path live turns (D-16) | Not probed this session — must be provisioned per D-16 | — | Blocking if absent — SPIKE-01/02/04 require real turns, not dummy-key stubs (v1.4's spike 003 stalled at PARTIAL on exactly this) |
| Real NVIDIA API key | NemoClaw-path live turns (D-16) | Not probed this session — must be provisioned per D-16 | — | Same as above |
| Real Revenium API key + `api.revenium.ai` egress preset | SPIKE-01/04's per-completion metering evidence | Not probed this session — must be provisioned per D-16 | — | Blocking if absent |

**Missing dependencies with no fallback:**
- Real Anthropic key, real NVIDIA key, real Revenium key — D-16 already mandates these be provisioned; flagging here only to confirm this is a provisioning-script step, not something to discover missing mid-spike.

**Missing dependencies with fallback:**
- `sshfs`, `node`, `docker`, `openclaw`, `nemoclaw` — all installer-recoverable per the commands captured in Host Provisioning above.

## Validation Architecture

> `workflow.nyquist_validation` is `true` in `.planning/config.json`. This phase produces no application code and no automated test suite — its "tests" are the live probes and evidence-capture commands themselves (D-12's evidence standard). The table below maps each phase requirement to its verification command instead of a unit-test invocation, consistent with how a fact-finding phase's "Nyquist sampling" actually works: the sample rate is per-probe, not per-commit.

### Test Framework
| Property | Value |
|----------|-------|
| Framework | None — this phase's verification unit is a live command + pasted raw output (D-12), not an automated assertion |
| Config file | none |
| Quick run command | Re-run any single probe command from `## Code Examples` against the live host |
| Full suite command | Re-run `provision-2-0-host.sh` end-to-end plus all four spike probe scripts in sequence |

### Phase Requirements → Verification Map
| Req ID | Behavior | Verification Type | Command | Evidence Exists? |
|--------|----------|-----------|-------------------|-------------|
| SPIKE-00 | Host reaches the four version floors, reproducibly | live probe | `bash provision-2-0-host.sh && openclaw --version && node --version && docker --version && nemoclaw --version` | ❌ Wave 0 — script not yet written |
| SPIKE-01 | Chosen read mechanism captures completions/toolCalls/parentage with zero loss | live probe, three-way comparison | probe scripts per candidate (a)/(b)/(c) above, output diffed against a known turn count | ❌ Wave 0 |
| SPIKE-02 | Each of 6 fixed hooks fires (or doesn't) per pairing, recorded | live probe | trigger one qualifying turn per hook per pairing; assert via hook's own log/counter | ❌ Wave 0 |
| SPIKE-03 | `command-dispatch: tool` scope + (if applicable) cross-model determinism | live probe | Pattern 2 scope probe, then (if scoped-in) a sustained two-model run | ❌ Wave 0 |
| SPIKE-04 | Zero `SQLITE_BUSY`/lock errors, zero missed completions, over a soak window with live traffic | live probe | per-minute cron against `verify-markers.sh`-style ground truth, sustained window | ❌ Wave 0 |

### Sampling Rate
- **Per probe:** run once, capture raw output verbatim (D-12) — no automated re-run cadence within the phase.
- **Phase gate:** all five README.md determinations written and consumable (per the phase's stated success criteria) before `/gsd-verify-work`.

### Wave 0 Gaps
- [ ] `provision-2-0-host.sh` — does not yet exist; SPIKE-00's core deliverable
- [ ] Probe scripts for SPIKE-01(a)/(b)/(c) — do not yet exist
- [ ] A shared long-running live-traffic harness for SPIKE-02/04 (recommended to share, per Architecture Patterns' Anti-Patterns note) — does not yet exist
- [ ] SPIKE-03's scope-probe skill fragment — does not yet exist

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | This phase provisions credentials for external services (Anthropic, NVIDIA, Revenium); it does not build an authentication system |
| V3 Session Management | No | Not applicable — "session" here means OpenClaw agent sessions, a data-model concern already covered under Standard Stack/Architecture, not an ASVS session-management control |
| V4 Access Control | No | No access-control logic is built this phase |
| V5 Input Validation | No | No user-facing input surface is built this phase (probe scripts consume host/CLI output, not untrusted external input) |
| V6 Cryptography | Yes (secrets handling, not cryptographic implementation) | Real API keys (Anthropic, NVIDIA, Revenium — D-16) must be provisioned on the shared host without committing them to the repo; use the same pattern the project already uses for SOPS-managed secrets (per `MEMORY.md`'s "revenium reads key from `api-key:` field" note) or an equivalent env-var/`config.yaml`-not-in-git pattern already established in `.planning/spikes/003-revenium-cli-in-sandbox/` |

### Known Threat Patterns for this phase's stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Real API keys landing in shell history, `ps aux`, or committed spike scripts | Information Disclosure | Pass keys via env vars sourced from a mode-600 file (established pattern: `install-nemoclaw-cron.sh`'s "Writes the host-side auth env at mode 600" per that script's own header comment read this session), never as inline CLI args — note the already-known NemoClaw CVE-class issue (`NVIDIA/NemoClaw#579`, "NVIDIA API Key Exposed in Process Arguments," surfaced during this session's websearch) as direct precedent for why this matters on this exact stack |
| Shared host (D-13) — a standalone-path probe accidentally reads/writes NemoClaw sandbox state or vice versa | Tampering (accidental, not adversarial) | Record which context (standalone vs. NemoClaw) produced every finding, per D-13's explicit named risk; keep probe scripts scoped to one path's paths (`~/.openclaw/` vs. the SSHFS mount point) rather than a shared "OPENCLAW_HOME"-style ambiguity during the spike itself |
| Spike transactions landing in the real Revenium tenant (D-16 — deliberately no scratch scope) | (Not a STRIDE threat — a deliberate, informed data-hygiene tradeoff) | No mitigation needed beyond what D-16 already states; flagging only so the planner does not add an unrequested scratch-tenant task |

## Sources

### Primary (CITED — official docs, fetched directly this session)
- docs.openclaw.ai/cli/doctor/sqlite-maintenance — SQLite file location, JSONL-archived-not-runtime-read, Doctor subcommand lock semantics
- docs.openclaw.ai/reference/session-management-compaction/schema — `SessionEntry` conceptual fields, transcript event types
- docs.openclaw.ai/tools/creating-skills — `command-dispatch`/`command-tool`/`command-arg-mode` field definitions
- docs.openclaw.ai/install/node — Node version floor, SQLite-TEXT-truncation upgrade-order warning
- docs.openclaw.ai/install — recommended install commands (curl script, npm alternative)
- docs.openclaw.ai/plugins/hooks/reference — full hook catalog, per-hook type/timeout/behavior
- docs.openclaw.ai/plugins/hooks — `allowConversationAccess`/`allowPromptInjection` permission gates, default-allowed nuance
- docs.openclaw.ai/cli/sessions — `sessions list/tail/export-trajectory` flags and documented output shapes/redaction

### Secondary (MEDIUM confidence — websearch cross-checked, or this project's own prior-session research)
- .planning/research/ARCHITECTURE.md, PITFALLS.md, FEATURES.md, SUMMARY.md — this milestone's own upstream research, read in full this session
- .planning/spikes/CONVENTIONS.md, MANIFEST.md — established v1.4 spike patterns this phase must follow (D-09)
- sqlite.org/forum, sqlite/sqlite doc/wal-lock.md, hynek.me — WAL concurrency mechanics, cross-checked across multiple sources

### Tertiary (LOW confidence — single websearch pass, not independently re-fetched)
- docs.nvidia.com/nemoclaw NemoClaw v0.0.128 release-note content (summarized via websearch, not directly fetched this session)
- kaxo.io/stack-junkie.com secondary summaries of `openclaw doctor --fix` behavior (re-fetch `docs.openclaw.ai/cli/doctor` directly before Phase 18)
- NVIDIA/NemoClaw#579 (API-key-in-process-args issue) — surfaced via websearch, informs the Security Domain section's mitigation but not independently confirmed against the issue tracker directly

### Live-verified this session (VERIFIED)
- `npm view openclaw dist-tags --json` / `npm view openclaw@latest engines --json` — registry state
- `ssh ubuntu@52.90.9.242` probes — host OS, RAM, disk, sudo, installed tooling
- `.planning/spikes/CONVENTIONS.md`, `.planning/spikes/MANIFEST.md`, `scripts/report.sh`, `scripts/common.sh`, `scripts/get-root-session-id.py`, `scripts/write-marker.sh`, `scripts/write-job-marker.sh`, `scripts/verify-markers.sh`, `scripts/guardrail-check.sh`, `scripts/nemoclaw-cron-tick.sh`, `scripts/install-nemoclaw-cron.sh` — read directly, line ranges quoted verbatim in-line above

## Metadata

**Confidence breakdown:**
- Host provisioning facts: MEDIUM-HIGH — version floors independently confirmed via live `npm view` and live SSH probe; install-script commands from official docs, not yet re-run end-to-end on the target host
- Session read path candidates: MEDIUM — official docs directly fetched this session confirm structural facts (no table names published, `sessions tail` redacts, `export-trajectory` approval-gating unconfirmed) but the actual SPIKE-01 ranking requires the live host, which is this phase's job, not this research's
- Hook matrix inputs: MEDIUM-HIGH — full hook catalog and permission-gate wording directly fetched and quoted; per-model firing behavior (the actual SPIKE-02 question) remains genuinely unknown until probed live
- `command-dispatch: tool` scope finding: MEDIUM — directly fetched from official docs; this is the highest-value finding of this research pass precisely because it reframes SPIKE-03's sequencing, not because the docs themselves are uncertain
- Concurrency/WAL mechanics: MEDIUM — cross-checked across multiple sources (sqlite.org forum, official SQLite doc, a well-corroborated blog post), general SQLite knowledge not OpenClaw-specific

**Research date:** 2026-09-24
**Valid until:** 7 days for the live-host-specific facts (host state, npm `latest` resolution) — this is an actively-moving CalVer line and a shared host whose state can change; 30 days for the general SQLite WAL mechanics and documented hook-permission model, which are stable platform facts
