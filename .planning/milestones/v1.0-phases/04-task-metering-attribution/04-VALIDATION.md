---
phase: 4
slug: task-metering-attribution
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-06-03
---

# Phase 4 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Pure-stdlib `unittest` for the Python resolver (`get-root-session-id.py`) — importable, no install; pure-shell test harness for the bash scripts using a stubbed `revenium` (`tests/stub-revenium.sh` captures argv to `STUB_REVENIUM_ARGV_FILE`) placed first on PATH. No bats install required (planner's discretion per RESEARCH "Wave 0 Gaps"). |
| **Config file** | none — `tests/` harness + stub created in Wave 0 (plan 04-01 Task 1) |
| **Quick run command** | `python3 -m unittest tests.test_get_root_session_id` (resolver) · `bash tests/test_<script>.sh` (the script touched) |
| **Full suite command** | `python3 -m unittest tests.test_get_root_session_id && bash tests/test_write_marker.sh && bash tests/test_report_argv.sh && bash tests/test_setup_guardrails_argv.sh` |
| **Estimated runtime** | ~10-15 seconds (resolver unit tests < 5s; each shell integration test runs against a tmp fixture tree with a stubbed CLI — no network) |

---

## Sampling Rate

- **After every task commit:** Run the unit/integration test for the script touched (`python3 -m unittest tests.test_get_root_session_id`, or `bash tests/test_write_marker.sh`, etc.) — < 5s.
- **After every plan wave:** Run the full suite command above (resolver unit + all script-level integration tests with a stubbed `revenium` on PATH).
- **Before `/gsd-verify-work`:** Full suite must be green; plus the manual smoke check below.
- **Max feedback latency:** ~15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 04-01-01 | 01 | 1 | METER-01 | T-04-SC | Taxonomy is the single allowlist source for marker validation | unit | `python3 -c "import json,sys; d=json.load(open('task-taxonomy.json')); sys.exit(0 if set(d['labels'])=={'research','analysis','generation','review','code_review','refactor','planning','debugging'} else 1)" && grep -q sessions_spawn tests/fixtures/sessions/parent-with-spawn.jsonl && test -x tests/stub-revenium.sh` | ❌ W0 | ⬜ pending |
| 04-01-02 | 01 | 1 | TRACE-01 / D-07 | — | Resolver wrapper fails open; prefix constant centralized | unit | `bash -c 'source scripts/common.sh; [[ "${REVENIUM_AGENT_PREFIX}" == "openclaw-" ]] && [[ -n "${MARKERS_DIR}" ]] && [[ -n "${TAXONOMY_FILE}" ]] && [[ -n "${SESSIONS_DIR}" ]] && type get_root_session_id >/dev/null'` | ❌ W0 | ⬜ pending |
| 04-01-03 | 01 | 1 | TRACE-01 | T-04-01 / T-04-02 | Malformed JSONL never raises; cycle capped at max_depth; fail-open to input sid | unit | `python3 -m unittest tests.test_get_root_session_id -v` | ❌ W0 | ⬜ pending |
| 04-02-01 | 02 | 2 | METER-02 / D-03 | T-04-04 / T-04-06 / T-04-07 | Allowlist rejects unknown label; sid charset guard; flock+0700 append | unit | `bash tests/test_write_marker.sh` | ❌ W0 | ⬜ pending |
| 04-02-02 | 02 | 2 | METER-03 / TRACE-01 / TRACE-02 | T-04-05 / T-04-08 / T-04-09 | Per-line try/except defaults `unclassified`; root resolved once per session | integration | `bash tests/test_report_argv.sh` | ❌ W0 | ⬜ pending |
| 04-03-01 | 03 | 2 | D-07 (base filter) | — | Base rule filters AGENT:STARTS_WITH:openclaw- (both occurrences) | integration | `grep -Fc 'AGENT:STARTS_WITH:${REVENIUM_AGENT_PREFIX}' scripts/setup-guardrails.sh \| grep -qx 2 && ! grep -Fq 'AGENT:IS:${REVENIUM_AGENT_NAME}' scripts/setup-guardrails.sh` | ❌ W0 | ⬜ pending |
| 04-03-02 | 03 | 2 | METER-01 / D-10 | T-04-10..14 | Per-task rule carries its own TASK_TYPE:IS filter (NP-4 bug fix); capability gate; index/limit validation | integration | `bash tests/test_setup_guardrails_argv.sh` | ❌ W0 | ⬜ pending |
| 04-04-01 | 04 | 3 | METER-02 / D-09 | T-04-15 | SKILL.md directs only the 8 taxonomy labels; no job/plugin refs | integration | `grep -qi 'TASK CLASSIFICATION' SKILL.md && grep -Fq 'write-marker.sh' SKILL.md && grep -q 'unclassified' SKILL.md && ! grep -qi 'agentic_job_id\|JOB DECLARATION' SKILL.md && ! grep -Fqi 'job-declaration.md' SKILL.md && test -f references/task-classification.md && grep -Fq 'write-marker.sh' references/task-classification.md` | ❌ W0 | ⬜ pending |
| 04-04-02 | 04 | 3 | D-08 | T-04-16 / T-04-19 | One-time legacy notice; no auto-rewrite; atomic flag write | integration | `grep -Fq "old filter and won't track spend" SKILL.md && grep -qi 'AGENT:IS:OpenClaw' SKILL.md && ! grep -qi 'auto-rewrite\|automatically rewrite\|silently recreate' SKILL.md` | ❌ W0 | ⬜ pending |
| 04-04-03 | 04 | 3 | D-04 / METER-01 | T-04-17 / T-04-18 | Prune fail-open after enforcement; markers/ 0700 | integration | `grep -q "markers" scripts/cron.sh && grep -q "mtime +7" scripts/cron.sh && grep -Fq 'write-marker.sh' scripts/post-install.sh && grep -Fq 'get-root-session-id.py' scripts/post-install.sh && grep -Fq 'task-taxonomy.json' scripts/post-install.sh && grep -Eq 'chmod 700.*markers\|markers.*chmod 700\|chmod 0700.*markers' scripts/post-install.sh && bash -n scripts/cron.sh && bash -n scripts/post-install.sh` |  ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

All Wave 0 fixtures are created by plan 04-01 (Task 1 + Task 3):

- [ ] `tests/stub-revenium.sh` — executable argv-capturing `revenium` stub (appends each argv to `STUB_REVENIUM_ARGV_FILE`, exits 0); reused by report.sh and setup-guardrails.sh integration tests (METER-03/TRACE-02, D-07/D-10).
- [ ] `tests/fixtures/sessions/parent-with-spawn.jsonl` — parent session header + a `sessions_spawn` toolResult line carrying `message.details.childSessionKey`; backs the resolver one-hop case and report.sh integration (TRACE-01/02).
- [ ] `tests/fixtures/sessions/plain-session.jsonl` — header + one ordinary assistant line, no spawn; backs the no-parent / fail-open-to-self case.
- [ ] `tests/test_get_root_session_id.py` — stdlib `unittest` resolver tests (no-parent→self, one-hop, cycle→depth-cap, missing-dir→sid, empty-sid→exit 0) for TRACE-01.

*Downstream per-script test files (`tests/test_write_marker.sh`, `tests/test_report_argv.sh`, `tests/test_setup_guardrails_argv.sh`) are created inside the plans that own the corresponding script and reuse the Wave 0 harness above.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| revenium CLI accepts `--task-type` / `--agent` on the live 1.1.2 binary | METER-03 / TRACE-02 | Confirming real server-side flag acceptance is outside the stubbed-CLI harness (the integration tests assert argv shape, not live acceptance) | Phase gate smoke check: run one `revenium meter completion --dry-run --task-type research --agent openclaw-test ...` and confirm it is accepted (flags already VERIFIED present on 1.1.2 in RESEARCH "Revenium CLI Flag Surface"). |

*All other phase behaviors have automated verification.*

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [x] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
