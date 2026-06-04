---
phase: 10-tool-registry-tool-event-metering
reviewed: 2026-06-04T00:00:00Z
depth: standard
files_reviewed: 5
files_reviewed_list:
  - scripts/common.sh
  - scripts/report.sh
  - tests/stub-revenium.sh
  - tests/test_report_argv.sh
  - tests/test_report_tool_argv.sh
findings:
  critical: 2
  warning: 5
  info: 3
  total: 10
status: issues_found
---

# Phase 10: Code Review Report

**Reviewed:** 2026-06-04T00:00:00Z
**Depth:** standard
**Files Reviewed:** 5
**Status:** issues_found

## Summary

Reviewed the Phase 10 tool-registry and tool-event metering implementation in
`scripts/report.sh` (helpers `_register_tool`, `_meter_tool_event`, the toolCall
scan loop, and the `TOOLS_CLI_CAPABLE` probe), plus the shared constants in
`scripts/common.sh` and the three test/stub files.

The argv-array discipline is sound — every `revenium` invocation builds a bash
array and never `eval`s or string-interpolates untrusted session data into a
command string, so classic command/argv injection is avoided. The fail-open
contract (return 0 on all paths, never touch `failed_count`/`reported_count`,
gate everything on `TOOLS_CLI_CAPABLE`) is correctly implemented in the tool
helpers.

However, the **dedup/idempotency layer for both tool ledgers is broken**: both
helpers use a non-anchored `grep -qF` substring match against ledger keys that
are themselves prefixes of one another. This silently drops registrations and
tool-events whenever one tool-id or toolCall-id is a prefix of another — the two
BLOCKER findings below. There is also a row-parsing defect where multi-line tool
error text corrupts the scan-loop's TSV stream. The rest of the findings are
robustness and consistency issues.

## Critical Issues

### CR-01: Tool-registry dedup uses non-anchored substring grep — prefix collision drops registrations

**File:** `scripts/report.sh:253` (`_register_tool`)
**Issue:**
The registry idempotency check is:
```bash
if grep -qF "TOOL:${tool_id}" "${TOOL_REGISTRY_LEDGER_FILE}" 2>/dev/null; then
  return 0  # already registered — idempotent skip
fi
```
This is an **unanchored substring** match. Ledger lines are written as
`TOOL:<tool_id>:<unix_ts>` (line 274). Because the search string lacks both a
leading `^` anchor and a trailing `:` delimiter, any tool whose `tool_id` is a
**prefix** of an already-registered tool collides and is wrongly treated as
already registered:

```
$ printf 'TOOL:read-file:123.456\n' > t.ledger
$ grep -qF "TOOL:read" t.ledger && echo COLLISION
COLLISION   # "read" is skipped because "read-file" is already in the ledger
```

Concretely: if `read-file` (→ `read-file`) is registered first, then on the same
or a later tick the built-in `read` tool (→ `read`) will never be registered with
Revenium, because `grep -F "TOOL:read"` matches the `TOOL:read-file:...` line.
The collision is asymmetric and order-dependent, so it is also non-deterministic
across sessions. Built-in OpenClaw tool names (`read`, `write`, `bash`,
`web_fetch`→`web-fetch`, etc.) and MCP names share prefixes freely, so this is
not a theoretical edge case.

Note every *other* ledger in this same file uses an anchored, delimited pattern
(`grep -q "^TX:${tx_id}$"` at line 1033; `grep -q "^JOB:${id}:created:"` at line
905), confirming the correct idiom is known and this is a regression unique to
the Phase 10 helpers.

**Fix:** Anchor the match and include the trailing delimiter so the whole key
field is matched exactly:
```bash
if grep -q "^TOOL:${tool_id}:" "${TOOL_REGISTRY_LEDGER_FILE}" 2>/dev/null; then
  return 0
fi
```
(If `tool_id` can contain regex metacharacters after normalization, prefer
`grep -qF "TOOL:${tool_id}:"` combined with a leading-anchor strategy, or match
the full line; normalization lowercases and maps `_`/`__` to `-`, so a fixed
`^TOOL:...:` BRE is safe in practice. Confirm normalize output charset.)

---

### CR-02: Tool-event dedup uses non-anchored substring grep — prefix collision drops tool-events (double-bill risk inverted: under-bill)

**File:** `scripts/report.sh:302` (`_meter_tool_event`)
**Issue:**
The tool-event idempotency check is:
```bash
local ledger_key="TOOLEV:${toolcall_id}"
if grep -qF "${ledger_key}" "${TOOL_EVENTS_LEDGER_FILE}" 2>/dev/null; then
  return 0  # already metered — idempotent skip
fi
```
Same defect as CR-01: unanchored substring match against ledger lines that are
exactly `TOOLEV:<toolcall_id>`. A toolCall id that is a **prefix** of a
previously-metered id is wrongly skipped:

```
$ printf 'TOOLEV:toolu_abc01\n' > te.ledger
$ grep -qF "TOOLEV:toolu_abc0" te.ledger && echo COLLISION
COLLISION
```

Anthropic/Bedrock toolCall ids (`toolu_...`) are variable-length and not
guaranteed to be non-prefix of one another within a session. When a shorter id
is a prefix of a longer already-ledgered id, the shorter call's tool-event is
silently dropped (under-metering). Because the toolCall scan loop re-scans the
*entire* session file every tick and relies solely on this ledger for dedup
(see WR-01), the prefix collision is the primary correctness gate here and it is
unsound.

**Fix:** Anchor both ends so the full key line is matched exactly:
```bash
if grep -q "^TOOLEV:${toolcall_id}$" "${TOOL_EVENTS_LEDGER_FILE}" 2>/dev/null; then
  return 0
fi
```
Mirror the existing `^TX:${tx_id}$` pattern used for the completion ledger at
line 1033.

## Warnings

### WR-01: toolCall scan loop re-scans the entire session file every tick (full-file, offset-ignored)

**File:** `scripts/report.sh:1124-1201`
**Issue:**
Unlike the completion path, which honors `offset`/`total_lines` and only reads
`tail -n +$((offset + 1))` (line 1110), the tool scan loop runs the Python
extractor over the **whole** `session_file` (`SESSION_FILE="${session_file}"`,
line 1128) on every tick where there is any new completion work. Idempotency is
therefore *entirely* dependent on the two tool ledgers — which are broken per
CR-01/CR-02. Even after those are fixed, every tick re-parses the full session
JSONL and re-greps the ledger once per historical toolCall, which scales with
total session size rather than new lines. This is acceptable only if the ledger
dedup is exact; given CR-01/CR-02 it currently is not.

**Fix:** After fixing CR-01/CR-02, this is tolerable for correctness. For
robustness, consider scoping the scan to the same `tail -n +$((offset+1))` window
the completion loop uses, or document explicitly that the tool ledgers are the
sole dedup authority and must remain exact-match.

### WR-02: Multi-line tool error text corrupts the TSV scan stream

**File:** `scripts/report.sh:1167` (python) and `1189` (bash read)
**Issue:**
The Python extractor truncates tool-result error text to 256 chars but does not
strip newlines or tabs:
```python
err_text = c.get('text', '')[:256]
```
The bash consumer reads this as tab-delimited, one row per line:
```bash
while IFS=$'\t' read -r tc_id tool_name parent_ts duration_ms is_error error_msg; do
```
If a tool error message contains a newline (common for stack traces / multi-line
errors), the row is split: the text after the first newline becomes a spurious
"next line" whose first field lands in `tc_id`. That value is non-empty, so the
`[[ -z "${tc_id}" ]] && continue` guard (line 1190) does **not** skip it, and the
loop then calls `normalize_tool_id`/`classify_tool_type`/`_register_tool`/
`_meter_tool_event` on garbage — emitting a bogus tool registration and
tool-event (with a `TOOLEV:<garbage>` ledger entry). An embedded tab similarly
shifts field alignment, corrupting `duration_ms`/`is_error`. This is attacker-
or content-influenced data from `toolResult.content[].text`.

**Fix:** Sanitize the field in Python before emitting the TSV row, e.g.:
```python
err_text = c.get('text', '')[:256].replace('\t', ' ').replace('\n', ' ').replace('\r', ' ')
```
Apply the same to `tc['name']` (tool names should be safe but defense-in-depth)
before the `print('{}\t{}...'`. The codebase already does exactly this kind of
delimiter sanitization for `agentic_job_id` at lines 494-495.

### WR-03: `_register_tool` registry ledger entry is written even on local exit-0 that may not be a real success path; and registry never re-tries genuine failures

**File:** `scripts/report.sh:262-281`
**Issue:**
Two coupled robustness gaps:
1. On registration failure (`reg_success=false`), the code warns and returns 0
   **without** writing the ledger — correct for fail-open, but it means a tool
   that genuinely failed to register (transient 500) will be retried every tick
   *and*, because tool-event emission proceeds regardless (intended), Revenium
   may receive tool-events referencing a `--tool-id` that was never registered.
   That is the documented fail-open intent, but there is no bound or backoff, so
   a permanently-failing registration produces a `tools create` call on every
   single tick forever. Confirm Revenium tolerates tool-events for unregistered
   tool-ids (RESEARCH Pitfall — HUMAN VERIFY).
2. `reg_exit` is referenced in the failure `warn` (line 279) but when the 409
   backstop path sets `reg_success=true`, `reg_exit` is the non-zero CLI exit;
   that is fine. No bug, but the success log does not distinguish "created" from
   "409 already-existed", which complicates ops triage.

**Fix:** Acceptable as fail-open, but add a negative-cache or per-tick attempt
guard so a hard-failing `tools create` is not re-issued on every cron tick, and
log the 409 path distinctly.

### WR-04: `tool_scan_tmp` uses bare `mktemp` and is not registered with the session cleanup trap

**File:** `scripts/report.sh:1126, 1200`
**Issue:**
```bash
tool_scan_tmp=$(mktemp)
```
Every other temp file in `process_session` uses the
`mktemp "${TMPDIR:-/tmp}/rv-*.XXXXXX"` convention and is cleaned via
`_cleanup_session_tmp` (lines 523-527). `tool_scan_tmp` is created with a bare
`mktemp` (no labeled template) and is removed only by the explicit `rm -f` at
line 1200. The file-level comment (lines 518-521) explicitly warns that temp
files must be cleaned "on every return path" because the function is invoked
every tick under cron. The tool block has no early `return`, so today it does not
leak — but it is fragile: any future `return`/error between line 1126 and 1200
(or a fix that adds one) leaks one temp file per tick.

**Fix:** Either add `tool_scan_tmp` to `_cleanup_session_tmp`'s `rm -f` list and
declare it alongside the other temp vars, or at minimum use the labeled template
for discoverability:
```bash
tool_scan_tmp=$(mktemp "${TMPDIR:-/tmp}/rv-tools.XXXXXX")
```

### WR-05: `normalize_tool_id` fallback can produce a tool_id inconsistent with the registered one

**File:** `scripts/report.sh:219-225`
**Issue:**
```bash
TOOL_NAME="${normalized}" python3 -c "...lower()..." 2>/dev/null \
  || printf '%s' "${normalized}"
```
When `python3` is present, the id is lowercased; when the python call fails (or
python3 is absent — plausible on the minimal cron PATH this project repeatedly
guards against), the fallback returns the **non-lowercased** `normalized`. So the
same raw tool name yields different `tool_id` values depending on python
availability at the moment of the call. Because the registry ledger key and the
`meter tool-event --tool-id` both derive from this, an inconsistent fallback
produces a mismatch between the registered tool-id and the metered tool-id, and
duplicate registrations (`Read` vs `read`) across ticks where python flapped.
This also undermines the dedup ledger keys even after CR-01/CR-02 are fixed.

**Fix:** Make the fallback deterministic and case-consistent without python,
using bash parameter expansion (Bash 4+) or `tr`:
```bash
normalized="$(printf '%s' "${normalized}" | tr '[:upper:]' '[:lower:]')"
printf '%s' "${normalized}"
```
The header comment claims "Bash 3.2 safe" as the reason for using python; `tr`
is equally Bash-3.2-safe and removes the python dependency entirely.

## Info

### IN-01: `_meter_tool_event` does not validate `duration_ms` / `is_error` shapes from the TSV

**File:** `scripts/report.sh:1196-1197, 306-319`
**Issue:** `duration_ms` and `is_error` flow from the Python TSV straight into
the argv array. Python guarantees `duration_ms` is an int and `is_error` is the
literal `"true"`/`"false"`, so this is safe today — but the contract is implicit.
If WR-02 corrupts field alignment, `duration_ms` could receive non-numeric data
that is then passed to `--duration-ms`. Fixing WR-02 removes the practical risk.
**Fix:** Optionally assert `[[ "${duration_ms}" =~ ^[0-9]+$ ]] || duration_ms=0`
before the call as defense-in-depth.

### IN-02: Duplicated constant blocks between `common.sh` and `report.sh` can drift

**File:** `scripts/common.sh:73-74` vs `scripts/report.sh:35-36`
**Issue:** `TOOL_REGISTRY_LEDGER_FILE` and `TOOL_EVENTS_LEDGER_FILE` (and several
other path constants) are defined independently in both files. `report.sh` does
not source `common.sh`, so the two definitions must be kept in sync manually. The
comment at `common.sh:62` already flags this hazard for `JOBS_LEDGER_FILE`
("must stay in sync"). One subtle drift already exists: `common.sh:64` makes
`JOBS_LEDGER_FILE` honor `REVENIUM_JOBS_LEDGER_FILE` and so does `report.sh:34`,
but the two tool ledgers have **no** env override in either file — fine, just
note the maintenance coupling.
**Fix:** Consider having `report.sh` source `common.sh` for path constants, or
add a test asserting the constants match across files.

### IN-03: Test asserts `--tool-id read` "somewhere in argv" — cannot distinguish registry from tool-event

**File:** `tests/test_report_tool_argv.sh:205-209`
**Issue:** The TOOLEV-02 assertion reuses the same `argv_vals "--tool-id" | grep
"^read$"` check already used for TOOLEV-01 (line 178), with a comment
acknowledging both `tools create` and `meter tool-event` pass `--tool-id`. The
test therefore does not actually prove a `meter tool-event` carried `--tool-id`
— a regression that emitted `--tool-id` only on `tools create` would still pass
this specific assertion. The adjacent `--duration-ms`/`--success` assertions do
cover tool-event, so coverage is not zero, but this assertion is weaker than its
label implies.
**Fix:** Assert `--tool-id read` appears within a token window following a
`meter`/`tool-event` adjacency, or count occurrences and require >= 2 (registry +
event).

---

_Reviewed: 2026-06-04T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
