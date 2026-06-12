/**
 * index.ts — Revenium Enforcement plugin entry point.
 *
 * Registers four OpenClaw hooks:
 *   before_prompt_build  — injects BUDGET-GUARD.md directive (baked at build, D-02) with
 *                          <revenium-guard> tag (D-10) into every agent turn (NCENF-01)
 *   before_tool_call     — observes exec/bash calls; adds runId to tracking sets (NCENF-02)
 *   before_agent_finalize — returns a revise action when exec ran but write-marker.sh did not
 *   agent_end            — cleans up tracking sets to prevent memory leaks
 *
 * The guard directive is inlined at build time from BUDGET-GUARD.md via scripts/bake-directive.js
 * so the plugin is pure/static — no fs I/O at hook time (anti-hang posture, D-02).
 *
 * gate.js is copied from plugin/src/gate.js at build time by scripts/bake-directive.js (D-06).
 * That file is the single source of truth for marker logic — no fork.
 * This file is the thin wiring layer only.
 *
 * IMPORTANT: Any change to this file requires a rebuild + re-commit of
 * dist/index.js (the host has no tsc; see Pitfall 2 in 11-RESEARCH.md).
 */
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { GUARD_DIRECTIVE } from "./guard.js";
import { METERING_DIRECTIVE } from "./metering.js";
import { safeBeforeToolCall, safeBeforeAgentFinalize, safeAgentEnd, } from "./gate.js";
export default definePluginEntry({
    id: "revenium-enforcement",
    name: "Revenium Enforcement",
    description: "Injects guardrail directive on every turn and gates task marker writing.",
    register(api) {
        // FAIL-OPEN GUARANTEE (CR-01): every handler body is wrapped in try/catch so
        // a throw from the gate logic can NEVER reject the hook promise. The safe*
        // wrappers in gate.js contain the same containment (so the property is
        // unit-testable without the openclaw peer); the local try/catch here is a
        // defensive second layer that also guards the ctx/event dereferences below.
        // before_prompt_build: NOT a conversation hook — no allowConversationAccess needed.
        // Injects two directives on every turn:
        //   <revenium-guard>    — BUDGET-GUARD.md guardrail enforcement (turn START), D-02/D-10
        //   <revenium-metering> — task-classification + job-declaration completion gates (turn END)
        // The metering block is the NemoClaw equivalent of standalone post-install.sh step 7b
        // (which injects it into AGENTS.md). Without it the in-sandbox agent is never told to
        // run write-marker.sh / write-job-marker.sh, so Revenium sees no task-type attribution
        // and no agentic jobs — the markers report.sh needs to call `revenium jobs create`.
        api.on("before_prompt_build", () => {
            try {
                return {
                    prependContext: "<revenium-guard>\n" + GUARD_DIRECTIVE + "\n</revenium-guard>\n" +
                        "<revenium-metering>\n" + METERING_DIRECTIVE + "\n</revenium-metering>",
                };
            }
            catch {
                return undefined; // fail-open: never block the turn
            }
        });
        // before_tool_call: NOT a conversation hook — no allowConversationAccess needed.
        api.on("before_tool_call", async (event, ctx) => {
            try {
                safeBeforeToolCall(ctx?.runId, event?.toolName, event?.params);
            }
            catch { /* fail-open: observation is best-effort, never block the turn */ }
        });
        // before_agent_finalize: IS a conversation hook — requires allowConversationAccess: true
        // in the openclaw config (see post-install-nemoclaw.sh for the config patch).
        // A thrown error MUST resolve to undefined (pass-through), never a rejection.
        // event.messages is the conversation transcript array (PluginHookBeforeAgentFinalizeEvent).
        // It is passed to safeBeforeAgentFinalize so the transcript-scan path (B-05)
        // can detect Nemotron's tool_search_code exec pattern.
        api.on("before_agent_finalize", async (event, ctx) => {
            try {
                return safeBeforeAgentFinalize(ctx?.runId, event?.messages, { log: (msg) => api.logger.info(msg) });
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
