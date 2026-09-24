// Spike 008 (SPIKE-01, candidate c): plugin-hook sidecar probe.
//
// Registers llm_output and after_tool_call ONLY, per the task's own scope -
// captures per-completion usage/model/id and per-tool-call name/result/
// error/duration into an append-only capture file this project owns,
// immune to OpenClaw changing its session-storage mechanism again (D-01).
//
// Packaging follows the packaging established live in spike 006
// (.planning/spikes/006-plugin-directive-injection/revenium-guard/):
// package.json needs "type":"module" + "main" + "openclaw.extensions";
// openclaw.plugin.json needs id/name/version/activation.onStartup/
// configSchema (omitting configSchema broke the whole openclaw CLI in
// spike 006 - treated here as mandatory). The default-export
// `register(api)` shape below is the same shape spike 006 proved fires
// live once the plugin is installed with real provenance
// (`openclaw plugins install`, not a hand-placed directory).
//
// Hook payload shapes confirmed live from the installed openclaw package's
// own .d.ts (openclaw 2026.9.6, host 52.90.9.242, 2026-09-24,
// hook-runner-global-CDmmGFJp.d.ts):
//   PluginHookLlmOutputEvent: { runId, sessionId, provider, model,
//     resolvedRef?, contextTokenBudget?, usage?: {input,output,cacheRead,
//     cacheWrite,total}, reasoningEffort?, fastMode?, assistantTexts,
//     prompt?, lastAssistant?, ... } - assistantTexts/prompt/lastAssistant
//     carry real conversation content and are DELIBERATELY NEVER read or
//     written here (T-17-05 - no raw prompt/assistant text in the capture
//     file).
//   ctx (PluginHookAgentContext) carries sessionKey/agentId alongside the
//     event's sessionId - captured for session-correlation only.
//   PluginHookAfterToolCallEvent: { toolName, params, runId?, toolCallId?,
//     result?, error?, durationMs? } - params/result may carry tool
//     arguments/output content and are DELIBERATELY NEVER read or written
//     here; only structural/metadata fields (name, id, presence-of-result,
//     error flag, duration) are captured.
//   ctx (PluginHookToolContext) carries sessionKey/agentId - captured for
//     session-correlation only.
//
// Handlers are synchronous-cheap (one appendFileSync per event) and
// fail-open: every handler body is wrapped in try/catch so a capture-file
// write failure (full disk, permission problem) can never block or hang
// the turn this plugin is only observing.
import { appendFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const CAPTURE_FILE = join(homedir(), ".openclaw", "revenium-sidecar-capture.jsonl");

function append(record) {
  try {
    appendFileSync(CAPTURE_FILE, JSON.stringify(record) + "\n");
  } catch {
    // fail-open: a capture-file write failure must never affect the turn
  }
}

export default function register(api) {
  api.on("llm_output", (event, ctx) => {
    try {
      append({
        hook: "llm_output",
        capturedAt: new Date().toISOString(),
        runId: event?.runId,
        sessionId: event?.sessionId,
        sessionKey: ctx?.sessionKey,
        agentId: ctx?.agentId,
        provider: event?.provider,
        model: event?.model,
        resolvedRef: event?.resolvedRef,
        usage: event?.usage,
        contextTokenBudget: event?.contextTokenBudget,
        reasoningEffort: event?.reasoningEffort,
        fastMode: event?.fastMode,
      });
    } catch {
      // fail-open
    }
  });

  api.on("after_tool_call", (event, ctx) => {
    try {
      append({
        hook: "after_tool_call",
        capturedAt: new Date().toISOString(),
        runId: event?.runId ?? ctx?.runId,
        toolCallId: event?.toolCallId ?? ctx?.toolCallId,
        toolName: event?.toolName ?? ctx?.toolName,
        sessionKey: ctx?.sessionKey,
        agentId: ctx?.agentId,
        hasResult: event?.result !== undefined,
        error: event?.error,
        durationMs: event?.durationMs,
      });
    } catch {
      // fail-open
    }
  });
}
