---
phase: 12
slug: parallel-install-scaffolding-detection
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-06-07
---

# Phase 12 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash (native, no framework) — mirrors all existing `tests/*.sh` files |
| **Config file** | none — tests run directly |
| **Quick run command** | `bash tests/test_install_dispatcher.sh` |
| **Full suite command** | `bash tests/test_install_dispatcher.sh && bash tests/test_write_marker.sh && bash tests/test_guardrail_argv.sh` |
| **Estimated runtime** | ~5 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test_install_dispatcher.sh`
- **After every plan wave:** Run `bash tests/test_install_dispatcher.sh && bash tests/test_write_marker.sh && bash tests/test_guardrail_argv.sh` (regression coverage)
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** ~5 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 12-XX | TBD | 0 | NCINST-01/02 | — | N/A | unit | `bash tests/test_install_dispatcher.sh` | ❌ W0 | ⬜ pending |
| 12-XX | TBD | 1 | NCINST-01 | — | Linux+NemoClaw host enters NemoClaw path; `post-install.sh` NOT invoked | integration | `bash tests/test_install_dispatcher.sh` | ❌ W0 | ⬜ pending |
| 12-XX | TBD | 1 | NCINST-01 | — | Standalone host runs existing path — no regression; `post-install.sh` byte-stable | integration | `bash tests/test_install_dispatcher.sh` + `git diff --name-only scripts/post-install.sh` (empty) | ✅ (git) | ⬜ pending |
| 12-XX | TBD | 1 | NCINST-01 | — | NemoClaw skeleton idempotent (run twice = identical output, exit 0 both) | integration | `bash tests/test_install_dispatcher.sh` | ❌ W0 | ⬜ pending |
| 12-XX | TBD | 1 | NCINST-02 | T-12-01 | macOS + NemoClaw signal → explicit "unsupported"/"graceful-skip" message + non-zero exit | integration | `bash tests/test_install_dispatcher.sh` | ❌ W0 | ⬜ pending |
| 12-XX | TBD | 1 | NCINST-02 | — | macOS without NemoClaw signal → standalone path runs normally | integration | `bash tests/test_install_dispatcher.sh` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*
*Task IDs are placeholders until plans are written — the planner finalizes plan/wave/task assignment.*

---

## Four Success Criteria → Observable Behaviors

| Success Criterion | Observable Behavior | Test Mechanism |
|-------------------|---------------------|----------------|
| SC1: Linux+NemoClaw host enters NemoClaw path | `post-install-nemoclaw.sh` invoked; `post-install.sh` NOT invoked; output contains "preflight" + "Phase 13+" stub notice | `HOME` with `~/.nemoclaw/` only, `STUB_UNAME_S=Linux`; assert output contains "Phase 13+" and NOT "Revenium skill installed" |
| SC2: Standalone host continues unchanged | `post-install.sh` invoked; output contains "Revenium skill installed" footer | `HOME` with `~/.openclaw/` only, no `--nemoclaw` flag |
| SC3: macOS prints explicit error, exits non-zero | Exit code ≠ 0; output contains "unsupported" + "graceful-skip" | `STUB_UNAME_S=Darwin` + `--nemoclaw` (or `~/.nemoclaw/` only); assert exit ≠ 0 + message |
| SC4: NemoClaw skeleton idempotent | Running `post-install-nemoclaw.sh` twice = identical output, no error on second run | Call with same `HOME` twice; compare output; assert exit 0 both times |

---

## Wave 0 Requirements

- [ ] `tests/test_install_dispatcher.sh` — covers all NCINST-01/02 routing, refusal, and idempotency cases (stub `HOME` dirs + `STUB_UNAME_S` env override)

*No new test framework or conftest needed — existing bash `tests/*.sh` conventions apply (`PASS`/`FAIL` counters, `mktemp -d` HOME isolation, `STUB_*` env-var stub injection).*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Real Linux+NemoClaw host enters NemoClaw path end-to-end | NCINST-01 | Requires live NemoClaw host (34.224.27.67); routing/skeleton is automated but a true on-host smoke confirms detection signals match production | Run `install.sh` on the spike host with `~/.nemoclaw/` present; confirm NemoClaw skeleton path runs and prints Phase 13+ stub notices |

*All routing/refusal/idempotency logic has automated verification via stubbed `HOME` + `uname`; the on-host run is a confirmatory smoke, not the primary gate.*

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 10s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
