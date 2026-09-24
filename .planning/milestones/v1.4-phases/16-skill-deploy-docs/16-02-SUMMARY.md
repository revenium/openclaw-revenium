---
phase: 16-skill-deploy-docs
plan: "02"
status: complete
subsystem: docs
tags: [nemoclaw, docs, operator-runbook, macos]
requirements: [NCDEPLOY-02]

dependency_graph:
  requires: []
  provides: [NemoClaw operator runbook, README pointer link]
  affects: [docs/nemoclaw-setup.md, README.md]

tech_stack:
  added: []
  patterns: [markdown-runbook, blockquote-caveat, fenced-bash-blocks]

key_files:
  created:
    - docs/nemoclaw-setup.md
  modified:
    - README.md

decisions:
  - "docs/nemoclaw-setup.md parallels README.md section structure without copying standalone-only steps"
  - "README.md pointer link placed after ### 5. Verify, before ### First-time setup (automatic)"
  - "Brew warning retained in runbook as explicit Pitfall 3 note (not a brew install instruction)"

metrics:
  duration_minutes: 3
  completed_date: "2026-06-10"
  tasks_completed: 2
  files_created: 1
  files_modified: 1
---

# Phase 16 Plan 02: NemoClaw Operator Runbook Summary

NemoClaw/OpenShell operator runbook covering all D-04 required sections with verbatim macOS refusal string from scripts/install.sh, plus a single pointer blockquote added to README.md.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Create docs/nemoclaw-setup.md operator runbook | 891aed8 | docs/nemoclaw-setup.md (315 lines, created) |
| 2 | Add single README.md pointer link to NemoClaw runbook | 58572ae | README.md (+2 lines, no deletions) |

## What Was Built

**docs/nemoclaw-setup.md** — a full standalone operator runbook for the NemoClaw/OpenShell install path, covering all D-04 required sections:

1. **Prerequisites** — Linux host, Docker, NemoClaw installed, `sshfs`, prebuilt `revenium` binary (tarball, not brew), required env vars (REVENIUM_API_KEY etc.)
2. **Install command sequence** — running `scripts/install.sh --nemoclaw` → `post-install-nemoclaw.sh`, noting the ~11 min bootstrap
3. **`✓ ready` verification** — `openclaw skills list` in-sandbox shows `✓ ready  💰 revenium`; installer asserts this automatically
4. **Parallel-path guarantee** — explicit statement that standalone OpenClaw + Docker path is untouched; pointer back to README.md
5. **macOS-unsupported constraint** — verbatim refusal string from scripts/install.sh (including `  ✗ NemoClaw is unsupported on macOS.`) with exit code 1 and explanation of graceful-skip false-success
6. **Troubleshooting** — macOS refusal, SSHFS unsafe-filename error with SKILL.md guard message, sandbox restart/recovery, re-provisioning after key rotation
7. **Uninstall** — host cron (uninstall-nemoclaw-cron.sh), enforcement plugin, `nemoclaw skill remove`, skill directory removal
8. **Cross-references** — SKILL.md, BUDGET-GUARD.md, README.md

**README.md** — single pointer blockquote added at the end of `### 5. Verify`, before `### First-time setup (automatic)`:
```
> **Running on NemoClaw/OpenShell?** See [NemoClaw Setup](docs/nemoclaw-setup.md) for the parallel install path.
```
2 lines added, 0 lines deleted. No standalone content modified (SC4).

## Deviations from Plan

None - plan executed exactly as written.

## Verification Results

All plan verification checks pass:
- `test -f docs/nemoclaw-setup.md` — PASS
- Section greps (Prerequisites, macOS, uninstall, `openclaw skills list`) — PASS
- `grep -qF 'NemoClaw is unsupported on macOS.' docs/nemoclaw-setup.md` — PASS (verbatim string parity with scripts/install.sh)
- `grep -q 'nemoclaw-setup.md' README.md` — PASS
- README.md diff: 2 lines added, 0 deleted — PASS (SC4 preserved)

## Acceptance Criteria

- [x] docs/nemoclaw-setup.md exists and contains all D-04 sections (Prerequisites, install sequence, `✓ ready`, parallel-path guarantee, macOS constraint, Troubleshooting, Uninstall)
- [x] Verbatim string `NemoClaw is unsupported on macOS.` present — matches scripts/install.sh
- [x] References `openclaw skills list` and `✓ ready` output shape
- [x] References `/sandbox/.config/revenium/config.yaml` with `api-key:` field
- [x] Does NOT instruct `brew install revenium` for the NemoClaw path (Pitfall 3 — only warns AGAINST it)
- [x] Cross-references SKILL.md, BUDGET-GUARD.md, README.md
- [x] README.md pointer link present (`nemoclaw-setup.md`)
- [x] README.md diff adds only pointer-link blockquote, no deletions of standalone content

## Self-Check: PASSED

Files exist:
- docs/nemoclaw-setup.md: FOUND
- README.md: FOUND (modified)

Commits exist:
- 891aed8 (docs(16-02): create NemoClaw operator runbook): FOUND
- 58572ae (docs(16-02): add NemoClaw runbook pointer link to README.md): FOUND
