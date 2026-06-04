# Phase 10: Tool Registry & Tool-Event Metering - Research

**Researched:** 2026-06-03
**Domain:** Shell + Python scripting, Revenium CLI metering, ledger-based idempotency
**Confidence:** HIGH (all CLI surface verified locally against `revenium 1.2.0`; JSONL structure confirmed against live session files; patterns extracted directly from canonical repo source)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01 (TOOLEV-03 — no double-counting):** Orthogonal coexistence. The existing `TOOL_CALL` completion record (`stopReason==toolUse` → `operation_type=TOOL_CALL`, ~line 847 of `report.sh`) captures **LLM inference cost** (tokens); a `tool-event` captures **tool execution** (duration / success). Both coexist. `report.sh`'s `operation_type` / completion path is **unchanged**.
- **D-02 (TOOLEV-01 — registry scope):** Dynamic first-seen. Register each distinct tool name as it is first observed in session `toolCall` entries — built-ins (e.g. `read`, `bash`, `edit`) and MCP tools (e.g. `mcp__server__tool`). Self-maintaining; no hand-curated list.
- **D-03 (TOOLEV-01/04 — registration lifecycle):** Lazy, in the cron report path. During `report.sh` cron tick, when a tool is seen for the first time (absent from registry ledger), register it via `revenium tools create` then meter its event. One pipeline, ledger-gated, fail-open. No separate setup-time registration step.
- **D-04 (TOOLEV-02 — granularity):** One tool-event per `toolCall` entry. Required fields supplied best-effort: `--duration-ms` from `toolCall`→`toolResult` timestamp delta (0 when unavailable), `--success` from tool-result `isError` flag (default `true` / pass `--success` flag when indeterminable), `--error-message` when `isError` is true. Missing fields never block emission (fail-open).
- **D-05 (attribution / idempotency — carry-forward):** Tool-events carry `--agent "openclaw-<root_session_id>"` using the same root-session resolution already in `report.sh`/`common.sh`. Idempotency uses the same ledger pattern as jobs/guardrail metering — a new registry ledger keyed per tool-id (register-once) and the reported-ledger discipline so a given `toolCall` is metered at-most-once across cron ticks. Fail-open is non-negotiable (TOOLEV-04).

### Claude's Discretion (resolve in research/planning)

- **Tool→agentic-job correlation:** `meter tool-event` has no `--agentic-job-id` flag. Research item: determine which field maps to "agentic job" for tool-events. Candidates are `--workflow-id`, `--usage-metadata` (JSON), or `--trace-id`. If none cleanly maps, attribution stops at `--agent` (root session) for v1.2.
- **`--tool-type` value + `--tool-id` normalization:** `--tool-type` is required; valid enum for built-ins unknown. Research item: confirm accepted `--tool-type` values; decide string for built-ins vs MCP tools. Derive stable, sanitized `--tool-id` from raw session tool names.
- **`--cost-usd`:** Lean omit — tools have no token cost.
- **Where the code lives:** Likely a fail-open helper in `report.sh` reusing `common.sh` constants; planner decides exact placement.

### Deferred Ideas (OUT OF SCOPE)

- Real per-tool cost (`--cost-usd`) — no cost source; revisit only if Revenium or OpenClaw surfaces per-tool cost.
- Tool-event-driven budget rules / enforcement — Phase 10 is observability-only.
- Backfilling tool-events for historical sessions — forward-looking from the cron pipeline only.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| TOOLEV-01 | Register agent tools in Revenium via `revenium tools create` | CLI surface verified: `--name`, `--tool-id`, `--tool-type` required. Registry ledger provides create-once idempotency (mirrors JOBS_LEDGER). |
| TOOLEV-02 | Meter tool invocations via `revenium meter tool-event` | CLI surface verified: `--tool-id`, `--duration-ms`, `--timestamp` required. Duration from `toolCall`→`toolResult` ts delta; `--success` flag maps to `toolResult.isError`. |
| TOOLEV-03 | No double-counting against existing TOOL_CALL completions | Architectural separation confirmed: `meter completion --operation-type TOOL_CALL` vs `meter tool-event` are different API paths (`/v2/api/completions` vs `/v2/tool/events`). Completion path untouched. |
| TOOLEV-04 | Fail-open + idempotency-gated against duplicate registrations/events | Registry ledger (create-once per tool-id) + reported-ledger (at-most-once per toolCall.id). All behind new `TOOLS_CLI_CAPABLE` probe. Pattern mirrors JOBS_CLI_CAPABLE in report.sh. |
</phase_requirements>

---

## Summary

Phase 10 extends `report.sh` with two new steps in the per-session loop: (1) tool registration — on first sight of a new tool name, call `revenium tools create` and write a registry ledger entry; (2) tool-event metering — for each `toolCall` content item in an assistant message, call `revenium meter tool-event`. Both operations are ledger-gated for idempotency, fully fail-open behind a new `TOOLS_CLI_CAPABLE` capability probe, and slot into the existing per-session loop after completion metering (so they can never delay or break it).

The JSONL structure is confirmed: `toolCall` items live in `.message.content[].type=="toolCall"` on assistant messages with `stopReason=="toolUse"`. Each has `.id` (the tool-call ID, used to find the matching `toolResult` via `toolResult.toolCallId`) and `.name` (the tool name). The corresponding `toolResult` message has `.message.isError` for success/failure and `.timestamp` for duration computation (delta from the parent assistant message timestamp).

The double-counting concern (TOOLEV-03) is a non-issue architecturally: `meter completion` posts to `/v2/api/completions` with `operationType`, while `meter tool-event` posts to `/v2/tool/events` — distinct API endpoints. The TOOL_CALL completion record captures inference tokens; the tool-event captures execution duration. The planner and verifier can confirm this by observing that both event types appear side-by-side in the Revenium dashboard with no deduplication.

**Primary recommendation:** Implement as two waves. Wave 0: test scaffolding — add `tests/test_report_tool_argv.sh` + extend `stub-revenium.sh` with `tools create` and `meter tool-event` switches. Wave 1: core implementation — new `TOOLS_CLI_CAPABLE` probe, new `TOOL_REGISTRY_LEDGER_FILE` constant in `common.sh`, new `_register_tool` + `_meter_tool_event` helpers in `report.sh`, invocation in the per-session `toolCall` scan loop.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Tool registry (create-once per tool) | Cron / report.sh | common.sh (ledger constant) | Registry ledger is a file on disk; tool creation is a Revenium API call — same tier as jobs create |
| Tool-event emission (per invocation) | Cron / report.sh | — | Emission happens in the existing per-session loop where toolCall entries are iterated |
| Idempotency / ledger dedup | Cron / report.sh | common.sh (constant definitions) | Two ledgers: registry ledger (one entry per tool-id) + existing reported-ledger (one TX: entry per toolCall.id) |
| TOOLS_CLI_CAPABLE probe | Cron / report.sh | — | One-time dual probe per tick, same as JOBS_CLI_CAPABLE; result cached as boolean |
| Root-session attribution | common.sh / get-root-session-id.py | report.sh (caller) | Already implemented; reused verbatim |
| Tool-id normalization | report.sh (inline Python) | — | Raw tool names (underscores, double-underscores) must be normalized to stable, URL-safe IDs |

---

## Standard Stack

No new external dependencies. All tools already available in the repo:

| Tool | Version | Purpose |
|------|---------|---------|
| `revenium` CLI | 1.2.0 (verified locally) | `tools create`, `meter tool-event` |
| `bash` | 3.2+ (macOS portability) | Script execution |
| `python3` | any (fail-open if absent) | Timestamp parsing, JSON, ledger helpers |
| `jq` | any | JSONL parsing in report.sh session loop |

**Installation:** No new packages. The only new CLI commands are already in `revenium 1.2.0`.

---

## Package Legitimacy Audit

Not applicable — no new packages are installed in this phase.

---

## Architecture Patterns

### System Architecture Diagram

```
cron tick
    |
    v
report.sh main()
    |
    +-- TOOLS_CLI_CAPABLE probe (one-time)
    |       revenium tools --help && meter tool-event --help | grep --tool-id
    |
    +-- for each session file:
    |       process_session()
    |           |
    |           +-- [existing] completion metering (UNCHANGED)
    |           |       meter completion --operation-type CHAT|TOOL_CALL
    |           |       TX:<id> >> reported.ledger
    |           |
    |           +-- [NEW] toolCall scan loop (AFTER completion metering)
    |                   for each line in session file:
    |                       for each .message.content[].type=="toolCall" item:
    |                           tool_name = item.name
    |                           tool_id   = normalize(tool_name)
    |                           tool_type = classify(tool_name)  # MCP_SERVER | BUILTIN
    |                           |
    |                           +-- _register_tool (if not in registry ledger)
    |                           |       revenium tools create --name --tool-id --tool-type
    |                           |       TOOL:<tool_id> >> registry.ledger
    |                           |
    |                           +-- _meter_tool_event (if toolCall.id not in reported ledger)
    |                                   duration = toolResult.timestamp - parent_msg.timestamp
    |                                   success  = !toolResult.isError
    |                                   revenium meter tool-event \
    |                                       --tool-id --duration-ms --success \
    |                                       --timestamp --agent [--error-message]
    |                                   TX:TOOLEV:<toolcall_id> >> reported.ledger
    |
    +-- [existing] handle_halt()  (UNCHANGED)
```

### Recommended Project Structure

```
scripts/
├── common.sh           # ADD: TOOL_REGISTRY_LEDGER_FILE constant
├── report.sh           # ADD: TOOLS_CLI_CAPABLE probe, _register_tool,
│                       #      _meter_tool_event, toolCall scan loop
└── (other scripts unchanged)
tests/
├── test_report_tool_argv.sh   # NEW: tool registry + tool-event emission tests
└── stub-revenium.sh           # EXTEND: tools create + meter tool-event switches
```

### Pattern 1: TOOLS_CLI_CAPABLE Capability Probe (mirrors JOBS_CLI_CAPABLE)

**What:** One-time dual probe per cron tick. If either check fails, all tool work is skipped and metering continues as v1.1.

**When to use:** At script startup in `report.sh`, before `main()`.

```bash
# Source: report.sh lines 1244-1250 (JOBS_CLI_CAPABLE pattern)
TOOLS_CLI_CAPABLE=false
if revenium tools --help >/dev/null 2>&1 && \
   revenium meter tool-event --help 2>&1 | grep -q -- '--tool-id'; then
  TOOLS_CLI_CAPABLE=true
else
  warn "revenium tools/meter tool-event not available — tool work skipped; metering continues as v1.1."
fi
```

[VERIFIED: live revenium 1.2.0 CLI — `tools --help` exits 0, `meter tool-event --help` contains `--tool-id`]

### Pattern 2: Tool-ID Normalization

**What:** Raw tool names from session JSONL must be normalized to stable, URL-safe `--tool-id` values. The CLI accepts alphanumeric characters, underscores, and hyphens in `--tool-id`.

**Normalization rule (confirmed with `--dry-run`):**
- Replace `__` (double-underscore, MCP separator) with `--`
- Replace `_` (single-underscore) with `-`
- All lowercase
- Verified: `web_fetch` → `web-fetch`, `sessions_spawn` → `sessions-spawn`, `mcp__ctx7__search` → `mcp--ctx7--search`

```bash
# Source: verified via `revenium tools create --dry-run` against tool names from live sessions
normalize_tool_id() {
  local raw="$1"
  # Replace __ with -- first (MCP server separator), then _ with -
  local normalized="${raw//__/--}"
  normalized="${normalized//_/-}"
  # Lowercase (bash 4+ only: ${var,,}; use python3 for portability)
  TOOL_NAME="${normalized}" python3 -c "import os; print(os.environ['TOOL_NAME'].lower())" 2>/dev/null \
    || printf '%s' "${normalized}"
}
```

**Note:** Bash `${var,,}` for lowercase requires bash 4+. macOS ships bash 3.2; use python3 for portability (consistent with existing codebase pattern).

### Pattern 3: --tool-type Classification

**What:** `--tool-type` is required by `revenium tools create`. The CLI documents `MCP_SERVER` but accepts any string (verified: `BUILTIN`, `CLI_TOOL`, `FUNCTION` all pass `--dry-run`).

**Decision for built-ins vs MCP tools:**
- MCP tool names contain `__` (double-underscore) by OpenClaw convention: e.g., `mcp__context7__resolve-library-id`
- Built-in Claude Code tools: `read`, `write`, `edit`, `bash`, `exec`, `web_fetch`, `sessions_spawn`, etc.
- **Recommended:** `MCP_SERVER` for names containing `__`; `BUILTIN` for all others

```bash
classify_tool_type() {
  local name="$1"
  if [[ "${name}" == *"__"* ]]; then
    echo "MCP_SERVER"
  else
    echo "BUILTIN"
  fi
}
```

[VERIFIED: `--dry-run` confirms `BUILTIN` and `MCP_SERVER` both accepted without error by revenium 1.2.0]
[ASSUMED: `BUILTIN` is the semantically correct enum for built-in Claude Code tools — CLI help only documents `MCP_SERVER` as example; server-side enum list not inspected]

### Pattern 4: Registry Ledger — Create-Once Idempotency (mirrors JOBS_LEDGER)

**What:** Append-only file. One line per registered tool-id. Keyed `TOOL:<tool_id>`.

```bash
# Ledger constant in common.sh (mirrors GUARDRAIL_LEDGER_FILE / JOBS_LEDGER_FILE)
TOOL_REGISTRY_LEDGER_FILE="${OPENCLAW_HOME}/revenium-tools.ledger"

# _register_tool — idempotent, fail-open (mirrors jobs create, report.sh lines 777-806)
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

### Pattern 5: Tool-Event Emission — At-Most-Once per toolCall.id

**What:** Each `toolCall` content item in an assistant message maps to one `meter tool-event` call. Idempotency key: `TOOLEV:<toolcall_id>` in the reported ledger (same `LEDGER_FILE` as completions, or a prefix-namespaced key in it).

**Duration computation:** `toolCall.id` (on the content item) matches `toolResult.message.toolCallId` (on the following toolResult message). Timestamps: parent assistant message `.timestamp` (start) to toolResult message `.timestamp` (end). Delta = duration-ms. Use 0 when the toolResult is not found.

**Success field:** `meter tool-event --success` is a boolean flag — pass `--success` when `isError==false`, omit (defaults to `false`) or pass `--success=false` when `isError==true`. The CLI defaults to `success:false` when `--success` is not specified — **always explicitly pass `--success` or `--success=false`** to avoid ambiguity.

```bash
# _meter_tool_event — one per toolCall.id, ledger-gated, fail-open
_meter_tool_event() {
  local toolcall_id="$1"
  local tool_id="$2"
  local ts="$3"          # ISO timestamp (from parent assistant message)
  local duration_ms="$4" # integer, may be 0
  local is_error="$5"    # "true" | "false"
  local error_msg="$6"   # may be empty
  local root_sid="$7"

  local ledger_key="TOOLEV:${toolcall_id}"
  if grep -qF "${ledger_key}" "${LEDGER_FILE}" 2>/dev/null; then
    return 0  # already metered — idempotent skip
  fi

  local ev_cmd=( revenium meter tool-event
    --tool-id     "${tool_id}"
    --duration-ms "${duration_ms}"
    --timestamp   "${ts}"
    --agent       "${REVENIUM_AGENT_PREFIX}${root_sid}"
    --quiet
  )
  # success defaults to false in CLI — always explicit
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
    printf '%s\n' "${ledger_key}" >> "${LEDGER_FILE}"
    info "Tool event metered: tool_id=${tool_id} duration=${duration_ms}ms"
  else
    warn "Tool event failed: id=${tool_id} toolcall=${toolcall_id} exit=${ev_exit} — fail-open"
  fi
  return 0
}
```

[VERIFIED: `revenium meter tool-event --dry-run` confirmed: `--duration-ms 0` accepted; `--success` flag sets `success:true`; omitting `--success` sets `success:false`; `--error-message`, `--agent`, `--organization-name` all accepted. revenium 1.2.0 locally]

### Pattern 6: toolCall Scan Loop Location

**What:** The `toolCall` scan runs AFTER the existing completion metering loop. In `process_session()`, after the `while IFS= read -r line` completion loop closes, add a second pass over the session file extracting `toolCall` content items.

**Parsing approach (Python heredoc, Bash 3.2 safe):**

The existing session loop iterates line-by-line checking for assistant messages with usage data. Tool calls need a separate extraction pass because:
- A single assistant message may contain multiple `toolCall` items (parallel tool use)
- The `toolResult` messages are separate JSONL lines (need cross-line lookup)
- Duration computation requires matching `toolCall.id` → `toolResult.toolCallId`

```bash
# Extract all toolCall items from a session file (Python heredoc, env-passing discipline)
# Output: TAB-separated: toolcall_id, tool_name, parent_msg_ts, result_ts, is_error, error_msg
SESSION_FILE="${session_file}" python3 - <<'PY' 2>/dev/null || true
import json, os
sf = os.environ.get('SESSION_FILE', '')
tool_calls = {}  # toolcall_id -> {name, parent_msg_ts, parent_msg_id}
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
                    tool_results[tc_id] = {
                        'result_ts': r.get('timestamp', ''),
                        'is_error': 'true' if msg.get('isError') else 'false',
                        'error_msg': '',
                    }
                    # Extract error text from content if isError
                    if msg.get('isError'):
                        for c in msg.get('content', []):
                            if c.get('type') == 'text':
                                tool_results[tc_id]['error_msg'] = c.get('text', '')[:256]
                                break
except Exception:
    pass
for tc_id, tc in tool_calls.items():
    tr = tool_results.get(tc_id, {})
    print(f"{tc_id}\t{tc['name']}\t{tc['parent_msg_ts']}\t{tr.get('result_ts','')}\t{tr.get('is_error','false')}\t{tr.get('error_msg','')}")
PY
```

[VERIFIED: toolCall/toolResult linkage pattern confirmed against live session file `1a491f30`: `toolCall.id` == `toolResult.message.toolCallId`]

### Pattern 7: Tool→Job Correlation (Claude's Discretion — resolved here)

**What:** `meter tool-event` has no `--agentic-job-id`. Available correlation fields:
- `--workflow-id string` — workflow identifier
- `--trace-id string` — distributed trace identifier
- `--usage-metadata string` — JSON object

**Verified (dry-run):** `--workflow-id` maps to `workflowId` in the API payload body; `--trace-id` maps to `traceId`. Neither is labeled "agentic job" in the CLI help text.

**Recommendation (v1.2):** Omit job correlation for tool-events. Attribution stops at `--agent openclaw-<root_sid>`. Rationale: the Revenium dashboard does not currently display tool-events under agentic jobs (per the CONTEXT.md note "no `--agentic-job-id` flag"), and fabricating a `--workflow-id` from the job ID without confirmation from the API owner could produce misleading rollup. The `--agent` attribution is sufficient for per-agent tool visibility in v1.2.

**If future exploration:** `--workflow-id` with the open `agentic_job_id` from the jobs ledger is the most natural candidate. Verify server-side rendering before adopting.

[ASSUMED: Revenium server does not map `--workflow-id` to "agentic job" rollup automatically — not verified from official documentation]

### Anti-Patterns to Avoid

- **Scanning for toolCall before completion metering:** Tool work must always run AFTER the completion metering loop so a tool-work failure can never block completion records from being written. This is the same sequencing rule as `handle_halt()` after the session loop.
- **Using `success:false` by default:** The `meter tool-event --success` flag defaults to `false` when omitted. Always pass `--success` explicitly to avoid every tool-event appearing failed.
- **Single loop over completions trying to also extract toolCalls:** The completion loop processes assistant messages that have `usage` data. Not every toolUse message has both usage and toolCall items in the correct position for a simple inline check. A second dedicated extraction pass (or a Python heredoc over the full file) is cleaner and matches the existing markers/jobs extraction pattern.
- **Storing toolCall events in a separate ledger from completions:** Using a ledger-key prefix (`TOOLEV:<id>`) in the existing `LEDGER_FILE` (or `TOOL_REGISTRY_LEDGER_FILE` for registrations) is simpler than adding a third ledger file. The reported-ledger already deduplicates TX: entries by message ID; TOOLEV: prefixed entries in the same file work identically.
- **Bash `${var,,}` for lowercasing:** Requires bash 4+. macOS has bash 3.2. Use `python3` env-heredoc for lowercase (existing codebase pattern).

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Tool registration dedup | Custom file-format registry | Append-only ledger + `grep -qF` (exact mirror of jobs create pattern) | Already proven in 9+ phases; edge cases handled |
| Duration computation | String-split timestamps | Python `datetime.fromisoformat` + env-passing heredoc | Millisecond precision; timezone-aware; same WR-02 fix already in report.sh |
| JSON error text extraction | Bash string parsing | Python `json.loads` in heredoc | Handles nested content arrays, escaping |
| Tool-type enum validation | Manual allowlist | Derive from name pattern (`__` = MCP) | CLI accepts any string; classification is best-effort; no server-side rejection observed |

**Key insight:** Every new operation in this phase has an exact structural analog already in `report.sh`. Copy-then-adapt beats from-scratch. The risk is drifting from the established argv-array discipline and env-passing heredoc pattern — the plan must enforce parity.

---

## Runtime State Inventory

> Not applicable — this phase is additive (new code + new ledger files). No rename, refactor, or migration involved. New ledger files (`revenium-tools.ledger`) are created fresh; no existing data migrated.

---

## Common Pitfalls

### Pitfall 1: Idempotency Key Collision Between Completions and Tool-Events

**What goes wrong:** A `toolCall.id` (e.g. `toolu_01Dmj7ucA4CbvpAmC9y3aL7h`) has a different format from a completion message `.id` (e.g. `4f01ff0d`). But if both share the same reported ledger and one stores `TX:4f01ff0d` while the other stores `TX:toolu_...`, there is no collision risk. However, if the same raw `.id` is used for both (hypothetically), they would incorrectly deduplicate each other.

**How to avoid:** Prefix tool-event ledger keys with `TOOLEV:` (not `TX:`). Completion keys stay `TX:<msg_id>`. These are never the same ID.

**Warning signs:** Tool-events not appearing in Revenium after the first run, but completions still appearing correctly.

### Pitfall 2: --success Defaults to false

**What goes wrong:** Omitting `--success` from `meter tool-event` causes the API to record `success:false` for every tool call, even successful ones. Confirmed via `--dry-run`: without `--success`, the body shows `success:false`.

**How to avoid:** Always explicitly pass either `--success` (for successful calls) or `--success=false` (for failed ones). Derive from `toolResult.message.isError`.

**Warning signs:** All tool-events in Revenium dashboard show failure status.

### Pitfall 3: Multiple toolCall Items in One Assistant Message

**What goes wrong:** An assistant message with `stopReason==toolUse` can contain multiple `toolCall` items in its `.message.content[]` array (parallel tool use). A loop that processes only the first item or treats each line as one tool call will miss subsequent items.

**How to avoid:** The toolCall extraction pass must iterate `.message.content[]` and collect ALL items where `type=="toolCall"`. The Python heredoc approach handles this naturally.

**Warning signs:** Fewer tool-events emitted than expected for parallel-tool sessions.

### Pitfall 4: toolResult Linkage via toolCallId, Not parentId

**What goes wrong:** The `toolResult` message's `.parentId` points to the assistant message that triggered the tool (not uniquely to the tool call). The correct link is `toolCall.id` == `toolResult.message.toolCallId`. Using parentId for lookup produces incorrect duration computation when multiple tool calls are in the same message.

**How to avoid:** Build a `tool_results` map keyed on `toolCallId`, not on parentId. Confirmed pattern from live session data.

**Warning signs:** Wrong durations (all the same); missing tool-results for parallel tool calls.

### Pitfall 5: Bash 3.2 Portability — ${var,,} Lowercase

**What goes wrong:** Using `${tool_name,,}` for lowercase works in bash 4+ (Linux) but fails silently or errors on macOS (bash 3.2). Tool names in lowercase are important for stable `--tool-id` normalization.

**How to avoid:** Use python3 with env-passing heredoc: `TOOL_NAME="${raw}" python3 -c "import os; print(os.environ['TOOL_NAME'].lower())"`. This is consistent with existing codebase pattern (T-04-09).

### Pitfall 6: Fail-Open Sequencing — Tool Work After Completion Record

**What goes wrong:** If tool registration or tool-event emission runs BEFORE the completion is ledger-stamped, a tool-work failure could prevent the completion from being retried on the next tick (the offset would advance past it).

**How to avoid:** Tool work runs AFTER `post_to_revenium` succeeds and `TX:<id>` is written to the ledger. Tool work failures use their own `warn` + `return 0` pattern (same as jobs outcome). The `failed_count` / `reported_count` counters used to gate `set_offset` are NEVER touched by tool work.

---

## CLI Surface (Verified Against revenium 1.2.0 Locally)

### `revenium tools create`

```
Required: --name string, --tool-id string, --tool-type string
Optional: --description string, --tool-provider string, --enabled
Global:   --quiet, --dry-run, --organization-name (via --organization-name)
```

**Verified `--tool-type` values (via `--dry-run`):** `MCP_SERVER`, `BUILTIN`, `CLI_TOOL`, `FUNCTION` — all accepted without error. CLI help only documents `MCP_SERVER` as example.

**API path:** `/v2/api/tools` (confirmed via `--dry-run` output)

**Idempotency:** No `--transaction-id` field. 409 conflict response expected when tool-id already exists (same backstop as `jobs create`). Use `grep -qi "409\|already.exist\|conflict"` on stderr.

```bash
# Minimal invocation (verified via --dry-run, revenium 1.2.0)
revenium tools create --name "bash" --tool-id "bash" --tool-type BUILTIN --quiet
# Dry-run output: Body: map[name:bash toolId:bash toolType:BUILTIN]
```

[VERIFIED: revenium 1.2.0, local machine, 2026-06-03]

### `revenium meter tool-event`

```
Required: --tool-id string, --duration-ms int, --timestamp string (ISO 8601)
Optional: --success (boolean flag; defaults false when omitted)
          --agent string
          --error-message string
          --trace-id string
          --transaction-id string
          --workflow-id string
          --usage-metadata string (JSON)
          --organization-name string
          --product-name string
          --subscriber-credential string
          --operation string
          --cost-usd float64
Global:   --quiet, --dry-run
```

**CRITICAL:** `--success` is a boolean flag. Default when omitted = `false`. Always pass explicitly.

**API path:** `/v2/tool/events` (confirmed via `--dry-run` output)

**Zero duration:** `--duration-ms 0` accepted without error.

```bash
# Successful tool event (verified via --dry-run, revenium 1.2.0)
revenium meter tool-event --tool-id "read" --duration-ms 16 --success \
  --timestamp "2026-06-03T10:00:00Z" --agent "openclaw-abc123" --quiet
# Body: map[agent:openclaw-abc123 durationMs:16 success:true timestamp:... toolId:read]

# Failed tool event
revenium meter tool-event --tool-id "bash" --duration-ms 5000 --success=false \
  --error-message "connection refused" --timestamp "2026-06-03T10:00:00Z" --quiet
# Body: map[durationMs:5000 errorMessage:connection refused success:false timestamp:... toolId:bash]
```

[VERIFIED: revenium 1.2.0, local machine, 2026-06-03]

---

## Session JSONL Structure (toolCall/toolResult)

**Confirmed from live session files on this machine:**

```json
// Assistant message with toolCall content (stopReason=="toolUse"):
{
  "type": "message",
  "id": "4f01ff0d",                    // parent message ID — NOT the toolCall ID
  "parentId": "15cbb6ce",
  "timestamp": "2026-06-02T08:03:28.675Z",   // START timestamp for duration
  "message": {
    "role": "assistant",
    "content": [
      {"type": "thinking", ...},
      {
        "type": "toolCall",
        "id": "toolu_01Dmj7ucA4CbvpAmC9y3aL7h",   // THE toolCall ID
        "name": "read",
        "arguments": {"file_path": "/tmp/x"}
      }
    ],
    "stopReason": "toolUse",
    "usage": {"input": 3, "output": 107, "cacheRead": 0, ...}
  }
}

// Tool result message (separate JSONL line):
{
  "type": "message",
  "id": "eb6037a8",
  "parentId": "4f01ff0d",             // parent = the assistant message above
  "timestamp": "2026-06-02T08:03:28.691Z",   // END timestamp for duration
  "message": {
    "role": "toolResult",
    "toolCallId": "toolu_01Dmj7ucA4CbvpAmC9y3aL7h",  // LINKS to toolCall.id above
    "toolName": "read",
    "isError": false,                  // false = success
    "content": [{"type": "text", "text": "..."}]
  }
}
```

**Duration formula:** `toolResult.timestamp - parentAssistantMsg.timestamp` (milliseconds)

**isError → success mapping:**
- `isError: false` → pass `--success` flag
- `isError: true` → pass `--success=false` + `--error-message`
- toolResult not found (race / missing) → pass `--success` (D-04: "default true when indeterminable")

**Tool names observed in local sessions:** `read`, `write`, `edit`, `exec`, `browser`, `web_fetch`, `agents_list`, `sessions_list`, `sessions_spawn`, `session_status`, `memory_search`, `message`, `process`, `cron`

[VERIFIED: live session file `~/.openclaw/agents/main/sessions/1a491f30-b7cf-4c08-b541-ad8c6ac0c6a2.jsonl`]

---

## Code Examples

### toolCall Extraction + Duration Computation (complete pattern)

```python
# Source: derived from live session JSONL analysis + existing report.sh Python heredoc discipline
# Session file passed via env (T-04-09: never interpolate file paths into <<'PY')
SESSION_FILE="${session_file}" python3 - <<'PY' 2>/dev/null || true
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

# First pass: collect toolCall items and toolResult messages
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

# Output: TAB-separated per toolCall item
for tc_id, tc in tool_calls.items():
    tr = tool_results.get(tc_id, {})
    start_ts = parse_ts(tc['parent_msg_ts'])
    end_ts = parse_ts(tr.get('result_ts', ''))
    duration_ms = 0
    if start_ts and end_ts:
        duration_ms = max(0, int((end_ts - start_ts).total_seconds() * 1000))
    print('{}\t{}\t{}\t{}\t{}\t{}'.format(
        tc_id,
        tc['name'],
        tc['parent_msg_ts'],
        duration_ms,
        tr.get('is_error', 'false'),
        tr.get('error_msg', ''),
    ))
PY
```

### Registry Ledger Constant (common.sh addition)

```bash
# Source: common.sh Phase 9 pattern (lines 59-64)
# Phase 10 path constant (TOOLEV-01/04).
# TOOL_REGISTRY_LEDGER_FILE: append-only dedup ledger for tool registration.
#   Key format: TOOL:<tool_id>:<unix_ts>
TOOL_REGISTRY_LEDGER_FILE="${OPENCLAW_HOME}/revenium-tools.ledger"
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| No tool observability | `meter tool-event` per invocation | Phase 10 (v1.2) | Per-tool usage (count, duration, success) visible in Revenium |
| No tool registry | `revenium tools create` on first sight | Phase 10 (v1.2) | Tools appear in Revenium tool registry |
| TOOL_CALL completion = only tool signal | TOOL_CALL completion + tool-event = complementary signals | Phase 10 (v1.2) | Inference cost and execution cost are now separately observable |

**Deprecated/outdated:** None in this phase. The TOOL_CALL completion path is explicitly preserved unchanged (D-01).

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `BUILTIN` is the semantically correct `--tool-type` for Claude Code built-in tools (read, edit, bash, etc.) | Pattern 3 | Server may reject unknown type or misclassify; fall back to `MCP_SERVER` for all if BUILTIN is rejected |
| A2 | Revenium server does not map `--workflow-id` to "agentic job" rollup for tool-events | Pattern 7 | Tool-events remain unlinked to jobs in Revenium dashboard; future phase needed to add correlation |
| A3 | The 409 conflict response format for `tools create` matches the jobs create pattern (contains "409", "already exist", or "conflict") | Pattern 4 | Registry ledger dedup prevents re-sending, but 409-as-success backstop may not fire; tool still registered on server |
| A4 | `revenium tools create` accepts the same `--organization-name` global flag available on `meter tool-event` | Pattern 4 | Organization scoping silently omitted; tools registered globally |

**If this table is empty:** Not applicable — 4 assumptions documented above.

---

## Open Questions

1. **Does `--workflow-id` on `meter tool-event` cause Revenium to roll tool-events up under the agentic job in the dashboard?**
   - What we know: The CLI accepts `--workflow-id`; it maps to `workflowId` in the API payload. The `meter completion` path uses `--agentic-job-id` (a distinct field). No CLI flag named `--agentic-job-id` exists on `meter tool-event`.
   - What's unclear: Whether the Revenium server equates `workflowId` with `agenticJobId` for rollup, or whether they are independent dimensions.
   - Recommendation: Omit for v1.2 and document as a follow-on. If stakeholder wants job rollup for tool-events, test `--workflow-id <agentic_job_id>` on the live host first.

2. **Does a `TOOLEV:<toolcall_id>` key in the reported ledger (`LEDGER_FILE`) interact correctly with the offset-advance gate (CR-02)?**
   - What we know: CR-02 gates `set_offset` on `failed_count == 0`. Tool-event failures must never increment `failed_count`.
   - What's unclear: Whether the planner should keep tool-event keys in `LEDGER_FILE` or use a separate file.
   - Recommendation: Use a separate `TOOL_EVENTS_LEDGER_FILE` (analogous to `TOOL_REGISTRY_LEDGER_FILE`) to avoid any coupling with the offset gate. The completion ledger's CR-02 gate is well-tested; adding tool-event keys could confuse future readers.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `revenium` CLI | All operations | ✓ | 1.2.0 | Skip all tool work (existing guard at line 96) |
| `revenium tools --help` | TOOLS_CLI_CAPABLE probe | ✓ | 1.2.0 | TOOLS_CLI_CAPABLE=false, skip tool work |
| `revenium meter tool-event --help` | TOOLS_CLI_CAPABLE probe | ✓ | 1.2.0 | TOOLS_CLI_CAPABLE=false, skip tool work |
| `python3` | Timestamp parsing, normalization | ✓ (assumed — existing dependency) | 3.x | Duration=0, no lowercase normalization |
| `jq` | Session JSONL parsing | ✓ (existing dependency) | any | Skip (existing guard at line 101) |

**Missing dependencies with no fallback:** None.

**Missing dependencies with fallback:** All dependencies have fallbacks via existing guards or fail-open behavior.

[VERIFIED: `revenium 1.2.0` installed at `/opt/homebrew/bin/revenium` on this machine; `tools --help` and `meter tool-event --help` both exit 0]

---

## Validation Architecture

> `nyquist_validation: true` in `.planning/config.json` — section required.

### Test Framework

| Property | Value |
|----------|-------|
| Framework | bash integration tests (existing pattern) |
| Config file | none — tests are standalone bash scripts in `tests/` |
| Quick run command | `bash tests/test_report_tool_argv.sh` |
| Full suite command | `bash tests/test_report_argv.sh && bash tests/test_report_jobs_argv.sh && bash tests/test_guardrail_argv.sh && bash tests/test_report_tool_argv.sh` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| TOOLEV-01 | Tool registered via `revenium tools create` with correct `--name`, `--tool-id`, `--tool-type` on first sight of new tool | integration | `bash tests/test_report_tool_argv.sh` | ❌ Wave 0 |
| TOOLEV-01 | Tool NOT re-registered on second cron tick (registry ledger dedup) | integration | `bash tests/test_report_tool_argv.sh` | ❌ Wave 0 |
| TOOLEV-02 | `meter tool-event` emitted with correct `--tool-id`, `--duration-ms`, `--success`, `--agent`, `--timestamp` | integration | `bash tests/test_report_tool_argv.sh` | ❌ Wave 0 |
| TOOLEV-02 | Zero duration accepted when toolResult not found | integration | `bash tests/test_report_tool_argv.sh` | ❌ Wave 0 |
| TOOLEV-02 | Failed tool call: `--success=false` + `--error-message` emitted | integration | `bash tests/test_report_tool_argv.sh` | ❌ Wave 0 |
| TOOLEV-03 | Completion metering still emitted (TOOL_CALL / CHAT) when tool work runs | integration | `bash tests/test_report_tool_argv.sh` | ❌ Wave 0 |
| TOOLEV-03 | `meter completion` NOT modified (no new flags, no new operation-type) | integration | `bash tests/test_report_tool_argv.sh` | ❌ Wave 0 |
| TOOLEV-04 | TOOLS_CLI_CAPABLE=false when probe fails: no `tools create` or `meter tool-event` calls | integration | `bash tests/test_report_tool_argv.sh` | ❌ Wave 0 |
| TOOLEV-04 | Tool-event failure does NOT increment `failed_count` or block offset advance | integration | `bash tests/test_report_tool_argv.sh` | ❌ Wave 0 |
| TOOLEV-04 | Tool-event NOT re-emitted on second cron tick (ledger dedup) | integration | `bash tests/test_report_tool_argv.sh` | ❌ Wave 0 |

### Test Strategy

The test follows the exact structure of `test_guardrail_argv.sh`:

1. Build a `tmp OPENCLAW_HOME` with:
   - A session JSONL file containing at least one assistant message with `toolCall` content + corresponding `toolResult` message
   - An empty `revenium-tools.ledger`
   - The existing `revenium-reported.ledger`
   - `config.json` with `organizationName`
2. Place `stub-revenium.sh` on PATH (captures all argv to `STUB_REVENIUM_ARGV_FILE`)
3. Extend `stub-revenium.sh` with:
   - `tools create` → exit 0 (success)
   - `tools --help` → exit 0 (probe passes)
   - A `STUB_REVENIUM_NO_TOOLS=1` switch: `tools --help` exits 1 (probe fails → TOOLS_CLI_CAPABLE=false)
   - A `STUB_REVENIUM_TOOLS_FAIL=1` switch: `tools create` exits 1, non-409 (fail-open test)
   - `meter tool-event` → exit 0 (already exit 0 via default fallthrough, but should be explicit)
4. Run `report.sh` with `OPENCLAW_HOME=<tmp>`
5. Assert captured argv contains:
   - `tools create` with `--name read --tool-id read --tool-type BUILTIN`
   - `meter tool-event` with `--tool-id read --agent openclaw-<root_sid> --success`
   - `meter completion` still present (TOOLEV-03)
6. Run again (second tick): assert `tools create` NOT called again (ledger dedup)

### Session Fixture for Tests

```json
{"type":"session","version":3,"id":"test-tool-sid-001","timestamp":"2026-01-01T10:00:00.000Z","cwd":"/tmp"}
{"type":"message","id":"user-001","parentId":"00000000","timestamp":"2026-01-01T10:01:00.000Z","message":{"role":"user","content":[{"type":"text","text":"Use the read tool"}]}}
{"type":"message","id":"asst-001","parentId":"user-001","timestamp":"2026-01-01T10:01:05.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"toolu_test001","name":"read","arguments":{"file_path":"/tmp/x"}}],"stopReason":"toolUse","model":"claude-sonnet-4-6","api":"anthropic-messages","provider":"anthropic","usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":150}}}
{"type":"message","id":"result-001","parentId":"asst-001","timestamp":"2026-01-01T10:01:05.250Z","message":{"role":"toolResult","toolCallId":"toolu_test001","toolName":"read","isError":false,"content":[{"type":"text","text":"file contents"}]}}
{"type":"message","id":"asst-002","parentId":"result-001","timestamp":"2026-01-01T10:01:06.000Z","message":{"role":"assistant","content":[{"type":"text","text":"Done"}],"stopReason":"stop","model":"claude-sonnet-4-6","api":"anthropic-messages","provider":"anthropic","usage":{"input":200,"output":30,"cacheRead":150,"cacheWrite":0,"totalTokens":380}}}
```

This fixture produces: one TOOL_CALL completion (asst-001), one CHAT completion (asst-002), one tool registration (read/BUILTIN), and one tool-event (toolu_test001, 250ms duration, success=true).

### Sampling Rate

- **Per task commit:** `bash tests/test_report_tool_argv.sh`
- **Per wave merge:** full suite (all `test_*.sh` files)
- **Phase gate:** Full suite green before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `tests/test_report_tool_argv.sh` — covers TOOLEV-01..04
- [ ] `tests/stub-revenium.sh` — add `tools create`, `tools --help`, `STUB_REVENIUM_NO_TOOLS`, `STUB_REVENIUM_TOOLS_FAIL` switches
- [ ] Session fixture for tool-call test (inline in test script, following existing pattern)

---

## Security Domain

> `security_enforcement` absent from config — treated as enabled.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | n/a — CLI uses pre-configured API key |
| V3 Session Management | no | n/a |
| V4 Access Control | no | n/a — skill runs as the user |
| V5 Input Validation | yes | Tool names from session JSONL must be sanitized before use in ledger keys and CLI args |
| V6 Cryptography | no | n/a |

### Known Threat Patterns for Shell/CLI Stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Tool name injection via crafted session JSONL | Tampering | Sanitize tool names before CLI args (strip `:`, `|`, newlines — same `sanitize()` pattern as write-job-marker.sh); pass as argv array elements, never string-interpolate |
| Ledger injection via malformed tool-id | Tampering | 64-char truncation + character sanitization on ledger key (same pattern as agentic_job_id log truncation, report.sh line 742) |
| Log injection via error message | Tampering | 256-char truncation on `--error-message` value (never interpolated into log template; passed as argv element) |
| Double-emission via race on cron flock | Repudiation | Existing cron.sh flock (`LOCK_FILE`) prevents concurrent ticks; ledger dedup prevents within-tick double-emission |

**Established controls to reuse:**
- Argv-array discipline: `cmd+=(--flag "${value}")` — never `eval` or string-join (T-04-09 / V5, already in report.sh)
- Env-passing heredoc: `VAR="${val}" python3 - <<'PY'` — prevents bash expansion of untrusted content inside heredocs (T-04-09, already in report.sh)
- 64-char log truncation: `"${var:0:64}"` before any `info`/`warn` call with untrusted IDs (T-04-08, already in report.sh)

---

## Sources

### Primary (HIGH confidence)

- `scripts/report.sh` (live codebase) — JOBS_CLI_CAPABLE probe pattern (lines 1244-1250), `post_to_revenium` argv-array discipline (lines 239-315), jobs create/outcome ledger pattern (lines 777-806, 940-982), `process_session` structure
- `scripts/common.sh` (live codebase) — path constants, GUARDRAIL_LEDGER_FILE, JOBS_LEDGER_FILE, REVENIUM_AGENT_PREFIX, get_root_session_id
- `scripts/guardrail-check.sh` (live codebase) — `_emit_guardrail_event` pattern (lines 533-603), ledger dedup, fail-open Section M
- `revenium 1.2.0 CLI` (local, `/opt/homebrew/bin/revenium`) — `tools create --help`, `meter tool-event --help`, `--dry-run` verification of payload shapes and defaults
- Live session JSONL files (`~/.openclaw/agents/main/sessions/*.jsonl`) — toolCall/toolResult JSONL structure, tool name enumeration, toolCallId linkage confirmation

### Secondary (MEDIUM confidence)

- `.planning/phases/09-guardrail-event-metering/09-CONTEXT.md` — D-10/D-11 patterns, attribution decisions
- `.planning/phases/09-guardrail-event-metering/09-PATTERNS.md` — pattern map for Phase 9 implementation

### Tertiary (LOW confidence)

- A3 (409 conflict response format for `tools create`): inferred from `jobs create` pattern; not confirmed against live `tools create` 409 response text

---

## Metadata

**Confidence breakdown:**
- CLI surface: HIGH — verified via `--dry-run` against revenium 1.2.0 locally
- Session JSONL structure: HIGH — confirmed from live session files on this machine
- Architecture patterns: HIGH — all drawn from existing codebase (report.sh, guardrail-check.sh)
- --tool-type enum (BUILTIN): MEDIUM — CLI accepts it without error, but semantic correctness unconfirmed
- 409 conflict text for tools create: LOW — inferred from jobs create pattern, not confirmed

**Research date:** 2026-06-03
**Valid until:** 2026-07-03 (stable CLI; 30-day window)

---

## RESEARCH COMPLETE

**Phase:** 10 - Tool Registry & Tool-Event Metering
**Confidence:** HIGH

### Key Findings

- **CLI surface fully verified locally (revenium 1.2.0):** `revenium tools create` requires `--name`, `--tool-id`, `--tool-type`; accepts `--quiet`, `--dry-run`, `--organization-name`. `revenium meter tool-event` requires `--tool-id`, `--duration-ms`, `--timestamp`; `--success` defaults to `false` when omitted — always pass explicitly.
- **TOOLEV-03 is architecturally clean:** `meter completion` posts to `/v2/api/completions`; `meter tool-event` posts to `/v2/tool/events`. These are distinct API endpoints with no overlap. The TOOL_CALL completion path is untouched.
- **Session JSONL confirmed:** `toolCall` items are in `.message.content[].type=="toolCall"` on assistant messages; each has a `.id` that matches the subsequent `toolResult.message.toolCallId`. Duration = toolResult.timestamp - parentAssistantMessage.timestamp.
- **Tool→job correlation: omit for v1.2.** `meter tool-event` has no `--agentic-job-id`; `--workflow-id` is the closest candidate but server-side rollup behavior is unconfirmed. Attribution stops at `--agent` (root session) in v1.2.
- **Two ledgers needed:** `TOOL_REGISTRY_LEDGER_FILE` (create-once per tool-id, `TOOL:<tool_id>` keys) + a separate tool-events ledger or `TOOLEV:<toolcall_id>` keys in a new file. Keeping tool-event dedup separate from the completion reported-ledger avoids coupling with the CR-02 offset-advance gate.
- **`BUILTIN` tool-type:** The CLI accepts `BUILTIN` without error for non-MCP tools. Use `BUILTIN` for standard Claude Code tools; `MCP_SERVER` for tool names containing `__`.

### File Created

`.planning/phases/10-tool-registry-tool-event-metering/10-RESEARCH.md`

### Confidence Assessment

| Area | Level | Reason |
|------|-------|--------|
| CLI surface (tools create + meter tool-event) | HIGH | Verified via `--dry-run` against local revenium 1.2.0 |
| Session JSONL toolCall/toolResult structure | HIGH | Confirmed from live local session files |
| Architecture patterns (probe, ledger, fail-open) | HIGH | Direct extraction from report.sh/guardrail-check.sh source |
| --tool-type BUILTIN semantic correctness | MEDIUM | CLI accepts without error; server-side enum not inspected |
| 409 response text for tools create | LOW | Inferred from jobs create; not confirmed live |

### Open Questions

- Does `--workflow-id <agentic_job_id>` on `meter tool-event` cause Revenium to associate tool-events with the agentic job in the dashboard? (Recommend: test on live host before adopting)
- Should tool-event dedup keys live in `LEDGER_FILE` (with `TOOLEV:` prefix) or in a separate `revenium-tool-events.ledger`? (Recommend: separate file for cleaner CR-02 isolation)

### Ready for Planning

Research complete. Planner can now create PLAN.md files for Phase 10.
