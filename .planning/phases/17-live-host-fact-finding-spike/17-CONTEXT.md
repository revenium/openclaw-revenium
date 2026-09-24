# Phase 17: Live-Host Fact-Finding Spike - Context

**Gathered:** 2026-09-23
**Status:** Ready for planning

<domain>
## Phase Boundary

This phase delivers **facts, not ported code**. Two outputs:

1. A live, reproducibly-provisioned OpenClaw 2.0 host carrying **both** production install paths (standalone OpenClaw + Docker, and NemoClaw/OpenShell).
2. Four written, evidence-backed determinations (SPIKE-01 through SPIKE-04) that Phases 18–24 are built on top of.

Nothing in `scripts/`, `plugin/`, or `plugin-nemoclaw/` is ported, rewritten, or fixed here. Probe code written during this phase is throwaway evidence, not a deliverable. The phase ends when the determinations are written and consumable, not when a read path works.

**Requirements:** SPIKE-00, SPIKE-01, SPIKE-02, SPIKE-03, SPIKE-04 (see `.planning/REQUIREMENTS.md`).

</domain>

<decisions>
## Implementation Decisions

### Read-Mechanism Investigation (SPIKE-01, SPIKE-04)

- **D-01:** SPIKE-01 exercises **all three** candidate read paths on the live host and ranks them: (a) direct `sqlite3` against `~/.openclaw/agents/<agentId>/agent/openclaw-agent.sqlite`, read-only and WAL-aware; (b) the real `openclaw sessions` subcommands (note: plain `sessions export` was researched and confirmed **not to exist**); (c) a plugin-hook sidecar in which the skill captures completions itself into a format we own. The sidecar is included deliberately — it is the only candidate immune to OpenClaw changing its storage again.
- **D-02:** The ranking criterion is **data fidelity first**. The winner is whichever mechanism yields everything `report.sh` needs today — per-completion token usage, model id, toolCalls, and session parentage — with zero loss. Performance and drift-resistance break ties only. Rationale: a mechanism that is fast but silently drops token counts reproduces the exact fail-open blackout this milestone exists to close.
- **D-03:** SPIKE-01 returns **two** determinations, not one — content reading *and* current-session-id resolution. Scouting found the JSONL dependency is wider than research reported: `write-marker.sh:66`, `write-job-marker.sh:132`, `verify-markers.sh:91`, and `guardrail-check.sh:496` resolve "which session am I in right now" by globbing the newest non-cron `*.jsonl` filename and never read message content at all. Answering only the content half leaves four scripts with no fact to port against in Phase 19.
- **D-04:** SPIKE-04's pass bar is a **concurrency soak with zero loss**: the tick runs on a real per-minute cron for a sustained window *while an agent is actively producing turns*, and passes only on zero lock/`SQLITE_BUSY` errors and zero missed completions measured against a ground-truth count. Resource metrics may be recorded but are not the bar. Rationale: the failure mode that matters is reading a store the agent is concurrently writing, and a fail-open miss is invisible.

### Verdict Bars & Model Coverage (SPIKE-03, SPIKE-02)

- **D-05:** SPIKE-03 returns "yes" only on **determinism across models** — the marker write dispatching on every qualifying turn across at least two models, including one from the class that previously broke observation (Nemotron routing exec through `tool_search_code`, the B-05 failure), over a run long enough that "the model happened to comply" is not a viable explanation. A single-model pass is not a yes.
- **D-06:** The verdict is **binary**. The likely real outcome — works on model A, not model B — counts as **NO**: ATTR-01 moves to REQUIREMENTS.md Future Requirements, Phase 21 is deleted, and the existing marker architecture ports as-is under Phase 20. No three-state "yes-but-model-gated" verdict. Rationale: ATTR-01 exists to remove model dependence; a model-gated deterministic dispatch is the same dependence wearing a new mechanism, and shipping it means maintaining two marker paths — the thing PITFALLS.md names as what made the CalVer line fragile. — **Reversibility:** costly — reversing after Phase 21 is deleted and ATTR-01 is moved requires re-running cross-model spike work on a host that may already be torn down.
- **D-07:** "Across at least two models" means **both production pairings**: standalone OpenClaw + Claude, and NemoClaw/OpenShell + Nemotron. This is the pairing research named for the hook matrix, and Nemotron is the model with the known prior failure, so it must be in the sample. This applies to SPIKE-02's matrix as well as SPIKE-03. Consequence: both install paths must be live on the host during Phase 17.
- **D-08:** SPIKE-02's matrix covers **every hook the skill depends on**, fixed in advance so "fires / doesn't fire" is comparable across both pairings: `before_prompt_build`, `after_tool_call`, `before_agent_finalize`, `subagent_spawned`, `subagent_ended`, plus `session_end` **recorded rather than skipped** (upstream issue #155696 reports its payload is broken for SQLite-backed sessions — the spike either confirms or retires that for us). Each of these is load-bearing for a named v2.0 requirement (PLUG-03, PLUG-05, the compliance gate, PLUG-04/READ-03).

### Findings Artifacts & Evidence

- **D-09:** Determinations live in **`.planning/spikes/007–011/README.md`**, following the existing format in `.planning/spikes/CONVENTIONS.md`, with `MANIFEST.md` rows added — the same structure v1.4's six spikes used to feed Phases 12–16. Phase SUMMARY docs alone are insufficient: anti-pattern rules cap how deeply later phases read transitive prior SUMMARYs, and Phase 24 sits seven phases downstream of these facts.
- **D-10:** Findings are then **wrapped into the project-local findings skill** so downstream agents auto-load them, by **re-scoping the existing `spike-findings-openclaw-revenium` skill** to whole-project live-host findings rather than creating a second skill. Broaden its description and the CLAUDE.md routing line, and add a new topic reference file alongside the existing four in `references/`. Its references are already split by topic rather than by milestone, so a new topic file matches the structure and keeps it to one load for a downstream agent. — **Reversibility:** costly — CLAUDE.md routing and the skill description are what make the facts discoverable; splitting them later means re-deciding which facts belong where.
- **D-11:** The spike hands Phase 19 **throwaway probes plus a verbatim schema capture**, not a reference implementation. Probe scripts stay in the spike dirs as evidence; the artifacts include `sqlite3 .schema` output and sample rows captured literally. Phase 19 writes production code from scratch against project conventions. Rationale: the schema is UNVERIFIED today and capturing it literally is the single most valuable artifact the spike produces — but spike-grade code (no error handling, host-specific paths) becoming production by inertia is a known trap. Precedent: `probe-host-compat.sh` earned promotion into `scripts/` only after the real build needed exactly that shape.
- **D-12:** Evidence standard: every claim carries the **exact command run, its raw output pasted (trimmed, never paraphrased), the host, the date, and the OpenClaw / NemoClaw / Node versions in effect**. Rationale: this project has already been burned by a researched-then-retracted nonexistent CLI command, and by "marked shipped" differing from "works on a clean host". A claim that cannot be re-run is indistinguishable from one inferred from docs.

### Host Provisioning & Credentials (SPIKE-00)

- **D-13:** **One host, both paths.** `52.90.9.242` (bare Ubuntu 26.04, `ssh -i ~/.ssh/hermes-sandbox.pem ubuntu@`) carries standalone OpenClaw + Docker *and* NemoClaw/OpenShell running a sandbox. The NemoClaw path already requires a host-side OpenClaw-reading cron over SSHFS, so the two coexist by design. **Named risk:** a shared host means a standalone-path experiment can perturb sandbox state — every finding must record which context produced it.
- **D-14:** Reproducibility takes the form of an **idempotent `provision-2-0-host.sh` committed under the spike dir** — re-runnable, each step gated on a detection check, recording the version floors (OpenClaw `>=2026.8.1`, Node `>=24.16`, Docker, NemoClaw `>=v0.0.128`, revenium CLI). Rationale: Phase 22 needs a freshly-provisioned sandbox and Phase 24 needs a fresh host for post-publish verification, so the script gets used at least twice more.
- **D-15:** Version policy is **provision at `latest`, record exactly what resolved**. Install whatever `latest` gives on the standalone path; let NemoClaw provision whatever it provisions in-sandbox (0.0.128 manages OpenClaw `2026.9.1`, which is not ours to choose); record both resolved versions verbatim in the findings and in the script's output. The two paths will therefore not necessarily run the same OpenClaw — that is expected and must be recorded, not normalized away. Rationale: the gate floor is already fixed at `2026.8.1`; what the spike needs to know is how the runtime behaves at or above the floor *as users will actually get it*.
- **D-16:** **Real keys, spike-scoped.** Provision a real model key (Anthropic / NVIDIA) and a real Revenium API key on the host, with the `api.revenium.ai` egress preset applied per spike 002. Rationale: SPIKE-01's bar is per-completion token usage with zero loss and SPIKE-04's is zero missed completions against ground truth — neither is answerable without real turns and a real meter call. v1.4's spike 003 stalled at PARTIAL precisely because it ran on a dummy key. Spike transactions land in the normal Revenium tenant; no scratch scope.

### Claude's Discretion
No area was handed to Claude wholesale. Left to the planner within the bars above: soak-window and determinism-run durations, spike-dir numbering granularity (one dir per SPIKE-nn vs one per question actually asked), whether `MANIFEST.md`'s Requirements section accrues 2.0 constraints as they are found, and the escalation path if no read candidate clears the fidelity bar.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Milestone scope and research basis
- `.planning/REQUIREMENTS.md` — SPIKE-00..04 wording, the target-host paragraph (including the four dead v1.4 hosts that must not be planned against), and the Out of Scope table
- `.planning/ROADMAP.md` §Phase 17 — goal, success criteria, and the sequencing note explaining why this phase gates every other
- `.planning/research/SUMMARY.md` — convergent spike-first/port-second/rewrite-third recommendation, and the "Gaps to Address" list that SPIKE-01..04 exist to close
- `.planning/research/PITFALLS.md` — silent hook-contract breakage, rewrite-under-migration, model-dependent hook behavior, stale-ClawHub drift
- `.planning/research/ARCHITECTURE.md` — session read layer vs hook registration layer split; `allowPromptInjection` finding
- `.planning/research/STACK.md` — CalVer floor, Node floor, plugin manifest state
- `.planning/research/FEATURES.md` — table-stakes vs spike-candidate feature split

### Spike conventions (the format Phase 17's artifacts must follow)
- `.planning/spikes/CONVENTIONS.md` — established patterns, paths table, CLI primitives, operational hazards (`exec` process pile-up, `pkill` self-match)
- `.planning/spikes/MANIFEST.md` — spike table format and the accumulated Requirements list to extend
- `.claude/skills/spike-findings-openclaw-revenium/SKILL.md` — the skill being re-scoped per D-10; its `references/` layout is the model for the new topic file

### Code the findings must be able to serve
- `scripts/report.sh` (see `:453`, `:1625`, `:1638`) — session-file iteration and completion parsing, the primary SPIKE-01 consumer
- `scripts/get-root-session-id.py` (see `:17`, `:45`, `:67`) — root-session walk by JSONL filename
- `scripts/common.sh` — shared path/env resolution including `OPENCLAW_HOME` normalization
- `scripts/write-marker.sh:66`, `scripts/write-job-marker.sh:132`, `scripts/verify-markers.sh:91`, `scripts/guardrail-check.sh:496` — the four current-session-id resolvers that motivate D-03
- `scripts/nemoclaw-cron-tick.sh`, `scripts/install-nemoclaw-cron.sh` — the host-side SSHFS metering loop whose read path SPIKE-01/04 must sustain

### Upstream issues to confirm or retire on 2.0
- github.com/openclaw/openclaw/issues/155696 — `session_end` payload broken for SQLite-backed sessions (drives D-08's "record, don't skip")
- github.com/openclaw/openclaw/issues/128314, pull/147611 — finalize-revise veto, open/unmerged; the reason `before_prompt_build` injection is not being retired

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `.planning/spikes/001-nemoclaw-bootstrap/probe-host-compat.sh` — host-compatibility probe; the shape `provision-2-0-host.sh` (D-14) should build on, and the precedent for promoting a probe into `scripts/` only when the real build needs it
- `.planning/spikes/002-openshell-egress/revenium-policy.yaml` — the `api.revenium.ai` egress preset D-16 requires; applied via `nemoclaw <name> policy-add --from-file`, hot-reloads with no rebuild
- `.planning/spikes/003-revenium-cli-in-sandbox/gh-release-policy.yaml` — `release-assets.githubusercontent.com` allowance needed if the revenium CLI is fetched in-sandbox
- `.planning/spikes/004-background-metering-loop/revenium-mount-tick.sh` — the proven host-cron-over-SSHFS tick shape SPIKE-04's soak should exercise
- `scripts/verify-markers.sh` — existing completions-vs-markers coverage accounting; the natural ground-truth counter for D-04's zero-loss check and for any SPIKE-03 coverage comparison

### Established Patterns
- **Spike artifacts** follow `.planning/spikes/NNN-name/README.md` with a MANIFEST row carrying a verdict of VALIDATED / PARTIAL / INVALIDATED — D-09 continues this numbering at 007
- **Explicit refusal, never silent no-op** — the project-wide convention behind GATE-01..04; SPIKE-00's provisioning script should follow it when a version floor is unmet
- **Host-side metering, never per-tick `nemoclaw exec`** — `exec` is synchronous, hang-prone, and accumulates hung host `node … exec` processes; SSHFS `share mount` is the host↔sandbox state channel
- **`pkill -f "<pattern>"` self-matches over SSH** and drops the session (exit 255) — kill by PID via `ps | grep | awk | xargs kill` filtered on `node`
- **NemoClaw argv rejects newlines** (gRPC) — keep `exec` commands single-line
- **revenium CLI reads its key from the `api-key:` field** in `config.yaml`, not `key:`
- **`revenium tools create --tool-type`** is a strict server-side enum (`BUILTIN` invalid; use `CUSTOM`/`MCP_SERVER`) and dry-run will not catch a bad value — probe live

### Integration Points
- **In-sandbox OpenClaw state** lives at `/sandbox/.openclaw/` (HOME=`/sandbox`, user `sandbox`), not `~/.openclaw/` — the 2.0 SQLite store path must be re-derived for the sandbox, not assumed from the standalone path
- **Sandbox TLS trust store** `/etc/openshell-tls/ca-bundle.pem` (`SSL_CERT_FILE`), egress proxy `10.200.0.1:3128`
- **`nemoclaw skill install`** does **not** run a skill's `post-install.sh` — no AGENTS.md injection, no cron, no status seed; anything the spike needs in-sandbox must be done separately
- Both plugin manifests (`plugin/openclaw.plugin.json`, `plugin-nemoclaw/openclaw.plugin.json`) **already exist** — resolved by direct repo check during research; no manifest work, do not carry it as an open question

</code_context>

<specifics>
## Specific Ideas

- The sidecar candidate (D-01c) is explicitly framed as *the skill capturing rather than reading* — if it wins on fidelity, Phase 19's shape changes from "port the read path" to "own the capture path". The findings must say so plainly rather than burying it in a ranking table.
- `session_end` is to be **recorded as observed**, not skipped as known-broken. Either outcome is useful: confirming #155696 on 2.0 closes off a fallback for good, and finding it fixed reopens one.
- The two install paths running different OpenClaw versions (D-15) is a finding in its own right, not an inconvenience to normalize — Phase 18's gate and Phase 22's NemoClaw work both inherit it.

</specifics>

<deferred>
## Deferred Ideas

- **Gate A exit-1 on the NemoClaw install path** (`nemoclaw-install-gate-a-exit1`) — the v1.4 Gate A `promptChars` check fails on the live Nemotron host. Belongs to Phase 20/22 where the plugin gates are rebuilt against 2.0, not to a fact-finding spike. Remains in `.planning/todos/pending/`.
- **Backfilling archived pre-2.0 JSONL sessions into Revenium** — already listed Out of Scope in REQUIREMENTS.md; noted here because the SQLite investigation will surface the archived files.

### Reviewed Todos (not folded)
- `16-review-deferred-findings` (WR-04 GROUP I-c exit-code assertion, IN-03 doc-timing wording) — matched Phase 17 on incidental keywords (phase / 2026 / nemoclaw). Left pending: it is minor docs/test polish against v1.4 code, and this phase writes no production code at all.

</deferred>

---

*Phase: 17-Live-Host Fact-Finding Spike*
*Context gathered: 2026-09-23*
