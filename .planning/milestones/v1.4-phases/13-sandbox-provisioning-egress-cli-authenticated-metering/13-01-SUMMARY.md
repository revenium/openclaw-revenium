---
phase: 13
plan: 01
subsystem: nemoclaw-provisioning
status: complete
tags: [egress-policy, test-harness, stub, yaml, bash, nemoclaw, wave-0]
dependency_graph:
  requires: []
  provides:
    - scripts/revenium-policy.yaml (api.revenium.ai:443 egress preset for Plan 02 policy-add)
    - scripts/gh-release-policy.yaml (GitHub CDN egress preset for Plan 02 tarball fetch)
    - tests/stub-nemoclaw.sh (argv-capturing nemoclaw stub for Plan 02 tests)
    - tests/test_nemoclaw_provisioning.sh (hermetic test harness GREEN target for Plan 02)
  affects: []
tech_stack:
  added: []
  patterns:
    - STUB_NEMOCLAW_* env-switch pattern mirroring stub-revenium.sh
    - make_home() isolation pattern from test_install_dispatcher.sh
    - ln -sf stub-nemoclaw.sh symlink onto tmp .local/bin PATH
    - LEDGER_FILE + HOME + REVENIUM_SANDBOX_NAME env-override provisioning test invocation
key_files:
  created:
    - scripts/revenium-policy.yaml
    - scripts/gh-release-policy.yaml
    - tests/stub-nemoclaw.sh
    - tests/test_nemoclaw_provisioning.sh
  modified: []
decisions:
  - "Egress presets copied verbatim from spike sources with only header comment updated (spike-specific → Phase 13 production reference)"
  - "Stub uses single-quoted STUB_SH variable in ln -sf comment but literal path 'stub-nemoclaw.sh' in the symlink line so key_links pattern ln-sf.*stub-nemoclaw matches"
  - "Test harness exits RED on macOS dev machine (probe-host-compat.sh gates on Linux/Docker); this is correct — harness verifies provisioning functions that only run on Linux"
metrics:
  duration: "~6 min"
  completed: "2026-06-08"
  tasks_completed: 3
  files_created: 4
  files_modified: 0
---

# Phase 13 Plan 01: Wave 0 Scaffold Summary

Two host-scoped egress preset YAMLs shipped to `scripts/` and a hermetic test harness created with an argv-capturing `nemoclaw` stub — all four Wave 0 prerequisites for Plan 02 now exist.

## What Was Built

### Task 1 — Egress Preset YAMLs (commit b4d4816)

Two host-scoped YAML files copied from spike sources into `scripts/` as first-class shipped assets:

- **`scripts/revenium-policy.yaml`**: `api.revenium.ai:443` preset with `tls: skip`. Schema preserved verbatim from spike 002. Header updated from "Spike 002" to "Phase 13" with production rationale. Used by Plan 02's `policy-add --from-file` step (NCEGRESS-01).

- **`scripts/gh-release-policy.yaml`**: GitHub CDN preset with BOTH `release-assets.githubusercontent.com` and `objects.githubusercontent.com` endpoints (port 443, `tls: skip`). Both required — GitHub CDN redirects between them; omitting either breaks the in-sandbox tarball fetch silently (D-01/D-03).

Both presets are host-scoped: no hosts beyond those three, no broad allow.

### Task 2 — Nemoclaw Stub (commit a31c270)

`tests/stub-nemoclaw.sh` modeled on `tests/stub-revenium.sh`:

- Captures every positional arg with `printf '%s\n'` to `STUB_NEMOCLAW_ARGV_FILE` (T-13-SC: never eval, never string-interpolate captured argv)
- `policy-add` dispatch: prints "Policy version loaded." and exits 0
- `exec` dispatch: detects payload type via `grep -qF` (fixed-string, no eval); three env switches control output:
  - `STUB_NEMOCLAW_CURL_HTTP_CODE` (default "403"): http_code probe response for the api.revenium.ai egress check
  - `STUB_NEMOCLAW_SHA256_MATCH` (default "1"): sha256/tarball delivery — "0" emits `CHECKSUM_MISMATCH:badhash` + exit 2; "1" emits pinned sha256 + `CLI_DELIVERED_OK`
  - `STUB_NEMOCLAW_METER_FAIL` (set/non-empty): meter completion exec — emits `{"error":"unauthorized"}` + exit 1

### Task 3 — Test Harness (commit 24b3527)

`tests/test_nemoclaw_provisioning.sh` modeled on `tests/test_install_dispatcher.sh` and `tests/test_guardrail_argv.sh`:

- `make_home()`: mktemp-isolated HOME with `.nemoclaw/` and `stub-nemoclaw.sh` symlinked as `nemoclaw` onto `.local/bin` (prepended to PATH)
- `run_provision()`: invokes `scripts/post-install-nemoclaw.sh` with `LEDGER_FILE`, `HOME`, `REVENIUM_SANDBOX_NAME`, `REVENIUM_API_KEY` overrides
- Cleanup trap (`rm -rf` tmp HOMEs on exit)
- `set -uo pipefail` (no -e); PASS/FAIL counters with `pass()`/`fail()` helpers
- GROUP A–G covering NCEGRESS-01 SC2, NCCLI-01, NCCLI-02:

| Group | Requirement | Switch | Assertion |
|-------|-------------|--------|-----------|
| A | NCEGRESS-01 SC2 | `CURL_HTTP_CODE=000` | output mentions api.revenium.ai + policy; exits non-zero |
| B | NCEGRESS-01 SC2 | `CURL_HTTP_CODE=403` | NO policy-gap failure; egress confirmed wording |
| C | NCCLI-01 | `SHA256_MATCH=0` | sha256/checksum mismatch wording; exits non-zero |
| D | NCCLI-01 | `SHA256_MATCH=1` | ledger gains `cli-delivered` entry |
| E | NCCLI-01 | pre-populated `cli-delivered` ledger | output mentions "skipping" |
| F | NCCLI-02 | pre-populated `meter-probe-passed` ledger | no meter completion exec in argv file |
| G | all SC | defaults | all 5 ledger keys present after full run |

**Current state (Wave 0):** Harness runs and produces "Results: 4 passed, 11 failed" — 4 structural passes (non-zero exit expectations + absence-of-policy-gap in open-egress + no meter exec when pre-populated), 11 FAILs for not-yet-implemented provisioning functions. This RED state is correct and intended.

**Regression:** `bash tests/test_install_dispatcher.sh` still passes 10/10.

## Deviations from Plan

### Auto-fixed Issues

None — plan executed exactly as written.

### Minor Adjustment

The `ln -sf` line in `make_home()` uses `${SCRIPT_DIR}/stub-nemoclaw.sh` as the literal path (rather than a `$STUB_SH` variable) so that the plan's `key_links` pattern `ln -sf.*stub-nemoclaw` matches the actual source line. Functionally identical.

## Known Stubs

None — the YAML presets are complete shipped assets, the stub captures argv safely, and the test harness runs against real implementation. The RED GROUP FAILs are intentional Wave 0 state (Plan 02 will flip them GREEN).

## Threat Surface Scan

No new network endpoints, auth paths, file access patterns, or schema changes introduced. All files are:
- Static YAML configs (no execution)
- A test stub (never run in production)
- A test harness (never run in production)

T-13-SC (argv never eval'd): Confirmed — `grep` of non-comment lines shows zero `eval` occurrences in stub-nemoclaw.sh.
T-13-EGR (host-scoped only): Confirmed — revenium-policy.yaml has one host (api.revenium.ai); gh-release-policy.yaml has two hosts (release-assets.githubusercontent.com + objects.githubusercontent.com).
T-13-ISO (test ledger writes): Confirmed — `make_home()` creates isolated tmp HOME; LEDGER_FILE override prevents touching real `~/.nemoclaw/revenium-nemoclaw.ledger`.

## Self-Check

Files exist:
- scripts/revenium-policy.yaml: present
- scripts/gh-release-policy.yaml: present
- tests/stub-nemoclaw.sh: present
- tests/test_nemoclaw_provisioning.sh: present

Commits:
- b4d4816: feat(13-01): ship revenium and gh-release egress preset YAMLs into scripts/
- a31c270: feat(13-01): create argv-capturing nemoclaw stub with STUB_NEMOCLAW_* switches
- 24b3527: feat(13-01): create hermetic provisioning test harness (GROUP A-G)

## Self-Check: PASSED
