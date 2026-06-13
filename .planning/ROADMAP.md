# Roadmap: Revenium OpenClaw Skill

## Milestones

- ✅ **v1.0 Budget Guardrails & Metering** — Phases 1–4 (shipped 2026-06-03)
- ✅ **v1.1 Agentic Job Tracking** — Phases 5–8 (shipped 2026-06-04)
- ✅ **v1.2 Metering Completeness** — Phases 9–10 (shipped 2026-06-04)
- ✅ **v1.3 Reliable Attribution** — Phase 11 (shipped 2026-06-05)
- ✅ **v1.4 NemoClaw/OpenShell Support** — Phases 12–16 (shipped 2026-06-11, hardened through 2026-06-13)

**No active milestone.** Run `/gsd-new-milestone` to scope the next one. Candidates: ClawHub release + NemoClaw plugin rebuild to adopt the job lifecycle, OpenClaw-version compatibility canaries, budget-breach → HALT validation on Nemotron, JCLASS-01 code-side classifier, GRDEV-F1, per-job-type budget rules. (See PROJECT.md → Next Milestone Goals.)

## Phases

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

_Full v1.4 phase details (goals, success criteria, plan breakdowns) archived in [`milestones/v1.4-ROADMAP.md`](milestones/v1.4-ROADMAP.md)._
