---
phase: 05-job-declaration-foundation
reviewed: 2026-06-03T00:00:00Z
depth: standard
files_reviewed: 7
files_reviewed_list:
  - SKILL.md
  - job-taxonomy.json
  - references/job-declaration.md
  - scripts/common.sh
  - scripts/post-install.sh
  - scripts/write-job-marker.sh
  - tests/test_write_job_marker.sh
findings:
  critical: 1
  warning: 5
  info: 4
  total: 10
status: issues_found
---

# Phase 5: Code Review Report

**Reviewed:** 2026-06-03T00:00:00Z
**Depth:** standard
**Files Reviewed:** 7
**Status:** issues_found

## Summary

Reviewed the Phase 5 job-declaration foundation: the new `scripts/write-job-marker.sh`
(untrusted-input JSONL marker writer), its taxonomy (`job-taxonomy.json`), the
`tests/test_write_job_marker.sh` harness, the SKILL.md JOB DECLARATION protocol, the
`references/job-declaration.md` operational detail, plus the touched `common.sh` and
`post-install.sh`.

The security-critical surface of `write-job-marker.sh` is largely sound. The
env-passing heredoc never interpolates shell into the Python body, `sanitize()` runs
before the allowlist check (and the 11 taxonomy labels are confirmed unaffected by
sanitization, so the ordering is safe), `json.dumps(separators=...)` neutralizes raw
field bytes, the sid path-traversal guard rejects non-hex names, and the append uses
`fcntl.LOCK_EX` + `O_APPEND`. All 18 harness tests pass.

The one BLOCKER is a correctness regression against the proven sibling: the writer
computes `completion_id` through its entire session-selection logic — and the WR-03
comment block explicitly states the purpose is to let `report.sh` correlate by exact
id (Approach A) — but never writes `completion_id` into the marker record. The sibling
`write-marker.sh` does (lines 187-188). As written, every job marker silently loses the
exact-id correlation key, degrading report.sh to timestamp-only matching (the exact
fragile attribution path the comment warns about). The remaining findings are a
log-injection gap, dead code, and test-quality concerns.

No structural findings were provided for this review.

## Critical Issues

### CR-01: `completion_id` is computed but never written to the marker record

**File:** `scripts/write-job-marker.sh:197-218`, `229-241`
**Issue:** The script runs the full `last_completion_info()` machinery and the
`with_completion` selection branch specifically to capture `completion_id` (the
top-level `.id` of the most recent assistant completion). The WR-03 comment at
lines 146-156 states the explicit intent: *"capture the .id of the most recent
assistant completion so report.sh can correlate by exact id match (Approach A) before
falling back to timestamp ordering (Approach D)."* But the record built at lines
230-238 never includes `completion_id`, and the value computed at lines 206/211/218 is
discarded.

The proven sibling `scripts/write-marker.sh` does exactly the right thing (lines
183-188): `if completion_id: rec["completion_id"] = completion_id`. The job writer
borrowed every line of the selection logic from the sibling but dropped the one line
that consumes its result.

Consequence: report.sh's Approach-A exact-id correlation can never fire for job
markers. Attribution silently degrades to timestamp ordering — the precise fragile
mechanism the comment block (lines 146-151) warns leads to misfiled markers lost to
`unclassified`. This is a correctness regression, it is invisible at runtime (no error,
all 18 tests still pass because none assert on `completion_id`), and it defeats the
stated design.

**Fix:** Mirror the sibling. After building `rec` (line 238), before the FAILED block:
```python
# Approach-A correlation key for report.sh (mirror write-marker.sh:187-188).
# Omit when unresolvable so report.sh applies the Approach-D timestamp fallback.
if completion_id:
    rec["completion_id"] = completion_id
```
Then add a harness assertion (e.g. seed a session JSONL with an assistant `message`
record carrying a top-level `.id`, run the marker, assert `completion_id` matches).

## Warnings

### WR-01: Log injection via unsanitized `--job-type` into LOG_FILE

**File:** `scripts/write-job-marker.sh:62-63`
**Issue:** `JOB_TYPE_LOG="${JOB_TYPE_ARG:0:64}"` is the documented "log-injection
mitigation," but it only caps length — it does NOT strip newlines or control characters
before passing to `info()`, which appends to `LOG_FILE`. A `--job-type` value containing
an embedded newline (agent-supplied, untrusted) injects forged log lines:
```
$ --job-type $'evil\n[2026-01-01] [ERROR] [revenium] forged entry'
# LOG_FILE receives:
[ts] [INFO ] [revenium] write-job-marker: writing job marker for job_type='evil
[2026-01-01] [ERROR] [revenium] forged entry'
```
The Python `sanitize()` (which strips `\n\r`) runs only inside the heredoc, AFTER this
log line is already written. The header comment at line 27 claims sanitize strips
newlines "before allowlist," but the bash-level log write at line 63 precedes all
sanitization.

**Fix:** Strip CR/LF (and ideally other control chars) before logging, e.g.:
```bash
JOB_TYPE_LOG="${JOB_TYPE_ARG//[$'\n\r']/_}"
JOB_TYPE_LOG="${JOB_TYPE_LOG:0:64}"
```

### WR-02: Validation/sid failures bypass the LOG_FILE logging contract

**File:** `scripts/write-job-marker.sh:74-253` (Python block)
**Issue:** Every Python failure path (`unknown job_type`, `invalid status`, taxonomy
load failure, `unsafe sid`) uses `raise SystemExit(msg)`, which writes `msg` to the
process stderr and exits 1. None of these route through the `error()`/`warn()` helpers,
so they never reach `LOG_FILE`. The bash wrapper only logs the single success-path
`info()` at line 63. SKILL.md and `references/job-declaration.md` describe a
"fail-loud-but-don't-block" contract where errors should be logged; here the
loud-to-LOG_FILE half is missing for the most important failure cases. Under cron-style
`>> LOG_FILE 2>&1` invocation the stderr is captured, but for the documented direct
`bash .../write-job-marker.sh` invocation the diagnostic is lost once the terminal
scrolls.

**Fix:** Either capture the Python exit/stderr in bash and route through `warn()`, or
have the Python block append to the same log file via a small helper. At minimum,
document that Python-side failures only surface on stderr, not LOG_FILE.

### WR-03: sid path-traversal guard accepts degenerate all-hyphen / short-hex names

**File:** `scripts/write-job-marker.sh:221`
**Issue:** `re.fullmatch(r'[0-9a-fA-F-]+|pseudo-[0-9]+', sid)` accepts pathologically
malformed sids such as `----`, `-`, or a single `a`, because the character class
permits any mix of hex and hyphens with no structural constraint. While this blocks
classic traversal (`..`, `/` are excluded) so it is not an exploitable BLOCKER, a
session file literally named `----.jsonl` would be accepted and a marker written to
`markers/----.jsonl`, which can never correlate to a real session. The guard is the
sole gate between an attacker-influenceable filename (a session file dropped into
SESSIONS_DIR) and `os.path.join(markers_dir, f"{sid}.jsonl")`.

**Fix:** Tighten to the actual sid shapes — a UUID or the pseudo form:
```python
if not re.fullmatch(
    r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    r'|pseudo-[0-9]+',
    sid):
    raise SystemExit(f"unsafe sid: {sid!r}")
```
(Relax only if non-UUID real session ids actually occur — verify against
`get-root-session-id.py` / report.sh expectations.)

### WR-04: Test 7 ("flock + O_APPEND") runs sequentially, never exercising concurrency

**File:** `tests/test_write_job_marker.sh:223-241`
**Issue:** The test claims to validate "Two rapid invocations — exactly 2 non-corrupt
lines (flock + O_APPEND)," but the two `run_job_marker` calls are sequential blocking
invocations, not backgrounded. The second never starts until the first fully exits, so
there is zero lock contention and zero interleaving pressure. The test would pass
identically even if `fcntl.flock` were removed entirely. The flock/O_APPEND guarantee
this phase relies on is therefore untested.

**Fix:** Background both (and more) invocations and `wait`:
```bash
for i in $(seq 1 20); do
  run_job_marker --job-id "c-$i" --job-name "j$i" --job-type testing --status SUCCESS >/dev/null 2>&1 &
done
wait
# assert line count == 20 AND every line parses as JSON (no interleaving)
```

### WR-05: Test redirection order `2>&1 >/dev/null` leaks stderr to the console

**File:** `tests/test_write_job_marker.sh:227,232,276,282,289,326,353,382,412` (and
similar `2>&1 >/dev/null` lines)
**Issue:** `2>&1 >/dev/null` is evaluated left-to-right: stderr is first dup'd to the
*current* stdout (the terminal), then stdout is redirected to `/dev/null`. The intent
("discard all output") is not met — stderr still reaches the console. This is why the
test run prints stray `write-job-marker: unknown job_type: ...` lines mid-suite. Harmless
to pass/fail accounting, but noisy and indicates the redirection is not doing what the
author believed.

**Fix:** Use `>/dev/null 2>&1` (redirect stdout first, then point stderr at the same
target) wherever full suppression is intended.

## Info

### IN-01: `openclaw_home` is read from env but never used

**File:** `scripts/write-job-marker.sh:86`
**Issue:** `openclaw_home = os.environ.get('OPENCLAW_HOME', '')` is dead — no subsequent
reference. The `OPENCLAW_HOME=...` passthrough at line 73 exists only to feed this unused
read. Dead code that implies a path dependency the script does not actually have.
**Fix:** Remove line 86 and the `OPENCLAW_HOME="${OPENCLAW_HOME}"` env line (73) if
nothing else needs it, or wire it in if it was meant to anchor SESSIONS_DIR resolution.

### IN-02: `last_completion_ts` helper is dead code

**File:** `scripts/write-job-marker.sh:192-195`
**Issue:** The "backward-compatible helper" `last_completion_ts(fname)` is never called
anywhere in the script (selection uses `last_completion_info` directly at line 201). It
is leftover from the sibling and adds confusion.
**Fix:** Delete lines 192-195.

### IN-03: Tail-window read may misalign on multi-byte UTF-8 / partial first line

**File:** `scripts/write-job-marker.sh:163-168`
**Issue:** `fh.seek(size - window)` can land mid-line and mid-UTF-8-codepoint. The
`decode('utf-8', 'replace')` and per-line `json.loads` try/except correctly tolerate the
garbled leading fragment, so this is not a correctness bug today. Worth a one-line
comment noting the partial-first-line is intentionally discarded so a future maintainer
does not "fix" it by removing the try/except.
**Fix:** Add a comment, or split on the first newline and drop the leading partial
before parsing.

### IN-04: 11-label taxonomy vs SKILL.md/code "11-label" wording vs file count

**File:** `job-taxonomy.json:1-81`, `scripts/common.sh:51`, `SKILL.md:138`
**Issue:** `common.sh:51` and SKILL.md both describe the job taxonomy as "11-label," and
the file does contain exactly 11 labels (feature_development, bug_fix, code_review,
refactoring, research, debugging, testing, documentation, devops, planning,
interrupted). Consistent — no defect. Flagged only to note that `interrupted` is a
terminal/system label the agent is told to mint at arc-cut events, yet the SKILL.md
JOB DECLARATION status flow (SUCCESS/FAILED/CANCELLED) never instructs using
`interrupted` as a `job_type` — verify the cron/`report.sh` side actually emits
`interrupted`, otherwise it is an unreachable label.
**Fix:** Confirm a producer assigns `interrupted`; if none does, document where it is set
(likely cron-side on budget halt) or remove it to avoid a dead taxonomy entry.

---

_Reviewed: 2026-06-03T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
