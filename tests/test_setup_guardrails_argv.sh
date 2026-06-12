#!/usr/bin/env bash
# test_setup_guardrails_argv.sh — Integration test for setup-guardrails.sh
# Plan 04-03 Task 2: argv-capture tests for:
#   (a) base rule: AGENT:STARTS_WITH:openclaw- + --group-by AGENT
#   (b) per-task rule: AGENT:STARTS_WITH:openclaw- + TASK_TYPE:IS:<label> + --group-by TASK_TYPE
#   (c) gate: when --help lacks TASK_TYPE, picker is skipped (only base rule created)
# Suite C (260605-enh): idempotent dedup — list-before-create ordering, single-match
#   adopt, multi-match warn+skip, and label-in-name.
#
# REVENIUM_BIN env var injects the stub after ensure_path runs (setup-guardrails.sh
# prepends $(dirname REVENIUM_BIN) to PATH, defeating ensure_path's brew-prepend).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0
ERRORS=""

fail() {
  FAIL=$((FAIL + 1))
  local msg="FAIL: $*"
  ERRORS="${ERRORS}${msg}
"
  printf '%s\n' "${msg}" >&2
}

pass() {
  PASS=$((PASS + 1))
  printf 'PASS: %s\n' "$*"
}

# ---------------------------------------------------------------------------
# Setup: tmp work area
# ---------------------------------------------------------------------------
TMPDIR_ROOT=$(mktemp -d)
trap 'rm -rf "${TMPDIR_ROOT}"' EXIT

STUB_BIN="${TMPDIR_ROOT}/bin"
mkdir -p "${STUB_BIN}"

# OPENCLAW_HOME: needs an agents/ subdir so the discovery probe passes
FAKE_HOME="${TMPDIR_ROOT}/openclaw"
FAKE_SKILL_DIR="${FAKE_HOME}/skills/revenium"
mkdir -p "${FAKE_HOME}/agents"
mkdir -p "${FAKE_SKILL_DIR}"

# Seed taxonomy (common.sh sets TAXONOMY_FILE=${STATE_DIR}/task-taxonomy.json)
cp "${REPO_ROOT}/task-taxonomy.json" "${FAKE_SKILL_DIR}/task-taxonomy.json"

# Invocation log file (budget-rules create)
INVOCATION_FILE="${TMPDIR_ROOT}/invocations.txt"
: > "${INVOCATION_FILE}"

# Update invocation log (budget-rules update)
UPDATE_FILE="${TMPDIR_ROOT}/updates.txt"
: > "${UPDATE_FILE}"

# Order file (LIST/CREATE/UPDATE tags for ordering assertions)
ORDER_FILE="${TMPDIR_ROOT}/order.txt"
: > "${ORDER_FILE}"

# ---------------------------------------------------------------------------
# Stub: revenium — env-driven (INVOCATION_FILE, HELP_HAS_TASK_TYPE,
# STUB_REVENIUM_BUDGET_RULES_JSON, ORDER_FILE exported by run_interactive;
# REVENIUM_BIN tells setup-guardrails.sh to prepend our bin dir to PATH
# after ensure_path, so the stub wins).
# ---------------------------------------------------------------------------
cat > "${STUB_BIN}/revenium" <<'STUB'
#!/usr/bin/env bash
# stubbed revenium for integration testing
# reads INVOCATION_FILE, HELP_HAS_TASK_TYPE, STUB_REVENIUM_BUDGET_RULES_JSON,
# ORDER_FILE, UPDATE_FILE from env

ARGS_STR="$*"
case "${ARGS_STR}" in
  *"budget-rules --help"*|"guardrails budget-rules")
    exit 0
    ;;
  *"enforcement-events --help"*|"guardrails enforcement-events")
    exit 0
    ;;
  *"budget-rules create --help"*|"guardrails budget-rules create --help")
    if [[ -n "${HELP_HAS_TASK_TYPE:-}" ]]; then
      echo "Usage: revenium guardrails budget-rules create"
      echo "  --filter stringArray  Dimensions: AGENT, TASK_TYPE, MODEL"
      echo "  --group-by string     One of AGENT, TASK_TYPE"
    else
      echo "Usage: revenium guardrails budget-rules create"
      echo "  --filter stringArray  Dimensions: AGENT, MODEL"
      echo "  --group-by string     One of AGENT, MODEL"
    fi
    exit 0
    ;;
  *"budget-rules list"*)
    if [[ -n "${ORDER_FILE:-}" ]]; then
      printf 'LIST\n' >> "${ORDER_FILE}"
    fi
    if [[ -n "${STUB_REVENIUM_BUDGET_RULES_JSON:-}" ]]; then
      printf '%s\n' "${STUB_REVENIUM_BUDGET_RULES_JSON}"
    else
      printf '[]\n'
    fi
    exit 0
    ;;
  *"budget-rules get"*)
    # argv: guardrails budget-rules get <id> --output json
    RULE_ID="${4:-rule-id}"
    printf '{"id":"%s","shadowMode":false,"name":"test","hardLimit":100,"warnThreshold":80,"windowType":"MONTHLY"}\n' "${RULE_ID}"
    exit 0
    ;;
  *"budget-rules delete"*)
    exit 0
    ;;
  *"budget-rules update"*)
    if [[ -n "${UPDATE_FILE:-}" ]]; then
      printf 'UPDATE\n' >> "${UPDATE_FILE}"
      for arg in "$@"; do
        printf '%s\n' "${arg}" >> "${UPDATE_FILE}"
      done
    fi
    if [[ -n "${ORDER_FILE:-}" ]]; then
      printf 'UPDATE\n' >> "${ORDER_FILE}"
    fi
    exit 0
    ;;
  *"budget-rules create"*)
    if [[ -n "${INVOCATION_FILE:-}" ]]; then
      printf 'INVOKE\n' >> "${INVOCATION_FILE}"
      for arg in "$@"; do
        printf '%s\n' "${arg}" >> "${INVOCATION_FILE}"
      done
    fi
    if [[ -n "${ORDER_FILE:-}" ]]; then
      printf 'CREATE\n' >> "${ORDER_FILE}"
    fi
    printf '{"id":"rule-stub-test","shadowMode":false}\n'
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "${STUB_BIN}/revenium"

# ---------------------------------------------------------------------------
# count_invocations: count INVOKE lines in INVOCATION_FILE
# ---------------------------------------------------------------------------
count_invocations() {
  python3 -c "
try:
    n = sum(1 for line in open('${INVOCATION_FILE}') if line.strip() == 'INVOKE')
    print(n)
except Exception:
    print(0)
"
}

# ---------------------------------------------------------------------------
# get_invocation N: return all args for invocation N (1-indexed), newline-sep
# ---------------------------------------------------------------------------
get_invocation() {
  local n="$1"
  python3 - <<PY
try:
    with open("${INVOCATION_FILE}") as f:
        content = f.read()
    # Split on INVOKE\n separators
    blocks = []
    current = []
    for line in content.splitlines():
        if line.strip() == "INVOKE":
            if current:
                blocks.append("\n".join(current))
            current = []
        else:
            current.append(line)
    if current:
        blocks.append("\n".join(current))
    n = int("${n}") - 1
    if 0 <= n < len(blocks):
        print(blocks[n])
except Exception:
    pass
PY
}

# ---------------------------------------------------------------------------
# assert helpers
# ---------------------------------------------------------------------------
assert_contains() {
  local n="$1" expected="$2" name="$3"
  local args
  args=$(get_invocation "${n}")
  if printf '%s' "${args}" | grep -qF "${expected}"; then
    pass "${name}"
  else
    fail "${name}: invocation ${n} missing '${expected}'. Args: $(printf '%s' "${args}" | tr '\n' '|')"
  fi
}

assert_not_contains() {
  local n="$1" unexpected="$2" name="$3"
  local args
  args=$(get_invocation "${n}")
  if printf '%s' "${args}" | grep -qF "${unexpected}"; then
    fail "${name}: invocation ${n} unexpectedly contains '${unexpected}'. Args: $(printf '%s' "${args}" | tr '\n' '|')"
  else
    pass "${name}"
  fi
}

# ---------------------------------------------------------------------------
# run_interactive: reset capture, seed config.json, run the script
# $1: "1" = HELP_HAS_TASK_TYPE (TASK_TYPE in help); "" = absent
# $2: stdin content
# $3: optional extra env vars (e.g. "REVENIUM_BUDGET_LABEL=myhost")
# ---------------------------------------------------------------------------
run_interactive() {
  local help_has_task_type="$1"
  local stdin_input="$2"
  local extra_env="${3:-}"

  : > "${INVOCATION_FILE}"
  : > "${UPDATE_FILE}"
  : > "${ORDER_FILE}"
  printf '{}\n' > "${FAKE_SKILL_DIR}/config.json"

  env \
    OPENCLAW_HOME="${FAKE_HOME}" \
    INVOCATION_FILE="${INVOCATION_FILE}" \
    UPDATE_FILE="${UPDATE_FILE}" \
    ORDER_FILE="${ORDER_FILE}" \
    HELP_HAS_TASK_TYPE="${help_has_task_type}" \
    REVENIUM_BIN="${STUB_BIN}/revenium" \
    STUB_REVENIUM_BUDGET_RULES_JSON="${STUB_REVENIUM_BUDGET_RULES_JSON:-}" \
    ${extra_env} \
    bash "${REPO_ROOT}/scripts/setup-guardrails.sh" --interactive <<EOF
${stdin_input}
EOF
}

# ===========================================================================
# SUITE A: TASK_TYPE present in --help → base + 1 per-task rule
# ===========================================================================
echo ""
echo "=== Suite A: picker enabled (TASK_TYPE in --help) ==="

# Stdin: hard_limit=100, period=MONTHLY, autonomous=no, shadow=no,
#        task selection=1 (research), task hard_limit=50
STDIN_A="100
MONTHLY
no
no
1
50"

run_interactive "1" "${STDIN_A}" > /dev/null 2>&1 || true

NUM_A=$(count_invocations)

if [[ "${NUM_A}" -eq 2 ]]; then
  pass "A1: exactly 2 budget-rules create invocations"
else
  fail "A1: expected 2 invocations, got ${NUM_A}"
fi

assert_contains 1 "AGENT:STARTS_WITH:openclaw-" "A2: base rule has AGENT:STARTS_WITH:openclaw-"
assert_not_contains 1 "TASK_TYPE:IS:" "A3: base rule has no TASK_TYPE filter"

# A4: base rule group-by is AGENT (appears as --group-by\nAGENT in the arg log)
assert_contains 1 "AGENT" "A4: base rule has AGENT as group-by dimension"

assert_contains 2 "AGENT:STARTS_WITH:openclaw-" "A5: per-task rule has AGENT:STARTS_WITH:openclaw-"
assert_contains 2 "TASK_TYPE:IS:research" "A6: per-task rule has TASK_TYPE:IS:research"
assert_contains 2 "TASK_TYPE" "A7: per-task rule has TASK_TYPE as group-by"

CONFIG_A=$(python3 -c "
import json
try:
    d = json.load(open('${FAKE_SKILL_DIR}/config.json'))
    print(len(d.get('ruleIds', [])))
except Exception:
    print(0)
" 2>/dev/null || printf '0')
if [[ "${CONFIG_A}" -eq 2 ]]; then
  pass "A8: config.json has 2 ruleIds"
else
  fail "A8: expected 2 ruleIds in config.json, got ${CONFIG_A}"
fi

# ===========================================================================
# SUITE B: TASK_TYPE absent from --help → gate, only base rule
# ===========================================================================
echo ""
echo "=== Suite B: picker gated out (TASK_TYPE absent from --help) ==="

# Only 4 stdin lines — picker not invoked
STDIN_B="100
MONTHLY
no
no"

run_interactive "" "${STDIN_B}" > /dev/null 2>&1 || true

NUM_B=$(count_invocations)

if [[ "${NUM_B}" -eq 1 ]]; then
  pass "B1: exactly 1 budget-rules create invocation (picker gated)"
else
  fail "B1: expected 1 invocation (gate), got ${NUM_B}"
fi

assert_contains 1 "AGENT:STARTS_WITH:openclaw-" "B2: base rule has AGENT:STARTS_WITH:openclaw-"

CONFIG_B=$(python3 -c "
import json
try:
    d = json.load(open('${FAKE_SKILL_DIR}/config.json'))
    print(len(d.get('ruleIds', [])))
except Exception:
    print(0)
" 2>/dev/null || printf '0')
if [[ "${CONFIG_B}" -eq 1 ]]; then
  pass "B3: config.json has 1 ruleId (base rule only)"
else
  fail "B3: expected 1 ruleId in config.json, got ${CONFIG_B}"
fi

# ===========================================================================
# SUITE C: Idempotent dedup — list-before-create ordering, adopt, warn+skip,
#          label-in-name (260605-enh)
# ===========================================================================
echo ""
echo "=== Suite C: idempotent dedup (260605-enh) ==="

# 4-line stdin for MONTHLY base rule (no per-task picker): limit=100, period=MONTHLY,
# autonomous=no, shadow=no.  Pass help_has_task_type="" so picker is skipped.
STDIN_C="100
MONTHLY
no
no"

# ---------------------------------------------------------------------------
# C1: list-before-create ordering
# ---------------------------------------------------------------------------
STUB_REVENIUM_BUDGET_RULES_JSON='[]' \
  run_interactive "" "${STDIN_C}" "" > /dev/null 2>&1 || true

# Read ORDER_FILE and verify LIST appears before the first CREATE
order_check=$(python3 - <<PY
try:
    with open("${ORDER_FILE}") as f:
        tags = [l.strip() for l in f if l.strip() in ('LIST','CREATE','UPDATE')]
    # Find position of first LIST and first CREATE
    first_list = next((i for i,t in enumerate(tags) if t == 'LIST'), None)
    first_create = next((i for i,t in enumerate(tags) if t == 'CREATE'), None)
    if first_list is None:
        print("no_list")
    elif first_create is None:
        print("no_create")
    elif first_list < first_create:
        print("ok")
    else:
        print("wrong_order")
except Exception as e:
    print("error:" + str(e))
PY
)

if [[ "${order_check}" == "ok" ]]; then
  pass "C1: LIST tag appears before first CREATE tag in ORDER_FILE"
else
  fail "C1: expected LIST before CREATE, got: ${order_check}"
fi

# ---------------------------------------------------------------------------
# C2: single-match adopt — zero creates, update --name, ruleIds=["existing-1"]
# ---------------------------------------------------------------------------
FIXTURE_ONE='[{"id":"existing-1","name":"old name","windowType":"MONTHLY","groupBy":"AGENT","filters":[{"dimension":"AGENT","operator":"STARTS_WITH","value":"openclaw-"}]}]'

STUB_REVENIUM_BUDGET_RULES_JSON="${FIXTURE_ONE}" \
  run_interactive "" "${STDIN_C}" "" > /dev/null 2>&1 || true

NUM_C2=$(count_invocations)
if [[ "${NUM_C2}" -eq 0 ]]; then
  pass "C2a: zero budget-rules create invocations on single-match adopt"
else
  fail "C2a: expected 0 create invocations, got ${NUM_C2}"
fi

# Check config.json ruleIds == ["existing-1"]
config_c2_ids=$(python3 - <<PY
import json
try:
    d = json.load(open('${FAKE_SKILL_DIR}/config.json'))
    print(json.dumps(d.get('ruleIds', [])))
except Exception:
    print('error')
PY
)
if [[ "${config_c2_ids}" == '["existing-1"]' ]]; then
  pass "C2b: config.json ruleIds == [\"existing-1\"] on single-match adopt"
else
  fail "C2b: expected ruleIds=[\"existing-1\"], got ${config_c2_ids}"
fi

# Check UPDATE invocation for --name (names differ: "old name" vs label-bearing name)
update_count_c2=$(python3 -c "
try:
    n = sum(1 for line in open('${UPDATE_FILE}') if line.strip() == 'UPDATE')
    print(n)
except Exception:
    print(0)
")
if [[ "${update_count_c2}" -ge 1 ]]; then
  pass "C2c: budget-rules update invoked (name differs — best-effort rename)"
else
  fail "C2c: expected at least 1 budget-rules update invocation, got ${update_count_c2}"
fi

# Check UPDATE invocation carries --name
update_has_name=$(python3 - <<PY
try:
    with open("${UPDATE_FILE}") as f:
        content = f.read()
    print("ok" if "--name" in content else "missing")
except Exception:
    print("error")
PY
)
if [[ "${update_has_name}" == "ok" ]]; then
  pass "C2d: budget-rules update invocation contains --name"
else
  fail "C2d: budget-rules update missing --name arg. UPDATE_FILE content: $(cat ${UPDATE_FILE} | tr '\n' '|')"
fi

# ---------------------------------------------------------------------------
# C3: multi-match warn+skip — zero creates, both delete commands printed,
#     ruleIds=["existing-1"]
# ---------------------------------------------------------------------------
FIXTURE_TWO='[{"id":"existing-1","name":"rule1","windowType":"MONTHLY","groupBy":"AGENT","filters":[{"dimension":"AGENT","operator":"STARTS_WITH","value":"openclaw-"}]},{"id":"existing-2","name":"rule2","windowType":"MONTHLY","groupBy":"AGENT","filters":[{"dimension":"AGENT","operator":"STARTS_WITH","value":"openclaw-"}]}]'

c3_output=$(STUB_REVENIUM_BUDGET_RULES_JSON="${FIXTURE_TWO}" \
  run_interactive "" "${STDIN_C}" "" 2>&1 || true)

NUM_C3=$(count_invocations)
if [[ "${NUM_C3}" -eq 0 ]]; then
  pass "C3a: zero budget-rules create invocations on multi-match warn+skip"
else
  fail "C3a: expected 0 create invocations, got ${NUM_C3}"
fi

# Check output warns about duplicates
if printf '%s' "${c3_output}" | grep -qi "duplicate\|exist.*budget\|budget.*rules\|dup\|identical\|same.*scope\|multiple.*rules\|rules.*meter"; then
  pass "C3b: output warns about duplicate/existing rules"
else
  fail "C3b: expected duplicate warning in output. Got: $(printf '%s' "${c3_output}" | head -20)"
fi

# Check both delete commands present in output
if printf '%s' "${c3_output}" | grep -q "budget-rules delete existing-1"; then
  pass "C3c: output contains delete command for existing-1"
else
  fail "C3c: missing 'budget-rules delete existing-1' in output. Got: $(printf '%s' "${c3_output}" | head -20)"
fi
if printf '%s' "${c3_output}" | grep -q "budget-rules delete existing-2"; then
  pass "C3d: output contains delete command for existing-2"
else
  fail "C3d: missing 'budget-rules delete existing-2' in output. Got: $(printf '%s' "${c3_output}" | head -20)"
fi

# Check config.json ruleIds == ["existing-1"] (first id adopted)
config_c3_ids=$(python3 - <<PY
import json
try:
    d = json.load(open('${FAKE_SKILL_DIR}/config.json'))
    print(json.dumps(d.get('ruleIds', [])))
except Exception:
    print('error')
PY
)
if [[ "${config_c3_ids}" == '["existing-1"]' ]]; then
  pass "C3e: config.json ruleIds == [\"existing-1\"] on multi-match (first adopted)"
else
  fail "C3e: expected ruleIds=[\"existing-1\"], got ${config_c3_ids}"
fi

# ---------------------------------------------------------------------------
# C4: label in name — with empty fixture and REVENIUM_BUDGET_LABEL=myhost,
#     create --name arg contains "myhost"
# ---------------------------------------------------------------------------
STUB_REVENIUM_BUDGET_RULES_JSON='[]' \
  run_interactive "" "${STDIN_C}" "REVENIUM_BUDGET_LABEL=myhost" > /dev/null 2>&1 || true

NUM_C4=$(count_invocations)
if [[ "${NUM_C4}" -ge 1 ]]; then
  inv1_c4=$(get_invocation 1)
  if printf '%s' "${inv1_c4}" | grep -q "myhost"; then
    pass "C4a: create --name carries REVENIUM_BUDGET_LABEL=myhost"
  else
    fail "C4a: expected 'myhost' in first create invocation. Args: $(printf '%s' "${inv1_c4}" | tr '\n' '|')"
  fi
else
  fail "C4a: no create invocation found for C4 (expected at least 1)"
fi

# ---------------------------------------------------------------------------
# C5: cross-deployment guard — a same-scope rule whose name carries a DIFFERENT
#     deployment label must NOT be adopted (and must not be renamed); a new
#     rule is created instead. (Live incident 2026-06-12: scope-only matching
#     would have adopted+renamed revenium-ftw-2's rule on a shared tenant.)
# ---------------------------------------------------------------------------
FIXTURE_FOREIGN='[{"id":"foreign-1","name":"OpenClaw Monthly Budget — otherhost","windowType":"MONTHLY","groupBy":"AGENT","filters":[{"dimension":"AGENT","operator":"STARTS_WITH","value":"openclaw-"}]}]'

STUB_REVENIUM_BUDGET_RULES_JSON="${FIXTURE_FOREIGN}" \
  run_interactive "" "${STDIN_C}" "REVENIUM_BUDGET_LABEL=myhost" > /dev/null 2>&1 || true

NUM_C5=$(count_invocations)
if [[ "${NUM_C5}" -eq 1 ]]; then
  pass "C5a: foreign-labeled same-scope rule NOT adopted — new rule created"
else
  fail "C5a: expected 1 create invocation (no adopt of foreign rule), got ${NUM_C5}"
fi

config_c5_ids=$(python3 -c "
import json
try:
    d = json.load(open('${FAKE_SKILL_DIR}/config.json'))
    print(json.dumps(d.get('ruleIds', [])))
except Exception:
    print('error')
")
if [[ "${config_c5_ids}" == '["rule-stub-test"]' ]]; then
  pass "C5b: config.json ruleIds is the NEW rule, not the foreign one"
else
  fail "C5b: expected ruleIds=[\"rule-stub-test\"], got ${config_c5_ids}"
fi

update_count_c5=$(python3 -c "
try:
    n = sum(1 for line in open('${UPDATE_FILE}') if line.strip() == 'UPDATE')
    print(n)
except Exception:
    print(0)
")
if [[ "${update_count_c5}" -eq 0 ]]; then
  pass "C5c: foreign rule never renamed (zero update invocations)"
else
  fail "C5c: expected 0 update invocations on foreign rule, got ${update_count_c5}"
fi

# ---------------------------------------------------------------------------
# C6: own-label rule IS adopted (label guard must not break same-host idempotency)
# ---------------------------------------------------------------------------
FIXTURE_MINE='[{"id":"existing-mine","name":"OpenClaw Monthly Budget — myhost","windowType":"MONTHLY","groupBy":"AGENT","filters":[{"dimension":"AGENT","operator":"STARTS_WITH","value":"openclaw-"}]}]'

STUB_REVENIUM_BUDGET_RULES_JSON="${FIXTURE_MINE}" \
  run_interactive "" "${STDIN_C}" "REVENIUM_BUDGET_LABEL=myhost" > /dev/null 2>&1 || true

NUM_C6=$(count_invocations)
config_c6_ids=$(python3 -c "
import json
try:
    d = json.load(open('${FAKE_SKILL_DIR}/config.json'))
    print(json.dumps(d.get('ruleIds', [])))
except Exception:
    print('error')
")
if [[ "${NUM_C6}" -eq 0 && "${config_c6_ids}" == '["existing-mine"]' ]]; then
  pass "C6: own-labeled same-scope rule still adopted (0 creates, ruleIds=[\"existing-mine\"])"
else
  fail "C6: expected adopt of own-labeled rule (0 creates + ruleIds=[\"existing-mine\"]), got creates=${NUM_C6} ruleIds=${config_c6_ids}"
fi

# ===========================================================================
# SUITE D: default mode — autonomousMode written explicitly
#
# guardrail-check.sh derives halted = autonomousMode AND blocked; an absent
# field reads as false, so hard limits never hard-halt. Default mode must
# therefore ALWAYS write the field: false without --autonomous, true with it.
# (This is the non-interactive path the NemoClaw install uses.)
# ===========================================================================
echo ""
echo "=== Suite D: default mode autonomousMode write-back ==="

# run_default: reset capture, seed config.json, run default mode with given flags
run_default() {
  : > "${INVOCATION_FILE}"
  : > "${UPDATE_FILE}"
  : > "${ORDER_FILE}"
  printf '{}\n' > "${FAKE_SKILL_DIR}/config.json"

  env \
    OPENCLAW_HOME="${FAKE_HOME}" \
    INVOCATION_FILE="${INVOCATION_FILE}" \
    UPDATE_FILE="${UPDATE_FILE}" \
    ORDER_FILE="${ORDER_FILE}" \
    HELP_HAS_TASK_TYPE="" \
    REVENIUM_BIN="${STUB_BIN}/revenium" \
    STUB_REVENIUM_BUDGET_RULES_JSON='[]' \
    bash "${REPO_ROOT}/scripts/setup-guardrails.sh" --hard-limit 100 --period MONTHLY "$@"
}

# read_autonomous_mode: print config.json autonomousMode as python repr (True/False/MISSING)
read_autonomous_mode() {
  python3 -c "
import json
try:
    d = json.load(open('${FAKE_SKILL_DIR}/config.json'))
    print(repr(d['autonomousMode']) if 'autonomousMode' in d else 'MISSING')
except Exception:
    print('ERROR')
"
}

# D1: default mode WITHOUT --autonomous → autonomousMode explicitly false
run_default > /dev/null 2>&1 || true
AUTO_D1=$(read_autonomous_mode)
if [[ "${AUTO_D1}" == "False" ]]; then
  pass "D1: default mode writes autonomousMode=false when --autonomous absent"
else
  fail "D1: expected autonomousMode False, got ${AUTO_D1}"
fi

# D2: default mode WITH --autonomous → autonomousMode true
run_default --autonomous > /dev/null 2>&1 || true
AUTO_D2=$(read_autonomous_mode)
if [[ "${AUTO_D2}" == "True" ]]; then
  pass "D2: default mode writes autonomousMode=true with --autonomous"
else
  fail "D2: expected autonomousMode True, got ${AUTO_D2}"
fi

# D3: ruleIds still written alongside autonomousMode (no regression of write-back)
RULE_IDS_D3=$(python3 -c "
import json
try:
    d = json.load(open('${FAKE_SKILL_DIR}/config.json'))
    print(json.dumps(d.get('ruleIds', [])))
except Exception:
    print('ERROR')
")
if [[ "${RULE_IDS_D3}" == '["rule-stub-test"]' ]]; then
  pass "D3: default mode still writes ruleIds alongside autonomousMode"
else
  fail "D3: expected ruleIds [\"rule-stub-test\"], got ${RULE_IDS_D3}"
fi

# ===========================================================================
# SUMMARY
# ===========================================================================
echo ""
echo "=== Results ==="
printf 'PASS: %d\n' "${PASS}"
printf 'FAIL: %d\n' "${FAIL}"
if [[ "${FAIL}" -gt 0 ]]; then
  echo ""
  printf 'Failed:\n%s\n' "${ERRORS}"
  exit 1
fi
echo "All tests passed."
exit 0
