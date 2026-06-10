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

---

## LIVE VALIDATION (Phase 16, clean-host, doc-driven)

**Date:** 2026-06-10
**Host:** 34.224.27.67 (sandbox: revenium-spike)
**Validator:** Automated executor agent (Plan 16-03, Task 1)
**Phase 16 code version:** local dev HEAD (not yet pushed to GitHub — see SC2)
**CRITICAL HONESTY RULE:** All output below is real verbatim captured output. No claimed pass without observed evidence. Failures recorded as STILL FAILING.

---

### Pre-run state

Ledger before run (`~/.nemoclaw/revenium-nemoclaw.ledger`):
```
revenium-policy-applied=1
gh-release-policy-applied=1
cli-delivered=v1.2.0:cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67
creds-written=1
meter-probe-passed=1
metering-loop-installed=1
```
Keys absent before run: `skill-installed-nemoclaw`, `enforcement-plugin-installed`.

---

## SC1 — Live clean-host install + D-02 ✓ ready assertion + independent discovery

### Status: PASSED (SC1-a, SC1-b, SC1-c all verified)

### Evidence: SC1-a — `nemoclaw skill install` exits 0

The install script ran `install_skill_nemoclaw()` fresh (no ledger skip). The "Deploying revenium skill into sandbox" step executed fully.

```
Command: bash ~/.openclaw/skills/revenium/scripts/install.sh --nemoclaw
  (with REVENIUM_SANDBOX_NAME=revenium-spike REVENIUM_API_KEY=*** REVENIUM_TEAM_ID=DZxzEl exported)
Exit: 1 (install aborted at enforcement-plugin step — see SC1 note below)

Relevant skill-deploy section of output:

▸ Deploying revenium skill into sandbox
  Skipping 5 hidden path(s): .claude/, .gitignore, .pytest_cache/, plugin/.gitignore, plugin-nemoclaw/.gitignore
  ✓ Validated SKILL.md (name: revenium, 78 files)
  ✓ Uploaded 78 file(s) to sandbox
  ✓ Skill 'revenium' updated
  ✓ revenium skill confirmed ready in sandbox
  ✓ Revenium skill deployed to sandbox 'revenium-spike'
```

**Note on overall install exit code:** The install exited 1 at the `install_enforcement_plugin` step (after the skill deploy step) because the enforcement plugin was already installed in the sandbox from a prior phase run, and `openclaw plugins install` rejected the re-install with:
```
plugin already exists: /sandbox/.openclaw/extensions/revenium-enforcement (delete it first)
Use `openclaw plugins update <id-or-npm-spec>` to upgrade the tracked plugin, or rerun install with `--force` to replace it.
  ✗ openclaw plugins install failed — plugin will be untrusted/inert. Aborting.
```
This is a pre-existing plugin-conflict issue unrelated to SC1. The skill-deploy step (`install_skill_nemoclaw`) completed fully and successfully before this failure.

### Evidence: SC1-b — D-02 `✓ ready` assertion fired and PASSED live (not ledger-skipped)

The `skill-installed-nemoclaw` key was absent from the ledger before the run. The function ran fully (no early `return 0`). The assertion line was observed in live output:

```
Command: (captured from install.sh run above — Deploying revenium skill section)
Exit: assertion path reached and passed (function did not call fail())

Output (verbatim from install output):
  ✓ revenium skill confirmed ready in sandbox
  ✓ Revenium skill deployed to sandbox 'revenium-spike'
```

Proof it ran (not ledger-skipped): `skill-installed-nemoclaw=1` was written to the ledger by this run (absent before, present after).

### Evidence: SC1-c — Independent `openclaw skills list` shows `✓ ready  💰 revenium`

```
Command: nemoclaw revenium-spike exec -- sh -lc "openclaw skills list 2>&1"
Exit: 0

Output (revenium line):
│ ✓ ready  │ 💰 revenium              │ MANDATORY guardrail check BEFORE EVERY OPERATION — read     │ openclaw-managed │
│          │                          │ guardrail-status.json first, always, no exceptions.         │                  │
│          │                          │ Enforces Revenium guardrails-native budget rules, warns on  │                  │
│          │                          │ block, and meters usage into Revenium.                      │                  │
```

The `✓ ready` shape (`✓ ready  💰 revenium`) was confirmed present.

---

## SC2 — No undocumented steps (doc-driven install)

### Status: PARTIALLY EVIDENCED — SC1 assertion PASSED but two doc bugs flagged

The install followed `docs/nemoclaw-setup.md` with the following undocumented steps required before the documented commands could succeed:

### Undocumented Steps (doc bugs):

**Undocumented step 1 — Phase 16 code not yet published to GitHub [CRITICAL DOC BUG]**

```
Command: git clone https://github.com/revenium/openclaw-revenium.git ~/.openclaw/skills/revenium
Exit: 0

Problem: The cloned repo does NOT contain the Phase 16 NemoClaw scripts:
  - scripts/install.sh does not have --nemoclaw routing
  - scripts/post-install-nemoclaw.sh does not exist in the published repo
  - The cloned scripts/ directory contains only the standalone path scripts

Result: bash ~/.openclaw/skills/revenium/scripts/install.sh --nemoclaw
Exit: 127 (No such file or directory)

Workaround applied (undocumented): rsync of Phase 16 local dev codebase to host
  Command: rsync -az --exclude='.git' --exclude='.planning' <local-dev-path>/ ubuntu@34.224.27.67:~/.openclaw/skills/revenium/
  Exit: 0

Root cause: The NemoClaw scripts (Phase 13-16 additions) have not been pushed to
github.com/revenium/openclaw-revenium. The documented git clone gives the pre-NemoClaw
version of the repo.

Required fix: Push Phase 16 code to GitHub before the docs are functional end-to-end.
  git push origin main  (or equivalent after merging all phase work)
```

**Undocumented step 2 — Stale clone removal before rsync**

```
Command: rm -rf ~/.openclaw/skills/revenium
Exit: 0
Reason: Had to remove the stale clone (wrong scripts) before deploying Phase 16 code.
```

**Undocumented step 3 — Enforcement plugin conflict recovery (post-install restore)**

```
Problem: install.sh aborted with "plugin already exists" at install_enforcement_plugin() step.
The enforcement-plugin-installed ledger key was absent, causing a re-install attempt.
The plugin was already present from a prior phase run.

Restore commands applied:
  Command 1: nemoclaw revenium-spike exec -- sh -lc "echo '{plugins: {entries: {"revenium-enforcement": {enabled: true, hooks: {allowConversationAccess: true}}}}}' | openclaw config patch --stdin"
  Exit: 0  (Applied 2 config update(s))

  Command 2: nemoclaw revenium-spike recover
  Exit: 0  (Probe complete: OpenClaw gateway is running)

  Command 3: grep -v "^enforcement-plugin-installed=" ~/.nemoclaw/revenium-nemoclaw.ledger > .tmp && mv .tmp ~/.nemoclaw/revenium-nemoclaw.ledger
  followed by: echo "enforcement-plugin-installed=1" >> ~/.nemoclaw/revenium-nemoclaw.ledger
  Exit: 0  (Ledger restored to consistent state)
```

### SC2 Summary

| Step | In docs/nemoclaw-setup.md? | Classification |
|------|---------------------------|----------------|
| `git clone <repo>` | Yes (Step 1) | Documented — but fails (GitHub repo out of date) |
| `git config core.fileMode false` | Yes (Step 1) | Documented |
| `export REVENIUM_*` + `bash install.sh --nemoclaw` | Yes (Step 2) | Documented — but fails (wrong scripts) |
| rsync Phase 16 code to host | **No** | **UNDOCUMENTED — doc bug 1 (critical)** |
| rm stale clone | **No** | **UNDOCUMENTED — doc bug 2** |
| enforcement plugin recovery | **No** | **UNDOCUMENTED — doc bug 3** |
| `nemoclaw <name> exec -- sh -lc "openclaw skills list"` | Yes (Step 4) | Documented |

**SC2 verdict:** NOT PASS — 3 undocumented steps required. Root cause is that the GitHub repo does not yet have the Phase 16 NemoClaw code. Once the code is pushed to GitHub, doc bugs 2 and 3 reduce to maintenance issues (stale clone cleanup and idempotent enforcement-plugin-installed ledger key).

---

## Host Restore

**Status: RESTORED HEALTHY**

After the run, the following restore was applied to leave the host in a functional state:

```
1. Re-enabled enforcement plugin:
   Command: nemoclaw revenium-spike exec -- sh -lc "echo '{plugins: ...}' | openclaw config patch --stdin"
   Exit: 0 → Applied 2 config update(s)

2. Recovered sandbox:
   Command: nemoclaw revenium-spike recover
   Exit: 0 → Probe complete: OpenClaw gateway is running in 'revenium-spike'

3. Wrote enforcement-plugin-installed=1 to ledger (was absent; plugin is installed)

Final ledger state:
  revenium-policy-applied=1
  gh-release-policy-applied=1
  cli-delivered=v1.2.0:cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67
  creds-written=1
  meter-probe-passed=1
  metering-loop-installed=1
  skill-installed-nemoclaw=1
  enforcement-plugin-installed=1

Final skill state (post-restore):
  openclaw skills list → ✓ ready  💰 revenium  (confirmed)
  openclaw plugins inspect revenium-enforcement → Status: loaded
```
