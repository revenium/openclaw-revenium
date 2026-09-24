# Roadmap: Revenium OpenClaw Skill

## Milestones

- ✅ **v1.0 Budget Guardrails & Metering** — Phases 1–4 (shipped 2026-06-03)
- ✅ **v1.1 Agentic Job Tracking** — Phases 5–8 (shipped 2026-06-04)
- ✅ **v1.2 Metering Completeness** — Phases 9–10 (shipped 2026-06-04)
- ✅ **v1.3 Reliable Attribution** — Phase 11 (shipped 2026-06-05)
- ✅ **v1.4 NemoClaw/OpenShell Support** — Phases 12–16 (shipped 2026-06-11, hardened through 2026-06-13)
- 🚧 **v2.0 OpenClaw 2.0 Cut-Over** — Phases 17–24 (in progress, started 2026-09-23)

## Phases

**Phase Numbering:** Continuous across milestones (never restarts). Phase 17 is this milestone's first phase, continuing from v1.4's Phase 16.

### 🚧 v2.0 OpenClaw 2.0 Cut-Over (In Progress)

**Milestone Goal:** Move the Revenium skill onto OpenClaw `>= 2026.8.1` ("2.0" — a CalVer nickname, not a semver major) across both install paths, restoring the metering read path that 2.0's move to SQLite session storage breaks, and establishing on a live host whether marker-writing can be made deterministic instead of model-dependent.

**Sequencing note:** Phase 17 is a live-host spike and must complete before any porting work — research could not resolve the session-read mechanism from documentation alone. Phase 19 (session read path) and Phase 21 (attribution dispatch, contingent) are kept in strictly separate phase groups with a green checkpoint between them, per the project's "rewrite-under-migration" pitfall. Every phase touching install/gate scripts (18, 19, 20, 22, 23, 24) carries its own live clean-host verification step rather than deferring to one final UAT phase — generalizing the v1.4 lesson that "marked shipped" and "works on a clean host" are different things.

- [ ] **Phase 17: Live-Host Fact-Finding Spike** - Provision a real 2.0 host and resolve the session-read, hook-firing, and dispatch unknowns research couldn't answer
- [ ] **Phase 18: Version Gate & Install Health** - Install refuses unsupported OpenClaw/Node versions explicitly and runs `doctor --fix`
- [ ] **Phase 19: Session Read Path & Root-Session Resolution** - Port `report.sh`/`common.sh`/`get-root-session-id.py` off JSONL onto 2.0's SQLite session store
- [ ] **Phase 20: Plugin 2.0 SDK Compliance** - Rebuild both plugins against 2.0's SDK with the new `allowPromptInjection` gate and current hook names
- [ ] **Phase 21: Attribution Dispatch Resolution (Contingent)** - If SPIKE-03 validated it, make marker dispatch deterministic via `command-dispatch: tool`
- [ ] **Phase 22: NemoClaw/OpenShell Path on 2.0** - Re-verify the NemoClaw install sequence and host-side metering loop on a freshly-provisioned 2.0 sandbox
- [ ] **Phase 23: Hard HALT & Version Canary Live Validation** - Prove a real budget breach halts the agent and a broken hook is caught loudly, both live
- [ ] **Phase 24: ClawHub Release & Post-Publish Verification** - Cut the release and verify the *published* artifact installs clean, not just the working tree

## Phase Details

### Phase 17: Live-Host Fact-Finding Spike

**Goal**: Before any 2.0 porting work begins, establish ground truth on a live, reproducibly-provisioned 2.0 host — the actual session read mechanism, per-model hook behavior, and whether deterministic marker dispatch is viable — since documentation research could not resolve these. This phase is the milestone's true first task and gates every other requirement.
**Depends on**: Nothing (first phase of this milestone; continues from Phase 16). Target host: `52.90.9.242` (bare Ubuntu 26.04, no openclaw/nemoclaw/docker — the four AWS hosts used through v1.4 are all dead and must not be planned against).
**Requirements**: SPIKE-00, SPIKE-01, SPIKE-02, SPIKE-03, SPIKE-04
**Success Criteria** (what must be TRUE):

  1. A Linux host is provisioned and reproducible (OpenClaw `>=2026.8.1`, Node `>=24.16`, Docker, NemoClaw `>=v0.0.128`), with the provisioning steps recorded so the same state can be reached again.
  2. Operator can read a written, evidence-backed determination of how the skill should read completions and toolCalls from the 2.0 SQLite session store.
  3. Operator can read a per-model hook-firing matrix captured live, showing where model-dependent gaps (the B-05 class) exist before any porting begins.
  4. Operator can read a yes/no verdict, with supporting evidence, on whether `command-dispatch: tool` makes marker-writing dispatch deterministic.
  5. Operator can read a confirmation of whether the chosen SQLite read mechanism sustains per-minute cron polling without degrading the host.

**Plans**: 6 plans

Plans:
**Wave 1**

- [x] 17-01-PLAN.md — Tracer: provision 52.90.9.242 with both install paths, complete one real turn, read it back from the 2.0 SQLite store, write the SPIKE-00 determination

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 17-02-PLAN.md — SPIKE-03: `command-dispatch: tool` scope probe first, conditional cross-model determinism run, binary verdict

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 17-03-PLAN.md — SPIKE-01 (a)+(b): direct read-only SQLite read with verbatim schema capture, the four `openclaw sessions`/`doctor` CLI surfaces, and D-03 current-session-id resolution

**Wave 4** *(blocked on Wave 3 completion)*

- [x] 17-04-PLAN.md — SPIKE-01 (c): plugin-hook sidecar capture candidate, fidelity-first ranking, the SPIKE-01 determination

**Wave 5** *(blocked on Wave 4 completion)*

- [ ] 17-05-PLAN.md — SPIKE-02 + SPIKE-04: six-hook matrix across both pairings and the per-minute concurrency soak, run against one shared live-traffic window

**Wave 6** *(blocked on Wave 5 completion)*

- [ ] 17-06-PLAN.md — Findings wrap-up: MANIFEST rows 007-011, findings-skill re-scope and routing, and SPIKE-03's verdict consequence applied

### Phase 18: Version Gate & Install Health

**Goal**: Installs on an unsupported runtime fail loudly and explicitly — matching the project's existing explicit-refusal convention (never a silent no-op) — before any provisioning proceeds.
**Depends on**: Phase 17 (confirms the numeric CalVer floor and Node floor to gate on)
**Requirements**: GATE-01, GATE-02, GATE-03, GATE-04
**Success Criteria** (what must be TRUE):

  1. Running install against an OpenClaw below `2026.8.1` stops with a message naming both the detected and required version, verified live on the Phase 17 host.
  2. Running install against a Node runtime below 2.0's floor (`>=24.16 <25` or `>=26.1`) stops with an explicit refusal, verified live.
  3. Version comparison is numeric-CalVer based, not a version-string prefix check — verified against a version string crafted to fool a naive prefix comparison.
  4. Install runs `openclaw doctor --fix` and the operator sees its result before provisioning continues, verified live.

**Plans**: TBD

### Phase 19: Session Read Path & Root-Session Resolution

**Goal**: The skill's metering read path is ported off direct JSONL parsing onto 2.0's SQLite session store, so completions, toolCalls, and root-session resolution work end-to-end instead of silently metering nothing. This is the milestone's centerpiece and the green checkpoint that must hold before any attribution-core work (Phase 21) begins.
**Depends on**: Phase 17 (SPIKE-01/SPIKE-04 findings), Phase 18 (host passes the version gate)
**Requirements**: READ-01, READ-02, READ-03, READ-04, PLUG-04
**Success Criteria** (what must be TRUE):

  1. A completion produced on the 2.0 host appears as a metered transaction in Revenium, verified live.
  2. A tool call produced on the 2.0 host appears as a tool-event in Revenium, verified live.
  3. Root-session resolution correctly attributes a subagent's activity to its root session on the 2.0 store, using `subagent_spawned`/`subagent_ended` hooks rather than cross-session marker-file resolution.
  4. Pointing the skill at a session store it cannot read produces a visible, operator-facing failure rather than silent zero-metering.

**Plans**: TBD

### Phase 20: Plugin 2.0 SDK Compliance

**Goal**: Both installed plugins (standalone + NemoClaw) load cleanly on 2.0's plugin SDK, with 2.0's new permission gate and current hook names wired in — no load errors, no stale prebuilt `dist/`. This ports the existing hook contract unchanged; it does not add new dispatch behavior (that's the contingent Phase 21).
**Depends on**: Phase 17 (`allowPromptInjection` requirement confirmed live)
**Requirements**: PLUG-01, PLUG-02, PLUG-03, PLUG-05
**Success Criteria** (what must be TRUE):

  1. Both plugins load on a 2.0 runtime without error, built from a rebuilt `dist/` diffed against 2.0's SDK output rather than the reused pre-2.0 build.
  2. `allowPromptInjection` is set alongside `allowConversationAccess` in both install scripts' config patches, verified live via `plugins inspect`.
  3. Operator can confirm, live on 2.0, that the per-turn guardrail directive is injected into every turn via `before_prompt_build` (the `before_prompt_build` mitigation itself is not being retired — the 2026.6.6 finalize-revise veto is not confirmed fixed).
  4. Exec observation fires via `after_tool_call` on 2.0, confirmed live rather than assumed from docs.

**Plans**: TBD

### Phase 21: Attribution Dispatch Resolution (Contingent)

**Goal**: If Phase 17's SPIKE-03 spike found that `command-dispatch: tool` makes marker-writing dispatch deterministic, implement it so classification no longer depends on model judgment. **Contingency: this phase executes only if SPIKE-03 returned yes.** If SPIKE-03 returned no, this phase is dropped entirely, ATTR-01 moves to REQUIREMENTS.md's Future Requirements section, and the existing marker architecture ports as-is (already covered by Phase 20).
**Depends on**: Phase 19 (session read path green — the required checkpoint before any attribution-core change), Phase 20 (plugin hook contract confirmed stable on 2.0)
**Requirements**: ATTR-01 (contingent on SPIKE-03 = yes)
**Success Criteria** (what must be TRUE, only if this phase executes):

  1. A task/job marker write dispatches deterministically via `command-dispatch: tool` rather than depending on the model choosing to comply, verified live.
  2. Marker coverage (`verify-markers.sh`, completions-vs-markers) on the 2.0 host is at or above the reliability already achieved by the v1.3 `before_agent_finalize` gate — confirming the new dispatch mechanism doesn't regress coverage.

**Plans**: TBD

### Phase 22: NemoClaw/OpenShell Path on 2.0

**Goal**: The NemoClaw/OpenShell install path works end-to-end against a freshly-provisioned 2.0-generation sandbox, re-verified against NemoClaw's own concurrent lifecycle changes (0.0.127/0.0.128) rather than assumed compatible.
**Depends on**: Phase 19 (session store read path ported), Phase 20 (NemoClaw plugin 2.0-compliant), Phase 21 (if it executed, reflected in the deployed skill)
**Requirements**: NEMO-01, NEMO-02, NEMO-03
**Success Criteria** (what must be TRUE):

  1. Installing against NemoClaw below `v0.0.128` is refused explicitly; installing against `v0.0.128+` provisions a 2.0-generation OpenClaw successfully, verified on a freshly-provisioned sandbox (not the reused `revenium-spike` host).
  2. The `nemoclaw exec -- openclaw ...` call sequence in `post-install-nemoclaw.sh` completes successfully against 0.0.128's lifecycle-ownership model, verified live.
  3. The host-side metering loop reads the 2.0 session store over the `nemoclaw share mount` SSHFS mount, and a completion produced in the sandbox appears in Revenium.

**Plans**: TBD

### Phase 23: Hard HALT & Version Canary Live Validation

**Goal**: The two safety guarantees the project has never fully proven on a live host are demonstrated end-to-end: a real budget breach halts the agent, and drift in a depended-on hook is caught loudly rather than silently (the 2026.6.6-veto-class failure mode this milestone is proactively defending against).
**Depends on**: Phase 19, Phase 20, Phase 22 (both install paths and all hook wiring must be live before validating halt/canary behavior against them)
**Requirements**: HALT-01, CNRY-01, CNRY-02
**Success Criteria** (what must be TRUE):

  1. A real budget breach on a 2.0 host produces a hard HALT end-to-end, confirmed live — the one v1.4 behavior never proven.
  2. Deliberately breaking a hook the skill depends on causes the version canary to fail loudly, verified on the live host.
  3. The canary runs against the live 2.0 runtime (not mocks), and its failure reaches the operator rather than only a log line.

**Plans**: TBD

### Phase 24: ClawHub Release & Post-Publish Verification

**Goal**: A ClawHub release ships carrying the full v1.4/v1.4.1/post-ship fix set plus 2.0 support, and the *published* artifact — not just the local working tree — is proven to install clean. Publishing is not the finish line; verifying the published artifact is.
**Depends on**: Phase 18, Phase 19, Phase 20, Phase 21 (if it executed), Phase 22, Phase 23 — everything green
**Requirements**: REL-01, REL-02
**Success Criteria** (what must be TRUE):

  1. A ClawHub release is published carrying all v1.4/v1.4.1/post-ship fixes plus 2.0 support, with the NemoClaw plugin rebuilt.
  2. A clean install performed from the *published* release (not the local working tree) succeeds end-to-end on a fresh host, verified after publish.

**Plans**: TBD

<details>
<summary>✅ v1.4 NemoClaw/OpenShell Support (Phases 12–16) — SHIPPED 2026-06-11 (+ v1.4.1 hardening + post-ship jobs/enforcement)</summary>

Full details archived in [`milestones/v1.4-ROADMAP.md`](milestones/v1.4-ROADMAP.md). Milestone summary in [`MILESTONES.md`](MILESTONES.md).

- [x] **Phase 12: Parallel Install Scaffolding & Detection** (2/2) — completed 2026-06-07
- [x] **Phase 13: Sandbox Provisioning — Egress, CLI & Authenticated Metering** (3/3) — completed 2026-06-08
- [x] **Phase 14: Host-Side Metering Loop** (3/3) — completed 2026-06-08
- [x] **Phase 15: Per-Turn Enforcement Plugin** (7/7) — completed 2026-06-10
- [x] **Phase 16: Skill Deploy & Docs** (3/3) — completed 2026-06-11

**v1.4.1 post-ship hardening (2026-06-11):** a clean-host UAT found the milestone marked-shipped but broken end-to-end; ~14 fixes made `install.sh --nemoclaw` exit 0 with all four enforcement gates passing live (Gate A/B v2026.5.22 probe repair, per-sandbox-UUID ledger, env-gated budget provisioning, `ensure_mount` SSHFS self-heal, host-side CLI install, common.sh OPENCLAW_HOME normalization).

**Post-ship jobs & enforcement (2026-06-12/13):** hard-halt arming (`--autonomous`), jobs-directive injection + cron-race sweep, declare-at-start job lifecycle, per-turn `before_prompt_build` directive injection (the compliance fix — OpenClaw 2026.6.6 vetoes finalize-revise on tool-using turns), one-step vanilla setup. Live-validated on NemoClaw/Sonnet + vanilla/Opus hosts.

</details>

<details>
<summary>✅ v1.3 Reliable Attribution (Phase 11) — SHIPPED 2026-06-05</summary>

Full details archived in [`milestones/v1.3-ROADMAP.md`](milestones/v1.3-ROADMAP.md).

- [x] **Phase 11: Structural Marker Enforcement via before_agent_finalize plugin** (3/3) — completed 2026-06-05

A typed OpenClaw `before_agent_finalize` plugin forces task classification before the agent can yield — markers no longer depend on the LLM remembering an end-of-turn directive.

</details>

<details>
<summary>✅ v1.2 Metering Completeness (Phases 9–10) — SHIPPED 2026-06-04</summary>

Full details archived in [`milestones/v1.2-ROADMAP.md`](milestones/v1.2-ROADMAP.md).

- [x] **Phase 9: Guardrail Event Metering** (3/3) — completed 2026-06-04
- [x] **Phase 10: Tool Registry & Tool-Event Metering** (3/3) — completed 2026-06-04

Closed the metering-visibility gaps found while debugging v1.1 in production — guardrail enforcement events and tool usage are now first-class Revenium transactions (`GUARDRAIL` / tool-events), not just `CHAT`/`TOOL_CALL` completions.

Deferred at close: Phase 9 live guardrail-halt UAT/verification on host 172.16.1.247 (see STATE.md → Deferred Items).

</details>

<details>
<summary>✅ v1.1 Agentic Job Tracking (Phases 5–8) — SHIPPED 2026-06-04</summary>

Full details archived in [`milestones/v1.1-ROADMAP.md`](milestones/v1.1-ROADMAP.md).

- [x] **Phase 5: Job Declaration Foundation** (3/3) — completed 2026-06-03
- [x] **Phase 6: Job Lifecycle Wiring** (3/3) — completed 2026-06-03
- [x] **Phase 7: Root-Session Job Rollup** (2/2) — completed 2026-06-03
- [x] **Phase 8: Halt → CANCELLED Outcome** (2/2) — completed 2026-06-03

Post-ship fix: the agent-written-marker pipeline never fired in production (OpenClaw loads SKILL.md on-demand) — fixed by injecting completion-gate directives into AGENTS.md via post-install.sh; validated end-to-end.

</details>

<details>
<summary>✅ v1.0 Budget Guardrails & Metering (Phases 1–4) — SHIPPED 2026-06-03</summary>

Full details archived in [`milestones/v1.0-ROADMAP.md`](milestones/v1.0-ROADMAP.md).

- [x] **Phase 1: Skill Scaffolding** (1/1) — completed 2026-03-14
- [x] **Phase 2: Setup Flow** (1/1) — completed 2026-05-29
- [x] **Phase 3: Guardrail Engine** (8/8) — completed 2026-05-31
- [x] **Phase 4: Task Metering & Attribution** (4/4) — completed 2026-06-03

</details>

## Progress

| Phase | Milestone | Plans Complete | Status | Completed |
|-------|-----------|----------------|--------|-----------|
| 1. Skill Scaffolding | v1.0 | 1/1 | Complete | 2026-03-14 |
| 2. Setup Flow | v1.0 | 1/1 | Complete | 2026-05-29 |
| 3. Guardrail Engine | v1.0 | 8/8 | Complete | 2026-05-31 |
| 4. Task Metering & Attribution | v1.0 | 4/4 | Complete | 2026-06-03 |
| 5. Job Declaration Foundation | v1.1 | 3/3 | Complete | 2026-06-03 |
| 6. Job Lifecycle Wiring | v1.1 | 3/3 | Complete | 2026-06-03 |
| 7. Root-Session Job Rollup | v1.1 | 2/2 | Complete | 2026-06-03 |
| 8. Halt → CANCELLED Outcome | v1.1 | 2/2 | Complete | 2026-06-03 |
| 9. Guardrail Event Metering | v1.2 | 3/3 | Complete | 2026-06-04 |
| 10. Tool Registry & Tool-Event Metering | v1.2 | 3/3 | Complete | 2026-06-04 |
| 11. Structural Marker Enforcement | v1.3 | 3/3 | Complete | 2026-06-05 |
| 12. Parallel Install Scaffolding & Detection | v1.4 | 2/2 | Complete | 2026-06-07 |
| 13. Sandbox Provisioning — Egress, CLI & Authenticated Metering | v1.4 | 3/3 | Complete | 2026-06-08 |
| 14. Host-Side Metering Loop | v1.4 | 3/3 | Complete | 2026-06-08 |
| 15. Per-Turn Enforcement Plugin | v1.4 | 7/7 | Complete | 2026-06-10 |
| 16. Skill Deploy & Docs | v1.4 | 3/3 | Complete | 2026-06-11 |
| 17. Live-Host Fact-Finding Spike | v2.0 | 4/6 | In Progress|  |
| 18. Version Gate & Install Health | v2.0 | 0/TBD | Not started | - |
| 19. Session Read Path & Root-Session Resolution | v2.0 | 0/TBD | Not started | - |
| 20. Plugin 2.0 SDK Compliance | v2.0 | 0/TBD | Not started | - |
| 21. Attribution Dispatch Resolution (Contingent) | v2.0 | 0/TBD | Not started | - |
| 22. NemoClaw/OpenShell Path on 2.0 | v2.0 | 0/TBD | Not started | - |
| 23. Hard HALT & Version Canary Live Validation | v2.0 | 0/TBD | Not started | - |
| 24. ClawHub Release & Post-Publish Verification | v2.0 | 0/TBD | Not started | - |

_Full v1.4 phase details (goals, success criteria, plan breakdowns) archived in [`milestones/v1.4-ROADMAP.md`](milestones/v1.4-ROADMAP.md)._
