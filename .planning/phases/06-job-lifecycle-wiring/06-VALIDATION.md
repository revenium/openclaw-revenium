---
phase: 6
slug: job-lifecycle-wiring
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-06-03
---

# Phase 6 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Plain bash integration scripts (no harness); `pass`/`fail` counters + final exit code (see `tests/test_report_argv.sh:38-42`) |
| **Config file** | none — each `tests/test_*.sh` is self-contained, builds its own tmp `OPENCLAW_HOME` |
| **Quick run command** | `bash tests/test_report_jobs_argv.sh` (new) |
| **Full suite command** | `for t in tests/test_*.sh; do bash "$t" || exit 1; done` |
| **Estimated runtime** | <30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `bash tests/test_report_jobs_argv.sh` + `bash tests/test_report_argv.sh` (regression — must stay green, Pitfall 4)
- **After every plan wave:** Run `for t in tests/test_*.sh; do bash "$t" || exit 1; done`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

> Populated by the planner per task. Requirement→behavior→test seam derived from RESEARCH.md §Validation Architecture.

| Req ID | Behavior | Test Type | Automated Command | File Exists | Status |
|--------|----------|-----------|-------------------|-------------|--------|
| JLIFE-01 | `jobs create` fires once per declared job; idempotent across two `report.sh` runs | integration (argv + ledger) | assert exactly one `^create$` token across two runs; one `JOB:<id>:created:` ledger line | ❌ W0 | ⬜ pending |
| JLIFE-02 | Correlated completion ships `--agentic-job-id/-name/-type` | integration (argv) | `awk '/^--agentic-job-id$/{getline;print}'` == marker id; name + type present | ❌ W0 | ⬜ pending |
| JLIFE-03 | `jobs outcome <id> --result <STATUS>` fires once from marker status; FAILED carries `--metadata`, SUCCESS/CANCELLED do not | integration (argv + ledger) | assert `^outcome$`, positional id, `--result`==status; `--metadata` only for FAILED; one `:outcome:...:STATUS` ledger line | ❌ W0 | ⬜ pending |
| JLIFE-04 | Broken/absent jobs CLI → `JOBS_CLI_CAPABLE=false`; no job tokens, no `--agentic-job-*`, task-type + `--agent` still ship (v1.0-identical) | integration (fail-open) | stub forcing capability-probe failure; assert zero `^jobs$`/`agentic-job` tokens AND `--task-type`/`--agent` present | ❌ W0 | ⬜ pending |
| JLIFE-04 (extra) | `jobs create` 409 treated as success (ledger row written, exit 0) | integration (409 path) | `STUB_REVENIUM_409_FOR=<id>`; assert `:created:` row written, exit 0 | ❌ W0 | ⬜ pending |
| JLIFE-04 (extra) | jobs-CLI failure does NOT block completion offset advance or re-meter (CR-02 stays decoupled) | integration | stub jobs to fail (non-409), completions succeed; assert offsets advance + completions TX:-ledgered once | ❌ W0 | ⬜ pending |
| JLIFE-05 | Two consecutive runs never re-issue create or outcome (ledger gates) | integration (ledger) | run twice; `grep -c '^JOB:.*:created:'`==1 and `:outcome:`==1; no second `^create$`/`^outcome$` in run-2 argv | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `tests/test_report_jobs_argv.sh` — new integration test covering JLIFE-01..05 (fixtures: session with a job marker correlating to a same-tick SUCCESS completion, a FAILED job with `failure_reason`, a CANCELLED job, and a re-run idempotency check)
- [ ] `tests/stub-revenium.sh` extension — fake `jobs create`/`jobs outcome` argv capture + optional `STUB_REVENIUM_409_FOR` 409 path
- [ ] Fail-open fixture/stub — a `revenium` stub whose `jobs --help` exits non-zero OR `meter completion --help` lacks `--agentic-job-id`, forcing `JOBS_CLI_CAPABLE=false`
- [ ] Decision recorded: keep `test_report_argv.sh` job-free (recommended) so its no-`agentic-job` assertion stays valid (Pitfall 4)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Live Revenium 409 conflict string on duplicate create/outcome | JLIFE-01 / JLIFE-03 | Exact server conflict text (`already exists`/`conflict`/HTTP 409) can't be confirmed against the live server in hermetic tests (RESEARCH A1) | At UAT, force a duplicate create against staging Revenium; confirm the 409-as-success branch matches the real response string |
| Server-side `--agent` rollup attributes un-stamped arc spend to the job | JLIFE-02 | Server behavior, not observable from `report.sh` argv (RESEARCH A3) | At UAT, inspect Revenium dashboard: arc completions metered before the closing marker still roll up to the job via `--agent "openclaw-<root_sid>"` |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
