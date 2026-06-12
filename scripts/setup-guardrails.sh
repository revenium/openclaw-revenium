#!/usr/bin/env bash
set -euo pipefail
# setup-guardrails.sh — interactive rule-creation entry point for the Phase 3
# guardrails-native budget enforcement. Two modes per D-02:
#   default     : --hard-limit N --period P [--shadow-mode] [--autonomous] from CLI args.
#   --interactive: operator prompts; called by SKILL.md Setup Flow (D-18).
# Legacy migration mode is intentionally absent (D-02/D-03 decision).
# Idempotent via ruleIds-presence pre-check; flock-guarded via RULES_LOCK_FILE.
# --shadow-mode propagates to create_rule (D-08).
# Bash 3.2 compatible (macOS default) — uses env-passing heredoc pattern for
# ALL python3 calls; no associative arrays, no lowercase expansion, no heredoc
# strings inside subshells (Pitfall 5).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

ensure_path

# ---------------------------------------------------------------------------
# REVENIUM_BIN override (testability hook).
# Integration tests set REVENIUM_BIN=/path/to/stub-revenium so the test
# stub is called even when ensure_path prepends system paths. Production
# runs never set this variable; the default is the `revenium` on PATH.
# ---------------------------------------------------------------------------
if [[ -n "${REVENIUM_BIN:-}" ]]; then
  # Prepend the stub's directory to PATH so `revenium` resolves to it.
  # This must come AFTER ensure_path (which prepends system paths) so the
  # stub directory has highest priority.
  export PATH="$(dirname "${REVENIUM_BIN}"):${PATH}"
fi

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
  cat <<'USAGE'
setup-guardrails.sh — create Revenium guardrails budget rules for OpenClaw

MODES:
  Default mode (all args from CLI flags):
    setup-guardrails.sh --hard-limit 100 --period MONTHLY [--shadow-mode] [--autonomous]

  Interactive mode (operator prompts; used by SKILL.md Setup Flow):
    setup-guardrails.sh --interactive [--shadow-mode]

OPTIONS:
  --hard-limit <N>    Budget hard limit (numeric, e.g. 50.00). Required in default mode.
  --period <P>        Budget period: DAILY | WEEKLY | MONTHLY | QUARTERLY. Required in default mode.
  --shadow-mode       Created rule runs in shadow mode (observe only, no blocking). D-08.
  --autonomous        Default mode only: write autonomousMode=true to config.json — on a
                      rule breach guardrail-check.sh sets halted:true and the agent
                      HARD-HALTS (no warn-and-ask). Without this flag default mode writes
                      autonomousMode=false: a breach sets warned:true and the agent asks
                      the user for permission each turn instead of halting. Interactive
                      mode prompts for this and ignores the flag.
  --interactive       Collect all args from operator prompts.
  --help              Show this usage block and exit.

DEFAULT FILTER SCOPING:
  Created rules default-scope to --filter AGENT:STARTS_WITH:${REVENIUM_AGENT_PREFIX:-openclaw-}
  so the rule matches all openclaw-{root_sid} and openclaw-{sid} completions (D-07).

IDEMPOTENCY:
  Re-running setup-guardrails against a tenant that already has a same-scope budget
  rule adopts the existing rule (sets RULE_ID to its id, skips creation) rather than
  creating a duplicate. If multiple same-scope rules are detected, setup warns, prints
  the exact `revenium guardrails budget-rules delete <id> --yes` command for each, and
  adopts the first without auto-deleting — a shared tenant may host other hosts' rules.
  Cross-deployment guard: a same-scope rule whose name carries a DIFFERENT deployment
  label ("... — <label>") is never adopted or renamed — only rules labeled for this
  deployment (REVENIUM_BUDGET_LABEL / hostname) or unlabeled legacy rules match.

REVENIUM_BUDGET_LABEL:
  Optional env var. When set, its value is appended to the rule name as a
  deployment-disambiguating label (e.g. "OpenClaw Monthly Budget — myhost").
  Default: short hostname from `hostname -s` (or uname -n / HOSTNAME / "unknown").
  Set REVENIUM_BUDGET_LABEL before invoking setup-guardrails.sh to produce
  human-distinguishable rule names when multiple hosts share the same tenant.

EXAMPLES:
  # Fresh install — interactive mode:
  setup-guardrails.sh --interactive

  # Default mode — MONTHLY hard limit:
  setup-guardrails.sh --hard-limit 100 --period MONTHLY

  # Default mode — hard-halt on breach (autonomous enforcement):
  setup-guardrails.sh --hard-limit 100 --period MONTHLY --autonomous

  # Shadow mode — observe only:
  setup-guardrails.sh --interactive --shadow-mode

  # Custom deployment label (host-unique rule name):
  REVENIUM_BUDGET_LABEL=prod-server-1 setup-guardrails.sh --interactive
USAGE
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
MODE="default"
HARD_LIMIT=""
PERIOD=""
SHADOW_MODE="false"
AUTONOMOUS_MODE="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interactive)
      MODE="interactive"
      shift
      ;;
    --autonomous)
      AUTONOMOUS_MODE="true"
      shift
      ;;
    --hard-limit)
      HARD_LIMIT="${2:-}"
      if [[ -z "${HARD_LIMIT}" ]]; then
        error "--hard-limit requires a value"; exit 2
      fi
      shift 2
      ;;
    --period)
      PERIOD="${2:-}"
      if [[ -z "${PERIOD}" ]]; then
        error "--period requires a value"; exit 2
      fi
      shift 2
      ;;
    --shadow-mode)
      SHADOW_MODE="true"
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      error "unknown flag: $1"
      exit 2
      ;;
  esac
done

# ---------------------------------------------------------------------------
# Mode resolution validation
# ---------------------------------------------------------------------------
if [[ "${MODE}" == "default" ]]; then
  if [[ -z "${HARD_LIMIT}" || -z "${PERIOD}" ]]; then
    error "default mode requires --hard-limit and --period"
    exit 2
  fi
elif [[ "${AUTONOMOUS_MODE}" == "true" ]]; then
  warn "--autonomous is ignored in interactive mode — the autonomous-mode prompt decides"
fi

# ---------------------------------------------------------------------------
# Capability precheck (fail-open)
# ---------------------------------------------------------------------------
if ! has_guardrails_cli; then
  echo "The revenium CLI does not support guardrails budget-rules commands."
  echo "Upgrade with: brew upgrade revenium/tap/revenium"
  exit 0
fi

# ---------------------------------------------------------------------------
# Helper: read_config_field KEY
# Reads a field from CONFIG_FILE; prints 'nonempty' for non-empty arrays,
# 'true'/'false' for booleans, and the value string for scalars.
# Bash 3.2: uses env-passing heredoc pattern (not herestrings).
# ---------------------------------------------------------------------------
read_config_field() {
  CONFIG_FILE="${CONFIG_FILE}" KEY="$1" python3 - <<'PY'
import json, os
try:
    val = json.load(open(os.environ['CONFIG_FILE'])).get(os.environ['KEY'], '')
except Exception:
    val = ''
if isinstance(val, list):
    print('nonempty' if val else '')
elif isinstance(val, bool):
    print('true' if val else 'false')
else:
    print(val if val is not None else '')
PY
}

# ---------------------------------------------------------------------------
# Helpers: input validation
# ---------------------------------------------------------------------------
validate_hard_limit() {
  # WR-06: the prompts/errors promise a "positive number", so reject 0, 0.00,
  # and other non-positive values. A zero hard limit produces a budget rule
  # whose warn threshold is also 0, which can block immediately / behave
  # nonsensically.
  [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  awk -v n="$1" 'BEGIN{exit !(n+0 > 0)}'
}

validate_period() {
  case "$1" in DAILY|WEEKLY|MONTHLY|QUARTERLY) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# Config.json existence check
# Interactive / default modes self-bootstrap: create STATE_DIR + seed an
# empty config.json so the operator can run on a fresh host without
# manually preparing state first.
# ---------------------------------------------------------------------------
if [[ ! -f "${CONFIG_FILE}" ]]; then
  info "no config.json at ${CONFIG_FILE} — bootstrapping fresh state"
  mkdir -p "${STATE_DIR}" || { error "could not create ${STATE_DIR}"; exit 1; }
  printf '{}\n' > "${CONFIG_FILE}" || { error "could not seed ${CONFIG_FILE}"; exit 1; }
fi

# ---------------------------------------------------------------------------
# Pre-check: ruleIds presence (idempotency)
# ---------------------------------------------------------------------------
RULE_IDS=$(read_config_field ruleIds)

if [[ "${MODE}" == "default" ]]; then
  if [[ "${RULE_IDS}" == "nonempty" ]]; then
    error "ruleIds already populated; refusing to create duplicate. Use --interactive to update/recreate."
    exit 1
  fi
fi
# For interactive mode, re-run gate is handled in run_interactive() after flock acquisition.

# ---------------------------------------------------------------------------
# Acquire RULES_LOCK_FILE flock (guards pre-check-and-create window).
# Python fcntl.flock LOCK_EX|LOCK_NB; warns + exits 0 on contention.
# Bash 3.2: uses env-passing heredoc pattern.
# ---------------------------------------------------------------------------
exec 9>"${RULES_LOCK_FILE}"
if ! python3 - <<'PY'
import fcntl, sys
try:
    fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except (OSError, BlockingIOError):
    sys.exit(11)
PY
then
  warn "rules.lock held by concurrent setup-guardrails — skipping this run"
  exit 0
fi

# Re-check ruleIds after flock (TOCTOU defense)
RULE_IDS=$(read_config_field ruleIds)
if [[ "${RULE_IDS}" == "nonempty" ]]; then
  info "ruleIds populated by concurrent process — exiting cleanly"
  exit 0
fi

# ---------------------------------------------------------------------------
# Helper: compute_warn_threshold HARD_LIMIT
# Returns 80% of the hard limit via python3 float math, trailing zeros stripped.
# Bash 3.2: uses env-passing heredoc pattern.
# ---------------------------------------------------------------------------
compute_warn_threshold() {
  local hard_limit="$1"
  HARD_LIMIT_ENV="${hard_limit}" python3 - <<'PY'
import os
hard = float(os.environ['HARD_LIMIT_ENV'])
warn = hard * 0.8
result = f"{warn:.2f}".rstrip('0').rstrip('.')
print(result if result else '0')
PY
}

# ---------------------------------------------------------------------------
# Helper: period_titled PERIOD
# Title-cases the period string: MONTHLY -> Monthly, etc.
# ---------------------------------------------------------------------------
period_titled() {
  local period="$1"
  case "${period}" in
    DAILY)     echo "Daily" ;;
    WEEKLY)    echo "Weekly" ;;
    MONTHLY)   echo "Monthly" ;;
    QUARTERLY) echo "Quarterly" ;;
    *)         echo "${period}" ;;
  esac
}

# ---------------------------------------------------------------------------
# Helper: short_host
# Returns a short hostname for rule-name disambiguation. Order of preference:
# REVENIUM_BUDGET_LABEL env (already used by callers), hostname -s, uname -n,
# HOSTNAME shell var, then "unknown". Bash 3.2 safe; no herestrings.
# ---------------------------------------------------------------------------
short_host() {
  local h
  h=$(hostname -s 2>/dev/null) && [[ -n "${h}" ]] && { printf '%s' "${h}"; return; }
  h=$(uname -n 2>/dev/null) && [[ -n "${h}" ]] && { printf '%s' "${h}"; return; }
  [[ -n "${HOSTNAME:-}" ]] && { printf '%s' "${HOSTNAME}"; return; }
  printf 'unknown'
}

# ---------------------------------------------------------------------------
# Helper: budget_label
# Returns the deployment label for rule names: REVENIUM_BUDGET_LABEL if set,
# otherwise the output of short_host.
# ---------------------------------------------------------------------------
budget_label() {
  if [[ -n "${REVENIUM_BUDGET_LABEL:-}" ]]; then
    printf '%s' "${REVENIUM_BUDGET_LABEL}"
  else
    short_host
  fi
}

# ---------------------------------------------------------------------------
# Helper: find_existing_rules PERIOD GROUP_BY_ARG [EXTRA_FILTER]
# Calls `revenium guardrails budget-rules list --output json`, then uses a
# python3 env-passing heredoc to compare each rule's scope (filters, windowType
# or period field, groupBy) against the desired scope. Prints matching rule ids,
# one per line. Returns 0; empty output = no matches.
#
# Cross-deployment guard: on a shared tenant, OTHER hosts' rules have the SAME
# scope (AGENT:STARTS_WITH:openclaw- / period / groupBy) — scope alone would
# adopt-and-RENAME another deployment's rule (observed live 2026-06-12 against
# revenium-ftw-2's rule). Rules whose display name carries a deployment label
# ("... — <label>") are therefore only matched when the label equals THIS
# deployment's budget_label(); unlabeled rules (legacy/hand-created) remain
# adoptable as before.
#
# Fail-open: if the list call exits non-zero OR stdout is not valid JSON, the
# function returns 0 with no output (treated as "none found" → caller proceeds
# to create as normal). Bash 3.2 safe; no associative arrays, no herestrings.
# ---------------------------------------------------------------------------
find_existing_rules() {
  local desired_period="$1"
  local desired_group_by="$2"
  local desired_extra_filter="${3:-}"

  # Build the desired filter set as a colon-joined string:
  # "AGENT:STARTS_WITH:<prefix>" always; extra_filter appended when non-empty.
  local desired_filter_base="AGENT:STARTS_WITH:${REVENIUM_AGENT_PREFIX}"

  local desired_label
  desired_label=$(budget_label)

  local list_json
  list_json=$(revenium guardrails budget-rules list --output json 2>/dev/null) || list_json=""

  # Pass all values to python3 via env (bash 3.2: no herestrings).
  LIST_JSON="${list_json}" \
  DESIRED_PERIOD="${desired_period}" \
  DESIRED_GROUP_BY="${desired_group_by}" \
  DESIRED_FILTER_BASE="${desired_filter_base}" \
  DESIRED_EXTRA_FILTER="${desired_extra_filter}" \
  DESIRED_LABEL="${desired_label}" \
  python3 - <<'PY'
import json, os

def normalize_filter(s):
    """Normalize a DIM:OP:VALUE string: uppercase DIM and OP, preserve VALUE case."""
    parts = s.split(':', 2)
    if len(parts) == 3:
        return '{}:{}:{}'.format(parts[0].upper(), parts[1].upper(), parts[2])
    return s.upper()

def make_filter_set(filters):
    """Normalize a list of {dimension,operator,value} dicts to a frozenset of 'DIM:OP:VAL' strings."""
    result = set()
    for f in filters:
        d = str(f.get('dimension', '')).upper()
        o = str(f.get('operator', '')).upper()
        v = str(f.get('value', ''))   # preserve value case
        result.add('{}:{}:{}'.format(d, o, v))
    return frozenset(result)

list_json = os.environ.get('LIST_JSON', '')
desired_period = os.environ.get('DESIRED_PERIOD', '').upper()
desired_group_by = os.environ.get('DESIRED_GROUP_BY', 'AGENT').upper()
desired_filter_base = os.environ.get('DESIRED_FILTER_BASE', '')
desired_extra_filter = os.environ.get('DESIRED_EXTRA_FILTER', '')
desired_label = os.environ.get('DESIRED_LABEL', '')

# Build desired filter set (normalize each colon-joined filter string)
desired_filters = set()
if desired_filter_base:
    desired_filters.add(normalize_filter(desired_filter_base))
if desired_extra_filter:
    desired_filters.add(normalize_filter(desired_extra_filter))
desired_filter_set = frozenset(desired_filters)

try:
    rules = json.loads(list_json)
    if not isinstance(rules, list):
        raise ValueError("not a list")
except Exception:
    # Fail-open: non-JSON or error → no output
    import sys; sys.exit(0)

for rule in rules:
    try:
        # Compare filters (order-insensitive normalized set)
        rule_filter_set = make_filter_set(rule.get('filters', []))
        if rule_filter_set != desired_filter_set:
            continue

        # Compare window type / period (field name varies: windowType or period)
        rule_period = (rule.get('windowType') or rule.get('period') or '').upper()
        if rule_period != desired_period:
            continue

        # Compare groupBy
        rule_group_by = str(rule.get('groupBy') or 'AGENT').upper()
        if rule_group_by != desired_group_by:
            continue

        # Cross-deployment guard: a name carrying a deployment label
        # ("... — <label>", em-dash separator from the rule_name template)
        # belongs to whichever deployment minted it. Adopt only when the
        # label is OURS; skip foreign-labeled rules so a shared tenant never
        # gets another host's rule adopted and renamed. Unlabeled names
        # (legacy/hand-created) stay adoptable.
        rule_name = str(rule.get('name') or '')
        if ' — ' in rule_name:
            rule_label = rule_name.rsplit(' — ', 1)[1].strip()
            if rule_label and rule_label != desired_label:
                continue

        # All match — print the id
        print(rule['id'])
    except Exception:
        continue
PY
}

# ---------------------------------------------------------------------------
# Helper: create_rule RULE_NAME HARD_LIMIT WARN_THRESHOLD PERIOD
# Single call site for rule creation (single base rule per D-02/D-03).
# Sets RULE_ID and RULE_EXIT globals on return.
# Passes --shadow-mode=${SHADOW_MODE} EXPLICITLY (D-08): the API defaults
# shadowMode=true when the flag is omitted, so non-shadow mode must force
# --shadow-mode=false to get a genuinely enforcing rule. After create, the rule
# is read back and shadowMode is asserted to match intent — on mismatch the rule
# is cleaned up and RULE_ID is cleared so callers do NOT record a bad ruleId.
# Base filter: AGENT:STARTS_WITH:<prefix> using REVENIUM_AGENT_PREFIX (D-07).
# Optional 5th arg EXTRA_FILTER: additional --filter value (e.g. TASK_TYPE:IS:<label>).
# Optional 6th arg GROUP_BY_OVERRIDE: overrides --group-by (default AGENT) when non-empty.
# Bash 3.2: RULE_JSON passed via env to python3 heredoc.
# ---------------------------------------------------------------------------
RULE_EXIT=0
RULE_ID=""

create_rule() {
  local rule_name="$1"
  local hard_limit="$2"
  local warn_threshold="$3"
  local period="$4"
  local extra_filter="${5:-}"        # optional: e.g. "TASK_TYPE:IS:research" (NP-4)
  local group_by_override="${6:-}"   # optional: override --group-by (e.g. TASK_TYPE)

  local group_by_arg="${group_by_override:-AGENT}"

  # ---------------------------------------------------------------------------
  # Dedup branch: check for an existing same-scope rule before creating.
  # find_existing_rules is fail-open: non-JSON or CLI error → empty output →
  # falls through to the existing create logic unchanged.
  # ---------------------------------------------------------------------------
  local existing_ids_raw
  existing_ids_raw=$(find_existing_rules "${period}" "${group_by_arg}" "${extra_filter}") || existing_ids_raw=""

  # Count non-empty lines in the id list (bash 3.2 safe; no arrays)
  local existing_count=0
  local _line
  while IFS= read -r _line; do
    [[ -n "${_line}" ]] && existing_count=$((existing_count + 1))
  done <<EOF
${existing_ids_raw}
EOF

  if [[ "${existing_count}" -eq 1 ]]; then
    # Single match — adopt, best-effort rename, skip create.
    local existing_id="${existing_ids_raw}"
    existing_id="${existing_id%%$'\n'*}"   # first line (already only one, but be safe)
    existing_id=$(printf '%s' "${existing_id}" | tr -d '[:space:]')
    RULE_ID="${existing_id}"
    RULE_EXIT=0
    local log_existing_name
    # Fetch current display name for log (fail-open). Pass JSON via env — bash 3.2 safe.
    local _get_json
    _get_json=$(revenium guardrails budget-rules get "${RULE_ID}" --output json 2>/dev/null) || _get_json=""
    log_existing_name=$(GET_JSON="${_get_json}" python3 - <<'PY'
import json, os
try:
    d = json.loads(os.environ.get('GET_JSON', ''))
    print((d.get('name') or '')[:64])
except Exception:
    print('')
PY
    ) || log_existing_name=""
    info "Reusing existing budget rule ${RULE_ID} (${log_existing_name:0:64}) — skipping duplicate creation"
    # Best-effort name update when display name differs from desired
    if [[ -n "${log_existing_name}" && "${log_existing_name}" != "${rule_name}" ]]; then
      revenium guardrails budget-rules update "${RULE_ID}" --name "${rule_name}" >/dev/null 2>&1 \
        || warn "Could not rename rule ${RULE_ID} — non-critical"
    fi
    return
  elif [[ "${existing_count}" -gt 1 ]]; then
    # Multiple matches — warn, list delete commands, adopt first, skip create.
    echo "WARNING: Found ${existing_count} existing same-scope budget rules — they all meter the same spend."
    echo "To clean up duplicates, run the following delete commands (no auto-delete; a shared tenant may host other hosts' rules):"
    local first_id=""
    while IFS= read -r _line; do
      _line=$(printf '%s' "${_line}" | tr -d '[:space:]')
      [[ -z "${_line}" ]] && continue
      echo "  revenium guardrails budget-rules delete ${_line} --yes"
      warn "  revenium guardrails budget-rules delete ${_line} --yes"
      if [[ -z "${first_id}" ]]; then
        first_id="${_line}"
      fi
    done <<EOF
${existing_ids_raw}
EOF
    RULE_ID="${first_id}"
    RULE_EXIT=0
    info "Adopting first existing rule ${RULE_ID} — skipping duplicate creation"
    return
  fi
  # Zero matches → fall through to create as normal.

  local rule_json
  # T-03-09 mitigation: validate_hard_limit and validate_period enforce input
  # allowlists before values reach the CLI (ASVS V5 input validation). Both
  # validators run before create_rule is ever called.

  if [[ "${SHADOW_MODE}" == "true" ]]; then
    # Build cmd as positional params (bash-3.2 safe; avoids the one-word-expansion
    # bug of ${var:+--flag "${var}"} which produces "--flag value" as a single token).
    set -- \
      guardrails budget-rules create \
      --output json \
      --name "${rule_name}" \
      --description "" \
      --metric-type TOTAL_COST \
      --window-type "${period}" \
      --action BLOCK \
      --group-by "${group_by_arg}" \
      --warn-threshold "${warn_threshold}" \
      --hard-limit "${hard_limit}" \
      --filter "AGENT:STARTS_WITH:${REVENIUM_AGENT_PREFIX}"
    [[ -n "${extra_filter}" ]] && set -- "$@" --filter "${extra_filter}"
    rule_json=$(revenium "$@" --shadow-mode 2>&1) && RULE_EXIT=0 || RULE_EXIT=$?
  else
    # Pass --shadow-mode=false EXPLICITLY. The Revenium API defaults shadowMode
    # to true on create when the flag is omitted, so simply leaving it off
    # silently produces an observe-only (non-enforcing) rule. The explicit
    # =false forces a genuinely enforcing rule. (Verified against
    # api.revenium.ai: omit -> shadowMode:true; --shadow-mode=false -> false.)
    set -- \
      guardrails budget-rules create \
      --output json \
      --name "${rule_name}" \
      --description "" \
      --metric-type TOTAL_COST \
      --window-type "${period}" \
      --action BLOCK \
      --group-by "${group_by_arg}" \
      --warn-threshold "${warn_threshold}" \
      --hard-limit "${hard_limit}" \
      --filter "AGENT:STARTS_WITH:${REVENIUM_AGENT_PREFIX}"
    [[ -n "${extra_filter}" ]] && set -- "$@" --filter "${extra_filter}"
    rule_json=$(revenium "$@" --shadow-mode=false 2>&1) && RULE_EXIT=0 || RULE_EXIT=$?
  fi

  if [[ "${RULE_EXIT}" -ne 0 ]]; then
    local truncated_err="${rule_json:0:200}"
    error "rule creation failed (exit ${RULE_EXIT}): ${truncated_err}"
    RULE_ID=""
    return
  fi

  RULE_ID=$(RULE_JSON="${rule_json}" python3 - <<'PY'
import json, os, sys
try:
    d = json.loads(os.environ['RULE_JSON'])
    print(d['id'])
except Exception:
    pass
PY
  )

  if [[ -z "${RULE_ID}" ]]; then
    error "rule creation returned no id; cannot record. Raw: ${rule_json:0:200}"
    RULE_EXIT=1
    return
  fi

  # Verify the PERSISTED rule matches the requested enforcement intent. Because
  # the API silently defaults shadowMode=true on create, never trust the flag
  # alone — read the rule back and assert shadowMode == SHADOW_MODE so we never
  # record a rule whose real enforcement contradicts what the operator asked for.
  local verify_json verify_shadow
  verify_json=$(revenium guardrails budget-rules get "${RULE_ID}" --output json 2>&1) || verify_json=""
  verify_shadow=$(VERIFY_JSON="${verify_json}" python3 - <<'PY'
import json, os
try:
    sm = json.loads(os.environ['VERIFY_JSON']).get('shadowMode')
    print('true' if sm is True else 'false' if sm is False else 'unknown')
except Exception:
    print('unknown')
PY
  )

  if [[ "${verify_shadow}" == "unknown" ]]; then
    error "could not read back rule ${RULE_ID} to verify shadowMode; refusing to record it. Inspect/remove manually: revenium guardrails budget-rules delete ${RULE_ID} -y"
    RULE_ID=""
    RULE_EXIT=1
    return
  fi

  if [[ "${verify_shadow}" != "${SHADOW_MODE}" ]]; then
    error "rule ${RULE_ID} shadowMode mismatch: requested '${SHADOW_MODE}', persisted '${verify_shadow}'. Refusing to record a non-matching rule."
    # Best-effort cleanup so a retry doesn't accumulate an orphaned rule.
    revenium guardrails budget-rules delete "${RULE_ID}" -y >/dev/null 2>&1 \
      && info "Deleted mismatched rule ${RULE_ID}" \
      || warn "Could not delete mismatched rule ${RULE_ID} — remove it manually: revenium guardrails budget-rules delete ${RULE_ID} -y"
    RULE_ID=""
    RULE_EXIT=1
    return
  fi

  info "Created rule ${RULE_ID} for ${rule_name} (warn=${warn_threshold} hard=${hard_limit} period=${period} shadow=${SHADOW_MODE})"
}

# ---------------------------------------------------------------------------
# Helper: write_rule_ids_to_config RULE_IDS_JSON
# Atomic write via temp-then-rename (T-03-10 mitigation, D-14).
# Preserves alertId and all other existing config fields (D-04).
# Bash 3.2: all values passed via env; python3 heredoc.
# ---------------------------------------------------------------------------
write_rule_ids_to_config() {
  local rule_ids_json="$1"
  CONFIG_FILE="${CONFIG_FILE}" NEW_RULE_IDS_JSON="${rule_ids_json}" python3 - <<'PY'
import json, os, tempfile
from pathlib import Path

config_path = Path(os.environ['CONFIG_FILE'])
new_rule_ids = json.loads(os.environ['NEW_RULE_IDS_JSON'])

try:
    config = json.loads(config_path.read_text())
except Exception:
    config = {}

config['ruleIds'] = new_rule_ids
# D-04: leave legacy alertId as an orphan — never remove it from config.json.

tmp_dir = config_path.parent
with tempfile.NamedTemporaryFile('w', dir=str(tmp_dir), delete=False, suffix='.tmp') as tmp:
    json.dump(config, tmp, indent=2)
    tmp.write('\n')
    tmp.flush()
    os.fsync(tmp.fileno())
    tmp_name = tmp.name

os.rename(tmp_name, str(config_path))
PY
}

# ---------------------------------------------------------------------------
# Helper: write_rule_ids_and_config RULE_IDS_JSON AUTONOMOUS
# Extended write-back that persists ruleIds + autonomousMode (GUARD-06 / D-06).
#
# autonomousMode semantics (GUARD-06):
#   true  — agent hard-stops on halt without asking (autonomous enforcement)
#   false — agent warns and asks user before continuing (warn-and-ask, default)
#
# This is the sole writer for the autonomousMode field. SKILL.md reads this
# field from config.json to determine halt behavior (D-04, D-18).
#
# Preserves alertId and all other fields (D-04, T-03-10 mitigation).
# Atomic via temp-then-rename; Bash 3.2: all values passed via env.
# ---------------------------------------------------------------------------
write_rule_ids_and_config() {
  local rule_ids_json="$1"
  local autonomous="${2:-}"
  CONFIG_FILE="${CONFIG_FILE}" \
  NEW_RULE_IDS_JSON="${rule_ids_json}" \
  AUTONOMOUS="${autonomous}" \
  python3 - <<'PY'
import json, os, tempfile
from pathlib import Path

config_path = Path(os.environ['CONFIG_FILE'])
new_rule_ids = json.loads(os.environ['NEW_RULE_IDS_JSON'])
autonomous = os.environ.get('AUTONOMOUS', '')

try:
    config = json.loads(config_path.read_text())
except Exception:
    config = {}

config['ruleIds'] = new_rule_ids

if autonomous in ('true', 'false'):
    config['autonomousMode'] = (autonomous == 'true')
# D-04: leave legacy alertId as an orphan — never remove it from config.json.

tmp_dir = config_path.parent
with tempfile.NamedTemporaryFile('w', dir=str(tmp_dir), delete=False, suffix='.tmp') as tmp:
    json.dump(config, tmp, indent=2)
    tmp.write('\n')
    tmp.flush()
    os.fsync(tmp.fileno())
    tmp_name = tmp.name

os.rename(tmp_name, str(config_path))
PY
}

# ---------------------------------------------------------------------------
# Mode A: run_default — all args from CLI flags
# ---------------------------------------------------------------------------
run_default() {
  # Validate args (mode resolution already confirmed they're present)
  if ! validate_hard_limit "${HARD_LIMIT}"; then
    error "--hard-limit '${HARD_LIMIT}' must be a positive number"
    exit 2
  fi
  if ! validate_period "${PERIOD}"; then
    error "--period '${PERIOD}' must be DAILY, WEEKLY, MONTHLY, or QUARTERLY"
    exit 2
  fi

  local warn_threshold
  warn_threshold=$(compute_warn_threshold "${HARD_LIMIT}")

  local period_title
  period_title=$(period_titled "${PERIOD}")
  local _label
  _label=$(budget_label)
  local rule_name="OpenClaw ${period_title} Budget — ${_label}"

  create_rule "${rule_name}" "${HARD_LIMIT}" "${warn_threshold}" "${PERIOD}"

  if [[ "${RULE_EXIT}" -ne 0 || -z "${RULE_ID}" ]]; then
    exit 1
  fi

  local new_rule_ids_json="[\"${RULE_ID}\"]"
  # Write autonomousMode explicitly (true with --autonomous, else false) so the
  # field always exists: guardrail-check.sh derives halted = autonomous AND blocked,
  # and an absent field silently reads as false — hard limits would never hard-halt.
  write_rule_ids_and_config "${new_rule_ids_json}" "${AUTONOMOUS_MODE}"

  info "config.json now contains ruleIds=[${RULE_ID}] autonomousMode=${AUTONOMOUS_MODE}"
  echo "Created 1 rule(s). config.json updated. ruleIds=${new_rule_ids_json} autonomousMode=${AUTONOMOUS_MODE}"
}

# ---------------------------------------------------------------------------
# Mode B: run_interactive — operator prompts (D-18)
# Prompts for: hard limit, period, autonomous (grace) mode (GUARD-06/D-06),
# shadow mode (D-08). Writes ruleIds + autonomousMode to config.json.
# ---------------------------------------------------------------------------
run_interactive() {
  echo ""
  echo "Setting up Revenium guardrails budget rules for OpenClaw..."
  echo ""

  # Re-run gate: if ruleIds already populated, offer [r]ecreate / [c]ancel
  if [[ "${RULE_IDS}" == "nonempty" ]]; then
    echo "Existing budget rules found:"

    # List current rules from Revenium and display them
    local rules_json
    rules_json=$(revenium guardrails budget-rules list --output json 2>/dev/null) || rules_json="[]"

    # Read current ruleIds from config.json and display matching rules
    CONFIG_FILE="${CONFIG_FILE}" RULES_JSON="${rules_json}" python3 - <<'PY'
import json, os
try:
    config = json.loads(open(os.environ['CONFIG_FILE']).read())
except Exception:
    config = {}
rule_ids = config.get('ruleIds', [])
try:
    rules = json.loads(os.environ['RULES_JSON'])
except Exception:
    rules = []
rules_by_id = {r['id']: r for r in rules}
for rid in rule_ids:
    r = rules_by_id.get(rid)
    if r:
        # T-03-09: truncate name to 64 chars for display (log injection mitigation)
        name = (r.get('name') or '')[:64]
        print("  {}  {}  hard={}  warn={}  window={}".format(
            rid, name,
            r.get('hardLimit', '?'),
            r.get('warnThreshold', '?'),
            r.get('windowType', '?')
        ))
    else:
        print("  {}  (not found in Revenium)".format(rid))
PY

    echo ""
    echo "Note: hard-limit cannot be updated in place; choose [r] to delete and recreate."

    local rerun_action=""
    local attempt=0
    while [[ ${attempt} -lt 3 ]]; do
      read -r -p "Action? [r]ecreate / [c]ancel: " rerun_action
      case "${rerun_action}" in
        r|recreate)
          # Delete all existing rules then fall through to fresh-install path
          local cur_rule_ids_raw
          cur_rule_ids_raw=$(CONFIG_FILE="${CONFIG_FILE}" python3 - <<'PY'
import json, os
try:
    config = json.loads(open(os.environ['CONFIG_FILE']).read())
except Exception:
    config = {}
for rid in config.get('ruleIds', []):
    print(rid)
PY
          )
          # CR-01: clear ruleIds in config.json BEFORE deleting rules so a failed
          # create_rule does not leave stale IDs; next run re-triggers Setup Flow.
          write_rule_ids_to_config '[]'
          info "Cleared ruleIds in config.json for recreate"
          local rid
          while IFS= read -r rid; do
            if [[ -n "${rid}" ]]; then
              revenium guardrails budget-rules delete "${rid}" --yes >/dev/null 2>&1 || true
              info "Deleted existing rule ${rid}"
            fi
          done <<EOF
${cur_rule_ids_raw}
EOF
          RULE_IDS=""
          break
          ;;
        c|cancel|"")
          echo "Cancelled."
          exit 0
          ;;
        *)
          echo "Invalid choice. Please enter r or c."
          attempt=$((attempt + 1))
          ;;
      esac
    done

    if [[ ${attempt} -ge 3 ]]; then
      error "Too many invalid responses."
      exit 1
    fi
  fi

  # --------------------------------------------------------------------------
  # Operator prompts — fresh-install path
  # --------------------------------------------------------------------------
  local hard_limit="" period="" autonomous="" shadow_response=""

  # Prompt for hard limit
  local hl_attempt=0
  while [[ ${hl_attempt} -lt 3 ]]; do
    read -r -p "Budget hard limit (numeric, e.g. 50.00): " hard_limit
    if validate_hard_limit "${hard_limit}"; then
      break
    fi
    echo "Invalid input. Must be a positive number (e.g. 50 or 100.00)."
    hl_attempt=$((hl_attempt + 1))
  done
  if ! validate_hard_limit "${hard_limit}"; then
    error "Too many invalid inputs for hard-limit."
    exit 1
  fi

  # Prompt for period
  local period_attempt=0
  while [[ ${period_attempt} -lt 3 ]]; do
    read -r -p "Budget period (DAILY/WEEKLY/MONTHLY/QUARTERLY): " period
    if validate_period "${period}"; then
      break
    fi
    echo "Invalid period. Must be DAILY, WEEKLY, MONTHLY, or QUARTERLY."
    period_attempt=$((period_attempt + 1))
  done
  if ! validate_period "${period}"; then
    error "Too many invalid inputs for period."
    exit 1
  fi

  # Prompt for autonomous mode (GUARD-06 / D-06):
  # autonomous=true  → hard-stop on halt (autonomous mode; no warn-and-ask)
  # autonomous=false → warn-and-ask (default; user retains control)
  local auto_response=""
  read -r -p "Enable autonomous mode (hard-stop when budget is exceeded, no warn-and-ask)? (yes/no, default no): " auto_response || auto_response=""
  case "${auto_response}" in
    yes|y|YES|Y)
      autonomous="true"
      ;;
    *)
      autonomous="false"
      ;;
  esac

  # Prompt for shadow mode (D-08): observe-only rules, no blocking.
  # Added AFTER autonomous/notify prompts and BEFORE create_rule per plan spec.
  read -r -p "Run in shadow mode (observe-only rules, no blocking)? (yes/no, default no): " shadow_response || shadow_response=""
  case "${shadow_response}" in
    yes|y|YES|Y)
      SHADOW_MODE="true"
      ;;
    *)
      SHADOW_MODE="false"
      ;;
  esac

  local warn_threshold
  warn_threshold=$(compute_warn_threshold "${hard_limit}")

  local period_title
  period_title=$(period_titled "${period}")
  local _label
  _label=$(budget_label)
  local rule_name="OpenClaw ${period_title} Budget — ${_label}"

  # Create the base budget rule (--group-by AGENT; AGENT:STARTS_WITH filter from create_rule)
  create_rule "${rule_name}" "${hard_limit}" "${warn_threshold}" "${period}"

  if [[ "${RULE_EXIT}" -ne 0 || -z "${RULE_ID}" ]]; then
    error "Failed to create base budget rule."
    exit 1
  fi

  local base_rule_id="${RULE_ID}"

  # Start the accumulated rule_ids list with the base rule id
  # Uses newline-separated list for bash-3.2 compatibility (no arrays)
  local rule_ids_list="${base_rule_id}"

  # --------------------------------------------------------------------------
  # Per-task-type picker (ROADMAP criterion 5 / D-10 / NP-4)
  # Capability gate: only offer the picker if the installed CLI supports
  # TASK_TYPE as a filter dimension. Gate is defense-in-depth; on 1.1.2 the
  # gate always passes (TASK_TYPE VERIFIED). Fail-open: if absent, the base
  # rule is still created and recorded. (D-10)
  # --------------------------------------------------------------------------
  # Capture --help output first, THEN grep the captured string. Piping the
  # revenium process directly into `grep -q` is unsafe under `set -o pipefail`:
  # `grep -q` exits the instant it matches, closing the pipe while revenium is
  # still writing, so revenium dies with SIGPIPE (141). Under pipefail the
  # pipeline then reports 141 and the gate spuriously fails — randomly, since it
  # races on whether revenium finished writing first. That intermittently
  # skipped the entire per-task picker (ROADMAP criterion 5) in production.
  local _ttype_help
  _ttype_help="$(revenium guardrails budget-rules create --help 2>/dev/null || true)"
  if grep -q 'TASK_TYPE' <<<"${_ttype_help}"; then
    # Picker is supported — read labels from TAXONOMY_FILE
    if [[ -f "${TAXONOMY_FILE}" ]]; then
      local labels_json
      labels_json=$(TAXONOMY_FILE="${TAXONOMY_FILE}" python3 - <<'PY'
import json, os, sys
try:
    d = json.load(open(os.environ['TAXONOMY_FILE']))
    labels = list(d.get('labels', {}).keys())
    print(json.dumps(labels))
except Exception:
    print('[]')
PY
      )

      local label_count
      label_count=$(LABELS_JSON="${labels_json}" python3 - <<'PY'
import json, os
print(len(json.loads(os.environ['LABELS_JSON'])))
PY
      )

      if [[ "${label_count}" -gt 0 ]]; then
        echo ""
        echo "Available task types (optional per-task budget rules):"
        LABELS_JSON="${labels_json}" python3 - <<'PY'
import json, os
labels = json.loads(os.environ['LABELS_JSON'])
for i, label in enumerate(labels, 1):
    print(f"  {i}) {label}")
PY

        local task_selection=""
        read -r -p 'Which to enforce? (comma-separated indices, or "none"): ' task_selection || task_selection=""

        # Parse and validate comma-separated indices (T-04-11: skip out-of-range / non-numeric)
        local selected_labels
        selected_labels=$(LABELS_JSON="${labels_json}" TASK_TYPE_SELECTION="${task_selection}" python3 - <<'PY'
import json, os
labels = json.loads(os.environ['LABELS_JSON'])
sel = os.environ['TASK_TYPE_SELECTION'].strip().lower()
if sel == 'none' or not sel:
    print('[]')
else:
    try:
        # Validate each token: must be a digit string; skip non-numeric and out-of-range
        indices = [int(x.strip()) for x in sel.split(',') if x.strip().isdigit()]
        selected = [labels[i-1] for i in indices if 1 <= i <= len(labels)]
        print(json.dumps(selected))
    except Exception:
        print('[]')
PY
        )

        local num_selected
        num_selected=$(LABELS_JSON="${selected_labels}" python3 - <<'PY'
import json, os
print(len(json.loads(os.environ['LABELS_JSON'])))
PY
        )

        if [[ "${num_selected}" -gt 0 ]]; then
          local label_index=0
          while [[ ${label_index} -lt ${num_selected} ]]; do
            local label
            label=$(LABELS_JSON="${selected_labels}" IDX="${label_index}" python3 - <<'PY'
import json, os
labels = json.loads(os.environ['LABELS_JSON'])
print(labels[int(os.environ['IDX'])])
PY
            )

            # Prompt for per-task hard limit (T-04-10: reuse validate_hard_limit — ASVS V5)
            local task_hard_limit="" task_hl_attempt=0
            while [[ ${task_hl_attempt} -lt 3 ]]; do
              read -r -p "Hard limit for ${label} (numeric): " task_hard_limit
              if validate_hard_limit "${task_hard_limit}"; then
                break
              fi
              echo "Invalid input. Must be a positive number."
              task_hl_attempt=$((task_hl_attempt + 1))
            done
            if ! validate_hard_limit "${task_hard_limit}"; then
              warn "Skipping task-type rule for ${label} (invalid hard-limit after 3 attempts)."
              label_index=$((label_index + 1))
              continue
            fi

            local task_warn
            task_warn=$(compute_warn_threshold "${task_hard_limit}")

            # Build rule name: "OpenClaw <Label> Budget"
            # T-04-12: 64-char truncation in log lines (log injection mitigation, 03-PATTERNS)
            local label_title
            label_title=$(LABEL="${label}" python3 - <<'PY'
import os
s = os.environ['LABEL']
print(s.replace('_', ' ').title())
PY
            )
            local task_rule_name="OpenClaw ${label_title} Budget"

            # NP-4 FIX: each per-task rule carries TASK_TYPE:IS:<label> filter
            # AND --group-by TASK_TYPE. The Hermes picker omits these, producing
            # identical rules with only the base AGENT filter (Pitfall 4).
            local task_extra_filter="TASK_TYPE:IS:${label}"

            # Log injection mitigation: truncate rule name in log output (T-04-12)
            local log_rule_name="${task_rule_name:0:64}"
            info "Creating per-task rule: ${log_rule_name} (filter=${task_extra_filter})"

            create_rule "${task_rule_name}" "${task_hard_limit}" "${task_warn}" "${period}" \
              "${task_extra_filter}" "TASK_TYPE"

            if [[ "${RULE_EXIT}" -eq 0 && -n "${RULE_ID}" ]]; then
              rule_ids_list="${rule_ids_list}
${RULE_ID}"
            else
              warn "Failed to create rule for task type ${label} — skipping."
            fi

            label_index=$((label_index + 1))
          done
        fi
      fi
    fi
  else
    info "revenium CLI lacks TASK_TYPE filter dimension — skipping per-task-type picker (D-10 gate)"
  fi

  # Build the final ruleIds JSON array from the accumulated newline-separated list
  local new_rule_ids_json
  new_rule_ids_json=$(RULE_IDS_LIST="${rule_ids_list}" python3 - <<'PY'
import json, os
raw = os.environ['RULE_IDS_LIST'].strip()
ids = [line.strip() for line in raw.splitlines() if line.strip()]
print(json.dumps(ids))
PY
  )

  write_rule_ids_and_config "${new_rule_ids_json}" "${autonomous}"

  local rule_count
  rule_count=$(NEW_RULE_IDS_JSON="${new_rule_ids_json}" python3 - <<'PY'
import json, os
print(len(json.loads(os.environ['NEW_RULE_IDS_JSON'])))
PY
  )
  echo "Created ${rule_count} rule(s). config.json updated. ruleIds=${new_rule_ids_json}"
}

# ---------------------------------------------------------------------------
# Top-level mode dispatch (D-02: default | interactive only; no migration mode)
# ---------------------------------------------------------------------------
case "${MODE}" in
  interactive) run_interactive ;;
  default)     run_default ;;
  *)           error "unknown mode ${MODE}"; exit 2 ;;
esac
