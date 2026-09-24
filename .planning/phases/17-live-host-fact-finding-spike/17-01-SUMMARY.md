---
phase: 17-live-host-fact-finding-spike
plan: "01"
subsystem: infra
tags: [spike, live-host, provisioning, nemoclaw, openshell, tracer, sqlite, openclaw-2-0]

requires: []
provides:
  - "Idempotent, committed provision-2-0-host.sh standing up both production install paths (standalone OpenClaw+Docker, NemoClaw/OpenShell) on 52.90.9.242"
  - "SPIKE-00 VALIDATED determination in .planning/spikes/007-live-2-0-host-provisioning/README.md"
  - "Proof the 2.0 SQLite session store is readable read-only (mode=ro, busy_timeout) — the apparatus SPIKE-01/04 depend on"
  - "api.revenium.ai egress preset confirmed working with a real key (closes spike 003's PARTIAL)"
  - "Live corrections to CONVENTIONS.md-era assumptions: NemoClaw's default 'latest' install undershoots the 2.0 floor; policy-add/policy-list renamed to policy add/policy list"
affects: [18-version-gate-and-install-health, 19-session-read-path, 20-plugin-2-0-sdk-compliance, 22-nemoclaw-openshell-path-on-2-0, 24-clawhub-release]

actuals:
  tokens: 16800
  tasks: 4
  commits: 5

tech-stack:
  added: []
  patterns:
    - "Idempotent, detection-gated provisioning script (pass/warn/fail scaffolding reused from spike 001)"
    - "Read-only WAL-aware SQLite probing: sqlite3 -cmd 'PRAGMA busy_timeout=5000;' 'file:<path>?mode=ro' '<dot-command-or-SQL>'"
    - "Numeric CalVer version comparison via sort -C -V, never string-prefix"
    - "Host-side binary delivery via NemoClaw share mount, not in-sandbox fetch (avoids widening sandbox egress)"

key-files:
  created:
    - .planning/spikes/007-live-2-0-host-provisioning/provision-2-0-host.sh
    - .planning/spikes/007-live-2-0-host-provisioning/README.md
    - .planning/spikes/007-live-2-0-host-provisioning/provision-run.log
    - .planning/spikes/007-live-2-0-host-provisioning/versions-resolved.txt
    - .planning/spikes/007-live-2-0-host-provisioning/tracer-turn-readback.txt
    - .planning/spikes/007-live-2-0-host-provisioning/revenium-egress-check.txt
  modified: []

key-decisions:
  - "NemoClaw's non-pinned 'latest' install resolves to a maintained-last-known-good tag (v0.0.124 observed) that undershoots the project's v0.0.128 floor and produces a pre-2.0 in-sandbox OpenClaw (2026.7.1) — provision-2-0-host.sh now defaults NEMOCLAW_INSTALL_TAG to the stated floor rather than trusting the installer's own 'latest' resolution."
  - "openclaw agent exec is ephemeral (no persisted SQLite state) and unsuitable as the read-path tracer entry point; openclaw agent --agent <id> --local --model ... is the persistent, production-shaped entry point used instead."
  - "The revenium CLI is delivered host-side and placed into the sandbox via the share mount (not an in-sandbox fetch), per spike 003's finding that brew has no Linux bottle and to avoid widening sandbox egress for the GitHub release CDN."
  - "api.revenium.ai egress-preset confirmation classified via CLI exit codes (2=auth rejected vs 4=validation error) rather than assuming only 200/403/transport-failure are possible outcomes — a real key produced an unanticipated 4th outcome (missing teamId) that is nonetheless decisive proof of working egress+TLS+auth."

requirements-completed: [SPIKE-00]

coverage:
  - id: D1
    description: "Standalone OpenClaw+Docker path provisioned idempotently on 52.90.9.242, clearing all version floors (OpenClaw >=2026.8.1, Node >=24.16 range)"
    requirement: SPIKE-00
    verification:
      - kind: manual_procedural
        ref: "ssh openclaw --version && node --version && docker --version (see provision-run.log)"
        status: pass
    human_judgment: false
  - id: D2
    description: "One real agent turn completed with a real Anthropic key and read back read-only from the 2.0 SQLite session store"
    requirement: SPIKE-00
    verification:
      - kind: manual_procedural
        ref: "tracer-turn-readback.txt — SELECT ... FROM transcript_events WHERE event_json LIKE '%SPIKE007_OK2%'"
        status: pass
    human_judgment: false
  - id: D3
    description: "NemoClaw/OpenShell path (sandbox revenium-2-0, NemoClaw v0.0.128, in-sandbox OpenClaw 2026.9.1) live simultaneously with the standalone path on the same host"
    requirement: SPIKE-00
    verification:
      - kind: manual_procedural
        ref: "nemoclaw revenium-2-0 status; versions-resolved.txt standalone: and nemoclaw-sandbox: lines"
        status: pass
    human_judgment: false
  - id: D4
    description: "api.revenium.ai egress preset confirmed working via one authenticated read-only call, closing spike 003's PARTIAL"
    requirement: SPIKE-00
    verification:
      - kind: manual_procedural
        ref: "revenium-egress-check.txt — revenium sources list --output json, CLI exit code 4 (validation, not auth-rejection)"
        status: pass
    human_judgment: true
    rationale: "The result (HTTP 400 missing teamId) is a 4th outcome not literally one of the plan's anticipated three (200/403/transport-failure); classification as 'egress proven, account-scoping incomplete' rests on CLI exit-code semantics reasoning documented in README.md Finding 7 — a human should confirm this interpretation is sound before downstream phases rely on it."
  - id: D5
    description: "provision-2-0-host.sh proven re-runnable (D-14): second full run exits 0 with zero install actions; version-comparison helper explicitly refuses below-floor versions including a naive-comparison-defeating crafted string"
    requirement: SPIKE-00
    verification:
      - kind: manual_procedural
        ref: "provision-run.log Task 4 sections; --version-check 2026.8.0 2026.8.1 and --version-check 2026.8.9 2026.8.10 probes"
        status: pass
    human_judgment: false

duration: 100min
completed: 2026-09-24
status: complete
---

# Phase 17 Plan 01: Live 2.0 Host Provisioning Summary

**Both OpenClaw 2.0 production install paths (standalone + NemoClaw/OpenShell) live simultaneously on a reproducibly-provisioned host, with one real agent turn proven readable from the 2.0 SQLite store and the api.revenium.ai egress preset confirmed working with a real key.**

## Performance

- **Duration:** ~100 min
- **Started:** 2026-09-24T04:15:00Z (approx.)
- **Completed:** 2026-09-24T05:35:35Z
- **Tasks:** 4
- **Files created:** 6

## Accomplishments

- Idempotent, committed `provision-2-0-host.sh` brings up both production install paths on `52.90.9.242` from a detection-gated, explicit-refusal-on-below-floor script, proven re-runnable with zero install actions on a second pass
- One real agent turn completed via `openclaw agent --local --model anthropic/claude-sonnet-4-6` and read back verbatim, read-only (`mode=ro`, `busy_timeout`), from the live 2.0 SQLite session store — the tracer's end-to-end proof the whole apparatus works
- Both paths' resolved OpenClaw versions recorded separately per D-15: standalone `2026.9.6`, NemoClaw-managed `2026.9.1` — genuinely different, not normalized
- `api.revenium.ai` egress preset confirmed working from inside the sandbox with a real Revenium key, closing spike 003's long-standing PARTIAL verdict
- SPIKE-00 written up as a complete, VALIDATED determination in `.planning/spikes/007-live-2-0-host-provisioning/README.md`, self-contained per D-12's evidence standard

## Task Commits

Each task was committed atomically:

1. **Task 1: End-to-end "a real 2.0 turn is readable" — one path only** - `85c7b09` (feat)
2. **Task 2: Expand provisioning to the NemoClaw/OpenShell path** - `5962241` (feat)
3. **Task 3: Prove the api.revenium.ai egress preset actually works** - `b99244e` (feat)
4. **Task 4: Prove re-runnability and finish the SPIKE-00 determination** - `665fc25` (docs)

A fifth commit, `70b1e65` (docs), refined PATH-ordering guidance discovered while running the plan-level `<verification>` block after Task 4.

## Files Created/Modified

- `.planning/spikes/007-live-2-0-host-provisioning/provision-2-0-host.sh` - Idempotent, detection-gated dual-path provisioning script
- `.planning/spikes/007-live-2-0-host-provisioning/README.md` - SPIKE-00 determination (VALIDATED), full evidence set, 7 numbered live-host findings
- `.planning/spikes/007-live-2-0-host-provisioning/provision-run.log` - Raw, trimmed-not-paraphrased provisioning run output across all 4 tasks
- `.planning/spikes/007-live-2-0-host-provisioning/versions-resolved.txt` - Per-path resolved versions, recorded separately per D-15
- `.planning/spikes/007-live-2-0-host-provisioning/tracer-turn-readback.txt` - The tracer turn's completion read back out of the 2.0 SQLite store
- `.planning/spikes/007-live-2-0-host-provisioning/revenium-egress-check.txt` - Key-redacted capture of the authenticated api.revenium.ai call

## Decisions Made

- **`NEMOCLAW_INSTALL_TAG` pinned by default to the project's floor (`v0.0.128`).** NemoClaw's documented non-interactive installer resolves "latest" to a maintained-last-known-good git tag, not the newest published tag — on this host that landed on `v0.0.124` (in-sandbox OpenClaw `2026.7.1`, pre-2.0) even though `v0.0.128`/`v0.0.129` already existed. The installer's own error output documents `NEMOCLAW_INSTALL_TAG=v<X>` as the escape hatch; the script now uses it by default, overridable for a future phase that wants true "latest."
- **`openclaw agent exec` rejected as the tracer's entry point.** It runs against ephemeral state (nothing persists to `~/.openclaw/agents/` afterward) — correct for its documented one-off headless purpose, but wrong for proving the persistent SQLite read path. `openclaw agent --agent <id> --local --model ...` is the entry point every downstream v2.0 phase's read-path work will actually observe in production.
- **revenium CLI delivered host-side via the share mount**, not an in-sandbox fetch — avoids widening sandbox egress for the GitHub release CDN and matches spike 003's finding that brew has no Linux bottle for this binary.
- **A 4th egress-check outcome (HTTP 400 missing teamId) classified via CLI exit-code semantics**, not literally one of the plan's anticipated three outcomes. Exit code 4 (validation error) is distinct from exit code 2 (authentication error) in the CLI's own documented contract — a dummy/invalid key would have failed authentication, not validation — so this is decisive proof the egress preset and the real key both work; only an additional account-scoping parameter (`teamId`) this spike's credential set didn't include remains unresolved. Flagged `human_judgment: true` in the coverage block for this reasoning to be reviewed.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Provisioning script's own PATH prepend shadowed the correct Node install**
- **Found during:** Task 1
- **Issue:** An early defensive `$HOME/.local/bin` PATH prepend (guessing the OpenClaw installer might need it, nvm-style) caused `command -v node` to resolve a pre-existing, unrelated Hermes-agent-bundled Node v22.23.2 symlink at `~/.local/bin/node`, instead of the correct NodeSource-installed `/usr/bin/node` v24.21.0.
- **Fix:** Removed the `~/.local/bin` prepend from the script's Node/OpenClaw check (only `~/.npm-global/bin` — where the OpenClaw installer actually places binaries — is added). Documented the live host's pre-existing Hermes state as a finding rather than silently working around it (52.90.9.242 is not the "bare host" the phase's own research probe characterized it as).
- **Files modified:** provision-2-0-host.sh
- **Verification:** Re-ran the script; `node --version` correctly reported `v24.21.0`.
- **Committed in:** 85c7b09 (Task 1 commit)

**2. [Rule 1 - Bug] Egress-preset commands used a renamed, no-longer-recognized CLI subcommand form**
- **Found during:** Task 2
- **Issue:** `nemoclaw <name> policy-add`/`policy-list` (hyphenated, per CONVENTIONS.md written against NemoClaw v0.0.55) silently failed on v0.0.128, which renamed these to space-separated subcommands (`policy add`/`policy list`). The script's own verification check used the same stale form, producing a false-negative "policy add did not result in a visible revenium policy" even after the policy had actually been applied.
- **Fix:** Updated the script to `policy add`/`policy list`.
- **Files modified:** provision-2-0-host.sh
- **Verification:** `nemoclaw revenium-2-0 policy list` shows `● revenium [user-added] — custom OpenShell policy`.
- **Committed in:** 5962241 (Task 2 commit)

**3. [Rule 1 - Bug] Stale SSHFS share mount after sandbox rebuild returned I/O errors while still appearing mounted**
- **Found during:** Task 2
- **Issue:** Upgrading NemoClaw from v0.0.124 to v0.0.128 rebuilt the underlying sandbox container, invalidating the pre-existing SSHFS session while `mount` output still listed it — a concrete instance of the SSHFS-cache-lag hazard CONVENTIONS.md already flagged abstractly.
- **Fix:** The script's mount-health check now verifies real filesystem access (`ls "$mount"`), not just presence in `mount` output, and unmounts (`fusermount3 -uz`) before remounting when stale.
- **Files modified:** provision-2-0-host.sh
- **Verification:** Re-ran the script; share mount reported "already mounted and readable."
- **Committed in:** 5962241 (Task 2 commit)

**4. [Rule 1 - Bug] In-sandbox SQLite store path recorded as the host-side mount path instead of the in-sandbox path**
- **Found during:** Task 2 (caught during Task 2's own acceptance-criteria self-check, before commit)
- **Issue:** `versions-resolved.txt` recorded the host-side share-mount path (`/home/ubuntu/nemoclaw-revenium-2-0-mount/...`) rather than the path as it exists inside the sandbox (`/sandbox/.openclaw/...`), which is what production code (Phase 19+) will actually use and what the task's acceptance criteria required ("resolved in-sandbox session-store path under `/sandbox/.openclaw/`").
- **Fix:** The script now converts the found host-mount path back to its in-sandbox equivalent before recording it, while still logging the host-mount path for operator convenience.
- **Files modified:** provision-2-0-host.sh
- **Verification:** `versions-resolved.txt` now contains `nemoclaw-sandbox: sqlite-store-path=/sandbox/.openclaw/agents/main/agent/openclaw-agent.sqlite`.
- **Committed in:** 5962241 (Task 2 commit)

---

**Total deviations:** 4 auto-fixed (all Rule 1 — bugs discovered and fixed during live execution before their respective task commits).
**Impact on plan:** All four fixes were necessary for the script's own correctness and for the acceptance criteria's literal requirements. No scope creep — each fix stayed within the task that surfaced it.

## Issues Encountered

None beyond the deviations documented above, which were resolved inline before each task's commit.

## Known Stubs

None. All four tasks produced real, verified artifacts against the live host — no placeholder data, no mocked responses.

## User Setup Required

None beyond what the plan's `user_setup` already specified (the operator-provisioned `~/.spike-17.env` credential file, verified present at mode 600 with all three required keys before Task 1 began). No new user action required.

## Next Phase Readiness

- SPIKE-00 is fully answered and VALIDATED — Phase 17's remaining plans (SPIKE-01 through SPIKE-04) can proceed against this host.
- **Carry-forward for Phase 22 (NemoClaw path):** re-run `provision-2-0-host.sh` for a fresh sandbox; the `NEMOCLAW_INSTALL_TAG=v0.0.128` default may need re-checking against whatever NemoClaw has since promoted as its new maintained-lkg release.
- **Carry-forward for Phase 19 (session read path):** the confirmed persistent read-path entry point is `openclaw agent --agent <id> --local --model ...` (not `agent exec`); the SQLite schema is genuinely unpublished (60 real table names captured via `.tables`, none matching the docs' conceptual `SessionEntry` field list) — full schema capture is SPIKE-01's job (plan 03/04), not this plan's.
- **Carry-forward for any Phase 19+ work needing a full 200 from `api.revenium.ai`:** the real key used in this spike needs an explicit `--team-id`/`REVENIUM_TEAM_ID` that `user_setup` did not provision — see README.md Finding 7.
- No blockers for Phase 17's next plans (02–06).

---
*Phase: 17-live-host-fact-finding-spike*
*Plan: 01*
*Completed: 2026-09-24*

## Self-Check: PASSED

All 7 files created (provision-2-0-host.sh, README.md, provision-run.log, versions-resolved.txt, tracer-turn-readback.txt, revenium-egress-check.txt, 17-01-SUMMARY.md) verified present on disk. All 6 commits (85c7b09, 5962241, b99244e, 665fc25, 70b1e65, 1dec3bf) verified present in git log.
