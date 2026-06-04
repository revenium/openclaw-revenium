# Phase 9: Guardrail Event Metering - Pattern Map

**Mapped:** 2026-06-03
**Files analyzed:** 5 (3 modified, 1 created, 1 modified)
**Analogs found:** 5 / 5

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `scripts/guardrail-check.sh` (MODIFY) | service | event-driven | `scripts/guardrail-check.sh` itself (shadow_transitions pattern); `scripts/report.sh` post_to_revenium + handle_halt | exact (same file extended) |
| `scripts/report.sh` (MODIFY – 3-line deletion) | service | request-response | n/a — deletion only | n/a |
| `scripts/common.sh` (MODIFY – add 2 constants) | config | n/a | `scripts/common.sh` Phase 4 path constants block (lines 49–57) | exact |
| `tests/test_guardrail_argv.sh` (CREATE) | test | request-response | `tests/test_report_argv.sh` | exact |
| `tests/stub-revenium.sh` (MODIFY – add guardrails switch) | utility | request-response | `tests/stub-revenium.sh` existing STUB_REVENIUM_HALT_JOBS_FAIL switch (lines 34–52, 108–115) | exact |

---

## Pattern Assignments

### `scripts/guardrail-check.sh` — ADD warn-onset detection in Python block

**Analog:** existing `shadow_transitions` block in `scripts/guardrail-check.sh` lines 268–287

**Existing shadow_transitions pattern to mirror** (lines 268–287):
```python
prev_rules_by_id = {
    pr.get('ruleId'): pr
    for pr in prev.get('rules', [])
    if pr.get('ruleId')
}
shadow_transitions = []
for nr in new_rules:
    if nr.get('shadowMode') and nr.get('state') == 'block':
        pr = prev_rules_by_id.get(nr.get('ruleId'))
        # transition if: no prev rule OR prev wasn't blocking OR prev wasn't shadow-mode
        if (pr is None) or (pr.get('state') != 'block') or (not pr.get('shadowMode')):
            shadow_transitions.append({
                'ruleId': nr['ruleId'],
                'name': nr['name'],
                'metricType': nr.get('metricType', ''),
                'windowType': nr.get('windowType', ''),
                'currentValue': nr['currentValue'],
                'hardLimit': nr['hardLimit'],
            })
```

**New warn_transitions block** — insert immediately after the `shadow_transitions` block (after line 287), before the `# Build output document` comment (line 289). Reuses `prev_rules_by_id` already built above; no second construction:
```python
warn_transitions = []
for nr in new_rules:
    # warnBreached but NOT breached (state=='warn', not 'block') and not shadow
    if nr.get('state') == 'warn' and not nr.get('shadowMode', False):
        pr = prev_rules_by_id.get(nr.get('ruleId'))
        # onset edge: no prev rule OR prev was NOT in warn state
        if (pr is None) or (pr.get('state') != 'warn'):
            warn_transitions.append({
                'ruleId': nr['ruleId'],
                'name': nr['name'],
                'metricType': nr.get('metricType', ''),
                'windowType': nr.get('windowType', ''),
                'currentValue': nr['currentValue'],
                'hardLimit': nr['hardLimit'],
                'warnThreshold': nr.get('warnThreshold', 0),
            })
```

**Critical difference from shadow_transitions:** condition is `state == 'warn'` (NOT `state == 'block'`), and transition guard is `pr.get('state') != 'warn'` (NOT `!= 'block'`). Also requires `not nr.get('shadowMode', False)` to exclude shadow rules.

---

### `scripts/guardrail-check.sh` — ADD HALTED_AT and WARN_TRANSITIONS emit lines in Python block

**Analog:** existing emit block at lines 320–331 (HALT_TRANSITION emit pattern):
```python
# lines 320–331
print(f"HALT_TRANSITION={'true' if halt_transition else 'false'}")
if halt_transition and halted_rule:
    print(f"HALTED_RULE_NAME={halted_rule['name']}")
    print(f"HALTED_RULE_ID={halted_rule['ruleId']}")
    print(f"HALTED_METRIC_TYPE={halted_rule['metricType']}")
    print(f"HALTED_WINDOW_TYPE={halted_rule['windowType']}")
    print(f"HALTED_CURRENT_VALUE={halted_rule['currentValue']}")
    print(f"HALTED_HARD_LIMIT={halted_rule['hardLimit']}")
# line 331
print(f"SHADOW_TRANSITIONS={json.dumps(shadow_transitions)}")
```

**Add these two print lines** — `HALTED_AT` immediately after the existing HALTED_RULE_* block (after line 328), `WARN_TRANSITIONS` immediately after `SHADOW_TRANSITIONS` (after line 331):
```python
    # add after HALTED_HARD_LIMIT print (line 328):
    if halt_transition:
        print(f"HALTED_AT={halted_at}")
# add after SHADOW_TRANSITIONS print (line 331):
print(f"WARN_TRANSITIONS={json.dumps(warn_transitions)}")
```

`WARN_TRANSITIONS` is always emitted (even as `[]`) — same pattern as `SHADOW_TRANSITIONS`. `HALTED_AT` is emitted only when `halt_transition` is true — same conditional pattern as the existing HALTED_RULE_* lines.

---

### `scripts/guardrail-check.sh` — ADD bash sed extraction for WARN_TRANSITIONS and HALTED_AT

**Analog:** existing sed extraction at lines 341 and 356–361:
```bash
# line 341 — template to mirror for WARN_TRANSITIONS
SHADOW_TRANSITIONS_JSON=$(echo "${HALT_OUTPUT}" | sed -n 's/^SHADOW_TRANSITIONS=//p')

# lines 356–361 — template to mirror for HALTED_AT extraction
HALTED_RULE_NAME=$(echo "${HALT_OUTPUT}" | sed -n 's/^HALTED_RULE_NAME=//p')
HALTED_RULE_ID=$(echo "${HALT_OUTPUT}" | sed -n 's/^HALTED_RULE_ID=//p')
```

**Add immediately after line 341** (after `SHADOW_TRANSITIONS_JSON=` extraction):
```bash
WARN_TRANSITIONS_JSON=$(echo "${HALT_OUTPUT}" | sed -n 's/^WARN_TRANSITIONS=//p')
HALTED_AT=$(echo "${HALT_OUTPUT}" | sed -n 's/^HALTED_AT=//p')
```

---

### `scripts/guardrail-check.sh` — ADD Section M: `_emit_guardrail_event` function + calls

**Analog:** `post_to_revenium` in `scripts/report.sh` lines 240–315 (argv-array discipline, conditional flag appending, exit-code handling).

**post_to_revenium core pattern** (report.sh lines 240–315) to mirror for `_emit_guardrail_event`:
```bash
# report.sh lines 240–258: argv-array construction
local cmd=(
  revenium meter completion
  --model "${model}"
  --provider "${provider}"
  --input-tokens "${input_tokens}"
  --output-tokens "${output_tokens}"
  --total-tokens "${total_tokens}"
  --cache-read-tokens "${cache_read_tokens}"
  --cache-creation-tokens "${cache_creation_tokens}"
  --stop-reason "${stop_reason}"
  --request-time "${request_time}"
  --completion-start-time "${request_time}"
  --response-time "${response_time}"
  --request-duration "${duration_ms}"
  --agent "${REVENIUM_AGENT_PREFIX}${root_sid}"
  --task-type "${task_type:-unclassified}"
  --transaction-id "${transaction_id}"
  --operation-type "${operation_type}"
  --quiet
)

# report.sh lines 296–302: conditional agentic-job append
if [[ "${JOBS_CLI_CAPABLE}" == "true" && -n "${agentic_job_id}" ]]; then
  cmd+=(--agentic-job-id "${agentic_job_id}")
  [[ -n "${agentic_job_name}" ]] && cmd+=(--agentic-job-name "${agentic_job_name}")
  [[ -n "${agentic_job_type}" ]] && cmd+=(--agentic-job-type "${agentic_job_type}")
fi

# report.sh lines 304–315: execution + exit code handling
local cmd_output cmd_exit
cmd_output=$("${cmd[@]}" 2>&1) && cmd_exit=0 || cmd_exit=$?
if [[ "${cmd_exit}" -eq 0 ]]; then
  info "Reported: model=${model} ..."
  return 0
else
  warn "Failed to report: model=${model} txId=${transaction_id} exit=${cmd_exit}"
  warn "Command: ${cmd[*]}"
  warn "Output: ${cmd_output}"
  return 1
fi
```

**Also mirror ORG_NAME conditional** (report.sh lines 277–279):
```bash
if [[ -n "${ORG_NAME}" ]]; then
  cmd+=(--organization-name "${ORG_NAME}")
fi
```

**ORG_NAME source:** In guardrail-check.sh use the existing `read_config_field` helper (lines 83–92) — add `ORG_NAME=$(read_config_field organizationName)` near lines 95–97 where other config fields are read.

**JOB:halt dedup gate** (report.sh lines 1062–1065):
```bash
# report.sh lines 1062–1065
if grep -q "^JOB:halt:${HALTED_AT}$" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
  return 0   # halt already processed this haltedAt — idempotent skip
fi
# on success:
echo "JOB:halt:${HALTED_AT}" >> "${JOBS_LEDGER_FILE}"  # line 1200
```

Mirror this for GUARDRAIL ledger using `grep -qF` (fixed-string, safer for ISO timestamps):
```bash
local ledger_key="GUARDRAIL:${event_type}:${rule_id}:${onset_marker}"
if grep -qF "${ledger_key}" "${GUARDRAIL_LEDGER_FILE}" 2>/dev/null; then
  return 0   # already emitted this onset
fi
# on success:
printf '%s\n' "${ledger_key}" >> "${GUARDRAIL_LEDGER_FILE}"
```

**Open-job scan** (report.sh lines 1086–1105) to adapt for D-07/D-08 most-recently-opened-job lookup. The original scans all open jobs for closing; the guardrail variant picks only the newest one:
```bash
# report.sh lines 1086–1105 (original)
OPEN_JOBS=$(
  JOBS_LEDGER_FILE="${JOBS_LEDGER_FILE}" \
  python3 - <<'PY' 2>/dev/null || true
import os, re
ledger = os.environ.get('JOBS_LEDGER_FILE', '')
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

**Adapted version for guardrail-check.sh** — returns the single most-recently-created open job (D-08: "most-recently-opened one"). Uses `created = {}` dict (id → line index) instead of set to enable ordering:
```bash
OPEN_JOB_ID=$(
  JOBS_LEDGER_FILE="${JOBS_LEDGER_FILE}" \
  python3 - <<'PY' 2>/dev/null || true
import os, re
ledger = os.environ.get('JOBS_LEDGER_FILE', '')
created = {}   # id -> line index for newest-first ordering
closed = set()
try:
    lines = open(ledger, encoding='utf-8').readlines()
    for i, line in enumerate(lines):
        line = line.strip()
        m = re.match(r'^JOB:([^:]+):created:', line)
        if m: created[m.group(1)] = i
        m = re.match(r'^JOB:([^:]+):outcome:', line)
        if m: closed.add(m.group(1))
except Exception:
    pass
open_jobs = [(v, k) for k, v in created.items() if k not in closed]
if open_jobs:
    print(sorted(open_jobs)[-1][1])  # highest line index = most-recently-created
PY
) || true
```

**Env-passing heredoc rule** (Bash 3.2 safe): all Python heredocs use `VAR="${VAR}" python3 - <<'PY'` and `os.environ['VAR']` inside. Never `${}` inside `<<'PY'`.

**Section M sequencing** — append after the final line of Section L (line 446, `fi` closing shadow notifications). This ensures status file is durable and notifications dispatched first (D-11):
```bash
# ---------------------------------------------------------------------------
# (M) Guardrail event metering — fail-open (D-11).
# Status file is durable and notifications dispatched before this point.
# ---------------------------------------------------------------------------
```

**Failure posture for Section M:** Every `_emit_guardrail_event` call must be wrapped with `|| true` since `set -euo pipefail` is active (line 17). The function itself returns 0 on both success and fail paths (warn-logs on failure, never returns 1).

**Root session lookup** — guardrail-check.sh already sources common.sh which defines `get_root_session_id` (common.sh lines 152–160) and `SESSIONS_DIR` (common.sh line 57). macOS-portable newest-session lookup:
```bash
# macOS-portable (no find -printf); uses ls -t for mtime ordering
local newest_session_id=""
newest_session_id=$(
  ls -t "${SESSIONS_DIR}"/*.jsonl 2>/dev/null | head -1 \
  | xargs basename 2>/dev/null | sed 's/\.jsonl$//'
) || true
local root_sid="${newest_session_id}"
if [[ -n "${newest_session_id}" ]]; then
  root_sid=$(get_root_session_id "${newest_session_id}")
  root_sid="${root_sid:-${newest_session_id}}"
fi
local agent_val="${REVENIUM_AGENT_PREFIX}${root_sid}"
```

**Ledger touch guard** — add at the top of Section M before any grep/append:
```bash
touch "${GUARDRAIL_LEDGER_FILE}" 2>/dev/null || true
```

---

### `scripts/report.sh` — DELETE lines 849–851 (D-12 GUARDRAIL heuristic)

**Exact lines to delete** (lines 849–851, currently inside the operation_type detection block at lines 843–853):
```bash
    if echo "${line}" | jq -e '.message.content[] | select(.type=="toolCall") | .arguments' 2>/dev/null | grep -q "budget-status.json"; then
      operation_type="GUARDRAIL"
    elif [[ "${raw_stop_reason}" == "toolUse" || "${raw_stop_reason}" == "tool_use" ]]; then
```

**After deletion** — the `if` block at line 843 becomes:
```bash
    local raw_stop_reason operation_type="CHAT"
    raw_stop_reason=$(echo "${line}" | jq -r '.message.stopReason // "stop"')
    if [[ "${raw_stop_reason}" == "toolUse" || "${raw_stop_reason}" == "tool_use" ]]; then
      operation_type="TOOL_CALL"
    fi
```

The surrounding comment block (lines 843–846) should also be updated to remove the GUARDRAIL line.

---

### `scripts/common.sh` — ADD two path constants

**Analog:** Phase 4 path constants block (lines 49–57):
```bash
# common.sh lines 49–57 (existing pattern to extend)
# Phase 4 path constants (METER-01 / D-07).
TAXONOMY_FILE="${STATE_DIR}/task-taxonomy.json"
JOB_TAXONOMY_FILE="${STATE_DIR}/job-taxonomy.json"
MARKERS_DIR="${STATE_DIR}/markers"
SESSIONS_DIR="${OPENCLAW_HOME}/agents/main/sessions"
```

**New constants to insert** — append immediately after line 57 (`SESSIONS_DIR=...`), before the blank line that separates the path constants block from `REVENIUM_AGENT_NAME`:

```bash
# Phase 9 path constants (GRDEV-01..05).
# GUARDRAIL_LEDGER_FILE: append-only dedup ledger for guardrail event metering.
# JOBS_LEDGER_FILE: read-only consumer from guardrail-check.sh for open-job attribution.
#   Identical path to report.sh's JOBS_LEDGER_FILE (must stay in sync).
GUARDRAIL_LEDGER_FILE="${OPENCLAW_HOME}/revenium-guardrail.ledger"
JOBS_LEDGER_FILE="${REVENIUM_JOBS_LEDGER_FILE:-${OPENCLAW_HOME}/revenium-jobs.ledger}"
```

**Note:** `JOBS_LEDGER_FILE` in report.sh (line 35) uses the same expansion: `"${REVENIUM_JOBS_LEDGER_FILE:-${OPENCLAW_HOME}/revenium-jobs.ledger}"`. The paths must be byte-identical so both scripts reference the same physical file.

---

### `tests/test_guardrail_argv.sh` — CREATE hermetic test

**Analog:** `tests/test_report_argv.sh` (entire file) — mirrors structure exactly.

**Header and boilerplate pattern** (test_report_argv.sh lines 1–43):
```bash
#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
GUARDRAIL_CHECK_SH="${REPO_ROOT}/scripts/guardrail-check.sh"
STUB_SH="${SCRIPT_DIR}/stub-revenium.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
```

**make_openclaw_home helper** — mirror `test_report_jobs_argv.sh` lines 48–63 (reusable factory function). Guardrail variant needs additional fixtures:
```bash
make_openclaw_home() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-gc-home.XXXXXX")
  mkdir -p "${d}/agents/main/sessions" \
           "${d}/skills/revenium/markers" \
           "${d}/skills/revenium/scripts"
  ln -sf "${REPO_ROOT}/scripts/get-root-session-id.py" \
         "${d}/skills/revenium/scripts/get-root-session-id.py"
  touch "${d}/revenium-guardrail.ledger"
  touch "${d}/revenium-jobs.ledger"
  echo '{"organizationName":"TestOrg","ruleIds":["rule-abc123"]}' \
    > "${d}/skills/revenium/config.json"
  # Minimal guardrail-status.json (prev state: no rules breached)
  echo '{"halted":false,"warned":false,"warnedRules":[],"autonomousMode":true,"lastChecked":"2026-01-01T00:00:00+00:00","rules":[]}' \
    > "${d}/skills/revenium/guardrail-status.json"
  echo "${d}"
}
```

**Fake HOME / stub placement pattern** (test_report_argv.sh lines 164–177):
```bash
TMP_FAKE_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-gc-fakehome.XXXXXX")
TMP_LOCAL_BIN="${TMP_FAKE_HOME}/.local/bin"
mkdir -p "${TMP_LOCAL_BIN}"
ln -sf "${STUB_SH}" "${TMP_LOCAL_BIN}/revenium"
ARGV_FILE=$(mktemp "${TMPDIR:-/tmp}/test-gc-argv.XXXXXX")

cleanup() {
  rm -rf "${TMP_HOME}" "${TMP_FAKE_HOME}" "${ARGV_FILE}" 2>/dev/null || true
}
trap cleanup EXIT

export STUB_REVENIUM_ARGV_FILE="${ARGV_FILE}"
```

**run_guardrail_check helper** — mirror `run_report` from test_report_jobs_argv.sh lines 98–108:
```bash
run_guardrail_check() {
  local openclaw_home="$1"
  local _argv_file="$2"
  shift 2
  local -a extra_env=("$@")
  STUB_REVENIUM_ARGV_FILE="${_argv_file}" \
  OPENCLAW_HOME="${openclaw_home}" \
  HOME="${TMP_FAKE_HOME}" \
  "${extra_env[@]+"${extra_env[@]}"}" \
  bash "${GUARDRAIL_CHECK_SH}" 2>&1 || true
}
```

**Fixture injection strategy for guardrail-check.sh:** The stub must handle:
- `config show` → emit `Team ID:    test-team-id` (guardrail-check.sh line 101 parses this)
- `guardrails enforcement-rules get test-team-id --output json` → fixture JSON with a halted/warned/shadow rule
- `guardrails budget-rules list --output json` → fixture JSON with matching name→string-id map
- `guardrails --help` / `guardrails budget-rules --help` / `guardrails enforcement-events --help` → exit 0 (capability probe at lines 58–73)
- `meter completion` → default exit 0 (argv captured)

**Assertion pattern** (mirror test_report_argv.sh lines 190–200):
```bash
argv_vals() { awk -v flag="$1" '$0==flag{getline;print}' "${ARGV_FILE}" 2>/dev/null || true; }

# GRDEV-01: halt emits --operation-type GUARDRAIL --task-type budget_guardrail_halt
if argv_vals "--operation-type" | grep -q "^GUARDRAIL$"; then
  pass "GRDEV-01: --operation-type GUARDRAIL found"
else
  fail "GRDEV-01: --operation-type GUARDRAIL NOT found"
fi
if argv_vals "--task-type" | grep -q "^budget_guardrail_halt$"; then
  pass "GRDEV-01: --task-type budget_guardrail_halt found"
else
  fail "GRDEV-01: --task-type budget_guardrail_halt NOT found"
fi
```

**Idempotency test pattern** — run twice, assert argv file has exactly 1 GUARDRAIL meter call per event type:
```bash
# Run twice to test idempotency
run_guardrail_check "${TMP_HOME}" "${ARGV_FILE}"
run_guardrail_check "${TMP_HOME}" "${ARGV_FILE}"
halt_count=$(grep -c "^budget_guardrail_halt$" "${ARGV_FILE}" 2>/dev/null || echo 0)
if [[ "${halt_count}" -eq 1 ]]; then
  pass "GRDEV-01 idempotency: halt emitted exactly once (ledger dedup worked)"
else
  fail "GRDEV-01 idempotency: halt count=${halt_count}, expected 1"
fi
```

**Fail-open test** — mirror stub_no_jobs pattern with new STUB_REVENIUM_GUARDRAILS_FAIL:
```bash
# Assert guardrail-check.sh exits 0 even when meter call fails
exit_code=0
STUB_REVENIUM_GUARDRAILS_FAIL=1 \
  run_guardrail_check "${TMP_HOME2}" "${ARGV_FILE2}" || exit_code=$?
if [[ "${exit_code}" -eq 0 ]]; then
  pass "GRDEV-05: guardrail-check.sh exits 0 when meter call fails (fail-open)"
else
  fail "GRDEV-05: guardrail-check.sh exited ${exit_code} — fail-open broken"
fi
```

**Summary footer** (test_report_argv.sh lines 302–309):
```bash
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
```

---

### `tests/stub-revenium.sh` — ADD guardrail stub responses + STUB_REVENIUM_GUARDRAILS_FAIL switch

**Analog:** existing STUB_REVENIUM_HALT_JOBS_FAIL switch (lines 34–52, 108–115) and `config show` response (lines 69–71).

**Existing config show pattern** (lines 69–71):
```bash
if [[ "$1 $2" == "config show" ]]; then
  exit 0
fi
```

**Modify to emit Team ID** (guardrail-check.sh line 101 parses `"Team ID:    <id>"`):
```bash
if [[ "$1 $2" == "config show" ]]; then
  echo "Team ID:    test-team-id"
  exit 0
fi
```

**Add guardrails capability probe responses** — insert after the `config show` block (after line 71), before `jobs --help`:
```bash
# guardrails --help and subcommand --help probes → exit 0 (satisfies has_guardrails_cli)
if [[ "$1" == "guardrails" && "$2" == "--help" ]]; then
  echo "usage: revenium guardrails <subcommand>"
  exit 0
fi
if [[ "$1 $2 $3" == "guardrails budget-rules --help" ]]; then
  echo "usage: revenium guardrails budget-rules <subcommand>"
  exit 0
fi
if [[ "$1 $2 $3" == "guardrails enforcement-events --help" ]]; then
  echo "usage: revenium guardrails enforcement-events <subcommand>"
  exit 0
fi
```

**Add enforcement-rules get and budget-rules list responses:**
```bash
# guardrails enforcement-rules get → fixture JSON (or STUB_REVENIUM_GUARDRAILS_FAIL)
if [[ "$1 $2 $3" == "guardrails enforcement-rules get" ]]; then
  if [[ -n "${STUB_REVENIUM_GUARDRAILS_FAIL:-}" ]]; then
    echo '{"error":"EOF"}' >&2
    exit 1
  fi
  # Emit fixture controlled by STUB_REVENIUM_ENFORCEMENT_JSON env var, or default halt fixture
  if [[ -n "${STUB_REVENIUM_ENFORCEMENT_JSON:-}" ]]; then
    echo "${STUB_REVENIUM_ENFORCEMENT_JSON}"
  else
    echo '{"rules":[]}'
  fi
  exit 0
fi

# guardrails budget-rules list → fixture JSON
if [[ "$1 $2 $3" == "guardrails budget-rules list" ]]; then
  if [[ -n "${STUB_REVENIUM_BUDGET_RULES_JSON:-}" ]]; then
    echo "${STUB_REVENIUM_BUDGET_RULES_JSON}"
  else
    echo '[]'
  fi
  exit 0
fi
```

**STUB_REVENIUM_GUARDRAILS_FAIL switch documentation comment** to add to the header (mirror existing switch docs at lines 16–52):
```bash
#   STUB_REVENIUM_GUARDRAILS_FAIL=1
#     When set, `guardrails enforcement-rules get` exits 1 with an EOF-style
#     error. Exercises the fail-open fallback path in guardrail-check.sh.
#     `meter completion`, `config show`, and `jobs` calls are UNAFFECTED.
#
#   STUB_REVENIUM_ENFORCEMENT_JSON=<json>
#     When set, returned as the body of `guardrails enforcement-rules get`.
#     Default when unset: '{"rules":[]}'.
#
#   STUB_REVENIUM_BUDGET_RULES_JSON=<json>
#     When set, returned as the body of `guardrails budget-rules list`.
#     Default when unset: '[]'.
```

**Argv capture placement:** The argv capture block (lines 58–62) is already `if [[ -n "${STUB_REVENIUM_ARGV_FILE:-}" ]]; then ... fi` at the top of the file — it captures ALL invocations before any branching. This must remain first and unchanged.

---

## Shared Patterns

### Env-passing Heredoc (Bash 3.2 Safe)
**Source:** `scripts/guardrail-check.sh` lines 83–92 (read_config_field), lines 122–129 (Section G Python block preamble)
**Apply to:** ALL new Python heredocs in guardrail-check.sh

Pattern:
```bash
# Variables passed via environment — NEVER ${}  inside <<'PY'
VAR1="${bash_var1}" VAR2="${bash_var2}" python3 - <<'PY'
import os
val1 = os.environ['VAR1']
val2 = os.environ['VAR2']
PY
```

### Fail-open Command Substitution
**Source:** `scripts/guardrail-check.sh` lines 36–43, 45–46, 109, 117
**Apply to:** All `$( ... )` subshells in Section M

Pattern:
```bash
result=$(some_command 2>/dev/null) || true
```

### Bash-array argv Discipline
**Source:** `scripts/report.sh` lines 240–302 (post_to_revenium)
**Apply to:** `_emit_guardrail_event` function in guardrail-check.sh

Pattern:
```bash
local cmd=(revenium meter completion --flag "${value}")
cmd+=(--optional-flag "${optional_value}")
local out exit_code
out=$("${cmd[@]}" 2>&1) && exit_code=0 || exit_code=$?
```
NEVER `eval`, NEVER `"${cmd[*]}"` (word-splits on spaces in values).

### Logging Conventions
**Source:** `scripts/common.sh` lines 116–128 (log/info/warn/error)
**Apply to:** All new shell code in guardrail-check.sh Section M

Guardrail-check.sh sources common.sh and has `info`/`warn` available. Use:
- `info "GUARDRAIL: emitted ${event_type} for rule ${rule_id}"` — on success
- `warn "GUARDRAIL: meter call failed (exit=${exit_code}) — fail-open, continuing"` — on failure

### Pipe-delimited Temp-file Loop (Bash 3.2 / no `<<<` in subshells)
**Source:** `scripts/guardrail-check.sh` lines 421–445 (shadow notification loop)
**Apply to:** Any multi-value iteration over warn_transitions or shadow_transitions in Section M

Pattern:
```bash
LOOP_TMP=$(mktemp)
TRANSITIONS_JSON="${transitions_json}" python3 - <<'PY' > "${LOOP_TMP}"
import json, os
for r in json.loads(os.environ['TRANSITIONS_JSON']):
    print(f"{r['ruleId']}|{r['name']}")
PY
while IFS='|' read -r RULE_ID RULE_NAME; do
  [[ -z "${RULE_ID}" ]] && continue
  # ... process ...
done < "${LOOP_TMP}"
rm -f "${LOOP_TMP}"
```

---

## No Analog Found

All files have analogs. No entries in this section.

---

## Key Constraints Extracted from Source

1. **`set -euo pipefail` active in guardrail-check.sh (line 17).** Every new function must return 0 on all paths. Callers use `function_call || true`.

2. **`_PATH_HEAD` stub-preservation pattern** (guardrail-check.sh lines 27–29): test harnesses prepend stub dirs to PATH before running the script; the `_PATH_HEAD` re-prepend keeps stubs first. New code must not reset `PATH` unconditionally.

3. **D-13 silent exit guard runs first** (lines 36–52): Section M is unreachable when ruleIds is empty — correct behavior, no metering without configured rules.

4. **Status file durability ordering** (per D-11): `guardrail-status.json` is atomically written in Section G (line 333 `|| { warn ...; exit 0; }`). Section M only runs when Section G succeeded.

5. **`JOBS_LEDGER_FILE` in common.sh must be byte-identical to report.sh line 35**: `"${REVENIUM_JOBS_LEDGER_FILE:-${OPENCLAW_HOME}/revenium-jobs.ledger}"`. Any divergence silently creates two different ledger files.

6. **stub-revenium.sh `config show` must now emit `"Team ID:    test-team-id"`** for guardrail-check.sh tests. This is a change from the current silent `exit 0`. Verify this does not break existing test_report_argv.sh assertions (report.sh line 107 uses `revenium config show &>/dev/null` — only checks exit code, not output — safe to add output).

---

## Metadata

**Analog search scope:** `scripts/`, `tests/`
**Files scanned:** guardrail-check.sh (447 lines, full read), common.sh (161 lines, full read), report.sh (lines 1–100, 220–316, 835–855, 1050–1205), test_report_argv.sh (310 lines, full read), test_report_jobs_argv.sh (lines 1–120), stub-revenium.sh (122 lines, full read)
**Pattern extraction date:** 2026-06-03
