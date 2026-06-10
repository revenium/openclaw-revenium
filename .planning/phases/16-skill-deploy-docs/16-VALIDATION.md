---
phase: 16
slug: skill-deploy-docs
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-06-10
---

# Phase 16 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Bash (existing `tests/test_install_dispatcher.sh`, `tests/test_nemoclaw_provisioning.sh`, `tests/test_nemoclaw_cron.sh`) |
| **Config file** | none — shell-based harness |
| **Quick run command** | `bash tests/test_nemoclaw_provisioning.sh` |
| **Full suite command** | `bash tests/test_install_dispatcher.sh && bash tests/test_nemoclaw_provisioning.sh && bash tests/test_nemoclaw_cron.sh` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test_nemoclaw_provisioning.sh`
- **After every plan wave:** Run `bash tests/test_install_dispatcher.sh && bash tests/test_nemoclaw_provisioning.sh && bash tests/test_nemoclaw_cron.sh`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 16-01-01 | 01 | 1 | NCDEPLOY-01 | T-16-01 / — | SKILL.md path guard fails hard with actionable message when skill dir is wrong (prevents SSHFS abort) | unit (bash) | `bash tests/test_nemoclaw_provisioning.sh` | ❌ W0 | ⬜ pending |
| 16-01-02 | 01 | 1 | NCDEPLOY-01 | — | `install_skill_nemoclaw()` asserts `✓ ready` via `openclaw skills list`; fails hard if revenium skill not ready | unit (bash) | `bash tests/test_nemoclaw_provisioning.sh` | ❌ W0 | ⬜ pending |
| 16-02-01 | 02 | 1 | NCDEPLOY-02 | — | `docs/nemoclaw-setup.md` exists with Prerequisites / install steps / `✓ ready` verify / parallel-path / macOS error / Troubleshooting / Uninstall sections | smoke | `grep -Eq 'Prerequisites' docs/nemoclaw-setup.md && grep -q 'macOS' docs/nemoclaw-setup.md` | ❌ W0 | ⬜ pending |
| 16-02-02 | 02 | 1 | NCDEPLOY-02 | — | `README.md` contains pointer link to `docs/nemoclaw-setup.md` and standalone path unchanged | smoke | `grep -q 'nemoclaw-setup.md' README.md` | ❌ W0 | ⬜ pending |
| 16-03-01 | 03 | 2 | NCDEPLOY-01, NCDEPLOY-02 | — | Live clean-host install follows only the docs; `✓ ready` observed; evidence recorded in 16-VALIDATION evidence log | manual (live sandbox) | manual — see Manual-Only Verifications | N/A | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test_nemoclaw_provisioning.sh` — add a test group for `install_skill_nemoclaw()`: (a) SKILL.md guard fires (non-zero exit + actionable message) when `SKILL.md` is absent from the resolved skill dir, (b) `✓ ready` assertion fails hard when `openclaw skills list` output lacks a ready `revenium` line, (c) assertion passes when output contains a ready `revenium` line. Stub the `nemoclaw` CLI so the test runs without a live sandbox.

*`docs/nemoclaw-setup.md` and the `README.md` pointer link are content tasks, not test-infra gaps — verified by smoke greps above.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Clean-host end-to-end install proves no undocumented steps (SC2) and real `✓ ready` discovery (SC1) | NCDEPLOY-01, NCDEPLOY-02 | Requires a live NemoClaw sandbox host (`34.224.27.67`); cannot run in the bash harness. CRITICAL HONESTY RULE applies — record real commands, exit codes, and observed output; never claim a pass that did not happen. | On clean host, follow **only** `docs/nemoclaw-setup.md`: install prerequisites, run the NemoClaw install path, observe `✓ ready` in `openclaw skills list`. Record every command + exit code + output in the 16-VALIDATION evidence log. Any deviation from the doc = an undocumented step = doc bug to fix. |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies (16-03-01 is manual-only by nature — live host)
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
