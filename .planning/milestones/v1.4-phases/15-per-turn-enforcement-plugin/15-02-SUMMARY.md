---
phase: 15-per-turn-enforcement-plugin
plan: "02"
subsystem: install-scripts
status: complete
tags: [install, nemoclaw, enforcement-plugin, skill-deploy, validation-gates, NCENF-01, NCENF-02, NCDEPLOY-01]
requirements: [NCENF-01, NCENF-02, NCDEPLOY-01]

dependency_graph:
  requires:
    - plugin-nemoclaw/ (Plan 01 artifact — committed dist/ required for delivery over mount)
    - scripts/install-nemoclaw-cron.sh (mount-establish pattern reused, Phase 14)
    - scripts/post-install.sh §7c (plugins install + config patch pattern adapted)
  provides:
    - scripts/post-install-nemoclaw.sh (real install_skill_nemoclaw + install_enforcement_plugin replacing stub)
    - scripts/uninstall-enforcement-nemoclaw.sh (teardown counterpart)
  affects:
    - scripts/post-install-nemoclaw.sh (stub_install_enforcement_plugin removed; two real functions wired)

tech_stack:
  added: []
  patterns:
    - Ledger-gated install functions (install_skill_nemoclaw, install_enforcement_plugin)
    - Share mount establish/reuse (Phase 14 MNT pattern)
    - Fail-HARD validation gates (not warn-and-continue): turn-test + inspect + python3 + marker smoke
    - Single-line sh -lc nemoclaw exec payloads (newline constraint honored)
    - Warn-and-continue teardown (uninstall is best-effort)

key_files:
  created:
    - scripts/uninstall-enforcement-nemoclaw.sh
  modified:
    - scripts/post-install-nemoclaw.sh

decisions:
  - key: validation-gates-inline-in-install_enforcement_plugin
    description: "Tasks 1 and 2 both target post-install-nemoclaw.sh. The plan allowed placing validation gates inline in install_enforcement_plugin() rather than in a separate helper (_validate_enforcement_install). Implemented inline for simpler control flow — the gate code is only called from one place."
    alternatives_considered: "Separate _validate_enforcement_install helper (more modular but unnecessary indirection for a single callsite)"

metrics:
  duration: "~3 minutes"
  completed: "2026-06-09"
  tasks_completed: 3
  tasks_total: 3
  files_created: 1
  files_modified: 1
  tests: 0
---

# Phase 15 Plan 02: Install Wiring & Validation Gates Summary

One-liner: Real `install_skill_nemoclaw` + `install_enforcement_plugin` replace the stub in `post-install-nemoclaw.sh` — delivering the Plan 01 plugin over the Phase 14 share mount, trust-installing it, applying config patch, recovering, and fail-HARD validating via turn-test + inspect + python3 + marker smoke.

## What Was Built

### `scripts/post-install-nemoclaw.sh` (modified)

The `stub_install_enforcement_plugin()` placeholder is removed. Two new ledger-gated functions replace it:

**`install_skill_nemoclaw()`** (ledger key: `skill-installed-nemoclaw`):
- Runs `nemoclaw "${SANDBOX_NAME}" skill install "${SCRIPT_DIR}/.."` (repo root IS the skill dir)
- Fails non-zero on error; sets the ledger key on success
- Pulled into Phase 15 per D-08 so the marker chain is end-to-end verifiable before the plugin smoke gate

**`install_enforcement_plugin()`** (ledger key: `enforcement-plugin-installed`):

1. **Mount establish** — reuses Phase 14 `MNT="${HOME}/sbx-openclaw-${SANDBOX_NAME}"` pattern; mounts if not already a mountpoint
2. **Plugin copy** — `rm -rf` dest first, then `cp -r plugin-nemoclaw/ <mount>/extensions/revenium-enforcement` (idempotent re-copy, no stale-file blends)
3. **Trust install** — `openclaw plugins install /sandbox/.openclaw/extensions/revenium-enforcement` (records provenance; hand-placed plugins are inert without this)
4. **Config patch** — single-line `sh -lc` payload: `{plugins: {entries: {"revenium-enforcement": {enabled: true, hooks: {allowConversationAccess: true}}}}}` piped to `openclaw config patch --stdin` (JSON5 merge, re-run-safe; `allowConversationAccess: true` required for `before_agent_finalize` + `agent_end` to register)
5. **Recover** — `nemoclaw recover` to load the plugin
6. **Fail-HARD validation gates** (each uses `fail`, not `warn`):
   - **Gate A (D-10)**: `openclaw agent --json --message 'ping'` output must contain `<revenium-guard>` — verifies `before_prompt_build` injects the directive
   - **Gate B (D-09)**: `openclaw plugins inspect revenium-enforcement` must contain both `before_prompt_build` AND `before_agent_finalize` — verifies trusted hooks + `allowConversationAccess`
   - **Gate C (D-07)**: `python3 --version` must succeed in-sandbox — `write-marker.sh` dependency
   - **Gate D (D-07)**: `write-marker.sh testing` must produce a `*.jsonl` visible under `${MNT}/markers/` — verifies mount + write path end-to-end

**Callsite rewire** (main execution block, lines 498-500):
```bash
install_metering_loop
install_skill_nemoclaw         # D-08: deploy skill first (marker chain precondition)
install_enforcement_plugin     # D-05/D-09/D-10/D-11: plugin + validation gate
```

Success banner updated: Phase 15 listed as delivered; `Phase 14/15 pending` section removed.

### `scripts/uninstall-enforcement-nemoclaw.sh` (new)

Modeled on `scripts/uninstall-nemoclaw-cron.sh`. Best-effort teardown:
1. `openclaw plugins uninstall revenium-enforcement` in-sandbox (warn-and-continue if absent)
2. Config patch setting `enabled: false` (single-line `sh -lc`, same newline constraint)
3. `rm -rf <mount>/extensions/revenium-enforcement` if mount is active
4. `ledger_clear "enforcement-plugin-installed"` so a later install re-provisions

Does not touch `metering-loop-installed`, `skill-installed-nemoclaw`, or any standalone-path file. Safe to run when nothing is installed.

## Verification Results

```
bash -n scripts/post-install-nemoclaw.sh          → OK
bash -n scripts/uninstall-enforcement-nemoclaw.sh  → OK
grep -q "install_enforcement_plugin"              → OK
grep -q "install_skill_nemoclaw"                  → OK
! grep -q "stub_install_enforcement_plugin"       → OK (stub gone)
grep -q "allowConversationAccess"                 → OK
grep -q "revenium-guard"                          → OK (Gate A)
grep -q "plugins inspect revenium-enforcement"    → OK (Gate B)
grep -q "python3"                                 → OK (Gate C)
grep -q "write-marker.sh"                         → OK (Gate D)
Callsite order: install_skill_nemoclaw (499) before install_enforcement_plugin (500) → OK
```

## Deviations from Plan

### Implementation Notes

**1. Tasks 1 and 2 combined in a single file edit**
- **Found during:** Task 1 implementation
- **Issue:** Plan Tasks 1 and 2 both modify the same function body (`install_enforcement_plugin`). The plan explicitly offers "place the validation inline after recover — Task 2 fills it" as the alternative to a separate helper.
- **Action:** Implemented all validation gates inline in the single function body per the plan's alternate guidance. Both tasks are covered in the Task 1 commit (5d396b7). No separate commit was needed for Task 2 as there were no additional file changes.
- **Impact:** None — all acceptance criteria for both tasks satisfied.

## Known Stubs

None. No placeholder data flows to any rendering path. Every gate is a real check, not a stub.

## Threat Surface Scan

All trust boundaries declared in the plan's `<threat_model>` are mitigated as implemented:

| Threat | Mitigation Status |
|--------|------------------|
| T-15-05 Elevation of Privilege (hand-placed plugin) | `openclaw plugins install` is the trust gate — hand copy alone is inert; Gate B (inspect) confirms provenance was accepted |
| T-15-06 Tampering (config patch over nemoclaw exec) | Single-line `sh -lc` payload only; no multi-line argv; JSON5 merge re-run-safe |
| T-15-07 DoS (install validation hang) | Turn-test reads `finalPromptText` (prompt-side, deterministic) with `2>/dev/null || true` capture; `fail` on absence rather than hang-wait |
| T-15-08 Information Disclosure (marker write egress) | `write-marker.sh` writes to local `markers/<sid>.jsonl` only — no egress, no secrets cross the boundary |
| T-15-09 Spoofing (mount-path integrity) | Phase 14 mount pattern reused; `rm -rf` dest before copy prevents stale-file blends |

No new threat surface beyond the plan's declared boundaries.

## Self-Check: PASSED

- [x] `bash -n scripts/post-install-nemoclaw.sh` exits 0
- [x] `bash -n scripts/uninstall-enforcement-nemoclaw.sh` exits 0
- [x] `stub_install_enforcement_plugin` not in `post-install-nemoclaw.sh`
- [x] `install_skill_nemoclaw` defined and ledger-gated (`skill-installed-nemoclaw`)
- [x] `install_enforcement_plugin` defined and ledger-gated (`enforcement-plugin-installed`)
- [x] Callsite: `install_skill_nemoclaw` at line 499, `install_enforcement_plugin` at line 500 (skill first)
- [x] Config patch is single-line `sh -lc` containing `enabled: true` and `allowConversationAccess: true`
- [x] Plugin delivered to `<mount>/extensions/revenium-enforcement` and installed via `openclaw plugins install /sandbox/.openclaw/extensions/revenium-enforcement`
- [x] All four gates use `fail` (not `warn`): Gate A (`revenium-guard`), Gate B (`before_prompt_build` + `before_agent_finalize`), Gate C (`python3`), Gate D (marker smoke)
- [x] `uninstall-enforcement-nemoclaw.sh` calls `plugins uninstall revenium-enforcement` and clears `enforcement-plugin-installed` ledger key
- [x] Commits: 5d396b7 (Tasks 1+2), 1695e6f (Task 3)
