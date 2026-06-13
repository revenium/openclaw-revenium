# Milestones

## v1.4 NemoClaw/OpenShell Support (Shipped: 2026-06-11, hardened through 2026-06-13)

**Phases completed:** 5 phases (12–16), 18 plans. Git range: `ac09477` (12-01) → `4273ae0`. ~123 files, +25.8k/−0.3k LOC across the milestone.

**Delivered:** A parallel NemoClaw/OpenShell install path that lets the Revenium skill run guardrail-enforced and fully metered inside an OpenShell sandbox — leaving the standalone OpenClaw + Docker path byte-stable. All 10 requirements (NCINST-01/02, NCEGRESS-01, NCCLI-01/02, NCMETER-01, NCENF-01/02, NCDEPLOY-01/02) satisfied and live-validated.

**Key accomplishments:**

- **Phase 12 — Parallel Install Scaffolding & Detection:** `install.sh` dispatcher routing NemoClaw vs standalone OpenClaw vs macOS (explicit macOS refusal, no silent no-op); standalone path byte-stable.
- **Phase 13 — Sandbox Provisioning:** two-preset egress, sha256-pinned in-sandbox CLI delivery, config-file credential write, and an authenticated `revenium meter completion` → HTTP 2xx live from inside the sandbox (closed spike 003).
- **Phase 14 — Host-Side Metering Loop:** host cron reads OpenClaw session JSONL over a `nemoclaw share mount` SSHFS mount and refreshes `guardrail-status.json` — no per-tick `exec`, no in-sandbox cron daemon.
- **Phase 15 — Per-Turn Enforcement Plugin:** `before_prompt_build` guardrail-directive plugin (highest-risk requirement) reaching every turn, plus the `before_agent_finalize` marker-gate adapter.
- **Phase 16 — Skill Deploy & Docs:** `nemoclaw skill install` wiring behind a SKILL.md guard + hardened `✓ ready` assertion, and the `docs/nemoclaw-setup.md` operator runbook.

**v1.4.1 — post-ship install-path hardening (2026-06-11):** A clean-host UAT found the milestone marked-shipped but broken end-to-end; ~14 fixes made `install.sh --nemoclaw` exit 0 with all four enforcement gates passing live — Gate A/B v2026.5.22 probe repair, per-sandbox-UUID ledger, env-gated install-time budget provisioning, consolidated `ensure_mount` SSHFS self-heal, host-side CLI install, `common.sh` OPENCLAW_HOME sandbox normalization. The stale "install exits 1 at the gate" claim (which had leaked into a downstream doc) was corrected throughout.

**Post-ship jobs & enforcement (2026-06-12/13, live-validated on NemoClaw/Sonnet + vanilla/Opus hosts):**

- **Hard-halt arming:** non-interactive setup never wrote `autonomousMode`, so a hard limit could never halt — added `--autonomous` / `REVENIUM_BUDGET_AUTONOMOUS`; a real breach now hard-halts (proven live).
- **Jobs delivery:** NemoClaw never injected the job-declaration directive (plugin baked only the guardrail directive) — fixed; then a cron-tick race that silently dropped markers was fixed with a per-session ledger-gated sweep.
- **Declare-at-start job lifecycle:** `RUNNING` open marker → interval spend stamping → `--close` terminal, with a stale-open janitor — jobs now visible in-flight with true per-job spend (additive; one-shot terminal form retained for NemoClaw compatibility).
- **Per-turn directive injection as the compliance driver:** OpenClaw 2026.6.6 silently vetoes `before_agent_finalize` revise on tool-using turns, and ambient AGENTS.md directives don't hold compliance — both plugins now prepend the metering directives every turn (the NemoClaw-proven mechanism), closing the file-tool and conversational blind spots.
- **Setup UX:** one-step env-driven vanilla install (creds + budget in a single post-install run) and decisive bare `/revenium` (acts, never interrogates).

**Known deferred items at close:** 4 (see STATE.md → Deferred Items). NOT yet validated: a real budget-BREACH → hard HALT end-to-end on Nemotron. Tracked externals: OpenClaw 2026.6.6 finalize-revise veto (report upstream), NemoClaw gateway wedge on tool-using turns (infra), Revenium 429-on-breach metering blackout (confirm with Revenium). Follow-up for next milestone: cut a ClawHub release and rebuild the NemoClaw plugin to adopt the job lifecycle there.

---

## v1.3 Reliable Attribution (Shipped: 2026-06-06)

**Phases completed:** 1 phase (Phase 11), 3 plans, 8 tasks
**Git range:** v1.2..HEAD — Phase 11 + 1 related quick task (260605-enh)

**Delivered:** Make task/job marker attribution reliable on real installs — markers no longer depend on the LLM remembering an end-of-turn directive. A typed OpenClaw `before_agent_finalize` plugin structurally forces classification before the agent can finalize a substantive turn, fixing the ~1-in-64 marked-completion baseline diagnosed live in production.

**Key accomplishments:**

- **Phase 11 — Structural Marker Enforcement:** the `revenium-marker-gate` TypeScript OpenClaw plugin (committed pre-built `dist/`) — `before_agent_finalize` returns a bounded (`retry.maxAttempts: 1`) revise action when an exec-running turn produced no task marker, forcing the agent to run `write-marker.sh`; `before_tool_call` observes exec without reading conversation content. Fail-open by contract (any gate throw resolves to pass-through), hardened at the host boundary with a throw-path test suite (CR-01). 30/30 `node:test`.
- **`scripts/verify-markers.sh`:** a genuinely read-only (WR-01) per-session completions-vs-markers coverage diagnostic that makes the classification gap measurable (SC-4); 16/16 integration tests.
- **`scripts/post-install.sh` §7c:** idempotent `openclaw plugins install --force` + config patch enabling `allowConversationAccess` (required to register the conversation hooks — D-05) + `plugins inspect` hook-registration check + gateway-restart note (no auto-restart); all `command_exists`-guarded and fail-open.
- **Host validation:** end-to-end confirmed on the live ClawHub host (`98.82.34.123`, opus-4-8) — the revise loop fires, the agent classifies on the forced pass, unmarked turns still finalize (fail-open), and attribution flows on the Revenium side above the ~1/64 baseline.
- **Post-ship hardening:** code review fixed 1 blocker + 2 warnings (CR-01 fail-open boundary + tests, WR-02 marker detection tightened from bare substring to actual invocation, WR-01 read-only diagnostic); 8 advisory findings deferred. Related quick task `260605-enh` made `setup-guardrails.sh` budget-rule creation idempotent + uniquely named (stops duplicate cost-control rules; `REVENIUM_BUDGET_LABEL`).

**Known deferred items at close:** 3 (see STATE.md → Deferred Items). 11-HUMAN-UAT SC-1 numeric coverage record waived (gate confirmed working live; exact %s lost to cleared terminal); 3 completed quick tasks flagged "missing" only for an absent SUMMARY `status:` field (cosmetic); Phase 9 live guardrail-halt E2E (host 172.16.1.247) still carried forward from v1.2.

---

## v1.2 Metering Completeness (Shipped: 2026-06-04)

**Phases completed:** 2 phases, 6 plans, 10 tasks
**Git range:** v1.1..HEAD — 45 commits, 38 files changed (+8,054 / −179)

**Delivered:** Close the metering-visibility gaps found while debugging v1.1 in production — guardrail enforcement and tool usage are now observable as first-class Revenium transactions (`GUARDRAIL` / tool-events), not just `CHAT`/`TOOL_CALL` completions, so spend has no blind spots.

**Key accomplishments:**

- **Phase 9 — Guardrail Event Metering:** every halt / warn / shadow-mode breach emits exactly one `GUARDRAIL` transaction (`meter completion --operation-type GUARDRAIL`, zero-token), transition-gated (`state=='warn'`, `HALTED_AT`/`WARN_TRANSITIONS` emit) and ledger-deduped so repeated cron ticks never re-emit; attributed to the root agent + open `--agentic-job-id`. Section M `_emit_guardrail_event` is fully fail-open. Dead `GUARDRAIL` operation-type heuristic deleted from `report.sh` (GRDEV-06). 18/18 guardrail-argv tests + GRDEV-06 assertion green.
- **Phase 10 — Tool Registry & Tool-Event Metering:** `TOOLS_CLI_CAPABLE` probe, `normalize_tool_id`/`classify_tool_type` helpers, and `_register_tool` create-once into `revenium-tools.ledger` (TOOLEV-01/04); `_meter_tool_event` + `toolCall` scan loop in `process_session` emit one `revenium meter tool-event` per call with explicit `--success` and at-most-once ledger dedup, without double-counting the existing `TOOL_CALL` completions (TOOLEV-02/03). Anchored ledger dedup to prevent prefix false-matches; valid tool-type enum (CUSTOM, not BUILTIN). Fully fail-open.
- **Test infrastructure:** hermetic argv-capture harnesses (`test_guardrail_argv.sh`, `test_report_tool_argv.sh`) plus `stub-revenium.sh` extended with guardrails / tools / `meter tool-event` switches and failure injection — full RED→GREEN coverage of every argv contract; all three live CLI questions resolved with no fallbacks.

**Known deferred items at close:** 2 (see STATE.md → Deferred Items). Phase 9 UAT left 1 pending scenario and verification `human_needed` — both gated on a live guardrail-halt test on host 172.16.1.247, deferred in favor of validation through production use on the test host.

---

## v1.1 Agentic Job Tracking (Shipped: 2026-06-04)

**Phases completed:** 4 phases, 10 plans, 14 tasks

**Delivered:** Group an OpenClaw agent's work into Revenium *agentic jobs* — every completion attributed to a job, jobs opened and closed with a terminal outcome — ported from the hermes-revenium job model onto OpenClaw's agent-written-marker architecture (no native-hook dependency).

**Key accomplishments:**

- **Phase 5 — Job Declaration Foundation:** 11-label `job-taxonomy.json` + `write-job-marker.sh` (sanitization → allowlist → flock atomic append) + `JOB DECLARATION` directive in SKILL.md; 18/18 writer tests.
- **Phase 6 — Job Lifecycle Wiring:** `report.sh` `JOBS_LEDGER_FILE` + `JOBS_CLI_CAPABLE` probe, per-completion correlation, `--agentic-job-id/-name/-type` stamping, ledger-gated `jobs create`/`jobs outcome` with 409-as-success and fail-open; 28/28 hermetic tests.
- **Phase 7 — Root-Session Job Rollup:** subagent completions inherit the ROOT session's `agentic_job_id` (race-omit on unresolved root); root-only gates prevent duplicate/sub-session jobs; 44+9+7 tests green.
- **Phase 8 — Halt → CANCELLED Outcome:** `handle_halt()` closes open jobs `CANCELLED` or mints a synthetic `guardrail-halt-<hex>` `interrupted` job on a budget halt; 71/71 cumulative tests.
- **Post-ship production fix:** live debugging on the test host found the agent-written-marker pipeline never fired in practice — OpenClaw loads `SKILL.md` on-demand, so the "classify/declare every turn" directives were never in the agent's context. Fixed by injecting hardened Task Classification + Job Declaration **completion-gates** into `AGENTS.md` via `post-install.sh`; validated end-to-end (agent self-wrote markers → cron → job created + closed `SUCCESS` in Revenium).

**Known deferred items at close:** 3 (see STATE.md → Deferred Items / `v1.1-MILESTONE-AUDIT.md`). Phase 6 left `human_needed` on two live-API checks (server 409-conflict string; CR-01 transient-failure job retry durability), plus one quick-task flagged "missing" covering the report.sh offset-gate. All three are carried into **v1.2** — Phase 9 directly touches the CR-01/offset area.

---

## v1.0 Budget Guardrails & Metering (Shipped: 2026-06-03)

**Phases completed:** 4 phases, 14 plans, 26 tasks

**Delivered:** A skill suite that turns every OpenClaw agent on the machine into a guardrail-enforced, task-metered agent — budget rules block runaway spend, and every completion is attributed by root session and task type in Revenium.

**Key accomplishments:**

- **Phase 1 — Skill Scaffolding:** SKILL.md with single-line JSON metadata, binary gating via `requires.bins`, and a guard-first body skeleton, installed to the OpenClaw skills directory.
- **Phase 2 — Setup Flow:** Agent-guided first-time configuration of the Revenium API key, budget alert, and anomaly-ID persistence with idempotent re-run behavior.
- **Phase 3 — Guardrail Engine:** Replaced the legacy budget-alert model with first-class guardrail rules — `common.sh` infrastructure, `setup-guardrails.sh` (two-mode dispatch + ASVS V5 input validation), `guardrail-check.sh` (silent-exit guard, shadow exclusion, transition-only notifications, atomic status writes), and a guardrail-native SKILL.md/BUDGET-GUARD.md HALT flow.
- **Phase 4 — Task Metering & Attribution:** 8-label task taxonomy, mandatory TASK CLASSIFICATION directive in SKILL.md, `--task-type` on every `meter completion`, and subagent spend rollup under the root session via `--agent openclaw-<root_session_id>` (D-07 `AGENT:STARTS_WITH` budget-rule scheme + per-task-type picker).
- **Post-ship hardening:** Code review fixed 2 critical + 7 warning findings (timestamp-injection, silent metering loss, marker mis-attribution); a `pipefail`+SIGPIPE race that randomly skipped the per-task picker was root-caused and fixed; and the task-type correlation was redesigned (completion_id keying) after live debugging showed markers are written after the completions they classify.

**Known deferred items at close:** 4 (see STATE.md → Deferred Items). Phase 4 UAT accepted with 2 caveats (in-skill legacy-notice firing unverified; subagent→root rollup not exercised end-to-end), Phases 1 & 3 verification left `human_needed` (in production use), and one quick task flagged "missing" that is actually complete.

---
