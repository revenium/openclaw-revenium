---
phase: 3
slug: guardrail-engine
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-05-31
---

# Phase 3 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash / shell integration tests |
| **Config file** | none — scripts tested via direct invocation |
| **Quick run command** | `bash scripts/guardrail-check.sh --dry-run` |
| **Full suite command** | `bash scripts/common.sh && bash scripts/guardrail-check.sh && openclaw skills list` |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash scripts/guardrail-check.sh --dry-run`
- **After every plan wave:** Run full suite command
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 10 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 3-01-01 | 01 | 1 | GUARD-01 | — | N/A | integration | `bash scripts/common.sh && echo OK` | ✅ | ⬜ pending |
| 3-01-02 | 01 | 1 | GUARD-02 | — | N/A | integration | `bash scripts/setup-guardrails.sh --help` | ✅ | ⬜ pending |
| 3-01-03 | 01 | 2 | GUARD-03 | — | N/A | integration | `bash scripts/guardrail-check.sh; echo exit:$?` | ✅ | ⬜ pending |
| 3-01-04 | 01 | 2 | GUARD-04 | — | N/A | integration | `grep ruleIds ~/.openclaw/skills/revenium/config.json` | ✅ | ⬜ pending |
| 3-01-05 | 01 | 3 | GUARD-05 | — | N/A | manual | Verify SKILL.md reads guardrail-status.json | ✅ | ⬜ pending |
| 3-01-06 | 01 | 3 | GUARD-06 | — | N/A | manual | Verify BUDGET-GUARD.md injected via bootstrap-extra-files | ✅ | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `bash` 3.2+ on PATH (macOS default — no install needed)
- [ ] `revenium` CLI on PATH with `guardrails` subcommands available (verified post-upgrade)
- [ ] `openclaw` 2026.5.28 installed and on PATH

*Existing infrastructure covers basic shell execution. No test framework installation required.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| `setup-guardrails.sh --interactive` creates rule and writes ruleIds | GUARD-01 | Requires live Revenium API + interactive TTY | Run `bash scripts/setup-guardrails.sh --interactive`, verify ruleIds in config.json |
| Halt transitions fire notification via openclaw message send | GUARD-03 | Requires live guardrail rule in block state | Manually set rule to block state, run guardrail-check.sh, verify notification received |
| Shadow mode: no halt on shadow block | GUARD-03 | Requires shadow rule configuration | Create shadow rule, trigger block, verify halted=false in guardrail-status.json |
| Legacy alertId-only install → Setup Flow triggered | GUARD-04 | Requires config.json with alertId but no ruleIds | Manually edit config.json, run SKILL.md logic, verify setup flow delegation |
| BUDGET-GUARD.md injected in new workspace | GUARD-06 | Requires openclaw workspace creation | Create new workspace, verify BUDGET-GUARD.md appears via bootstrap-extra-files |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 10s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
