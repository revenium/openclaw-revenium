# Phase 2: Setup Flow - Research

**Researched:** 2026-03-14
**Domain:** SKILL.md instruction authoring — setup conversation flow, revenium-cli command interface, config persistence, idempotency
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

**Setup Conversation**
- Agent collects API key, budget amount, and period — Claude decides whether step-by-step or all-at-once based on what minimizes friction
- No API key validation step — trust the user, errors surface naturally during budget creation
- Budget alert name is auto-generated (e.g., "OpenClaw Daily Budget") based on the selected period — user is not asked to name it
- Post-setup confirmation verbosity at Claude's discretion

**Config Persistence**
- Config file location: `~/.openclaw/skills/revenium/config.json` (co-located with SKILL.md)
- Config stores anomaly ID only — API key lives in revenium's own config (`revenium config set key`), budget details queryable via CLI
- Config file should be human-readable (pretty-printed JSON)
- Grace mode setting will be added to config.json in Phase 3 (not this phase)

**Idempotency & Reconfiguration**
- When existing config.json with anomaly ID detected: offer to reconfigure ("Budget already configured. Want to update it?")
- On reconfigure: delete the old budget alert from Revenium (`revenium alerts budget delete`), then create new one — clean up, don't leave orphans
- Granularity of reconfiguration at Claude's discretion (full redo vs selective changes)

**Error Handling**
- If API key is invalid / budget creation fails: report error, tell user to run `/revenium` when ready, and stop — no retries
- Atomic setup: only write config.json after ALL steps succeed — no partial state
- If setup hasn't completed (no config.json): behavior at Claude's discretion (refuse to work vs warn-and-work — should align with enforcement philosophy from Core Value)

### Claude's Discretion
- Step-by-step vs all-at-once setup conversation flow
- Post-setup confirmation verbosity
- Granular vs full-redo reconfiguration
- Whether to refuse operations or warn when setup incomplete

### Deferred Ideas (OUT OF SCOPE)
None — discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| SETUP-01 | Agent prompts user for Revenium API key on first use | Instruction prose in SKILL.md `## Setup` section; triggers when `{baseDir}/config.json` does not exist |
| SETUP-02 | Agent configures CLI via `revenium config set key <api-key>` | Verified: `revenium config set key <api-key>` — no `--json` needed; exit code 0 = success |
| SETUP-03 | Agent prompts user for budget amount (numeric threshold) | Instruction prose; agent passes value to `--threshold <amount>` on budget create |
| SETUP-04 | Agent prompts user for budget period (DAILY, WEEKLY, MONTHLY, QUARTERLY) | Verified: `--period` flag exists on `alerts budget create` with exactly these four values; default is MONTHLY |
| SETUP-05 | Agent creates budget alert via `revenium alerts budget create --name <name> --threshold <amount> --period <period>` | Verified: all three flags confirmed in binary help; `--json` flag available for reliable ID parsing |
| SETUP-06 | Agent persists the returned anomaly ID to a config file for subsequent checks | CRITICAL: `budget create --json` returns the full anomaly object; ID to store is the `"id"` field (string, e.g., `"75BjG5"`), NOT the integer `anomalyId` in `budget get` responses |
| SETUP-07 | Setup is idempotent — skips budget creation if anomaly ID already exists | Check for `{baseDir}/config.json` at start of setup; offer reconfigure on existing config |
| SETUP-08 | Agent can reconfigure settings (re-run setup) when user requests it | `/revenium` command handles this; on reconfigure: `revenium alerts budget delete <id> --yes`, then full setup |
</phase_requirements>

## Summary

Phase 2 delivers the content for two SKILL.md sections: `## Setup` and `## /revenium Command`. There is no code, no build step, and no test framework — the deliverable is markdown prose that instructs an LLM agent how to run a CLI-based setup flow. The work is: write the instructions correctly so an agent following them will configure the revenium-cli API key, create a budget alert with the correct flags, persist the right ID field from the response, and handle idempotent re-runs cleanly.

The most critical technical finding is an ID field naming discrepancy in the revenium-cli output. The `alerts budget get <id> --json` response contains a field called `anomalyId` which is an **integer** (e.g., `1206`) — but this integer cannot be passed back to `budget get`. The **string** `alertId` field from `alerts budget list --json` (e.g., `"75BjG5"`) is what actually works with `budget get`. When `budget create --json` runs, it returns the full anomaly object with an `"id"` field (string) — that `"id"` field is what must be stored in config.json and used for all subsequent Phase 3 `budget get` calls. The instructions must be explicit about this.

The second key finding is that `config show` does not support `--json` output — it returns human-readable text only. The setup section must not instruct the agent to parse config show output programmatically. The only way to verify key configuration worked is by checking the exit code of `config set key`.

**Primary recommendation:** Write the `## Setup` section as a numbered procedure with explicit variable names (e.g., `ALERT_ID`) so the agent has clear identifiers to track through multi-step setup. Use `--json` on `budget create` and extract `.id` from the response. Write config.json with `jq` or a Python one-liner to guarantee pretty-printing and atomic write.

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| OpenClaw SKILL.md markdown prose | AgentSkills v1 | All agent behavior is instruction text, not code | The only delivery mechanism; agent receives instructions as part of system prompt |
| revenium-cli | Binary on PATH (arm64, verified) | API key config, budget alert creation, deletion | Already established; Phase 2 uses `config set`, `alerts budget create`, `alerts budget delete` |
| Bash (via agent's shell tool) | POSIX | Execute CLI commands and file writes | Standard agent execution mechanism; no dependencies beyond the existing binary |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `jq` or Python3 | System-installed | Parse `--json` output to extract `"id"` field from budget create response | Use `python3 -c` inline for JSON extraction — more reliably available than `jq` on all machines |
| `{baseDir}` placeholder | OpenClaw runtime | Reference `{baseDir}/config.json` in instructions | Use throughout setup instructions to reference the config file path |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `python3 -c "import json,sys; print(json.load(sys.stdin)['id'])"` for ID extraction | `jq -r '.id'` | `jq` is cleaner but not always on PATH; Python3 is available on all modern macOS/Linux; prefer Python3 for reliability |
| Atomic config write via temp file + mv | Direct file write | Both are acceptable for a single-key config; atomic write prevents partial-write corruption on crashes but is overkill for this use case |
| Storing `alertId` from `budget list` | Storing `id` from `budget create` response | Same value, different source; during setup, `create --json` returns it directly — no need to list afterward |

**Installation:**

No installation step. This phase modifies the existing `SKILL.md` (fills in placeholder sections) and creates `{baseDir}/config.json` at runtime during agent execution.

## Architecture Patterns

### Recommended Project Structure

```
SKILL.md                               # source of truth (repo root)
~/.openclaw/skills/revenium/
├── SKILL.md                           # runtime install
└── config.json                        # created by setup; stores { "alertId": "..." }
```

Config file schema (Phase 2 only — Phase 3 will add `graceMode`):

```json
{
  "alertId": "75BjG5"
}
```

### Pattern 1: Atomic Config Write (Write After All Steps Succeed)

**What:** Only write config.json after `revenium config set key` AND `alerts budget create` both succeed. If any step fails, no config.json is written. This enforces the locked decision: "only write config.json after ALL steps succeed — no partial state."

**When to use:** Mandatory. This is the correctness invariant for setup.

**Example instruction phrasing:**
```
5. Run: revenium alerts budget create --name "OpenClaw {Period} Budget" --threshold {AMOUNT} --period {PERIOD} --json
   - If this command fails with a non-zero exit code: tell the user what went wrong, tell them to run /revenium when ready, and STOP. Do NOT write config.json.
   - If it succeeds: extract the "id" field from the JSON response. This is the ALERT_ID.
6. Write config.json to {baseDir}/config.json:
   echo '{"alertId":"ALERT_ID"}' | python3 -c "import json,sys; d=json.load(sys.stdin); print(json.dumps(d, indent=2))" > {baseDir}/config.json
```

### Pattern 2: Idempotency Check at Entry

**What:** The first thing the setup section does is check whether `{baseDir}/config.json` exists. If it does, the agent offers reconfiguration instead of running setup.

**When to use:** Always — this is the SETUP-07 requirement.

**Example instruction phrasing:**
```
## Setup

At the start of any operation, check: does {baseDir}/config.json exist?

- If YES: setup is complete. Proceed to the Operation Guard section.
  - Exception: if the user has explicitly requested reconfiguration (via /revenium), run the Reconfiguration flow below instead.
- If NO: run the Setup Flow below.
```

### Pattern 3: Alert Name Generation from Period

**What:** Generate the alert name programmatically from the user-selected period: `"OpenClaw {Period} Budget"` where `{Period}` is title-cased (e.g., "DAILY" → "Daily", "MONTHLY" → "Monthly").

**When to use:** Always — user is never asked to name the alert (locked decision).

**Examples:**
```
Period: DAILY     → Name: "OpenClaw Daily Budget"
Period: WEEKLY    → Name: "OpenClaw Weekly Budget"
Period: MONTHLY   → Name: "OpenClaw Monthly Budget"
Period: QUARTERLY → Name: "OpenClaw Quarterly Budget"
```

### Pattern 4: Reconfiguration with Orphan Cleanup

**What:** On reconfigure, delete the old alert first, then run full setup from scratch. Prevents orphaned alerts in Revenium.

**When to use:** When user requests reconfiguration via `/revenium` and existing config.json is detected.

**Example instruction phrasing:**
```
## Reconfiguration Flow

1. Read the existing alertId from {baseDir}/config.json
2. Run: revenium alerts budget delete {alertId} --yes
   - If this fails (alert already deleted or not found): log a warning but continue — the important thing is no orphans going forward
3. Delete {baseDir}/config.json
4. Run the full Setup Flow above
```

### Anti-Patterns to Avoid

- **Storing `anomalyId` (integer) from `budget get` response:** The integer `anomalyId` in `budget get --json` responses is internal metadata. Passing it back to `budget get` returns HTTP 400. Store the string `id` field from `budget create --json`.
- **Verifying API key via `config show` parsing:** `config show` does not support `--json`; its output is human-readable only. Do not instruct the agent to parse it. Trust the exit code of `config set key`.
- **Writing config.json before budget create succeeds:** Partial state means Phase 3's guard reads a config but the alert may not exist in Revenium. Always write config.json last.
- **Using `jq` without verifying it's installed:** `jq` is common but not universal. Python3 is more reliably available for JSON parsing in SKILL.md instructions.
- **Asking user to provide the alert name:** Locked decision prohibits this. Auto-generate from period.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| JSON pretty-printing | Custom shell string formatting | `python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin), indent=2))"` | Built-in, no dependencies, always available |
| Idempotency state store | Custom state tracking logic | Check existence of `{baseDir}/config.json` | The file IS the state — presence = setup complete, absence = setup needed |
| API key validation | Custom validation regex | Trust `revenium config set key` exit code; errors surface at `budget create` step | No validation step is a locked decision — don't add complexity |
| Budget alert lookup by name | Manual `budget list` parsing + matching | `budget delete <alertId> --yes` from stored config | The stored alertId is already the correct reference — no need to re-lookup by name |

**Key insight:** The SKILL.md is prose instructions for an LLM, not a shell script. Every step that requires "logic" should be framed as a simple decision the agent makes, not a complex script. The agent is the runtime — keep instructions declarative.

## Common Pitfalls

### Pitfall 1: Wrong ID Field Stored in config.json

**What goes wrong:** Instructions tell the agent to store `anomalyId` from `budget get` (integer), or `alertId` from `budget list`. Phase 3's guard then calls `revenium alerts budget get {stored-id}` and gets HTTP 400 (if integer was stored) or works correctly (if string alertId from list was used).

**Why it happens:** The CLI uses "anomaly ID" terminology inconsistently. `budget get` response contains `anomalyId` (integer) which looks like the canonical ID. But `budget get` itself only accepts string IDs (e.g., "75BjG5"). The integer is internal Revenium database metadata.

**How to avoid:** Instructions must explicitly say: "from the JSON response of `budget create --json`, extract the `"id"` field (a short alphanumeric string like `"75BjG5"`). This is the alertId. Store it in config.json as `alertId`."

**Warning signs:**
- Phase 3 budget guard calls fail with HTTP 400
- config.json contains a numeric value for alertId instead of a short alphanumeric string
- `revenium alerts budget get 1206` returns "Failed to decode hashed Id: [1206]"

### Pitfall 2: config.json Written Before `budget create` Runs

**What goes wrong:** Agent writes config.json right after `config set key`, before `budget create`. If `budget create` then fails (network error, invalid key), config.json exists but contains no alertId — or a placeholder. Phase 3's guard reads the empty/wrong config.json and calls `budget get` with bad data.

**Why it happens:** Agents executing multi-step instructions may write intermediate state to reduce the risk of "losing work." The locked decision (atomic setup) must be explicitly stated to prevent this.

**How to avoid:** SKILL.md must include: "ONLY write config.json as the FINAL step, after all other setup steps have succeeded. Do not write any partial state."

**Warning signs:**
- config.json exists but contains empty or missing alertId
- Budget guard fails immediately after setup

### Pitfall 3: Orphaned Budget Alerts on Reconfiguration

**What goes wrong:** Reconfiguration creates a new budget alert without deleting the old one. User accumulates multiple alerts in Revenium, each billing notification triggers separately, and budget tracking is confusing.

**Why it happens:** Simpler reconfiguration logic skips the delete step. CONTEXT.md locked decision explicitly requires delete-before-create.

**How to avoid:** Reconfiguration flow MUST call `revenium alerts budget delete {old-alertId} --yes` before running setup. The `--yes` flag skips the CLI confirmation prompt.

**Warning signs:**
- Multiple "OpenClaw * Budget" alerts visible in Revenium dashboard
- User receives duplicate budget notifications

### Pitfall 4: Agent Treats Setup as Optional When config.json Is Missing

**What goes wrong:** Agent has no config.json, is asked to do an operation, and proceeds without running setup (treating the missing config as a non-blocking warning).

**Why it happens:** SKILL.md instructions don't use strong enough mandatory language. Agent applies discretion and decides setup is optional for "harmless" operations.

**How to avoid:** The existing skeleton in SKILL.md already establishes MUST/STOP language. The Phase 2 content must maintain this tone. The instruction should say: "If {baseDir}/config.json does not exist, you MUST run the Setup Flow before proceeding. Do NOT execute any operations until setup is complete."

**Warning signs:**
- Agent runs operations and then mentions setup is needed afterward
- Budget enforcement silently absent for first few operations after install

### Pitfall 5: `config show` Output Parsed Programmatically

**What goes wrong:** Instructions tell agent to run `revenium config show --json` and parse API key presence. The command doesn't support `--json` — output is human-readable only.

**Why it happens:** Other CLI commands support `--json`; agent or author assumes `config show` does too.

**How to avoid:** Do not include any instruction to parse `config show` output. The locked decision already prohibits API key validation — there is no step where this would be needed.

**Warning signs:**
- Instructions reference `config show --json` or parsing of `config show` output
- Agent reports JSON parse errors during setup

## Code Examples

Verified against the revenium-cli binary (2026-03-14):

### Complete Setup Command Sequence

```bash
# Step 1: Configure API key
revenium config set key <API_KEY>
# Exit code 0 = success. No --json support. Do not parse output.

# Step 2: Create budget alert
revenium alerts budget create \
  --name "OpenClaw Monthly Budget" \
  --threshold 10 \
  --period MONTHLY \
  --json
# Returns full anomaly object JSON. Extract the "id" field (string).

# Step 3: Extract alertId from create response
# (If piped directly from create):
python3 -c "import json,sys; d=json.load(sys.stdin); print(d['id'])"
# Returns: "75BjG5" (example — actual value varies)

# Step 4: Write config.json (ONLY after all above succeed)
python3 -c "import json; print(json.dumps({'alertId': '75BjG5'}, indent=2))" \
  > ~/.openclaw/skills/revenium/config.json
```

### Budget Create JSON Response (verified via `budget update --json` which returns identical structure)

```json
{
  "id": "75BjG5",
  "alertType": "CUMULATIVE_USAGE",
  "name": "OpenClaw Monthly Budget",
  "threshold": 10,
  "periodDuration": "MONTHLY",
  "metricType": "TOTAL_COST",
  "enabled": true,
  "firing": false,
  ...
}
```

The `"id"` field is the alertId to store. It is a short base-62 string.

### Budget Get JSON Response (verified directly)

```json
{
  "anomalyId": 1206,
  "currentValue": 0.10832865,
  "metricType": "TOTAL_COST",
  "percentUsed": 0.10832865,
  "remaining": 0.89167135,
  "threshold": 1,
  "window": { ... }
}
```

Note: `anomalyId` here is an integer. DO NOT store this. It is internal metadata only. The ID to use with `budget get <id>` is the string `"id"` from create/list/update responses.

### Reconfiguration Sequence

```bash
# Read stored alertId from config
ALERT_ID=$(python3 -c "import json; d=json.load(open('~/.openclaw/skills/revenium/config.json')); print(d['alertId'])")

# Delete old alert (--yes skips confirmation prompt)
revenium alerts budget delete ${ALERT_ID} --yes

# Remove config file
rm ~/.openclaw/skills/revenium/config.json

# Then run full setup flow again
```

### config.json Format

```json
{
  "alertId": "75BjG5"
}
```

Single key, pretty-printed. Phase 3 will add `"graceMode"` key to this same file.

### Idempotency Check

```bash
# In SKILL.md instructions: check before any operation
test -f {baseDir}/config.json && echo "setup complete" || echo "setup needed"
```

### Period-to-Name Mapping

```
DAILY     → "OpenClaw Daily Budget"
WEEKLY    → "OpenClaw Weekly Budget"
MONTHLY   → "OpenClaw Monthly Budget"
QUARTERLY → "OpenClaw Quarterly Budget"
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Storing full CLI response in state file | Storing only the `alertId` string | CONTEXT.md decision | Minimal config.json; less brittle to schema changes |
| Separate config file in `~/.config/` | Co-located at `{baseDir}/config.json` | CONTEXT.md decision | Keeps skill self-contained; same directory as SKILL.md |
| Interactive confirmation during delete | `--yes` flag for non-interactive delete | Verified from binary help | Agent-driven flows must not require human prompts mid-execution |

**Deprecated/outdated:**
- Phase 1 RESEARCH.md noted `--period` flag was absent: CONFIRMED PRESENT in current binary. Flag exists with values DAILY, WEEKLY, MONTHLY, QUARTERLY and default MONTHLY.
- STACK.md suggested storing in `.env` file: CONTEXT.md locked decision overrides this — use `config.json`.

## Open Questions

1. **What does `budget create --json` return on failure?**
   - What we know: `budget update --json` returns the full anomaly object on success. Failure returns `{"error": "...", "status": N}` based on observed delete/get errors.
   - What's unclear: Whether create returns a structured error JSON or exits with a non-zero code and unstructured output when the API key is invalid.
   - Recommendation: Instructions should check exit code (non-zero = failure) rather than trying to parse error response. This is more reliable.

2. **Does `revenium alerts budget delete` return a parseable response?**
   - What we know: The command accepts `--yes` to skip confirmation. The `--json` flag is available globally.
   - What's unclear: Whether `delete --yes --json` returns `{}` or the deleted object or nothing.
   - Recommendation: For reconfiguration, the delete step only needs to succeed (exit code 0). No need to parse the response. Treat non-zero exit as "already deleted or not found" and continue — the goal is simply no orphan alerts.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Manual shell verification (no automated test framework — SKILL.md is markdown prose, not code) |
| Config file | None |
| Quick run command | `test -f ~/.openclaw/skills/revenium/config.json && python3 -c "import json; d=json.load(open('$HOME/.openclaw/skills/revenium/config.json')); assert 'alertId' in d and isinstance(d['alertId'], str) and len(d['alertId']) > 3; print('PASS')"` |
| Full suite command | See Phase Requirements Test Map below |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| SETUP-01 | Agent prompts for API key when no config.json exists | manual | Remove `~/.openclaw/skills/revenium/config.json`; start agent session; confirm agent asks for API key before any operation | Wave 0 (no file needed) |
| SETUP-02 | Agent runs `revenium config set key` successfully | smoke | `revenium config show` — confirms key is set by non-empty output | N/A (uses live CLI) |
| SETUP-03 | Agent prompts for budget amount | manual | Observe setup conversation; confirm amount is requested | N/A |
| SETUP-04 | Agent prompts for budget period (DAILY/WEEKLY/MONTHLY/QUARTERLY) | manual | Observe setup conversation; confirm period is requested with valid options | N/A |
| SETUP-05 | Budget alert created via `alerts budget create` with correct flags | smoke | `revenium alerts budget list --json \| python3 -c "import json,sys; alerts=[a for a in json.load(sys.stdin) if 'OpenClaw' in a['name']]; print('PASS' if alerts else 'FAIL')"` | N/A |
| SETUP-06 | config.json written with string alertId | smoke | `python3 -c "import json; d=json.load(open('$HOME/.openclaw/skills/revenium/config.json')); assert isinstance(d.get('alertId'), str) and len(d['alertId']) > 3; print('PASS')"` | Wave 0 |
| SETUP-07 | Re-running setup with existing config.json offers reconfigure instead of creating duplicate | smoke | Run setup twice; `revenium alerts budget list --json \| python3 -c "import json,sys; alerts=[a for a in json.load(sys.stdin) if 'OpenClaw' in a['name']]; print(f'Alert count: {len(alerts)}'); print('PASS' if len(alerts) == 1 else 'FAIL-DUPLICATE')"` | N/A |
| SETUP-08 | `/revenium` command triggers reconfiguration when requested | manual | Invoke `/revenium`; choose reconfigure; verify old alert deleted and new one created; verify config.json updated | N/A |

### Sampling Rate

- **Per task commit:** `test -f ~/.openclaw/skills/revenium/config.json && python3 -c "import json; d=json.load(open('$HOME/.openclaw/skills/revenium/config.json')); assert 'alertId' in d; print('config valid')" 2>&1`
- **Per wave merge:** Full suite — all automated checks above + manual observation of setup conversation
- **Phase gate:** config.json exists with valid string alertId, exactly one "OpenClaw * Budget" alert in Revenium dashboard, reconfiguration flow deletes old alert before `/gsd:verify-work`

### Wave 0 Gaps

- None — existing test infrastructure (manual shell verification) covers all phase requirements. No test files need to be created as a prerequisite. SKILL.md is the only artifact; its correctness is verified by running the agent through the setup flow.

## Sources

### Primary (HIGH confidence)

- `revenium-cli alerts budget create --help` — Direct binary introspection confirming `--period` flag with DAILY/WEEKLY/MONTHLY/QUARTERLY values (2026-03-14)
- `revenium-cli alerts budget list --json` — Live output confirming response structure: `alertId` (string), `name`, `cumulativePeriod`, `threshold` (2026-03-14)
- `revenium-cli alerts budget get <id> --json` — Live output confirming `anomalyId` (integer, NOT the ID to store), `currentValue`, `threshold`, `percentUsed`, `remaining` fields (2026-03-14)
- `revenium-cli alerts budget update <id> --threshold 1 --json` — Live output confirming create response structure: `"id"` field (string) is the alertId to store (2026-03-14)
- `.planning/phases/02-setup-flow/02-CONTEXT.md` — All locked decisions and constraints for this phase (2026-03-14)
- `.planning/phases/01-skill-scaffolding/01-RESEARCH.md` — Established patterns (MUST/STOP language, guard-first ordering) carried forward (2026-03-14)

### Secondary (MEDIUM confidence)

- `.planning/research/STACK.md` — CLI interface reference and config storage pattern options (2026-03-13)
- `.planning/research/PITFALLS.md` — Pitfalls including anomaly ID persistence, duplicate alert prevention, binary PATH resolution (2026-03-13)

### Tertiary (LOW confidence)

- None for this phase — direct binary introspection covers all critical unknowns at HIGH confidence.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — CLI commands verified against live binary; response formats observed from live API calls
- Architecture: HIGH — config.json location locked by CONTEXT.md; ID field naming discrepancy resolved by direct testing
- Pitfalls: HIGH — ID field trap confirmed by actual HTTP 400 error from integer ID; other pitfalls carry forward from Phase 1 research at HIGH/MEDIUM

**Research date:** 2026-03-14
**Valid until:** 2026-04-14 (30 days — CLI interface stable; ID field behavior verified against live API)
