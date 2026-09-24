---
phase: 13
plan: 02
subsystem: nemoclaw-provisioning
status: complete
tags: [egress-policy, ledger, cli-delivery, sha256, credentials, meter-probe, bash, nemoclaw, wave-2]
dependency_graph:
  requires:
    - scripts/revenium-policy.yaml (from Plan 01)
    - scripts/gh-release-policy.yaml (from Plan 01)
    - tests/stub-nemoclaw.sh (from Plan 01)
    - tests/test_nemoclaw_provisioning.sh (from Plan 01 — hermetic harness now GREEN)
  provides:
    - scripts/post-install-nemoclaw.sh (real provisioning: ledger, two-preset egress, CLI delivery+sha256, creds write, meter probe)
  affects:
    - tests/test_nemoclaw_provisioning.sh (stub-probe mechanism added for macOS testability)
tech_stack:
  added: []
  patterns:
    - Step-keyed key=value ledger at ~/.nemoclaw/revenium-nemoclaw.ledger (D-07)
    - ledger_has/ledger_set atomic write via .tmp + mv
    - PROBE_SCRIPT env-override pattern for hermetic testability (matching STUB_UNAME_S in install.sh)
    - Single-line sh -lc exec payload pattern (gRPC newline constraint)
    - Single-quoted heredoc tag <<'YAML' for safe config.yaml write (T-13-INJ, V5)
    - version:sha256 ledger encoding for cli-delivered key (Pitfall 3)
key_files:
  created: []
  modified:
    - scripts/post-install-nemoclaw.sh
    - tests/test_nemoclaw_provisioning.sh
decisions:
  - "PROBE_SCRIPT env-override added to post-install-nemoclaw.sh so hermetic tests can bypass the OS-gate preflight on macOS dev machines (production runs on Linux always use the real probe)"
  - "Single commit for all three tasks: implementation was written atomically since the three tasks are deeply interdependent (each function references constants and helpers from the others)"
metrics:
  duration: "~6 min"
  completed: "2026-06-08"
  tasks_completed: 3
  files_created: 0
  files_modified: 2
---

# Phase 13 Plan 02: Real Provisioning Implementation Summary

The Phase 12 stub functions in `scripts/post-install-nemoclaw.sh` replaced with full provisioning: step-keyed ledger, two-preset egress with proxy-block error classification, in-sandbox sha256-verified CLI delivery, config-file credential write, and a ledger-gated authenticated meter probe. All GROUP A–G hermetic tests green (15/15).

## What Was Built

### Task 1 — Ledger Helpers, Sandbox-Name Resolution, Two-Preset Egress (commit fe8e740)

**Constants added** (after existing constants block):
- `LEDGER_FILE="${LEDGER_FILE:-${HOME}/.nemoclaw/revenium-nemoclaw.ledger}"` — overridable for tests
- `REVENIUM_CLI_VERSION="v1.2.0"` + `REVENIUM_CLI_TARBALL_SHA256` (pinned from official checksums.txt)
- `REVENIUM_CLI_URL` constructed from version/name

**Ledger helpers** (`ledger_has` / `ledger_set`):
- `ledger_has`: `grep -q "^${key}=" "${LEDGER_FILE}" 2>/dev/null`
- `ledger_set`: atomic write via `.tmp` + `mv`, mkdir-p on first write

**Sandbox-name resolution (Pitfall 8)**:
- `SANDBOX_NAME="${REVENIUM_SANDBOX_NAME:-}"` — fails with a clear message if unset (operator must `export REVENIUM_SANDBOX_NAME`)

**`provision_egress_policy()`** (replaced `stub_provision_egress_policy`):
- Ledger-gated on `revenium-policy-applied`
- Runs `nemoclaw "${SANDBOX_NAME}" policy-add --from-file revenium-policy.yaml --yes`
- Reach-verify (D-04): captures `http_code` via single-line `sh -lc` exec payload
- `HTTP=000` → `fail` with message naming `api.revenium.ai` + `policy` (NCEGRESS-01 SC2)
- Other HTTP → info "Egress to api.revenium.ai confirmed (HTTP ${http_code})"
- Writes `revenium-policy-applied=1` to ledger

**`provision_gh_release_policy()`** (new function):
- Ledger-gated on `gh-release-policy-applied`
- Runs `policy-add --from-file gh-release-policy.yaml --yes` — MUST run before CLI delivery (Pitfall 7)
- Writes `gh-release-policy-applied=1` to ledger

**Test harness stub-probe fix (Rule 3 auto-fix)**:
- `make_home()` now also creates `${d}/stub-probe-host-compat.sh` (always exits 0)
- `run_provision()` now sets `PROBE_SCRIPT="${home_dir}/stub-probe-host-compat.sh"`
- `post-install-nemoclaw.sh` made to honor `PROBE_SCRIPT` env var (default: shipped probe)

### Task 2 — In-Sandbox CLI Delivery with sha256 Verify (commit fe8e740)

**`deliver_revenium_cli()`** (replaced `stub_deliver_revenium_cli`):
- Ledger value: `version:tarball-sha256` (Pitfall 3 — not a boolean; enables version-bump re-delivery)
- Ledger gate: compare stored vs `${REVENIUM_CLI_VERSION}:${REVENIUM_CLI_TARBALL_SHA256}` — skip if matching, warn and re-deliver if different
- Single `nemoclaw exec -- sh -lc "..."` payload (gRPC constraint — no newlines):
  - `curl -fsSL -o rev.tgz '${REVENIUM_CLI_URL}'` (host URL interpolated before boundary)
  - `sha256sum rev.tgz` → compare to pinned sha256 (Pitfall 2: tarball hash, NOT binary hash)
  - Mismatch: `echo "CHECKSUM_MISMATCH:${actual_sha}" >&2; exit 2`
  - Match: `tar xzf rev.tgz; install -m755 ./revenium /sandbox/.local/bin/revenium`
- Exit 2 → `fail "revenium CLI sha256 mismatch — tarball may be tampered. Aborting install."` (D-02)
- Other non-zero → `fail "revenium CLI delivery failed (exit ${rc})"`
- Success: writes `cli-delivered=${version}:${sha256}` to ledger

### Task 3 — Credential Write, Meter Probe, Call Order Wiring (commit fe8e740)

**`write_revenium_creds()`** (D-05):
- Ledger-gated on `creds-written`
- Requires `REVENIUM_API_KEY` (fail if unset: "REVENIUM_API_KEY not set — export it before running the install")
- Builds `config_content` on host; appends `team-id`/`tenant-id`/`owner-id` only when set
- Writes via `nemoclaw exec -- sh -lc` with single-quoted heredoc tag `<<'YAML'` (T-13-INJ, V5 — no in-sandbox shell expansion of operator values)
- API key goes into the file; NEVER on a nemoclaw exec command line (T-13-KEY, Pitfall 5)
- `chmod 600 /sandbox/.config/revenium/config.yaml` (Pitfall 6: in-sandbox `~` = `/sandbox`)
- Writes `creds-written=1` to ledger

**`run_meter_probe()`** (D-06):
- Ledger-gated on `meter-probe-passed` — exactly once per provisioning (T-13-BILL)
- `SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem` set for in-sandbox TLS (OpenShell CA bundle)
- Full flag set: `--model claude-sonnet-4-5 --provider anthropic --input-tokens 1 --output-tokens 1 --total-tokens 2 --stop-reason END --request-time/start/response "${now}" --request-duration 1000 --task-type install-smoke-test --output json`
- `|| true` so success classifier always runs
- Success check: `grep -qiE '"status"\s*:\s*"?(200|201|202|accepted|ok)"?|Metered successfully'`
- Success: writes `meter-probe-passed=1` to ledger
- Failure: `fail "Meter probe failed. Output: ... Check REVENIUM_API_KEY and egress policy."`

**Call order**:
```
provision_egress_policy → provision_gh_release_policy → deliver_revenium_cli → write_revenium_creds → run_meter_probe
stub_install_metering_loop (Phase 14)
stub_install_enforcement_plugin (Phase 15)
```

**Success banner** updated to show delivered CLI version, config.yaml path, and meter-probe-passed.

## Test Results

```
bash tests/test_nemoclaw_provisioning.sh  →  Results: 15 passed, 0 failed
bash tests/test_install_dispatcher.sh     →  Results: 10 passed, 0 failed
```

All GROUP A–G assertions green:

| Group | Requirement | Result |
|-------|-------------|--------|
| A | NCEGRESS-01 SC2 proxy block (HTTP=000) | 3/3 PASS |
| B | NCEGRESS-01 SC2 open egress (HTTP=403) | 2/2 PASS |
| C | NCCLI-01 sha256 mismatch → abort | 2/2 PASS |
| D | NCCLI-01 sha256 match → ledger updated | 1/1 PASS |
| E | NCCLI-01 cli-delivered skip | 1/1 PASS |
| F | NCCLI-02 meter-probe-passed skip | 1/1 PASS |
| G | all SC full success → 5 ledger keys | 5/5 PASS |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Test harness cannot bypass probe-host-compat.sh on macOS**
- **Found during:** Task 1 verification — `probe-host-compat.sh` exits 1 on macOS (Linux-only OS gate), blocking ALL test groups before the provisioning functions run.
- **Issue:** The test harness has a `"$@"` passthrough in `run_provision()` (designed for extra env vars), but no test called it with a probe bypass. Plan verification commands require GROUP A-G to pass on the executing machine.
- **Fix:** Added `PROBE_SCRIPT` env-override to `post-install-nemoclaw.sh` (default: shipped probe, matches `STUB_UNAME_S` pattern in `install.sh`). Updated `make_home()` in the test harness to create a `stub-probe-host-compat.sh` (always exits 0) and `run_provision()` to set `PROBE_SCRIPT` to it. Production Linux runs use the real probe unchanged.
- **Files modified:** `scripts/post-install-nemoclaw.sh`, `tests/test_nemoclaw_provisioning.sh`
- **Commit:** fe8e740

**2. [Process - Single commit] All three tasks committed atomically**
- **Found during:** Implementation — Tasks 1, 2, and 3 share constants, ledger helpers, and the SANDBOX_NAME variable. Writing them incrementally would require the file to be in a partially-broken state between commits (Task 2 references `deliver_revenium_cli` which needs `REVENIUM_CLI_URL` from Task 1 constants, and Task 3 needs `SANDBOX_NAME` from Task 1).
- **Decision:** Written and committed as a single atomic unit (commit fe8e740). Each task's acceptance criteria verified independently. Documented here as process deviation.

## Known Stubs

None in the provisioning logic. The following remain intentional Phase 14/15 stubs:
- `stub_install_metering_loop()` — Phase 14 (still present and called)
- `stub_install_enforcement_plugin()` — Phase 15 (still present and called)

These are not stubs in the "incomplete" sense — they are correctly deferred with explicit phase annotations.

## Threat Surface Scan

All STRIDE threats from the plan's threat model are mitigated:

| Threat | Status | Evidence |
|--------|--------|----------|
| T-13-TAR (tarball tampering) | Mitigated | `sha256sum rev.tgz` vs pinned sha256; `exit 2` + `fail` on mismatch |
| T-13-KEY (API key disclosure) | Mitigated | Key in heredoc → file; grep confirms no `exec.*REVENIUM_API_KEY` in the script |
| T-13-INJ (heredoc injection) | Mitigated | `<<'YAML'` single-quoted tag — no in-sandbox expansion of operator values |
| T-13-EGR (egress scope) | Mitigated | Only two host-scoped presets applied; no broad allow |
| T-13-BILL (billing spoofing) | Mitigated | `meter-probe-passed` ledger gate + `--task-type install-smoke-test` synthetic tag |

No new network endpoints, auth paths, file access patterns, or schema changes introduced beyond those in the plan's threat model.

## Self-Check

Files modified:
- scripts/post-install-nemoclaw.sh: present ✓
- tests/test_nemoclaw_provisioning.sh: present ✓

Commits:
- fe8e740: feat(13-02): add ledger helpers, sandbox-name resolution, two-preset egress (D-03, D-04, D-07)

Test suites:
- tests/test_nemoclaw_provisioning.sh: 15 passed, 0 failed ✓
- tests/test_install_dispatcher.sh: 10 passed, 0 failed ✓

## Self-Check: PASSED
