# Phase 3: Guardrail Engine - Research

**Researched:** 2026-05-31
**Domain:** Bash scripting, Revenium guardrails CLI, OpenClaw skill model, shell patterns
**Confidence:** HIGH

## Summary

Phase 3 replaces the legacy budget-alert polling model (`budget-check.sh` + `budget-status.json`) with a guardrails-native enforcement engine. The deliverables are five interconnected pieces: a `common.sh` shared helper library, a `setup-guardrails.sh` interactive rule creator, a `guardrail-check.sh` cron enforcement stage, an updated `cron.sh` pipeline, and a rewritten SKILL.md enforcement section. Additionally, `clear-halt.sh`, `post-install.sh`, and `BUDGET-GUARD.md` need targeted content updates.

The canonical implementation exists in `../hermes-revenium/skills/revenium/` and has been read in full. Porting to OpenClaw requires three categories of substitution: path rewrites (`~/.hermes/state/revenium/` → `~/.openclaw/skills/revenium/`), agent name (`Hermes` → `OpenClaw`), and notification command (`hermes chat --toolsets messaging` → `openclaw message send --channel X --target Y -m "MSG"`). The migration mode (`--from-alert --auto`) from the Hermes version is dropped per D-02/D-03. Shadow mode and halt transition logic port verbatim.

A critical pre-execution gate (D-01) applies: OpenClaw is currently at 2026.3.13 (npm); 2026.5.28 is available via `npm update -g openclaw`. The upgrade MUST happen before authoring scripts, and the `openclaw message send` flag form must be re-verified post-upgrade. The current 2026.3.13 `openclaw message send --help` output has been captured as a baseline.

**Primary recommendation:** Port Hermes scripts with the three substitution categories above, drop migration mode entirely, and insert the `ruleIds`-absent silent-exit guard (D-03/D-13) at the top of guardrail-check.sh.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Pre-execution: OpenClaw Upgrade**
- D-01: Upgrade OpenClaw to 2026.5.28 (latest) BEFORE authoring any scripts. Current install is 2026.3.13 (2 months stale). Re-verify `openclaw message send`, `openclaw hooks`, and all CLI commands against the new version before scripting them.

**Legacy Migration**
- D-02: No auto-migration code. Phase 3 does NOT include `--from-alert --auto` migration logic in cron.sh or setup-guardrails.sh.
- D-03: When `guardrail-check.sh` runs on an install with `alertId` but no `ruleIds`, it exits 0 silently (fail-open). No warning line, no cron log noise.
- D-04: When the user runs `/revenium` on a legacy alertId-only install (ruleIds absent or empty array), SKILL.md applies the same gate as Phase 2: treat as "setup not complete" and run the full Setup Flow. Old `alertId` is left in config.json as an orphan (not cleaned up by the skill).

**Workspace Bootstrap File**
- D-05: Keep the filename `BUDGET-GUARD.md` — no rename. Update content only.
- D-06: `post-install.sh` is responsible for writing/updating `BUDGET-GUARD.md` to the workspace directory and ensuring it is registered in the `bootstrap-extra-files` hook config in `~/.openclaw/openclaw.json`.
- D-07: BUDGET-GUARD.md content stays minimal after the Phase 3 update — one directive: "Read `~/.openclaw/skills/revenium/guardrail-status.json`. If `halted` is `true`, output the halt message from SKILL.md and stop."

**Shadow Mode**
- D-08: Shadow mode supported with full interactive prompt parity with Hermes. `setup-guardrails.sh --interactive` asks the user: "Run in shadow mode (observe-only rules)?" before creating rules. `--shadow-mode` flag also accepted for non-interactive invocations.
- D-09: `guardrail-check.sh` excludes shadow-mode rules from the halt decision (`halted` stays `false`) but includes them in `rules[]` with their actual `state` for dashboard visibility. Shadow transitions (first time a shadow rule enters `block` state) send a one-shot `[shadow]` notification.

**Notifications (Halt & Shadow)**
- D-10: Verified command form: `openclaw message send --channel X --target Y -m "MESSAGE"`.
- D-11: Halt notification fires on transition only.
- D-12: Shadow transition notification fires on first breach only.

**guardrail-check.sh Specifics**
- D-13: `ruleIds` empty or absent → skip guardrail check entirely, exit 0.
- D-14: Atomic write: `guardrail-status.json` written via temp-file-then-rename.
- D-15: Integer ruleId / string-hash ruleId mismatch: join by rule `name` field.

**SKILL.md Rewrite**
- D-16: HALT CHECK section reads `guardrail-status.json` (not `budget-status.json`); uses `haltedRule` block.
- D-17: Setup gate: `ruleIds` absent or empty array → run Setup Flow. Legacy `alertId`-only → also run Setup Flow.
- D-18: Setup Flow delegates to `setup-guardrails.sh --interactive`. SKILL.md does NOT prompt for budget details itself.
- D-19: `/revenium` command shows `ruleIds` and per-rule state; offers `reconfigure` or `done`.

**cron.sh Update**
- D-20: cron.sh pipeline after Phase 3: `report.sh` → `guardrail-check.sh`. `budget-check.sh` is deleted.
- D-21: No migration stage in cron.sh.

**common.sh**
- D-22: `common.sh` contains: path constants (`STATE_DIR`, `CONFIG_FILE`, `GUARDRAIL_STATUS_FILE`, `LOCK_FILE`, `LOG_FILE`), `ensure_path()`, `log()`/`info()`/`warn()`/`error()`, `has_guardrails_cli()` probe, `REVENIUM_AGENT_NAME` default.
- D-23: `REVENIUM_AGENT_NAME` defaults to `"OpenClaw"`.

### Claude's Discretion
- Exact warn threshold computation (Hermes uses 80% of hard limit — same is fine)
- Rule naming convention (use "OpenClaw {Period} Budget")
- Log verbosity level for cron operations
- Whether to include `uninstall-hooks.sh` equivalent (hooks not yet confirmed for OpenClaw)

### Deferred Ideas (OUT OF SCOPE)
- Structural hook enforcement (`pre_llm_call` / `pre_tool_call` equivalent)
- Task-type metering and per-task-type guardrail rules — Phase 4
- Subagent trace correlation — Phase 4
- `hooks-status.sh` equivalent — deferred
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| GUARD-01 | Agent runs guardrail enforcement check before every operation | SKILL.md halt-check section rewrite; guardrail-check.sh cron stage writes guardrail-status.json; skill reads that file |
| GUARD-02 | When guardrail not exceeded, agent proceeds silently | guardrail-status.json `halted: false` → SKILL.md proceeds without user interruption |
| GUARD-03 | When guardrail exceeded, agent warns user with context | haltedRule block in guardrail-status.json carries currentValue, hardLimit, name for the halt message |
| GUARD-04 | When exceeded, agent asks for permission before continuing (interactive) / halts (autonomous) | autonomousMode flag in config.json drives halt vs warn path; `halted: true` produces verbatim halt string |
| GUARD-05 | Warning includes actionable budget status | halt message template uses haltedRule fields: name, metricType, windowType, currentValue, hardLimit |
| GUARD-06 | User can configure grace mode (warn-and-ask vs hard-stop) | autonomousMode field in config.json; setup-guardrails.sh --interactive prompts for autonomous mode |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Guardrail rule state polling | Cron script (guardrail-check.sh) | — | Runs on schedule; never called live from agent session |
| Halt state persistence | guardrail-status.json (file) | — | Written by cron, read by agent — decouples polling from enforcement |
| Agent halt enforcement | SKILL.md (LLM instruction) | BUDGET-GUARD.md (bootstrap) | Primary = skill instructions; bootstrap = defense-in-depth for isolated sessions |
| Rule creation / setup | setup-guardrails.sh (script) | SKILL.md Setup Flow (delegation) | Script owns all prompts and API calls; SKILL.md only delegates to it |
| Notification delivery | guardrail-check.sh (cron stage) | — | Fires on halt/shadow transition; uses openclaw message send |
| Config persistence | config.json (file) | — | Written atomically by setup-guardrails.sh; read by all scripts and SKILL.md |
| Cron orchestration | cron.sh | — | Sequences report.sh → guardrail-check.sh; flock-guarded |

## Standard Stack

This phase is a pure bash/Python3 scripting project. No npm or pip packages are installed.

### Core (already present in the project)

| Component | Version | Purpose | Why Standard |
|-----------|---------|---------|--------------|
| bash | 3.2+ (macOS min) | Script runtime | Already used by all existing scripts; bash 3.2 compatibility required for Mac |
| python3 | system | JSON manipulation, atomic writes, float math | Already used by budget-check.sh; no jq dependency on enforcement path |
| revenium CLI | 1.1.2 (current) | Guardrails API calls | [VERIFIED: brew info revenium/tap/revenium] |
| openclaw CLI | 2026.3.13 (current), 2026.5.28 (target) | Notification delivery | [VERIFIED: npm view openclaw] — upgrade required per D-01 |

### No New Packages

No external packages are installed by this phase. All scripting uses bash builtins, python3 stdlib, and the two CLIs already present.

## Package Legitimacy Audit

No new packages are installed in this phase. The two CLIs in use are pre-existing project dependencies:

| Package | Registry | Age | Source Repo | Disposition |
|---------|----------|-----|-------------|-------------|
| revenium CLI | brew tap (revenium/tap) | Established | github.com/revenium/revenium-cli | Approved — pre-existing |
| openclaw CLI | npm (openclaw) | Established | docs.openclaw.ai | Approved — pre-existing, upgrade gated by D-01 |

**Packages removed due to slopcheck:** none  
**Packages flagged as suspicious:** none

## Architecture Patterns

### System Architecture Diagram

```
[cron tick (every 1 min)]
        |
        v
   cron.sh (flock-guarded)
        |
        |-- run_report() ──> report.sh (metering, unchanged)
        |                        |
        |                    [revenium meter completion]
        |
        └── guardrail-check.sh
                |
                |-- preflight: ruleIds absent? --> exit 0 (silent)
                |-- preflight: has_guardrails_cli()? --> exit 0 warn
                |
                |-- revenium guardrails enforcement-rules get <teamId>
                |-- revenium guardrails budget-rules list
                |
                [Python heredoc: state derivation]
                |-- name-join (enforcement integer IDs → string-hash IDs)
                |-- per-rule state: block / warn / ok
                |-- shadow rules: recorded but excluded from halt decision
                |-- halt transition detection (prev vs new halted)
                |-- shadow transition detection (prev vs new shadow-block)
                |
                |-- atomic write: guardrail-status.json
                |
                |-- HALT_TRANSITION=true?
                |       └── openclaw message send --channel X --target Y -m "MSG"
                |
                └── SHADOW_TRANSITIONS non-empty?
                        └── openclaw message send (per shadow rule, one-shot)

[agent session start / every turn]
        |
        v
   BUDGET-GUARD.md (bootstrap-extra-files injection)
        |-- read guardrail-status.json
        |-- halted=true? --> emit halt string, stop
        |-- else: proceed

   SKILL.md (guardrail check procedure)
        |-- HALT CHECK (defense-in-depth)
        |-- setup gate: ruleIds absent/empty? --> Setup Flow
        |       └── bash setup-guardrails.sh --interactive
        |               |-- prompts: hard-limit, period, org, autonomous, shadow
        |               |-- revenium guardrails budget-rules create (×N)
        |               |-- write ruleIds array to config.json (atomic)
        |               |-- print "Created N rule(s)..."
        |-- /revenium command: show ruleIds + per-rule state, offer reconfigure/done
```

### Recommended Project Structure

```
~/.openclaw/skills/revenium/
├── SKILL.md                          # rewritten (guardrail-native enforcement)
├── BUDGET-GUARD.md                   # content updated (guardrail-status.json reference)
├── scripts/
│   ├── common.sh                     # NEW — shared path constants + helpers
│   ├── setup-guardrails.sh           # NEW — interactive rule creation
│   ├── guardrail-check.sh            # NEW — cron enforcement stage
│   ├── cron.sh                       # UPDATED — remove budget-check.sh, add guardrail-check.sh
│   ├── post-install.sh               # UPDATED — write BUDGET-GUARD.md with new content, chmod new scripts
│   ├── clear-halt.sh                 # UPDATED — target guardrail-status.json, not budget-status.json
│   ├── report.sh                     # unchanged
│   ├── install-cron.sh               # unchanged
│   └── uninstall-cron.sh             # unchanged
│   [DELETE: budget-check.sh]
└── guardrail-status.json             # runtime, written by guardrail-check.sh
```

Runtime state location (OpenClaw pattern, distinct from Hermes):
```
~/.openclaw/skills/revenium/          # STATE_DIR = same as SKILL_DIR for OpenClaw
├── config.json
├── guardrail-status.json
├── revenium-metering.log
└── revenium-metering.lock
```

**Key difference from Hermes:** Hermes separates `~/.hermes/skills/revenium/` (skill content) from `~/.hermes/state/revenium/` (runtime state). OpenClaw collapses both into `~/.openclaw/skills/revenium/`. All path constants in `common.sh` must use the single OpenClaw path.

### Pattern 1: common.sh Path Constants (OpenClaw adaptation)

**What:** Central file defining all path constants so scripts never hardcode paths.  
**When to use:** sourced at the top of every script with `. "${SCRIPT_DIR}/common.sh"`.

```bash
# Source: ../hermes-revenium/skills/revenium/scripts/common.sh (adapted)
#!/usr/bin/env bash
set -uo pipefail

OPENCLAW_HOME="${OPENCLAW_HOME:-${HOME}/.openclaw}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${OPENCLAW_HOME}/skills/revenium"
CONFIG_FILE="${STATE_DIR}/config.json"
GUARDRAIL_STATUS_FILE="${STATE_DIR}/guardrail-status.json"
LOCK_FILE="${STATE_DIR}/revenium-metering.lock"
LOG_FILE="${STATE_DIR}/revenium-metering.log"
REVENIUM_AGENT_NAME="${REVENIUM_AGENT_NAME:-OpenClaw}"

ensure_path() { ... }  # brew prefix detection + PATH extension
log() { ... }          # single-source log writer, TTY-guarded stderr mirror
info()  { log "INFO " "$@"; }
warn()  { log "WARN " "$@"; }
error() { log "ERROR" "$@"; }

has_guardrails_cli() {
  revenium guardrails budget-rules --help >/dev/null 2>&1 && \
  revenium guardrails enforcement-events --help >/dev/null 2>&1
}
```

**OPENCLAW_HOME discovery:** The existing scripts (budget-check.sh, cron.sh) already implement a multi-candidate OPENCLAW_HOME probe (HOME/.openclaw, /home/ubuntu/.openclaw — checks for agents/ subdirectory). common.sh MUST replicate this probe, not just fall back to `${HOME}/.openclaw`, so sandbox environments work correctly.

### Pattern 2: ruleIds Silent-Exit Guard (D-13)

**What:** guardrail-check.sh exits 0 silently when `ruleIds` is absent or empty — handles both legacy alertId-only installs and pre-setup states.

```bash
# Source: D-13 decision + Hermes guardrail-check.sh pattern
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
  # D-13: no ruleIds — legacy install or pre-setup. Exit silently.
  exit 0
fi
```

### Pattern 3: Name-Join for Integer/String-Hash ruleId Reconciliation (D-15)

**What:** The enforcement-rules API returns integer `ruleId` values; budget-rules list returns string-hash IDs. The only stable join key is the `name` field.

```python
# Source: ../hermes-revenium/skills/revenium/scripts/guardrail-check.sh (verbatim logic)
name_to_string_id = {}
try:
    br_data = json.loads(budget_rules_json)
    if isinstance(br_data, list):
        for br in br_data:
            n = br.get('name')
            sid = br.get('id')   # string-hash ID matching config.json::ruleIds
            if n and sid:
                name_to_string_id[n] = sid
except Exception:
    pass

# In the per-rule loop:
resolved_rule_id = name_to_string_id.get(rule_name)
if not resolved_rule_id:
    resolved_rule_id = str(r.get('ruleId', '')) if r.get('ruleId') is not None else ''
```

### Pattern 4: Atomic Write for guardrail-status.json (D-14)

**What:** Write to a temp file in the same directory, then `os.replace()` (atomic rename). Prevents partial reads by the agent.

```python
# Source: ../hermes-revenium/skills/revenium/scripts/guardrail-check.sh
import tempfile
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

### Pattern 5: OpenClaw Notification Command (D-10)

**What:** Replace Hermes `hermes chat --toolsets messaging` with the verified OpenClaw command.

```bash
# Source: [VERIFIED: openclaw message send --help, 2026.3.13]
# D-10: verified flag form — -m is the short form for --message
openclaw message send \
  --channel "${NOTIFY_CHANNEL}" \
  --target "${NOTIFY_TARGET}" \
  -m "${MSG}"
```

**CRITICAL POST-UPGRADE CHECK:** After upgrading to 2026.5.28, re-run `openclaw message send --help` and confirm:
- `--channel` flag still exists (present in 2026.3.13)
- `-m` / `--message` still exists (present in 2026.3.13)
- `--target` flag still exists (present in 2026.3.13)

The 2026.3.13 help output shows `-m, --message <text>` as the message flag. Do NOT use `--message` in cron scripts without confirming it is still available in 2026.5.28.

### Pattern 6: guardrail-status.json Schema (ENF-04)

The canonical schema written by guardrail-check.sh and read by SKILL.md and BUDGET-GUARD.md:

```json
{
  "halted": false,
  "autonomousMode": true,
  "lastChecked": "2026-05-31T12:00:00.000000+00:00",
  "haltedAt": "2026-05-31T11:55:00.000000+00:00",
  "haltedRule": {
    "ruleId": "d5jng5",
    "name": "OpenClaw Daily Budget",
    "metricType": "TOTAL_COST",
    "windowType": "DAILY",
    "currentValue": 5.12,
    "hardLimit": 5.00
  },
  "rules": [
    {
      "ruleId": "d5jng5",
      "name": "OpenClaw Daily Budget",
      "metricType": "TOTAL_COST",
      "windowType": "DAILY",
      "groupBy": "AGENT",
      "currentValue": 5.12,
      "warnThreshold": 4.00,
      "hardLimit": 5.00,
      "state": "block",
      "shadowMode": false,
      "lastChecked": "2026-05-31T12:00:00.000000+00:00"
    }
  ]
}
```

`haltedAt` and `haltedRule` are only present when `halted: true`.

### Pattern 7: Halt Message Template (SKILL.md and cron notification)

```
Guardrail halt active — rule '{haltedRule.name}' ({haltedRule.metricType}, {haltedRule.windowType}) at {haltedRule.currentValue} of {haltedRule.hardLimit} hard-limit. To resume: `bash ~/.openclaw/skills/revenium/scripts/clear-halt.sh`
```

Used in:
1. SKILL.md HALT CHECK section (agent emits this verbatim)
2. guardrail-check.sh notification message (appends enforcement event data)

### Pattern 8: Flock Acquisition (Python-based, bash 3.2 safe)

The existing cron.sh uses `flock -n 9` (bash flock builtin). The Hermes setup-guardrails.sh uses a Python-based flock for the RULES_LOCK_FILE. The OpenClaw port may use either approach — but MUST use the same style as the surrounding codebase. Since cron.sh already uses bash `flock -n 9`, prefer that for cron.sh itself. setup-guardrails.sh may use Python flock (from Hermes).

### Anti-Patterns to Avoid

- **Calling the Revenium API from SKILL.md:** SKILL.md reads the local `guardrail-status.json` file only. It NEVER calls `revenium guardrails enforcement-rules get` directly.
- **Using `jq` in enforcement-path scripts:** The project explicitly avoids jq on the enforcement path (see budget-check.sh: "Python3 used for all JSON manipulation (no jq dependency on the enforcement path)"). All JSON work goes through Python3.
- **Blocking cron on guardrail check failure:** Every failure path in guardrail-check.sh MUST `exit 0`. Cron must not emit error emails.
- **Writing notification in a loop while halted:** Notification fires on transition only (D-11). The script checks `HALT_TRANSITION=true`, not `halted=true`.
- **Including migration mode in setup-guardrails.sh:** The `--from-alert --auto` mode from Hermes is NOT ported (D-02). Removing it means the three-state mode dispatch simplifies to: `default | interactive`.
- **Leaving budget-check.sh:** It must be deleted after guardrail-check.sh is in place (D-20).
- **Using `--output json` instead of `--json` flag in enforcement-rules get:** The revenium CLI uses `--output json` (global flag, not `--json`) for guardrails commands. [VERIFIED: revenium guardrails --help]

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Atomic file writes | Manual file + mv | Python `tempfile.mkstemp` + `os.replace()` | fsync + same-dir rename is POSIX atomic; `mv` across filesystems is not |
| JSON parsing in bash | `grep`, `sed`, `awk` on JSON | `python3 -c "import json..."` | Handles nested structures, unicode, float precision; established project pattern |
| Float percentage math | String arithmetic | Python3 float math | Precision; already used in budget-check.sh |
| Rule name join | Integer ID assumptions | Name-field join (D-15 pattern) | Enforcement API returns integer IDs; budget-rules list returns string-hash IDs |

## Runtime State Inventory

This phase does not rename existing identifiers — it replaces files. The relevant state changes are:

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | `~/.openclaw/skills/revenium/budget-status.json` — written by budget-check.sh; read by SKILL.md and clear-halt.sh | New file: `guardrail-status.json` replaces it. Hermes cleans up budget-status.json in guardrail-check.sh (post-atomic-write). OpenClaw should do the same: if `budget-status.json` exists after first successful guardrail-check.sh run, delete it. |
| Live service config | `~/.openclaw/openclaw.json` bootstrap-extra-files entry — already set to `["BUDGET-GUARD.md"]` by post-install.sh | No config change needed (D-05, D-06); post-install.sh updates the file content only |
| OS-registered state | crontab entry — `bash ~/.openclaw/skills/revenium/scripts/cron.sh` | No change to cron entry; cron.sh is updated in-place |
| Secrets/env vars | `REVENIUM_AGENT_NAME` — new env var override point added in common.sh | No action; defaults to "OpenClaw"; can be overridden by operator |
| Build artifacts | `scripts/budget-check.sh` — to be deleted | Delete after guardrail-check.sh is in place; post-install.sh must stop referencing it |

**post-install.sh changes required:**
1. Remove `budget-check.sh` from the `chmod +x` loop (line 114)
2. Add `setup-guardrails.sh` and `guardrail-check.sh` to the `chmod +x` loop
3. Update the "Seed initial budget-status.json" step (step 5): seed `guardrail-status.json` with `{"halted": false}` placeholder instead of calling budget-check.sh
4. Update BUDGET-GUARD.md content write (step 8): write new guardrail-status.json-referencing content

## Common Pitfalls

### Pitfall 1: OPENCLAW_HOME Multi-Candidate Discovery Omitted from common.sh
**What goes wrong:** common.sh falls back to `${HOME}/.openclaw` without trying the sandbox path `/home/ubuntu/.openclaw`. Scripts sourcing common.sh silently use the wrong HOME.
**Why it happens:** The Hermes common.sh uses `HERMES_HOME` without a multi-candidate probe. The OpenClaw probe (already in budget-check.sh and cron.sh) checks whether `${candidate}/agents` exists.
**How to avoid:** Copy the multi-candidate probe block from cron.sh into common.sh verbatim; use `OPENCLAW_HOME` (not `HERMES_HOME`) as the env override name.
**Warning signs:** `guardrail-check.sh` logs "No config.json found" on first run despite config.json existing at `~/.openclaw/skills/revenium/config.json`.

### Pitfall 2: `--output json` vs `--json` Flag Confusion
**What goes wrong:** Using `--json` (the global flag) instead of `--output json` on guardrails subcommands — or vice versa.
**Why it happens:** The existing budget-check.sh uses `revenium alerts budget get "${ALERT_ID}" --json`. Guardrails subcommands use the `--output json` global flag.
**How to avoid:** [VERIFIED from CLI help] Use `--output json` for all `revenium guardrails` commands. The Hermes scripts use `--output json`.
**Warning signs:** Script gets table-formatted output instead of JSON; Python JSON parse fails.

### Pitfall 3: `openclaw message send` Flag Drift After 2026.5.28 Upgrade
**What goes wrong:** The notification command fails silently or with an unrecognized flag error if the 2026.5.28 version changed flag names.
**Why it happens:** D-01 requires upgrading before scripting, but the upgrade was not done at research time. The 2026.3.13 help is captured as a baseline but 2026.5.28 may differ.
**How to avoid:** After upgrading, run `openclaw message send --help` and confirm `--channel`, `--target`, `-m` still exist. Adjust scripts if any flag renamed.
**Warning signs:** `unknown flag: --channel` in cron logs.

### Pitfall 4: Notification in Shadow Path Uses Wrong Comparison
**What goes wrong:** Shadow rule notification fires on every cron tick where the rule is in `block` state instead of only on first breach.
**Why it happens:** The `prev_rules_by_id` lookup in the Python heredoc compares against the previous `guardrail-status.json` — but if the file does not exist yet (first run), `prev` is `{}` and the guard treats every rule as a new transition.
**How to avoid:** The Hermes guard already handles this: `(pr is None) or (pr.get('state') != 'block')`. On first run, `pr is None` → fires the notification once. On subsequent runs, `pr.get('state') == 'block'` → suppressed. This is correct behavior.
**Warning signs:** Multiple `[shadow]` notifications in the same cron period.

### Pitfall 5: setup-guardrails.sh Missing Bash 3.2 Compatibility
**What goes wrong:** Script uses bash 4.4+ features (e.g. `${var@Q}`, `declare -A`, `<<<` in compound subshells) that fail on macOS default bash 3.2.
**Why it happens:** Hermes scripts are annotated "Bash 3.2 compatible" but the annotation requires active maintenance.
**How to avoid:** The Hermes script uses the env-passing heredoc pattern for all Python calls (env vars passed via `KEY=value python3 - <<'PY'`). Port this pattern verbatim. Avoid `declare -A` (associative arrays), `${var,,}` (lowercase), and `<<<` heredoc strings inside subshells.
**Warning signs:** `syntax error near unexpected token` on macOS during interactive setup.

### Pitfall 6: `ruleIds` Silent-Exit vs `alertId` Warning
**What goes wrong:** guardrail-check.sh emits a `warn` log line when seeing an alertId-only install, causing cron log noise (violates D-03).
**Why it happens:** Developers add a warning to aid debugging, forgetting D-03 specifies "no warning line, no cron log noise."
**How to avoid:** The ruleIds guard must be a bare `exit 0` with no log output at all. The check precedes all log-emitting code.

### Pitfall 7: delete budget-check.sh Before Verifying cron.sh and post-install.sh Are Updated
**What goes wrong:** cron.sh or post-install.sh still reference `budget-check.sh` by name after it is deleted, causing cron errors.
**How to avoid:** Update cron.sh and post-install.sh BEFORE deleting budget-check.sh. Verify with `grep -r budget-check.sh scripts/` after deletion — expect no hits.

### Pitfall 8: clear-halt.sh Targets Wrong File
**What goes wrong:** clear-halt.sh still writes to `budget-status.json` instead of `guardrail-status.json`.
**Why it happens:** Phase 3 updates clear-halt.sh content but forgets to update the target file variable.
**How to avoid:** clear-halt.sh after the update must reference `GUARDRAIL_STATUS_FILE` (from common.sh, or inline as `${HOME}/.openclaw/skills/revenium/guardrail-status.json`). The new logic: write `{"halted": false}` merge into `guardrail-status.json`, leaving all other fields intact (especially `rules[]`).

## Code Examples

### budget-rules create call (verified flag form)
```bash
# Source: [VERIFIED: revenium guardrails budget-rules create --help]
revenium guardrails budget-rules create \
  --output json \
  --name "OpenClaw Daily Budget" \
  --description "" \
  --metric-type TOTAL_COST \
  --window-type DAILY \
  --action BLOCK \
  --group-by AGENT \
  --warn-threshold 4.00 \
  --hard-limit 5.00 \
  --filter "AGENT:IS:OpenClaw"
  # add --shadow-mode for shadow rules
```

### enforcement-rules get (verified flag form)
```bash
# Source: [VERIFIED: revenium guardrails enforcement-rules --help]
ENFORCEMENT_JSON=$(revenium guardrails enforcement-rules get "${TEAM_ID}" --output json 2>&1) || true
```

### enforcement-events list (verified flag form)
```bash
# Source: [VERIFIED: revenium guardrails enforcement-events list --help]
EVENT_JSON=$(revenium guardrails enforcement-events list \
  --rule-id "${HALTED_RULE_ID}" --page-size 1 --output json 2>/dev/null || echo '__FAIL__')
```

### budget-rules list (verified flag form)
```bash
# Source: [VERIFIED: revenium guardrails budget-rules --help]
BUDGET_RULES_JSON=$(revenium guardrails budget-rules list --output json 2>/dev/null || echo '[]')
```

### has_guardrails_cli probe
```bash
# Source: ../hermes-revenium/skills/revenium/scripts/common.sh (adapted)
# [VERIFIED: both subcommands exist in revenium 1.1.2 CLI]
has_guardrails_cli() {
  revenium guardrails budget-rules --help >/dev/null 2>&1 && \
  revenium guardrails enforcement-events --help >/dev/null 2>&1
}
```

### config.json ruleIds write (atomic, Python)
```python
# Source: ../hermes-revenium/skills/revenium/scripts/setup-guardrails.sh write_rule_ids_and_config()
import json, os, tempfile
from pathlib import Path

config_path = Path(os.environ['CONFIG_FILE'])
new_rule_ids = json.loads(os.environ['NEW_RULE_IDS_JSON'])

try:
    config = json.loads(config_path.read_text())
except Exception:
    config = {}

config['ruleIds'] = new_rule_ids
# Never strip alertId — D-04: leave as orphan

tmp_dir = config_path.parent
with tempfile.NamedTemporaryFile('w', dir=tmp_dir, delete=False, suffix='.tmp') as tmp:
    json.dump(config, tmp, indent=2)
    tmp.write('\n')
    tmp.flush()
    os.fsync(tmp.fileno())
    tmp_name = tmp.name

os.rename(tmp_name, str(config_path))
```

### cron.sh pipeline (after Phase 3)
```bash
# Source: cron.sh adapted per D-20
LOCK_FILE="${OPENCLAW_HOME}/revenium-metering.lock"
(
  flock -n 9 || exit 0
  run_report "$@" || true
  bash "${SKILL_DIR}/scripts/guardrail-check.sh" || true
) 9>"${LOCK_FILE}"
```

**NOTE on ordering:** The existing cron.sh runs budget-check.sh FIRST (before report.sh) to ensure halt state is always fresh. After Phase 3, the ordering is REVERSED — report.sh runs first (ships metering data), then guardrail-check.sh reads the updated enforcement state. This matches the Hermes cron.sh ordering where metering ships before the guardrail check reads consequences.

### SKILL.md Setup Gate (D-17)
```
At the start of any operation, check: does `~/.openclaw/skills/revenium/config.json` exist AND contain a non-empty `ruleIds` array (present and not `[]`)?

- **If YES** and the user has NOT requested reconfiguration: setup is complete. Proceed to the guardrail check.
- **If NO** (file missing, or `ruleIds` absent, or `ruleIds` is `[]`): run the Setup Flow below. Note: a legacy `alertId`-only config.json also triggers the Setup Flow — `alertId` is ignored for the setup gate; `ruleIds` is the sole signal.
```

### BUDGET-GUARD.md (new content per D-07)
```markdown
## Guardrail Enforcement (Mandatory)

BEFORE EVERY RESPONSE — read `~/.openclaw/skills/revenium/guardrail-status.json`.

- **File missing:** Proceed with caution.
- **`halted` is `false`:** Proceed silently.
- **`halted` is `true`:** YOUR ENTIRE RESPONSE MUST BE EXACTLY this halt message from `~/.openclaw/skills/revenium/SKILL.md` (HALT CHECK section) — substitute values from the `haltedRule` block in guardrail-status.json. Do NOT continue.

No operation is exempt.
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Poll `revenium alerts budget get` → budget-status.json | Poll `revenium guardrails enforcement-rules get` → guardrail-status.json | Phase 3 | Per-rule state, shadow mode, rule name in halt message |
| Single `exceeded`/`threshold` fields in status | `rules[]` array with per-rule `state`, `shadowMode` | Phase 3 | Dashboard visibility for shadow rules without halting |
| alertId string in config.json | ruleIds array in config.json | Phase 3 | Supports multiple rules; joins on name field |
| budget-check.sh deleted | guardrail-check.sh replaces it | Phase 3 | Different API, different schema, different halt logic |

**Deprecated/outdated:**
- `budget-status.json`: deprecated; deleted by guardrail-check.sh on first successful write
- `alertId` field in config.json: deprecated; left as orphan (D-04); ignored by SKILL.md and guardrail-check.sh
- `budget-check.sh`: deleted in Phase 3

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| python3 | All scripts (JSON manipulation) | ✓ | system | None — hard requirement |
| revenium CLI | guardrail-check.sh, setup-guardrails.sh | ✓ | 1.1.2 | fail-open exit 0 (has_guardrails_cli probe) |
| openclaw CLI | guardrail-check.sh (notifications) | ✓ | 2026.3.13 (upgrade needed) | warn log if not found |
| bash 3.2+ | All scripts | ✓ | macOS built-in | N/A |
| flock | cron.sh (already in use) | ✓ | macOS built-in | N/A |

**Missing dependencies with no fallback:** none  
**Missing dependencies with fallback:**
- openclaw 2026.5.28: currently 2026.3.13. Scripts include `command -v openclaw >/dev/null 2>&1` guard; notification skipped with warn log if CLI missing/fails. Upgrade must happen before authoring per D-01.

**OpenClaw upgrade path (D-01):**
```bash
npm update -g openclaw
# or, if installed differently:
npm install -g openclaw@latest
```
[VERIFIED: npm view openclaw version returns 2026.5.28]

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | None — scripts are tested by running them directly with preconditioned state |
| Config file | none |
| Quick run command | `bash ~/.openclaw/skills/revenium/scripts/guardrail-check.sh` |
| Full suite command | Manual end-to-end (run cron.sh, check guardrail-status.json, verify SKILL.md halt behavior) |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| GUARD-01 | guardrail-check.sh runs and writes guardrail-status.json | smoke | `bash ~/.openclaw/skills/revenium/scripts/guardrail-check.sh && cat ~/.openclaw/skills/revenium/guardrail-status.json` | ❌ Wave 0 |
| GUARD-02 | No output when not exceeded | smoke | verify `halted: false` in guardrail-status.json | ❌ Wave 0 |
| GUARD-03 | halt message contains rule name + values | manual | Manually trip a rule (or mock with a pre-staged guardrail-status.json) and start an agent session | manual-only |
| GUARD-04 | autonomousMode=true produces halt, false produces warn-and-ask | manual | Requires live Revenium rule breach | manual-only |
| GUARD-05 | halt message contains currentValue and hardLimit | manual | Inspect halt message format in agent session | manual-only |
| GUARD-06 | autonomousMode prompt in setup-guardrails.sh --interactive | smoke | `bash ~/.openclaw/skills/revenium/scripts/setup-guardrails.sh --interactive` (needs live Revenium credentials) | ❌ Wave 0 |

### Sampling Rate
- Per task commit: `cat ~/.openclaw/skills/revenium/guardrail-status.json` — verify file is written and `halted` field is present
- Per wave merge: `bash ~/.openclaw/skills/revenium/scripts/cron.sh` — full cron pipeline run
- Phase gate: manual agent session test with a staged `guardrail-status.json` containing `halted: true`

### Wave 0 Gaps
- [ ] Staged `guardrail-status.json` fixtures for testing SKILL.md halt behavior without live Revenium rule breach
- [ ] `scripts/guardrail-check.sh` — must exist and be executable before any cron test
- [ ] `scripts/setup-guardrails.sh` — must exist and be executable before any interactive test
- [ ] `scripts/common.sh` — must exist before any sourcing script is tested

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | N/A — skill reads local files only |
| V3 Session Management | no | N/A |
| V4 Access Control | yes (minimal) | File permissions on guardrail-status.json and config.json; scripts run as current user only |
| V5 Input Validation | yes | validate_hard_limit() and validate_period() in setup-guardrails.sh; bounds-check user input before passing to CLI |
| V6 Cryptography | no | API key managed by revenium CLI, not this skill |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Log injection via rule name field | Tampering | Hermes applies 64-char truncation on rule name before logging: `name = (match.get('name') or '')[:64]`. Port this to guardrail-check.sh and setup-guardrails.sh. |
| Notification message injection via rule name | Tampering | Rule name is embedded in notification MSG string. Since name comes from Revenium API (not user input to this script), risk is low. Use f-string construction (not shell expansion) for MSG in Python, or quote carefully in bash. |
| Partial config.json reads during atomic write | Tampering | Atomic write pattern (Pattern 4 above) prevents this. Never write config.json without temp-file-then-rename. |

## Open Questions (RESOLVED)

1. **openclaw message send flag stability post-2026.5.28 upgrade**
   - What we know: 2026.3.13 has `--channel`, `--target`, `-m` flags
   - What's unclear: whether 2026.5.28 changed any flag names (the app and CLI are versioned together)
   - Recommendation: First task in Wave 1 must be the upgrade and re-verification before any script is authored
   - **RESOLVED:** Delegated to Plan 01 Task 1 (blocking `checkpoint:human-verify` gate). Executor must confirm flag names post-upgrade before any script is authored.

2. **revenium config show teamId parsing**
   - What we know: Hermes guardrail-check.sh parses `TEAM_ID` via `revenium config show 2>&1 | sed -n 's/.*Team ID:[ \t]*//p'`
   - What's unclear: whether revenium 1.1.2 `config show` output format matches this sed expression
   - Recommendation: Run `revenium config show` on the live machine post-upgrade and confirm the "Team ID:" label is present
   - **RESOLVED:** Delegated to Plan 01 Task 1 checkpoint. Executor verifies `revenium config show` output format at execution time.

3. **SKILL.md Setup Flow interaction model for Phase 3**
   - What we know: D-18 says SKILL.md delegates entirely to `setup-guardrails.sh --interactive`; the script owns all prompts and the config.json write
   - What's unclear: Whether the existing SKILL.md setup flow sections (steps 1-14) are fully replaced, or only the budget-creation steps (steps 3-13) are replaced
   - Recommendation: The Hermes SKILL.md Setup Flow section (3 steps: verify CLI, configure credentials if needed, run setup-guardrails.sh --interactive) is the target. The full OpenClaw Setup Flow from Phase 2 (14 steps) collapses to 3 equivalent steps in Phase 3.
   - **RESOLVED:** Full Phase 2 Setup Flow (14 steps) collapses to 3 steps per the Hermes model. Plan 05 Task 1 implements this directly.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | cron.sh ordering change: report.sh runs BEFORE guardrail-check.sh (reversed from current order) | Architecture Patterns, cron.sh pipeline example | If wrong, halt state is one tick stale (acceptable per existing codebase comment) but ordering may violate cron.sh comments |
| A2 | `revenium config show` output contains "Team ID:" label parseable by sed (Hermes pattern) | Open Questions | guardrail-check.sh fails to resolve teamId; exits 0 with warn on every tick |
| A3 | `BUDGET-GUARD.md` content update is sufficient without a filename change (D-05 confirmed) | User Constraints | No risk — this is a locked decision |

**If this table is empty:** N/A — A1 and A2 require verification at execution time.

## Sources

### Primary (HIGH confidence)
- `../hermes-revenium/skills/revenium/scripts/common.sh` — canonical common helpers, read in full
- `../hermes-revenium/skills/revenium/scripts/setup-guardrails.sh` — canonical setup-guardrails implementation, read in full
- `../hermes-revenium/skills/revenium/scripts/guardrail-check.sh` — canonical guardrail-check implementation, read in full
- `../hermes-revenium/skills/revenium/SKILL.md` — canonical SKILL.md structure for guardrail sections, read in full
- `revenium guardrails budget-rules create --help` [VERIFIED: run 2026-05-31, revenium 1.1.2]
- `revenium guardrails enforcement-rules --help` [VERIFIED: run 2026-05-31, revenium 1.1.2]
- `revenium guardrails enforcement-events list --help` [VERIFIED: run 2026-05-31, revenium 1.1.2]
- `openclaw message send --help` [VERIFIED: run 2026-05-31, openclaw 2026.3.13]
- `npm view openclaw version` → 2026.5.28 [VERIFIED: run 2026-05-31]

### Secondary (MEDIUM confidence)
- `.planning/phases/03-guardrail-engine/03-CONTEXT.md` — user decisions (all implementation decisions confirmed as locked)
- `scripts/budget-check.sh`, `scripts/cron.sh`, `scripts/post-install.sh`, `scripts/clear-halt.sh` — current OpenClaw scripts, read in full for adaptation context

### Tertiary (LOW confidence)
- None

## Metadata

**Confidence breakdown:**
- Script porting patterns: HIGH — canonical source scripts read in full; verified against live CLI
- CLI flag forms: HIGH — all flags verified via `--help` on installed CLI versions
- OpenClaw 2026.5.28 flag stability: MEDIUM — 2026.3.13 baseline captured; 2026.5.28 not yet installed
- cron.sh ordering decision: MEDIUM — inferred from Hermes pattern; confirmed by code comment in existing cron.sh

**Research date:** 2026-05-31
**Valid until:** 2026-06-30 (revenium CLI and openclaw CLI are stable within this window; re-verify if either updates beyond 2026.5.28 / 1.1.2)
