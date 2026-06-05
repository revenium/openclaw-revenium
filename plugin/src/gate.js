/**
 * gate.js — Pure marker-gate logic for the revenium-marker-gate plugin.
 *
 * This module contains only the logic for tracking exec runs and
 * determining whether a before_agent_finalize revise action is needed.
 * It is a plain ESM module (no TypeScript, no openclaw dependency) so
 * that node:test can import it directly without tsc or the peer package.
 *
 * plugin/src/index.ts imports this module and registers the handlers.
 */

// Per-run tracking state (in-process, not persisted).
// Module-level Sets so they survive across hook calls within the same process.
export const execRuns = new Set();       // runIds that invoked any exec/bash tool
export const markedTaskRuns = new Set(); // runIds that invoked write-marker.sh

// One-time diagnostic: log the observed toolName + params keys on the first
// exec observation so the real command field name is confirmable from host
// logs during the 11-03 Task 2 E2E (resolves open question A1).
let _loggedFirstExec = false;

// Marker invocation matcher (WR-02). A bare `cmd.includes("write-marker.sh")`
// false-positives on any string merely *containing* the token — e.g. an echo
// into a notes file ("...run write-marker.sh later..."), a comment, or a
// `my-write-marker.sh.bak` lookalike. We require write-marker.sh to be the
// script genuinely being invoked, matching exactly one of:
//   (a) interpreter-invoked:  `bash write-marker.sh`, `sh  write-marker.sh`
//   (b) path-invoked:         `./write-marker.sh`, `/abs/write-marker.sh`,
//                             `rel/dir/write-marker.sh`
//   (c) command-position:     the token is the first word of the command, i.e.
//                             at start-of-string or right after a shell command
//                             separator (`;`, `|`, `&`, `(`, `\n`).
// In every case the token must be immediately followed by whitespace or
// end-of-string, so `write-marker.sh.bak` does NOT match. `.sh` escapes the dot
// to a literal. A bare `write-marker.sh` sitting mid-sentence after an ordinary
// word (e.g. `run write-marker.sh`) is deliberately NOT matched — that is the
// mention-only false positive WR-02 targets.
const MARKER_INVOKE =
  /(?:(?:^|[;|&(\n])\s*(?:bash\s+|sh\s+|\S*\/)?|\s+(?:bash\s+|sh\s+|\S*\/))write-marker\.sh(?:\s|$)/;

/**
 * Reset tracking state (used by tests to isolate cases).
 */
export function resetState() {
  execRuns.clear();
  markedTaskRuns.clear();
  _loggedFirstExec = false;
}

/**
 * Handle a before_tool_call event.
 *
 * @param {string|undefined} runId - The ctx.runId from the hook context.
 * @param {string} toolName - The event.toolName.
 * @param {Record<string,unknown>} params - The event.params.
 * @param {{ log?: (msg: string) => void }} [opts] - Optional logger.
 */
export function handleBeforeToolCall(runId, toolName, params, opts = {}) {
  if (!runId) return;

  // Treat both "exec" and "bash" as exec tool calls (Pitfall 5).
  if (toolName !== "exec" && toolName !== "bash") return;

  // One-time diagnostic log: record observed toolName + param key names.
  if (!_loggedFirstExec) {
    _loggedFirstExec = true;
    const paramKeys = params && typeof params === "object" ? Object.keys(params) : [];
    const logFn = (opts && opts.log) ? opts.log : console.log;
    logFn(
      `[revenium-marker-gate] first exec observation: toolName="${toolName}" params keys=[${paramKeys.join(", ")}]`
    );
  }

  // Coalesce command field: params.command first, fallback to params.code (A1).
  let cmd = params && typeof params === "object" ? params.command : undefined;
  if (typeof cmd !== "string" || cmd === "") {
    cmd = params && typeof params === "object" ? params.code : undefined;
  }

  // Guard before any string operation (T-11-cmd-read).
  if (typeof cmd !== "string") {
    execRuns.add(runId);
    return;
  }

  execRuns.add(runId);
  // Match the actual invocation of write-marker.sh, not an arbitrary substring
  // (WR-02): a command that merely mentions the script name must NOT classify.
  if (MARKER_INVOKE.test(cmd)) {
    markedTaskRuns.add(runId);
  }
}

/**
 * Handle a before_agent_finalize event.
 *
 * Returns a revise action when an exec tool ran but write-marker.sh did not;
 * returns undefined (pass-through) in all other cases (fail-open).
 *
 * @param {string|undefined} runId - The ctx.runId from the hook context.
 * @returns {{ action: "revise", reason: string, retry: { instruction: string, idempotencyKey: string, maxAttempts: number } } | undefined}
 */
export function handleBeforeAgentFinalize(runId) {
  // fail-open: no runId
  if (!runId) return undefined;
  // Non-substantive turn (no exec tool ran) → pass through
  if (!execRuns.has(runId)) return undefined;
  // Already classified → pass through
  if (markedTaskRuns.has(runId)) return undefined;

  // Substantive turn with no marker → force one more pass.
  // The instruction is a STATIC string — no event/conversation input interpolated
  // (T-11-injection mitigation).
  return {
    action: "revise",
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
}

/**
 * Handle an agent_end event.
 *
 * Clears both tracking sets for the given runId (Pitfall 3 leak prevention).
 *
 * @param {string|undefined} runId - The ctx.runId from the hook context.
 */
export function handleAgentEnd(runId) {
  if (runId) {
    execRuns.delete(runId);
    markedTaskRuns.delete(runId);
  }
}

// ---------------------------------------------------------------------------
// Fail-open boundary wrappers (CR-01).
//
// The phase's central safety requirement is that the gate must NEVER block or
// break the agent reply on error. index.ts registers `async` hook callbacks; if
// a gate function ever throws (today they are throw-free, but fail-open must be
// guaranteed structurally, not assumed), the rejected promise would propagate to
// the host's dispatcher instead of resolving to a pass-through. These wrappers
// contain the try/catch at the boundary so a throw can NEVER reject the hook
// promise: before_agent_finalize resolves to `undefined` (pass-through / no
// block); the observe/cleanup wrappers swallow silently (best-effort).
//
// They are exported (and accept an injectable `impl`) so node:test can force the
// underlying handler to throw and assert the boundary still returns `undefined`
// and does not reject — without needing the openclaw peer to load index.ts.
// ---------------------------------------------------------------------------

/**
 * Fail-open wrapper for before_agent_finalize.
 *
 * @param {string|undefined} runId
 * @param {{ log?: (msg: string) => void }} [opts] - Optional host logger.
 * @param {(runId: string|undefined) => any} [impl] - Injectable handler (tests).
 * @returns {any} The revise action, or undefined (never throws).
 */
export function safeBeforeAgentFinalize(runId, opts = {}, impl = handleBeforeAgentFinalize) {
  try {
    return impl(runId);
  } catch (err) {
    try {
      const logFn = opts && opts.log ? opts.log : console.error;
      logFn(`[revenium-marker-gate] finalize error (fail-open): ${err}`);
    } catch { /* logging must never break fail-open */ }
    return undefined; // fail-open: never block the reply
  }
}

/**
 * Fail-open wrapper for before_tool_call (observation is best-effort).
 *
 * @param {string|undefined} runId
 * @param {string} toolName
 * @param {Record<string,unknown>} params
 * @param {{ log?: (msg: string) => void }} [opts]
 * @param {(runId: any, toolName: any, params: any, opts: any) => void} [impl]
 */
export function safeBeforeToolCall(runId, toolName, params, opts = {}, impl = handleBeforeToolCall) {
  try {
    impl(runId, toolName, params, opts);
  } catch { /* fail-open: observation is best-effort, never block the turn */ }
}

/**
 * Fail-open wrapper for agent_end (cleanup is best-effort).
 *
 * @param {string|undefined} runId
 * @param {(runId: any) => void} [impl]
 */
export function safeAgentEnd(runId, impl = handleAgentEnd) {
  try {
    impl(runId);
  } catch { /* fail-open */ }
}
