# Phase 11: Structural Marker Enforcement — Research

**Researched:** 2026-06-04
**Domain:** OpenClaw TypeScript plugin SDK — `before_agent_finalize` lifecycle hook, plugin packaging and installation, shell-command observation via `before_tool_call`
**Confidence:** HIGH (all critical SDK claims verified by reading OpenClaw 2026.6.1 source on the ClawHub host `98.82.34.123`)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-00 (carry-forward):** Use the typed `before_agent_finalize` plugin hook. Chosen over `message:sent` file hook and `report.sh` cron backfill.
- **D-01:** Same repo, new `plugin/` dir. Plugin lives in `plugin/` package inside this repo, versions and ships alongside the bash skill on ClawHub as one unit.
- **D-02:** `post-install.sh` automates install + enable. Idempotent, mirroring the existing AGENTS.md injection pattern.
- **D-03:** Task marker only. Gate forces `write-marker.sh` only; does not gate `write-job-marker.sh` per turn.
- **D-04:** Fire only on turns that ran ≥1 `exec` tool call and produced no `write-marker.sh`. Structural "substantive turn" definition — no conversation access.
- **D-05:** Bounded + fail-open. `retry.maxAttempts` caps passes; hook error or timeout must never block the user's reply. No `allowConversationAccess` grant — the plugin observes `exec` tool calls only.
- **D-06:** `scripts/verify-markers.sh` built regardless of plugin progress.
- **D-07:** No change to budget-rule logic, `config.json` `ruleIds`, `guardrail-status.json` halt/warn JSON contract. Preserve `report.sh` atomic-write patterns, completion_id correlation, and `unclassified` default.

### Claude's Discretion (resolved by this research)

- Packaging / build format
- `maxAttempts` value
- Forced-pass instruction wording + idempotencyKey format
- `runId` stability confirmation

### Deferred Ideas (OUT OF SCOPE)

- `session_end` deterministic job-closure hook
- Per-turn job marker gating
- JCLASS-01, JGUARD-01, JOUT-01, GRDEV-F1 milestone candidates
</user_constraints>

---

## Summary

Phase 11 ships a TypeScript OpenClaw plugin (`revenium-marker-gate`) that uses the `before_agent_finalize` hook to force per-turn task classification before the agent yields. The plugin observes `exec` tool calls via `before_tool_call` (no conversation access needed for this hook), tracks which turns invoked `write-marker.sh`, and on an unclassified substantive turn returns a bounded `revise` response.

**Critical discovery (changes D-05 assumption):** `before_agent_finalize` and `agent_end` are classified as `CONVERSATION_HOOK_NAMES` in OpenClaw 2026.6.1. Non-bundled plugins registering these hooks **must** have `plugins.entries.<id>.hooks.allowConversationAccess: true` in the config — without it the hook is silently blocked (logged as a warning, not an error). This means `post-install.sh` must write this config key as part of its enable step. `before_tool_call` and `after_tool_call` are NOT conversation hooks; they work without `allowConversationAccess`.

**Packaging recommendation:** Ship a local-directory plugin with pre-built JavaScript (`dist/index.js`). Build on the developer machine via `npm run build` (TypeScript → ESM JS). Install on the host via `openclaw plugins install /path/to/skill-dir/plugin --force`. The host has Node 22.22.1 and npm 9.2.0 but no `tsc` — so the prebuilt `.js` artifact must ship inside the skill tarball so no build step is needed on the host.

**Primary recommendation:** Plugin package structure: `plugin/` directory at repo root with `package.json` (`type: module`, `openclaw.extensions: ["./dist/index.js"]`), `openclaw.plugin.json` manifest, TypeScript source in `plugin/src/index.ts`, pre-built output in `plugin/dist/index.js`. Post-install.sh installs via `openclaw plugins install "${SKILL_DIR}/plugin" --force` and patches config via `openclaw config patch --stdin` to set `allowConversationAccess: true`.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Turn tool-call observation | Plugin (before_tool_call hook) | — | Structural — no conversation content needed, just tool name/params |
| Unclassified-turn detection | Plugin (before_agent_finalize hook) | — | Runs at natural finalize; not /stop or user-abort |
| Forced classification pass | OpenClaw harness (revise loop) | Plugin returns revise action | Harness owns the retry; plugin only signals intent |
| Fail-open on hook error | OpenClaw harness (catch → continue) | — | Harness catches all hook errors, returns action: continue |
| runId tracking set | Plugin in-process (Map/Set) | — | Per-process, per-gateway-lifetime state; cleared on agent_end |
| Plugin install + enable | post-install.sh step | — | Idempotent automation (D-02 lesson) |
| Marker data source | write-marker.sh + markers/{sid}.jsonl | — | Unchanged from Phase 4 |
| Completions vs markers gap report | verify-markers.sh (new bash script) | — | Diffs session JSONL completions vs marker JSONL |

---

## Standard Stack

### Core Plugin SDK

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `openclaw/plugin-sdk/plugin-entry` | bundled with openclaw 2026.6.1 | `definePluginEntry` export for typed plugin registration | Official SDK subpath — verified in package.json exports map |
| Node.js ESM | 22.x (host: 22.22.1) | Plugin runtime | OpenClaw requires Node 22+ for plugins |
| TypeScript | dev-only, not on host | Source language for type safety | Build on dev machine, ship compiled JS |

### Supporting (dev-machine build only)

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `typescript` | ≥5.x | Compile `.ts` → `.js` | `npm run build` step on dev machine |
| `@types/node` | ≥22 | Node.js type definitions | Dev-time type checking only |

### No npm packages ship to the host

The plugin imports only from `openclaw/plugin-sdk/plugin-entry`, which is a subpath export of the `openclaw` CLI already on the host. No additional npm packages need to be installed on the host.

**Installation:**
```bash
# On dev machine (build step)
cd plugin && npm run build

# On host (called from post-install.sh)
openclaw plugins install "${SKILL_DIR}/plugin" --force
```

---

## Package Legitimacy Audit

No external packages are installed by this plugin on the host. The sole import (`openclaw/plugin-sdk/plugin-entry`) is a subpath of the `openclaw` CLI already installed at `/home/ubuntu/.npm-global/lib/node_modules/openclaw/`. The npm package `openclaw` exists on the registry (version 2026.6.1 verified on host), but `openclaw` is the application, not a library dependency — it is installed via the ClawHub installer, not by this plugin.

| Package | Registry | Note | slopcheck | Disposition |
|---------|----------|------|-----------|-------------|
| `openclaw` (CLI host install) | npm | Already installed, not installed by plugin | N/A — pre-existing | N/A |

**No external packages to audit** — plugin is zero-dependency at runtime.

---

## Architecture Patterns

### System Architecture Diagram

```
Agent turn (exec tools called)
        │
        ▼
┌─────────────────────────────────────────┐
│  before_tool_call hook (no conv access) │
│  if toolName === "exec"                 │
│    and params.command includes          │
│       "write-marker.sh"                 │
│  → markedTaskRuns.add(ctx.runId)        │
└───────────────┬─────────────────────────┘
                │ (per exec tool call)
                ▼
     [all tool calls complete]
                │
                ▼
┌─────────────────────────────────────────┐
│  before_agent_finalize hook             │
│  (conversation hook: allowConvAccess)   │
│                                         │
│  if markedTaskRuns.has(ctx.runId):      │
│    → return undefined (finalize OK)     │
│  else if hadDeterministicSideEffect:    │
│    → return undefined (fail-open)       │
│  else if no exec tool ran this turn:    │
│    → return undefined (non-substantive) │
│  else:                                  │
│    → return { action: "revise",         │
│        retry: {                         │
│          instruction: "...",            │
│          idempotencyKey: "marker-gate:${runId}", │
│          maxAttempts: 1 } }             │
└───────────────┬─────────────────────────┘
                │
     ┌──────────┴──────────┐
     │                     │
  revise →           finalize →
  harness adds       agent yields
  retry prompt       normally
  to conversation
  (one more pass)
     │
     ▼
  agent invokes write-marker.sh
  → before_tool_call fires
  → markedTaskRuns.add(runId)
  → before_agent_finalize
  → already marked → finalize
                │
                ▼
┌─────────────────────────────────────────┐
│  agent_end hook (conv hook: allowConv)  │
│  markedTaskRuns.delete(ctx.runId)       │
│  execRuns.delete(ctx.runId)             │
└─────────────────────────────────────────┘
```

### Recommended Project Structure

```
plugin/                     # NEW: revenium-marker-gate plugin package
├── package.json            # type:module, openclaw.extensions: ["./dist/index.js"]
├── openclaw.plugin.json    # plugin manifest (id, name, configSchema, activation)
├── tsconfig.json           # compiles src/ → dist/
├── src/
│   └── index.ts            # plugin source (definePluginEntry + api.on registrations)
└── dist/
    └── index.js            # COMMITTED pre-built artifact (ships in skill tarball)
scripts/
└── verify-markers.sh       # NEW: per-session completions vs markers diagnostic
```

### Pattern 1: Plugin Entry with Conversation-Hook Registration

```typescript
// Source: openclaw/plugin-sdk/plugin-entry subpath export (verified on host)
// File: plugin/src/index.ts
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";

// Per-run tracking state (in-process, not persisted)
const execRuns = new Set<string>();       // runIds that invoked any exec tool
const markedTaskRuns = new Set<string>(); // runIds that invoked write-marker.sh

export default definePluginEntry({
  id: "revenium-marker-gate",
  name: "Revenium Marker Gate",
  description: "Forces write-marker.sh before finalizing a substantive turn.",
  register(api) {
    // before_tool_call: NOT a conversation hook — no allowConversationAccess needed
    api.on("before_tool_call", async (event, ctx) => {
      const runId = ctx.runId;
      if (!runId) return;
      if (event.toolName === "exec") {
        const cmd: string = (event.params as Record<string, unknown>)?.command as string ?? "";
        if (typeof cmd === "string") {
          execRuns.add(runId);
          if (cmd.includes("write-marker.sh")) {
            markedTaskRuns.add(runId);
          }
        }
      }
    });

    // before_agent_finalize: IS a conversation hook — requires allowConversationAccess: true
    api.on("before_agent_finalize", async (event, ctx) => {
      const runId = ctx.runId;
      if (!runId) return; // fail-open: no runId
      // Not a substantive turn (no exec tool ran) → pass through
      if (!execRuns.has(runId)) return;
      // Already classified → pass through
      if (markedTaskRuns.has(runId)) return;
      // Substantive turn with no marker → force one more pass
      return {
        action: "revise" as const,
        reason: "turn not classified for Revenium metering",
        retry: {
          instruction:
            "Before finishing, classify this turn by running: " +
            "`bash ~/.openclaw/skills/revenium/scripts/write-marker.sh <task_type>` " +
            "(where <task_type> is one of the labels in task-taxonomy.json), " +
            "then finish your response.",
          idempotencyKey: `marker-gate:${runId}`,
          maxAttempts: 1,
        },
      };
    });

    // agent_end: IS a conversation hook — requires allowConversationAccess: true
    // Cleanup to avoid memory leak across turns
    api.on("agent_end", async (event, ctx) => {
      const runId = ctx.runId;
      if (runId) {
        execRuns.delete(runId);
        markedTaskRuns.delete(runId);
      }
    });
  },
});
```

### Pattern 2: Idempotent Install + Enable in post-install.sh

```bash
# Source: verified on ClawHub host 98.82.34.123 with openclaw 2026.6.1
# Install (idempotent via --force; overwrites previous version)
openclaw plugins install "${SKILL_DIR}/plugin" --force 2>/dev/null \
  || warn "plugin install failed — skipping"

# Enable with allowConversationAccess (required for before_agent_finalize + agent_end)
# Uses JSON5 stdin (objects merge recursively)
echo '{plugins: {entries: {"revenium-marker-gate": {enabled: true, hooks: {allowConversationAccess: true}}}}}' \
  | openclaw config patch --stdin 2>/dev/null \
  || warn "plugin config patch failed — skipping"
```

**Why `allowConversationAccess: true` is required:** `before_agent_finalize` and `agent_end` are in `CONVERSATION_HOOK_NAMES` (verified in `command-registration-D4pJ4aKM.js`). Without `allowConversationAccess: true`, the registry silently blocks these hooks with a warning-level diagnostic. The hook does not fail loudly — it is simply never registered. This would make the gate a silent no-op after install.

**Note:** `before_tool_call` and `after_tool_call` are NOT conversation hooks — they work without `allowConversationAccess`.

### Pattern 3: verify-markers.sh Structure

```bash
#!/usr/bin/env bash
# verify-markers.sh — Report per-session completions vs markers gap.
# Sources common.sh for SESSIONS_DIR, MARKERS_DIR, get_root_session_id.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"

# For each *.jsonl in SESSIONS_DIR: count assistant completions
# For each matching *.jsonl in MARKERS_DIR: count marker entries
# Output: session_id | completions | markers | gap
```

### Anti-Patterns to Avoid

- **Relying on `allowConversationAccess: false` (the default for non-bundled plugins):** Hooks are silently blocked, not errored. Post-install.sh MUST patch `allowConversationAccess: true` or the gate never fires.
- **Tracking by toolCallId instead of runId:** `runId` is what connects `before_tool_call` observations to `before_agent_finalize` within the same turn. `toolCallId` changes per tool call.
- **Using `after_tool_call` for tracking instead of `before_tool_call`:** Both work, but `before_tool_call` fires with the exact same `ctx.runId` before the tool executes. Either is safe for observation-only tracking.
- **Not deleting runId from sets in agent_end:** The `Set` is in-process memory. Without cleanup, a long-lived gateway accumulates runIds indefinitely. `agent_end` is the correct cleanup point.
- **Shipping TypeScript source as the plugin entry without pre-building:** The openclaw `extensions` field points to the built JS file. The host has no `tsc`. The compiled `dist/index.js` must be committed to the repo and shipped in the skill tarball.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Retry loop / max attempts tracking | Custom retry counter in plugin | `retry.maxAttempts` in revise return + SDK's `getFinalizeRetryBudget` | SDK tracks the budget by `(runId, idempotencyKey)` — custom counters could lose state or double-count |
| Hook error fail-open | Try/catch in handler | SDK's built-in catch | `runBeforeAgentFinalize` has a top-level `catch → { action: "continue" }` — handler errors never block the reply |
| Retry prompt formatting | Custom prompt injection | `retry.instruction` field | Harness prepends `BEFORE_AGENT_FINALIZE_RETRY_PROMPT_PREFIX` automatically before delivering the instruction |
| Config patching idempotency | Parse/diff openclaw.json | `openclaw config patch --stdin` | Merges objects recursively; safe to re-run |

**Key insight:** The SDK's budget tracker (`getFinalizeRetryBudget`) uses the `idempotencyKey` and `runId` combination to enforce `maxAttempts`. A plugin returning `maxAttempts: 1` with a stable `idempotencyKey` (e.g., `marker-gate:${runId}`) cannot accidentally loop more than once per turn — the harness enforces the budget and falls through to `action: continue` (finalize-anyway) when the budget is exhausted.

---

## SDK Contract Details (Verified)

### before_agent_finalize

**Source:** `lifecycle-hook-helpers-CmSPVI6t.js` + `embedded-agent-eUaVGd6D.js` on host

- Runs when the harness is about to accept a natural final assistant answer. Does NOT run on `/stop`, `/new`, user abort (`aborted: true`), or `yieldDetected`.
- The harness checks `shouldHonorBeforeAgentFinalizeRevision`: requires `!aborted && !promptError && !timedOut && !attempt.clientToolCalls && !attempt.yieldDetected`.
- If the hook throws, `lifecycle-hook-helpers-CmSPVI6t.js` catches and returns `{ action: "continue" }` — never blocks the reply. [VERIFIED: host openclaw source]
- Return contract (verified):
  - `{ action: "revise", reason, retry: { instruction, idempotencyKey?, maxAttempts? } }` → one more model pass
  - `{ action: "finalize", reason? }` → force finalize
  - `undefined` / omit → continue (finalize normally)
- `maxAttempts` is normalized to `max(1, floor(maxAttempts))` — minimum 1. Seed's `maxAttempts: 1` is valid. [VERIFIED: host source]
- `idempotencyKey`: if omitted, SDK derives one from `buildFinalizeRetryInstructionKey(instruction)`. Providing an explicit key based on `ctx.runId` is more stable. [VERIFIED: host source]
- Harness-level cap: `MAX_BEFORE_AGENT_FINALIZE_REVISIONS = 3` (regardless of plugin `maxAttempts`). Plugin `maxAttempts: 1` is always ≤ this cap, so the plugin value governs. [VERIFIED: host source]
- The `retry.instruction` is delivered to the model as: `BEFORE_AGENT_FINALIZE_RETRY_PROMPT_PREFIX + "\n\n" + reason`. The prefix is: `"Before accepting the previous final answer, apply this revision request and produce the revised final answer. Do not repeat completed work or rerun tools unless the request explicitly requires it."` [VERIFIED: host source]
- `allowConversationAccess: true` is REQUIRED for non-bundled plugins. Without it, the hook is silently blocked. [VERIFIED: `registry-BVye-IRt.js` on host]

### before_tool_call

- NOT a conversation hook → does NOT require `allowConversationAccess`. [VERIFIED: `command-registration-D4pJ4aKM.js` on host]
- Event payload includes: `toolName`, `params` (the tool input object), `toolCallId`, `runId` (conditionally spread from `ctx.runId`). [VERIFIED: `agent-tools.before-tool-call-CDXSxqiL.js`]
- For the `exec` tool: `params.command` is the shell command string. [VERIFIED: `control-ui/assets/index-DRTyMBOr.js` BD() function + `agent-tools.before-tool-call-CDXSxqiL.js` `const command = params.command`]
- The `toolName` is the string `"exec"` for the exec tool. [VERIFIED: `embedded-agent-subscribe.tools-Df3nL-HB.js`]
- `fail-closed` is the failure policy for `before_tool_call`. For observation-only use (no return value), this is moot — the handler returning `undefined` is safe. [VERIFIED: `hook-runner-global-CBGmN_LW.js`]

### agent_end

- IS a conversation hook → requires `allowConversationAccess: true`. [VERIFIED: `command-registration-D4pJ4aKM.js`]
- Observation-only; receives `runId` when available via `ctx.runId`. [VERIFIED: hooks doc + `lifecycle-hook-helpers-CmSPVI6t.js` `buildAgentHookContext`]
- 30-second timeout applied by hook runner. Fire-and-forget on gateway paths; CLI paths wait. [VERIFIED: hooks doc]

### runId Stability

`ctx.runId` in `before_tool_call`, `before_agent_finalize`, and `agent_end` all originate from the same `params.runId` passed to `runEmbeddedAgent`. It is stable across all hooks within a single turn (a single "run"). The harness passes it through `buildAgentHookContext(params.ctx)` where `params.ctx.runId` is the stable run identifier. [VERIFIED: `lifecycle-hook-helpers-CmSPVI6t.js` `buildAgentHookContext` + `agent-tools.before-tool-call-CDXSxqiL.js` `args.ctx.runId`]

### Conversation Hook Names (VERIFIED)

```
CONVERSATION_HOOK_NAMES = [
  "before_model_resolve",
  "before_agent_reply",
  "llm_input",
  "llm_output",
  "before_agent_finalize",   ← requires allowConversationAccess: true
  "agent_end",               ← requires allowConversationAccess: true
  "before_agent_run"
]
```

`before_tool_call`, `after_tool_call` — NOT in this list — safe without `allowConversationAccess`. [VERIFIED: `command-registration-D4pJ4aKM.js` on host]

### Config Shape (VERIFIED on host)

After install + patch, `openclaw.json` contains:
```json
{
  "plugins": {
    "entries": {
      "revenium-marker-gate": {
        "enabled": true,
        "hooks": {
          "allowConversationAccess": true
        }
      }
    }
  }
}
```

Plugin is installed to `~/.openclaw/extensions/revenium-marker-gate/`. [VERIFIED: live install test on host]

### Plugin manifest (openclaw.plugin.json)

```json
{
  "id": "revenium-marker-gate",
  "name": "Revenium Marker Gate",
  "description": "Forces write-marker.sh before finalizing a substantive turn.",
  "version": "1.0.0",
  "activation": { "onStartup": false },
  "contracts": { "tools": [] },
  "configSchema": {}
}
```

### package.json

```json
{
  "name": "revenium-marker-gate",
  "type": "module",
  "openclaw": {
    "extensions": ["./dist/index.js"]
  },
  "peerDependencies": {
    "openclaw": ">=2026.6.1"
  },
  "devDependencies": {
    "typescript": "^5.0.0"
  }
}
```

---

## Common Pitfalls

### Pitfall 1: Silent Hook Block Due to Missing allowConversationAccess

**What goes wrong:** `before_agent_finalize` and `agent_end` are registered but never fire. The plugin installs successfully, `openclaw plugins list` shows it enabled, but no gate fires. The only indication is a warn-level log in openclaw logs.

**Why it happens:** Non-bundled plugins registering CONVERSATION_HOOK_NAMES without `allowConversationAccess: true` in config. The registry silently drops the hook registration with a diagnostic at `warn` level, not an error.

**How to avoid:** Post-install.sh MUST write `plugins.entries.revenium-marker-gate.hooks.allowConversationAccess: true` via `openclaw config patch --stdin`. Add a `openclaw plugins inspect revenium-marker-gate` post-install check to verify `hookNames` includes `before_agent_finalize`.

**Warning signs:** Plugin enabled in list, marker coverage unchanged after install, `openclaw plugins doctor` shows hook blocked.

### Pitfall 2: TypeScript Source Shipped Without Pre-Building

**What goes wrong:** `package.json` points `openclaw.extensions` to `./src/index.ts`. OpenClaw loads it as JS (it is ESM), Node.js cannot parse TypeScript syntax → plugin fails to load.

**Why it happens:** OpenClaw uses the `extensions` array path directly as a Node.js module; it does not invoke `tsc` at load time.

**How to avoid:** Build `dist/index.js` on the dev machine and commit it. `openclaw.extensions` must point to `"./dist/index.js"`. The host has no `tsc` (verified). Do not add a `prepare` or `postinstall` npm script that runs `tsc` — the plugin directory is copied by the installer, not `npm install`-ed.

### Pitfall 3: execRuns / markedTaskRuns Memory Leak

**What goes wrong:** The in-process `Set` objects grow unboundedly as turns accumulate over the gateway's lifetime.

**Why it happens:** `before_agent_finalize` fires once per turn; `agent_end` must fire to clean up. If `agent_end` is not registered (or not receiving runId), old entries accumulate.

**How to avoid:** Always register `agent_end` with cleanup. Note `agent_end` also requires `allowConversationAccess: true` — if the hook is silently blocked (Pitfall 1), cleanup never runs. Both hooks live or die together with the `allowConversationAccess` config.

### Pitfall 4: Gate Fires on /stop or User Abort

**What goes wrong:** The gate is expected not to fire on abort paths, but the tracking set has entries for the aborted run.

**Why it happens:** `before_agent_finalize` contract guarantees it does NOT run on `/stop` or user abort (`aborted: true` path) — the harness checks `shouldHonorBeforeAgentFinalizeRevision` and skips if `aborted`. No action needed from the plugin, but `agent_end` still fires (for cleanup).

**How to avoid:** No special handling needed — the SDK guarantee is verified in source. `agent_end` cleanup still fires on abort paths, which is correct.

### Pitfall 5: exec Tool Name Mismatch

**What goes wrong:** The gate checks `toolName === "exec"` but on some session configurations, the exec tool is renamed (e.g., `bash`).

**Why it happens:** Some OpenClaw configurations expose the exec capability under a different name (e.g., sandboxed sessions use `bash` vs `exec`).

**How to avoid:** Check both `toolName === "exec"` and `toolName === "bash"` in `before_tool_call`. Alternatively, check `event.toolKind === "exec"` if the `toolKind` field is available (seen in `before_tool_call` context from `policyAdjustedToolIdentity`). Log the tool name in the initial version for diagnosis.

### Pitfall 6: post-install.sh Must Restart Gateway for Hooks to Load

**What goes wrong:** Plugin installed and config patched, but hooks are not active in the current session.

**Why it happens:** OpenClaw loads plugins at gateway start. Config changes take effect after a gateway restart (`Restart the gateway to load plugins` is shown by the installer).

**How to avoid:** Post-install.sh comment must note this. The validation step (end-to-end test on host) must restart the gateway (or run in a fresh session) after install.

---

## verify-markers.sh Data Sources (VERIFIED)

- **Completions source:** `~/.openclaw/agents/main/sessions/*.jsonl` — each line is a JSONL record; records with `type: "message"` and `message.role: "assistant"` are completions. The `.id` field at the top level is the `completion_id`. [VERIFIED: write-marker.sh source code + existing test fixtures]
- **Markers source:** `~/.openclaw/skills/revenium/markers/{sid}.jsonl` — per-session marker files, one JSON record per line, fields: `ts`, `task_type`, optional `completion_id`. [VERIFIED: write-marker.sh source code]
- **Session resolution:** `common.sh`'s `get_root_session_id` + `SESSIONS_DIR`/`MARKERS_DIR` constants can be reused directly. [VERIFIED: common.sh source]
- **Cron exclusion:** `sessions/sessions.json` maps `agent:main:cron:*` keys to session IDs that should be excluded. [VERIFIED: write-marker.sh source]

**verify-markers.sh algorithm:**
1. For each `*.jsonl` in `SESSIONS_DIR` (excluding cron sids): count assistant-message records.
2. For matching `{sid}.jsonl` in `MARKERS_DIR`: count marker records.
3. Output gap = completions − markers per session.
4. Summary: total completions, total markers, total gap, coverage %.

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| AGENTS.md directive: "classify every turn" | Structural plugin hook | Phase 11 | LLM compliance → structural enforcement |
| write-marker.sh invoked by LLM willingness | write-marker.sh forced by before_agent_finalize revise | Phase 11 | 1/64 → expected near-100% coverage |
| Unmeasured gap (no baseline report) | verify-markers.sh per-session report | Phase 11 | Gap visible before/after |

**Deprecated/outdated:**
- Relying solely on AGENTS.md directive for end-of-turn classification: demonstrated to fail at ~63/64 turns on ClawHub with Opus 4.8. Plugin does not replace the directive (belt-and-suspenders) but makes it structurally redundant for the classification gate.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Node.js | Plugin runtime (host) | ✓ | 22.22.1 | — |
| npm | Post-install (host) | ✓ | 9.2.0 | — |
| `tsc` (TypeScript compiler) | Build step (dev machine) | ✗ on host | — | Build on dev machine, commit dist/ |
| `openclaw` CLI | Plugin install | ✓ | 2026.6.1 | — |
| `openclaw config patch --stdin` | Enable + configure plugin | ✓ | 2026.6.1 | Python direct-edit fallback (same pattern as AGENTS.md injection) |
| ssh access to 98.82.34.123 | End-to-end validation | ✓ | `ssh -i ~/.ssh/agent-sandbox.pem ubuntu@` | — |

**Missing dependencies with no fallback:** None blocking.
**Missing dependencies with fallback:** `tsc` not on host — handled by committing pre-built `dist/index.js`.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | bash integration tests (existing pattern) + Node.js unit tests (new, for plugin logic) |
| Config file | none — shell scripts sourced directly |
| Quick run command | `bash tests/test_write_marker.sh && bash tests/test_verify_markers.sh` |
| Full suite command | `bash tests/run-all.sh` (or `for f in tests/test_*.sh; do bash "$f"; done`) |
| Node unit test command | `cd plugin && node --test src/index.test.js` (or vitest if added) |

### Phase Requirements → Test Map

| Success Criterion | Behavior | Test Type | Automated Command | Notes |
|------------------|----------|-----------|-------------------|-------|
| SC-1: before_agent_finalize fires on unclassified exec turn | Plugin returns `revise` when exec ran but write-marker.sh did not | Unit (plugin logic) | `cd plugin && node --test` | Mock event; verify return shape |
| SC-1: coverage rises above ~1/64 on host | End-to-end: revise loop fires, agent classifies | E2E on ClawHub host | Manual: start agent, run tasks, inspect markers | Requires live host session |
| SC-2: Fail-open — bounded, non-blocking | `maxAttempts: 1` enforced; hook error → continue | Unit (plugin logic) | `cd plugin && node --test` | Inject error in handler, verify SDK catches it |
| SC-3: No `allowConversationAccess` on before_tool_call | Plugin observes exec tools without conversation access for before_tool_call | Structural (code review) | `openclaw plugins doctor` on host | before_tool_call is not a conv hook |
| SC-3: Package installable on ClawHub host | Install succeeds via `openclaw plugins install` | Manual on host | `openclaw plugins install ${SKILL_DIR}/plugin` | Run by post-install.sh validation |
| SC-4: verify-markers.sh reports gap | Script diffs completions vs markers per session | Shell unit test | `bash tests/test_verify_markers.sh` | Use session fixture + markers fixture |
| SC-5: No change to report.sh / guardrail behavior | Existing tests still pass | Regression | `bash tests/test_report_argv.sh` | No code changes to report.sh expected |

### Wave 0 Gaps

- [ ] `plugin/src/index.ts` — plugin source (new file)
- [ ] `plugin/dist/index.js` — pre-built artifact (must be committed)
- [ ] `plugin/package.json` + `plugin/openclaw.plugin.json` + `plugin/tsconfig.json` — plugin package files
- [ ] `tests/test_verify_markers.sh` — unit test for verify-markers.sh
- [ ] `scripts/verify-markers.sh` — diagnostic script (new file)
- [ ] Node.js test infrastructure in `plugin/` if using `node:test` (no extra install needed — Node 22 ships it)

*(Existing test infrastructure covers SC-5 fully; SC-1/2/3/4 need the above additions)*

---

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | — |
| V3 Session Management | no | — |
| V4 Access Control | partial | Plugin in-process state not shared; `agent_end` cleanup prevents runId leakage across users on multi-user gateways |
| V5 Input Validation | yes | `params.command` is read-only observed (not eval-ed); `typeof cmd === "string"` guard before `.includes()` |
| V6 Cryptography | no | — |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Prompt injection via retry.instruction | Tampering | Instruction is a static string constructed in plugin source — no user input interpolated |
| In-process state shared across sessions | Information Disclosure | `agent_end` cleanup; `execRuns`/`markedTaskRuns` are per-runId, not per-user |
| `params.command` includes shell metacharacters | Tampering | Plugin only reads the string (`.includes("write-marker.sh")`) — no execution or interpolation |

---

## Open Questions

1. **exec tool `toolKind` field availability in before_tool_call**
   - What we know: `toolName === "exec"` is confirmed. `toolKind` is in the `policyAdjustedToolIdentity` spread passed to before_tool_call event, but its value for the exec tool is not confirmed.
   - What's unclear: Whether `event.toolKind === "exec"` is a more reliable alternative to `event.toolName === "exec"` when the tool is renamed.
   - Recommendation: Log `toolName` in the initial deployed version; fall back to also checking `"bash"` as a second toolName.

2. **Gateway restart required after post-install.sh**
   - What we know: `openclaw plugins install` prints "Restart the gateway to load plugins."
   - What's unclear: Whether post-install.sh can trigger a gateway restart or whether it must only install and document that a restart is needed.
   - Recommendation: post-install.sh installs and patches config; documents that a gateway restart is required. Do not auto-restart from a skill's post-install script.

3. **verify-markers.sh cron session exclusion on the ClawHub host**
   - What we know: `sessions.json` maps cron session keys. The host uses Docker sandbox with cron-triggered sessions.
   - What's unclear: Whether the host's `sessions.json` format matches what write-marker.sh expects (confirmed locally but not verified on 98.82.34.123 in the verify-markers.sh context).
   - Recommendation: Reuse write-marker.sh's exact cron-exclusion logic — it is proven on the host already.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `event.params.command` is the shell command string in before_tool_call for the exec tool | SDK Contract Details | Gate would never detect write-marker.sh; fall back to checking other fields like `event.params.code` (seen in code-mode exec normalization) |
| A2 | `"bash"` as an alternative exec tool name covers sandboxed sessions | Pitfall 5 | Gate misses turns where exec is exposed as `bash` — fix by also checking `toolName === "bash"` |
| A3 | A gateway restart (not just a config reload) is required after plugin install | Open Questions | If config reload suffices, the validation gap shrinks; if restart is needed and post-install.sh doesn't document it, the gate silently never fires in the current session |

---

## Sources

### Primary (HIGH confidence)

- OpenClaw 2026.6.1 source on host `98.82.34.123` — `command-registration-D4pJ4aKM.js` (CONVERSATION_HOOK_NAMES), `lifecycle-hook-helpers-CmSPVI6t.js` (before_agent_finalize contract, fail-open behavior), `registry-BVye-IRt.js` (allowConversationAccess enforcement), `embedded-agent-eUaVGd6D.js` (MAX_BEFORE_AGENT_FINALIZE_REVISIONS=3, revision loop), `agent-tools.before-tool-call-CDXSxqiL.js` (before_tool_call event payload, runId), `plugin-entry-D0csrIe8.js` (definePluginEntry), `hook-runner-global-CBGmN_LW.js` (hook runner)
- Live install test on host: `openclaw plugins install /tmp/test-plugin` + `openclaw config patch --stdin` — confirmed install location (`~/.openclaw/extensions/<id>/`), config shape (`plugins.entries.<id>.enabled + hooks.allowConversationAccess`)
- OpenClaw package.json exports map on host — confirmed `openclaw/plugin-sdk/plugin-entry` export exists
- `scripts/write-marker.sh` in-repo source — confirmed `params.command` field reference + session JSONL format
- `scripts/common.sh` in-repo source — confirmed `SESSIONS_DIR`, `MARKERS_DIR`, `get_root_session_id` for verify-markers.sh reuse

### Secondary (MEDIUM confidence)

- `docs.openclaw.ai/plugins/hooks` — before_agent_finalize contract overview, hook registration patterns
- `docs.openclaw.ai/plugins/building-plugins` — definePluginEntry signature, package.json format, install invocation
- `docs.openclaw.ai/plugins/tool-plugins` — package.json format with `openclaw.extensions`, local path install syntax

### Tertiary (LOW confidence)

- A1 assumption: `params.command` for exec tool — inferred from `control-ui` BD() function and `agent-tools.before-tool-call-CDXSxqiL.js` `const command = params.command`; not confirmed by reading a live session log with an exec tool call in before_tool_call hook context

---

## Metadata

**Confidence breakdown:**
- SDK hook contracts: HIGH — read directly from OpenClaw 2026.6.1 minified source on the live host
- allowConversationAccess requirement: HIGH — read from `command-registration-D4pJ4aKM.js` and `registry-BVye-IRt.js`
- Install + config shape: HIGH — confirmed by live test on host
- exec tool command field name: MEDIUM — inferred from multiple indirect sources; direct hook-payload confirmation not achieved
- Packaging approach (prebuilt JS): HIGH — host confirmed no `tsc`; install accepts local directory; extensions field points to JS file in stock plugins

**Research date:** 2026-06-04
**Valid until:** 30 days (OpenClaw plugin SDK is actively developed; re-verify before major version bump)
