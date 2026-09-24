---
probe_date: 2026-06-10
host: 34.224.27.67
sandbox: revenium-spike
model: nvidia/nemotron-3-super-120b-a12b
openclaw_version: 2026.5.22
schema_status: confirmed_with_caveats
---

# B-05 Schema Probe — Nemotron tool_search_code Exec Transcript

## Summary

Live probe on host 34.224.27.67 / sandbox revenium-spike confirmed the following:

1. **`before_agent_finalize` does NOT fire for `openclaw agent --json` CLI runs.** The CLI route uses the `agent/embedded` runner which skips the full gateway lifecycle hooks. `before_agent_finalize` only fires for full messaging-gateway sessions (SMS, web UI, channel-mediated turns). This was confirmed by running 3 instrumented probe turns with diagnostic logging — NO `before_agent_finalize` events appeared in the gateway log for any CLI `agent --json` run.

2. **`before_tool_call` DOES fire with `toolName="exec"` even for exec calls routed through `tool_search_code`.** When Nemotron calls `await openclaw.tools.call('openclaw:core:exec', {command: ...})` inside `tool_search_code` code, OpenClaw surfaces the inner `exec` call to the plugin `before_tool_call` hook with `toolName="exec"` and `params = {command: "..."}`. This contradicts the plan 15-05 finding.

3. **The transcript (conversation messages) lives in `event.messages` (the FIRST argument to `before_agent_finalize`)**, NOT in `ctx.conversation.messages` (the second argument). The type definition `PluginHookBeforeAgentFinalizeEvent` has `messages?: unknown[]` and `transcriptPath?: string`.

## Confirmed Schema

### (a) Field path from hook to message list

The before_agent_finalize handler signature is:
```ts
api.on("before_agent_finalize", async (event, ctx) => { ... })
```

The message list is at: **`event.messages`** (the FIRST argument, currently `_event` in the codebase)

The `ctx` (second argument) is `PluginHookAgentContext = { runId?, jobId?, trace?, agentId?, sessionKey? }` — it does NOT contain conversation/transcript.

**`ctx.conversation` does NOT exist.** The plan's assumption that the transcript is at `ctx.conversation.messages` is INCORRECT — it is `event.messages`.

The type definition (confirmed from `/usr/local/lib/node_modules/openclaw/dist/plugin-sdk/src/plugins/hook-types.d.ts` on the live host):
```ts
export type PluginHookBeforeAgentFinalizeEvent = {
    runId?: string;
    sessionId: string;
    sessionKey?: string;
    turnId?: string;
    provider?: string;
    model?: string;
    cwd?: string;
    transcriptPath?: string;    // path to .jsonl session file
    stopHookActive: boolean;
    lastAssistantMessage?: string;
    messages?: unknown[];       // the conversation messages array
};
```

### (b) Literal toolName value for tool_search_code calls

When Nemotron calls JavaScript code in `tool_search_code`, the toolName at the plugin `before_tool_call` hook is **`"exec"`** (not `"tool_search_code"`). OpenClaw's tool bridge surfaces the INNER `openclaw.tools.call('openclaw:core:exec', ...)` call as a direct `exec` tool event.

Confirmed from gateway log:
```
2026-06-10T16:06:54.851+00:00 [revenium-marker-gate] first exec observation: toolName="exec" params keys=[command]
```

The session JSONL shows the OUTER model call used `tool_search_code`:
```json
{"type": "toolCall", "name": "tool_search_code", "arguments": {"code": "return await openclaw.tools.call('openclaw:core:exec', { command: 'echo b05_probe_test' });"}}
```

But the plugin layer sees `toolName="exec"` because OpenClaw's tool bridge dispatches the inner call.

### (c) Where `openclaw:core:exec` appears in the message schema

In the session JSONL (at `event.transcriptPath`), the exec invocation appears in an assistant message's toolCall content part:

```json
{
  "type": "message",
  "id": "...",
  "parentId": "...",
  "timestamp": ...,
  "message": {
    "role": "assistant",
    "content": [
      {
        "type": "toolCall",
        "id": "call_b56f99acaeb94dadae78ca2f",
        "name": "tool_search_code",
        "arguments": {
          "code": "return await openclaw.tools.call('openclaw:core:exec', { command: 'echo b05_probe_test' });"
        }
      }
    ]
  }
}
```

The `openclaw:core:exec` string appears at:
**`event.messages[N].message.content[M].arguments.code`** where `content[M].name === "tool_search_code"` and `content[M].type === "toolCall"`.

The corresponding toolResult message:
```json
{
  "type": "message",
  "message": {
    "role": "toolResult",
    "content": [
      {
        "type": "text",
        "text": "{\"ok\": true, \"value\": {...exec result...}}"
      }
    ]
  }
}
```

### (d) How to distinguish toolResult/tool messages from others

Message discriminator: `event.messages[N].message.role`:
- `"assistant"` — model's response (may include toolCall content parts)
- `"user"` — user input
- `"toolResult"` — tool call result
- `"thinking"` — model thinking (content part type, not role)

For scanning exec evidence in `tool_search_code`: look for:
1. `message.role === "assistant"` AND
2. `message.content[M].type === "toolCall"` AND
3. `message.content[M].name === "tool_search_code"` AND
4. `message.content[M].arguments.code` contains `"openclaw:core:exec"`

### (e) runId presence

- `ctx.runId` — the run ID (second argument, always present when `before_agent_finalize` fires)
- `event.runId` — also present in the event (optional field)
- The JSONL messages do NOT embed a runId per-message

## Critical Finding: Hook Firing Scope

**`before_agent_finalize` does NOT fire for `openclaw agent --json` runs via `nemoclaw exec`.**

This is the deepest root cause for B-05: the `nemoclaw exec --agent main --json` CLI path uses the `agent/embedded` runner (confirmed by `[agent/embedded]` in gateway logs), which does NOT trigger conversation lifecycle hooks (`before_agent_finalize`, `agent_end`). Only full messaging-gateway turns (via SMS, web UI, or similar channels) trigger these hooks.

The plan 15-05 observation that "no markers were produced" is explained by this: `before_agent_finalize` never fires for CLI-initiated turns on this host. The plan's suggestion of scanning `ctx.conversation.messages` would never execute.

**Implication for observation code:** The transcript-scan B-05 fix in `handleBeforeAgentFinalize` will WORK when the agent is used through a messaging channel (the real production use case). It will NOT trigger for `openclaw agent --json` CLI test runs. Tests must call `handleBeforeAgentFinalize` directly with a constructed transcript (not via a live CLI run).

**Correct event parameter access:** The code must change `_event` to `event` and use `event.messages` (not `ctx.conversation?.messages`) to access the transcript.

## Capture Evidence

### Commands executed

```bash
# Instrumented dist deployed (v1 — logs ctx keys)
scp /tmp/index-instrumented.js ubuntu@34.224.27.67:/home/ubuntu/plugin-nemoclaw/dist/index.js
# v2 — logs event (first arg) keys
scp /tmp/index-instrumented2.js ubuntu@34.224.27.67:/home/ubuntu/plugin-nemoclaw/dist/index.js

# Plugin installed + recovered for each version
nemoclaw revenium-spike exec --timeout 30 -- sh -lc 'openclaw plugins install --force /sandbox/.openclaw/extensions/revenium-enforcement 2>/dev/null'
nemoclaw revenium-spike exec --timeout 30 -- sh -lc 'openclaw plugins enable revenium-enforcement 2>/dev/null'
nemoclaw revenium-spike recover

# Probe turns (sessions 524a4a76, 5aa8a683, 20685a2a)
nemoclaw revenium-spike exec --timeout 300 -- sh -lc 'openclaw agent --agent main --json --message "Run the shell command: echo b05_probe_test" 2>/dev/null'
```

### Session IDs and exit codes

| Session | ID | Exit | B05-PROBE in logs? | before_agent_finalize fired? |
|---------|----|------|-------------------|------------------------------|
| rv-b05-probe (v1) | 524a4a76-b331-4415-a421-d18a81ddc3ed | 0 | NO | NO |
| rv-b05-probe2 (v2) | 5aa8a683-64e2-49c2-9822-1f9619a6b8e3 | 0 | NO | NO |
| rv-b05-probe3 (v2) | 20685a2a-ddd5-4535-8032-e070883652f5 | 0 | NO | NO |

### Gateway log evidence of tool_search_code + exec

```
2026-06-10T16:06:54.851+00:00 [revenium-marker-gate] first exec observation: toolName="exec" params keys=[command]
```

This confirms `before_tool_call` DID fire with `toolName="exec"`, but `before_agent_finalize` did NOT fire (no B05-PROBE or B05-EVT log entries after this line).

### Session JSONL excerpt (session 524a4a76, messages 21-22)

```json
[21] assistant content[1]:
{"type":"toolCall","id":"call_b56f99acaeb94dadae78ca2f","name":"tool_search_code",
 "arguments":{"code":"return await openclaw.tools.call('openclaw:core:exec', { command: 'echo b05_probe_test' });"}}

[22] toolResult content[0]:
{"type":"text","text":"{\"ok\":true,\"value\":{\"tool\":{\"id\":\"openclaw:core:exec\",...},\"stdout\":\"b05_probe_test\\n\",...}}"}
```

This is a **REDACTED** excerpt. The literal strings `tool_search_code` and `openclaw:core:exec` appear at:
- `messages[21].message.content[1].name === "tool_search_code"`
- `messages[21].message.content[1].arguments.code` contains `"openclaw:core:exec"`

### Type definition source (live host)

```bash
cat /usr/local/lib/node_modules/openclaw/dist/plugin-sdk/src/plugins/hook-types.d.ts
# Confirms: before_agent_finalize receives (event: PluginHookBeforeAgentFinalizeEvent, ctx: PluginHookAgentContext)
# event.messages?: unknown[]  — the conversation messages
# event.transcriptPath?: string  — path to session JSONL
# ctx.runId?: string  — the run ID
```

### Sandbox restore

```bash
# Restored original dist/index.js from backup
cp /home/ubuntu/plugin-nemoclaw/dist/index.js.backup-task1 /home/ubuntu/plugin-nemoclaw/dist/index.js
cp /home/ubuntu/plugin-nemoclaw/dist/index.js /home/ubuntu/sbx-openclaw-revenium-spike/extensions/revenium-enforcement/dist/index.js
nemoclaw revenium-spike exec -- sh -lc 'openclaw plugins disable revenium-enforcement 2>/dev/null'
nemoclaw revenium-spike recover
# Result: Status: disabled, guardrail-status.json: halted=false, warned=false
```

## Plan Impact

The observation code for B-05 MUST:
1. Use `event.messages` (first arg), NOT `ctx.conversation.messages`
2. Look for `message.role === "assistant"` + `content[M].type === "toolCall"` + `content[M].name === "tool_search_code"` + `content[M].arguments.code` containing `"openclaw:core:exec"`
3. Look for write-marker.sh evidence in the SAME `arguments.code` field
4. Accept that this fix will only function for full gateway messaging sessions, not CLI test runs

The `safeBeforeAgentFinalize` wrapper must be updated to pass the transcript from `event` through to `impl` — the index.ts handler must read `event.messages` and pass it to `safeBeforeAgentFinalize`. **Both index.ts files must be updated to use the first `event` parameter (not `_event`).**
