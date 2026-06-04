---
phase: 10
slug: tool-registry-tool-event-metering
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-06-03
---

# Phase 10 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bats-core (shell test harness) / existing project test pattern |
| **Config file** | none — Wave 0 confirms harness from prior phases (4, 9) |
| **Quick run command** | `bats test/` (or the project's existing shell test runner) |
| **Full suite command** | `bats test/ && shellcheck report.sh` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bats test/` (relevant file)
- **After every plan wave:** Run full suite
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 10-01-01 | 01 | 1 | TOOLEV-01 | — | `revenium tools create` registers each tool once; fail-open on CLI error | unit | `bats test/tool-registry.bats` | ❌ W0 | ⬜ pending |
| 10-01-02 | 01 | 1 | TOOLEV-04 | — | Duplicate registration is idempotency-gated via TOOL: ledger key | unit | `bats test/tool-registry.bats` | ❌ W0 | ⬜ pending |
| 10-02-01 | 02 | 2 | TOOLEV-02 | — | toolCall items emit `revenium meter tool-event` with explicit `--success` | unit | `bats test/tool-event.bats` | ❌ W0 | ⬜ pending |
| 10-02-02 | 02 | 2 | TOOLEV-03 | — | tool-events post to /v2/tool/events; TOOL_CALL completion path untouched | unit | `bats test/tool-event.bats` | ❌ W0 | ⬜ pending |
| 10-02-03 | 02 | 2 | TOOLEV-04 | — | Duplicate tool-events idempotency-gated via TOOLEV:<toolcall_id> key | unit | `bats test/tool-event.bats` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `test/tool-registry.bats` — stubs for TOOLEV-01, TOOLEV-04 (registration + idempotency)
- [ ] `test/tool-event.bats` — stubs for TOOLEV-02, TOOLEV-03, TOOLEV-04 (event emission, no double-count, dedup)
- [ ] `bats-core` — confirm installed (used by prior metering phases); install if absent
- [ ] revenium CLI stub/mock for `tools create` and `meter tool-event` to assert invocation args without live API

*If existing infrastructure from Phases 4/9 covers these, Wave 0 reuses it.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Tool-event appears in Revenium dashboard with success=true | TOOLEV-02 | Requires live Revenium account + network | On test host 172.16.1.247, trigger a tool call, run report.sh, confirm tool-event in Revenium UI with correct success flag |
| Registered tool visible via `revenium tools list` | TOOLEV-01 | Requires live API | Run `revenium tools create` then `revenium tools list`, confirm tool-id present once |
| No double-count: tool usage not also billed as extra completion | TOOLEV-03 | Cross-endpoint correlation in live account | Compare /v2/api/completions vs /v2/tool/events counts after a session with N tool calls |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
