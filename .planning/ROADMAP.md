# Roadmap: Revenium OpenClaw Skill

## Milestones

- ✅ **v1.0 Budget Guardrails & Metering** — Phases 1–4 (shipped 2026-06-03)
- ✅ **v1.1 Agentic Job Tracking** — Phases 5–8 (shipped 2026-06-04)
- ✅ **v1.2 Metering Completeness** — Phases 9–10 (shipped 2026-06-04)
- ✅ **v1.3 Reliable Attribution** — Phase 11 (shipped 2026-06-05)
- 🔲 **v1.4 NemoClaw/OpenShell Support** — Phases 12–16 (in progress)

## Phases

### v1.4 NemoClaw/OpenShell Support

**Milestone Goal:** Let the Revenium skill optionally run under NemoClaw inside an OpenShell sandbox — a parallel install path that leaves the existing standalone OpenClaw + Docker path untouched. Feasibility proven on live host 34.224.27.67 (sandbox `revenium-spike`). Build consumes spike artifacts (policy YAMLs, tick scripts, revenium-guard plugin skeleton) rather than re-deriving them.

- [x] **Phase 12: Parallel Install Scaffolding & Detection** — Detection gate (Linux+NemoClaw vs standalone vs macOS-refuse) and the parallel install path skeleton (completed 2026-06-07)
- [x] **Phase 13: Sandbox Provisioning — Egress, CLI & Authenticated Metering** — Apply the `revenium` egress policy preset, deliver the revenium binary into the sandbox, close the authenticated-meter spike (completed 2026-06-08)
- [x] **Phase 14: Host-Side Metering Loop** — Host cron + `nemoclaw share mount` pipeline that keeps `guardrail-status.json` current for the in-sandbox agent (completed 2026-06-08)
- [ ] **Phase 15: Per-Turn Enforcement Plugin** — `before_prompt_build` guardrail-directive plugin + `before_agent_finalize` marker-gate adapter for NemoClaw (highest-risk phase)
- [ ] **Phase 16: Skill Deploy & Docs** — `nemoclaw skill install` wiring and operator documentation for the NemoClaw install path

### ✅ v1.3 Reliable Attribution (Shipped 2026-06-05)

**Milestone Goal:** Make task/job marker attribution reliable on real installs — markers must not depend on the LLM remembering an end-of-turn directive. Diagnosed live on the ClawHub host (`98.82.34.123`, opus-4-8): the v1.1 AGENTS.md directive is present and in-context, yet the agent drops the end-of-turn `write-marker.sh` gate (~1 of 64 completions marked). The fix is a typed OpenClaw `before_agent_finalize` plugin that forces classification before the agent can yield.

- [x] **Phase 11: Structural Marker Enforcement via before_agent_finalize plugin** (3/3) — completed 2026-06-05

<details>
<summary>✅ v1.0 Budget Guardrails & Metering (Phases 1–4) — SHIPPED 2026-06-03</summary>

Full details archived in [`milestones/v1.0-ROADMAP.md`](milestones/v1.0-ROADMAP.md).

- [x] **Phase 1: Skill Scaffolding** (1/1) — completed 2026-03-14
- [x] **Phase 2: Setup Flow** (1/1) — completed 2026-05-29
- [x] **Phase 3: Guardrail Engine** (8/8) — completed 2026-05-31
- [x] **Phase 4: Task Metering & Attribution** (4/4) — completed 2026-06-03

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
<summary>✅ v1.2 Metering Completeness (Phases 9–10) — SHIPPED 2026-06-04</summary>

Full details archived in [`milestones/v1.2-ROADMAP.md`](milestones/v1.2-ROADMAP.md).

- [x] **Phase 9: Guardrail Event Metering** (3/3) — completed 2026-06-04
- [x] **Phase 10: Tool Registry & Tool-Event Metering** (3/3) — completed 2026-06-04

Closed the metering-visibility gaps found while debugging v1.1 in production — guardrail enforcement events and tool usage are now first-class Revenium transactions (`GUARDRAIL` / tool-events), not just `CHAT`/`TOOL_CALL` completions.

Deferred at close: Phase 9 live guardrail-halt UAT/verification on host 172.16.1.247 (see STATE.md → Deferred Items).

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
| 12. Parallel Install Scaffolding & Detection | v1.4 | 2/2 | Complete    | 2026-06-07 |
| 13. Sandbox Provisioning — Egress, CLI & Authenticated Metering | v1.4 | 3/3 | Complete    | 2026-06-08 |
| 14. Host-Side Metering Loop | v1.4 | 3/3 | Complete    | 2026-06-08 |
| 15. Per-Turn Enforcement Plugin | v1.4 | 6/7 | In Progress|  |
| 16. Skill Deploy & Docs | v1.4 | 0/? | Not started | - |

## Phase Details

### Phase 12: Parallel Install Scaffolding & Detection

**Goal:** The install tooling detects NemoClaw vs standalone OpenClaw vs macOS and routes correctly — the NemoClaw path is skeletal but gated, and a macOS operator gets an explicit refusal rather than a silent no-op.

**Depends on:** Phase 11 (existing standalone path must be preserved)

**Requirements:** NCINST-01, NCINST-02

**Success Criteria** (what must be TRUE):

  1. Running the install on a Linux+NemoClaw host (`~/.nemoclaw/` present + Docker) enters the NemoClaw install path without touching the standalone OpenClaw install
  2. Running the install on a standalone OpenClaw host (no `~/.nemoclaw/`) continues through the existing path unchanged — no regression
  3. Running the install on macOS prints an explicit "NemoClaw is unsupported on macOS" error and exits non-zero rather than silently completing or no-opping
  4. The NemoClaw install path skeleton is idempotent — running it twice on the same host produces the same result without duplication or error

**Plans:** 2/2 plans complete
Plans:
**Wave 1**

- [x] 12-01-PLAN.md — Nyquist test harness (test_install_dispatcher.sh) + verbatim probe-host-compat.sh copy

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 12-02-PLAN.md — install.sh dispatcher (D-03 routing + macOS refusal) + post-install-nemoclaw.sh skeleton

**Spike artifacts consumed:** spike 001 bootstrap findings, `install-and-bootstrap.md` detection pattern

---

### Phase 13: Sandbox Provisioning — Egress, CLI & Authenticated Metering

**Goal:** The sandbox has egress to `api.revenium.ai`, the revenium binary is installed inside it, and an authenticated `revenium meter` call succeeds from inside the sandbox — closing the spike 003 pending authenticated-meter step.

**Depends on:** Phase 12

**Requirements:** NCEGRESS-01, NCCLI-01, NCCLI-02

**Success Criteria** (what must be TRUE):

  1. The install path applies the `revenium` network-policy preset via `nemoclaw policy-add` and the sandbox can reach `api.revenium.ai` over HTTPS (verified via `curl` or the CLI inside the sandbox)
  2. If the policy preset is missing or blocked, the install surfaces a clear error identifying the policy gap — not a generic network failure
  3. The `revenium` binary is present inside the sandbox at `/sandbox/.local/bin/revenium` (prebuilt tarball delivery, not brew) with `SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem` and `REVENIUM_*` env wired
  4. An authenticated `revenium meter completion` call from inside the sandbox returns HTTP 2xx against the real Revenium API (closes NCCLI-02 and spike 003's partial verdict)

**Plans:** 3/3 plans complete

Plans:
**Wave 1**

- [x] 13-01-PLAN.md — Wave 0 scaffold: ship both egress preset YAMLs into scripts/ + hermetic harness (stub-nemoclaw.sh, test_nemoclaw_provisioning.sh, GROUP A–G)

**Wave 2** *(blocked on Wave 1)*

- [x] 13-02-PLAN.md — Real provisioning in post-install-nemoclaw.sh: ledger, two-preset egress + policy-gap classification, sha256-verified CLI delivery, config-file creds, ledger-gated meter probe

**Wave 3** *(blocked on Wave 2)*

- [x] 13-03-PLAN.md — Live smoke on 34.224.27.67 (authenticated meter 2xx, D-LIVE) + flip spike 003 PARTIAL→VALIDATED

**Spike artifacts consumed:** `002-openshell-egress/revenium-policy.yaml`, `003-revenium-cli-in-sandbox/` probe scripts and `gh-release-policy.yaml`

---

### Phase 14: Host-Side Metering Loop

**Goal:** `guardrail-status.json` stays current for the in-sandbox agent via a host cron job that reads OpenClaw session logs over a `nemoclaw share mount` — without per-tick `nemoclaw exec` and without an in-sandbox cron daemon.

**Depends on:** Phase 13

**Requirements:** NCMETER-01

**Success Criteria** (what must be TRUE):

  1. A host-side cron job runs every minute (or configurable interval), reads OpenClaw session JSONL logs from the SSHFS mount, and writes a refreshed `guardrail-status.json` back through the mount — visible to the in-sandbox agent on its next turn
  2. The metering loop does NOT use per-tick `nemoclaw exec` — no accumulating hung `node` processes on the host
  3. A stopped or unmounted share fails gracefully — the loop logs a clear error and exits cleanly rather than hanging or corrupting the status file
  4. The existing standalone OpenClaw cron and `report.sh`/`guardrail-check.sh` scripts are not modified

**Plans:** 3/3 plans complete

Plans:
**Wave 1**

- [x] 14-01-PLAN.md — Wave-0 Nyquist scaffold: stub-mount-env.sh (mountpoint/crontab/sshfs stubs) + test_nemoclaw_cron.sh harness encoding SC1-SC4 + D-02..D-08 (RED)

**Wave 2** *(blocked on Wave 1)*

- [x] 14-02-PLAN.md — nemoclaw-cron-tick.sh (mount self-heal + OPENCLAW_HOME delegation to unmodified cron.sh, exit-3-on-failure) + install-nemoclaw-cron.sh (sshfs hard-gate, 600-mode host env, idempotent per-sandbox cron, interval precedence)

**Wave 3** *(blocked on Wave 2)*

- [x] 14-03-PLAN.md — uninstall-nemoclaw-cron.sh + wire real install_metering_loop into post-install-nemoclaw.sh (replaces Phase 13 stub) + SC4 byte-identical guard

**Spike artifacts consumed:** `004-background-metering-loop/` tick scripts, SSHFS mount pattern from CONVENTIONS.md

---

### Phase 15: Per-Turn Enforcement Plugin

**Goal:** Every agent turn inside the NemoClaw sandbox receives the mandatory guardrail directive via an OpenClaw `before_prompt_build` plugin, and task/job marker writing is preserved via a deployed `before_agent_finalize` adapter — making halt and warn-and-ask enforcement and Revenium attribution work under NemoClaw.

**Depends on:** Phase 14

**Requirements:** NCENF-01, NCENF-02

**Risk note:** NCENF-01 is the **highest-risk requirement** in v1.4. Spike 006 proved the `before_prompt_build` → `prependContext` mechanism reaches every turn (the nemoclaw plugin uses it), but a hand-stubbed plugin hung the agent turn. The plugin must be authored from `openclaw plugins init` (official scaffold) or by mirroring the nemoclaw plugin source, then validated on the live sandbox at 34.224.27.67 before proceeding. Do not ship a hand-rolled stub.

**Success Criteria** (what must be TRUE):

  1. A custom OpenClaw `before_prompt_build` plugin (`revenium-guard`) is installed in the sandbox via `openclaw plugins install`, authoritatively trusted (not just loaded), and the guardrail directive appears in agent context on every turn — verified on the live sandbox host 34.224.27.67
  2. An agent turn that would be halted under the standalone path is also halted under NemoClaw — the halt directive from `guardrail-status.json` reaches the agent via the plugin
  3. The `before_agent_finalize` marker-gate plugin (from Phase 11) is deployed/adapted for the sandbox environment and task/job markers are written under NemoClaw — attribution flows to Revenium
  4. A plugin hook error or timeout is fail-open — it never blocks the agent's reply (same contract as the Phase 11 plugin)
  5. The plugin is authored from the official `openclaw plugins init` scaffold (not a hand-rolled stub), with `configSchema` and `openclaw.extensions` in `package.json` as required by the trusted-plugin install path

**Plans:** 6/7 plans executed

**Install-path note (D-08):** NCDEPLOY-01's *deploy step* (`nemoclaw skill install`) is pulled forward into Phase 15 so the marker chain is end-to-end testable and SC3 is honestly verifiable here. Install-path order is now: 13 provisioning → 14 metering loop → 15a skill install → 15b plugin install → 15c preflight+smoke → 16 docs. Phase 16 keeps only docs + polish.

Plans:
**Wave 1**

- [x] 15-01-PLAN.md — Combined revenium-enforcement plugin (4 hooks: before_prompt_build guard + verbatim gate.js marker hooks), build-time inlined BUDGET-GUARD.md, committed dist/, + _maxAgeSeconds freshness rule

**Wave 2** *(blocked on Wave 1)*

- [x] 15-02-PLAN.md — Install path: install_skill_nemoclaw (D-08) + install_enforcement_plugin replacing the stub (mount-deliver → trusted install → config patch → recover → fail-HARD turn-test/inspect + python3/marker smoke) + uninstall counterpart

**Wave 3** *(blocked on Wave 2)*

- [x] 15-03-PLAN.md — Live validation on 34.224.27.67 / revenium-spike (SC1-SC5 evidence in 15-VALIDATION.md; human checkpoint)

**Gap-closure note (verification 2026-06-08):** Initial pass scored 3/5 truths. Two blockers: **B-01** (Gate A greps the removed `finalPromptText` field → aborts every real install) and **B-05** (in-process `execRuns` Set resets on `nemoclaw recover` → no end-to-end marker). Plans 15-04 (code fixes) + 15-05 (live re-validation) close them.

**Gap-closure Wave 1**

- [x] 15-04-PLAN.md — B-01 + B-05 code fixes: persist exec-run state to disk in plugin/src/gate.js (survives nemoclaw recover) + rewrite Gate A to assert currentTurn.promptChars instead of removed finalPromptText; new persistence tests in both index.test.js suites

**Gap-closure Wave 2** *(blocked on 15-04)*

- [x] 15-05-PLAN.md — Live re-validation on 34.224.27.67 / revenium-spike: new Gate A passes a real install (B-01) + a substantive turn writes an end-to-end marker .jsonl across the recover boundary (B-05); human checkpoint

**Gap-closure note (re-verification 2026-06-09):** Re-verification scored 3/5. B-01 CLOSED. Three gaps remain: **CR-01** (Gate A `_prompt_chars` pipeline lacks `|| true` → pipefail aborts before the diagnostic fires), **WR-01** (`persistRunState(runId, false)` on the non-string exec path downgrades a prior `marked:true` disk record), and **B-05** (Nemotron routes exec through `tool_search_code` + `openclaw:core:exec` so `before_tool_call` never fires → no marker). Plans 15-06 (code fixes) + 15-07 (live re-validation) close them.

**Gap-closure Wave 3 (round 3)**

- [x] 15-06-PLAN.md — CR-01 + WR-01 + B-05 code fixes: `|| true` guard on Gate A; non-downgrade `persistRunState(runId, markedTaskRuns.has(runId))` + WR-04 regression; live schema-probe FIRST then transcript-scan observation in before_agent_finalize (unioned with before_tool_call) wired through both index.ts; D-06 build copy + dist regenerated; both unit suites green

**Gap-closure Wave 4 (round 3)** *(blocked on 15-06)*

- [ ] 15-07-PLAN.md — Live re-validation on 34.224.27.67 / revenium-spike: CR-01 diagnostic-on-no-injection + pass-on-injection, WR-01 non-downgrade-across-recover, B-05 transcript-scan end-to-end marker; human checkpoint with terminal SC3 decision (marker produced → PASS; not produced → user-approved SC3 scope-renegotiation to direct-exec agents, Nemotron tool_search_code indirection documented as a known limitation)

**Spike artifacts consumed:** spike 006 findings (`skill-deploy-and-enforcement.md`, plugin skeleton), Phase 11 `revenium-marker-gate` source as the `before_agent_finalize` template

---

### Phase 16: Skill Deploy & Docs

**Goal:** The Revenium skill is fully deployed into the NemoClaw sandbox via `nemoclaw skill install` and discovered by the agent as `✓ ready`, and operators have clear documentation for the NemoClaw install path including prerequisites and the macOS-unsupported constraint.

**Depends on:** Phase 15

**Requirements:** NCDEPLOY-01, NCDEPLOY-02

**Success Criteria** (what must be TRUE):

  1. `nemoclaw <name> skill install <path>` deploys the Revenium skill into the sandbox and the agent lists it as `✓ ready`
  2. The NemoClaw install path is runnable end-to-end on a clean host (34.224.27.67 or equivalent) with the documented prerequisites — no undocumented manual steps required
  3. The setup documentation covers the NemoClaw path prerequisites (Linux, Docker, NemoClaw installed, `sshfs`), the parallel-path guarantee (standalone path untouched), and the macOS-unsupported constraint with an explicit error message
  4. The existing standalone OpenClaw setup docs are not changed or contradicted by the NemoClaw additions

**Plans:** TBD

**UI hint**: no
