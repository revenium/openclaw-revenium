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

import { existsSync, mkdirSync, writeFileSync, readFileSync, rmSync, readdirSync } from "node:fs";
import { join } from "node:path";

// ---------------------------------------------------------------------------
// Run-state persistence (B-05 / NCENF-02)
//
// exec observations are written to a small per-runId JSON file so that the
// marker revise loop survives a `nemoclaw recover` (which spawns a fresh
// gateway process with empty in-process Sets). `before_agent_finalize` reads
// the file as a fallback when the in-process Set is empty.
//
// Base dir resolution mirrors scripts/common.sh OPENCLAW_HOME discovery:
//   1. OPENCLAW_HOME env override (e.g. /sandbox/.openclaw in-sandbox)
//   2. ${HOME}/.openclaw fallback
//
// Tests inject a tmp dir via setRunStateDir(dir) to avoid touching real state.
// ---------------------------------------------------------------------------

/** @type {string|null} Injectable base dir for tests (null = use env-derived default). */
let _runStateDirOverride = null;

/**
 * Set the run-state base directory (used by tests to inject a tmp dir).
 * Pass null to revert to the default env-derived directory.
 *
 * @param {string|null} dir
 */
export function setRunStateDir(dir) {
  _runStateDirOverride = dir;
}

/**
 * Resolve the run-state base directory.
 * Mirrors scripts/common.sh OPENCLAW_HOME discovery (honors env override).
 *
 * @returns {string}
 */
function resolveRunStateDir() {
  if (_runStateDirOverride !== null) return _runStateDirOverride;
  const ocHome = process.env.OPENCLAW_HOME || (process.env.HOME + "/.openclaw");
  return join(ocHome, "run-state");
}

/**
 * Sanitize a runId to a safe basename (path-traversal guard — T-15-RS-01).
 * Strips any character outside [A-Za-z0-9._-] and rejects empty result.
 *
 * @param {string} runId
 * @returns {string|null} Sanitized basename, or null if empty after sanitization.
 */
function sanitizeRunId(runId) {
  const safe = String(runId).replace(/[^A-Za-z0-9._-]/g, "");
  return safe.length > 0 ? safe : null;
}

/**
 * Resolve the full path for a run-state file.
 * Returns null if runId sanitizes to empty (traversal-safe rejection).
 *
 * @param {string} runId
 * @returns {string|null}
 */
function runStatePath(runId) {
  const safe = sanitizeRunId(runId);
  if (!safe) return null;
  return join(resolveRunStateDir(), safe + ".json");
}

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
 * Write run-state to disk (fail-open — any error is silently swallowed).
 * Creates the base dir with mkdirSync({ recursive: true }).
 * File is written with mode 0o600 (owner-only — T-15-RS-03).
 *
 * @param {string} runId
 * @param {boolean} marked
 */
function persistRunState(runId, marked) {
  try {
    const filePath = runStatePath(runId);
    if (!filePath) return; // sanitized to empty — skip silently
    const dir = resolveRunStateDir();
    mkdirSync(dir, { recursive: true });
    const content = JSON.stringify({ exec: true, marked, updatedAt: Date.now() });
    writeFileSync(filePath, content, { encoding: "utf8", mode: 0o600 });
  } catch {
    /* fail-open: a write failure must NOT change in-process behavior or throw */
  }
}

/**
 * Reset tracking state (used by tests to isolate cases).
 *
 * Clears the in-process Sets. If a test base dir is set via setRunStateDir(),
 * also removes its contents (best-effort) so disk state from one test does not
 * leak into the next. This guard is conditional on _runStateDirOverride being set,
 * so it never touches a real OPENCLAW_HOME unexpectedly in production.
 */
export function resetState() {
  execRuns.clear();
  markedTaskRuns.clear();
  _loggedFirstExec = false;
  // If a test-injected base dir is active, clean its contents (test isolation).
  if (_runStateDirOverride !== null) {
    try {
      const entries = readdirSync(_runStateDirOverride);
      for (const entry of entries) {
        try { rmSync(join(_runStateDirOverride, entry)); } catch { /* ignore */ }
      }
    } catch {
      /* ignore — dir may not exist yet or may already be clean */
    }
  }
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
    // Persist exec observation — preserve prior marked state (WR-01: do NOT unconditionally
    // downgrade a prior marked:true record; check markedTaskRuns before persisting).
    persistRunState(runId, markedTaskRuns.has(runId));
    return;
  }

  execRuns.add(runId);
  // Match the actual invocation of write-marker.sh, not an arbitrary substring
  // (WR-02): a command that merely mentions the script name must NOT classify.
  const isMarked = MARKER_INVOKE.test(cmd);
  if (isMarked) {
    markedTaskRuns.add(runId);
  }
  // Persist exec observation to disk (owner-only, fail-open — T-15-RS-03).
  persistRunState(runId, isMarked || markedTaskRuns.has(runId));
}

/**
 * Handle a before_agent_finalize event.
 *
 * Returns a revise action when an exec tool ran but write-marker.sh did not;
 * returns undefined (pass-through) in all other cases (fail-open).
 *
 * Disk fallback (B-05): when in-process execRuns does not contain runId (e.g.
 * after a `nemoclaw recover` spawning a fresh gateway process), reads the
 * persisted run-state file to determine if the run was substantive. Any fs
 * error in the fallback path resolves to pass-through (fail-open).
 *
 * @param {string|undefined} runId - The ctx.runId from the hook context.
 * @returns {{ action: "revise", reason: string, retry: { instruction: string, idempotencyKey: string, maxAttempts: number } } | undefined}
 */
export function handleBeforeAgentFinalize(runId) {
  // fail-open: no runId
  if (!runId) return undefined;

  // In-process path (normal case: same gateway process).
  if (execRuns.has(runId)) {
    // Already classified → pass through
    if (markedTaskRuns.has(runId)) return undefined;
    // Substantive turn with no marker → force one more pass.
    return _buildReviseAction(runId);
  }

  // Disk fallback (B-05): in-process execRuns is empty for this runId, which
  // happens when `nemoclaw recover` spawned a fresh gateway process. Read the
  // persisted state file to determine if this run was substantive.
  try {
    const filePath = runStatePath(runId);
    if (filePath && existsSync(filePath)) {
      const raw = readFileSync(filePath, "utf8");
      const state = JSON.parse(raw);
      if (state && state.exec === true) {
        // Run was substantive per disk record.
        if (state.marked === true) return undefined; // already classified
        return _buildReviseAction(runId); // needs marker
      }
    }
  } catch {
    /* fail-open: any read/parse error → pass through (undefined) */
  }

  // Non-substantive turn (no exec tool ran in this run) → pass through.
  return undefined;
}

/**
 * Build the static revise action.
 * The instruction is a STATIC string — no event/conversation input interpolated
 * (T-11-injection mitigation).
 *
 * @param {string} runId
 */
function _buildReviseAction(runId) {
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
 * Clears both tracking sets for the given runId (Pitfall 3 leak prevention)
 * and deletes the persisted run-state file (T-15-RS-04 disk-exhaustion mitigation).
 *
 * @param {string|undefined} runId - The ctx.runId from the hook context.
 */
export function handleAgentEnd(runId) {
  if (runId) {
    execRuns.delete(runId);
    markedTaskRuns.delete(runId);
    // Delete persisted run-state file (best-effort, swallow errors — T-15-RS-04).
    try {
      const filePath = runStatePath(runId);
      if (filePath && existsSync(filePath)) {
        rmSync(filePath);
      }
    } catch {
      /* best-effort cleanup — a cleanup miss leaks one small stale file */
    }
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
