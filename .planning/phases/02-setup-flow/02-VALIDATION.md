---
phase: 2
slug: setup-flow
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-14
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Manual shell verification (SKILL.md is markdown prose, not code) |
| **Config file** | None |
| **Quick run command** | `test -f ~/.openclaw/skills/revenium/config.json && python3 -c "import json; d=json.load(open('$HOME/.openclaw/skills/revenium/config.json')); assert 'alertId' in d and isinstance(d['alertId'], str) and len(d['alertId']) > 3; print('PASS')"` |
| **Full suite command** | See Per-Task Verification Map below |
| **Estimated runtime** | ~10 seconds |

---

## Sampling Rate

- **After every task commit:** `test -f ~/.openclaw/skills/revenium/config.json && python3 -c "import json; d=json.load(open('$HOME/.openclaw/skills/revenium/config.json')); assert 'alertId' in d; print('config valid')" 2>&1`
- **After every plan wave:** Run all automated checks + manual observation of setup conversation
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 10 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 02-01-01 | 01 | 1 | SETUP-01 | manual | Remove config.json; start agent session; confirm agent asks for API key | N/A | ⬜ pending |
| 02-01-02 | 01 | 1 | SETUP-02 | smoke | `revenium config show` — confirms key is set | N/A | ⬜ pending |
| 02-01-03 | 01 | 1 | SETUP-03 | manual | Observe setup; confirm amount is requested | N/A | ⬜ pending |
| 02-01-04 | 01 | 1 | SETUP-04 | manual | Observe setup; confirm period options presented | N/A | ⬜ pending |
| 02-01-05 | 01 | 1 | SETUP-05 | smoke | `revenium alerts budget list --json` — check for OpenClaw alert | N/A | ⬜ pending |
| 02-01-06 | 01 | 1 | SETUP-06 | smoke | `python3 -c "import json; d=json.load(open('...')); assert isinstance(d.get('alertId'), str)"` | ❌ W0 | ⬜ pending |
| 02-01-07 | 01 | 1 | SETUP-07 | smoke | Run setup twice; check alert count = 1 | N/A | ⬜ pending |
| 02-01-08 | 01 | 1 | SETUP-08 | manual | Invoke `/revenium`; reconfigure; verify old alert deleted + new created | N/A | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- None — existing test infrastructure covers all phase requirements. SKILL.md correctness verified by running the agent through the setup flow.

*If none: "Existing infrastructure covers all phase requirements."*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Agent prompts for API key on first use | SETUP-01 | Requires observing agent conversation | 1. Remove config.json 2. Start agent session 3. Verify agent asks for key before operating |
| Agent prompts for budget amount | SETUP-03 | Requires observing agent conversation | Observe during setup |
| Agent prompts for period selection | SETUP-04 | Requires observing agent conversation | Observe during setup, confirm DAILY/WEEKLY/MONTHLY/QUARTERLY offered |
| `/revenium` reconfiguration | SETUP-08 | Requires interactive agent session | Invoke `/revenium`, choose reconfigure, verify old alert deleted + new created |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 10s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
