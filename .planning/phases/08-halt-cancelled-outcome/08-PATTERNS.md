# Phase 8: Halt → CANCELLED Outcome - Pattern Map

**Mapped:** 2026-06-03
**Files analyzed:** 3 (report.sh modified; stub-revenium.sh extended; test_report_jobs_argv.sh extended)
**Analogs found:** 8 / 8 code elements — all from existing codebase

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `scripts/report.sh` (halt-handler step) | service | CRUD + event-driven | `scripts/report.sh` jobs create/outcome (~lines 772–807, 935–986) | exact — extends same file |
| `scripts/report.sh` (guardrail-status.json read) | service | file-I/O | `scripts/guardrail-check.sh` Python heredoc env-passing read (~lines 123–145, 197–204) | role-match |
| `scripts/report.sh` (`JOB:halt:<haltedAt>` gate) | service | CRUD | `scripts/report.sh` ledger-gate idiom at jobs create (~lines 780–782) and jobs outcome (~lines 946–948) | exact |
| `scripts/report.sh` (open-job ledger scan) | service | file-I/O | `scripts/report.sh` grep ledger pattern (~lines 780, 946, 948) | exact |
| `scripts/report.sh` (CANCELLED-close loop) | service | CRUD | `scripts/report.sh` jobs outcome (~lines 951–985) | exact |
| `scripts/report.sh` (synthetic create+outcome fallback) | service | CRUD | `scripts/report.sh` jobs create (~lines 783–806) + jobs outcome (~lines 951–985) | exact |
| `scripts/report.sh` (sha1 synthetic-id derivation) | utility | transform | `scripts/write-job-marker.sh` env-passing Python heredoc (~lines 65–74) | role-match |
| `tests/stub-revenium.sh` (halt fixture stubs) | test | request-response | `tests/stub-revenium.sh` STUB_REVENIUM_NO_JOBS / STUB_REVENIUM_JOBS_FAIL switches (~lines 56–93) | exact |
| `tests/test_report_jobs_argv.sh` (halt test groups) | test | CRUD | `tests/test_report_jobs_argv.sh` GROUP B/D/E pattern (~lines 329–578) | exact |

---

## Pattern Assignments

### Halt-handler step placement in `scripts/report.sh` (after per-session loop)

**Analog:** `scripts/report.sh` `main()` function, lines 1012–1032

**Structure to copy** (lines 1012–1032 — the account-level step goes INSIDE `main()` after the `while` loop closes):
```bash
main() {
  info "=== Revenium Metering Reporter starting ==="
  # ... session discovery ...
  local total_files=0
  while IFS= read -r -d '' session_file; do
    ((total_files++)) || true
    process_session "${session_file}"
  done < <(find "${SESSIONS_DIR}" -name "*.jsonl" -print0 2>/dev/null)

  info "=== Done. Processed ${total_files} session file(s). ==="
  # <<< NEW: halt_handler step goes HERE, after the while loop and before or
  # replacing the closing info line. Behind JOBS_CLI_CAPABLE (D-10). >>>
}
```

**Fail-open wrapping pattern** (lines 1048 — the probe guard that gates all job work):
```bash
JOBS_CLI_CAPABLE=false
if revenium jobs --help >/dev/null 2>&1 && \
   revenium meter completion --help 2>&1 | grep -q -- '--agentic-job-id'; then
  JOBS_CLI_CAPABLE=true
else
  warn "revenium jobs/--agentic-job-id not available — job work skipped; metering continues as v1.0."
fi
```

The halt handler opens with the same guard:
```bash
if [[ "${JOBS_CLI_CAPABLE}" == "true" ]]; then
  # ... entire halt-handler body wrapped so any failure is non-fatal ...
fi
```

---

### `guardrail-status.json` read in `scripts/report.sh` (new read — first time report.sh reads halt state)

**Analog:** `scripts/guardrail-check.sh` Python heredoc env-passing read, lines 123–145 and 197–204

**Env-passing heredoc discipline** (lines 123–129 — ALL values passed via env, NEVER string-interpolated):
```bash
HALT_OUTPUT=$(
  GUARDRAIL_STATUS_FILE="${GUARDRAIL_STATUS_FILE}" \
  ENFORCEMENT_JSON="${ENFORCEMENT_JSON}" \
  BUDGET_RULES_JSON="${BUDGET_RULES_JSON}" \
  RULE_IDS_JSON="${RULE_IDS_JSON}" \
  AUTONOMOUS="${AUTONOMOUS}" \
  python3 - <<'PY'
import json, os, tempfile
from pathlib import Path

status_file = Path(os.environ['GUARDRAIL_STATUS_FILE'])
# ... all reads go through os.environ, never ${VAR} inside heredoc ...
PY
)
```

**Fail-open read of guardrail-status.json** (lines 197–204 — exact pattern to copy):
```bash
# Load previous state (fail-open)
prev = {}
try:
    prev = json.loads(status_file.read_text(encoding='utf-8'))
except Exception:
    pass
prev_halted = bool(prev.get('halted', False))
prev_halted_at = prev.get('haltedAt')
```

**Applied to report.sh:** The halt handler reads `guardrail-status.json` via a small env-passing Python heredoc, extracts `halted` and `haltedAt` (and optionally `haltedRule`), fails open on any exception, and returns values as `KEY=VALUE` lines for bash to parse:

```bash
HALT_STATUS=$(
  GUARDRAIL_STATUS_FILE="${SKILL_DIR}/guardrail-status.json" \
  python3 - <<'PY'
import json, os
status_file = os.environ['GUARDRAIL_STATUS_FILE']
try:
    data = json.load(open(status_file, encoding='utf-8'))
    halted = 'true' if data.get('halted') else 'false'
    halted_at = data.get('haltedAt', '')
    halted_rule_name = (data.get('haltedRule') or {}).get('name', '')
    print(f"HALTED={halted}")
    print(f"HALTED_AT={halted_at}")
    print(f"HALTED_RULE_NAME={halted_rule_name}")
except Exception:
    print("HALTED=false")
    print("HALTED_AT=")
    print("HALTED_RULE_NAME=")
PY
) || true
HALTED=$(echo "${HALT_STATUS}" | sed -n 's/^HALTED=//p')
HALTED_AT=$(echo "${HALT_STATUS}" | sed -n 's/^HALTED_AT=//p')
```

**Critical discipline (T-04-09):** `haltedAt` is an ISO timestamp from the JSON file — it MUST be passed through env, never interpolated into the heredoc string. The `<<'PY'` quoting (single-quoted delimiter) enforces this — any `${VAR}` inside would be literal text, not expanded.

**Source path for `guardrail-status.json` in report.sh context:** `${SKILL_DIR}/guardrail-status.json` where `SKILL_DIR="${OPENCLAW_HOME}/skills/revenium"` is already defined at line 31 of report.sh.

---

### `JOB:halt:<haltedAt>` gate (exactly-once-per-halt idempotency key)

**Analog:** `scripts/report.sh` jobs create ledger gate, lines 780–782

**Exact gate pattern to copy** (lines 780–782):
```bash
if grep -q "^JOB:${agentic_job_id}:created:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
  :   # already created — idempotent skip (D-06)
else
  # ... create call ...
fi
```

**Applied to halt gate** — same grep idiom, new key family:
```bash
if grep -q "^JOB:halt:${HALTED_AT}$" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
  :   # halt already processed this tick — idempotent skip (D-03)
else
  # ... CANCELLED-close loop + synthetic fallback ...
  echo "JOB:halt:${HALTED_AT}" >> "${JOBS_LEDGER_FILE}"
fi
```

**Ledger append pattern** (line 801 — exact timestamp idiom to copy):
```bash
local jobs_now_ts
jobs_now_ts=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
echo "JOB:${agentic_job_id}:created:${jobs_now_ts}" >> "${JOBS_LEDGER_FILE}"
```

The `JOB:halt:<haltedAt>` gate line is simpler (no timestamp suffix needed — `haltedAt` IS the unique key):
```bash
echo "JOB:halt:${HALTED_AT}" >> "${JOBS_LEDGER_FILE}"
```

---

### Open-job ledger scan (source of truth per D-06)

**Analog:** `scripts/report.sh` grep-based ledger checks, lines 780, 946, 948

**Pattern to extract all open job ids** — grep for `:created:` lines whose id has no matching `:outcome:` line:
```bash
# Extract ids with a :created: line
# Analog: grep -q "^JOB:${agentic_job_id}:created:" "${JOBS_LEDGER_FILE}" 2>/dev/null
# (lines 780, 948)

# For the scan, read all created ids then filter out those with outcome lines.
# Use Python heredoc (env-passing discipline) to do this safely:
OPEN_JOBS=$(
  JOBS_LEDGER_FILE="${JOBS_LEDGER_FILE}" \
  python3 - <<'PY'
import os, re
ledger = os.environ['JOBS_LEDGER_FILE']
created = set()
closed = set()
try:
    for line in open(ledger, encoding='utf-8'):
        line = line.strip()
        m = re.match(r'^JOB:([^:]+):created:', line)
        if m: created.add(m.group(1))
        m = re.match(r'^JOB:([^:]+):outcome:', line)
        if m: closed.add(m.group(1))
except Exception:
    pass
for jid in sorted(created - closed):
    print(jid)
PY
) || true
```

**Key invariant (D-06):** Do NOT use markers for this scan — only the ledger. The ledger lines follow the `JOB:<id>:created:<ts>` and `JOB:<id>:outcome:<ts>:<status>` format already established in Phase 6 (lines 801, 980 of report.sh).

---

### CANCELLED-close loop (JHALT-01 / D-04 / D-08)

**Analog:** `scripts/report.sh` jobs outcome block, lines 951–985

**Exact pattern to reuse** (lines 951–984):
```bash
local outcome_cmd=( revenium jobs outcome "${agentic_job_id}" --result "${job_status}" --quiet )
# D-07: NO --outcome-type ever.
# D-08: failure_reason via --metadata only for FAILED status ...

local outcome_cmd_output outcome_cmd_exit
outcome_cmd_output=$("${outcome_cmd[@]}" 2>&1) && outcome_cmd_exit=0 || outcome_cmd_exit=$?

local outcome_success=false
if [[ "${outcome_cmd_exit}" -eq 0 ]]; then
  outcome_success=true
elif echo "${outcome_cmd_output}" | grep -qi "409\|already.exist\|conflict"; then
  outcome_success=true   # 409-as-success backstop (D-06)
fi

if [[ "${outcome_success}" == "true" ]]; then
  local outcome_now_ts
  outcome_now_ts=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
  echo "JOB:${agentic_job_id}:outcome:${outcome_now_ts}:${job_status}" >> "${JOBS_LEDGER_FILE}"
  info "Outcome reported: agentic_job_id=${agentic_job_id_log} result=${job_status}"
else
  warn "outcome failed: id=${agentic_job_id_log} exit=${outcome_cmd_exit} — retries next tick"
fi
```

**Applied to CANCELLED-close loop** — substitute `job_status=CANCELLED`, omit `--metadata` (no failure_reason for CANCELLED), add ledger idempotency gate per open job id before calling outcome (mirrors line 946):

```bash
for open_job_id in ${OPEN_JOBS}; do
  # Per-job outcome idempotency gate (mirrors report.sh line 946)
  if grep -q "^JOB:${open_job_id}:outcome:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
    continue   # already closed — idempotent skip
  fi
  local halt_outcome_cmd=( revenium jobs outcome "${open_job_id}" --result CANCELLED --quiet )
  local halt_outcome_output halt_outcome_exit
  halt_outcome_output=$("${halt_outcome_cmd[@]}" 2>&1) && halt_outcome_exit=0 || halt_outcome_exit=$?
  local halt_outcome_success=false
  if [[ "${halt_outcome_exit}" -eq 0 ]]; then
    halt_outcome_success=true
  elif echo "${halt_outcome_output}" | grep -qi "409\|already.exist\|conflict"; then
    halt_outcome_success=true
  fi
  if [[ "${halt_outcome_success}" == "true" ]]; then
    local halt_outcome_ts
    halt_outcome_ts=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
    echo "JOB:${open_job_id}:outcome:${halt_outcome_ts}:CANCELLED" >> "${JOBS_LEDGER_FILE}"
    info "Halt: closed job CANCELLED: id=${open_job_id}"
  else
    warn "Halt: outcome CANCELLED failed: id=${open_job_id} exit=${halt_outcome_exit} — continuing"
  fi
done
```

---

### Synthetic create+outcome fallback (JHALT-02 / D-05 / D-09)

**Analog (create):** `scripts/report.sh` jobs create block, lines 783–806

**Exact pattern to copy for synthetic create** (lines 783–806):
```bash
local jobs_cmd=( revenium jobs create --agentic-job-id "${agentic_job_id}" --quiet )
[[ -n "${agentic_job_name}" ]] && jobs_cmd+=(--name "${agentic_job_name}")
[[ -n "${agentic_job_type}" ]] && jobs_cmd+=(--type "${agentic_job_type}")
# D-04: NO --environment

local jobs_cmd_output jobs_cmd_exit
jobs_cmd_output=$("${jobs_cmd[@]}" 2>&1) && jobs_cmd_exit=0 || jobs_cmd_exit=$?

local jobs_success=false
if [[ "${jobs_cmd_exit}" -eq 0 ]]; then
  jobs_success=true
elif echo "${jobs_cmd_output}" | grep -qi "409\|already.exist\|conflict"; then
  jobs_success=true   # 409-as-success backstop (D-06)
fi

if [[ "${jobs_success}" == "true" ]]; then
  local jobs_now_ts
  jobs_now_ts=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
  echo "JOB:${agentic_job_id}:created:${jobs_now_ts}" >> "${JOBS_LEDGER_FILE}"
  info "Job created: agentic_job_id=${agentic_job_id_log}"
else
  warn "jobs create failed: id=${agentic_job_id_log} exit=${jobs_cmd_exit} — metering continues"
fi
```

**Applied to synthetic fallback** — `agentic_job_id=guardrail-halt-<hex>`, `job_type=interrupted`, `job_name` set to embed halt context (D-05 / D-09). Ledger-gated create then immediately followed by the same 409-as-success outcome call with `--result CANCELLED`:

```bash
# Synthetic create — only when open-count was 0 (D-05/D-08)
local synth_id="guardrail-halt-${HALT_HEX}"
if ! grep -q "^JOB:${synth_id}:created:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
  local synth_create_cmd=( revenium jobs create --agentic-job-id "${synth_id}" \
    --name "Interrupted by guardrail halt" --type "interrupted" --quiet )
  local synth_create_output synth_create_exit
  synth_create_output=$("${synth_create_cmd[@]}" 2>&1) && synth_create_exit=0 || synth_create_exit=$?
  local synth_create_success=false
  if [[ "${synth_create_exit}" -eq 0 ]]; then
    synth_create_success=true
  elif echo "${synth_create_output}" | grep -qi "409\|already.exist\|conflict"; then
    synth_create_success=true
  fi
  if [[ "${synth_create_success}" == "true" ]]; then
    local synth_ts
    synth_ts=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
    echo "JOB:${synth_id}:created:${synth_ts}" >> "${JOBS_LEDGER_FILE}"
    info "Halt: synthetic interrupted job created: id=${synth_id}"
    # Immediately close CANCELLED (same tick, same idempotency discipline)
    # ... [outcome block mirrors the CANCELLED-close pattern above] ...
  else
    warn "Halt: synthetic create failed: id=${synth_id} exit=${synth_create_exit}"
  fi
fi
```

---

### sha1 synthetic-id derivation (D-09: `hex = sha1(haltedAt)[:4]`)

**Analog:** `scripts/write-job-marker.sh` env-passing Python heredoc, lines 65–74

**Env-passing discipline from write-job-marker.sh** (lines 65–74 — ALL inputs via env):
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
import json, os, time, fcntl, re, sys
job_id_raw = os.environ['JOB_ID']
# ... never string-interpolated into the heredoc ...
PY
```

**Applied to sha1 derivation** — pass `haltedAt` via env, compute sha1, return first 4 hex chars:
```bash
HALT_HEX=$(
  HALTED_AT="${HALTED_AT}" \
  python3 - <<'PY'
import hashlib, os
halted_at = os.environ.get('HALTED_AT', '')
h = hashlib.sha1(halted_at.encode('utf-8')).hexdigest()
print(h[:4])
PY
) || true
```

**Why env-passing matters for `haltedAt`:** `haltedAt` is an ISO 8601 timestamp like `2026-06-03T12:34:56.789Z`. It contains colons and dots — characters that are safe in Python but would cause bash parsing issues if naively interpolated. The env-passing pattern (T-04-09) is the project standard and is the ONLY safe path here.

**Job-id kebab+4-hex format** (from Phase 5 discipline, referenced in write-job-marker.sh): `guardrail-halt-<4hex>` follows the kebab + 4-hex safety floor exactly: all-lowercase, alphanumeric + hyphens only, 4 hex chars appended. This matches the pattern of existing test fixture ids like `add-feature-1ab2` (GROUP A), `fix-bug-2cd3` (GROUP A), `idempotent-9kl0` (GROUP E).

---

### `tests/stub-revenium.sh` halt fixture stubs

**Analog:** `tests/stub-revenium.sh` existing environment switches, lines 17–36 and 56–93

**Existing switch pattern to extend** (lines 56–88 — add new switches in same style):
```bash
# jobs --help → exit 0 unless STUB_REVENIUM_NO_JOBS forces probe failure
if [[ "$1 $2" == "jobs --help" ]]; then
  if [[ -n "${STUB_REVENIUM_NO_JOBS:-}" ]]; then
    exit 1
  fi
  echo "usage: revenium jobs <subcommand>"
  exit 0
fi

# 3. jobs create / jobs outcome — optional 409 or non-409 failure
if [[ "$1 $2" == "jobs create" || "$1 $2" == "jobs outcome" ]]; then
  # 409 fake (takes precedence): opt-in via STUB_REVENIUM_409_FOR
  if [[ -n "${STUB_REVENIUM_409_FOR:-}" ]] && printf '%s\n' "$@" | grep -qF -- "${STUB_REVENIUM_409_FOR}"; then
    echo "Error: 409 Conflict: job already exists" >&2
    exit 1
  fi
  # Non-409 jobs-fail switch (CR-02/D-12 decoupling seam)
  if [[ -n "${STUB_REVENIUM_JOBS_FAIL:-}" ]]; then
    echo "Error: 500 jobs service unavailable" >&2
    exit 1
  fi
fi
```

**New switches to add** (same style, same section):
```bash
#   STUB_REVENIUM_HALTED_AT=<timestamp>
#     When set, the stub simulates a halted guardrail-status.json for the halt-
#     handler tests. The test harness writes the actual fixture file; this switch
#     documents the naming convention used in GROUP I/J/K/L test groups.
#
#   STUB_REVENIUM_HALT_JOBS_FAIL=1
#     When set, `jobs outcome` and `jobs create` fail only for halt-handler
#     calls (identified by the guardrail-halt- prefix on --agentic-job-id).
#     Normal per-session jobs calls are unaffected. Exercises D-10 fail-open.
```

**Argv capture discipline** (lines 41–45 — unchanged, captures all tokens before any switch logic):
```bash
if [[ -n "${STUB_REVENIUM_ARGV_FILE:-}" ]]; then
  for arg in "$@"; do
    printf '%s\n' "${arg}" >> "${STUB_REVENIUM_ARGV_FILE}"
  done
fi
```

This runs before any routing, so halt-handler tokens (`jobs outcome guardrail-halt-<hex>`) are always capturable via grep on `STUB_REVENIUM_ARGV_FILE`.

---

### `tests/test_report_jobs_argv.sh` halt test groups (GROUP I/J/K/L)

**Analog:** `tests/test_report_jobs_argv.sh` GROUP B (fail-open) and GROUP E (idempotency) patterns, lines 329–387 and 517–578

**make_openclaw_home helper** (lines 48–63 — reuse unchanged; add `guardrail-status.json` fixture write after home creation):
```bash
make_openclaw_home() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-rpt-jobs-home.XXXXXX")
  mkdir -p "${d}/agents/main/sessions" "${d}/skills/revenium/markers" \
            "${d}/skills/revenium/scripts"
  ln -sf "${REPO_ROOT}/scripts/get-root-session-id.py" \
         "${d}/skills/revenium/scripts/get-root-session-id.py"
  echo '{}' > "${d}/revenium-offsets.json"
  touch "${d}/revenium-reported.ledger"
  touch "${d}/revenium-jobs.ledger"
  echo '{"organizationName":"TestOrg"}' > "${d}/skills/revenium/config.json"
  echo "${d}"
}
# After make_openclaw_home, write halt fixture:
# printf '%s\n' '{"halted":true,"haltedAt":"2026-06-03T10:00:00.000Z","haltedRule":{"name":"token-budget","ruleId":"abc123"}}' \
#   > "${TMP_HOME_X}/skills/revenium/guardrail-status.json"
```

**run_report helper** (lines 98–108 — reuse unchanged; halt state is carried by the fixture file, not env):
```bash
run_report() {
  local openclaw_home="$1"
  local _argv_file="$2"
  shift 2
  local -a extra_env=("$@")
  STUB_REVENIUM_ARGV_FILE="${_argv_file}" \
  OPENCLAW_HOME="${openclaw_home}" \
  HOME="${TMP_FAKE_HOME}" \
  "${extra_env[@]+"${extra_env[@]}"}" \
  bash "${REPORT_SH}" 2>&1 || true
}
```

**count_grep helper** (lines 86–91 — reuse unchanged for all halt assertions):
```bash
count_grep() {
  local pattern="$1" file="${2:-/dev/null}"
  local r
  r=$(grep -c "${pattern}" "${file}" 2>/dev/null; exit 0)
  echo "${r:-0}"
}
```

**Idempotency test pattern** (GROUP E, lines 535–538 — copy for halt idempotency test):
```bash
# First run
run_report "${TMP_HOME_E}" "${ARGV_FILE_E1}"
# Second run (same OPENCLAW_HOME — no reset of offsets/ledgers)
run_report "${TMP_HOME_E}" "${ARGV_FILE_E2}"
# Merge and assert token counts are STILL exactly 1 across both runs
```

**Fail-open assertion pattern** (GROUP B, lines 357–363):
```bash
create_token_count_b=$(count_grep "^create$" "${ARGV_FILE_B}")
outcome_token_count_b=$(count_grep "^outcome$" "${ARGV_FILE_B}")
if [[ "${create_token_count_b}" -eq 0 && "${outcome_token_count_b}" -eq 0 ]]; then
  pass "JLIFE-04 fail-open: zero ^create$/^outcome$ tokens in argv (JOBS_CLI_CAPABLE=false, no job work)"
else
  fail "..."
fi
```

**Test fixture shape for halted guardrail-status.json** — write before running report.sh:
```bash
HALTED_AT_I="2026-06-03T10:00:00.000Z"
printf '%s\n' \
  '{"halted":true,"haltedAt":"'"${HALTED_AT_I}"'","autonomousMode":true,"haltedRule":{"name":"token-budget","ruleId":"test-rule-id","metricType":"TOKEN","windowType":"ROLLING","currentValue":1000,"hardLimit":500}}' \
  > "${TMP_HOME_I}/skills/revenium/guardrail-status.json"
```

---

## Shared Patterns

### Ledger-gated idempotency + 409-as-success
**Source:** `scripts/report.sh` lines 780–807 (create gate) and 946–985 (outcome gate)
**Apply to:** All job create and outcome calls in the halt handler (`JOB:halt:<haltedAt>` gate, per-job CANCELLED close gate, synthetic create gate)

```bash
# Gate pattern (grep before act, skip if already done)
if grep -q "^JOB:${id}:created:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
  :   # idempotent skip
else
  # ... call + 409-as-success check + ledger append ...
fi

# 409-as-success check (copy verbatim)
local success=false
if [[ "${exit_code}" -eq 0 ]]; then
  success=true
elif echo "${output}" | grep -qi "409\|already.exist\|conflict"; then
  success=true
fi
```

### Fail-open warn-logging
**Source:** `scripts/report.sh` lines 803–805 (create warn) and 982–983 (outcome warn); `scripts/common.sh` lines 116–128 (log/warn helpers)
**Apply to:** Every jobs call in the halt handler; handler as a whole is non-fatal

```bash
# warn() helper (common.sh lines 116–128)
log() {
  local level="$1"; shift
  local line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${level}] [revenium] $*"
  mkdir -p "${STATE_DIR}"
  printf '%s\n' "${line}" >> "${LOG_FILE}"
  if [[ -t 2 ]]; then printf '%s\n' "${line}" >&2; fi
}
warn() { log "WARN " "$@"; }

# Failure path (mirrors report.sh line 804):
warn "jobs create failed: id=${id_log} exit=${exit_code} — metering continues"
warn "outcome failed: id=${id_log} exit=${exit_code} — retries next tick"
```

Note: `report.sh` defines its own `warn()` inline (it does not source `common.sh`). The halt handler must use the same inline `warn` / `info` calls already present in `report.sh`.

### Env-passing Python heredoc discipline (T-04-09)
**Source:** `scripts/report.sh` lines 822–838 (duration heredoc) and `scripts/guardrail-check.sh` lines 123–129 (status-write heredoc) and `scripts/write-job-marker.sh` lines 65–74
**Apply to:** Every Python heredoc in the halt handler (guardrail-status.json read, sha1 derivation, open-job ledger scan)

```bash
# Pattern: VAR=value python3 - <<'PY' ... os.environ['VAR'] ... PY
# Single-quoted 'PY' delimiter is mandatory — prevents any bash expansion inside heredoc.
# All untrusted/dynamic values (haltedAt, file paths) pass through os.environ only.
HALTED_AT="${HALTED_AT}" python3 - <<'PY'
import os
val = os.environ.get('HALTED_AT', '')   # CORRECT
# val = "${HALTED_AT}"                  # NEVER — string interpolation into heredoc
PY
```

### Timestamp generation
**Source:** `scripts/report.sh` lines 799–800 and 978–979
**Apply to:** All ledger append lines in the halt handler

```bash
local ts
ts=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
echo "JOB:${id}:created:${ts}" >> "${JOBS_LEDGER_FILE}"
```

### JOBS_CLI_CAPABLE guard
**Source:** `scripts/report.sh` lines 1043–1049 (probe), 778–779 (create guard), 944–945 (outcome guard)
**Apply to:** The entire halt-handler step (one outer guard around the whole block)

```bash
if [[ "${JOBS_CLI_CAPABLE}" == "true" ]]; then
  # ... halt handler body (non-fatal internally) ...
fi
```

---

## No Analog Found

All code elements have close analogs within the existing codebase. No external reference patterns needed.

---

## Metadata

**Analog search scope:** `scripts/report.sh`, `scripts/guardrail-check.sh`, `scripts/common.sh`, `scripts/write-job-marker.sh`, `tests/stub-revenium.sh`, `tests/test_report_jobs_argv.sh`
**Files scanned:** 6
**Pattern extraction date:** 2026-06-03
