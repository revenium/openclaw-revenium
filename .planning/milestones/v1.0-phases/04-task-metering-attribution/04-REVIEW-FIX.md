---
phase: 04-task-metering-attribution
fixed_at: 2026-06-03T00:00:00Z
review_path: .planning/phases/04-task-metering-attribution/04-REVIEW.md
iteration: 1
findings_in_scope: 9
fixed: 9
skipped: 0
status: all_fixed
---

# Phase 4: Code Review Fix Report

**Fixed at:** 2026-06-03
**Source review:** .planning/phases/04-task-metering-attribution/04-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 9 (2 Critical + 7 Warning)
- Fixed: 9
- Skipped: 0

All four test suites pass after the fixes:
`python3 tests/test_get_root_session_id.py` (7 OK),
`bash tests/test_write_marker.sh` (10 passed),
`bash tests/test_report_argv.sh` (6 passed),
`bash tests/test_setup_guardrails_argv.sh` (11 passed).

> Note on a pre-existing flake (NOT introduced by these fixes) — ROOT-CAUSED AND FIXED:
> `tests/test_setup_guardrails_argv.sh` intermittently (~50%) failed assertions
> A1/A5/A6/A7/A8 ("expected 2 invocations, got 1"; per-task `budget-rules create`
> missing TASK_TYPE; only 1 ruleId persisted). This was NOT test isolation — it
> was a real product defect.
>
> **Root cause:** `setup-guardrails.sh:691` gated the per-task-type picker with
> `revenium guardrails budget-rules create --help 2>/dev/null | grep -q 'TASK_TYPE'`
> under `set -euo pipefail`. `grep -q` exits the instant it matches and closes the
> pipe; the `revenium` producer process, still writing, dies with SIGPIPE (141);
> pipefail then surfaces 141 as the pipeline status and the `if` gate evaluates
> false — so the picker (ROADMAP success criterion 5) was silently skipped. The
> outcome races on whether the producer finished writing before grep exited,
> hence the ~50/50 split. **This affected production too** (with the real
> `revenium` on PATH), not just the test.
>
> **Fix:** capture `--help` output into a variable first, then grep the captured
> string via here-string (no pipe, no SIGPIPE). Same bug class fixed in
> `post-install.sh:618` (`openclaw skills list | grep -q "${SKILL_NAME}"`), which
> gated skill-visibility reporting. Committed as
> `fix(04): avoid pipefail+SIGPIPE race in revenium/openclaw --help|grep -q gates`.
> After the fix, `test_setup_guardrails_argv.sh` passed 20/20 consecutive runs.

## Fixed Issues

### CR-01: Code injection via untrusted session timestamps in `python3 -c`

**Files modified:** `scripts/report.sh`
**Commit:** bbd4c42
**Applied fix:** Converted three `python3 -c "..."` call sites that interpolated
untrusted session data to the project's env-passing quoted-heredoc pattern
(T-04-09). The duration computation now reads `REQ_TS`/`RESP_TS` from
`os.environ`; `get_offset` reads `OFFSETS_FILE`/`SID`; `set_offset` reads
`OFFSETS_FILE`/`SID`/`COUNT`. No session-derived bytes (timestamps, session
filenames) are interpolated into a Python program string anymore, closing the
arbitrary-code-execution vector. Also replaced bare `except:` with
`except Exception:` in the moved code. Verified with `bash -n` and
`test_report_argv.sh`.

### CR-02: Per-session offset advances even when completions fail to ship

**Files modified:** `scripts/report.sh`
**Commit:** dd0834f
**Applied fix:** `process_session` now only calls `set_offset` to the
high-water mark when `failed_count -eq 0`. When any completion failed to post,
the offset is left unchanged and a warning is logged, so the failed lines are
re-scanned on the next tick and retried. Re-processing succeeded lines is safe
because the `TX:` ledger dedups them, so this does not double-bill.
**Requires human verification:** this is a control-flow/logic change to the
metering retry semantics; syntax + test pass, but the developer should confirm
the retry behavior against the intended billing semantics (e.g., that a session
with a permanent failure does not stall forever — acceptable here because the
ledger still dedups, but worth a conscious sign-off).

### WR-01: `trap ... EXIT` overwrites prior trap — temp files leak

**Files modified:** `scripts/report.sh`
**Commit:** fd12112
**Applied fix:** Removed the two single-command `trap ... EXIT` installs (the
second silently replaced the first, and both were overwritten every loop
iteration, leaking `rv-markers`/`rv-meta`/`rv-umsg` temp files every cron tick).
Declared all three temp-file vars up front and added a function-scoped
`_cleanup_session_tmp` helper that is invoked on the early-return path and at
the end of `process_session`, so each iteration cleans its own temp files.

### WR-02: Timestamp tie at equal wall-clock instant drops the marker

**Files modified:** `scripts/report.sh`
**Commit:** ebec839
**Applied fix:** The marker-correlation Python heredoc now parses both the
marker `ts` and the completion `ts` to `datetime` objects (via the same
`parse_ts` helper logic used elsewhere) and compares those instead of doing a
raw lexicographic string compare. This fixes the case where a second-precision
marker (`...00Z`) coincides with a millisecond-precision completion
(`...00.000Z`) and was wrongly excluded because `'Z' > '.'` lexicographically.
Falls back to the raw compare if either side fails to parse. Verified the tie
case now correlates (`research` instead of `unclassified`).

### WR-03: Marker attributed to newest-mtime session, not the agent's own

**Files modified:** `scripts/write-marker.sh`
**Commit:** 362de7e
**Applied fix:** The caller (the OpenClaw agent via SKILL.md) cannot reliably
pass its own session id, so applied the review's "at minimum" remedy: session
resolution now prefers the non-cron session whose JSONL most recently appended
an assistant *completion* (parsed from the file tail), falling back to non-cron
mtime only when no completions exist yet, and never falling back to cron
sessions (the old `elif all_files` branch that could file a marker under a cron
sid was removed). Verified with a simulation where a session with an older
mtime but a more recent completion correctly wins attribution.
**Requires human verification:** this changes the active-session heuristic; the
maintainer should confirm the "most recent assistant completion" signal matches
how OpenClaw actually interleaves concurrent/subagent sessions in production.

### WR-04: `meta_lookup`/`user_msg_lookup` treat message IDs as regexes

**Files modified:** `scripts/report.sh`
**Commit:** 7fc3fc2
**Applied fix:** Replaced the `grep "^${1}\t"` lookups (which treated the
message ID as a basic regex) with `awk -F'\t' '$1==id'` literal-string field
matches. `user_msg_lookup` uses `sub(/^[^\t]*\t/, "")` to reproduce the prior
`cut -f2-` behavior (preserving embedded tabs in the message body). Verified the
trace-id walk and parent-ts lookups still pass `test_report_argv.sh`.

### WR-05: Offset off-by-one when a session JSONL line lacks a trailing newline

**Files modified:** `scripts/report.sh`
**Commit:** 6f2048b
**Applied fix:** Replaced `wc -l < file` (counts newline characters, undercounts
an unterminated final line) with `grep -c '' file`, which counts the final
unterminated line the same way `tail`/`read` consume it. Verified: a 3-line file
without a trailing newline now counts 3 (was 2 under `wc -l`), so `total_lines`
matches what is actually processed.

### WR-06: `validate_hard_limit` accepts `0`, `0.0`, leading-zero values

**Files modified:** `scripts/setup-guardrails.sh`
**Commit:** 6305845
**Applied fix:** Added a post-regex numeric check
(`awk -v n="$1" 'BEGIN{exit !(n+0 > 0)}'`) so the function rejects non-positive
values. Verified: `0`, `0.0`, `0.00` are now rejected; `5`, `0.5`, `12.34`, and
`007` (→ 7) are accepted, matching the "positive number" contract in the
prompts/errors.

### WR-07: `report.sh` reads usage keys that fixtures/OpenClaw emit differently

**Files modified:** `scripts/report.sh`
**Commit:** cce49c8
**Applied fix:** Per instructions, the fixture was NOT changed to mask the
mismatch; instead the consumer's jq extraction is now tolerant of both observed
spellings — camelCase (`input`/`output`/`cacheRead`/`cacheWrite`/`totalTokens`)
and Anthropic snake_case (`input_tokens`/`output_tokens`/
`cache_read_input_tokens`/`cache_creation_input_tokens`, no `totalTokens`).
`total_tokens` is synthesized from the component fields when neither
`totalTokens` nor `total_tokens` is present, so usage in the snake_case form is
no longer silently dropped by the `total_tokens -eq 0` skip. Verified both
schemas resolve correctly (camelCase → 150 via explicit total; snake_case →
sum 165).
**Requires human verification:** the canonical production OpenClaw usage schema
is not documented in the repo. The reporter is now tolerant of both forms, but
the maintainer should confirm which spelling production JSONL actually uses and
whether cache tokens should be included in `total_tokens` (this fix sums them
into the synthesized total when no explicit total is provided).

---

_Fixed: 2026-06-03_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
