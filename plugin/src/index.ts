/**
 * index.ts — Revenium Marker Gate plugin entry point.
 *
 * Registers six OpenClaw hooks:
 *   before_prompt_build — prepends the metering directives (task classification +
 *                         job lifecycle) to EVERY turn. Added 2026-06-13: OpenClaw
 *                         2026.6.6 refuses finalize revise actions on turns with
 *                         side effects, so per-turn injection (the NemoClaw-proven
 *                         mechanism) is the primary compliance driver now.
 *   before_tool_call  — observes working tool calls; adds runId to tracking sets
 *   before_agent_finalize — returns a revise action when a substantive turn did not classify
 *   agent_end         — cleans up tracking sets to prevent memory leaks
 *   subagent_spawned  — appends a child-to-parent session-key edge to the
 *                       PLUG-04 sidecar (root-session resolution, phase 19)
 *   subagent_ended    — appends a matching lifecycle "ended" record to the same sidecar
 *
 * The pure gate logic lives in ./gate.js (importable by node:test without tsc
 * or the openclaw peer). This file is the thin wiring layer only.
 *
 * IMPORTANT: Any change to this file requires a rebuild + re-commit of
 * dist/index.js (the host has no tsc; see Phase 19-03, prior reference:
 * Pitfall 2 in 11-RESEARCH.md).
 */
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import {
  safeBeforeToolCall,
  safeBeforeAgentFinalize,
  safeAgentEnd,
  safeSubagentSpawned,
  safeSubagentEnded,
  buildMeteringInjection,
} from "./gate.js";

// Loaded ONCE at plugin load — static for the gateway's lifetime (no hook-time
// fs I/O). null (file missing/out-of-bounds) → the hook returns undefined.
const METERING_INJECTION: string | null = buildMeteringInjection();

export default definePluginEntry({
  id: "revenium-marker-gate",
  name: "Revenium Marker Gate",
  description: "Forces write-marker.sh before finalizing a substantive turn.",
  register(api: any) {
    // before_prompt_build: NOT a conversation hook. Prepends the metering
    // directives to every turn (per-turn salience is what holds compliance —
    // ambient AGENTS.md demonstrably does not on long sessions).
    api.on("before_prompt_build", () => {
      try {
        return METERING_INJECTION ? { prependContext: METERING_INJECTION } : undefined;
      } catch {
        return undefined; // fail-open: never block the turn
      }
    });
    // FAIL-OPEN GUARANTEE (CR-01): every handler body is wrapped in try/catch so
    // a throw from the gate logic can NEVER reject the hook promise. The safe*
    // wrappers in gate.js contain the same containment (so the property is
    // unit-testable without the openclaw peer); the local try/catch here is a
    // defensive second layer that also guards the ctx/event dereferences below.

    // before_tool_call: NOT a conversation hook — no allowConversationAccess needed.
    api.on("before_tool_call", async (event: { toolName?: string; params?: Record<string, unknown> } | undefined, ctx: { runId?: string } | undefined) => {
      try {
        safeBeforeToolCall(ctx?.runId, event?.toolName ?? "", event?.params ?? {});
      } catch { /* fail-open: observation is best-effort, never block the turn */ }
    });

    // before_agent_finalize: IS a conversation hook — requires allowConversationAccess: true
    // in the openclaw config (see post-install.sh for the config patch).
    // A thrown error MUST resolve to undefined (pass-through), never a rejection.
    // event.messages is the conversation transcript array (PluginHookBeforeAgentFinalizeEvent).
    // It is passed to safeBeforeAgentFinalize so the transcript-scan path (B-05)
    // can detect Nemotron's tool_search_code exec pattern.
    api.on("before_agent_finalize", async (event: { messages?: unknown[] } | undefined, ctx: { runId?: string } | undefined) => {
      try {
        return safeBeforeAgentFinalize(ctx?.runId, event?.messages, { log: (msg: string) => api.log?.(msg) });
      } catch {
        return undefined; // fail-open: never block the reply
      }
    });

    // agent_end: IS a conversation hook — requires allowConversationAccess: true.
    // Cleans up per-runId state to prevent memory leaks on long-lived gateways.
    api.on("agent_end", async (_event: unknown, ctx: { runId?: string } | undefined) => {
      try {
        safeAgentEnd(ctx?.runId);
      } catch { /* fail-open */ }
    });

    // subagent_spawned: NOT a conversation hook — no allowConversationAccess needed.
    // Records the direct child-to-parent session-key link (PLUG-04/D-08) into the
    // durable sidecar that scripts/get-root-session-id.py (plan 19-05) reads.
    api.on("subagent_spawned", async (event: { childSessionKey?: string; requester?: string; runId?: string } | undefined, ctx: { requesterSessionKey?: string; childSessionKey?: string; runId?: string } | undefined) => {
      try {
        safeSubagentSpawned(event, ctx);
      } catch { /* fail-open: observation is best-effort, never block the turn */ }
    });

    // subagent_ended: NOT a conversation hook — no allowConversationAccess needed.
    // Records a matching lifecycle "ended" record so a resolver can tell a
    // still-running child from a completed one without re-querying the store.
    api.on("subagent_ended", async (event: { targetSessionKey?: string; outcome?: string; runId?: string } | undefined, ctx: { requesterSessionKey?: string; childSessionKey?: string; runId?: string } | undefined) => {
      try {
        safeSubagentEnded(event, ctx);
      } catch { /* fail-open: observation is best-effort, never block the turn */ }
    });
  },
});
