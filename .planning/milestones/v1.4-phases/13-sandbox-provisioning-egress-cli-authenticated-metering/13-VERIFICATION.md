---
phase: 13-sandbox-provisioning-egress-cli-authenticated-metering
verified: 2026-06-08T00:00:00Z
status: passed
score: 7/7
overrides_applied: 0
---

# Phase 13: Sandbox Provisioning — Egress, CLI & Authenticated Metering — Verification Report

**Phase Goal:** The sandbox has egress to `api.revenium.ai`, the revenium binary is installed inside it, and an authenticated `revenium meter` call succeeds from inside the sandbox — closing the spike 003 pending authenticated-meter step.
**Verified:** 2026-06-08T00:00:00Z
**Status:** passed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths (from ROADMAP.md Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| SC1 | The install path applies the `revenium` network-policy preset via `nemoclaw policy-add` and the sandbox can reach `api.revenium.ai` over HTTPS | VERIFIED | `provision_egress_policy()` in `post-install-nemoclaw.sh` runs `nemoclaw policy-add --from-file revenium-policy.yaml --yes` and reach-verifies with an in-sandbox `curl` probe. GROUP-B passes (HTTP=403 → egress confirmed). |
| SC2 | If the policy preset is missing or blocked, the install surfaces a clear error identifying the policy gap | VERIFIED | `provision_egress_policy()` checks exec exit code, empty output, and `000` http_code — any of the three triggers `fail "sandbox cannot reach api.revenium.ai — policy gap detected"`. GROUP-A passes: `STUB_NEMOCLAW_CURL_HTTP_CODE=000` → output contains both `api.revenium.ai` and `policy`, run exits non-zero. CR-01 (review) fixed the double-`000` regression; stub WR-01 companion fix makes the test genuine. |
| SC3 | The `revenium` binary is present inside the sandbox at `/sandbox/.local/bin/revenium` (prebuilt tarball, not brew) with `SSL_CERT_FILE` and `REVENIUM_*` wired | VERIFIED | `deliver_revenium_cli()` fetches the `v1.2.0` tarball, sha256-verifies it against the pinned value, and runs `install -m755 ./revenium /sandbox/.local/bin/revenium`. `write_revenium_creds()` writes config via base64-decoded heredoc to `/sandbox/.config/revenium/config.yaml` (field `api-key:`, never on exec command line). `run_meter_probe()` sets `SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem`. GROUP-D, GROUP-H pass. |
| SC4 | An authenticated `revenium meter completion` call from inside the sandbox returns HTTP 2xx against the real Revenium API (closes NCCLI-02 and spike 003's partial verdict) | VERIFIED | Live smoke executed on host 34.224.27.67 / sandbox `revenium-spike` (Plan 03, Task 1 blocking-human checkpoint, operator-approved). Authenticated call returned HTTP 2xx — created `metered-event` resource `id 36597852-c046-4ef2-b79e-4c52ac1c1627` with `signature`. Re-run emitted no second event (exactly-once, D-06). Spike 003 README verdict flipped to `VALIDATED`. |

**Score:** 4/4 roadmap success criteria verified.

### Must-Have Truths (from PLAN frontmatter, merged)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | `scripts/revenium-policy.yaml` exists as a host-scoped `api.revenium.ai` egress preset (13-01) | VERIFIED | File present; contains `api.revenium.ai`, `port: 443`, `tls: skip`, `access: full`. No hosts beyond `api.revenium.ai`. |
| 2 | `scripts/gh-release-policy.yaml` exists covering `release-assets.githubusercontent.com` AND `objects.githubusercontent.com` (13-01) | VERIFIED | File present; contains both CDN hosts, each with `port: 443`, `tls: skip`, `access: full`. |
| 3 | `tests/stub-nemoclaw.sh` captures argv without eval and is switchable via `STUB_NEMOCLAW_*` env vars (13-01) | VERIFIED | Argv captured with `printf '%s\n'`. No `eval` present. All three switches (`CURL_HTTP_CODE`, `SHA256_MATCH`, `METER_FAIL`) implemented and tested. Also rejects newline/CR in argv (live-smoke regression guard). |
| 4 | `tests/test_nemoclaw_provisioning.sh` runs and reports PASS/FAIL counts for GROUP A–G (13-01, now A–H) | VERIFIED | Harness runs; reports `18 passed, 0 failed`. GROUP A–H all green. |
| 5 | Install applies both egress presets via `nemoclaw policy-add` before fetching the CLI (13-02) | VERIFIED | Call order in `post-install-nemoclaw.sh` lines 342-344: `provision_egress_policy` → `provision_gh_release_policy` → `deliver_revenium_cli`. Both presets applied before tarball fetch. |
| 6 | A blocked sandbox (HTTP=000) is surfaced as a policy gap naming `api.revenium.ai`, not a generic network error (13-02) | VERIFIED | `fail "sandbox cannot reach api.revenium.ai — policy gap detected. Apply the revenium egress preset: nemoclaw ${SANDBOX_NAME} policy-list"`. GROUP-A exercises this path end-to-end. |
| 7 | Spike 003 is flipped from PARTIAL to VALIDATED with the live-2xx evidence recorded (13-03) | VERIFIED | `sources/003-revenium-cli-in-sandbox/README.md` frontmatter: `verdict: VALIDATED`. `SKILL.md` spike-verdicts row 003: `VALIDATED`. Closure note present with date, host, sandbox, metered-event id. |

**Score:** 7/7 must-have truths verified.

---

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `scripts/revenium-policy.yaml` | api.revenium.ai:443 egress preset | VERIFIED | 28 lines. Contains `api.revenium.ai`, `tls: skip`, `access: full`. Host-scoped only. |
| `scripts/gh-release-policy.yaml` | GitHub CDN egress preset (two hosts) | VERIFIED | 31 lines. Both `release-assets.githubusercontent.com` and `objects.githubusercontent.com` present. |
| `tests/stub-nemoclaw.sh` | argv-capturing stub, 40+ lines | VERIFIED | 155 lines. No `eval`. Three `STUB_NEMOCLAW_*` switches + newline/CR rejection guard (live-smoke finding). |
| `tests/test_nemoclaw_provisioning.sh` | GROUP A–G hermetic harness, 60+ lines | VERIFIED | 388 lines. GROUP A–H implemented (GROUP H added post live-smoke for `api-key:` field regression). |
| `scripts/post-install-nemoclaw.sh` | Real provisioning: ledger, egress, CLI delivery, creds, meter probe | VERIFIED | 379 lines. All five functions implemented with ledger gates. No stubs in Phase 13 logic. |
| `.claude/skills/spike-findings-openclaw-revenium/sources/003-revenium-cli-in-sandbox/README.md` | VALIDATED verdict + closure note | VERIFIED | Frontmatter `verdict: VALIDATED`. Closure note with `id 36597852-...`, date 2026-06-08, live host/sandbox. |
| `.claude/skills/spike-findings-openclaw-revenium/SKILL.md` | Spike-verdicts row 003 → VALIDATED | VERIFIED | Row `| 003 | revenium-cli-in-sandbox | VALIDATED |`. |

---

## Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `post-install-nemoclaw.sh` | `scripts/revenium-policy.yaml` | `policy-add --from-file` | WIRED | `nemoclaw "${SANDBOX_NAME}" policy-add --from-file "${preset_src}" --yes` (line 128); `preset_src="${SCRIPT_DIR}/revenium-policy.yaml"`. |
| `post-install-nemoclaw.sh` | `~/.nemoclaw/revenium-nemoclaw.ledger` | `ledger_has` / `ledger_set` | WIRED | 14 occurrences of `ledger_has`/`ledger_set`; `LEDGER_FILE` variable (not hardcoded) honored across all functions. |
| `post-install-nemoclaw.sh` | `/sandbox/.local/bin/revenium` | `install -m755` | WIRED | `install -m755 ./revenium /sandbox/.local/bin/revenium` in `deliver_revenium_cli()` exec payload. |
| `post-install-nemoclaw.sh` | `revenium meter completion` | ledger-gated `SSL_CERT_FILE` meter probe | WIRED | `run_meter_probe()` at line 280: full flag set with `SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem`, `--task-type install-smoke-test`, ledger gate on `meter-probe-passed`. |
| `tests/test_nemoclaw_provisioning.sh` | `tests/stub-nemoclaw.sh` | `ln -sf` onto tmp PATH | WIRED | `ln -sf "${SCRIPT_DIR}/stub-nemoclaw.sh" "${d}/.local/bin/nemoclaw"` in `make_home()` (line 90). |
| `tests/test_nemoclaw_provisioning.sh` | `scripts/post-install-nemoclaw.sh` | `LEDGER_FILE + HOME override` | WIRED | `run_provision()` sets `LEDGER_FILE`, `HOME`, `REVENIUM_SANDBOX_NAME`, `REVENIUM_API_KEY`, `PROBE_SCRIPT`, then `bash "${PROVISION_SH}"`. |

---

## Data-Flow Trace (Level 4)

Not applicable — this is a bash provisioning script, not a component rendering dynamic data. All outputs are side-effects (ledger writes, in-sandbox file writes). The hermetic test suite validates the data flows end-to-end.

---

## Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Hermetic suite GROUP A–H all pass | `bash tests/test_nemoclaw_provisioning.sh` | `18 passed, 0 failed`, exit 0 | PASS |
| Install dispatcher regression | `bash tests/test_install_dispatcher.sh` | `10 passed, 0 failed`, exit 0 | PASS |
| post-install-nemoclaw.sh syntax valid | `bash -n scripts/post-install-nemoclaw.sh` | exit 0 | PASS |
| stub-nemoclaw.sh syntax valid | `bash -n tests/stub-nemoclaw.sh` | exit 0 | PASS |
| test_nemoclaw_provisioning.sh syntax valid | `bash -n tests/test_nemoclaw_provisioning.sh` | exit 0 | PASS |

---

## Probe Execution

No conventional `scripts/*/tests/probe-*.sh` probes are defined for Phase 13. The phase uses `tests/test_nemoclaw_provisioning.sh` as its hermetic harness (run above, 18/18). The live smoke (Plan 03, Task 1) was a blocking-human checkpoint executed by the operator on host 34.224.27.67 and is not re-executable by this verifier (requires a real API key + live NemoClaw host). The live evidence is recorded in `13-03-SUMMARY.md` and the spike 003 README closure note.

---

## Requirements Coverage

| Requirement | Source Plan(s) | Description | Status | Evidence |
|-------------|---------------|-------------|--------|----------|
| NCEGRESS-01 | 13-01, 13-02 | Install path ships and applies a host-scoped `revenium` network-policy preset; missing/blocking policy surfaced as policy gap (not generic network error) | SATISFIED | `scripts/revenium-policy.yaml` ships as a first-class asset; `provision_egress_policy()` applies it and classifies HTTP=000 / exec non-zero as a policy gap naming `api.revenium.ai`. GROUP-A/B hermetically verified. |
| NCCLI-01 | 13-01, 13-02 | `revenium` CLI delivered into sandbox (prebuilt binary, not brew); authenticates via `REVENIUM_*` + `SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem` | SATISFIED | `deliver_revenium_cli()` fetches `v1.2.0` tarball, sha256-verifies (`cc4b07e9…`), installs to `/sandbox/.local/bin/revenium`. `write_revenium_creds()` writes `api-key:` config via base64 (never on exec command line). `SSL_CERT_FILE` set in meter probe. GROUP-C/D/E/H pass. |
| NCCLI-02 | 13-01, 13-02, 13-03 | Authenticated meter call succeeds against Revenium from the NemoClaw deployment (closes spike 003 partial verdict) | SATISFIED | Live smoke on 34.224.27.67: authenticated `revenium meter completion` returned HTTP 2xx (`id 36597852-c046-4ef2-b79e-4c52ac1c1627`, `resourceType: metered-event`). Spike 003 VALIDATED. GROUP-F/G/H hermetically verify the ledger-gate and success-classifier. |

All three requirements declared in PLAN frontmatter are satisfied. No orphaned requirements for Phase 13 found in REQUIREMENTS.md.

---

## Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `tests/test_nemoclaw_provisioning.sh` | 161, 198, 221, 252, 279, 333 | `"not yet implemented"` strings | Info | These strings appear inside `fail()` diagnostic messages — the text shown when a test fails. They are stale Wave-0 comments written before Plan 02. All tests pass; these code paths are unreachable. Not a stub or debt marker. |
| `tests/test_nemoclaw_provisioning.sh` | 380 | `"expected RED state"` NOTE comment | Info | Stale NOTE at the bottom of the test file (written in Wave-0). Tests are now green. Not a functional concern. |

No `TBD`, `FIXME`, or `XXX` markers found in any phase-modified file. No `eval` of captured argv. No REVENIUM_API_KEY on exec command lines (`grep -n 'exec.*REVENIUM_API_KEY'` → 0 results). No hardcoded `revenium-spike` in runtime paths (2 occurrences are a comment and an error-message example). Phase 14/15 deferral stubs (`stub_install_metering_loop`, `stub_install_enforcement_plugin`) are present and called as intended.

---

## Code Review Status

The 13-REVIEW.md (status: `resolved`) identified:
- **CR-01** (proxy-block double-000 false-negative): Fixed — separate `exec_rc` capture; stub now exits non-zero on `000` (WR-01 companion fix). GROUP-A genuinely exercises the exit-code path.
- **WR-01** (stub false-green): Fixed — stub exits 1 when `CURL_HTTP_CODE=000`.
- **WR-02** (unvalidated YAML scalars): Fixed — `yaml_dquote()` helper wraps all credential values in double-quoted YAML scalars with `\` and `"` escaped.
- **WR-03** (misleading idempotent banner): Fixed — `WORK_DONE` flag distinguishes fresh provision from all-skipped re-run.
- **IN-01** (unanchored ledger asserts): Fixed — GROUP-G uses `grep -qE "^${key}="` anchor; additional `cli-delivered` value check added.
- **IN-02** (stub tmpfile trap): Accepted as test-only, low severity.

---

## Human Verification Required

None. All automated checks pass. The authenticated-meter live smoke was a blocking-human checkpoint (Plan 03, Task 1) that was executed and operator-approved during phase execution. The evidence is permanently recorded in `13-03-SUMMARY.md` and the spike 003 README closure note (`id 36597852-c046-4ef2-b79e-4c52ac1c1627`). No further human testing is outstanding.

---

## Gaps Summary

No gaps. All phase-13 success criteria are verified:

1. Egress policy shipped, applied, and tested hermetically (NCEGRESS-01).
2. Policy-gap detection works for both proxy-blocked and open-egress paths (NCEGRESS-01 SC2).
3. CLI delivered into sandbox via sha256-pinned tarball; credentials written to `config.yaml` at `api-key:` field; `SSL_CERT_FILE` wired (NCCLI-01).
4. Authenticated `revenium meter completion` returned HTTP 2xx on live host; exactly-once guaranteed; spike 003 VALIDATED (NCCLI-02).
5. Hermetic suite 18/18, dispatcher 10/10, all syntax valid.

---

## Post-ship hardening (v1.4.1 — 2026-06-11)

This phase verified passed on 2026-06-08, but a **live UAT pass on a clean host (2026-06-11)** found the install path broken end-to-end and surfaced Phase-13 provisioning gaps that the hermetic suite couldn't model. Fixed on `origin/main` (HEAD `fa7deeb`):

- **Per-sandbox-UUID provisioning ledger** (`dd20f81`) — the host-global ledger skipped a 2nd/recreated sandbox wholesale. The ledger is now scoped per-sandbox **instance UUID** (`nemoclaw <name> status` Id → `revenium-nemoclaw-<uuid>.ledger`).
- **Install-time budget guardrail provisioning** (`9382597`) — NemoClaw never created budget rules (the agent-guided flow doesn't run in-sandbox). Added `provision_budget_guardrails()`, **env-gated** on `REVENIUM_BUDGET_LIMIT` + `REVENIUM_BUDGET_PERIOD`, running `setup-guardrails.sh` on the host with `OPENCLAW_HOME=<mount>` so rule IDs land in the in-sandbox `config.json`.
- **Consolidated `ensure_mount` SSHFS handling** (`1a9e93e`, `c07cd83`, `040c488`) — one bulletproof helper that self-heals a stale mount but does **not** tear down a healthy/populated mount on cache lag; health check made testable.

Live-validated on Nemotron: egress policy, CLI delivery (sandbox + host), credential write, **budget-RULE creation in Revenium**, and metering all confirmed. The authenticated-meter result (the original SC4) remains valid.

---

_Verified: 2026-06-08T00:00:00Z_
_Verifier: Claude (gsd-verifier)_
_Post-ship hardening addendum: 2026-06-11 (v1.4.1)_
