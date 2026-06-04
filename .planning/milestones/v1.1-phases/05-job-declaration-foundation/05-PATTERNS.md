# Phase 5: Job Declaration Foundation - Pattern Map

**Mapped:** 2026-06-03
**Files analyzed:** 7
**Analogs found:** 6 / 7

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `job-taxonomy.json` | config | — | `task-taxonomy.json` | exact |
| `scripts/write-job-marker.sh` | utility | file-I/O | `scripts/write-marker.sh` | exact |
| `scripts/common.sh` | config | — | `scripts/common.sh` (self) | exact (modify) |
| `scripts/post-install.sh` | config | — | `scripts/post-install.sh` (self) | exact (modify) |
| `SKILL.md` | config | — | `SKILL.md §TASK CLASSIFICATION` (self) | exact (modify) |
| `references/job-declaration.md` | config | — | `references/task-classification.md` | role-match |
| `tests/test_write_job_marker.sh` | test | file-I/O | `tests/test_write_marker.sh` | exact |

---

## Pattern Assignments

### `job-taxonomy.json` (config)

**Analog:** `task-taxonomy.json`

**Shape pattern** (full file, lines 1-60):
```json
{
  "labels": {
    "<snake_case_label>": {
      "description": "...",
      "examples": [
        "...",
        "..."
      ]
    }
  }
}
```

The 11 labels to use are exactly: `feature_development`, `bug_fix`, `code_review`, `refactoring`, `research`, `debugging`, `testing`, `documentation`, `devops`, `planning`, `interrupted`. All are valid snake_case strings. No regex is enforced by the toolchain today — `write-marker.sh` uses allowlist-membership-only validation (`if tt not in labels: raise SystemExit(...)`). The new writer follows the same pattern.

Install path: `${STATE_DIR}/job-taxonomy.json` (i.e., `~/.openclaw/skills/revenium/job-taxonomy.json`). The seeding mechanism is `post-install.sh` (see that file's pattern below).

---

### `scripts/write-job-marker.sh` (utility, file-I/O)

**Analog:** `scripts/write-marker.sh`

**File header + set + source pattern** (lines 1-27):
```bash
#!/usr/bin/env bash
# write-job-marker.sh — Validate job fields and append a kind:"job" marker.
# ...
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"
```

**Arg parsing pattern** (write-marker.sh lines 28-38 — positional; write-job-marker.sh DIVERGES to named flags per D-07):
```bash
# write-marker.sh analog (positional — do NOT copy verbatim):
if [[ $# -lt 1 || -z "${1:-}" ]]; then
  warn "write-marker.sh: usage: write-marker.sh <task_type>"
  exit 1
fi
TASK_TYPE_ARG="$1"
TASK_TYPE_LOG="${TASK_TYPE_ARG:0:64}"
info "write-marker: writing marker for task_type='${TASK_TYPE_LOG}'"
```

**For write-job-marker.sh, replace with named-flag parser (Pattern 4 from RESEARCH.md):**
```bash
JOB_ID_ARG=""
JOB_NAME_ARG=""
JOB_TYPE_ARG=""
STATUS_ARG=""
FAILURE_REASON_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job-id)         JOB_ID_ARG="$2";         shift 2 ;;
    --job-name)       JOB_NAME_ARG="$2";       shift 2 ;;
    --job-type)       JOB_TYPE_ARG="$2";       shift 2 ;;
    --status)         STATUS_ARG="$2";         shift 2 ;;
    --failure-reason) FAILURE_REASON_ARG="$2"; shift 2 ;;
    *) warn "write-job-marker.sh: unknown argument: $1"; exit 1 ;;
  esac
done

# Mandatory-flag bash-level presence check (before Python)
if [[ -z "${JOB_ID_ARG}" || -z "${JOB_NAME_ARG}" || -z "${JOB_TYPE_ARG}" || -z "${STATUS_ARG}" ]]; then
  warn "write-job-marker.sh: missing required flag(s): --job-id, --job-name, --job-type, --status"
  exit 1
fi

# Log-injection mitigation: truncate to 64 chars (mirrors TASK_TYPE_LOG pattern)
JOB_TYPE_LOG="${JOB_TYPE_ARG:0:64}"
info "write-job-marker: writing job marker for job_type='${JOB_TYPE_LOG}'"
```

**Env-passing Python heredoc invocation** (write-marker.sh lines 40-45 — copy and extend):
```bash
# write-marker.sh (lines 40-45):
TASK_TYPE="${TASK_TYPE_ARG}" \
TAXONOMY_FILE="${TAXONOMY_FILE}" \
MARKERS_DIR="${MARKERS_DIR}" \
SESSIONS_DIR="${SESSIONS_DIR}" \
OPENCLAW_HOME="${OPENCLAW_HOME}" \
python3 - <<'PY'
```

**For write-job-marker.sh, pass each named-flag value as its own env var plus the new `JOB_TAXONOMY_FILE`:**
```bash
JOB_ID="${JOB_ID_ARG}" \
JOB_NAME="${JOB_NAME_ARG}" \
JOB_TYPE="${JOB_TYPE_ARG}" \
STATUS="${STATUS_ARG}" \
FAILURE_REASON="${FAILURE_REASON_ARG}" \
JOB_TAXONOMY_FILE="${JOB_TAXONOMY_FILE}" \
MARKERS_DIR="${MARKERS_DIR}" \
SESSIONS_DIR="${SESSIONS_DIR}" \
OPENCLAW_HOME="${OPENCLAW_HOME}" \
python3 - <<'PY'
```

**Python heredoc — read-from-env block** (write-marker.sh lines 46-53):
```python
import json, os, time, fcntl, re, sys

tt          = os.environ['TASK_TYPE']
tax_file    = os.environ['TAXONOMY_FILE']
markers_dir = os.environ['MARKERS_DIR']
sessions_dir = os.environ['SESSIONS_DIR']
openclaw_home = os.environ.get('OPENCLAW_HOME', '')
```

**For write-job-marker.sh, read the new env vars and add the sanitize() function immediately after (NEW — D-09):**
```python
import json, os, time, fcntl, re, sys

job_id_raw       = os.environ['JOB_ID']
job_name_raw     = os.environ['JOB_NAME']
job_type_raw     = os.environ['JOB_TYPE']
status_raw       = os.environ['STATUS']
failure_reason_raw = os.environ.get('FAILURE_REASON', '')
tax_file         = os.environ['JOB_TAXONOMY_FILE']
markers_dir      = os.environ['MARKERS_DIR']
sessions_dir     = os.environ['SESSIONS_DIR']
openclaw_home    = os.environ.get('OPENCLAW_HOME', '')

def sanitize(value, maxlen=256):
    """Replace :, |, newline with _ and cap length."""
    return re.sub(r'[:\|\n\r]', '_', str(value))[:maxlen]

job_id        = sanitize(job_id_raw)
job_name      = sanitize(job_name_raw)
job_type      = sanitize(job_type_raw)   # also validated against allowlist below
status        = sanitize(status_raw)     # also validated against allowlist below
failure_reason = sanitize(failure_reason_raw)
```

**Taxonomy allowlist validation** (write-marker.sh lines 55-64 — copy verbatim, change var names):
```python
# write-marker.sh (lines 55-64):
try:
    with open(tax_file, encoding='utf-8') as fh:
        taxonomy = json.load(fh)
    labels = set(taxonomy.get('labels', {}) if isinstance(taxonomy.get('labels'), dict) else taxonomy.get('labels', []))
except Exception as exc:
    raise SystemExit(f"write-marker: cannot load taxonomy: {exc}")

if tt not in labels:
    raise SystemExit(f"unknown task_type: {tt}")
```

**For write-job-marker.sh (same pattern + status allowlist check added):**
```python
try:
    with open(tax_file, encoding='utf-8') as fh:
        taxonomy = json.load(fh)
    labels = set(taxonomy.get('labels', {}) if isinstance(taxonomy.get('labels'), dict) else taxonomy.get('labels', []))
except Exception as exc:
    raise SystemExit(f"write-job-marker: cannot load job taxonomy: {exc}")

if job_type not in labels:
    raise SystemExit(f"write-job-marker: unknown job_type: {job_type!r}")

VALID_STATUSES = {'SUCCESS', 'FAILED', 'CANCELLED'}
if status not in VALID_STATUSES:
    raise SystemExit(f"write-job-marker: invalid status: {status!r} (must be SUCCESS, FAILED, or CANCELLED)")
```

**Sid resolution block** (write-marker.sh lines 66-169 — copy verbatim):
This is the ~100-line Python block that: loads `sessions.json` to find cron sids, lists `*.jsonl` in `SESSIONS_DIR`, selects the session with the most recent assistant completion (by `timestamp` field), falls back to mtime, falls back to `pseudo-{int(time.time())}`. Copy this block **verbatim** from `scripts/write-marker.sh` lines 66–169. The `completion_id` extraction (lines 108–141 and 150–163) can be included or omitted — it does no harm in the job writer and keeps the sid selection logic intact.

**Path-traversal guard** (write-marker.sh line 172 — copy verbatim):
```python
if not re.fullmatch(r'[0-9a-fA-F-]+|pseudo-[0-9]+', sid):
    raise SystemExit(f"unsafe sid: {sid!r}")
```

**Markers dir creation** (write-marker.sh line 176 — copy verbatim):
```python
os.makedirs(markers_dir, mode=0o700, exist_ok=True)
```

**Record build** (write-marker.sh lines 182-188 — DIVERGES for job markers per D-11, D-12, D-13):
```python
# write-marker.sh (lines 182-198) — task record, NO kind field:
marker_path = os.path.join(markers_dir, f"{sid}.jsonl")
rec = {
    "ts": time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    "task_type": tt
}
if completion_id:
    rec["completion_id"] = completion_id
```

**For write-job-marker.sh (7 mandatory fields + kind + in-record sid + optional failure_reason):**
```python
marker_path = os.path.join(markers_dir, f"{sid}.jsonl")
rec = {
    "kind":           "job",
    "ts":             time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    "sid":            sid,
    "agentic_job_id": job_id,
    "job_name":       job_name,
    "job_type":       job_type,
    "status":         status,
}
# Optional field: only present for FAILED with a non-empty reason (D-13)
if status == "FAILED" and failure_reason:
    rec["failure_reason"] = failure_reason
```

**Atomic append** (write-marker.sh lines 194-196 — copy verbatim):
```python
with open(marker_path, 'ab', buffering=0) as fh:
    fcntl.flock(fh, fcntl.LOCK_EX)
    fh.write((json.dumps(rec, separators=(',', ':')) + '\n').encode('utf-8'))

print(f"job marker written: {marker_path}")
sys.exit(0)
PY
```

---

### `scripts/common.sh` (config — MODIFY)

**Analog:** `scripts/common.sh` lines 50-55 (the existing taxonomy/markers block)

**Existing block to extend** (lines 49-55):
```bash
# Phase 4 path constants (METER-01 / D-07).
# TAXONOMY_FILE: 8-label task vocabulary for write-marker.sh + setup-guardrails.sh.
# MARKERS_DIR: per-session marker JSONL files (appended by write-marker.sh).
# SESSIONS_DIR: OpenClaw agent session JSONL directory (read by resolver + report.sh).
TAXONOMY_FILE="${STATE_DIR}/task-taxonomy.json"
MARKERS_DIR="${STATE_DIR}/markers"
SESSIONS_DIR="${OPENCLAW_HOME}/agents/main/sessions"
```

**Add immediately after `TAXONOMY_FILE` line** (after line 53):
```bash
JOB_TAXONOMY_FILE="${STATE_DIR}/job-taxonomy.json"
```

The comment block above should be updated to mention `JOB_TAXONOMY_FILE` as well. Follow the same `${STATE_DIR}/` prefix convention — `STATE_DIR` is already defined two lines above as `"${OPENCLAW_HOME}/skills/revenium"`.

---

### `scripts/post-install.sh` (config — MODIFY)

**Two insertion points:**

**Insertion 1 — chmod loop** (line 114):
```bash
# Existing (line 114):
for script in cron.sh report.sh common.sh setup-guardrails.sh guardrail-check.sh install-cron.sh uninstall-cron.sh clear-halt.sh post-install.sh write-marker.sh get-root-session-id.py; do
```
Add `write-job-marker.sh` to this list (order within the list does not matter).

**Insertion 2 — taxonomy seeding block** (lines 121-136, existing block):
```bash
# Existing block (lines 121-136):
TAXONOMY_SRC="${SKILL_DIR}/task-taxonomy.json"
TAXONOMY_DST="${SKILL_DIR}/task-taxonomy.json"  # same path (self-contained install)
if [[ ! -f "${TAXONOMY_DST}" ]]; then
  if [[ -f "${TAXONOMY_SRC}" ]]; then
    cp "${TAXONOMY_SRC}" "${TAXONOMY_DST}"
    info "Seeded task-taxonomy.json at ${TAXONOMY_DST}"
  else
    warn "task-taxonomy.json not found at ${TAXONOMY_SRC} — write-marker.sh will fail until it is present"
  fi
else
  info "task-taxonomy.json already present at ${TAXONOMY_DST}"
fi
```

**Add immediately after line 136 (mirror the same structure):**
```bash
# Seed job-taxonomy.json into SKILL_DIR if absent.
JOB_TAXONOMY_SRC="${SKILL_DIR}/job-taxonomy.json"
JOB_TAXONOMY_DST="${SKILL_DIR}/job-taxonomy.json"  # same path (self-contained install)
if [[ ! -f "${JOB_TAXONOMY_DST}" ]]; then
  if [[ -f "${JOB_TAXONOMY_SRC}" ]]; then
    cp "${JOB_TAXONOMY_SRC}" "${JOB_TAXONOMY_DST}"
    info "Seeded job-taxonomy.json at ${JOB_TAXONOMY_DST}"
  else
    warn "job-taxonomy.json not found at ${JOB_TAXONOMY_SRC} — write-job-marker.sh will fail until it is present"
  fi
else
  info "job-taxonomy.json already present at ${JOB_TAXONOMY_DST}"
fi
```

---

### `SKILL.md` (config — MODIFY)

**Analog:** `SKILL.md` lines 63-115 (`## TASK CLASSIFICATION` section)

**Insertion point:** After line 115 (`## Path Resolution` begins at line 116). The guard-first ordering is preserved: HALT CHECK → Guardrail Check Procedure → TASK CLASSIFICATION → **JOB DECLARATION** → Path Resolution.

**Structural model to mirror** (lines 63-115 — full section reproduced for reference):

Section header line (line 63): `## TASK CLASSIFICATION`
Framing line (line 65): `**MANDATORY — NON-NEGOTIABLE. Execute before EVERY yield back to the user on a substantive turn.**`

For `## JOB DECLARATION`, mirror this structure:
1. Section header: `## JOB DECLARATION`
2. Mandatory framing — arc-boundary trigger (not per-turn), reference D-01/D-04
3. `### Trigger (binary — no judgment calls)` — three fire conditions, one skip condition
4. `### Required action` — Step 1: pick job_type from table; Step 2: mint agentic_job_id; Step 3: call write-job-marker.sh
5. 11-label job_type table (labels from `job-taxonomy.json`)
6. Status bar (SUCCESS/FAILED/CANCELLED criteria)
7. failure_reason guidance (FAILED-only)
8. Confirmation/error handling (mirrors write-marker.sh's "marker written:" / non-zero exit pattern)
9. `### Why this matters` subsection
10. Reference to `references/job-declaration.md` for full worked examples

**Status bar framing** (from D-02, adapted from Hermes):
```
- **`SUCCESS`:** positive, checkable evidence established in the session (tests passed, build green,
  question fully answered). "Made the change but could not verify" = CANCELLED, not SUCCESS.
- **`FAILED`:** definitive negative terminal state (the fix didn't fix, build cannot pass, goal
  objectively unachievable). Include `--failure-reason` with a brief plain-text cause.
- **`CANCELLED`:** catch-all and uncertainty-bias default. When in doubt: CANCELLED.
```

**Confirmation/error handling pattern** (mirrors TASK CLASSIFICATION lines 106-108):
```
- **Confirmation:** `job marker written: <path>` — the marker was appended successfully.
- **Non-zero exit or no `job marker written:` output:** protocol error — log the error but do not block your response.
```

---

### `references/job-declaration.md` (config — NEW)

**Analog:** `references/task-classification.md`

**Shape to follow** (task-classification.md lines 1-4):
```markdown
# Task Classification — Operational Detail

This file holds the full operational detail for the `## TASK CLASSIFICATION` step in `SKILL.md`.
Refer here for trigger rules, the `write-marker.sh` invocation, the blocklist, and worked examples.
```

**For job-declaration.md, open with:**
```markdown
# Job Declaration — Operational Detail

This file holds the full operational detail for the `## JOB DECLARATION` step in `SKILL.md`.
Refer here for the arc definition, trigger rules, status bar, worked examples, and the pivot-cancel rule.
```

**Content to include** (ported from Hermes `references/job-declaration.md`, adapted to OpenClaw writer):
- Arc definition (same-arc vs new-arc continuity rule)
- Trigger (3 fire conditions, 1 skip condition)
- Status bar (SUCCESS / FAILED / CANCELLED criteria verbatim from D-02)
- Pivot-cancel rule (D-03)
- Granularity floor note (D-04 — soft guideline, no hard enforcement)
- 4 worked examples using OpenClaw CLI syntax (SUCCESS, CANCELLED-because-unverified, FAILED with failure_reason, pivot-cancel sequence)

**Example CLI invocation format** (from RESEARCH.md §Hermes content to port):
```bash
bash ~/.openclaw/skills/revenium/scripts/write-job-marker.sh \
  --job-id "add-pagination-endpoint-3b1e" \
  --job-name "Add pagination to /api/users endpoint" \
  --job-type "feature_development" \
  --status "SUCCESS"
```

---

### `tests/test_write_job_marker.sh` (test, file-I/O)

**Analog:** `tests/test_write_marker.sh`

**Full harness structure** (lines 1-54 — copy verbatim, adjust for job writer):

```bash
#!/usr/bin/env bash
# test_write_job_marker.sh — Integration tests for write-job-marker.sh (JOBDEC-03, JOBDEC-04)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WRITE_JOB_MARKER="${REPO_ROOT}/scripts/write-job-marker.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
```

**Tmp-tree setup** (lines 28-49 — mirror exactly, adding job taxonomy seed):
```bash
TMP_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-wjm-home.XXXXXX")
TMP_SESSIONS="${TMP_HOME}/agents/main/sessions"
TMP_STATE="${TMP_HOME}/skills/revenium"
TMP_MARKERS="${TMP_STATE}/markers"
TMP_JOB_TAXONOMY="${TMP_STATE}/job-taxonomy.json"

mkdir -p "${TMP_SESSIONS}" "${TMP_STATE}"

# Seed job taxonomy (copy from repo root)
cp "${REPO_ROOT}/job-taxonomy.json" "${TMP_JOB_TAXONOMY}"

# Create a fake interactive session file
FAKE_SID="aabbccdd-0001-0001-0001-000000000001"
FAKE_SESSION="${TMP_SESSIONS}/${FAKE_SID}.jsonl"
echo '{"type":"session","id":"aabbccdd-0001-0001-0001-000000000001","timestamp":"2026-01-01T00:00:00.000Z"}' \
  > "${FAKE_SESSION}"
touch "${FAKE_SESSION}"

cleanup() { rm -rf "${TMP_HOME}"; }
trap cleanup EXIT

run_job_marker() {
  OPENCLAW_HOME="${TMP_HOME}" bash "${WRITE_JOB_MARKER}" "$@"
}
```

**Test cases to implement** (derived from RESEARCH.md §Phase Requirements → Test Map):

| Test # | What it checks | Key assertion |
|--------|----------------|---------------|
| 1 | Valid well-formed call — exits 0 + prints "job marker written:" + file created | `exit_code -eq 0`, `grep "job marker written:"` |
| 2 | Valid call — written record has all 7 mandatory fields + `kind:"job"` + ISO8601 ts | `python3 -c "json.loads(...); assert rec['kind']=='job'; assert all fields present; assert ISO8601 ts"` |
| 3 | Valid call — markers/ dir is mode 0700 | `stat` check (macOS: `stat -f "%Lp"`; Linux: `stat -c "%a"`) |
| 4 | Unknown `job_type` — exits non-zero, no marker appended | `bad_exit -ne 0`, line count unchanged |
| 5 | Invalid `status` value — exits non-zero, no marker appended | same pattern as test 4 |
| 6 | Missing mandatory flag — exits non-zero | `bad_exit -ne 0` |
| 7 | Two rapid invocations — 2 non-corrupt lines (flock + O_APPEND) | `wc -l -eq 2`, both lines valid JSON |
| 8 | `failure_reason` present for FAILED, absent for SUCCESS and CANCELLED | `python3 assert 'failure_reason' in rec` / `assert 'failure_reason' not in rec` |
| 9 | Field with `:` sanitized to `_` in written record | pass `--job-name "foo:bar"`, assert written name is `"foo_bar"` |
| 10 | Field longer than length cap is truncated | pass 300-char string, assert written value is ≤ 256 chars |

**Summary block** (lines 267-272 — copy verbatim):
```bash
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
```

---

## Shared Patterns

### Env-Passing Python Heredoc (apply to: `write-job-marker.sh`)
**Source:** `scripts/write-marker.sh` lines 40-45
All user-controlled values passed via environment variables, never interpolated into the heredoc body. The `<<'PY'` quoting (single-quoted delimiter) prevents any shell expansion inside the heredoc.
```bash
TASK_TYPE="${TASK_TYPE_ARG}" \
TAXONOMY_FILE="${TAXONOMY_FILE}" \
...
python3 - <<'PY'
# inside: all values come from os.environ[...], never from string interpolation
PY
```

### fcntl.LOCK_EX + O_APPEND Atomic Append (apply to: `write-job-marker.sh`)
**Source:** `scripts/write-marker.sh` lines 194-196
```python
with open(marker_path, 'ab', buffering=0) as fh:
    fcntl.flock(fh, fcntl.LOCK_EX)
    fh.write((json.dumps(rec, separators=(',', ':')) + '\n').encode('utf-8'))
```

### Path-Traversal Sid Guard (apply to: `write-job-marker.sh`)
**Source:** `scripts/write-marker.sh` line 172
```python
if not re.fullmatch(r'[0-9a-fA-F-]+|pseudo-[0-9]+', sid):
    raise SystemExit(f"unsafe sid: {sid!r}")
```

### Fail-Loud-But-Don't-Block Exit Contract (apply to: `write-job-marker.sh`, `SKILL.md §JOB DECLARATION`)
**Source:** `scripts/write-marker.sh` lines 63-64 + `SKILL.md` lines 106-108
Unknown label or invalid input → `raise SystemExit(...)` (non-zero exit) + no marker written. The SKILL.md directive tells the agent to log the error but not block its response.

### Markers Dir 0700 Creation (apply to: `write-job-marker.sh`)
**Source:** `scripts/write-marker.sh` line 176
```python
os.makedirs(markers_dir, mode=0o700, exist_ok=True)
```

### Log-Injection Truncation Pattern (apply to: `write-job-marker.sh` bash wrapper)
**Source:** `scripts/write-marker.sh` lines 35-38
```bash
TASK_TYPE_LOG="${TASK_TYPE_ARG:0:64}"
info "write-marker: writing marker for task_type='${TASK_TYPE_LOG}'"
```
Mirror for write-job-marker.sh: truncate `JOB_TYPE_ARG` to 64 chars before the `info` call.

### Taxonomy Seeding Block (apply to: `scripts/post-install.sh` addition)
**Source:** `scripts/post-install.sh` lines 121-136
Copy the entire if/elif/else block structure verbatim, substituting `task-taxonomy.json` → `job-taxonomy.json` and `write-marker.sh` → `write-job-marker.sh` in the warning message.

### Tmp-Home Test Harness (apply to: `tests/test_write_job_marker.sh`)
**Source:** `tests/test_write_marker.sh` lines 28-54
`mktemp -d` tmp home, `mkdir -p` the sessions/state/markers dirs, seed taxonomy from repo root, create a fake UUID-named session JSONL, `trap cleanup EXIT`. Run the script under test with `OPENCLAW_HOME="${TMP_HOME}"`.

---

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `references/job-declaration.md` content | config | — | No existing job-declaration.md in this repo; content is ported/adapted from the sibling `../hermes-revenium/skills/revenium/references/job-declaration.md`, which was read by the researcher. The structure mirrors `references/task-classification.md` (role-match listed above) but the content is Hermes-sourced and adapted to OpenClaw writer syntax. |

---

## Metadata

**Analog search scope:** `scripts/`, `tests/`, `references/`, repo root (`*.json`, `SKILL.md`)
**Files scanned:** 7 live files read (write-marker.sh, common.sh, post-install.sh, task-taxonomy.json, SKILL.md lines 1-115, test_write_marker.sh, references/task-classification.md)
**Pattern extraction date:** 2026-06-03
