# Milestones

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
