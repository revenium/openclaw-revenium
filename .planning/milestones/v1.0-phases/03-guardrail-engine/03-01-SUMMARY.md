---
phase: 03-guardrail-engine
plan: "01"
subsystem: infra
tags: [bash, openclaw, shell, common.sh]

# Dependency graph
requires: []
provides:
  - scripts/common.sh with OpenClaw path constants, multi-candidate OPENCLAW_HOME probe, and helper functions
  - Verified openclaw 2026.5.28 flag form for message send
affects: [03-02, 03-03, 03-04, 03-05]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "OPENCLAW_HOME multi-candidate probe (checks ${candidate}/agents existence)"
    - "Sourced bash library with set -uo pipefail (no -e)"

key-files:
  created:
    - scripts/common.sh
  modified: []

key-decisions:
  - "REVENIUM_AGENT_NAME defaults to OpenClaw (not Hermes)"
  - "STATE_DIR = OPENCLAW_HOME/skills/revenium (OpenClaw collapsed model vs Hermes two-path model)"
  - "openclaw message send flags confirmed: --channel, --target, -t (new short form), -m still valid in 2026.5.28"
  - "revenium config show emits Team ID: label (confirmed: value 5jdO2v on live machine)"

patterns-established:
  - "Pattern: common.sh is sourced (not executed) — shebang + set -uo pipefail without -e"
  - "Pattern: OPENCLAW_HOME discovered via multi-candidate loop checking ${candidate}/agents existence"

requirements-completed: [GUARD-01, GUARD-06]

# Metrics
duration: 5min
completed: 2026-05-31
---

# Phase 3 Plan 01: Prerequisites and shared library (common.sh) Summary

**OpenClaw upgraded to 2026.5.28 and scripts/common.sh authored with OpenClaw path model, multi-candidate HOME probe, and all D-22 helpers; no Hermes-only identifiers remain**

## Performance

- **Duration:** ~5 min
- **Started:** 2026-05-31T19:21:56Z
- **Completed:** 2026-05-31T19:26:00Z
- **Tasks:** 2/2 (checkpoint reached on Task 1; Task 2 completed)
- **Files modified:** 1

## Accomplishments
- Upgraded openclaw CLI from 2026.3.13 to 2026.5.28 via `npm update -g openclaw`
- Confirmed openclaw message send flags in 2026.5.28: --channel, --target (-t shorthand new), -m/--message all present
- Confirmed `revenium config show` emits `Team ID:` label parseable by sed (value: 5jdO2v)
- Authored `scripts/common.sh` with full OpenClaw adaptation: multi-candidate OPENCLAW_HOME probe, all D-22 path constants, ensure_path/log/info/warn/error/has_guardrails_cli helpers; zero Hermes-only identifiers

## Task Commits

Each task was committed atomically:

1. **Task 1: Upgrade OpenClaw CLI and verify flags** - checkpoint (no commit — human-verify gate)
2. **Task 2: Author scripts/common.sh** - `0ad0df5` (feat)

**Plan metadata:** `TBD` (docs: complete plan)

## Files Created/Modified
- `scripts/common.sh` - Shared path constants and helpers sourced by all guardrail scripts

## Decisions Made
- `openclaw message send` in 2026.5.28 retains `--channel`, `--target` (now also `-t`), and `-m`/`--message` — the D-10 command form is confirmed stable
- `revenium config show` output confirmed to contain `Team ID:` label — Hermes sed pattern (`sed -n 's/.*Team ID:[ \t]*//p'`) will work for guardrail-check.sh
- `REVENIUM_AGENT_NAME` defaults to `"OpenClaw"` as per D-23

## Checkpoint: Task 1 Human Verify Gate

**Status:** BLOCKING — awaiting human verification

**Automation completed:**
- `npm update -g openclaw` ran successfully
- `openclaw --version` → `OpenClaw 2026.5.28 (e932160)` ✓
- `openclaw message send --help` captured — flags confirmed
- `revenium config show` output captured — `Team ID:` label confirmed

**Observed flags in 2026.5.28:**
- `--channel <channel>` — CONFIRMED (same name as 2026.3.13)
- `-m, --message <text>` — CONFIRMED (same as 2026.3.13)
- `-t, --target <dest>` — CONFIRMED (now has `-t` shorthand, was `--target` only in 2026.3.13)

**revenium config show output:**
```
API Key:    ****548f
API URL:    https://api.revenium.ai/profitstream
Team ID:    5jdO2v
Tenant ID:  5jLgdv
Owner ID:   l3nwNv
```

`Team ID:` label is present and parseable. The Hermes pattern `sed -n 's/.*Team ID:[ \t]*//p'` will extract `5jdO2v`.

## Deviations from Plan

None — plan executed exactly as written.

## Issues Encountered
None.

## Next Phase Readiness
- Task 1 checkpoint must be approved before Wave 2 scripts can be authored
- Task 2 (common.sh) is complete and verified once human confirms Task 1 acceptance
- Wave 2 plans (03-02, 03-03, 03-04, 03-05) can source `scripts/common.sh` safely

---
*Phase: 03-guardrail-engine*
*Completed: 2026-05-31*
