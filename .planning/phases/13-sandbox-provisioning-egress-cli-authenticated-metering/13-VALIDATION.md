---
phase: 13
slug: sandbox-provisioning-egress-cli-authenticated-metering
status: approved
nyquist_compliant: true
wave_0_complete: false
created: 2026-06-08
---

# Phase 13 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash (matches existing `tests/` conventions; `set -uo pipefail`, no `-e`) + a confirmatory live smoke on host 34.224.27.67 |
| **Config file** | none — standalone bash scripts (Wave 1 / Plan 01 creates the harness) |
| **Quick run command** | `bash tests/test_nemoclaw_provisioning.sh` |
| **Full suite command** | `bash tests/test_install_dispatcher.sh && bash tests/test_nemoclaw_provisioning.sh` |
| **Estimated runtime** | ~10–20 seconds (hermetic; no network, no real `nemoclaw`) |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test_nemoclaw_provisioning.sh`
- **After every plan wave:** Run `bash tests/test_install_dispatcher.sh && bash tests/test_nemoclaw_provisioning.sh`
- **Before `/gsd-verify-work`:** Full hermetic suite green + live smoke on 34.224.27.67 passing
- **Max feedback latency:** ~20 seconds (hermetic suite)

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 13-01-01 | 01 | 1 | NCEGRESS-01 | T-13-EGR | Both shipped presets are host-scoped (single-host endpoints, `tls: skip`); no broad allow | unit | `bash tests/test_nemoclaw_provisioning.sh` (preset-content assertions) | ❌ W0 | ⬜ pending |
| 13-01-02 | 01 | 1 | NCEGRESS-01, NCCLI-01, NCCLI-02 | T-13-SC | Stub never `eval`s captured argv; argv captured with `printf '%s\n'` | unit | `bash tests/test_nemoclaw_provisioning.sh` (harness self-check / GROUP skeleton) | ❌ W0 | ⬜ pending |
| 13-02-01 | 02 | 2 | NCEGRESS-01 | T-13-EGR | HTTP=000/curl(56) → policy-gap error naming `api.revenium.ai`; HTTP=4xx/2xx → egress confirmed | unit | `bash tests/test_nemoclaw_provisioning.sh` (GROUP A, GROUP B) | ✅ (after 01) | ⬜ pending |
| 13-02-02 | 02 | 2 | NCCLI-01 | T-13-TAR | sha256 mismatch aborts install non-zero; match installs to `/sandbox/.local/bin/revenium`; ledger `cli-delivered` stores version:sha256 | unit | `bash tests/test_nemoclaw_provisioning.sh` (GROUP C, GROUP D, GROUP E) | ✅ (after 01) | ⬜ pending |
| 13-02-03 | 02 | 2 | NCCLI-01, NCCLI-02 | T-13-KEY, T-13-BILL | Creds written to config.yaml chmod 600 (never on exec cmd line); meter probe ledger-gated exactly-once; `--task-type install-smoke-test` tag | unit | `bash tests/test_nemoclaw_provisioning.sh` (GROUP F, GROUP G) | ✅ (after 01) | ⬜ pending |
| 13-03-01 | 03 | 3 | NCCLI-02 | T-13-BILL | Authenticated `revenium meter completion` returns HTTP 2xx from inside the sandbox; probe fires once (ledger) | live-smoke | Manual exec on 34.224.27.67 (full `post-install-nemoclaw.sh` run + ledger/binary/config assertions) | live-only | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/stub-nemoclaw.sh` — argv-capturing `nemoclaw` stub (modeled on `tests/stub-revenium.sh`) with `STUB_NEMOCLAW_*` switches (Plan 01)
- [ ] `tests/test_nemoclaw_provisioning.sh` — hermetic harness covering GROUP A–G for NCEGRESS-01 / NCCLI-01 / NCCLI-02 (Plan 01)
- [ ] `scripts/revenium-policy.yaml` — shipped `api.revenium.ai` egress preset (Plan 01; required for `policy-add` in Plan 02)
- [ ] `scripts/gh-release-policy.yaml` — shipped GitHub CDN egress preset (Plan 01; required for in-sandbox tarball fetch in Plan 02)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Authenticated `revenium meter completion` returns HTTP 2xx against the real Revenium API from inside the live sandbox | NCCLI-02 | Requires a real Revenium API key + a live NemoClaw sandbox; cannot be exercised hermetically. D-LIVE makes this in-scope this phase (not deferred to UAT). | Run full `REVENIUM_SANDBOX_NAME=revenium-spike REVENIUM_API_KEY=… [team/tenant/owner] bash scripts/post-install-nemoclaw.sh` on 34.224.27.67; assert both policies applied, binary at `/sandbox/.local/bin/revenium` reports `1.2.0`, config.yaml present, `meter-probe-passed=1` in ledger, Revenium dashboard shows one `install-smoke-test`-tagged event. |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references
- [x] No watch-mode flags
- [x] Feedback latency < 20s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** approved 2026-06-08
