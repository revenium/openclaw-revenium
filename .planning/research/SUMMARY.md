# Project Research Summary

**Project:** Revenium OpenClaw Skill — v2.0 "OpenClaw 2.0 Cut-Over"
**Domain:** Major-runtime-version cut-over for a production agent-metering/guardrail skill (bash + TypeScript plugin), across two install paths (standalone OpenClaw+Docker, NemoClaw/OpenShell sandbox)
**Researched:** 2026-09-23
**Confidence:** MEDIUM-HIGH

## Executive Summary

All four researchers independently confirm: "OpenClaw 2.0" is a marketing nickname for the CalVer release `2026.8.1` (shipped 2026-08-30/31), not a semver major version. CalVer numbering continued past it (`2026.9.1`-`2026.9.6`, npm `latest` as of 2026-09-23). There is no `2.x.x` line to branch code on. The milestone's "drop CalVer support" framing must be corrected to: target `>= 2026.8.1`, refuse below it explicitly — a `startswith("2026.")` check would be a bug.

The highest-impact break: OpenClaw 2.0 moved session storage from per-agent JSONL to per-agent SQLite (`~/.openclaw/agents/<agentId>/agent/openclaw-agent.sqlite`); legacy JSONL is archived, not runtime-read. `report.sh`, `common.sh`, `get-root-session-id.py` read JSONL directly today — on 2.0 this silently stops seeing new completions (fail-open metering blackout). An open upstream bug (#155696) shows `session_end` hook payloads carry no messages and point at nonexistent JSONL for SQLite-backed sessions, closing off the obvious hook fallback. A plausible-sounding `openclaw sessions export` command does not exist — the replacement read mechanism is unresolved and needs a live-host spike.

Recommended approach (convergent across all four researchers): spike first, port second, rewrite third, in strictly separate phase groups with green checkpoints between them. Avoid bundling the attribution-core rewrite with the runtime port (two-hypothesis debugging problem), and require live clean-host verification per phase, not one final UAT phase.

## Key Findings

### Recommended Stack
Target `openclaw >= 2026.8.1` (not the `extended-stable` dist-tag, still at `2026.7.35`). Node floor raises to `>=24.16.0 <25` or `>=26.1.0`. `openclaw.plugin.json` manifest is now mandatory per-plugin (STACK.md and ARCHITECTURE.md disagree on whether it already exists in this repo — resolve via direct repo check at Phase 1). `openclaw/plugin-sdk/plugin-entry` import remains valid. NemoClaw CLI `>=v0.0.128` (2026-09-22) is the first confirmed 2.0-generation-qualified build — very recent, treat as freshly-qualified not battle-tested.

### Expected Features
**Must have:** session read path ported off JSONL; version target corrected to `>=2026.8.1` with numeric-floor refusal; `openclaw doctor --fix` added to install/upgrade; hook re-registration re-verified (incl. new `allowPromptInjection` gate); NemoClaw 2.0-line support confirmed; live-host version canary (not hermetic).
**Should have (unproven, spike candidates):** `command-dispatch: tool` SKILL.md frontmatter field as a deterministic dispatch mechanism (new lead against B-05, not a resolved answer); `subagent_spawned`/`subagent_ended` hooks to simplify root-session resolution; `after_tool_call` for richer exec observation.
**Defer:** treating native OpenClaw usage/cost telemetry as a Revenium replacement; `diagnostics-otel`/`llm_output` corroboration.

### Architecture Approach
Both install paths share `cron.sh`/`report.sh`/`guardrail-check.sh` — preserve this invariant. Break concentrates in (1) session-line acquisition and (2) conversation-hook registration. New, high-confidence finding: 2.0 requires a second permission gate, `allowPromptInjection`, alongside `allowConversationAccess`, for `before_prompt_build` — today's sole surviving compliance mechanism. Neither install script sets it; must be live-verified.

**Major components:** session read layer (core rewrite); plugin/hook registration layer (modify + rebuild); attribution-core markers/AGENTS.md (port as-is — Branch B applies per current docs); NemoClaw provisioning (re-verify call sequences against NemoClaw's own concurrent lifecycle changes); version gate + canary (new).

### Critical Pitfalls
1. **Silent hook-contract breakage** — fail-open plugins make drift invisible (2026.6.6 finalize-revise veto, still open as #128314). Build a fail-loud live-host canary, separate from the fail-open enforcement plugin.
2. **SQLite session-store break is table-stakes #1** — must resolve live in Phase 1; obvious hook fallback (`session_end`) is itself confirmed broken.
3. **"Works hermetically, broken on clean host" recurs** — v1.4 was marked shipped then found broken; every install/gate-touching phase needs its own live verification, not one final UAT.
4. **Rewrite-under-migration** — bundling attribution-core rewrite with runtime port entangles variables; keep strictly separate phase groups gated on a written fact.
5. **Model-dependent hook behavior (next B-05)** — OpenClaw's own docs disclaim universal hook firing; Nemotron's `tool_search_code` exec routing already broke `before_tool_call` observation once.
6. **Stale ClawHub artifact vs repo drift** — already happened once; ClawHub release must be last phase with its own post-publish verification.

## Implications for Roadmap

All four researchers converge on: spike first, port second, rewrite third.

### Phase 1: Establish 2.0 Facts (live-host spike — blocks everything else)
**Rationale:** Docs-only research left unresolved load-bearing questions; one researcher found and retracted a plausible-but-nonexistent CLI command during this research.
**Delivers:** Confirmed session-read mechanism; confirmed `allowPromptInjection` requirement; per-model hook-firing matrix (standalone+Claude, NemoClaw+Nemotron); written Branch A/B attribution decision; `command-dispatch: tool` evaluation; re-verified NemoClaw call sequence.
**Addresses:** Session read path, version canary, NemoClaw confirmation, hook re-registration (FEATURES.md table stakes).
**Avoids:** Pitfalls 1, 2, 5.

### Phase 2: Version Gate + Canary Scaffolding
**Rationale:** Low-risk, unblocks safe iteration; gate shape doesn't depend on harder Phase-1 answers.
**Delivers:** `install.sh` numeric-floor version gate (explicit refusal, mirrors macOS precedent); `version-canary.sh` skeleton.
**Uses:** CalVer floor from Phase 1.

### Phase 3: Session Read Path Rewrite (report.sh, get-root-session-id.py, common.sh, guardrail-check.sh)
**Rationale:** Critical path — blocks both install paths' live validation.
**Delivers:** Session-line acquisition rewritten per Phase 1's chosen mechanism; downstream marker/job/tool-event logic largely unchanged if the "iterate sessions, checkpoint" contract is preserved.
**Avoids:** Pitfall 2; explicitly does not touch attribution-core logic (sets up Pitfall 4 separation).

### Phase 4: Standalone Plugin Migration (plugin/)
**Rationale:** Can run parallel to Phase 3 once Phase 1's `allowPromptInjection` answer lands.
**Delivers:** Bumped peerDependencies, rebuilt dist/, `allowPromptInjection` added to config patch, gate inspection switched to `--json`.

### Phase 5: NemoClaw Path (plugin-nemoclaw/, post-install-nemoclaw.sh)
**Rationale:** Depends on Phase 3 + Phase 4's pattern; must validate on a freshly-provisioned sandbox, not the reused revenium-spike host.
**Delivers:** Re-verified `nemoclaw exec -- openclaw ...` sequence, re-verified Gate A/B parsing, pairing/device-auth re-check, mount-and-read SQLite validation over SSHFS.

### Phase 6: Attribution-Core Resolution
**Rationale:** Per current docs, Branch B (port as-is) applies — no 2.0 hook exposes semantic classification. Only expands if Phase 1 reverses this. `command-dispatch: tool` is a separate, unproven lead already scoped in Phase 1, not a "hooks now classify" conclusion.
**Delivers:** Documented Branch B confirmation, or (contingent) a sub-milestone-scale classification design with shadow-mode validation.
**Avoids:** Pitfall 4.

### Phase 7: Hard HALT Live Validation
**Rationale:** Independent of the storage migration technically; can run parallel to Phases 3-5.
**Delivers:** Live-validated budget-breach → hard HALT end-to-end, closing the one gap never proven since v1.4.

### Phase 8: ClawHub Release
**Rationale:** Must be last, gated on all prior phases green on a live 2.0 host.
**Delivers:** Rebuilt NemoClaw plugin, cut release, explicit post-publish clean-install verification.

### Phase Ordering Rationale
- Session read path is the root dependency for nearly everything else.
- Attribution-core and runtime-port work stay in non-overlapping phase groups to avoid two-hypothesis debugging.
- Every install/gate-touching phase carries its own live clean-host verification, not one final UAT.
- NemoClaw validates on a fresh sandbox, not the reused spike host.
- ClawHub release is last, with its own post-publish verification.

### Research Flags

Needs research: Phase 1 (by definition — live-host investigation, not desk research), Phase 3 (depends on Phase 1 findings), Phase 6 (contingent scope unknown until Phase 1's Branch A/B call), Phase 5 (NemoClaw's own changes are ~1 day old at research time, docs may lag reality).

Standard patterns (skip research-phase): Phase 2 (existing fail()/refusal convention), Phase 4 (hook names/import paths confirmed stable, mechanical bump-and-rebuild), Phase 7 (existing mechanism unaffected by 2.0), Phase 8 (established release/verify pattern from v1.4).

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | HIGH on "2.0 = CalVer 2026.8.1+"; MEDIUM on plugin-manifest state (STACK.md vs ARCHITECTURE.md disagree on whether `openclaw.plugin.json` already exists in-repo) |
| Features | MEDIUM | Researcher self-rated MEDIUM: official docs/GitHub issues fetched directly, but session's fetch tooling is scored LOW by project's own confidence convention regardless of source authority |
| Architecture | MEDIUM overall — HIGH on "does 2.0 exist"/structural changes; MEDIUM/LOW on exact plugin-permission and session-export mechanics (one claim was found-then-retracted as nonexistent during research) |
| Pitfalls | MEDIUM-HIGH | 2.0 facts well-sourced from official docs; project-specific pitfalls (2026.6.6, B-05, ClawHub staleness) are HIGH — drawn from this project's own history |

**Overall confidence:** MEDIUM-HIGH on problem shape and sequencing; MEDIUM on implementation-level specifics requiring live-host confirmation.

### Gaps to Address
- Exact `openclaw-agent.sqlite` schema — UNVERIFIED, capture via `sqlite3 .schema` in Phase 1.
- Whether `sessions export-trajectory` is fast/stable enough for per-minute cron polling and carries full message fidelity — UNVERIFIED, may require interactive/owner-approved exec (unclear if usable unattended from cron).
- Whether `allowPromptInjection` is actually enforced as documented — highest-value fact to confirm before writing plugin code.
- Whether the 2026.6.6 revise-veto behavior persists on `2026.8.1+` — related issue #128314 open, PR #147611 unmerged.
- Whether `get-root-session-id.py`'s id-parsing assumptions hold under the new store — UNVERIFIED.
- Whether `command-dispatch: tool` can force deterministic marker/guardrail dispatch — unproven, needs dedicated spike.
- Internal contradiction: does `plugin/openclaw.plugin.json` already exist in-repo? (STACK.md: no; ARCHITECTURE.md's direct repo read: yes) — resolve with a direct check before assuming manifest work is greenfield.
- NemoClaw's `nemoclaw exec -- openclaw ...` sequence under 0.0.127+'s lifecycle handback — plausibly simplified, UNVERIFIED without a live host.

## Sources

### Primary (HIGH confidence)
- docs.openclaw.ai/releases/2026.8.1 — "AKA OpenClaw 2.0" release notes
- docs.openclaw.ai/releases — release index, CalVer continues past 2.0
- openclaw.ai/blog/openclaw-2-accidentally — official "2.0" nickname framing
- docs.openclaw.ai/reference/RELEASING — CalVer policy, no semver major
- npm registry, queried live (`npm view openclaw versions/time/dist-tags/engines --json`)
- docs.openclaw.ai/plugins/manifest — mandatory `openclaw.plugin.json`
- docs.openclaw.ai/plugins/sdk-migration, .../sdk-overview/imports — import-surface deprecations
- docs.openclaw.ai/plugins/hooks, .../hooks/reference — hook catalog, `allowConversationAccess`/`allowPromptInjection`
- docs.openclaw.ai/cli/doctor/sqlite-maintenance — SQLite migration, JSONL archived not runtime-read
- docs.openclaw.ai/cli/sessions, github.com/openclaw/openclaw/blob/main/docs/cli/sessions.md — real `sessions` subcommands (no plain `export`)
- github.com/openclaw/openclaw/issues/155696 — open bug, `session_end` payload broken for SQLite-backed sessions
- github.com/openclaw/openclaw/issues/128314, pull/147611 — open/unmerged, revise-veto not confirmed fixed
- docs.nvidia.com/nemoclaw/user-guide/openclaw/release-notes — v0.0.128 manages OpenClaw 2026.9.1; device-auth-bypass retirement; lifecycle handback (0.0.127)
- github.com/openclaw/plugin-inspector — version-canary CI component
- This project's own source and `.planning/PROJECT.md`

### Secondary (MEDIUM confidence)
- openclawlaunch.com, cellcog.ai, digitalapplied.com — third-party corroboration of CalVer/"2.0" framing, `doctor --fix`
- cybersecuritynews.com, infoq.com, marktechpost.com — press coverage
- getreadyforagents.com — contributor/PR-count corroboration

### Tertiary (LOW confidence — UNVERIFIED per researchers)
- Exact `openclaw-agent.sqlite` schema
- Whether SKILL.md body is injected every turn vs. only on model self-invocation
- Exact `openclaw --version` stdout format
- September 1, 2026 plugin-SDK deprecated-subpath removal deadline (search synthesis only)
- NemoClaw device-auth-bypass and Node-floor exact version numbers (search synthesis only)

---
*Research completed: 2026-09-23*
*Ready for roadmap: yes — pending Phase 1 live-host spike before Phase 3+ implementation detail is finalized*
