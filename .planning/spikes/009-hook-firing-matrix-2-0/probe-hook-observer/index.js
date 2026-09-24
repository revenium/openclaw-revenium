// Spike 009 (SPIKE-02): hook-observer plugin.
//
// Registers EXACTLY the six hooks D-08 fixes in advance and does nothing but
// record a fire: before_prompt_build, after_tool_call, before_agent_finalize,
// subagent_spawned, subagent_ended, session_end. No other hooks are
// registered.
//
// Packaging mirrors the proven shape from spike 006
// (.planning/spikes/006-plugin-directive-injection/) and plan 17-04's sidecar
// probe (.planning/spikes/008-sqlite-session-read-path/probe-sidecar-plugin/):
// package.json needs "type":"module" + "main" + "openclaw.extensions";
// openclaw.plugin.json needs id/name/version/activation.onStartup/
// configSchema (omitting configSchema broke the whole openclaw CLI in spike
// 006 - treated here as mandatory). The default-export `register(api)` shape
// below is the same shape spike 006/17-04 proved fires live once the plugin
// is installed with real provenance (`openclaw plugins install`, not a
// hand-placed directory).
//
// Hook payload shapes confirmed live from the installed openclaw package's
// own .d.ts (openclaw 2026.9.6, host 52.90.9.242, 2026-09-24,
// hook-runner-global-CDmmGFJp.d.ts, read directly via ssh grep for this
// task):
//   PluginHookBeforePromptBuildEvent: { prompt, currentUserMessage?,
//     currentUserMessageId?, messages }. `prompt`/`currentUserMessage`/
//     `messages` carry real conversation content and are DELIBERATELY NEVER
//     read or written here (T-17-05) - only key names and structural
//     presence booleans are captured.
//   PluginHookAfterToolCallEvent: { toolName, params, runId?, toolCallId?,
//     result?, error?, durationMs? }. `params`/`result` may carry tool
//     arguments/output content and are DELIBERATELY NEVER read or written
//     here; only structural/metadata fields are captured (name, id,
//     hasResult, hasError, duration).
//   PluginHookBeforeAgentFinalizeEvent: { runId?, sessionId, sessionKey?,
//     turnId?, provider?, model?, cwd?, transcriptPath?, stopHookActive,
//     lastAssistantMessage?, messages? }. `lastAssistantMessage`/`messages`
//     carry content and are never read or written here.
//   PluginHookSubagentSpawnedEvent: { childSessionKey, agentId, label?,
//     mode, requester?, threadRequested, runId, resolvedModel?,
//     resolvedProvider? } - carries childSessionKey for correlation with
//     subagent_ended per the task's own instruction (subagent_ended does
//     NOT carry agentId; correlation runs through
//     subagent_spawned.childSessionKey).
//   PluginHookSubagentEndedEvent: { targetSessionKey, targetKind, reason,
//     sendFarewell?, accountId?, runId?, endedAt?, outcome?, error? } - no
//     agentId field, confirming the correlation note above live.
//   PluginHookSessionEndEvent: { sessionId, sessionKey?, messageCount,
//     durationMs?, reason?, sessionFile?, transcriptArchived?,
//     nextSessionId?, nextSessionKey? }. `reason` enum per the live .d.ts:
//     new, reset, idle, daily, compaction, deleted, shutdown, restart,
//     unknown. This event's schema carries NO message-content field at all
//     (messageCount is a number, sessionFile is a path) - the
//     hasMessageContent flag below is computed dynamically from the actual
//     keys received rather than hardcoded, so a future schema change would
//     still be caught, but on the current schema it structurally confirms
//     (or is consistent with) upstream issue #155696's claim that the
//     session_end payload carries no message content.
//
// Handlers are synchronous-cheap (one appendFileSync per event) and
// fail-open: every handler body is wrapped in try/catch so a capture-file
// write failure (full disk, permission problem) can never block or hang the
// turn. before_prompt_build and before_agent_finalize are Modify-type hooks
// with a 15s default timeout whose documented failure behavior is
// log-and-skip - this handler returns nothing (no result object), so it
// never mutates the turn it observes.
import { appendFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const CAPTURE_FILE = join(homedir(), ".openclaw", "revenium-hook-observer-capture.jsonl");

function append(record) {
  try {
    appendFileSync(CAPTURE_FILE, JSON.stringify(record) + "\n");
  } catch {
    // fail-open: a capture-file write failure must never affect the turn
  }
}

// Content-bearing keys never logged by value, only checked for presence.
const CONTENT_KEYS = new Set([
  "prompt",
  "currentUserMessage",
  "messages",
  "lastAssistantMessage",
  "params",
  "result",
]);

function hasNonEmpty(value) {
  if (value === undefined || value === null) return false;
  if (typeof value === "string") return value.length > 0;
  if (Array.isArray(value)) return value.length > 0;
  if (typeof value === "object") return Object.keys(value).length > 0;
  return true;
}

function eventKeys(event) {
  try {
    return Object.keys(event ?? {});
  } catch {
    return [];
  }
}

function ctxKeys(ctx) {
  try {
    return Object.keys(ctx ?? {});
  } catch {
    return [];
  }
}

// Dynamic, schema-agnostic scan: does this event carry any key whose name
// suggests message/prompt/content text, with a non-empty value? Computed
// live rather than hardcoded so a future OpenClaw schema change is still
// caught, not silently assumed away.
function hasMessageContent(event) {
  try {
    for (const [key, value] of Object.entries(event ?? {})) {
      if (key === "messageCount") continue; // a count, not content
      if (/message|content|text|prompt/i.test(key) && hasNonEmpty(value)) {
        return true;
      }
    }
    return false;
  } catch {
    return false;
  }
}

export default function register(api) {
  api.on("before_prompt_build", (event, ctx) => {
    try {
      append({
        hook: "before_prompt_build",
        capturedAt: new Date().toISOString(),
        eventKeys: eventKeys(event),
        ctxKeys: ctxKeys(ctx),
        hasPrompt: hasNonEmpty(event?.prompt),
        hasCurrentUserMessage: hasNonEmpty(event?.currentUserMessage),
        messagesCount: Array.isArray(event?.messages) ? event.messages.length : undefined,
        sessionKey: ctx?.sessionKey,
        sessionId: ctx?.sessionId,
        agentId: ctx?.agentId,
      });
      // No result returned: this observer never modifies the turn.
    } catch {
      // fail-open
    }
  });

  api.on("after_tool_call", (event, ctx) => {
    try {
      append({
        hook: "after_tool_call",
        capturedAt: new Date().toISOString(),
        eventKeys: eventKeys(event),
        ctxKeys: ctxKeys(ctx),
        toolName: event?.toolName ?? ctx?.toolName,
        toolCallId: event?.toolCallId ?? ctx?.toolCallId,
        runId: event?.runId ?? ctx?.runId,
        hasResult: event?.result !== undefined,
        hasError: event?.error !== undefined,
        durationMs: event?.durationMs,
        sessionKey: ctx?.sessionKey,
        agentId: ctx?.agentId,
      });
    } catch {
      // fail-open
    }
  });

  api.on("before_agent_finalize", (event, ctx) => {
    try {
      append({
        hook: "before_agent_finalize",
        capturedAt: new Date().toISOString(),
        eventKeys: eventKeys(event),
        ctxKeys: ctxKeys(ctx),
        sessionId: event?.sessionId,
        sessionKey: event?.sessionKey ?? ctx?.sessionKey,
        turnId: event?.turnId,
        provider: event?.provider,
        model: event?.model,
        stopHookActive: event?.stopHookActive,
        hasLastAssistantMessage: hasNonEmpty(event?.lastAssistantMessage),
        messagesCount: Array.isArray(event?.messages) ? event.messages.length : undefined,
        agentId: ctx?.agentId,
      });
      // No result returned: this observer never modifies the turn.
    } catch {
      // fail-open
    }
  });

  api.on("subagent_spawned", (event, ctx) => {
    try {
      append({
        hook: "subagent_spawned",
        capturedAt: new Date().toISOString(),
        eventKeys: eventKeys(event),
        ctxKeys: ctxKeys(ctx),
        childSessionKey: event?.childSessionKey ?? ctx?.childSessionKey,
        agentId: event?.agentId,
        mode: event?.mode,
        threadRequested: event?.threadRequested,
        resolvedModel: event?.resolvedModel,
        resolvedProvider: event?.resolvedProvider,
        runId: event?.runId ?? ctx?.runId,
        hasLabel: hasNonEmpty(event?.label),
        hasRequester: hasNonEmpty(event?.requester),
        requesterSessionKey: ctx?.requesterSessionKey,
      });
    } catch {
      // fail-open
    }
  });

  api.on("subagent_ended", (event, ctx) => {
    try {
      append({
        hook: "subagent_ended",
        capturedAt: new Date().toISOString(),
        eventKeys: eventKeys(event),
        ctxKeys: ctxKeys(ctx),
        // NOTE: this event does NOT carry agentId (confirmed structurally,
        // per eventKeys above) - correlate with subagent_spawned via
        // targetSessionKey == childSessionKey.
        targetSessionKey: event?.targetSessionKey,
        targetKind: event?.targetKind,
        reason: event?.reason,
        outcome: event?.outcome,
        hasError: event?.error !== undefined,
        endedAt: event?.endedAt,
        runId: event?.runId ?? ctx?.runId,
        childSessionKeyCtx: ctx?.childSessionKey,
      });
    } catch {
      // fail-open
    }
  });

  api.on("session_end", (event, ctx) => {
    try {
      append({
        hook: "session_end",
        capturedAt: new Date().toISOString(),
        eventKeys: eventKeys(event),
        ctxKeys: ctxKeys(ctx),
        sessionId: event?.sessionId,
        sessionKey: event?.sessionKey ?? ctx?.sessionKey,
        messageCount: event?.messageCount,
        durationMs: event?.durationMs,
        // #155696 confirm-or-retire observation: the exact reason value and
        // whether any content-bearing key was present in this payload.
        reason: event?.reason,
        hasMessageContent: hasMessageContent(event),
        hasSessionFile: hasNonEmpty(event?.sessionFile),
        transcriptArchived: event?.transcriptArchived,
        hasNextSessionId: hasNonEmpty(event?.nextSessionId),
        hasNextSessionKey: hasNonEmpty(event?.nextSessionKey),
      });
    } catch {
      // fail-open
    }
  });
}
