#!/usr/bin/env bash
# test_setup_guardrails_argv.sh — Integration test for setup-guardrails.sh
# Plan 04-03 Task 2: argv-capture tests for:
#   (a) base rule: AGENT:STARTS_WITH:openclaw- + --group-by AGENT
#   (b) per-task rule: AGENT:STARTS_WITH:openclaw- + TASK_TYPE:IS:<label> + --group-by TASK_TYPE
#   (c) gate: when --help lacks TASK_TYPE, picker is skipped (only base rule created)
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

# Invocation log file
INVOCATION_FILE="${TMPDIR_ROOT}/invocations.txt"
: > "${INVOCATION_FILE}"

# ---------------------------------------------------------------------------
# Stub: revenium — env-driven (INVOCATION_FILE, HELP_HAS_TASK_TYPE exported
# by run_interactive; REVENIUM_BIN tells setup-guardrails.sh to prepend our
# bin dir to PATH after ensure_path, so the stub wins).
# ---------------------------------------------------------------------------
cat > "${STUB_BIN}/revenium" <<'STUB'
#!/usr/bin/env bash
# stubbed revenium for integration testing
# reads INVOCATION_FILE and HELP_HAS_TASK_TYPE from env

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
    printf '[]\n'
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
  *"budget-rules create"*)
    if [[ -n "${INVOCATION_FILE:-}" ]]; then
      printf 'INVOKE\n' >> "${INVOCATION_FILE}"
      for arg in "$@"; do
        printf '%s\n' "${arg}" >> "${INVOCATION_FILE}"
      done
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
# ---------------------------------------------------------------------------
run_interactive() {
  local help_has_task_type="$1"
  local stdin_input="$2"

  : > "${INVOCATION_FILE}"
  printf '{}\n' > "${FAKE_SKILL_DIR}/config.json"

  OPENCLAW_HOME="${FAKE_HOME}" \
  INVOCATION_FILE="${INVOCATION_FILE}" \
  HELP_HAS_TASK_TYPE="${help_has_task_type}" \
  REVENIUM_BIN="${STUB_BIN}/revenium" \
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
