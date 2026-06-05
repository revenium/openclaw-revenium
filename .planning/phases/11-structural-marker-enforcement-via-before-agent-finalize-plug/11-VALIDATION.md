---
phase: 11
slug: structural-marker-enforcement-via-before-agent-finalize-plug
status: approved
nyquist_compliant: true
wave_0_complete: false
created: 2026-06-04
---

# Phase 11 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash integration tests (existing `tests/test_*.sh` pattern) + Node.js `node:test` for plugin logic (Node 22 ships it — no install) |
| **Config file** | none — shell scripts sourced directly; `plugin/` uses `node --test` |
| **Quick run command** | `bash tests/test_verify_markers.sh && (cd plugin && node --test)` |
| **Full suite command** | `for f in tests/test_*.sh; do bash "$f" || exit 1; done && (cd plugin && node --test)` |
| **Estimated runtime** | ~30 seconds (unit/integration; excludes manual host E2E) |

---

## Sampling Rate

- **After every task commit:** Run quick command for the touched surface (`node --test` for plugin tasks, the relevant `tests/test_*.sh` for bash tasks)
- **After every plan wave:** Run full suite command
- **Before `/gsd-verify-work`:** Full suite green AND the manual host E2E (SC-1) performed on `98.82.34.123`
- **Max feedback latency:** ~30 seconds (automated); host E2E is manual

---

## Per-Task Verification Map

> Task IDs are assigned by the planner; rows below map each Success Criterion to its proof so the planner can attach `<automated>` verify to the owning task. `File Exists` reflects Wave 0 status (most artifacts are new).

| SC | Behavior | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|----|----------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| SC-1 | `before_agent_finalize` returns `revise` when an `exec` turn ran but `write-marker.sh` did not | 1 | SC-1 | — | N/A | unit | `cd plugin && node --test` | ❌ W0 | ⬜ pending |
| SC-1 | Marked-completion coverage rises well above ~1/64 on host | — | SC-1 | — | N/A | manual E2E | host session on `98.82.34.123` + `scripts/verify-markers.sh` before/after | ❌ W0 | ⬜ pending |
| SC-2 | Bounded: `maxAttempts: 1` returned; harness budget caps forced passes | 1 | SC-2 | — | N/A | unit | `cd plugin && node --test` | ❌ W0 | ⬜ pending |
| SC-2 | Fail-open: handler error / no runId → no block (SDK catch → continue) | 1 | SC-2 | T-11-fail-open | hook error never blocks reply | unit | `cd plugin && node --test` | ❌ W0 | ⬜ pending |
| SC-3 | `before_tool_call` observation works without `allowConversationAccess`; `before_agent_finalize` registered only with the flag | 1 | SC-3 | T-11-silent-block | gate is not a silent no-op | structural + manual | `openclaw plugins inspect revenium-marker-gate` shows `before_agent_finalize` in `hookNames` | ❌ W0 | ⬜ pending |
| SC-3 | Plugin installs on ClawHub host via `openclaw plugins install` | — | SC-3 | — | N/A | manual on host | `openclaw plugins install "${SKILL_DIR}/plugin" --force` (run by post-install + validation) | ❌ W0 | ⬜ pending |
| SC-4 | `verify-markers.sh` reports per-session completions vs markers + coverage % | 1 | SC-4 | — | N/A | shell unit | `bash tests/test_verify_markers.sh` | ❌ W0 | ⬜ pending |
| SC-5 | No change to `report.sh` / guardrail behavior | 1 | SC-5 | — | preserve metering floor | regression | `bash tests/test_report_argv.sh` (and existing report tests) | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `plugin/package.json`, `plugin/openclaw.plugin.json`, `plugin/tsconfig.json` — plugin package scaffold
- [ ] `plugin/src/index.ts` — plugin source (testable handler logic)
- [ ] `plugin/dist/index.js` — committed pre-built artifact (ships in skill tarball; host has no `tsc`)
- [ ] `plugin/src/index.test.js` (or `.ts`) — `node:test` unit tests for SC-1 / SC-2
- [ ] `tests/test_verify_markers.sh` — shell unit test for SC-4 (session + markers fixtures)
- [ ] `scripts/verify-markers.sh` — diagnostic script under test

*Existing `tests/test_report_argv.sh` + report regression tests fully cover SC-5.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Revise loop fires end-to-end; agent classifies on the forced pass; coverage rises above ~1/64 | SC-1 | The premise is a production LLM-compliance failure that only reproduces on a real install with a live model (opus-4-8) | On `98.82.34.123` (`ssh -i ~/.ssh/agent-sandbox.pem ubuntu@`): install + enable plugin, restart gateway, run a batch of substantive turns, then `scripts/verify-markers.sh` and compare coverage before/after |
| Finalize proceeds when still unmarked after the bounded pass (fail-open in production) | SC-2 | Requires a real model that may still skip the marker after one forced pass | On host: observe that an unclassified turn still finalizes (no block) after the single revise attempt |
| Plugin install + `allowConversationAccess` flag take effect after gateway restart | SC-3 | Hook registration only loads at gateway start; silent-block failure mode only visible against the live registry | On host: `openclaw plugins install … --force`, patch config, restart gateway, `openclaw plugins inspect revenium-marker-gate` confirms `before_agent_finalize` registered |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies (host-only behaviors documented as manual)
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s (automated tier)
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** approved 2026-06-04 (plan-checker PASS; plans satisfy Nyquist Dimension 8 — `wave_0_complete` flips to true once the Wave 0 test files are built during execution)
