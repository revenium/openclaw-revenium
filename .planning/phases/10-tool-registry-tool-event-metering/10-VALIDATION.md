---
phase: 10
slug: tool-registry-tool-event-metering
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-06-03
---

# Phase 10 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
>
> **Framework note:** This repo uses **bash integration tests** (`tests/test_*.sh` invoked via `bash`), NOT `bats`. There is no `test/` directory and no `bats` dependency. The plans (10-00..10-02) follow the real repo pattern sourced from the live codebase in RESEARCH.md / PATTERNS.md. This file matches that reality.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | bash integration tests (hermetic, stub-driven — pattern from Phase 9 `tests/test_guardrail_argv.sh`) |
| **Config file** | none — Plan 10-00 (Wave 1) creates the test scaffolding |
| **Quick run command** | `bash tests/test_report_tool_argv.sh` |
| **Full suite command** | `bash -n scripts/report.sh && bash -n scripts/common.sh && bash tests/test_report_tool_argv.sh` |
| **Estimated runtime** | ~10 seconds (hermetic, no live network — uses `tests/stub-revenium.sh`) |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test_report_tool_argv.sh`
- **After every plan wave:** Run the full suite command above
- **Before `/gsd-verify-work`:** Full suite must exit 0
- **Max feedback latency:** 10 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 10-00-01 | 10-00 | 1 | TOOLEV-01..04 | T-tool-name-injection | Stub captures argv hermetically; no live API | unit | `bash -n tests/stub-revenium.sh` | ❌ W0 | ⬜ pending |
| 10-00-02 | 10-00 | 1 | TOOLEV-01..04 | — | Argv assertions pin registration + event shape (incl. `--duration-ms 250`, explicit `--success`) | unit | `bash tests/test_report_tool_argv.sh` | ❌ W0 | ⬜ pending |
| 10-01-01 | 10-01 | 2 | TOOLEV-01, 04 | — | `TOOL_REGISTRY_LEDGER_FILE` / `TOOL_EVENTS_LEDGER_FILE` constants defined | unit | `bash -n scripts/common.sh && grep -c TOOL_REGISTRY_LEDGER_FILE scripts/common.sh` | ❌ W0 | ⬜ pending |
| 10-01-02 | 10-01 | 2 | TOOLEV-01, 04 | T-ledger-poison | `TOOLS_CLI_CAPABLE` probe + `_register_tool` idempotency-gated on `TOOL:<tool_id>`; fail-open | unit | `bash tests/test_report_tool_argv.sh` | ❌ W0 | ⬜ pending |
| 10-02-01 | 10-02 | 3 | TOOLEV-02, 03, 04 | T-fail-open-masking | `_meter_tool_event` posts to /v2/tool/events with explicit `--success`; dedup on `TOOLEV:<toolcall_id>` in `TOOL_EVENTS_LEDGER_FILE` | unit | `bash tests/test_report_tool_argv.sh` | ❌ W0 | ⬜ pending |
| 10-02-02 | 10-02 | 3 | TOOLEV-02, 03, 04 | T-double-count | toolCall scan loop runs after completion loop; completion path (/v2/api/completions) byte-unchanged | unit | `bash tests/test_report_tool_argv.sh` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*
*"File Exists ❌ W0" = the test target is created by Wave 1 Plan 10-00; green once that plan executes.*

---

## Wave 0 Requirements

Wave 0 scaffolding is delivered by **Plan 10-00 (Wave 1)** — there is no separate pre-wave:

- [ ] `tests/test_report_tool_argv.sh` — hermetic argv test covering TOOLEV-01..04 (Plan 10-00 Task 2)
- [ ] `tests/stub-revenium.sh` — extend with `tools create` + `meter tool-event` switches and argv capture (Plan 10-00 Task 1)
- [ ] bash + python3 present (existing toolchain; macOS bash 3.2 — no bash-4 features, per RESEARCH)

*No `bats` install required — repo uses plain `bash tests/test_*.sh`.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Tool-event appears in Revenium dashboard with success=true | TOOLEV-02 | Requires live Revenium account + network | On test host 172.16.1.247, trigger a tool call, run report.sh, confirm the tool-event in Revenium UI with the correct success flag |
| Registered tool visible via `revenium tools list` | TOOLEV-01 | Requires live API | Run a cron tick that first-sees a tool, then `revenium tools list`; confirm the tool-id present exactly once |
| No double-count: tool usage not also billed as an extra completion | TOOLEV-03 | Cross-endpoint correlation in a live account | After a session with N tool calls, compare /v2/api/completions vs /v2/tool/events counts; completions unchanged by tool work |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references (delivered by Plan 10-00)
- [x] No watch-mode flags
- [x] Feedback latency < 10s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** approved 2026-06-03 (strategy); `wave_0_complete` flips true once Plan 10-00 executes green.
