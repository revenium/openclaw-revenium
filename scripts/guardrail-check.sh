#!/usr/bin/env bash
# guardrail-check.sh — cron enforcement stage for OpenClaw guardrail enforcement.
# Polls revenium guardrails enforcement-rules get on every cron tick, builds
# per-rule state (block/warn/ok), writes guardrail-status.json atomically,
# detects new halt transitions, and fires openclaw message send notification on
# a new halt. Shadow-mode rules are tracked but excluded from the halt decision.
# Fail-open posture: every preflight and failure path exits 0.
#
# Decisions implemented:
#   D-09: shadow exclusion from halt
#   D-11: halt notification on false->true transition only
#   D-12: shadow notification on first breach only
#   D-13: ruleIds empty/absent -> silent exit 0 (no log line)
#   D-14: atomic write via tempfile.mkstemp + os.replace
#   D-15: name-join for integer ruleId / string-hash ruleId reconciliation

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

# Save the head of PATH before ensure_path so that test-injected stub directories
# (prepended by the test harness) are not pushed back by ensure_path's Homebrew
# additions. Re-prepending the original head after ensure_path keeps stubs first
# while still benefiting from the Homebrew/system paths ensure_path provides.
_PATH_HEAD="${PATH%%:*}"
ensure_path
[[ -n "${_PATH_HEAD}" ]] && export PATH="${_PATH_HEAD}:${PATH}"

# ---------------------------------------------------------------------------
# (A) D-13: ruleIds absent or empty -> exit silently.
# MUST appear before all warn-logging code (D-03 / Pitfall 6).
# If CONFIG_FILE does not exist yet, python3 returns [] and we exit 0 silently.
# ---------------------------------------------------------------------------
RULE_IDS_JSON=$(CONFIG_FILE="${CONFIG_FILE}" python3 -c "
import json, os
try:
    ids = json.load(open(os.environ['CONFIG_FILE'])).get('ruleIds', [])
    print(json.dumps(ids))
except Exception:
    print('[]')
" 2>/dev/null || echo '[]')

RULE_IDS_COUNT=$(echo "${RULE_IDS_JSON}" | python3 -c \
  "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")

if [[ "${RULE_IDS_COUNT}" -eq 0 ]]; then
  # D-13: no ruleIds — legacy alertId-only install or pre-setup state.
  # Bare exit 0 — no log line (D-03: cron must not emit noise for pre-setup installs).
  exit 0
fi

# ---------------------------------------------------------------------------
# (B) Preflight checks — fail-open: each exits 0 with a warn log.
# These appear AFTER the D-13 silent-exit guard so legacy installs never log.
# ---------------------------------------------------------------------------
if ! command -v revenium >/dev/null 2>&1; then
  warn "revenium CLI not found on PATH — skipping guardrail check."
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  warn "python3 not found — skipping guardrail check."
  exit 0
fi
if [[ ! -f "${CONFIG_FILE}" ]]; then
  warn "No config.json found at ${CONFIG_FILE} — skipping guardrail check."
  exit 0
fi
if ! has_guardrails_cli; then
  warn "revenium guardrails CLI not available — skipping guardrail check."
  exit 0
fi
if ! revenium config show >/dev/null 2>&1; then
  warn "revenium not configured — skipping guardrail check."
  exit 0
fi

# ---------------------------------------------------------------------------
# (C) read_config_field helper — reads a scalar key from CONFIG_FILE via Python.
# Uses env-passing heredoc pattern (Bash 3.2 safe — no ${} inside <<'PY').
# ---------------------------------------------------------------------------
read_config_field() {
  CONFIG_FILE="${CONFIG_FILE}" KEY="$1" python3 - <<'PY'
import json, os
val = json.load(open(os.environ['CONFIG_FILE'])).get(os.environ['KEY'], '')
if isinstance(val, bool):
    print('true' if val else 'false')
else:
    print(val if val is not None else '')
PY
}

# (D) Read scalar config fields.
AUTONOMOUS=$(read_config_field autonomousMode)
NOTIFY_CHANNEL=$(read_config_field notifyChannel)
NOTIFY_TARGET=$(read_config_field notifyTarget)

# (E) Resolve teamId from revenium config show.
# Confirmed output format: "Team ID:    5jdO2v" (03-01-SUMMARY verification).
TEAM_ID=$(revenium config show 2>&1 | sed -n 's/.*Team ID:[ 	]*//p' | tr -d ' ')
if [[ -z "${TEAM_ID}" ]]; then
  warn "Could not resolve teamId from revenium config show — skipping guardrail check."
  exit 0
fi

# (F) Fetch enforcement rules — treat EOF/exit-1 (empty team) as soft-fail.
# Uses --output json (global flag, not --json per Pitfall 2 verification).
ENFORCEMENT_JSON=$(revenium guardrails enforcement-rules get "${TEAM_ID}" --output json 2>&1) || true
if echo "${ENFORCEMENT_JSON}" | grep -q '"error".*EOF'; then
  ENFORCEMENT_JSON='{"rules": []}'
fi

# Pre-step: build name -> string-id map once per tick (D-15 name-join).
# enforcement-rules API returns integer ruleId values; budget-rules list returns
# string-hash IDs matching config.json::ruleIds. Only join key is the name field.
BUDGET_RULES_JSON=$(revenium guardrails budget-rules list --output json 2>/dev/null || echo '[]')

# ---------------------------------------------------------------------------
# (G) Build guardrail-status.json via a single Python heredoc with atomic write.
# All variables passed via environment (Bash 3.2 safe — no ${} inside <<'PY').
# ---------------------------------------------------------------------------
HALT_OUTPUT=$(
  GUARDRAIL_STATUS_FILE="${GUARDRAIL_STATUS_FILE}" \
  ENFORCEMENT_JSON="${ENFORCEMENT_JSON}" \
  BUDGET_RULES_JSON="${BUDGET_RULES_JSON}" \
  RULE_IDS_JSON="${RULE_IDS_JSON}" \
  AUTONOMOUS="${AUTONOMOUS}" \
  python3 - <<'PY'
import json, os, tempfile
from datetime import datetime, timezone
from pathlib import Path

status_file = Path(os.environ['GUARDRAIL_STATUS_FILE'])
enforcement_json = os.environ['ENFORCEMENT_JSON']
budget_rules_json = os.environ.get('BUDGET_RULES_JSON', '[]')
rule_ids_order = json.loads(os.environ['RULE_IDS_JSON'])   # string IDs, declaration order
autonomous = os.environ['AUTONOMOUS'] == 'true'

# Parse enforcement-rules response (integer ruleId space)
api_rules = []
try:
    api_rules = json.loads(enforcement_json).get('rules', [])
except Exception:
    pass

# Parse budget-rules list (string-hash ruleId space) and build name -> string-id map.
# D-15: enforcement-rules API returns integer IDs that do NOT match config.json::ruleIds
# (string hashes). The only stable join key between the two is the rule name field.
name_to_string_id = {}
try:
    br_data = json.loads(budget_rules_json)
    # budget-rules list returns a JSON array; each entry has {id: "<string-hash>", name: "..."}
    if isinstance(br_data, list):
        for br in br_data:
            n = br.get('name')
            sid = br.get('id')   # string-hash ID, e.g. "d5jng5"
            if n and sid:
                name_to_string_id[n] = sid
except Exception:
    pass

# Build per-rule state list (Pattern 6 schema)
# state derivation: breached -> 'block', warnBreached -> 'warn', else 'ok'
now = datetime.now(timezone.utc).isoformat()
new_rules = []
for r in api_rules:
    if r.get('breached'):
        state = 'block'
    elif r.get('warnBreached'):
        state = 'warn'
    else:
        state = 'ok'
    # Truncate rule name to 64 chars before logging (T-03-04 log-injection mitigation).
    rule_name = (r.get('name') or '')[:64]
    # ruleId resolution (D-15): prefer the string-hash from budget-rules list (matches
    # config.json::ruleIds format). Fallback: coerce the API integer ruleId to string.
    resolved_rule_id = name_to_string_id.get(rule_name)
    if not resolved_rule_id:
        resolved_rule_id = str(r.get('ruleId', '')) if r.get('ruleId') is not None else ''
    # shadowMode: when true, rule still records state:block on breach but is excluded
    # from any_blocked and haltedRule below (D-09).
    new_rules.append({
        'ruleId': resolved_rule_id,
        'name': rule_name,
        'metricType': r.get('metricType', ''),
        'windowType': r.get('periodType', ''),    # API: periodType -> schema: windowType
        'groupBy': r.get('groupBy', ''),
        'currentValue': r.get('currentValue', 0),
        'warnThreshold': r.get('warnThreshold', 0),
        'hardLimit': r.get('threshold', 0),       # API: threshold -> schema: hardLimit
        'state': state,
        'shadowMode': bool(r.get('shadowMode', False)),
        'lastChecked': now,
    })

# Load previous state (fail-open)
prev = {}
try:
    prev = json.loads(status_file.read_text(encoding='utf-8'))
except Exception:
    pass
prev_halted = bool(prev.get('halted', False))
prev_halted_at = prev.get('haltedAt')

# Top-level halted derivation (D-09): shadow-mode rules are excluded from the halt
# decision so they record signal without blocking traffic.
any_blocked = any(
    r['state'] == 'block' and not r.get('shadowMode', False)
    for r in new_rules
)
new_halted = autonomous and any_blocked

# HALT_TRANSITION detection (D-11): new halt iff new_halted and not prev_halted
halt_transition = False
if new_halted and not prev_halted:
    halt_transition = True
    halted_at = now
elif new_halted and prev_halted:
    halted_at = prev_halted_at or now
else:
    halted_at = None

# haltedRule: first non-shadow blocked rule (D-09 excludes shadow-mode rules)
halted_rule = None
if new_halted:
    blocked = [
        r for r in new_rules
        if r['state'] == 'block' and not r.get('shadowMode', False)
    ]
    if blocked:
        first = blocked[0]
        halted_rule = {
            'ruleId': first['ruleId'],
            'name': first['name'],
            'metricType': first['metricType'],
            'windowType': first['windowType'],
            'currentValue': first['currentValue'],
            'hardLimit': first['hardLimit'],
        }

# Shadow-mode transition detection (D-12): emit a one-shot notification when a shadow
# rule JUST transitioned into would-have-halted state this cycle. Gate against prev
# guardrail-status.json so re-runs are silent (Pitfall 4 guard).
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
        # Pitfall 4: use (pr is None) or (pr.get('state') != 'block') guard
        if (pr is None) or (pr.get('state') != 'block') or (not pr.get('shadowMode')):
            shadow_transitions.append({
                'ruleId': nr['ruleId'],
                'name': nr['name'],
                'metricType': nr.get('metricType', ''),
                'windowType': nr.get('windowType', ''),
                'currentValue': nr['currentValue'],
                'hardLimit': nr['hardLimit'],
            })

# Build output document (Pattern 6 schema)
data = {
    'halted': new_halted,
    'autonomousMode': autonomous,
    'lastChecked': now,
    'rules': new_rules,
}
if new_halted and halted_at:
    data['haltedAt'] = halted_at
if halted_rule:
    data['haltedRule'] = halted_rule

# Atomic write (D-14 / Pattern 4): write-tmp-rename in the same directory.
# T-03-05 mitigation: partial writes never visible to the agent.
tmp_fd, tmp_path = tempfile.mkstemp(
    dir=str(status_file.parent),
    prefix='.guardrail-status-',
    suffix='.tmp'
)
try:
    with os.fdopen(tmp_fd, 'w', encoding='utf-8') as f:
        f.write(json.dumps(data, indent=2) + '\n')
    os.replace(tmp_path, str(status_file))
finally:
    try:
        os.unlink(tmp_path)
    except FileNotFoundError:
        pass

# Emit KEY=value lines for bash caller to parse HALT_TRANSITION and halted rule fields
print(f"HALT_TRANSITION={'true' if halt_transition else 'false'}")
if halt_transition and halted_rule:
    print(f"HALTED_RULE_NAME={halted_rule['name']}")
    print(f"HALTED_RULE_ID={halted_rule['ruleId']}")
    print(f"HALTED_METRIC_TYPE={halted_rule['metricType']}")
    print(f"HALTED_WINDOW_TYPE={halted_rule['windowType']}")
    print(f"HALTED_CURRENT_VALUE={halted_rule['currentValue']}")
    print(f"HALTED_HARD_LIMIT={halted_rule['hardLimit']}")
# Emit shadow-mode transitions as a single JSON-encoded line for bash to parse.
# Always emitted (defaults to '[]') so bash sed extraction is deterministic.
print(f"SHADOW_TRANSITIONS={json.dumps(shadow_transitions)}")
PY
)

# Emit KEY=value lines from the heredoc to stdout so the cron caller (and test
# harness) can observe HALT_TRANSITION, HALTED_RULE_*, etc.
echo "${HALT_OUTPUT}"

# Extract shadow-transition payload. Always present in HALT_OUTPUT;
# defaults to '[]' when no rule transitioned into shadow-block.
SHADOW_TRANSITIONS_JSON=$(echo "${HALT_OUTPUT}" | sed -n 's/^SHADOW_TRANSITIONS=//p')

# ---------------------------------------------------------------------------
# (H) Legacy budget-status.json cleanup — runs AFTER guardrail-status.json is
# durably on disk, BEFORE halt notification. Idempotent.
# ---------------------------------------------------------------------------
if [[ -f "${STATE_DIR}/budget-status.json" ]]; then
  rm -f "${STATE_DIR}/budget-status.json"
  info "Cleaned up legacy budget-status.json"
fi

# ---------------------------------------------------------------------------
# (I) Parse halt output and dispatch halt notification on HALT_TRANSITION (D-11).
# ---------------------------------------------------------------------------
if echo "${HALT_OUTPUT}" | grep -q '^HALT_TRANSITION=true$'; then
  HALTED_RULE_NAME=$(echo "${HALT_OUTPUT}" | sed -n 's/^HALTED_RULE_NAME=//p')
  HALTED_RULE_ID=$(echo "${HALT_OUTPUT}" | sed -n 's/^HALTED_RULE_ID=//p')
  HALTED_METRIC_TYPE=$(echo "${HALT_OUTPUT}" | sed -n 's/^HALTED_METRIC_TYPE=//p')
  HALTED_WINDOW_TYPE=$(echo "${HALT_OUTPUT}" | sed -n 's/^HALTED_WINDOW_TYPE=//p')
  HALTED_CURRENT_VALUE=$(echo "${HALT_OUTPUT}" | sed -n 's/^HALTED_CURRENT_VALUE=//p')
  HALTED_HARD_LIMIT=$(echo "${HALT_OUTPUT}" | sed -n 's/^HALTED_HARD_LIMIT=//p')

  # (J) Fetch enforcement event for the halted rule (graceful degradation).
  # Use sentinel "__FAIL__" to distinguish API failure from an empty result.
  EVENT_JSON=$(revenium guardrails enforcement-events list \
    --rule-id "${HALTED_RULE_ID}" --page-size 1 --output json 2>/dev/null || echo '__FAIL__')
  if [[ "${EVENT_JSON}" == "__FAIL__" ]]; then
    warn "enforcement-events list failed for rule ${HALTED_RULE_ID} — falling back to rule-level data"
    EVENT_TS='(unavailable)'
    EVENT_SUMMARY='(unavailable)'
  else
    EVENT_TS=$(EVENT_JSON="${EVENT_JSON}" python3 -c "
import json, os
try:
    events = json.loads(os.environ['EVENT_JSON'])
    print(events[0].get('created', '(unavailable)') if events else '(no events)')
except Exception:
    print('(unavailable)')
" 2>/dev/null || echo '(unavailable)')
    EVENT_SUMMARY=$(EVENT_JSON="${EVENT_JSON}" python3 -c "
import json, os
try:
    events = json.loads(os.environ['EVENT_JSON'])
    print(events[0].get('rawDetails', '(unavailable)') if events else '(no events)')
except Exception:
    print('(unavailable)')
" 2>/dev/null || echo '(unavailable)')
  fi

  # Emit audit event fields on stdout (observable signal; '(unavailable)' on fallback).
  echo "EVENT_TS=${EVENT_TS}"
  echo "EVENT_SUMMARY=${EVENT_SUMMARY}"

  # (K) Halt notification via openclaw message send (D-10/D-11).
  # Pattern 7 halt template with OpenClaw resume path.
  MSG="Guardrail halt active — rule '${HALTED_RULE_NAME}' (${HALTED_METRIC_TYPE}, ${HALTED_WINDOW_TYPE}) at ${HALTED_CURRENT_VALUE} of ${HALTED_HARD_LIMIT} hard-limit. To resume: bash ~/.openclaw/skills/revenium/scripts/clear-halt.sh | Event: [${EVENT_TS}] ${EVENT_SUMMARY}"
  if [[ -n "${NOTIFY_CHANNEL}" && -n "${NOTIFY_TARGET}" ]]; then
    if command -v openclaw >/dev/null 2>&1; then
      if openclaw message send \
           --channel "${NOTIFY_CHANNEL}" \
           --target "${NOTIFY_TARGET}" \
           -m "${MSG}" >/dev/null 2>&1; then
        info "Halt notification sent via openclaw ${NOTIFY_CHANNEL}"
      else
        warn "Failed to send halt notification via openclaw ${NOTIFY_CHANNEL}"
      fi
    else
      warn "openclaw CLI not available — halt notification not sent"
    fi
  else
    info "Guardrail halted but no notification channel configured"
  fi
fi

# ---------------------------------------------------------------------------
# (L) Shadow-mode one-shot notification (D-12). For every rule that JUST
# transitioned into shadow-block this cycle, emit a [shadow]-prefixed message.
# Bash 3.2 compatible: uses mktemp + while read (no <<< here-strings in subshells).
# ---------------------------------------------------------------------------
if [[ -n "${SHADOW_TRANSITIONS_JSON}" && "${SHADOW_TRANSITIONS_JSON}" != "[]" ]]; then
  SHADOW_TMP=$(mktemp)
  SHADOW_TRANSITIONS_JSON="${SHADOW_TRANSITIONS_JSON}" python3 - <<'PY' > "${SHADOW_TMP}"
import json, os
for r in json.loads(os.environ['SHADOW_TRANSITIONS_JSON']):
    # pipe-delimited; pipes don't appear in numeric values or in the short
    # metric/window enum strings (TOTAL_COST, MONTHLY, etc.).
    print(f"{r['name']}|{r.get('metricType','')}|{r.get('windowType','')}|{r['currentValue']}|{r['hardLimit']}")
PY
  while IFS='|' read -r SR_NAME SR_METRIC SR_WINDOW SR_CV SR_HL; do
    [[ -z "${SR_NAME}" ]] && continue
    SHADOW_MSG="[shadow] Rule '${SR_NAME}' (${SR_METRIC}, ${SR_WINDOW}) would have halted at ${SR_CV} of ${SR_HL}; shadow mode prevented block."
    if [[ -n "${NOTIFY_CHANNEL}" && -n "${NOTIFY_TARGET}" ]] && command -v openclaw >/dev/null 2>&1; then
      if openclaw message send \
           --channel "${NOTIFY_CHANNEL}" \
           --target "${NOTIFY_TARGET}" \
           -m "${SHADOW_MSG}" >/dev/null 2>&1; then
        info "Shadow notification sent via openclaw ${NOTIFY_CHANNEL}: ${SHADOW_MSG}"
      else
        warn "Failed to send shadow notification via openclaw ${NOTIFY_CHANNEL}: ${SHADOW_MSG}"
      fi
    else
      warn "${SHADOW_MSG}"
    fi
  done < "${SHADOW_TMP}"
  rm -f "${SHADOW_TMP}"
fi
