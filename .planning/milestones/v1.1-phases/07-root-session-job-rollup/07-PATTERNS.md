# Phase 7: Root-Session Job Rollup - Pattern Map

**Mapped:** 2026-06-03
**Files analyzed:** 4 (1 modified production file + 3 test/fixture additions)
**Analogs found:** 4 / 4

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `scripts/report.sh` (3 change sites) | service | batch/event-driven | `scripts/report.sh` itself (Phase 6 baseline) + `hermes-report.sh` lines 204-254, 347, 863 | exact (port) |
| `tests/test_report_jobs_argv.sh` (GROUP F/G/H appended) | test | batch | `tests/test_report_jobs_argv.sh` GROUP A-E (lines 104-593) | exact |
| `tests/fixtures/sessions/{ROOT_UUID}.jsonl` (new) | fixture | — | `tests/fixtures/sessions/a1b2c3d4-0001-0001-0001-000000000001.jsonl` | exact |
| `tests/fixtures/sessions/{CHILD_UUID}.jsonl` (new) | fixture | — | `tests/test_report_jobs_argv.sh` SESSION_J1 inline fixture (lines 150-154) | exact |

---

## Pattern Assignments

### CHANGE SITE 1 — `root_aid` Resolution Block (new, in `process_session`)

**Location to insert:** After line 330 (`root_sid="${root_sid:-${session_id}}"`), before line 332 (markers-cache comment).

**Analog A — env-passing heredoc discipline** (`scripts/report.sh` lines 357-401):

```bash
# Existing pattern to copy: env-passing, single-quoted 'PY' delimiter, || true, 2>/dev/null
_MARKER_FILE="${marker_file}" \
_TASKS_CACHE="${markers_cache_file}" \
_JOBS_CACHE="${jobs_cache_file}" \
python3 - <<'PY' 2>/dev/null || true
import json, os, sys
mf = os.environ.get('_MARKER_FILE', '')
...
PY
```

Key rules from this analog (lines 355-360):
- Pass ALL variables via env (`VAR="$val" python3 -`), never `${var}` inside `<<'PY'`
- Single-quoted `'PY'` delimiter prevents any expansion inside the heredoc body
- Suffix with `2>/dev/null || true` so parse errors never abort `process_session`
- Write to temp files or capture output via `$(...)` subshell

**Analog B — Hermes `root_aid` block** (`../hermes-revenium/skills/revenium/scripts/hermes-report.sh` lines 204-254):

```bash
# Phase 22 (JOB-01 / D-02): resolve root_aid ONCE per session for subagent
# agentic-job inheritance. Only meaningful when root_sid != sid (subagent);
local root_aid=""
if [[ "${root_sid}" != "${sid}" ]]; then
  root_aid=$(
    ROOT_SID="${root_sid}" MARKERS_DIR="${MARKERS_DIR}" python3 - <<'PY' 2>/dev/null || true
import json, os
from pathlib import Path
root_sid = os.environ.get('ROOT_SID', '')
markers_dir = os.environ.get('MARKERS_DIR', '')
if not root_sid or not markers_dir:
    pass
else:
    marker_path = Path(markers_dir) / f"{root_sid}.jsonl"
    if marker_path.exists():
        latest_aid = ""
        try:
            with open(marker_path, 'r', encoding='utf-8') as fh:
                for line in fh:
                    line = line.rstrip('\n')
                    if not line:
                        continue
                    try:
                        rec = json.loads(line)
                    except (json.JSONDecodeError, ValueError):
                        continue
                    if not isinstance(rec, dict):
                        continue
                    if rec.get('kind') == 'job':
                        aid = rec.get('agentic_job_id') or ''
                        if isinstance(aid, str) and aid:
                            # Sanitize pipe / newline / colon (parity with WR-01)
                            for _bad in ('|', '\n', '\r', ':'):
                                aid = aid.replace(_bad, '_')
                            latest_aid = aid
            if latest_aid:
                print(latest_aid)
        except OSError:
            pass
PY
  )
  # Strip any trailing newline/whitespace the heredoc emitted.
  root_aid="${root_aid%%$'\n'*}"
fi
```

**OpenClaw adaptation** — Hermes emits only `latest_aid`. Phase 7 must also emit `job_name` and `job_type` (tab-separated on one line) because `post_to_revenium` takes `--agentic-job-name`/`--agentic-job-type` as args 23/24 (report.sh lines 237-238). The adapted print statement and bash tab-split pattern:

```bash
# Inside the Python block, replace the final `print(latest_aid)` with:
if latest_aid:
    latest_name = str(rec.get('job_name', ''))
    latest_type = str(rec.get('job_type', ''))
    print(f"{latest_aid}\t{latest_name}\t{latest_type}")

# Bash tab-split (mirrors the job_resolve_result split at report.sh lines 677-684):
local root_aid="" root_job_name="" root_job_type=""
if [[ "${root_sid}" != "${session_id}" ]]; then
  local _root_resolve
  _root_resolve=$(
    ROOT_SID="${root_sid}" MARKERS_DIR="${MARKERS_DIR}" python3 - <<'PY' 2>/dev/null || true
    ...emit latest_aid TAB latest_name TAB latest_type...
PY
  )
  _root_resolve="${_root_resolve%%$'\n'*}"
  if [[ -n "${_root_resolve}" ]]; then
    root_aid="${_root_resolve%%$'\t'*}"
    local _rr2="${_root_resolve#*$'\t'}"
    root_job_name="${_rr2%%$'\t'*}"
    root_job_type="${_rr2#*$'\t'}"
  fi
fi
```

Tab-split precedent: report.sh lines 677-684 (job_resolve_result parse). Variable naming precedent: `_jrest` pattern at lines 678-684.

---

### CHANGE SITE 2 — Subagent Override Block (new, in-loop)

**Location to insert:** After line 690 (closing `fi` of the `job_resolve_result` block, `info "Job correlation:..."`), before line 692 (`# jobs create` comment block).

**Analog — D-01 discriminator** (report.sh lines 328-330):

```bash
# Existing discriminator already live for --agent rollup:
local root_sid
root_sid=$(get_root_session_id "${session_id}")
root_sid="${root_sid:-${session_id}}"
```

The override block reuses the same `root_sid != session_id` comparison. No new detection mechanism.

**Pattern to create:**

```bash
# Phase 7 (JROLL-01/02/03): subagent override — replace same-session correlation
# with root's job values. For root sessions (root_sid == session_id) this block
# is skipped entirely — Phase 6 path is byte-identical.
if [[ "${root_sid}" != "${session_id}" ]]; then
  if [[ -n "${root_aid}" ]]; then
    # Inherit root's job for this completion (JROLL-01 / D-02)
    agentic_job_id="${root_aid}"
    agentic_job_name="${root_job_name}"
    agentic_job_type="${root_job_type}"
  else
    # Race window or orphan subagent — omit entirely (JROLL-02 / D-03 / D-04 / D-07)
    # NEVER substitute the subagent's own orphan id (D-04 safety invariant).
    agentic_job_id=""
    agentic_job_name=""
    agentic_job_type=""
  fi
fi
```

Critical: both branches of the `else` must explicitly zero all three variables. Leaving the `else` branch absent means the Phase 6 jobs_cache_file resolution leaks through for subagents on race — violating D-04 (Pitfall 2 in RESEARCH.md).

---

### CHANGE SITE 3A — Root-Only Gate on `jobs create`

**Location:** Line 699 (`if [[ "${JOBS_CLI_CAPABLE}" == "true" && -n "${agentic_job_id}" ]]; then`).

**Analog — Hermes gate** (`hermes-report.sh` line 347):

```bash
if [[ "${root_sid}" == "${sid}" ]]; then
```

**Analog — existing Phase 6 gate** (report.sh line 699):

```bash
if [[ "${JOBS_CLI_CAPABLE}" == "true" && -n "${agentic_job_id}" ]]; then
```

**Pattern — compound condition** (append `&& "${root_sid}" == "${session_id}"`):

```bash
# BEFORE (Phase 6, line 699):
if [[ "${JOBS_CLI_CAPABLE}" == "true" && -n "${agentic_job_id}" ]]; then

# AFTER (Phase 7 — add root-only gate as third compound term):
if [[ "${JOBS_CLI_CAPABLE}" == "true" && -n "${agentic_job_id}" \
   && "${root_sid}" == "${session_id}" ]]; then
```

The inner block (lines 700-727) is preserved byte-for-byte. Only the outer `if` condition gains the third term.

---

### CHANGE SITE 3B — Root-Only Gate on `jobs outcome`

**Location:** Line 864 (`if [[ "${JOBS_CLI_CAPABLE}" == "true" && -n "${agentic_job_id}" ]]; then`).

**Analog — Hermes gate** (`hermes-report.sh` line 863):

```bash
if [[ "${root_sid}" == "${sid}" ]]; then
```

**Analog — existing Phase 6 gate** (report.sh line 864):

```bash
if [[ "${JOBS_CLI_CAPABLE}" == "true" && -n "${agentic_job_id}" ]]; then
```

**Pattern — same compound condition** (identical to 3A):

```bash
# BEFORE (Phase 6, line 864):
if [[ "${JOBS_CLI_CAPABLE}" == "true" && -n "${agentic_job_id}" ]]; then

# AFTER (Phase 7):
if [[ "${JOBS_CLI_CAPABLE}" == "true" && -n "${agentic_job_id}" \
   && "${root_sid}" == "${session_id}" ]]; then
```

The inner block (lines 865-905) is preserved byte-for-byte.

---

### `tests/test_report_jobs_argv.sh` — GROUP F/G/H Addition

**Analog:** GROUP A structure (test file lines 104-320). Copy the group scaffolding exactly.

**`make_openclaw_home` helper** (lines 48-57) — already creates `${d}/skills/revenium/markers` (line 51). No change needed; root markers file can be written directly.

**Session fixture pattern** (GROUP A, lines 149-154 for J1):

```bash
SESSION_J1="${TMP_HOME_A}/agents/main/sessions/${SID_J1}.jsonl"
cat > "${SESSION_J1}" <<JSONL
{"type":"session","version":3,"id":"${SID_J1}","timestamp":"2026-02-01T10:00:00.000Z","cwd":"/tmp/test"}
{"type":"message","id":"user-J1-001","parentId":"00000000","timestamp":"2026-02-01T10:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Build the feature"}]}}
{"type":"message","id":"comp-J1-001","parentId":"user-J1-001","timestamp":"2026-02-01T10:02:00.000Z","message":{"role":"assistant","model":"claude-sonnet-4-5","stopReason":"end_turn","content":[{"type":"text","text":"Feature implemented"}],"usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":150}}}
JSONL
```

**Marker fixture pattern** (GROUP A, line 157 for J1):

```bash
MARKER_J1="${TMP_HOME_A}/skills/revenium/markers/${SID_J1}.jsonl"
printf '%s\n' '{"kind":"job","ts":"2026-02-01T10:03:00Z","sid":"'"${SID_J1}"'","agentic_job_id":"'"${JOB_ID_J1}"'","job_name":"'"${JOB_NAME_J1}"'","job_type":"'"${JOB_TYPE_J1}"'","status":"SUCCESS","completion_id":"comp-J1-001"}' > "${MARKER_J1}"
```

**sessions_spawn fixture pattern** (existing fixture `a1b2c3d4-0001-0001-0001-000000000001.jsonl`, line 3; adapted for inline heredoc):

```bash
# Root session JSONL with sessions_spawn tool result — required so
# get-root-session-id.py resolves CHILD_UUID -> ROOT_UUID.
# Key: toolName must be literally "sessions_spawn"; details.childSessionKey
# must use "agent:main:subagent:<UUID>" prefix (resolver strips prefix with
# rsplit(":", 1)[-1]).
printf '%s\n' \
  '{"type":"session","version":3,"id":"'"${ROOT_UUID}"'","timestamp":"2026-03-01T10:00:00.000Z","cwd":"/tmp/test"}' \
  '{"type":"message","id":"spawn-msg-f1","parentId":"00000000","timestamp":"2026-03-01T10:01:00.000Z","message":{"role":"toolResult","toolName":"sessions_spawn","content":[{"type":"text","text":"{}"}],"details":{"status":"accepted","childSessionKey":"agent:main:subagent:'"${CHILD_UUID}"'","runId":"run-f001"}}}' \
  > "${TMP_HOME_F}/agents/main/sessions/${ROOT_UUID}.jsonl"
```

**`run_report` helper** (lines 92-102) — use as-is for all groups F/G/H.

**`count_grep` helper** (lines 80-85) — use as-is for all assertions.

**argv assertion pattern** (GROUP A, lines 209-214 — `--agentic-job-id` check):

```bash
# Check that a specific id appears in the captured argv after --agentic-job-id:
all_stamped_ids=$(awk '/^--agentic-job-id$/{getline; print}' "${ARGV_FILE_F}" 2>/dev/null || true)
if echo "${all_stamped_ids}" | grep -qx "${JOB_ID_ROOT_F}"; then
  pass "JROLL-01 F: --agentic-job-id ${JOB_ID_ROOT_F} found (root's id, not child's)"
else
  fail "JROLL-01 F: expected --agentic-job-id ${JOB_ID_ROOT_F}, got '$(echo "${all_stamped_ids}" | tr '\n' '|')'"
fi
```

**Negative assertion pattern** (GROUP B, lines 351-356 — zero ^create$ tokens):

```bash
create_token_count=$(count_grep "^create$" "${ARGV_FILE}")
outcome_token_count=$(count_grep "^outcome$" "${ARGV_FILE}")
if [[ "${create_token_count}" -eq 0 && "${outcome_token_count}" -eq 0 ]]; then
  pass "JROLL-03 G: zero ^create$/^outcome$ tokens (subagent skips both)"
else
  fail "JROLL-03 G: expected 0 tokens, got create=${create_token_count} outcome=${outcome_token_count}"
fi
```

**Cleanup pattern** (end of test file, lines 579-593 — `cleanup_all` trap and summary):

```bash
cleanup_all() {
  rm -rf "${TMP_HOME_A}" "${TMP_HOME_B}" ... "${TMP_HOME_F}" "${TMP_HOME_G}" "${TMP_HOME_H}" 2>/dev/null || true
  cleanup
}
trap cleanup_all EXIT

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
```

The existing `cleanup_all` at lines 579-583 must be extended to include TMP_HOME_F/G/H, or the groups can use their own `rm -rf` calls matching the per-group cleanup at lines 320 and 417.

---

## Shared Patterns

### Env-Passing Python Heredoc (T-04-09)

**Source:** `scripts/report.sh` lines 355-401 (markers-cache block)
**Apply to:** The new `root_aid` resolution heredoc

```bash
# Correct: env-passing, single-quoted delimiter, fail-soft suffix
VAR="${bash_var}" python3 - <<'PY' 2>/dev/null || true
import os
val = os.environ.get('VAR', '')
PY

# WRONG: variable inside heredoc body
python3 - <<'PY'
val = "${bash_var}"   # never interpolated — 'PY' prevents it; stays as literal
PY
```

### Tab-Split Parse of Python Output

**Source:** `scripts/report.sh` lines 677-684 (job_resolve_result parse)
**Apply to:** Bash parse of the `root_aid` heredoc output (root_job_name, root_job_type)

```bash
# Reference split (lines 677-684):
agentic_job_id="${job_resolve_result%%$'\t'*}"
local _jrest="${job_resolve_result#*$'\t'}"
agentic_job_name="${_jrest%%$'\t'*}"
_jrest="${_jrest#*$'\t'}"
agentic_job_type="${_jrest%%$'\t'*}"
```

Use the same `%%$'\t'*` / `#*$'\t'` idiom for the root_aid three-field split.

### Fail-Open / Abort-Prevention Pattern

**Source:** `scripts/report.sh` lines 693-727 (jobs create block) and lines 856-905 (jobs outcome block)
**Apply to:** Root-only gate addition — the inner blocks remain byte-identical

Comment style at line 697:
```bash
# CRITICAL (D-12 / Pitfall 1): own exit locals; NEVER touch failed_count/
# reported_count; NEVER return/exit process_session; NEVER reach CR-02 gate.
```

### Logging Pattern

**Source:** `scripts/report.sh` lines 686-689 (Job correlation log)
**Apply to:** Optional info-log of subagent rollup (parallel to existing `Job correlation:` log)

```bash
# Existing (line 686-689):
local agentic_job_id_log="${agentic_job_id:0:64}"
if [[ -n "${agentic_job_id}" ]]; then
  info "Job correlation: tx_id=${tx_id} agentic_job_id=${agentic_job_id_log}"
fi

# Pattern for subagent rollup log (place after the override block):
if [[ "${root_sid}" != "${session_id}" && -n "${root_aid}" ]]; then
  local root_aid_log="${root_aid:0:64}"
  info "Subagent job rollup: session=${session_id} root=${root_sid} root_aid=${root_aid_log}"
fi
```

### GROUP-Level Test Scaffolding

**Source:** `tests/test_report_jobs_argv.sh` lines 104-320 (GROUP A)
**Apply to:** GROUP F, GROUP G, GROUP H

Structure to copy per group:
1. UUID constants for ROOT and CHILD sessions (lines 116-119 pattern)
2. `TMP_HOME_X=$(make_openclaw_home)` + `ARGV_FILE_X=$(mktemp ...)` (lines 145-146)
3. Root session JSONL with sessions_spawn (new for F/G/H — use fixture format from `a1b2c3d4-0001-0001-0001-000000000001.jsonl`)
4. Child session JSONL with one completion (lines 149-154 pattern)
5. Root markers file with `kind:"job"` line (GROUP A line 157 pattern, in `markers/` subdir)
6. `run_report "${TMP_HOME_X}" "${ARGV_FILE_X}"` (line 182 pattern)
7. Assertions using `count_grep` and `awk '/^--flag$/{getline; print}'` (lines 190-315)
8. `rm -f "${ARGV_FILE_X}"` cleanup (line 320)

---

## Key Line Numbers in `scripts/report.sh` (Confirmed by Direct Read)

| Landmark | Actual Lines | Purpose |
|----------|-------------|---------|
| `get_root_session_id()` wrapper | 50-58 | Called by line 329; no change in Phase 7 |
| `post_to_revenium()` arg 22-24 (job fields) | 236-238 | Positional parameters the call site at 847-848 feeds |
| `--agentic-job-*` append block | 298-302 | Unchanged; Phase 7 feeds root values via call site |
| `root_sid` resolution | 328-330 | **Insertion point for `root_aid` block = after line 330** |
| Temp-file declaration + cleanup | 340-345 | `root_aid` uses no new temp files (bash locals only) |
| Markers-cache Python heredoc | 357-401 | Pattern source for env-passing heredoc discipline |
| `job_resolve_result` Python block | 605-690 | Pattern source for per-completion job resolution |
| Tab-split parse of job result | 677-684 | Pattern source for root_aid tab-split |
| `Job correlation:` info log | 686-689 | Pattern source for subagent rollup log; **insertion point for override block = after line 690** |
| `jobs create` outer gate | 699 | **Modify: add `&& "${root_sid}" == "${session_id}"`** |
| `jobs create` inner block | 700-727 | Byte-identical — no change |
| `post_to_revenium` call site (job args) | 847-848 | Feeds `agentic_job_id/name/type`; Phase 7 override block changes the VALUES, not this line |
| `jobs outcome` outer gate | 864 | **Modify: add `&& "${root_sid}" == "${session_id}"`** |
| `jobs outcome` inner block | 865-905 | Byte-identical — no change |

---

## No Analog Found

All files have close analogs. Nothing in this table.

---

## Metadata

**Analog search scope:** `scripts/`, `tests/`, `tests/fixtures/sessions/`, `../hermes-revenium/skills/revenium/scripts/`
**Files scanned:** 6 (report.sh, hermes-report.sh, test_report_jobs_argv.sh, stub-revenium.sh, a1b2c3d4 fixture, common.sh)
**Pattern extraction date:** 2026-06-03
