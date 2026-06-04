# Phase 10: Tool Registry & Tool-Event Metering - Pattern Map

**Mapped:** 2026-06-04
**Files analyzed:** 4 (2 modified, 2 created)
**Analogs found:** 4 / 4

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `scripts/common.sh` (MODIFY — add 1 constant) | config | n/a | `scripts/common.sh` Phase 9 path-constants block (lines 59–64) | exact |
| `scripts/report.sh` (MODIFY — add probe + 3 helpers + toolCall loop) | service | event-driven | `scripts/report.sh` JOBS_CLI_CAPABLE probe (lines 1236–1250) + `post_to_revenium` + jobs create/outcome blocks (lines 770–806, 931–976) | exact |
| `tests/test_report_tool_argv.sh` (CREATE) | test | request-response | `tests/test_guardrail_argv.sh` (full file) + `tests/test_report_jobs_argv.sh` structure | exact |
| `tests/stub-revenium.sh` (MODIFY — add tools + tool-event switches) | utility | request-response | `tests/stub-revenium.sh` existing STUB_REVENIUM_NO_JOBS / STUB_REVENIUM_JOBS_FAIL pattern (lines 16–52, 129–143) | exact |

---

## Pattern Assignments

### `scripts/common.sh` — ADD `TOOL_REGISTRY_LEDGER_FILE` constant

**Analog:** Phase 9 path-constants block, `scripts/common.sh` lines 59–64

**Existing pattern to extend** (lines 59–64):
```bash
# Phase 9 path constants (GRDEV-01..05).
# GUARDRAIL_LEDGER_FILE: append-only dedup ledger for guardrail event metering.
# JOBS_LEDGER_FILE: read-only consumer from guardrail-check.sh for open-job attribution.
#   Identical path to report.sh's JOBS_LEDGER_FILE (must stay in sync).
GUARDRAIL_LEDGER_FILE="${OPENCLAW_HOME}/revenium-guardrail.ledger"
JOBS_LEDGER_FILE="${REVENIUM_JOBS_LEDGER_FILE:-${OPENCLAW_HOME}/revenium-jobs.ledger}"
```

**New constant to append immediately after line 64** (after `JOBS_LEDGER_FILE=`):
```bash
# Phase 10 path constants (TOOLEV-01/04).
# TOOL_REGISTRY_LEDGER_FILE: append-only dedup ledger for tool registration.
#   Key format: TOOL:<tool_id>:<unix_ts>
# TOOL_EVENTS_LEDGER_FILE: append-only dedup ledger for per-invocation tool-events.
#   Key format: TOOLEV:<toolcall_id>
#   Kept separate from LEDGER_FILE (revenium-reported.ledger) to avoid coupling
#   with the CR-02 offset-advance gate in report.sh (RESEARCH.md Open Question 2).
TOOL_REGISTRY_LEDGER_FILE="${OPENCLAW_HOME}/revenium-tools.ledger"
TOOL_EVENTS_LEDGER_FILE="${OPENCLAW_HOME}/revenium-tool-events.ledger"
```

---

### `scripts/report.sh` — ADD TOOLS_CLI_CAPABLE probe

**Analog:** JOBS_CLI_CAPABLE probe, `scripts/report.sh` lines 1236–1250

**Existing pattern to copy** (lines 1236–1250):
```bash
# JOBS_CLI_CAPABLE — one-time dual capability probe per cron tick (D-11).
# Set true only if BOTH `revenium jobs --help` exits 0 AND
# `revenium meter completion --help` output contains --agentic-job-id.
# On probe failure, warn once and leave JOBS_CLI_CAPABLE=false so all job
# work is skipped; metering ships byte-identical to v1.0.
# Probe runs ONCE at startup (before main); the boolean is cached for the
# whole tick and read by per-completion stamping and Plan 03's create/outcome.
# ---------------------------------------------------------------------------
JOBS_CLI_CAPABLE=false
if revenium jobs --help >/dev/null 2>&1 && \
   revenium meter completion --help 2>&1 | grep -q -- '--agentic-job-id'; then
  JOBS_CLI_CAPABLE=true
else
  warn "revenium jobs/--agentic-job-id not available — job work skipped; metering continues as v1.0."
fi
```

**New probe to insert immediately before `main "$@"` (line 1252), after JOBS_CLI_CAPABLE block:**
```bash
# TOOLS_CLI_CAPABLE — one-time dual capability probe per cron tick (TOOLEV-04).
# Set true only if BOTH `revenium tools --help` exits 0 AND
# `revenium meter tool-event --help` output contains --tool-id.
# On probe failure, warn once and leave TOOLS_CLI_CAPABLE=false so all tool
# work is skipped; metering continues as v1.1 (job-aware).
TOOLS_CLI_CAPABLE=false
if revenium tools --help >/dev/null 2>&1 && \
   revenium meter tool-event --help 2>&1 | grep -q -- '--tool-id'; then
  TOOLS_CLI_CAPABLE=true
else
  warn "revenium tools/meter tool-event not available — tool work skipped; metering continues as v1.1."
fi
```

**Placement note:** Both probe blocks sit between the config-read section and `main "$@"`. TOOLS_CLI_CAPABLE must appear AFTER JOBS_CLI_CAPABLE (same tier, same lifecycle). `TOOL_REGISTRY_LEDGER_FILE` and `TOOL_EVENTS_LEDGER_FILE` need `touch` calls alongside the existing `touch "${LEDGER_FILE}"` and `touch "${JOBS_LEDGER_FILE}"` at lines 111–112.

---

### `scripts/report.sh` — ADD `normalize_tool_id` + `classify_tool_type` helpers

**Analog:** The python3 env-passing heredoc for duration computation (report.sh lines 821–838) — same Bash 3.2 portability discipline.

**Existing env-passing heredoc pattern to mirror** (lines 821–838):
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
t1 = parse_ts(os.environ.get('REQ_TS', ''))
t2 = parse_ts(os.environ.get('RESP_TS', ''))
if t1 and t2:
    print(max(0, int((t2 - t1).total_seconds() * 1000)))
else:
    print(0)
PY
)
```

**New helpers to insert in the helper-function block (after `get_root_session_id`, before `process_session`):**
```bash
# normalize_tool_id — convert raw session tool name to stable URL-safe --tool-id.
# Rules: __ → -- (MCP separator); _ → -; lowercase via python3 (Bash 3.2 safe).
# Examples: web_fetch→web-fetch; mcp__ctx7__search→mcp--ctx7--search
normalize_tool_id() {
  local raw="$1"
  local normalized="${raw//__/--}"
  normalized="${normalized//_/-}"
  TOOL_NAME="${normalized}" python3 -c "import os; print(os.environ['TOOL_NAME'].lower())" 2>/dev/null \
    || printf '%s' "${normalized}"
}

# classify_tool_type — return --tool-type value for revenium tools create.
# MCP tool names contain __ (double-underscore) by OpenClaw convention.
# All others are built-in Claude Code tools.
classify_tool_type() {
  local name="$1"
  if [[ "${name}" == *"__"* ]]; then
    echo "MCP_SERVER"
  else
    echo "BUILTIN"
  fi
}
```

---

### `scripts/report.sh` — ADD `_register_tool` helper (create-once, ledger-gated, fail-open)

**Analog:** jobs create block, `scripts/report.sh` lines 770–806

**Existing jobs create pattern to mirror** (lines 770–806):
```bash
if [[ "${JOBS_CLI_CAPABLE}" == "true" && -n "${agentic_job_id}" \
   && "${root_sid}" == "${session_id}" ]]; then
  if grep -q "^JOB:${agentic_job_id}:created:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
    :   # already created — idempotent skip (D-06)
  else
    local jobs_cmd=( revenium jobs create --agentic-job-id "${agentic_job_id}" --quiet )
    [[ -n "${agentic_job_name}" ]] && jobs_cmd+=(--name "${agentic_job_name}")
    [[ -n "${agentic_job_type}" ]] && jobs_cmd+=(--type "${agentic_job_type}")

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
  fi
fi
```

**New `_register_tool` function (standalone helper, not inline):**
```bash
# _register_tool — register a tool in Revenium on first sight (TOOLEV-01/04).
# Idempotent: skip if TOOL:<tool_id> already in TOOL_REGISTRY_LEDGER_FILE.
# 409-as-success backstop: mirrors jobs create (D-06 equivalent).
# Fail-open: returns 0 on all paths; never blocks tool-event emission.
# CRITICAL (mirrors D-12): NEVER touch failed_count/reported_count.
_register_tool() {
  local tool_name="$1"
  local tool_id="$2"
  local tool_type="$3"

  if grep -qF "TOOL:${tool_id}" "${TOOL_REGISTRY_LEDGER_FILE}" 2>/dev/null; then
    return 0  # already registered — idempotent skip
  fi

  local reg_cmd=( revenium tools create --name "${tool_name}" --tool-id "${tool_id}" \
                  --tool-type "${tool_type}" --quiet )
  [[ -n "${ORG_NAME:-}" ]] && reg_cmd+=(--organization-name "${ORG_NAME}")

  local reg_out reg_exit
  reg_out=$("${reg_cmd[@]}" 2>&1) && reg_exit=0 || reg_exit=$?

  local reg_success=false
  if [[ "${reg_exit}" -eq 0 ]]; then
    reg_success=true
  elif echo "${reg_out}" | grep -qi "409\|already.exist\|conflict"; then
    reg_success=true  # 409-as-success backstop (mirrors jobs create D-06)
  fi

  if [[ "${reg_success}" == "true" ]]; then
    local reg_ts
    reg_ts=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
    printf 'TOOL:%s:%s\n' "${tool_id}" "${reg_ts}" >> "${TOOL_REGISTRY_LEDGER_FILE}"
    info "Tool registered: name=${tool_name} id=${tool_id} type=${tool_type}"
  else
    warn "Tool registration failed: id=${tool_id} exit=${reg_exit} — tool-event emission continues"
    # Fail-open: do NOT return non-zero; do NOT block tool-event emission
  fi
  return 0
}
```

---

### `scripts/report.sh` — ADD `_meter_tool_event` helper (at-most-once per toolCall.id)

**Analog:** `post_to_revenium` function (lines 213–315) — argv-array discipline, conditional flag appending, exit-code handling. Ledger dedup gate mirrors jobs outcome (lines 907–929).

**Existing dedup gate + post pattern to mirror** (lines 906–929):
```bash
# Skip already-reported transactions
if grep -q "^TX:${tx_id}$" "${LEDGER_FILE}" 2>/dev/null; then
  continue
fi

if post_to_revenium \
    "${model}" "${provider}" \
    ...
    "${operation_type}"; then
  echo "TX:${tx_id}" >> "${LEDGER_FILE}"
  ((reported_count++)) || true
else
  ((failed_count++)) || true
fi
```

**Existing argv-array discipline to mirror** (lines 239–313):
```bash
local cmd=(
  revenium meter completion
  --model "${model}"
  ...
  --quiet
)
if [[ -n "${ORG_NAME}" ]]; then
  cmd+=(--organization-name "${ORG_NAME}")
fi
local cmd_output cmd_exit
cmd_output=$("${cmd[@]}" 2>&1) && cmd_exit=0 || cmd_exit=$?
if [[ "${cmd_exit}" -eq 0 ]]; then
  info "Reported: ..."
  return 0
else
  warn "Failed to report: ... exit=${cmd_exit}"
  return 1
fi
```

**New `_meter_tool_event` function:**
```bash
# _meter_tool_event — emit one revenium meter tool-event per toolCall.id (TOOLEV-02/04).
# Idempotent: skip if TOOLEV:<toolcall_id> already in TOOL_EVENTS_LEDGER_FILE.
# Fail-open: returns 0 on all paths; NEVER touches failed_count/reported_count.
# --success defaults to false in CLI — always pass explicitly (RESEARCH Pitfall 2).
_meter_tool_event() {
  local toolcall_id="$1"
  local tool_id="$2"
  local ts="$3"          # ISO timestamp (from parent assistant message)
  local duration_ms="$4" # integer, may be 0
  local is_error="$5"    # "true" | "false"
  local error_msg="$6"   # may be empty
  local root_sid="$7"

  local ledger_key="TOOLEV:${toolcall_id}"
  if grep -qF "${ledger_key}" "${TOOL_EVENTS_LEDGER_FILE}" 2>/dev/null; then
    return 0  # already metered — idempotent skip
  fi

  local ev_cmd=( revenium meter tool-event
    --tool-id     "${tool_id}"
    --duration-ms "${duration_ms}"
    --timestamp   "${ts}"
    --agent       "${REVENIUM_AGENT_PREFIX}${root_sid}"
    --quiet
  )
  # --success defaults to false in CLI — always explicit (RESEARCH Pitfall 2)
  if [[ "${is_error}" == "true" ]]; then
    ev_cmd+=(--success=false)
    [[ -n "${error_msg}" ]] && ev_cmd+=(--error-message "${error_msg}")
  else
    ev_cmd+=(--success)
  fi
  [[ -n "${ORG_NAME:-}" ]] && ev_cmd+=(--organization-name "${ORG_NAME}")

  local ev_out ev_exit
  ev_out=$("${ev_cmd[@]}" 2>&1) && ev_exit=0 || ev_exit=$?

  if [[ "${ev_exit}" -eq 0 ]]; then
    printf '%s\n' "${ledger_key}" >> "${TOOL_EVENTS_LEDGER_FILE}"
    info "Tool event metered: tool_id=${tool_id} duration=${duration_ms}ms"
  else
    warn "Tool event failed: id=${tool_id} toolcall=${toolcall_id} exit=${ev_exit} — fail-open"
  fi
  return 0
}
```

---

### `scripts/report.sh` — ADD toolCall scan loop (inside `process_session`)

**Analog:** Jobs create/outcome in-loop block (lines 770–806, 931–976) — sequencing discipline (after completion metering, own exit locals, never touch `failed_count`/`reported_count`).

**Sequencing rule from jobs outcome block** (comment at lines 931–938):
```bash
# ---------------------------------------------------------------------------
# jobs outcome — in-loop, create-confirmed gate, fail-open (JLIFE-03/05)
# Fires after post_to_revenium (D-09: create → stamp → outcome).
# CRITICAL (D-12 / Pitfall 1): own exit locals; NEVER touch failed_count/
# reported_count; NEVER return/exit process_session; NEVER reach CR-02 gate.
# ---------------------------------------------------------------------------
```

**Existing env-passing Python heredoc pattern** (lines 1083–1106 in handle_halt) — same discipline for multi-line Python extraction:
```bash
JOBS_LEDGER_FILE="${JOBS_LEDGER_FILE}" \
python3 - <<'PY' 2>/dev/null || true
import os, re
ledger = os.environ.get('JOBS_LEDGER_FILE', '')
...
PY
```

**New toolCall scan loop — insert AFTER the while IFS= read -r line completion loop closes, BEFORE `handle_halt` call:**
```bash
# ---------------------------------------------------------------------------
# toolCall scan loop — AFTER completion metering (TOOLEV-04 sequencing rule).
# Scans the same session file for toolCall content items; for each:
#   1. _register_tool (create-once, registry ledger gated)
#   2. _meter_tool_event (at-most-once, tool-events ledger gated)
# CRITICAL: NEVER touch failed_count/reported_count; NEVER return/exit.
# Gated on TOOLS_CLI_CAPABLE (TOOLEV-04).
# ---------------------------------------------------------------------------
if [[ "${TOOLS_CLI_CAPABLE}" == "true" ]]; then
  local tool_scan_tmp
  tool_scan_tmp=$(mktemp)

  SESSION_FILE="${session_file}" python3 - <<'PY' 2>/dev/null > "${tool_scan_tmp}" || true
import json, os
from datetime import datetime, timezone

sf = os.environ.get('SESSION_FILE', '')

def parse_ts(s):
    try: return datetime.fromisoformat(s.replace('Z', '+00:00'))
    except Exception: pass
    for fmt in ('%Y-%m-%dT%H:%M:%S.%fZ', '%Y-%m-%dT%H:%M:%SZ'):
        try: return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except Exception: pass
    return None

tool_calls = {}   # toolcall_id -> {name, parent_msg_ts}
tool_results = {} # toolcall_id -> {result_ts, is_error, error_msg}
try:
    with open(sf, encoding='utf-8') as fh:
        for line in fh:
            line = line.strip()
            if not line: continue
            try: r = json.loads(line)
            except: continue
            if r.get('type') != 'message': continue
            msg = r.get('message', {})
            if msg.get('role') == 'assistant':
                for item in msg.get('content', []):
                    if item.get('type') == 'toolCall' and item.get('id'):
                        tool_calls[item['id']] = {
                            'name': item.get('name', 'unknown'),
                            'parent_msg_ts': r.get('timestamp', ''),
                        }
            elif msg.get('role') == 'toolResult':
                tc_id = msg.get('toolCallId')
                if tc_id:
                    err_text = ''
                    if msg.get('isError'):
                        for c in msg.get('content', []):
                            if c.get('type') == 'text':
                                err_text = c.get('text', '')[:256]
                                break
                    tool_results[tc_id] = {
                        'result_ts': r.get('timestamp', ''),
                        'is_error': 'true' if msg.get('isError') else 'false',
                        'error_msg': err_text,
                    }
except Exception:
    pass
for tc_id, tc in tool_calls.items():
    tr = tool_results.get(tc_id, {})
    start_ts = parse_ts(tc['parent_msg_ts'])
    end_ts = parse_ts(tr.get('result_ts', ''))
    duration_ms = 0
    if start_ts and end_ts:
        duration_ms = max(0, int((end_ts - start_ts).total_seconds() * 1000))
    print('{}\t{}\t{}\t{}\t{}\t{}'.format(
        tc_id, tc['name'], tc['parent_msg_ts'],
        duration_ms, tr.get('is_error', 'false'), tr.get('error_msg', ''),
    ))
PY

  while IFS=$'\t' read -r tc_id tool_name parent_ts duration_ms is_error error_msg; do
    [[ -z "${tc_id}" ]] && continue
    local tool_id tool_type
    tool_id=$(normalize_tool_id "${tool_name}")
    tool_type=$(classify_tool_type "${tool_name}")
    # Sanitize before ledger key / log (T-04-08): 64-char truncation
    local tool_id_log="${tool_id:0:64}"
    _register_tool "${tool_name}" "${tool_id}" "${tool_type}"
    _meter_tool_event "${tc_id}" "${tool_id}" "${parent_ts:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}" \
      "${duration_ms:-0}" "${is_error:-false}" "${error_msg:-}" "${root_sid}"
  done < "${tool_scan_tmp}"

  rm -f "${tool_scan_tmp}"
fi
```

---

### `tests/test_report_tool_argv.sh` — CREATE hermetic test

**Analog:** `tests/test_guardrail_argv.sh` (full file — 591 lines) and `tests/test_report_jobs_argv.sh` (structure)

**Header + boilerplate pattern** (test_guardrail_argv.sh lines 1–43):
```bash
#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
REPORT_SH="${REPO_ROOT}/scripts/report.sh"
STUB_SH="${SCRIPT_DIR}/stub-revenium.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
```

**`make_openclaw_home` helper pattern** (test_report_jobs_argv.sh lines 48–63 + test_guardrail_argv.sh lines 68–89):
```bash
make_openclaw_home() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-rpt-tools-home.XXXXXX")
  mkdir -p "${d}/agents/main/sessions" "${d}/skills/revenium/markers" \
            "${d}/skills/revenium/scripts"
  ln -sf "${REPO_ROOT}/scripts/get-root-session-id.py" \
         "${d}/skills/revenium/scripts/get-root-session-id.py"
  echo '{}' > "${d}/revenium-offsets.json"
  touch "${d}/revenium-reported.ledger"
  touch "${d}/revenium-jobs.ledger"
  touch "${d}/revenium-tools.ledger"
  touch "${d}/revenium-tool-events.ledger"
  echo '{"organizationName":"TestOrg"}' > "${d}/skills/revenium/config.json"
  echo "${d}"
}
```

**Fake HOME / stub placement pattern** (test_guardrail_argv.sh lines 96–112):
```bash
TMP_FAKE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-rpt-tools-fakehome.XXXXXX")
TMP_LOCAL_BIN="${TMP_FAKE_HOME}/.local/bin"
mkdir -p "${TMP_LOCAL_BIN}"
ln -sf "${STUB_SH}" "${TMP_LOCAL_BIN}/revenium"
ARGV_FILE=$(mktemp "${TMPDIR:-/tmp}/test-rpt-tools-argv.XXXXXX")

cleanup() {
  rm -rf "${TMP_FAKE_HOME}" "${ARGV_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

export STUB_REVENIUM_ARGV_FILE="${ARGV_FILE}"
```

**`argv_vals` helper** (test_guardrail_argv.sh line 118):
```bash
argv_vals() {
  awk -v flag="$1" '$0==flag{getline;print}' "${ARGV_FILE}" 2>/dev/null || true
}
```

**`count_grep` helper** (test_guardrail_argv.sh lines 49–54):
```bash
count_grep() {
  local pattern="$1" file="${2:-/dev/null}"
  local r
  r=$(grep -c "${pattern}" "${file}" 2>/dev/null; exit 0)
  echo "${r:-0}"
}
```

**`run_report` helper** (test_report_jobs_argv.sh lines 98–108):
```bash
run_report() {
  local openclaw_home="$1"
  local _argv_file="$2"
  STUB_REVENIUM_ARGV_FILE="${_argv_file}" \
  OPENCLAW_HOME="${openclaw_home}" \
  HOME="${TMP_FAKE_HOME}" \
  bash "${REPORT_SH}" 2>&1 || true
}
```

**Session fixture for tool-call test** (from RESEARCH.md Validation Architecture):
```json
{"type":"session","version":3,"id":"test-tool-sid-001","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/tmp"}
{"type":"message","id":"user-001","parentId":"00000000","timestamp":"2026-01-01T10:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Use the read tool"}]}}
{"type":"message","id":"asst-001","parentId":"user-001","timestamp":"2026-01-01T10:01:05.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"toolu_test001","name":"read","arguments":{"file_path":"/tmp/x"}}],"stopReason":"toolUse","model":"claude-sonnet-4-6","api":"anthropic-messages","provider":"anthropic","usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":150}}}
{"type":"message","id":"result-001","parentId":"asst-001","timestamp":"2026-01-01T10:01:05.250Z","message":{"role":"toolResult","toolCallId":"toolu_test001","toolName":"read","isError":false,"content":[{"type":"text","text":"file contents"}]}}
{"type":"message","id":"asst-002","parentId":"result-001","timestamp":"2026-01-01T10:01:06.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Done"}],"stopReason":"stop","model":"claude-sonnet-4-6","api":"anthropic-messages","provider":"anthropic","usage":{"input":200,"output":30,"cacheRead":150,"cacheWrite":0,"totalTokens":380}}}
```

**Assertion pattern** (mirrors test_guardrail_argv.sh lines 177–217):
```bash
# TOOLEV-01: tools create called with correct flags
if argv_vals "--name" | grep -q "^read$"; then
  pass "TOOLEV-01: tools create --name read found"
else
  fail "TOOLEV-01: tools create --name read NOT found"
fi
if argv_vals "--tool-id" | grep -q "^read$"; then
  pass "TOOLEV-01: tools create --tool-id read found"
else
  fail "TOOLEV-01: tools create --tool-id read NOT found"
fi
if argv_vals "--tool-type" | grep -q "^BUILTIN$"; then
  pass "TOOLEV-01: tools create --tool-type BUILTIN found"
else
  fail "TOOLEV-01: tools create --tool-type BUILTIN NOT found"
fi

# TOOLEV-02: meter tool-event called with correct flags
if argv_vals "--tool-id" | grep -q "^read$"; then
  pass "TOOLEV-02: meter tool-event --tool-id read found"
else
  fail "TOOLEV-02: meter tool-event --tool-id read NOT found"
fi
if argv_vals "--agent" | grep -q "^openclaw-"; then
  pass "TOOLEV-02: meter tool-event --agent openclaw-* found"
else
  fail "TOOLEV-02: meter tool-event --agent NOT found or wrong prefix"
fi
if grep -q "^--success$" "${ARGV_FILE}"; then
  pass "TOOLEV-02: --success flag present (explicit success)"
else
  fail "TOOLEV-02: --success flag NOT found"
fi
```

**Idempotency test pattern** (mirrors test_guardrail_argv.sh lines 437–445):
```bash
# Run twice; tools create must NOT appear a second time
run_report "${TMP_HOME}" "${ARGV_FILE}"
create_count=$(count_grep "^tools$" "${ARGV_FILE}")
if [[ "${create_count}" -eq 1 ]]; then
  pass "TOOLEV-01 idempotency: tools create called exactly once"
else
  fail "TOOLEV-01 idempotency: tools create count=${create_count}, expected 1"
fi
```

**Fail-open probe test pattern** (mirrors test_guardrail_argv.sh fail-open test):
```bash
STUB_REVENIUM_NO_TOOLS=1 run_report "${TMP_HOME_PROBE}" "${ARGV_FILE_PROBE}"
if ! grep -q "^tools$" "${ARGV_FILE_PROBE}"; then
  pass "TOOLEV-04: TOOLS_CLI_CAPABLE=false — no tools create called"
else
  fail "TOOLEV-04: tools create called despite probe failure"
fi
```

**Summary footer** (test_guardrail_argv.sh lines 580–591):
```bash
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
```

---

### `tests/stub-revenium.sh` — ADD tools + meter tool-event switches

**Analog:** `tests/stub-revenium.sh` existing STUB_REVENIUM_NO_JOBS / STUB_REVENIUM_JOBS_FAIL switches (lines 16–52, 129–143) and Phase 9 STUB_REVENIUM_GUARDRAILS_FAIL switch (lines 51–67)

**Existing switch documentation pattern to extend** (lines 16–52):
```bash
# Phase N additions:
#
#   STUB_REVENIUM_NO_TOOLS=1
#     When set, `tools --help` exits 1, forcing TOOLS_CLI_CAPABLE=false.
#     All meter tool-event and tools create calls are UNAFFECTED in terms of
#     routing — they never reach their branches. Use for fail-open tests.
#
#   STUB_REVENIUM_TOOLS_FAIL=1
#     When set, `tools create` exits 1 with a NON-409 error.
#     Exercises the fail-open path where registration fails but tool-event
#     emission continues. `meter tool-event` is UNAFFECTED.
```

**Existing capability probe response pattern to copy** (lines 129–135):
```bash
# jobs --help → exit 0 unless STUB_REVENIUM_NO_JOBS forces probe failure
if [[ "$1 $2" == "jobs --help" ]]; then
  if [[ -n "${STUB_REVENIUM_NO_JOBS:-}" ]]; then
    exit 1
  fi
  echo "usage: revenium jobs <subcommand>"
  exit 0
fi
```

**New probe responses to add** (after existing `jobs --help` block):
```bash
# tools --help → exit 0 unless STUB_REVENIUM_NO_TOOLS forces probe failure
if [[ "$1 $2" == "tools --help" ]]; then
  if [[ -n "${STUB_REVENIUM_NO_TOOLS:-}" ]]; then
    exit 1
  fi
  echo "usage: revenium tools <subcommand>"
  exit 0
fi

# meter tool-event --help → print a line with --tool-id so the dual probe
# sets TOOLS_CLI_CAPABLE=true. ONLY for this --help invocation.
if [[ "$1 $2 $3" == "meter tool-event --help" ]]; then
  echo "  --tool-id string    ID of the tool"
  exit 0
fi
```

**Existing jobs create/outcome failure pattern to copy** (lines 149–172):
```bash
if [[ "$1 $2" == "jobs create" || "$1 $2" == "jobs outcome" ]]; then
  if [[ -n "${STUB_REVENIUM_409_FOR:-}" ]] && printf '%s\n' "$@" | grep -qF -- "${STUB_REVENIUM_409_FOR}"; then
    echo "Error: 409 Conflict: job already exists" >&2
    exit 1
  fi
  if [[ -n "${STUB_REVENIUM_JOBS_FAIL:-}" ]]; then
    echo "Error: 500 jobs service unavailable" >&2
    exit 1
  fi
fi
```

**New tools create failure block to add** (after jobs create/outcome block):
```bash
# tools create — optional NON-409 failure (STUB_REVENIUM_TOOLS_FAIL)
if [[ "$1 $2" == "tools create" ]]; then
  if [[ -n "${STUB_REVENIUM_TOOLS_FAIL:-}" ]]; then
    echo "Error: 500 tools service unavailable" >&2
    exit 1
  fi
fi
```

**Existing default fallthrough** (line 177 — must remain last):
```bash
# 4. Default — exit 0 (meter completion posts, meter tool-event posts, etc.)
exit 0
```

---

## Shared Patterns

### Argv-array Discipline (T-04-09 / V5)
**Source:** `scripts/report.sh` lines 239–313 (`post_to_revenium`)
**Apply to:** `_register_tool` and `_meter_tool_event` in report.sh
```bash
local cmd=(revenium tools create --name "${tool_name}" --tool-id "${tool_id}" --quiet)
cmd+=(--optional-flag "${optional_value}")
local out exit_code
out=$("${cmd[@]}" 2>&1) && exit_code=0 || exit_code=$?
```
NEVER `eval`, NEVER `"${cmd[*]}"`.

### Env-passing Python Heredoc (Bash 3.2 Safe)
**Source:** `scripts/report.sh` lines 821–838 (duration computation)
**Apply to:** toolCall scan Python block in report.sh; normalize_tool_id helper
```bash
# Variables passed via env — NEVER ${} inside <<'PY' single-quoted heredoc
SESSION_FILE="${session_file}" python3 - <<'PY' 2>/dev/null || true
import os
val = os.environ.get('SESSION_FILE', '')
PY
```

### 409-as-Success Backstop
**Source:** `scripts/report.sh` lines 790–795 (jobs create)
**Apply to:** `_register_tool` in report.sh
```bash
elif echo "${jobs_cmd_output}" | grep -qi "409\|already.exist\|conflict"; then
  jobs_success=true   # 409-as-success backstop
fi
```

### Fail-open Return-0 Posture
**Source:** `scripts/guardrail-check.sh` lines 543–603 (`_emit_guardrail_event`)
**Apply to:** `_register_tool` and `_meter_tool_event` in report.sh
```bash
# Every _helper call uses || true since set -euo pipefail is active in callers.
# The function itself returns 0 on success, dedup-skip, and failure paths.
warn "... — fail-open"
return 0
```

### Ledger Dedup Gate (grep -qF)
**Source:** `scripts/guardrail-check.sh` lines 551–555 (`_emit_guardrail_event`)
**Apply to:** Both `_register_tool` and `_meter_tool_event`
```bash
local ledger_key="GUARDRAIL:${event_type}:${rule_id}:${onset_marker}"
if grep -qF "${ledger_key}" "${GUARDRAIL_LEDGER_FILE}" 2>/dev/null; then
  return 0   # already emitted this onset — skip silently
fi
```
Use `grep -qF` (fixed-string) not `grep -q` (regex) — safer for IDs containing special chars.

### Tool ID / Log Truncation (V5 / T-04-08)
**Source:** `scripts/report.sh` line 742 (agentic_job_id log truncation)
**Apply to:** Any `info`/`warn` using untrusted tool IDs
```bash
local tool_id_log="${tool_id:0:64}"
info "Tool registered: name=${tool_name} id=${tool_id_log} ..."
```

### Capability-gated Block (TOOLS_CLI_CAPABLE)
**Source:** `scripts/report.sh` lines 777–806 (JOBS_CLI_CAPABLE guard wrapping jobs create)
**Apply to:** toolCall scan loop and all `_register_tool`/`_meter_tool_event` calls
```bash
if [[ "${TOOLS_CLI_CAPABLE}" == "true" ]]; then
  # ... tool work here ...
fi
```

### ORG_NAME Optional Flag
**Source:** `scripts/report.sh` lines 276–279; `scripts/guardrail-check.sh` lines 585–587
**Apply to:** `_register_tool` and `_meter_tool_event`
```bash
if [[ -n "${ORG_NAME:-}" ]]; then
  cmd+=(--organization-name "${ORG_NAME}")
fi
```

---

## No Analog Found

All files have exact or near-exact analogs. No entries in this section.

---

## Key Constraints from Source

1. **`failed_count` / `reported_count` are never touched by tool work.** These counters gate CR-02 `set_offset`. Tool work failures use their own `warn` + `return 0` pattern — same as jobs create/outcome (D-12 / Pitfall 1 in RESEARCH.md).

2. **toolCall scan runs AFTER the completion `while IFS= read -r line` loop closes** (RESEARCH.md Anti-Patterns). A tool-work failure can never delay or skip completion stamping.

3. **Separate ledger files.** Tool-event dedup keys (`TOOLEV:`) go in `TOOL_EVENTS_LEDGER_FILE` (new), NOT in `LEDGER_FILE` (`revenium-reported.ledger`). This isolates CR-02 from tool-event failures (RESEARCH.md Open Question 2).

4. **`--success` flag defaults to `false` in CLI.** Always pass `--success` explicitly on success; pass `--success=false` on failure. Never omit it (RESEARCH.md Pitfall 2).

5. **Parallel toolCall items in one message** (RESEARCH.md Pitfall 3). The Python heredoc must iterate `msg.get('content', [])` and collect ALL items where `type=="toolCall"`, not just the first.

6. **toolResult linkage uses `toolCallId`, not `parentId`** (RESEARCH.md Pitfall 4). Build `tool_results` map keyed on `toolCallId`.

7. **Bash 3.2 portability.** No `${var,,}` lowercase. Use `python3 -c "import os; print(os.environ['TOOL_NAME'].lower())"` via env-passing (RESEARCH.md Pitfall 5).

8. **stub-revenium.sh argv capture block is FIRST and MUST remain first** (lines 71–77). New branches insert after it. Default `exit 0` remains last.

---

## Metadata

**Analog search scope:** `scripts/`, `tests/`
**Files scanned:** `common.sh` (168 lines, full read); `report.sh` (1252 lines, targeted: lines 1–120, 213–322, 520–570, 770–860, 900–950, 1236–1252); `guardrail-check.sh` (661 lines, targeted: lines 533–603); `stub-revenium.sh` (177 lines, full read); `test_guardrail_argv.sh` (591 lines, lines 1–219); `test_report_jobs_argv.sh` (lines 1–80); `09-PATTERNS.md` (650 lines, full read)
**Pattern extraction date:** 2026-06-04
