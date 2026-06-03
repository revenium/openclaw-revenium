---
phase: 04-task-metering-attribution
reviewed: 2026-06-03T00:00:00Z
depth: standard
files_reviewed: 15
files_reviewed_list:
  - SKILL.md
  - references/task-classification.md
  - scripts/common.sh
  - scripts/cron.sh
  - scripts/get-root-session-id.py
  - scripts/post-install.sh
  - scripts/report.sh
  - scripts/setup-guardrails.sh
  - scripts/write-marker.sh
  - task-taxonomy.json
  - tests/stub-revenium.sh
  - tests/test_get_root_session_id.py
  - tests/test_report_argv.sh
  - tests/test_setup_guardrails_argv.sh
  - tests/test_write_marker.sh
findings:
  critical: 2
  warning: 7
  info: 4
  total: 13
status: issues_found
---

# Phase 4: Code Review Report

**Reviewed:** 2026-06-03
**Depth:** standard
**Files Reviewed:** 15
**Status:** issues_found

## Summary

Reviewed the Phase 4 task-metering / attribution implementation: bash reporter
(`report.sh`), the marker writer (`write-marker.sh`), the root-session resolver
(`get-root-session-id.py` + `common.sh` wrapper), the guardrail-rule setup
(`setup-guardrails.sh`), the cron runner (`cron.sh`), `post-install.sh`, the
taxonomy JSON, the SKILL/reference markdown, and the test suite.

The codebase is generally careful — it has an explicit "env-passing heredoc"
discipline (T-04-09) to keep untrusted bytes out of interpolated `python3`
strings, atomic temp-then-rename writes, `flock`/`mkdir` mutual exclusion, a
path-traversal guard in `write-marker.sh`, and 64-char log-injection truncation.
However, two correctness/security defects undercut the metering pipeline:

1. **`report.sh` interpolates untrusted JSONL timestamps directly into a
   `python3 -c` string** — a code-injection vector that violates the project's
   own env-passing rule (CR-01).
2. **`report.sh` advances the per-session line offset unconditionally even when
   a completion fails to ship**, silently and permanently dropping metering
   events for any transaction that fails to post (CR-02). For a billing/budget
   product, dropped usage is a data-integrity defect.

Several warnings concern correlation fragility (timestamp tie-breaking, marker
attribution by mtime), a temp-file leak from overwriting `trap EXIT`, and
`grep` treating message IDs as regexes.

No structural-findings block was supplied with this review, so the
`## Structural Findings (fallow)` section is omitted.

## Critical Issues

### CR-01: Code injection via untrusted session timestamps in `python3 -c`

**File:** `scripts/report.sh:487-502` (also `:178-185`, `:191-204`)
**Issue:**
The duration computation interpolates session-derived timestamps straight into
an inline Python program:

```bash
duration_ms=$(python3 -c "
...
t1 = parse_ts('${request_time}')
t2 = parse_ts('${timestamp}')
...
")
```

`${timestamp}` and `${request_time}` come from the session JSONL
(`.timestamp` / parent `.timestamp`), which is written by OpenClaw agents,
subagents, and any process able to write under
`~/.openclaw/agents/main/sessions/`. A timestamp value containing a single
quote, newline, or `'); <python> #` breaks out of the string literal and
executes arbitrary Python inside the metering cron. This is exactly the
class of bug the codebase elsewhere prevents with the documented env-passing
heredoc pattern (T-04-09) — this call site simply does not follow it.

The same direct-interpolation pattern appears in `get_offset` (`d.get('${sid}', 0)`)
and `set_offset` (`d['${sid}'] = int('${count}')`), where `${sid}` is a session
filename. Filenames are more constrained than timestamps, but the injection
class is identical and should be closed at the same time.

Even when injection only mangles the program, the `2>/dev/null || echo 0`
guard masks it as a silent `duration_ms=0`, so the corruption is invisible.

**Fix:** Pass the values through the environment to a quoted heredoc, matching
the project's existing pattern (e.g. `write_rule_ids_to_config`):

```bash
duration_ms=$(REQ_TS="${request_time}" RESP_TS="${timestamp}" python3 - <<'PY' 2>/dev/null || echo 0
import os
from datetime import datetime, timezone
def parse_ts(s):
    try: return datetime.fromisoformat(s.replace('Z', '+00:00'))
    except Exception: pass
    for fmt in ('%Y-%m-%dT%H:%M:%S.%fZ', '%Y-%m-%dT%H:%M:%SZ'):
        try: return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except Exception: pass
    return None
t1 = parse_ts(os.environ['REQ_TS']); t2 = parse_ts(os.environ['RESP_TS'])
print(max(0, int((t2 - t1).total_seconds() * 1000)) if t1 and t2 else 0)
PY
)
```

Apply the same env-passing conversion to `get_offset`/`set_offset` (`SID`/`COUNT`
via env).

### CR-02: Per-session offset advances even when completions fail to ship — silent metering data loss

**File:** `scripts/report.sh:578-604`
**Issue:**
At the end of `process_session`, the offset is persisted unconditionally:

```bash
  done < <(tail -n +$((offset + 1)) "${session_file}")
  ...
  set_offset "${session_id}" "${total_lines}"
```

A transaction is only recorded in the ledger on a *successful* post
(`echo "TX:${tx_id}" >> "${LEDGER_FILE}"` runs inside the `if post_to_revenium ...; then` success branch at line 591). When `post_to_revenium` fails
(network outage, API 5xx, transient auth failure — all expected and explicitly
logged at line 295), the tx is **not** ledgered, yet the offset still jumps to
`total_lines`. On the next tick, `tail -n +$((offset+1))` skips those lines
entirely, so the failed completions are never retried and are permanently lost.
The ledger dedup only protects lines that get re-read; advancing the offset
past them removes that protection. For a budget/billing product this is a
data-integrity defect: usage that should be metered silently disappears whenever
the API is briefly unreachable.

**Fix:** Only advance the offset to the high-water mark of *successfully
handled* lines, or do not advance past any line whose tx failed to post. A
simple correct approach: track the line index of the first failure and persist
`min(failure_index, total_lines)`; or decouple offsets from delivery and rely
solely on the ledger for dedup (drop the offset-skip, accept the re-scan cost).
Minimal patch — skip the offset bump when there were failures:

```bash
  if [[ "${failed_count}" -eq 0 ]]; then
    set_offset "${session_id}" "${total_lines}"
  else
    warn "Session ${session_id}: ${failed_count} failures — not advancing offset (will retry)"
  fi
```

(Re-processing succeeded lines is safe because the ledger dedups them.)

## Warnings

### WR-01: `trap ... EXIT` overwrites prior trap — temp files leak across sessions

**File:** `scripts/report.sh:350` and `scripts/report.sh:377`
**Issue:**
`process_session` installs two single-command EXIT traps:

```bash
trap "rm -f '${markers_cache_file}'" EXIT          # line 350
...
trap "rm -f '${msg_meta_file}' '${user_msgs_file}'" EXIT  # line 377
```

The second `trap` **replaces** the first, so `markers_cache_file` is never
cleaned up. Worse, because `process_session` runs in a loop over every session
file, each iteration overwrites the EXIT trap with the current iteration's
paths. Only the final session's `rv-meta`/`rv-umsg` temp files are removed at
process exit; every prior session's three temp files (`rv-markers`, `rv-meta`,
`rv-umsg`) leak into `${TMPDIR:-/tmp}` and accumulate every minute under cron.

**Fix:** Clean per-iteration at the end of `process_session` instead of relying
on a single EXIT trap, e.g.:

```bash
rm -f "${markers_cache_file}" "${msg_meta_file}" "${user_msgs_file}"
```

placed at the end of the function (and on the early-return path at line 358–360),
or accumulate all temp paths into one trap that is additive across iterations.

### WR-02: Timestamp tie at equal wall-clock instant drops the marker (lexicographic format mismatch)

**File:** `scripts/report.sh:450-471`; markers from `scripts/write-marker.sh:116`
**Issue:**
Markers are written with second precision and a `Z` suffix
(`%Y-%m-%dT%H:%M:%SZ` → `2026-01-01T10:06:00Z`), while completion timestamps in
the JSONL carry milliseconds (`2026-01-01T10:06:00.000Z`). The correlation does
a lexicographic `if ts <= cts`. When a marker and a completion share the same
second, the strings are `...00Z` vs `...00.000Z`; comparing char-by-char, the
marker's `Z` (0x5A) is greater than the completion's `.` (0x2E), so
`ts <= cts` is **false** and the marker that genuinely precedes (or coincides
with) the completion is excluded — the completion falls back to `unclassified`.
This is a real edge case for fast turns where the marker write and the
completion land in the same second.

**Fix:** Normalize both sides to a common parsed form before comparing instead
of comparing raw strings — parse each `ts`/`cts` to a `datetime` (the script
already has `parse_ts` logic) and compare those, or strip sub-second precision
from the completion ts before the lexicographic compare.

### WR-03: Marker attributed to newest-mtime session, not the agent's own session

**File:** `scripts/write-marker.sh:94-104`; consumed by `scripts/report.sh:321`
**Issue:**
`write-marker.sh` resolves the "current" session as the newest-mtime non-cron
`*.jsonl` in `SESSIONS_DIR`, then writes the marker to
`markers/<that-sid>.jsonl`. `report.sh` correlates markers strictly within the
same session id (`${MARKERS_DIR}/${session_id}.jsonl`). If any other session
file has a more recent mtime at marker-write time — concurrent sessions, a
subagent session, or a cron-session that escaped the `sessions.json` filter —
the marker is filed under the wrong session and is never correlated to the
completion it was meant to classify, silently degrading attribution to
`unclassified`. The fallback at line 98-101 (use newest of *all* files,
including cron) widens this when the non-cron list is empty.

**Fix:** Pass the actual session id to `write-marker.sh` (the caller knows it)
rather than inferring it by mtime; or, at minimum, prefer the session whose
JSONL most recently *appended an assistant completion* rather than raw mtime,
and never fall back to including cron sessions.

### WR-04: `meta_lookup`/`user_msg_lookup` treat message IDs as regexes

**File:** `scripts/report.sh:391-398`
**Issue:**
```bash
meta_lookup()    { grep "^${1}\t" "${msg_meta_file}" ... }
user_msg_lookup(){ grep "^${1}\t" "${user_msgs_file}" ... }
```
The message ID `${1}` (from `.id` / `.parentId` in the JSONL) is used as an
unescaped basic-regex. An ID containing regex metacharacters (`.`, `[`, `*`,
`\`, `+`) matches more (or fewer) rows than intended, corrupting parent-timestamp
lookups, the trace-id walk, and the duration computation. IDs are UUID/`msg…`
in practice so this is robustness rather than an exploit, but it is incorrect.

**Fix:** Use a fixed-string match anchored to the field boundary:
`grep -F -- "${1}$(printf '\t')"` is awkward with `-F` plus `^`; prefer `awk`:

```bash
meta_lookup() { awk -F'\t' -v id="$1" -v f="$2" '$1==id{print $f; exit}' "${msg_meta_file}"; }
```

### WR-05: Offset off-by-one when a session JSONL line lacks a trailing newline

**File:** `scripts/report.sh:355-360, 597, 604`
**Issue:**
`total_lines=$(wc -l < "${session_file}")` undercounts by one when the file's
last line has no trailing newline (`wc -l` counts newline characters). The
`while read` loop still processes the unterminated final line, but `set_offset`
records the undercounted `total_lines`. On the next tick with the same content,
`offset >= total_lines` triggers the early return — acceptable. But once a new
line is appended (making the previously-unterminated line now terminated),
`tail -n +$((offset+1))` re-yields a previously processed line. Correctness is
currently preserved only because the ledger dedups by `TX:`; the offset
arithmetic itself is wrong and brittle (and interacts badly with CR-02 if you
change offset semantics).

**Fix:** Count lines consistently with how they are read, e.g.
`total_lines=$(grep -c '' "${session_file}")` (counts the final unterminated
line) or use `awk 'END{print NR}'`, so `total_lines` matches what `tail`/`read`
actually consume.

### WR-06: `validate_hard_limit` accepts `0`, `0.0`, and leading-zero values despite "positive number" contract

**File:** `scripts/setup-guardrails.sh:157-159` (used at `:468`, `:606`, `:762`)
**Issue:**
```bash
validate_hard_limit() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
```
The regex accepts `0`, `0.00`, and `007`, but the prompts/errors promise a
"positive number" (lines 469, 609, 765). A `0` hard limit creates a budget rule
whose hard limit is zero — `compute_warn_threshold` then yields `0`, producing a
rule that may block immediately or behave nonsensically. Zero / all-zero input
should be rejected.

**Fix:** Reject non-positive values, e.g. add a post-regex numeric check:
```bash
validate_hard_limit() {
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  awk -v n="$1" 'BEGIN{exit !(n+0 > 0)}'
}
```

### WR-07: `report.sh` reads `cacheRead`/`cacheWrite` keys that fixtures and OpenClaw emit differently

**File:** `scripts/report.sh:437-438` vs fixture
`tests/fixtures/sessions/c3d4e5f6-...jsonl`
**Issue:**
`report.sh` extracts `.message.usage.cacheRead` and `.message.usage.cacheWrite`,
and `.message.usage.input` / `.output` / `.totalTokens`. The plain-session
fixture, however, uses `input_tokens` / `output_tokens` /
`cache_creation_input_tokens` / `cache_read_input_tokens` and has no
`totalTokens`. Under the real key set in that fixture, every usage field would
default to `0`, `total_tokens` would be `0`, and the line would be silently
skipped at line 569 (`total_tokens -eq 0`). Either the fixture or the reporter
is using the wrong key schema; one of them is wrong, and if production JSONL
ever uses the `*_tokens` form, all usage is dropped. The `test_report_argv.sh`
fixtures use the `input/output/totalTokens` form, so the discrepancy is not
caught by tests.

**Fix:** Confirm the actual OpenClaw usage schema and make the jq extraction
tolerant of both spellings (e.g.
`.message.usage.input // .message.usage.input_tokens // 0`), and align the
`get-root-session-id` fixture with the schema the reporter expects.

## Info

### IN-01: Revenium credentials written in plaintext into `openclaw.json`

**File:** `scripts/post-install.sh:373-385`
**Issue:** API key, team/tenant/owner IDs are injected as plaintext
`docker.env` values in `openclaw.json`. This is the documented design (the
sandbox blocks `~/.config` binds), but the resulting file holds long-lived
secrets in cleartext with whatever umask created it. Consider documenting the
expected file mode (0600) and/or chmod-ing `openclaw.json` after write.

### IN-02: `${OFFSETS_FILE}` / `${CONFIG_FILE}` paths interpolated into inline Python

**File:** `scripts/report.sh:118, 180, 191`
**Issue:** Path constants are interpolated into `python3 -c` strings. They are
not untrusted, but a home directory containing a `'` would break the program.
Folding these into the CR-01 env-passing conversion removes the foot-gun
entirely.

### IN-03: Empty `--description ""` passed to rule create

**File:** `scripts/setup-guardrails.sh:285, 305`
**Issue:** An explicit empty `--description ""` is sent on every rule create. If
the CLI ever rejects empty descriptions this becomes a silent failure. Harmless
today; consider omitting the flag when empty.

### IN-04: `get_root_session_id` strips only the last `:`-segment of `childSessionKey`

**File:** `scripts/get-root-session-id.py:83`
**Issue:** `ck.rsplit(":", 1)[-1]` keeps the UUID suffix of
`agent:main:subagent:<uuid>`. This assumes the child key always ends in a bare
UUID with no further `:`-delimited suffix. If OpenClaw ever appends a run
qualifier (e.g. `...:<uuid>:run-1`), the reverse-map key would be wrong and the
walk silently fails-open to the input sid. Low risk given current key format;
worth a defensive comment or an explicit `subagent:` prefix strip.

---

_Reviewed: 2026-06-03_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
