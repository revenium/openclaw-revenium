---
phase: 1
slug: skill-scaffolding
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-13
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Manual shell verification (SKILL.md is markdown, not code) |
| **Config file** | None |
| **Quick run command** | `openclaw skills list \| grep revenium` |
| **Full suite command** | See Per-Task Verification Map below |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `test -f ~/.openclaw/skills/revenium/SKILL.md && openclaw skills list | grep revenium`
- **After every plan wave:** Run all four requirement verifications
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 01-01-01 | 01 | 1 | SKAF-01 | smoke | `test -f ~/.openclaw/skills/revenium/SKILL.md && echo PASS` | ❌ W0 | ⬜ pending |
| 01-01-02 | 01 | 1 | SKAF-02 | manual | Remove `revenium` from PATH; `openclaw skills list \| grep -v revenium && echo PASS` | ❌ W0 | ⬜ pending |
| 01-01-03 | 01 | 1 | SKAF-03 | smoke | `openclaw skills list \| grep revenium` (skill appears = frontmatter valid) | ❌ W0 | ⬜ pending |
| 01-01-04 | 01 | 1 | SKAF-04 | smoke | `openclaw skills list \| grep revenium && echo PASS` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `openclaw` binary installed and on PATH
- [ ] `~/.openclaw/skills/revenium/` directory created
- [ ] `revenium` binary on PATH (already present)

*If none: "Existing infrastructure covers all phase requirements."*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Skill absent when binary missing | SKAF-02 | Requires temporarily modifying PATH | 1. Remove `revenium` from PATH 2. Run `openclaw skills list` 3. Verify revenium not listed 4. Restore PATH |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 5s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
