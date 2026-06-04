# Phase 9: Guardrail Event Metering - Research

**Researched:** 2026-06-03
**Domain:** Shell + Python enforcement scripting, Revenium CLI metering, ledger-based idempotency
**Confidence:** HIGH (all findings extracted directly from canonical source files in the repo)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Warn = soft warn-threshold signal — rule whose per-rule `state` becomes `'warn'`
  (`currentValue >= warnThreshold` but `< hardLimit`). Fires in both autonomous and
  non-autonomous mode.
- **D-02:** Top-level non-autonomous `warned` field (hardLimit breached, autonomousMode off →
  warn-and-ask) is NOT metered as a guardrail transaction in this phase (deferred).
- **D-03:** Warn-onset transition detection MUST BE ADDED to guardrail-check.sh — mirror the
  existing `shadow_transitions` prev-vs-now comparison.
- **D-04:** Three GUARDRAIL transactions distinguished by `--task-type`:
  - halt → `budget_guardrail_halt`
  - warn → `budget_guardrail_warn`
  - shadow → `budget_guardrail_shadow`
- **D-05:** Mechanism = `revenium meter completion --operation-type GUARDRAIL` (zero tokens),
  `--stop-reason COST_LIMIT`.
- **D-06:** Emit meter calls directly from `guardrail-check.sh` (not report.sh).
- **D-07:** Attribution: `--agent openclaw-<root_session_id>` of the most-recent active root
  session (newest non-cron session file in `SESSIONS_DIR`, resolved to root via
  `get-root-session-id.py`); `--agentic-job-id` of the most-recently-opened open job from the
  jobs ledger.
- **D-08:** If no job is open at event time: omit `--agentic-job-id` (still attach `--agent`).
  If multiple jobs open: use the most-recently-opened one.
- **D-09:** Model/provider = descriptive constants (e.g. `--provider revenium --model
  guardrail-enforcement`). Zero tokens, zero cost. Exact strings are Claude's discretion.
- **D-10:** Primary dedup = state-transition detection (only onset edge fires). Secondary
  backstop = new ledger `revenium-guardrail.ledger` keyed per
  `GUARDRAIL:<type>:<ruleId>:<onset-marker>`.
- **D-11:** All metering is best-effort and MUST NOT change guardrail-check.sh's exit-0
  fail-open posture. Metering runs AFTER status-file write AND notifications.
- **D-12:** Remove the dead operation-type GUARDRAIL branch in `report.sh` (~line 849).

### Claude's Discretion

- Exact constant strings for `--model`/`--provider` (D-09)
- Precise ledger onset-marker format for warn/shadow (D-10)
- `--request-duration`/timestamp values for the synthetic completion
- Whether warn/shadow attribution reuses the exact same lookup helper as halt (recommendation:
  yes — one shared `_emit_guardrail_event` shell function)

### Deferred Ideas (OUT OF SCOPE)

- Non-autonomous hard-block ("warned") transactions (D-02)
- Per-tick guardrail API-poll overhead metering (GRDEV-F1)
- One-per-open-job guardrail events (rejected for v1.2)
- Tool registry + tool-event metering (Phase 10)
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| GRDEV-01 | Halt transition emits exactly one GUARDRAIL transaction (`budget_guardrail_halt`, zero-token, `--stop-reason COST_LIMIT`), deduped via ledger | Section: "Halt emission" in Architecture Patterns |
| GRDEV-02 | Warn transition emits exactly one GUARDRAIL transaction (`budget_guardrail_warn`), transition-gated once per warn onset | Section: "Warn-onset detection" in Architecture Patterns |
| GRDEV-03 | Shadow-mode would-have-halted transition emits exactly one GUARDRAIL transaction (`budget_guardrail_shadow`) | Existing `shadow_transitions` detection is the direct template |
| GRDEV-04 | Each guardrail transaction attributed to agent (root session) and open `--agentic-job-id` when present | Section: "Attribution lookup" in Architecture Patterns |
| GRDEV-05 | Guardrail-event metering is fully fail-open — no metering error blocks enforcement or cron tick | Section: "Fail-open sequencing" in Architecture Patterns |
| GRDEV-06 | Dead GUARDRAIL heuristic removed from `report.sh` (~line 849) | Section: "D-12 removal" in Architecture Patterns |
</phase_requirements>

---

## Summary

Phase 9 adds guardrail-event metering to `guardrail-check.sh`, emitting a synthetic
`revenium meter completion --operation-type GUARDRAIL` call for each halt, warn-onset, and
shadow-onset transition. All machinery needed — transition detection, attribution lookup,
and ledger dedup — can be built by directly adapting patterns already present in the repo.

The scope is narrow: one new Python detection block inside the existing Python heredoc (warn
detection mirrors `shadow_transitions`); one new bash function `_emit_guardrail_event` in
the bash tail (mirrors `post_to_revenium` argv-array discipline from report.sh); a new
ledger file (`revenium-guardrail.ledger`) defined in `common.sh`; and a two-line deletion
in `report.sh` (~lines 849-851). No new dependencies, no external APIs beyond what already
exist.

There are **zero existing hermetic tests** for `guardrail-check.sh`. The plan must include a
`tests/test_guardrail_argv.sh` (new file) following the `test_report_argv.sh` structure.

**Primary recommendation:** Implement as one wave with three tasks: (1) extend Python block
+ add warn-onset emit lines, (2) add `_emit_guardrail_event` bash function + emit calls after
notifications, (3) D-12 removal in report.sh + new test file.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Warn-onset detection | guardrail-check.sh (Python block) | — | Transition state lives in the Python block; mirrors shadow_transitions pattern already there |
| Halt/warn/shadow meter emission | guardrail-check.sh (bash tail) | — | D-06 locks this to guardrail-check.sh, not report.sh |
| Attribution lookup (root session, open job) | guardrail-check.sh (bash tail) | common.sh (SESSIONS_DIR, get_root_session_id) | All path constants and session resolver are already in common.sh/get-root-session-id.py |
| Ledger dedup | guardrail-check.sh (bash tail) | common.sh (GUARDRAIL_LEDGER_FILE constant) | Pattern mirrors existing JOB:halt:<haltedAt> gate in report.sh handle_halt |
| D-12 GUARDRAIL heuristic removal | report.sh | — | The only change to report.sh; removes a 3-line branch |

---

## Standard Stack

No new external packages. All tools already in use:

| Tool/Script | Version | Purpose | Status |
|-------------|---------|---------|--------|
| `revenium` CLI | existing | `meter completion` invocation | Already on PATH via ensure_path |
| `python3` | existing | State transitions, JSON parsing, ledger logic | Already guarded in preflights |
| `get-root-session-id.py` | existing | Root session resolution | Already in `SKILL_DIR/scripts/` |
| `common.sh` | existing | Path constants, `get_root_session_id` wrapper | Sourced by guardrail-check.sh |

**Installation:** None required. No new packages.

---

## Package Legitimacy Audit

Not applicable — no new packages are installed in this phase.

---

## Architecture Patterns

### Q1: Warn-onset Detection — Exact Code Shape

The existing `shadow_transitions` detection block (guardrail-check.sh lines 268–287) is the
direct template. Here is the exact shape:

```python
# EXISTING: Shadow-mode transition detection (lines 268–287)
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
            shadow_transitions.append({...})
```

**Warn-onset detection uses the exact same shape**, substituting:
- condition: `nr.get('state') == 'warn'` (and NOT shadowMode — warn means warnBreached but not breached)
- transition guard: `(pr is None) or (pr.get('state') != 'warn')`

```python
# NEW: Warn-onset transition detection (add after shadow_transitions block)
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

**Prev-rule reconstruction:** `prev_rules_by_id` is built from `prev.get('rules', [])` where
`prev` = the prior `guardrail-status.json` loaded at line 199–202. This means:
- First cron tick after install: `prev == {}`, `prev_rules_by_id == {}`, pr will always be
  `None`, so first tick fires for every rule currently in warn/shadow/halt state.
- Warn→ok→warn re-fire: when a rule recovers to `state='ok'` on one tick and then returns to
  `state='warn'` on a later tick, the previous state stored in `guardrail-status.json` will
  be `'ok'`, so `pr.get('state') != 'warn'` is true → re-fires correctly.

**Python emit line (mirrors HALT_TRANSITION / SHADOW_TRANSITIONS):**

```python
# After shadow_transitions and warn_transitions blocks, add:
print(f"WARN_TRANSITIONS={json.dumps(warn_transitions)}")
```

`SHADOW_TRANSITIONS` is already always emitted (even as `[]`). `WARN_TRANSITIONS` should
follow the same pattern so bash sed extraction is deterministic.

**Important:** `prev_rules_by_id` is already built for shadow detection. The warn detection
block reuses it — no second construction needed.

---

### Q2: `revenium meter completion` — Exact Flag Set

From `post_to_revenium` in report.sh (lines 240–316), the canonical argv-array discipline:

```bash
# Canonical pattern (report.sh lines 240–316)
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
  --task-type "${task_type}"
  --transaction-id "${transaction_id}"
  --operation-type "${operation_type}"
  --quiet
)
# Optional (conditional):
# --trace-id, --model-source, --is-streamed, --organization-name,
# --system-prompt, --input-messages, --output-response
# --agentic-job-id, --agentic-job-name, --agentic-job-type (when JOBS_CLI_CAPABLE)
```

**For the synthetic GUARDRAIL event, the minimal required flag set is:**

```bash
_emit_guardrail_event() {
  local event_type="$1"   # budget_guardrail_halt | budget_guardrail_warn | budget_guardrail_shadow
  local rule_id="$2"
  local onset_marker="$3" # for ledger dedup
  local agent_val="$4"    # "openclaw-<root_sid>"
  local job_id="$5"       # may be empty

  local now
  now=$(python3 -c "from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat())" 2>/dev/null \
        || date -u +%Y-%m-%dT%H:%M:%SZ)

  # Ledger dedup gate (D-10 secondary backstop)
  local ledger_key="GUARDRAIL:${event_type}:${rule_id}:${onset_marker}"
  if grep -qF "${ledger_key}" "${GUARDRAIL_LEDGER_FILE}" 2>/dev/null; then
    return 0   # already emitted this onset
  fi

  local cmd=(
    revenium meter completion
    --model "guardrail-enforcement"
    --provider "revenium"
    --input-tokens 0
    --output-tokens 0
    --total-tokens 0
    --cache-read-tokens 0
    --cache-creation-tokens 0
    --stop-reason "COST_LIMIT"
    --request-time "${now}"
    --completion-start-time "${now}"
    --response-time "${now}"
    --request-duration 0
    --agent "${agent_val}"
    --task-type "${event_type}"
    --operation-type "GUARDRAIL"
    --quiet
  )
  # Agentic job attribution (D-08): only when job_id non-empty
  if [[ -n "${job_id}" ]]; then
    cmd+=(--agentic-job-id "${job_id}")
  fi

  local out exit_code
  out=$("${cmd[@]}" 2>&1) && exit_code=0 || exit_code=$?
  if [[ "${exit_code}" -eq 0 ]]; then
    printf '%s\n' "${ledger_key}" >> "${GUARDRAIL_LEDGER_FILE}"
    info "GUARDRAIL: emitted ${event_type} for rule ${rule_id}"
  else
    warn "GUARDRAIL: meter call failed (exit=${exit_code}) — fail-open, continuing"
  fi
}
```

**Key observations from the canonical pattern:**
- `--quiet` suppresses all non-error output — required (no TTY in cron).
- `cmd+=(--flag "$val")` bash-array discipline — NEVER eval, NEVER unquoted. [VERIFIED: source]
- `--transaction-id` is omitted for synthetic events — there is no session tx_id. This is
  intentional; report.sh's dedup gate uses `TX:<tx_id>` in `LEDGER_FILE`, but guardrail
  events use the separate `GUARDRAIL_LEDGER_FILE` with the onset key.
- `--organization-name` should be added when `ORG_NAME` is non-empty, mirroring report.sh.
  Read from `CONFIG_FILE` via the existing `read_config_field organizationName` helper.

---

### Q3: Attribution Lookup — Shell Logic

**Root session resolution:**

guardrail-check.sh has no session resolution today. The plan must add it. The mechanism:

```bash
# Step 1: Find newest session file in SESSIONS_DIR (modtime order, newest first)
# "Non-cron" filtering: there is no isCron or sessionType field in the JSONL headers.
# OpenClaw session files are UUID-named *.jsonl. The cron itself does NOT create session
# files. The correct approach is: find the most-recently-modified *.jsonl in SESSIONS_DIR.
local newest_session_id=""
newest_session_id=$(
  find "${SESSIONS_DIR}" -name "*.jsonl" -printf '%T@ %f\n' 2>/dev/null \
  | sort -rn | head -1 | awk '{print $2}' | sed 's/\.jsonl$//'
) || true

# macOS-portable version (no -printf):
# newest_session_id=$(
#   ls -t "${SESSIONS_DIR}"/*.jsonl 2>/dev/null | head -1 | xargs basename | sed 's/\.jsonl$//'
# ) || true

# Step 2: Resolve to root session via existing wrapper (fail-open)
local root_sid="${newest_session_id}"
if [[ -n "${newest_session_id}" ]]; then
  root_sid=$(get_root_session_id "${newest_session_id}")
  root_sid="${root_sid:-${newest_session_id}}"
fi
local agent_val="${REVENIUM_AGENT_PREFIX}${root_sid}"
```

**Note on "non-cron" session identification:** The CONTEXT.md says "newest non-cron session
file in SESSIONS_DIR". Inspection of the session JSONL fixtures shows the header is:
`{"type":"session","version":3,"id":"...","timestamp":"...","cwd":"..."}` — there is no
`isCron` field. The cron runner (`cron.sh`) does not create session files; it only runs
`report.sh` and `guardrail-check.sh`. Therefore "non-cron" simply means: any *.jsonl file in
`SESSIONS_DIR`. The newest by mtime is the correct heuristic. [VERIFIED: source]

**Open job resolution:**

Direct translation of `handle_halt`'s open-job scan (report.sh lines 1086–1105):

```bash
# Read JOBS_LEDGER_FILE (path must be constructed in guardrail-check.sh since
# it's defined in report.sh today, not in common.sh — see "Where JOBS_LEDGER_FILE
# lives" below).
local OPEN_JOB_ID=""
OPEN_JOB_ID=$(
  JOBS_LEDGER_FILE="${JOBS_LEDGER_FILE}" \
  python3 - <<'PY' 2>/dev/null || true
import os, re
ledger = os.environ.get('JOBS_LEDGER_FILE', '')
created = {}   # id -> line position (for newest-first ordering)
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
    # Most-recently-created = highest line index
    print(sorted(open_jobs)[-1][1])
PY
) || true
```

This emits the single most-recently-opened open job id (by ledger line order, which is
append-only chronological). D-08: if empty, omit `--agentic-job-id`.

**Where JOBS_LEDGER_FILE lives:** It is defined only in report.sh today:
`JOBS_LEDGER_FILE="${REVENIUM_JOBS_LEDGER_FILE:-${OPENCLAW_HOME}/revenium-jobs.ledger}"`

For guardrail-check.sh to read it, the plan MUST add `JOBS_LEDGER_FILE` to `common.sh`
(same pattern as `GUARDRAIL_LEDGER_FILE`). The path must be identical:
`JOBS_LEDGER_FILE="${REVENIUM_JOBS_LEDGER_FILE:-${OPENCLAW_HOME}/revenium-jobs.ledger}"`

After adding to `common.sh`, the `touch "${JOBS_LEDGER_FILE}"` guard in report.sh ensures
the file exists before guardrail-check.sh runs (cron.sh runs report.sh first).

---

### Q4: Dedup Ledger — Exact Pattern and Onset-Marker Format

**Halt dedup (mirrors JOB:halt:<haltedAt>):**

report.sh uses:
```
JOB:halt:<haltedAt>
```
appended only on success; gated by `grep -q "^JOB:halt:${HALTED_AT}$"`.

For GUARDRAIL events, the analogous key is:
```
GUARDRAIL:<event_type>:<ruleId>:<onset_marker>
```

**Onset markers:**

- **Halt:** Use `haltedAt` (the ISO timestamp emitted by the Python block when `halt_transition=True`). This is the exact same value as report.sh's `JOB:halt:<haltedAt>` gate key — consistent with that pattern. The bash tail already extracts `HALTED_RULE_ID` and `HALT_TRANSITION`. Extract `haltedAt` from `guardrail-status.json` (or emit it from the Python block as `HALTED_AT=<iso>`).

  Ledger key: `GUARDRAIL:budget_guardrail_halt:<ruleId>:<haltedAt>`

- **Warn:** No `warnedAt` timestamp exists in the current schema. The onset marker must be
  stable for the duration of the warn episode. The cleanest approach: use a SHA1-derived
  hash of `<ruleId>:<current tick ISO timestamp>` at onset time, OR simply use the ISO
  timestamp of the Python block's `now` value that was current at the onset tick. The
  simplest and most consistent with the halt pattern: **emit `WARN_ONSET_<n>=<ruleId>:<now>`
  from the Python block** so the bash tail has the same stable identifier.

  Recommendation: emit `now` (from the Python block's `now` variable, which is already
  captured at the top of the heredoc) as the onset marker for both warn and shadow, matching
  how `haltedAt = now` is assigned for halt. The Python block already produces a per-rule
  `lastChecked: now` field.

  Ledger key: `GUARDRAIL:budget_guardrail_warn:<ruleId>:<now>`
  Ledger key: `GUARDRAIL:budget_guardrail_shadow:<ruleId>:<now>`

- **Re-fire safety:** The dedup ledger is secondary to the Python transition gate (D-10). The
  ledger prevents double-emission on crash/restart within the same tick. A new warn-onset on
  a recovered rule produces a new `<now>` value → new key → new emission. This is correct.

**Ledger file definition:**

Add to `common.sh` (in the "Phase 4 path constants" block):
```bash
GUARDRAIL_LEDGER_FILE="${OPENCLAW_HOME}/revenium-guardrail.ledger"
```

The file is append-only (never truncated) and uses `grep -qF` for dedup lookups — no
locking needed since guardrail-check.sh runs under the cron flock.

---

### Q5: Fail-Open Sequencing

The bash tail of guardrail-check.sh executes in this order:

1. **Section G** (lines 123–333): Python heredoc writes `guardrail-status.json` atomically
   (`tempfile.mkstemp` + `os.replace`). Status file is **durably on disk before any bash runs**.
2. **Section H** (lines 347–350): Legacy `budget-status.json` cleanup.
3. **Section I** (lines 355–413): `HALT_TRANSITION=true` → halt notification via
   `openclaw message send`.
4. **Section L** (lines 420–446): Shadow-mode one-shot notification.

**Meter emission must be added as Section M**, appended AFTER Section L:

```
# ---------------------------------------------------------------------------
# (M) Guardrail event metering — fail-open (D-11).
# Status file is durable and notifications dispatched before this point.
# ---------------------------------------------------------------------------
```

This ordering is non-negotiable per D-11. Any failure in section M (network error, CLI not
found, bad argv) exits 0 (the function catches errors internally).

The `|| { warn "..."; exit 0; }` guard on Section G (line 333) means: if the Python block
fails entirely, the script exits 0 before reaching Section M at all. This is correct — there
is no transition data to emit if the Python block failed.

---

### Q6: D-12 Removal — Exact Branch to Delete

The dead GUARDRAIL branch in `report.sh` is lines 843–851. The exact block:

```bash
# DELETE lines 843–851 (keeping only the TOOL_CALL and CHAT paths):

    # Determine operation type from message content:
    #   GUARDRAIL — completion reads budget-status.json (budget enforcement check)
    #   TOOL_CALL — completion invokes tools (stopReason=toolUse)
    #   CHAT      — regular text response
    local raw_stop_reason operation_type="CHAT"
    raw_stop_reason=$(echo "${line}" | jq -r '.message.stopReason // "stop"')
    if echo "${line}" | jq -e '.message.content[] | select(.type=="toolCall") | .arguments' 2>/dev/null | grep -q "budget-status.json"; then
      operation_type="GUARDRAIL"
    elif [[ "${raw_stop_reason}" == "toolUse" || "${raw_stop_reason}" == "tool_use" ]]; then
      operation_type="TOOL_CALL"
    fi
```

**After removal**, these lines become:

```bash
    # Determine operation type from message content:
    #   TOOL_CALL — completion invokes tools (stopReason=toolUse)
    #   CHAT      — regular text response
    local raw_stop_reason operation_type="CHAT"
    raw_stop_reason=$(echo "${line}" | jq -r '.message.stopReason // "stop"')
    if [[ "${raw_stop_reason}" == "toolUse" || "${raw_stop_reason}" == "tool_use" ]]; then
      operation_type="TOOL_CALL"
    fi
```

The removed `if` branch:
```bash
    if echo "${line}" | jq -e '.message.content[] | select(.type=="toolCall") | .arguments' 2>/dev/null | grep -q "budget-status.json"; then
      operation_type="GUARDRAIL"
    elif [[ ...
```

becomes just:
```bash
    if [[ "${raw_stop_reason}" == "toolUse" || "${raw_stop_reason}" == "tool_use" ]]; then
      operation_type="TOOL_CALL"
    fi
```

**Why the heuristic is dead:** It greps `toolCall.arguments` for `"budget-status.json"` — but
the current file is `guardrail-status.json`. Every completion that reads the config (which is
common) would match and get tagged GUARDRAIL. The heuristic is unreliable and predates the
current filename.

**Effect after removal:** `operation_type` for any completion is either `TOOL_CALL`
(stopReason=toolUse) or `CHAT` (everything else). This is the correct, desired state.

---

### Q7: Bash 3.2 / Heredoc Constraints

All constraints already established in the codebase. The plan must follow these exactly:

1. **No `${}` inside `<<'PY'` heredocs.** Variables MUST be passed via environment:
   ```bash
   FOO="${bash_var}" python3 - <<'PY'
   import os
   foo = os.environ['FOO']
   PY
   ```
   Any new Python heredoc in guardrail-check.sh must use `VAR="${VAR}"` env-passing.

2. **No `<<<` here-strings in subshells on macOS (Bash 3.2).** The shadow notification
   section uses `mktemp + while IFS='|' read` (lines 421–445) to avoid this. Any new
   multi-value iteration in guardrail-check.sh should follow the same pattern.

3. **`|| true` after command substitutions.** Every `$( ... )` that could fail must have
   `|| true` to avoid aborting under `set -e`.

4. **`|| { warn "..."; exit 0; }` for critical blocks.** The Python heredoc has this guard
   (line 333). Any new Python block that writes the ledger should also use `|| true` so
   failures are warn-logged without killing the script.

5. **`set -euo pipefail` is active** in guardrail-check.sh (line 17). The `_emit_guardrail_event`
   function must never `return 1` (only `return 0`) or use `exit` — callers must wrap it with
   `|| true`.

6. **Bash-array discipline:** `cmd+=(--flag "$val")` — NEVER eval, NEVER string interpolation
   of untrusted values. The `_emit_guardrail_event` function follows `post_to_revenium`'s
   exact pattern.

---

### Q8: Existing Test Surface and How to Extend It

**What exists today:**

| Test file | Covers | Pattern |
|-----------|--------|---------|
| `tests/test_report_argv.sh` | report.sh task-type/agent wiring (METER-03/TRACE-01/02) | Builds tmp OPENCLAW_HOME, places stub-revenium.sh on PATH, runs report.sh, asserts STUB_REVENIUM_ARGV_FILE contents |
| `tests/test_report_jobs_argv.sh` | report.sh agentic-job wiring (JLIFE-01..05), Phase 8 halt handler | Same pattern + halt fixture helper; includes GROUP I/J/K for halt scenarios |
| `tests/test_get_root_session_id.py` | get-root-session-id.py resolver | Pure Python unit test |
| `tests/test_write_marker.sh` | write-marker.sh | Shell test |
| `tests/test_write_job_marker.sh` | write-job-marker.sh | Shell test |
| `tests/stub-revenium.sh` | Argv-capturing stub | Shared fixture |

**No guardrail-check.sh test file exists today.** [VERIFIED: source — `ls tests/` found no `test_guardrail*.sh`]

**New test file needed:** `tests/test_guardrail_argv.sh`

Structure mirrors `test_report_argv.sh`:

```
tests/test_guardrail_argv.sh:
  - Build tmp OPENCLAW_HOME with:
      - guardrail-status.json (pre-state: no prior halted/warned/shadow rules)
      - config.json (ruleIds: ["rule-abc123"])
      - revenium-guardrail.ledger (empty)
      - revenium-jobs.ledger (with one open job)
      - agents/main/sessions/ (one fake session file for attribution)
  - Place stub-revenium.sh on PATH (captures argv to STUB_REVENIUM_ARGV_FILE)
  - Stub `revenium guardrails enforcement-rules get` response (halt/warn/shadow fixture)
  - Run guardrail-check.sh
  - Assert STUB_REVENIUM_ARGV_FILE contains:
      - meter completion token
      - --operation-type GUARDRAIL
      - --task-type budget_guardrail_halt | budget_guardrail_warn | budget_guardrail_shadow
      - --stop-reason COST_LIMIT
      - --agent openclaw-<expected_root_sid>
      - --agentic-job-id <expected_job_id>
      - --provider revenium
      - --model guardrail-enforcement
  - Assert revenium-guardrail.ledger contains the onset key
  - Assert idempotency: run twice, assert argv file has exactly 1 meter call per event type
  - Assert fail-open: break stub so meter call fails, assert guardrail-check.sh exits 0
```

**Extension to stub-revenium.sh needed:** Add a `STUB_REVENIUM_GUARDRAILS_FAIL=1` switch
that fails `guardrails enforcement-rules get` → exercises the `|| true` fallback path in
guardrail-check.sh. Also need stub responses for:
- `guardrails enforcement-rules get <teamId> --output json` → fixture JSON
- `guardrails budget-rules list --output json` → fixture JSON
- `config show` → "Team ID:    test-team-id" output

**stub-revenium.sh currently exits 0 silently for unknown commands.** The new tests can rely
on that for `meter completion` calls (they succeed silently and capture argv).

**Live validation (test host 172.16.1.247):**

Per CONTEXT.md and project memory (test machine is at 172.16.1.247):

1. Deploy the skill update to `~/.openclaw/skills/revenium/` on the test host.
2. Force a halt condition: temporarily set a rule threshold below the current spend.
3. Wait for the next cron tick (or run `bash ~/.openclaw/skills/revenium/scripts/cron.sh` manually).
4. Verify a GUARDRAIL transaction appears in Revenium dashboard for the team.
5. Verify `revenium-guardrail.ledger` contains the onset key.
6. Verify no double-emit on subsequent cron ticks (ledger gate works).
7. Reset the rule threshold.
8. Force a warn condition (threshold slightly above current spend).
9. Repeat steps 3–6 for warn-onset.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead |
|---------|-------------|-------------|
| Root session resolution | Custom JSONL walker | `get_root_session_id` wrapper in common.sh (already present) |
| Open-job discovery | Custom ledger parser | Adapt the exact `handle_halt` Python heredoc (report.sh lines 1086–1105) |
| Fail-open meter invocation | Custom error propagation | `cmd+=(...)` array + `"${cmd[@]}" 2>&1 \|\| exit_code=$?` pattern from `post_to_revenium` |
| Ledger dedup | Custom file locking | `grep -qF` + append — safe under the cron flock already held |
| Atomic status write | Custom tmpfile | Already done in Section G (`tempfile.mkstemp + os.replace`) — do NOT duplicate |

---

## Common Pitfalls

### Pitfall 1: `warn_transitions` using `state == 'block'` instead of `state == 'warn'`
**What goes wrong:** Warn detection accidentally fires on halted (blocked) rules.
**Why it happens:** `shadow_transitions` gates on `state == 'block'`; copying verbatim without
changing the state check produces wrong behavior.
**How to avoid:** Use `state == 'warn'` (warnBreached but NOT breached) for warn detection.
**Warning signs:** Warn events fire simultaneously with halt events for the same rule.

### Pitfall 2: Metering before status file write
**What goes wrong:** Metering call blocks or fails and the status file never gets written.
**Why it happens:** Placing Section M before Section G or I/L.
**How to avoid:** Section M is the LAST section in the bash tail, after L (shadow notifications).
**Warning signs:** guardrail-check.sh hangs or exits non-zero on network issues.

### Pitfall 3: `${GUARDRAIL_LEDGER_FILE}` not defined in guardrail-check.sh context
**What goes wrong:** `GUARDRAIL_LEDGER_FILE` is empty, ledger writes go to a relative path or
fail silently, dedup never works.
**Why it happens:** `JOBS_LEDGER_FILE` is currently only defined in report.sh; common.sh does
not define either.
**How to avoid:** Add BOTH `GUARDRAIL_LEDGER_FILE` and `JOBS_LEDGER_FILE` to common.sh so
guardrail-check.sh (which sources common.sh) has both paths.

### Pitfall 4: `${}` inside `<<'PY'` heredocs
**What goes wrong:** Bash 3.2 does not expand `${}` inside single-quoted heredocs — the
literal string `${VAR}` is passed to Python, which fails with a NameError or EnvironmentError.
**Why it happens:** Developer copies Python f-string patterns from elsewhere.
**How to avoid:** All new Python heredocs in guardrail-check.sh MUST use `os.environ['VAR']`.
**Warning signs:** Python block outputs nothing or throws a SyntaxError.

### Pitfall 5: `--transaction-id` missing vs. `TX:` ledger collision
**What goes wrong:** Without `--transaction-id`, the Revenium API may reject the call or
assign a random id.
**Why it happens:** Synthetic events have no OpenClaw transaction id.
**How to avoid:** Either omit `--transaction-id` (check if it is optional) or generate a
stable synthetic id from the ledger key (e.g. SHA1 of the onset marker). The GUARDRAIL
ledger gate provides the idempotency anyway. Confirm against `revenium meter completion
--help` during Wave 0.

### Pitfall 6: Shadow exclusion from warn detection
**What goes wrong:** Shadow-mode rules emit `state='block'`, not `state='warn'`. If
shadow-mode rules somehow also reached `state=='warn'` (possible if warnThreshold breached
but hardLimit not), they should be excluded from warn_transitions to avoid double-emitting
(shadow path already handles them).
**How to avoid:** Add `and not nr.get('shadowMode', False)` to warn-onset condition. The
code above already includes this.

### Pitfall 7: `JOBS_LEDGER_FILE` race with report.sh
**What goes wrong:** guardrail-check.sh reads `revenium-jobs.ledger` while report.sh is still
writing to it.
**Why it happens:** cron.sh runs `report.sh → guardrail-check.sh` sequentially under one
flock. As long as `report.sh` completes before `guardrail-check.sh` starts (which it does —
they are sequential, not parallel), the ledger is fully consistent when guardrail-check.sh
reads it.
**Warning signs:** Would only manifest if cron.sh parallel execution were introduced. Not a
current concern.

---

## Code Examples

### Existing shadow_transitions emit line (template)
```python
# Source: guardrail-check.sh line 331
print(f"SHADOW_TRANSITIONS={json.dumps(shadow_transitions)}")
```

### Existing bash sed extraction (template for WARN_TRANSITIONS)
```bash
# Source: guardrail-check.sh line 341
SHADOW_TRANSITIONS_JSON=$(echo "${HALT_OUTPUT}" | sed -n 's/^SHADOW_TRANSITIONS=//p')
# New (mirrors this):
WARN_TRANSITIONS_JSON=$(echo "${HALT_OUTPUT}" | sed -n 's/^WARN_TRANSITIONS=//p')
```

### Existing shadow-to-pipe loop (template for iterating warn_transitions)
```bash
# Source: guardrail-check.sh lines 421-445
# pipe-delimited format; pipes don't appear in numeric values or enum strings.
SHADOW_TRANSITIONS_JSON="${SHADOW_TRANSITIONS_JSON}" python3 - <<'PY' > "${SHADOW_TMP}"
import json, os
for r in json.loads(os.environ['SHADOW_TRANSITIONS_JSON']):
    print(f"{r['name']}|{r.get('metricType','')}|{r.get('windowType','')}|{r['currentValue']}|{r['hardLimit']}")
PY
while IFS='|' read -r SR_NAME SR_METRIC SR_WINDOW SR_CV SR_HL; do
    ...
done < "${SHADOW_TMP}"
rm -f "${SHADOW_TMP}"
```

### Existing haltedAt emit (halt onset marker source)
```python
# Source: guardrail-check.sh lines 321-328
print(f"HALT_TRANSITION={'true' if halt_transition else 'false'}")
if halt_transition and halted_rule:
    print(f"HALTED_RULE_NAME={halted_rule['name']}")
    print(f"HALTED_RULE_ID={halted_rule['ruleId']}")
    # ... other fields ...
```

**Note:** `haltedAt` is NOT currently emitted as a `KEY=VALUE` line. It is stored in the
status file (`data['haltedAt'] = halted_at` at line 299). The bash tail would need to either
(a) emit `HALTED_AT=${halted_at}` from Python, or (b) read `haltedAt` from the freshly
written `guardrail-status.json`. Option (a) is simpler and consistent with the existing
pattern. **The plan must add `print(f"HALTED_AT={halted_at}")` to the Python emit block.**

---

## State of the Art

| Old Approach | Current Approach | Impact |
|--------------|------------------|--------|
| `budget-status.json` filename | `guardrail-status.json` | D-12 heuristic greps for old name — always fails |
| GUARDRAIL operation_type heuristic in report.sh | Removed by D-12 | Completions become CHAT or TOOL_CALL only |
| No guardrail event metering | GUARDRAIL transactions from guardrail-check.sh | Phase 9 |

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `revenium meter completion --transaction-id` is optional (can be omitted for synthetic events) | Q2 flag set | If required, must generate synthetic id; add to Wave 0 preflight check |
| A2 | `revenium meter completion` accepts `--input-tokens 0` / `--output-tokens 0` / `--total-tokens 0` (zero values are valid) | Q2 flag set | If minimum is 1, zero-token synthetic events will fail; need to use 1 as sentinel |
| A3 | `revenium meter completion` accepts `--request-duration 0` | Q2 flag set | Same risk as A2 |
| A4 | Session files in `SESSIONS_DIR` are modified by OpenClaw at session end; newest mtime = most recent active session | Q3 attribution | If mtime is set at creation not modification, ls -t ordering is still creation-time ordering, which is equivalent |
| A5 | `GUARDRAIL_LEDGER_FILE` append (without flock) is safe since guardrail-check.sh always runs under the cron flock | Q4 ledger | If run outside cron without flock, two simultaneous runs could race on ledger append — low risk given cron use |

**All A1–A3 can be verified during Wave 0 task by running `revenium meter completion --help`
and testing against the live Revenium API on the test host.**

---

## Open Questions (RESOLVED)

1. **Is `--transaction-id` required for `revenium meter completion`?**
   - What we know: report.sh always passes it; the CLI help output is not captured here.
   - What's unclear: Whether the API enforces it server-side.
   - Recommendation: Wave 0 task must run `revenium meter completion --help | grep transaction-id` and test a call without it. If required, generate `GUARDRAIL_<type>_<sha1_of_onset_key[:8]>` as the synthetic id.
   - **RESOLVED (2026-06-04, host 172.16.1.247, Team DZxzEl):** `--transaction-id` is OPTIONAL. Listed in `--help` WITHOUT `(required)`, and a call omitting it returned EXIT=0 and created a real event. **No synthetic transaction-id is needed. The implementation MUST NOT add `--transaction-id`.**

2. **Does `revenium meter completion` accept zero for all token/cost fields?**
   - What we know: The CLI is designed for LLM completions; zero may trigger validation.
   - Recommendation: Same Wave 0 test — attempt a zero-token synthetic call against the Revenium API on the test host. If rejected, use `--input-tokens 0 --output-tokens 0 --total-tokens 1` (sentinel 1) with a comment explaining the synthetic nature.
   - **RESOLVED (2026-06-04, host 172.16.1.247, Team DZxzEl):** Zero token values ARE accepted. `--input-tokens 0 --output-tokens 0 --total-tokens 0` was accepted by both dry-run (body showed inputTokenCount:0/outputTokenCount:0/totalTokenCount:0) and the real API (event created, EXIT=0). **No `--total-tokens 1` sentinel is needed.**

3. **Does `revenium meter completion --help` show `--stop-reason COST_LIMIT` as a valid enum value?**
   - What we know: report.sh uses `map_stop_reason` to map OpenClaw stop reasons to Revenium enums. `COST_LIMIT` is used in the REQUIREMENTS.md spec.
   - Recommendation: Verify against `revenium meter completion --help` on the test host.
   - **RESOLVED (2026-06-04, host 172.16.1.247, Team DZxzEl):** `COST_LIMIT` IS a valid `--stop-reason` enum. `--help` enumerates it as `(END, END_SEQUENCE, TIMEOUT, TOKEN_LIMIT, COST_LIMIT, COMPLETION_LIMIT, ERROR, CANCELLED)`, and the call with `--stop-reason COST_LIMIT` returned EXIT=0. **No alternate stop-reason fallback is needed.**
   - **BONUS:** `--operation-type GUARDRAIL` passes through the live CLI even though `--help` documents the enum WITHOUT listing GUARDRAIL. The dry-run body showed `operationType:GUARDRAIL` and the real API created the event with EXIT=0. The phase's `--operation-type GUARDRAIL` design is confirmed working.
   - **CLEANUP NOTE:** A trial event (id 81f8cc86-a1d3-4c51-92f8-92105ed7e9bf, created 2026-06-04T02:25:56Z) was created during verification — zero-token/zero-cost on test tenant Team DZxzEl. `revenium meter` has NO delete subcommand (events are immutable usage records); the trial event is benign and was left in place.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `revenium` CLI | All meter calls | guarded (line 58-61 in guardrail-check.sh) | prod | exit 0 warn (existing preflight) |
| `python3` | Transition detection, attribution, ledger | guarded (line 62-65) | prod | exit 0 warn (existing preflight) |
| `get-root-session-id.py` | Root session resolution | exists in SKILL_DIR/scripts/ | current | fail-open to input sid (existing wrapper) |
| `revenium-jobs.ledger` | Open-job attribution | created by report.sh (touch at startup) | report.sh runs first | empty file = no open jobs = omit --agentic-job-id |
| `revenium-guardrail.ledger` | Onset dedup | new file, must be created | — | `touch "${GUARDRAIL_LEDGER_FILE}"` in guardrail-check.sh startup |

---

## Validation Architecture

> nyquist_validation is enabled in .planning/config.json.

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Bash integration tests (existing pattern in tests/) |
| Config file | None — tests are standalone shell scripts |
| Quick run command | `bash tests/test_guardrail_argv.sh` |
| Full suite command | `bash tests/test_report_argv.sh && bash tests/test_report_jobs_argv.sh && bash tests/test_guardrail_argv.sh` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| GRDEV-01 | Halt onset emits `--operation-type GUARDRAIL --task-type budget_guardrail_halt --stop-reason COST_LIMIT` | integration | `bash tests/test_guardrail_argv.sh` | ❌ Wave 0 |
| GRDEV-01 | Halt dedup: second run produces no additional meter call | integration | `bash tests/test_guardrail_argv.sh` | ❌ Wave 0 |
| GRDEV-02 | Warn onset emits `--task-type budget_guardrail_warn`, once per onset | integration | `bash tests/test_guardrail_argv.sh` | ❌ Wave 0 |
| GRDEV-02 | Warn→ok→warn re-fires (second onset after recovery) | integration | `bash tests/test_guardrail_argv.sh` | ❌ Wave 0 |
| GRDEV-03 | Shadow onset emits `--task-type budget_guardrail_shadow`, once per onset | integration | `bash tests/test_guardrail_argv.sh` | ❌ Wave 0 |
| GRDEV-04 | `--agent openclaw-<root_sid>` present in meter call | integration | `bash tests/test_guardrail_argv.sh` | ❌ Wave 0 |
| GRDEV-04 | `--agentic-job-id` present when open job exists; omitted when none | integration | `bash tests/test_guardrail_argv.sh` | ❌ Wave 0 |
| GRDEV-05 | Meter call failure → guardrail-check.sh still exits 0, status file written | integration | `bash tests/test_guardrail_argv.sh` | ❌ Wave 0 |
| GRDEV-06 | report.sh `operation_type` is only CHAT or TOOL_CALL after D-12 removal | integration | `bash tests/test_report_argv.sh` | ✅ (existing, extend) |

### Sampling Rate

- **Per task commit:** `bash tests/test_guardrail_argv.sh`
- **Per wave merge:** Full suite command above
- **Phase gate:** Full suite green before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `tests/test_guardrail_argv.sh` — covers GRDEV-01..05 (new file, does not exist)
- [ ] `tests/stub-revenium.sh` extension — needs `guardrails enforcement-rules get` and
      `guardrails budget-rules list` stub responses and `STUB_REVENIUM_GUARDRAILS_FAIL` switch
- [ ] `revenium meter completion --help` verification — confirm `--transaction-id` optional,
      zero token values accepted, `COST_LIMIT` stop-reason valid

*(GRDEV-06: existing `tests/test_report_argv.sh` can be extended with a new assertion that
no `operation_type GUARDRAIL` token appears in argv after the D-12 removal.)*

---

## Security Domain

> security_enforcement not explicitly set to false in config.json — treated as enabled.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | Revenium API auth is pre-established via `revenium config show` |
| V3 Session Management | no | Not applicable |
| V4 Access Control | no | Not applicable |
| V5 Input Validation | yes | Env-passing heredoc pattern prevents injection; rule names truncated to 64 chars (existing T-03-04); ruleId is string-hash from API |
| V6 Cryptography | no | No new crypto; sha1 only for synthetic id (non-security use) |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Rule name injection via meter call argv | Tampering | Env-passing heredoc + `cmd+=(...)` array discipline (existing T-04-09) |
| Session file path traversal | Tampering | `find "${SESSIONS_DIR}"` scoped to known directory; basename strips path components |
| Ledger append with adversarial onset-marker | Tampering | Onset marker is composed of `<ruleId>:<now>` — ruleId comes from the Revenium API response (trusted), `now` is local datetime; not user-supplied |
| Double-emit on concurrent cron ticks | Repudiation | cron flock (flock -n) prevents concurrent execution; ledger is secondary backstop |

---

## Sources

### Primary (HIGH confidence)
- `scripts/guardrail-check.sh` (entire file read) — shadow_transitions detection template,
  bash tail structure, env-passing heredoc patterns, fail-open posture
- `scripts/report.sh` (lines 1–316, 820–934, 1009–1256 read) — post_to_revenium argv
  discipline, handle_halt open-job scan, JOB:halt dedup gate, D-12 branch location
- `scripts/common.sh` (entire file read) — path constants, get_root_session_id wrapper,
  existing constant definitions
- `scripts/get-root-session-id.py` (entire file read) — resolver semantics, fail-open contract
- `scripts/cron.sh` (entire file read) — report.sh → guardrail-check.sh sequential ordering
  under single flock, confirms D-11 sequencing
- `.planning/phases/09-guardrail-event-metering/09-CONTEXT.md` — all locked decisions D-01..D-12
- `.planning/REQUIREMENTS.md` — GRDEV-01..06

### Secondary (MEDIUM confidence)
- `tests/test_report_argv.sh`, `tests/test_report_jobs_argv.sh`, `tests/stub-revenium.sh`
  (read) — test patterns, stub behavior, GROUP I halt test fixture structure

### Tertiary (LOW confidence)
- None

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — no new packages; existing tools fully verified by source inspection
- Architecture: HIGH — all patterns extracted directly from canonical source files
- Pitfalls: HIGH — all pitfalls derived from direct inspection of guards and comments already in the code
- Test surface: HIGH — confirmed by `ls tests/` that no guardrail test file exists today

**Research date:** 2026-06-03
**Valid until:** 2026-07-03 (stable internal codebase, 30-day window)
