/**
 * index.ts — Revenium Marker Gate plugin entry point.
 *
 * Registers three OpenClaw hooks:
 *   before_tool_call  — observes exec/bash calls; adds runId to tracking sets
 *   before_agent_finalize — returns a revise action when exec ran but write-marker.sh did not
 *   agent_end         — cleans up tracking sets to prevent memory leaks
 *
 * The pure gate logic lives in ./gate.js (importable by node:test without tsc
 * or the openclaw peer). This file is the thin wiring layer only.
 *
 * IMPORTANT: Any change to this file requires a rebuild + re-commit of
 * dist/index.js (the host has no tsc; see Pitfall 2 in 11-RESEARCH.md).
 */
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { safeBeforeToolCall, safeBeforeAgentFinalize, safeAgentEnd, } from "./gate.js";
export default definePluginEntry({
    id: "revenium-marker-gate",
    name: "Revenium Marker Gate",
    description: "Forces write-marker.sh before finalizing a substantive turn.",
    register(api) {
        // FAIL-OPEN GUARANTEE (CR-01): every handler body is wrapped in try/catch
        // so a throw from the gate logic can NEVER reject the hook promise.
        // before_tool_call: NOT a conversation hook — no allowConversationAccess needed.
        api.on("before_tool_call", async (event, ctx) => {
            try {
                safeBeforeToolCall(ctx?.runId, event?.toolName, event?.params);
            }
            catch { /* fail-open: observation is best-effort, never block the turn */ }
        });
        // before_agent_finalize: IS a conversation hook — requires allowConversationAccess: true
        // in the openclaw config (see post-install.sh for the config patch).
        // A thrown error MUST resolve to undefined (pass-through), never a rejection.
        api.on("before_agent_finalize", async (_event, ctx) => {
            try {
                return safeBeforeAgentFinalize(ctx?.runId, { log: (msg) => api.log?.(msg) });
            }
            catch {
                return undefined; // fail-open: never block the reply
            }
        });
        // agent_end: IS a conversation hook — requires allowConversationAccess: true.
        // Cleans up per-runId state to prevent memory leaks on long-lived gateways.
        api.on("agent_end", async (_event, ctx) => {
            try {
                safeAgentEnd(ctx?.runId);
            }
            catch { /* fail-open */ }
        });
    },
});
