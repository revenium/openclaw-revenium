---
phase: 12-parallel-install-scaffolding-detection
verified: 2026-06-07T19:27:15Z
status: passed
score: 9/9
overrides_applied: 0
---

# Phase 12: Parallel Install Scaffolding & Detection — Verification Report

**Phase Goal:** The install tooling detects NemoClaw vs standalone OpenClaw vs macOS and routes correctly — the NemoClaw path is skeletal but gated, and a macOS operator gets an explicit refusal rather than a silent no-op.
**Verified:** 2026-06-07T19:27:15Z
**Status:** passed
**Re-verification:** No — initial verification

---

## Goal Achievement

### Observable Truths (Roadmap Success Criteria)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| SC1 | Running the install on a Linux+NemoClaw host (`~/.nemoclaw/` present) enters the NemoClaw install path without touching the standalone OpenClaw install | VERIFIED | GROUP A passes: `STUB_UNAME_S=Linux` + `~/.nemoclaw/` only routes to `post-install-nemoclaw.sh`; output contains "preflight"/"Phase 13"; standalone footer absent |
| SC2 | Running the install on a standalone OpenClaw host continues through the existing path unchanged — no regression | VERIFIED | GROUP byte-stable passes: `git diff --name-only HEAD -- scripts/post-install.sh` is empty; GROUP C confirms dual-home without flag routes standalone (NemoClaw markers absent) |
| SC3 | Running the install on macOS prints an explicit "NemoClaw is unsupported on macOS" error and exits non-zero rather than silently completing | VERIFIED | GROUP D passes: `STUB_UNAME_S=Darwin` + `--nemoclaw` exits non-zero and output contains "graceful-skip" + "unsupported"; GROUP E confirms macOS without NemoClaw signal falls through to standalone without firing refusal |
| SC4 | The NemoClaw install path skeleton is idempotent — running it twice produces the same result without duplication or error | VERIFIED | GROUP F passes: both runs produce identical exit codes and identical NemoClaw marker presence; on macOS dev machine both exit 1 (probe reports Darwin INCOMPATIBLE — expected; on a real Linux host both would exit 0) |

**Score: 4/4 roadmap success criteria VERIFIED**

### Plan Must-Have Truths (Plan 01 + Plan 02 merged)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| P1-T1 | `tests/test_install_dispatcher.sh` executes a PASS/FAIL-counted suite covering all six VALIDATION.md test rows and exits non-zero while install.sh is absent (RED), zero once it exists (GREEN) | VERIFIED | Test suite exits 0 with 10 passed, 0 failed; pre-plan-02 RED state documented in 12-01-SUMMARY; structure confirmed by reading file |
| P1-T2 | `scripts/probe-host-compat.sh` exists as a first-class install-time script with the verbatim exit-code contract (fail>0 -> exit 1; warn>0 or clean -> exit 0) | VERIFIED | File exists (131 lines, executable); contains `VERDICT` block with correct exit logic; `set -u` only (not `set -euo pipefail`); `diff <(tail -n +3 source) <(tail -n +3 scripts/probe-host-compat.sh)` is empty |
| P1-T3 | The test exercises all four D-03 routing branches plus the macOS refusal and the post-install.sh byte-stability check using `STUB_UNAME_S` + `mktemp -d` HOME isolation | VERIFIED | All seven groups (A–F + byte-stable) present as labeled sections; `STUB_UNAME_S` used 4 times; `mktemp -d` HOME isolation per group; `git diff --name-only` byte-stability assertion at line 242 |
| P2-T1 | Running install.sh on Linux with `~/.nemoclaw/` only (or `--nemoclaw` / `NEMOCLAW=1`) enters the NemoClaw path; on a dual-home or standalone host with no flag it routes to the untouched post-install.sh (D-03) | VERIFIED | install.sh implements D-03 routing: flag parse via `case "${arg}"`, `NEMOCLAW:-` env check, dir presence check. Groups A/B/C all pass in test suite. NEMOCLAW=1 env implemented in install.sh (line 65) but not separately tested — not required by roadmap SCs |
| P2-T2 | Running install.sh on macOS WITH a NemoClaw signal prints an explicit 'unsupported' message naming the Darwin graceful-skip trap and exits non-zero; macOS WITHOUT a NemoClaw signal falls through to standalone | VERIFIED | install.sh lines 75-85: Darwin + TARGET==nemoclaw -> `fail()` with multi-line message containing "graceful-skip"; standalone fallthrough unaffected. GROUP D and GROUP E both pass |
| P2-T3 | post-install-nemoclaw.sh runs probe-host-compat.sh as a hard gate (FAIL->non-zero exit, WARN->continue), checks nemoclaw CLI, runs Phase 13+ stub no-ops, and is idempotent on second run | VERIFIED | `bash "${PROBE_SCRIPT}"` at line 77 (subprocess, never sourced); `! bash` pattern propagates probe exit 1 as non-zero from script; four stub functions defined at lines 50-64 and called in sequence at lines 102-105; no ledger/writes → naturally idempotent |
| P2-T4 | `scripts/post-install.sh` is byte-stable — git diff empty | VERIFIED | `git diff --name-only HEAD -- scripts/post-install.sh` produces no output |
| P2-T5 | `tests/test_install_dispatcher.sh` goes GREEN (exit 0, all six groups pass) | VERIFIED | `bash tests/test_install_dispatcher.sh` exits 0 with "Results: 10 passed, 0 failed" |

**Score: 8/8 plan must-have truths VERIFIED** (combined P1+P2)

**Overall Score: 9/9 truths verified** (4 roadmap SCs + 5 distinct plan truths after deduplication)

---

## Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `scripts/install.sh` | Thin dispatcher: flag parse, D-03 routing, macOS refusal, passthrough exec | VERIFIED | 106 lines, executable (`-rwxr-xr-x`), contains `STUB_UNAME_S`, `graceful-skip`, `case "${arg}" in` flag parse, `${HOME}/.nemoclaw`/`${HOME}/.openclaw` dir checks, no `read` calls |
| `scripts/post-install-nemoclaw.sh` | NemoClaw path skeleton: preflight hard gate + CLI check + Phase 13+ stub functions | VERIFIED | 119 lines, executable; `bash "${PROBE_SCRIPT}"` (subprocess, not sourced); four `stub_*` functions defined and called; PATH extended with `~/.local/bin`; no `read` calls; no ledger created |
| `scripts/probe-host-compat.sh` | Host compatibility preflight probe with verbatim exit-code contract | VERIFIED | 131 lines, executable; `set -u` (not `set -euo pipefail`); contains `VERDICT`; banner updated to "Host Compatibility Preflight"; logic identical to spike source (tail-n+3 diff is empty) |
| `tests/test_install_dispatcher.sh` | Hermetic routing/refusal/idempotency/byte-stability test suite | VERIFIED | 182 non-comment lines (>= 120); contains `STUB_UNAME_S`, `graceful-skip`, `git ... diff --name-only ... scripts/post-install.sh`; all 7 groups (A–F + byte-stable) present |

---

## Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| `tests/test_install_dispatcher.sh` | `scripts/install.sh` | `STUB_UNAME_S + HOME env-override subprocess invocation` | VERIFIED | `run_install()` at line 68 calls `bash "${INSTALL_SH}" "$@"`; all six groups invoke it |
| `tests/test_install_dispatcher.sh` | `scripts/post-install.sh` | `git diff --name-only byte-stability assertion` | VERIFIED | Line 242: `git -C "${REPO_ROOT}" diff --name-only HEAD -- scripts/post-install.sh` |
| `scripts/install.sh` | `scripts/post-install-nemoclaw.sh` | `bash subprocess exec on NemoClaw target` | VERIFIED | Line 100: `bash "${SCRIPT_DIR}/post-install-nemoclaw.sh" ...` |
| `scripts/install.sh` | `scripts/post-install.sh` | `bash subprocess exec on standalone target` | VERIFIED | Line 104: `bash "${SCRIPT_DIR}/post-install.sh" ...` |
| `scripts/post-install-nemoclaw.sh` | `scripts/probe-host-compat.sh` | `bash subprocess exec as hard preflight gate (never sourced)` | VERIFIED | Line 77: `if ! bash "${PROBE_SCRIPT}"; then fail "..."` — subprocess confirmed; source pattern (`\. "${PROBE_SCRIPT}"`) is absent |

---

## Data-Flow Trace (Level 4)

Not applicable. All four deliverables are bash install scripts — no dynamic data rendering. The "data" flowing through the system is OS detection, directory presence signals, and probe exit codes, all of which are verified by the test suite's behavioral assertions.

---

## Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Full dispatcher test suite | `bash tests/test_install_dispatcher.sh` | `Results: 10 passed, 0 failed` (exit 0) | PASS |
| Existing write-marker tests not regressed | `bash tests/test_write_marker.sh` | `Results: 12 passed, 0 failed` (exit 0) | PASS |
| Existing guardrail-argv tests not regressed | `bash tests/test_guardrail_argv.sh` | `Results: 18 passed, 0 failed` (exit 0) | PASS |
| Syntax check all four deliverables | `bash -n` on all four files | All clean | PASS |
| post-install.sh byte-stability | `git diff --name-only HEAD -- scripts/post-install.sh` | Empty (no output) | PASS |
| Probe source fidelity | `diff <(tail -n +3 spike-source) <(tail -n +3 scripts/probe-host-compat.sh)` | No differences | PASS |

---

## Probe Execution

No `scripts/*/tests/probe-*.sh` files exist for Phase 12. The phase's own test harness (`tests/test_install_dispatcher.sh`) serves as the equivalent verification mechanism and was executed directly above.

---

## Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
|-------------|------------|-------------|--------|---------|
| NCINST-01 | 12-01-PLAN.md, 12-02-PLAN.md | Parallel install path leaving standalone untouched | SATISFIED | scripts/install.sh dispatches to post-install-nemoclaw.sh (NemoClaw) or post-install.sh (standalone); post-install.sh is byte-stable (git diff empty); GROUP A/B/C all pass |
| NCINST-02 | 12-01-PLAN.md, 12-02-PLAN.md | Detect NemoClaw target; refuse macOS explicitly | SATISFIED | install.sh detects Linux vs Darwin via `STUB_UNAME_S:-$(uname -s)`; Darwin + NemoClaw signal produces multi-line refusal containing "graceful-skip" and exits non-zero (GROUP D); macOS without NemoClaw signal routes to standalone without refusal (GROUP E) |

Both NCINST-01 and NCINST-02 are assigned to Phase 12 in REQUIREMENTS.md. Both are satisfied. No orphaned requirements found — REQUIREMENTS.md shows all other IDs (NCEGRESS-01, NCCLI-01/02, NCMETER-01, NCENF-01/02, NCDEPLOY-01/02) are assigned to Phases 13–16.

---

## Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| `tests/test_install_dispatcher.sh` | 52 | `XXXXXX` in mktemp template | Info | False positive — `mktemp -d "${TMPDIR:-/tmp}/test-inst.XXXXXX"` is the standard POSIX mktemp template syntax, not a debt marker |

No `TBD`, `FIXME`, or `XXX` debt markers found in any of the four modified files. No placeholder returns, empty handlers, or hollow stubs outside the intentional Phase 13+ no-op stubs (which are the defined deliverable for this phase, not gaps).

**Note on Phase 13+ stub functions:** `stub_provision_egress_policy`, `stub_deliver_revenium_cli`, `stub_install_metering_loop`, `stub_install_enforcement_plugin` are intentional no-ops that define insertion points. They are not gaps — they are the explicitly specified output of this phase per Plan 02 D-07.

**Note on GROUP-F exit codes:** GROUP-F asserts exit code equality (both runs match) rather than equality to 0. On the macOS dev machine, both runs exit 1 because `probe-host-compat.sh` correctly reports Darwin as INCOMPATIBLE. On a real Linux host, both would exit 0. The idempotency contract (same result twice) is satisfied. The SUMMARY documents this behavior accurately.

---

## Human Verification Required

One confirmatory smoke test is identified in the VALIDATION.md as manual-only:

### 1. Real Linux+NemoClaw Host End-to-End Run

**Test:** SSH to spike host 34.224.27.67 (or any host with `~/.nemoclaw/` present and Docker). Run `bash scripts/install.sh`. Confirm the NemoClaw skeleton path runs: output contains preflight probe results, "Phase 13+" stub notices, and the success banner. Confirm probe exits 0 (Linux passes COMPATIBLE or USABLE WITH CAVEATS).

**Expected:** The dispatcher routes to `post-install-nemoclaw.sh`; the probe runs and exits 0; all four stub functions emit their deferral warnings; the success banner appears. No standalone footer ("Revenium skill installed") appears.

**Why human:** Requires a live NemoClaw host with `~/.nemoclaw/` present and Docker accessible. The automated test suite covers routing logic hermetically via `STUB_UNAME_S` + `mktemp -d` HOME isolation. The on-host run is a confirmatory smoke, not the primary gate. Per VALIDATION.md, this is classified as confirmatory, not blocking.

---

## Gaps Summary

No gaps. All four roadmap success criteria are VERIFIED. All must-have truths from both plan frontmatter files are VERIFIED. All key links are WIRED. The full test suite (10/10) passes. The existing regression suites (test_write_marker.sh 12/12, test_guardrail_argv.sh 18/18) are green. post-install.sh is byte-stable. The probe is a verbatim copy of the validated spike source (banner-only edit).

The phase goal — "install tooling detects NemoClaw vs standalone OpenClaw vs macOS and routes correctly; NemoClaw path is skeletal but gated; macOS operator gets explicit refusal rather than silent no-op" — is fully achieved in the codebase.

---

_Verified: 2026-06-07T19:27:15Z_
_Verifier: Claude (gsd-verifier)_
