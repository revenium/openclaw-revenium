# Phase 3: Guardrail Engine - Pattern Map

**Mapped:** 2026-05-31
**Files analyzed:** 9 (7 new/modified scripts + SKILL.md + BUDGET-GUARD.md)
**Analogs found:** 9 / 9

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `scripts/common.sh` | utility/library | N/A (sourced) | `../hermes-revenium/skills/revenium/scripts/common.sh` | exact |
| `scripts/guardrail-check.sh` | service/cron-stage | event-driven, file-I/O | `../hermes-revenium/skills/revenium/scripts/guardrail-check.sh` | exact |
| `scripts/setup-guardrails.sh` | utility/interactive | request-response | `../hermes-revenium/skills/revenium/scripts/setup-guardrails.sh` | exact (drop migration mode) |
| `scripts/cron.sh` | orchestrator/cron | batch | `scripts/cron.sh` (self, update) | exact |
| `scripts/post-install.sh` | config/installer | batch | `scripts/post-install.sh` (self, update) | exact |
| `scripts/clear-halt.sh` | utility | file-I/O | `scripts/clear-halt.sh` (self, update) | exact |
| `SKILL.md` | LLM-instruction | request-response | `../hermes-revenium/skills/revenium/SKILL.md` | exact |
| `BUDGET-GUARD.md` | LLM-instruction/bootstrap | request-response | `BUDGET-GUARD.md` (self, update) | exact |
| `scripts/budget-check.sh` | — | — | — | DELETE |

---

## Pattern Assignments

### `scripts/common.sh` (utility, sourced library) — NEW

**Analog:** `../hermes-revenium/skills/revenium/scripts/common.sh`

**Header pattern** (Hermes common.sh lines 1-3):
```bash
#!/usr/bin/env bash
# Common helpers for the Hermes Revenium skill.
set -uo pipefail
```
Note: Use `set -uo pipefail` (no `-e`) — this is a sourced library, not a top-level script.

**Path discovery pattern** (Hermes common.sh lines 6-9, adapted with OpenClaw multi-candidate probe from `scripts/cron.sh` lines 12-21):

The Hermes common.sh uses a single `HERMES_HOME` fallback. OpenClaw requires the multi-candidate probe already present in `cron.sh` and `budget-check.sh`. common.sh MUST use this probe, not the Hermes single-candidate pattern.

```bash
# Copy from scripts/cron.sh lines 12-21 verbatim; rename OPENCLAW_HOME
OPENCLAW_HOME="${OPENCLAW_HOME:-}"
if [[ -z "${OPENCLAW_HOME}" ]]; then
  for candidate in "${HOME}/.openclaw" "/home/ubuntu/.openclaw"; do
    if [[ -d "${candidate}/agents" ]]; then
      OPENCLAW_HOME="${candidate}"
      break
    fi
  done
  OPENCLAW_HOME="${OPENCLAW_HOME:-${HOME}/.openclaw}"
fi
```

**Path constants pattern** (Hermes common.sh lines 6-45, OpenClaw adaptation):
```bash
# OpenClaw collapses skill dir and state dir into one path (unlike Hermes)
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${OPENCLAW_HOME}/skills/revenium"
CONFIG_FILE="${STATE_DIR}/config.json"
GUARDRAIL_STATUS_FILE="${STATE_DIR}/guardrail-status.json"
LOCK_FILE="${STATE_DIR}/revenium-metering.lock"
LOG_FILE="${STATE_DIR}/revenium-metering.log"
REVENIUM_AGENT_NAME="${REVENIUM_AGENT_NAME:-OpenClaw}"   # D-23: NOT Hermes
```
Omit Hermes-only constants: `LEDGER_FILE`, `STATE_DB`, `TAXONOMY_FILE`, `MARKERS_DIR`, `WARN_FLAGS_DIR`, `PRUNE_LOCK_FILE`, `JOBS_LEDGER_FILE`, `HOOKS_CONFIG_FILE`, `TOOL_EVENTS_DIR`, `MIGRATION_NOTIFY_FILE`. Include only: `RULES_LOCK_FILE` (needed by setup-guardrails.sh flock).

**ensure_path pattern** (Hermes common.sh lines 48-56):
```bash
ensure_path() {
  local brew_prefix=""
  if command -v brew >/dev/null 2>&1; then
    brew_prefix="$(brew --prefix 2>/dev/null || true)"
  fi
  for p in \
    "${brew_prefix:+${brew_prefix}/bin}" \
    "${brew_prefix:+${brew_prefix}/sbin}" \
    /home/linuxbrew/.linuxbrew/bin \
    /home/linuxbrew/.linuxbrew/sbin \
    /opt/homebrew/bin \
    /opt/homebrew/sbin \
    /usr/local/bin \
    /usr/bin \
    "${HOME}/go/bin" \
    "${HOME}/.local/bin"; do
    [[ -n "${p}" && -d "${p}" ]] && export PATH="${p}:${PATH}"
  done
}
```
This pattern matches the inline PATH extension in `scripts/cron.sh` lines 36-52 and `scripts/budget-check.sh` lines 23-30. Port the function form from Hermes.

**log/info/warn/error pattern** (Hermes common.sh lines 58-80):
```bash
log() {
  local level="$1"; shift
  local line="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [${level}] [revenium] $*"
  mkdir -p "${STATE_DIR}"
  printf '%s\n' "${line}" >> "${LOG_FILE}"
  if [[ -t 2 ]]; then
    printf '%s\n' "${line}" >&2
  fi
}
info()  { log "INFO " "$@"; }
warn()  { log "WARN " "$@"; }
error() { log "ERROR" "$@"; }
```
TTY guard (`-t 2`) prevents double-logging under cron redirect (`>> logfile 2>&1`). Port verbatim from Hermes.

**has_guardrails_cli probe** (Hermes common.sh lines 85-88):
```bash
has_guardrails_cli() {
  revenium guardrails budget-rules --help >/dev/null 2>&1 && \
  revenium guardrails enforcement-events --help >/dev/null 2>&1
}
```
Verified against revenium 1.1.2.

**mkdir initialization** (Hermes common.sh line 46):
```bash
mkdir -p "${STATE_DIR}"
```
Hermes creates multiple dirs; OpenClaw needs only `STATE_DIR` (single path model).

**Omit from OpenClaw common.sh:**
- `get_root_session_id()` (Phase 4 concern, Hermes-specific)
- `TAXONOMY_FILE`, `MARKERS_DIR`, `TOOL_EVENTS_DIR` constants
- `HERMES_HOME` / `REVENIUM_STATE_DIR` env vars

---

### `scripts/guardrail-check.sh` (cron-stage, event-driven + file-I/O) — NEW

**Analog:** `../hermes-revenium/skills/revenium/scripts/guardrail-check.sh`

**Header and source pattern** (Hermes guardrail-check.sh lines 1-20):
```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/common.sh"

_PATH_HEAD="${PATH%%:*}"
ensure_path
[[ -n "${_PATH_HEAD}" ]] && export PATH="${_PATH_HEAD}:${PATH}"
```
The `_PATH_HEAD` save-and-restore pattern preserves test-injected stub directories.

**Preflight / silent-exit guard** (Hermes guardrail-check.sh lines 22-43, D-13):

CRITICAL: D-13 requires the `ruleIds` absent/empty check to be a BARE `exit 0` with no log output. Insert it BEFORE the preflight checks that emit `warn` logs (D-03/Pitfall 6):

```bash
# D-13: ruleIds absent or empty → exit silently. Must precede all warn-logging code.
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
  exit 0
fi
```

Then the warn-emitting preflights (Hermes guardrail-check.sh lines 22-42 pattern):
```bash
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
```

**read_config_field helper** (Hermes guardrail-check.sh lines 45-54):
```bash
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
```

**teamId resolution** (Hermes guardrail-check.sh lines 72-77):
```bash
TEAM_ID=$(revenium config show 2>&1 | sed -n 's/.*Team ID:[ \t]*//p' | tr -d ' ')
if [[ -z "${TEAM_ID}" ]]; then
  warn "Could not resolve teamId from revenium config show — skipping guardrail check."
  exit 0
fi
```
OPEN QUESTION: verify `revenium config show` output format matches this sed on revenium 1.1.2.

**API fetch pattern** (Hermes guardrail-check.sh lines 79-87):
```bash
ENFORCEMENT_JSON=$(revenium guardrails enforcement-rules get "${TEAM_ID}" --output json 2>&1) || true
if echo "${ENFORCEMENT_JSON}" | grep -q '"error".*EOF'; then
  ENFORCEMENT_JSON='{"rules": []}'
fi
BUDGET_RULES_JSON=$(revenium guardrails budget-rules list --output json 2>/dev/null || echo '[]')
```
Note: `--output json` (not `--json`); `|| true` for fail-open; EOF guard for empty team.

**Python state derivation heredoc** (Hermes guardrail-check.sh lines 90-281):

Port the entire Python block verbatim with these substitutions:
- `GUARDRAIL_STATUS_FILE="${GUARDRAIL_STATUS_FILE}"` — path constant from common.sh (same key name)
- No changes to the Python logic itself — shadow mode, name-join, atomic write, halt transition, shadow transition all port verbatim.

**Notification dispatch** — replace Hermes messaging with OpenClaw (D-10):
```bash
# Replace (Hermes guardrail-check.sh lines 345-357):
# hermes chat --toolsets messaging -q "Use the send_message tool to send..."
# With (D-10 verified form):
if command -v openclaw >/dev/null 2>&1; then
  openclaw message send \
    --channel "${NOTIFY_CHANNEL}" \
    --target "${NOTIFY_TARGET}" \
    -m "${MSG}" >/dev/null 2>&1 && \
    info "Halt notification sent via openclaw ${NOTIFY_CHANNEL}" || \
    warn "Failed to send halt notification via openclaw ${NOTIFY_CHANNEL}"
else
  warn "openclaw CLI not available — halt notification not sent"
fi
```
Apply same substitution to the shadow notification loop (Hermes lines 366-389).

**Halt message template** (D-10, adapted from Hermes line 344):
```bash
MSG="Guardrail halt active — rule '${HALTED_RULE_NAME}' (${HALTED_METRIC_TYPE}, ${HALTED_WINDOW_TYPE}) at ${HALTED_CURRENT_VALUE} of ${HALTED_HARD_LIMIT} hard-limit. To resume: bash ~/.openclaw/skills/revenium/scripts/clear-halt.sh | Event: [${EVENT_TS}] ${EVENT_SUMMARY}"
```

**Legacy budget-status.json cleanup** (Hermes guardrail-check.sh lines 294-298):
```bash
if [[ -f "${STATE_DIR}/budget-status.json" ]]; then
  rm -f "${STATE_DIR}/budget-status.json"
  info "Cleaned up legacy budget-status.json"
fi
```
Port verbatim — `STATE_DIR` is the same path in OpenClaw.

---

### `scripts/setup-guardrails.sh` (utility, interactive + request-response) — NEW

**Analog:** `../hermes-revenium/skills/revenium/scripts/setup-guardrails.sh`

**Header and mode dispatch** (Hermes setup-guardrails.sh lines 1-15):
```bash
#!/usr/bin/env bash
set -euo pipefail
# setup-guardrails.sh — interactive rule-creation entry point.
# Two modes per D-02 (migration mode dropped):
#   default      : --hard-limit N --period P [...] from CLI args
#   --interactive : operator prompts; called by SKILL.md Setup Flow
# Bash 3.2 compatible — uses env-passing heredoc pattern (no bash 4.4+ operators).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"
ensure_path
```

**Mode simplification** (D-02): Drop the `from-alert` mode entirely. The mode dispatch collapses from three cases to two:
```bash
# Hermes (lines 930-935):
# case "${MODE}" in
#   interactive) run_interactive ;;
#   from-alert)  run_migration ;;   # DROP THIS
#   default)     run_default ;;
# ...

# OpenClaw:
case "${MODE}" in
  interactive) run_interactive ;;
  default)     run_default ;;
  *)           error "unknown mode ${MODE}"; exit 2 ;;
esac
```
Remove: `--from-alert`, `--auto`, `MODE="from-alert"` parser cases, `run_migration()`, `migration_notify_once()`, `migration_notify_reset()`, `MIGRATION_NOTIFY_FILE`, `FROM_ALERT`, `AUTO` variables.

**Flock acquisition** (Hermes setup-guardrails.sh lines 265-276):
```bash
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
```

**create_rule helper** (Hermes setup-guardrails.sh lines 293-358):

Port verbatim with one substitution in the default filter line:
```bash
# Hermes line 330:
cmd+=(--filter "AGENT:IS:${REVENIUM_AGENT_NAME}")
# OpenClaw: same line — REVENIUM_AGENT_NAME defaults to "OpenClaw" in common.sh
```
Rule name uses "OpenClaw" prefix per D-23 (Specific Ideas):
```bash
# Hermes line 535:
local rule_name="Hermes ${period_title} Budget"
# OpenClaw:
local rule_name="OpenClaw ${period_title} Budget"
```
Same substitution in `run_interactive()` line 686.

**write_rule_ids_to_config and write_rule_ids_and_config helpers** (Hermes setup-guardrails.sh lines 365-449):
Port both helpers verbatim — they use `CONFIG_FILE` from common.sh (same env var name).

**validate_hard_limit / validate_period / compute_warn_threshold / period_titled** (Hermes setup-guardrails.sh lines 210-514):
```bash
validate_hard_limit() { [[ "$1" =~ ^[0-9]+(\.[0-9]+)?$ ]]; }
validate_period() {
  case "$1" in DAILY|WEEKLY|MONTHLY|QUARTERLY) return 0 ;; *) return 1 ;; esac
}
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
```
Port verbatim — no Hermes-specific logic.

**run_interactive shadow-mode prompt** (D-08 addition — not in Hermes v1.3, add after autonomous prompt):
```bash
# After the autonomous/notify prompts and BEFORE create_rule:
local shadow_response=""
read -r -p "Run in shadow mode (observe-only rules, no blocking)? (yes/no, default no): " shadow_response || shadow_response=""
case "${shadow_response}" in
  yes|y|YES|Y) SHADOW_MODE="true" ;;
  *) SHADOW_MODE="false" ;;
esac
```

**Task-type picker section** (Hermes setup-guardrails.sh lines 700-797):
Omit entirely — no `TAXONOMY_FILE` in OpenClaw Phase 3. `run_interactive` creates only the single base budget rule.

---

### `scripts/cron.sh` (orchestrator/cron, batch) — UPDATE

**Analog:** `scripts/cron.sh` (self)

**Current pipeline** (cron.sh lines 68-76 — replace):
```bash
# CURRENT (lines 68-76):
(
  flock -n 9 || exit 0
  bash "${SKILL_DIR}/scripts/budget-check.sh" || true   # DELETE
  run_report "$@" || true
) 9>"${LOCK_FILE}"
```

**New pipeline** (D-20, reversed ordering to match RESEARCH.md pattern):
```bash
# After Phase 3:
(
  flock -n 9 || exit 0
  run_report "$@" || true
  bash "${SKILL_DIR}/scripts/guardrail-check.sh" || true
) 9>"${LOCK_FILE}"
```
Remove the comment block on lines 70-73 that explains why budget-check.sh ran first — the new ordering is reversed (report first, then check). The LOCK_FILE variable is unchanged.

All other content in cron.sh (OPENCLAW_HOME probe lines 12-21, ENV_FILE source, PATH extension, run_report function with timeout) is UNCHANGED.

---

### `scripts/post-install.sh` (config/installer, batch) — UPDATE

**Analog:** `scripts/post-install.sh` (self)

Four targeted changes only; everything else unchanged.

**Change 1 — chmod loop** (post-install.sh line 114):
```bash
# CURRENT:
for script in cron.sh report.sh budget-check.sh install-cron.sh uninstall-cron.sh clear-halt.sh post-install.sh; do

# AFTER:
for script in cron.sh report.sh common.sh setup-guardrails.sh guardrail-check.sh install-cron.sh uninstall-cron.sh clear-halt.sh post-install.sh; do
```

**Change 2 — seed step** (post-install.sh lines 386-413, step 5):

Replace the `budget-status.json` seeding block with a `guardrail-status.json` placeholder:
```bash
# Step 5: Seed initial guardrail-status.json
GUARDRAIL_STATUS_FILE="${SKILL_DIR}/guardrail-status.json"
if [[ ! -f "${GUARDRAIL_STATUS_FILE}" ]]; then
  python3 -c "
import json, sys
data = {'halted': False, 'lastChecked': None, 'rules': []}
with open('${GUARDRAIL_STATUS_FILE}', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"
  info "Seeded guardrail-status.json placeholder"
fi
```
Remove the `budget-check.sh` invocation in this step entirely (D-20).

**Change 3 — BUDGET-GUARD.md content write** (post-install.sh lines 509-518, step 8):

The copy-from-SKILL_DIR approach is preserved; the content of `SKILL_DIR/BUDGET-GUARD.md` changes (see BUDGET-GUARD.md section below). post-install.sh copies the file — no logic change, only the source file content changes.

**Change 4 — verification section** (post-install.sh line 563):
Remove the `budget-status.json` / `report.sh` check; add `guardrail-check.sh` check:
```bash
if [[ -f "${SKILL_DIR}/scripts/guardrail-check.sh" ]]; then
  info "Guardrail scripts present"
else
  warn "Guardrail scripts missing — cron enforcement will not work"
fi
```

---

### `scripts/clear-halt.sh` (utility, file-I/O) — UPDATE

**Analog:** `scripts/clear-halt.sh` (self)

Full rewrite of the file body; header pattern preserved.

**Current pattern** (clear-halt.sh lines 1-32):
```bash
#!/usr/bin/env bash
set -euo pipefail
SKILL_DIR="${HOME}/.openclaw/skills/revenium"
BUDGET_STATUS_FILE="${SKILL_DIR}/budget-status.json"   # OLD
```

**New pattern** (target `guardrail-status.json`, preserve all other fields per Pitfall 8):
```bash
#!/usr/bin/env bash
# =============================================================================
# Clear guardrail enforcement halt
# Allows the autonomous agent to resume operations after a guardrail block.
# =============================================================================
set -euo pipefail

SKILL_DIR="${HOME}/.openclaw/skills/revenium"
GUARDRAIL_STATUS_FILE="${SKILL_DIR}/guardrail-status.json"

if [[ ! -f "${GUARDRAIL_STATUS_FILE}" ]]; then
  echo "No guardrail-status.json found — nothing to clear."
  exit 0
fi

python3 -c "
import json, os, tempfile
from pathlib import Path

status_path = Path('${GUARDRAIL_STATUS_FILE}')
data = json.loads(status_path.read_text())

if not data.get('halted', False):
    print('No halt is currently active.')
else:
    data['halted'] = False
    # Preserve haltedRule and haltedAt for audit (do NOT pop them)
    # Write atomically
    tmp_fd, tmp_path = tempfile.mkstemp(dir=str(status_path.parent), suffix='.tmp')
    try:
        with os.fdopen(tmp_fd, 'w') as f:
            f.write(json.dumps(data, indent=2) + '\n')
        os.replace(tmp_path, str(status_path))
    finally:
        try:
            os.unlink(tmp_path)
        except FileNotFoundError:
            pass
    print('Guardrail halt cleared. The agent may now resume operations.')
"
```
Key difference from Phase 2: uses `guardrail-status.json` (not `budget-status.json`), uses atomic write (temp-then-rename), and preserves `haltedRule`/`haltedAt` fields for audit trail.

---

### `SKILL.md` (LLM-instruction, request-response) — REWRITE

**Analog:** `../hermes-revenium/skills/revenium/SKILL.md`

**Frontmatter** — preserve existing OpenClaw frontmatter:
```yaml
---
name: revenium
description: "MANDATORY guardrail check BEFORE EVERY OPERATION — read guardrail-status.json first, always, no exceptions. Enforces Revenium guardrails-native budget rules, warns on threshold exceedance, halts autonomous agents on guardrail block."
metadata: {"openclaw":{"emoji":"💰","version":"0.2.0","homepage":"https://docs.revenium.io/for-ai-agents",...}}
---
```

**HALT CHECK section** (Hermes SKILL.md lines 24-43, adapted D-16):
```markdown
## HALT CHECK — DEFENSE-IN-DEPTH BACKSTOP

Guardrail enforcement relies on SKILL.md as the primary enforcement gate (OpenClaw
hooks are not yet confirmed). This section is non-optional.

**If you read `~/.openclaw/skills/revenium/guardrail-status.json` and `halted` is `true`:**
read the `haltedRule` block. Your entire response must be exactly:

> Guardrail halt active — rule '[haltedRule.name]' ([haltedRule.metricType],
> [haltedRule.windowType]) at [haltedRule.currentValue] of [haltedRule.hardLimit]
> hard-limit. To resume: `bash ~/.openclaw/skills/revenium/scripts/clear-halt.sh`

Substitute actual values from `haltedRule`. Do not add any other content.
Do NOT make any tool calls. Do NOT read anything else first.

**If `halted` is `false`, proceed to the Guardrail Check Procedure below.**
```

**Guardrail Check Procedure section** (Hermes SKILL.md lines 45-70, adapted):
Substitute `~/.hermes/state/revenium/` → `~/.openclaw/skills/revenium/` in all paths.

**Path Resolution section** (Hermes SKILL.md lines 72-74, adapted):
Remove the two-path Hermes model (skill vs state). Use single path:
```markdown
All file paths use `~/.openclaw/skills/revenium/` as both the skill directory and
the runtime state directory. When using file tools, pass paths with `~/`. When
running shell commands, use `$HOME/.openclaw/skills/revenium/` explicitly.
```

**Setup gate** (D-17, Hermes SKILL.md lines 99-104):
```markdown
At the start of any operation, check: does `~/.openclaw/skills/revenium/config.json`
exist AND contain a non-empty `ruleIds` array (present and not `[]`)?

- **If YES** and the user has NOT requested reconfiguration: setup is complete.
  Proceed to the guardrail check.
- **If NO** (file missing, `ruleIds` absent, or `ruleIds` is `[]`): run the Setup
  Flow below. Note: a legacy `alertId`-only config.json also triggers Setup Flow —
  `alertId` is deprecated and ignored for this gate. `ruleIds` is the sole signal.
```

**Setup Flow** (D-18, Hermes SKILL.md lines 106-156, simplified to 4 steps):
Drop the task-type picker, hook install, and migration references. Steps:
1. Verify `revenium config show` (API key check)
2. If no API key: collect and instruct host-side `revenium config set ...` (same as Phase 2 SKILL.md steps 1-2)
3. Run `bash ~/.openclaw/skills/revenium/scripts/setup-guardrails.sh --interactive`
4. Install cron: `bash ~/.openclaw/skills/revenium/scripts/install-cron.sh`

Exit-code contract from script (Hermes SKILL.md lines 139-142):
```markdown
- Exit 0, final output `Created N rule(s). config.json updated. ruleIds=[...]` → success
- Exit 0, final output `Cancelled.` → user cancelled; STOP
- Non-zero → failure; report verbatim and STOP
```

**`/revenium` command** (D-19, Hermes SKILL.md lines 159-166):
```markdown
When the user invokes `/revenium`:

1. Show `ruleIds` from `config.json` and per-rule state from `guardrail-status.json`
   (`state`, `currentValue`, `hardLimit`, `shadowMode` for each rule).
2. Show autonomous mode and current halt state.
3. Offer:
   - `reconfigure` → run `bash ~/.openclaw/skills/revenium/scripts/setup-guardrails.sh --interactive`
   - `done` → exit.
```

**Drop from SKILL.md:**
- Steps 3-14 of the old Setup Flow (budget alert API calls, alertId writing — all moved to script)
- Reset Budget Flow (alertId-specific — deprecated)
- Reconfiguration Flow that manually strips `alertId` (script handles it now)
- All references to `budget-status.json`, `exceeded`, `threshold`, `percentUsed`, `alertId`

---

### `BUDGET-GUARD.md` (LLM-instruction/bootstrap, request-response) — UPDATE

**Analog:** `BUDGET-GUARD.md` (self)

**Current content** reads `budget-status.json` and checks `exceeded`. Replace entirely with D-07 content:

```markdown
## Guardrail Enforcement (Mandatory)

BEFORE EVERY RESPONSE — read `~/.openclaw/skills/revenium/guardrail-status.json`.

- **File missing:** Proceed with caution.
- **`halted` is `false`:** Proceed silently.
- **`halted` is `true`:** YOUR ENTIRE RESPONSE MUST BE EXACTLY the halt message
  from `~/.openclaw/skills/revenium/SKILL.md` (HALT CHECK section) — substitute
  values from the `haltedRule` block in guardrail-status.json. Do NOT continue.

No operation is exempt.
```

Minimal by design (D-07): one directive, one file path, redirect to SKILL.md for the full halt string template.

---

## Shared Patterns

### OPENCLAW_HOME Multi-Candidate Probe
**Source:** `scripts/cron.sh` lines 12-21 and `scripts/budget-check.sh` lines 6-15
**Apply to:** `scripts/common.sh` (all sourcing scripts inherit it from common.sh)
```bash
OPENCLAW_HOME="${OPENCLAW_HOME:-}"
if [[ -z "${OPENCLAW_HOME}" ]]; then
  for candidate in "${HOME}/.openclaw" "/home/ubuntu/.openclaw"; do
    if [[ -d "${candidate}/agents" ]]; then
      OPENCLAW_HOME="${candidate}"
      break
    fi
  done
  OPENCLAW_HOME="${OPENCLAW_HOME:-${HOME}/.openclaw}"
fi
```
This multi-candidate probe is the established OpenClaw pattern. Hermes common.sh does NOT have this — common.sh must add it, not inherit it from Hermes.

### Atomic JSON Write (temp-then-rename)
**Source:** `../hermes-revenium/skills/revenium/scripts/guardrail-check.sh` lines 252-265
**Apply to:** `guardrail-check.sh` (guardrail-status.json), `setup-guardrails.sh` (config.json), `clear-halt.sh` (guardrail-status.json)
```python
import tempfile, os
from pathlib import Path
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
```

### Fail-Open Cron Posture
**Source:** `scripts/cron.sh` lines 68-76, `scripts/budget-check.sh` pattern
**Apply to:** `guardrail-check.sh` (every failure path), `cron.sh` (wrapper)
Every error in guardrail-check.sh MUST `exit 0`. Use `|| true` in cron.sh pipeline. No failure path may exit non-zero from the cron context.

### Python3 Env-Passing Heredoc (Bash 3.2 safe)
**Source:** `../hermes-revenium/skills/revenium/scripts/setup-guardrails.sh` lines 194-205, 265-272
**Apply to:** All Python calls in `setup-guardrails.sh`, `guardrail-check.sh`, `clear-halt.sh`
```bash
# Pass variables via environment, NOT shell substitution inside heredoc:
CONFIG_FILE="${CONFIG_FILE}" KEY="$1" python3 - <<'PY'
import json, os
val = json.load(open(os.environ['CONFIG_FILE'])).get(os.environ['KEY'], '')
print(val if val is not None else '')
PY
```
Never interpolate `${VARIABLE}` inside the `<<'PY'` heredoc body. Always pass via env.

### Log Injection Mitigation (64-char truncation)
**Source:** `../hermes-revenium/skills/revenium/scripts/setup-guardrails.sh` line 849
**Apply to:** `guardrail-check.sh` (rule name in log lines), `setup-guardrails.sh` (alert data in logs)
```python
name = (match.get('name') or '')[:64]
```

### OpenClaw Notification Command
**Source:** `scripts/budget-check.sh` lines 116-119 (existing), D-10
**Apply to:** `guardrail-check.sh` (halt notification, shadow notification)
```bash
if command -v openclaw &>/dev/null; then
  openclaw message send \
    --channel "${NOTIFY_CHANNEL}" \
    --target "${NOTIFY_TARGET}" \
    -m "${MSG}" 2>/dev/null && \
    info "Notification sent via ${NOTIFY_CHANNEL}" || \
    warn "Failed to send notification via ${NOTIFY_CHANNEL}"
else
  warn "openclaw CLI not available — notification not sent"
fi
```
POST-UPGRADE CHECK: After upgrading to 2026.5.28, re-verify `--channel`, `--target`, `-m` flags still exist. The `-m` short form was verified on 2026.3.13.

---

## No Analog Found

All files have close analogs. No entries here.

---

## Key Substitution Map (Hermes → OpenClaw)

| Hermes | OpenClaw |
|--------|----------|
| `~/.hermes/state/revenium/` | `~/.openclaw/skills/revenium/` |
| `~/.hermes/skills/revenium/` | `~/.openclaw/skills/revenium/` |
| `HERMES_HOME` | `OPENCLAW_HOME` |
| `REVENIUM_AGENT_NAME="Hermes"` | `REVENIUM_AGENT_NAME="OpenClaw"` |
| `hermes chat --toolsets messaging -q "..."` | `openclaw message send --channel X --target Y -m "MSG"` |
| `"Hermes {Period} Budget"` | `"OpenClaw {Period} Budget"` |
| `clear-halt.sh` resume path in MSG | `bash ~/.openclaw/skills/revenium/scripts/clear-halt.sh` |
| `${REVENIUM_STATE_DIR}` | `${OPENCLAW_HOME}/skills/revenium` |
| `budget-status.json` | `guardrail-status.json` |
| migration mode (`run_migration`) | DROP ENTIRELY |
| task-type picker in `run_interactive` | DROP ENTIRELY (Phase 4) |

## Metadata

**Analog search scope:** `scripts/` (openclaw-revenium), `../hermes-revenium/skills/revenium/scripts/`, `../hermes-revenium/skills/revenium/SKILL.md`
**Files read:** 10
**Pattern extraction date:** 2026-05-31
