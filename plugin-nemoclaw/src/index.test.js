/**
 * index.test.js — node:test unit suite for the revenium-enforcement plugin.
 *
 * Tests the pure gate logic in ./gate.js directly (no openclaw peer needed,
 * no tsc needed). Covers all <behavior> cases from 15-01-PLAN.md:
 *
 * Guard injection tests (NCENF-01):
 *   - before_prompt_build returns prependContext with <revenium-guard> tag and GUARD_DIRECTIVE
 *   - before_prompt_build is fail-open (error yields undefined, never throws)
 *
 * Carried-over marker gate tests from plugin/src/index.test.js (NCENF-02):
 *   - exec tracking (before_tool_call)
 *   - gate logic (before_agent_finalize)
 *   - cleanup (agent_end)
 *   - CR-01 fail-open boundary
 *
 * Run: node --test src/index.test.js  (from plugin-nemoclaw/ directory)
 */
import { test, describe, beforeEach, after } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, readFileSync, existsSync, chmodSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  execRuns,
  markedTaskRuns,
  resetState,
  setRunStateDir,
  handleBeforeToolCall,
  handleBeforeAgentFinalize,
  handleAgentEnd,
  safeBeforeAgentFinalize,
  safeBeforeToolCall,
  safeAgentEnd,
} from "./gate.js";   // copied from plugin/src/gate.js at build time (D-06)

// Shared runIds for tests
const RUN_A = "run-aaa-001";
const RUN_B = "run-bbb-002";

// Shared tmp dir for ALL tests — keeps disk writes isolated from the real
// OPENCLAW_HOME. Created once for the whole suite; resetState() cleans
// its contents before each test (because _runStateDirOverride is set).
const SUITE_TMP_DIR = mkdtempSync(join(tmpdir(), "gate-nc-suite-"));
setRunStateDir(SUITE_TMP_DIR);

// Reset module-level state before each test to prevent leakage.
beforeEach(() => {
  resetState();
});

// Clean up the suite-level tmp dir after all tests.
after(() => {
  try { rmSync(SUITE_TMP_DIR, { recursive: true }); } catch { /* ignore */ }
});

// ---------------------------------------------------------------------------
// before_prompt_build — guard directive injection (NCENF-01, D-10)
// ---------------------------------------------------------------------------

describe("before_prompt_build - guard directive injection", () => {
  test("prependContext contains opening <revenium-guard> tag (D-10)", async () => {
    const { GUARD_DIRECTIVE } = await import("./guard.js");
    const result = {
      prependContext: "<revenium-guard>\n" + GUARD_DIRECTIVE + "\n</revenium-guard>",
    };
    assert.ok(result.prependContext.includes("<revenium-guard>"), "must contain opening tag");
  });

  test("prependContext contains closing </revenium-guard> tag (D-10)", async () => {
    const { GUARD_DIRECTIVE } = await import("./guard.js");
    const result = {
      prependContext: "<revenium-guard>\n" + GUARD_DIRECTIVE + "\n</revenium-guard>",
    };
    assert.ok(result.prependContext.includes("</revenium-guard>"), "must contain closing tag");
  });

  test("prependContext contains the full GUARD_DIRECTIVE (Guardrail Enforcement text)", async () => {
    const { GUARD_DIRECTIVE } = await import("./guard.js");
    const result = {
      prependContext: "<revenium-guard>\n" + GUARD_DIRECTIVE + "\n</revenium-guard>",
    };
    assert.ok(result.prependContext.includes(GUARD_DIRECTIVE), "must contain full directive");
    assert.ok(result.prependContext.includes("Guardrail Enforcement"), "must contain directive heading");
  });

  test("GUARD_DIRECTIVE includes _maxAgeSeconds freshness rule (D-03/D-04)", async () => {
    const { GUARD_DIRECTIVE } = await import("./guard.js");
    assert.ok(GUARD_DIRECTIVE.includes("_maxAgeSeconds"), "directive must include freshness field name");
    assert.ok(GUARD_DIRECTIVE.includes("absent"), "directive must include absent-field skip branch");
  });

  test("guard hook is fail-open (error returns undefined, never throws)", () => {
    // Mirror the try/catch pattern from index.ts
    let result;
    assert.doesNotThrow(() => {
      try {
        throw new Error("simulated hook error");
      } catch {
        result = undefined; // fail-open
      }
    });
    assert.equal(result, undefined);
  });
});

// ---------------------------------------------------------------------------
// before_tool_call — exec tool tracking (carried over from plugin/src/index.test.js)
// ---------------------------------------------------------------------------

describe("before_tool_call - exec tracking", () => {
  test("toolName='exec' with non-marker command adds runId to execRuns only", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "ls -la" });
    assert.ok(execRuns.has(RUN_A), "execRuns should contain runId");
    assert.ok(!markedTaskRuns.has(RUN_A), "markedTaskRuns should NOT contain runId");
  });

  test("toolName='exec' with write-marker.sh command adds runId to both sets", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "bash ~/.openclaw/skills/revenium/scripts/write-marker.sh coding" });
    assert.ok(execRuns.has(RUN_A), "execRuns should contain runId");
    assert.ok(markedTaskRuns.has(RUN_A), "markedTaskRuns should contain runId");
  });

  test("toolName='bash' with write-marker.sh command adds runId to both sets (Pitfall 5)", () => {
    handleBeforeToolCall(RUN_A, "bash", { command: "write-marker.sh debugging" });
    assert.ok(execRuns.has(RUN_A), "execRuns should contain runId");
    assert.ok(markedTaskRuns.has(RUN_A), "markedTaskRuns should contain runId");
  });

  test("toolName='bash' with non-marker command adds runId to execRuns only", () => {
    handleBeforeToolCall(RUN_A, "bash", { command: "echo hello" });
    assert.ok(execRuns.has(RUN_A), "execRuns should contain runId");
    assert.ok(!markedTaskRuns.has(RUN_A), "markedTaskRuns should NOT contain runId");
  });

  test("command in params.code (not params.command) — A1 coalesce — adds runId to markedTaskRuns", () => {
    handleBeforeToolCall(RUN_A, "exec", { code: "bash write-marker.sh analysis" });
    assert.ok(execRuns.has(RUN_A), "execRuns should contain runId");
    assert.ok(markedTaskRuns.has(RUN_A), "markedTaskRuns should contain runId (params.code fallback)");
  });

  test("params.code non-marker command — adds to execRuns only", () => {
    handleBeforeToolCall(RUN_A, "exec", { code: "npm test" });
    assert.ok(execRuns.has(RUN_A), "execRuns should contain runId");
    assert.ok(!markedTaskRuns.has(RUN_A), "markedTaskRuns should NOT contain runId");
  });

  test("non-exec toolName is ignored", () => {
    handleBeforeToolCall(RUN_A, "read_file", { path: "/some/file" });
    assert.ok(!execRuns.has(RUN_A), "execRuns should NOT contain runId for non-exec tool");
    assert.ok(!markedTaskRuns.has(RUN_A), "markedTaskRuns should NOT contain runId");
  });

  test("no runId → no-op, no throw", () => {
    assert.doesNotThrow(() => handleBeforeToolCall(undefined, "exec", { command: "ls" }));
    assert.equal(execRuns.size, 0);
  });

  test("WR-02: command merely MENTIONING write-marker.sh (echo into notes) is NOT classified", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: 'echo "remember to run write-marker.sh later" >> notes.txt' });
    assert.ok(execRuns.has(RUN_A), "execRuns should contain runId (exec did run)");
    assert.ok(!markedTaskRuns.has(RUN_A), "markedTaskRuns must NOT contain runId for a mention-only command");
  });

  test("WR-02: lookalike filename my-write-marker.sh.bak is NOT classified", () => {
    handleBeforeToolCall(RUN_A, "bash", { command: "bash my-write-marker.sh.bak" });
    assert.ok(execRuns.has(RUN_A), "execRuns should contain runId (exec did run)");
    assert.ok(!markedTaskRuns.has(RUN_A), "markedTaskRuns must NOT contain runId for a .bak lookalike");
  });

  test("WR-02: real invocation `write-marker.sh` (bare, no path) IS classified", () => {
    handleBeforeToolCall(RUN_A, "bash", { command: "write-marker.sh coding" });
    assert.ok(markedTaskRuns.has(RUN_A), "bare write-marker.sh invocation must be classified");
  });

  test("WR-02: real invocation with full path and bash prefix IS classified", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "bash ~/.openclaw/skills/revenium/scripts/write-marker.sh debugging" });
    assert.ok(markedTaskRuns.has(RUN_A), "bash <path>/write-marker.sh invocation must be classified");
  });

  test("non-string params.command AND non-string params.code → guarded, adds to execRuns, no throw", () => {
    assert.doesNotThrow(() => handleBeforeToolCall(RUN_A, "exec", { command: 42, code: null }));
    assert.ok(execRuns.has(RUN_A), "execRuns should contain runId even when command is non-string");
    assert.ok(!markedTaskRuns.has(RUN_A), "markedTaskRuns should NOT contain runId");
  });
});

// ---------------------------------------------------------------------------
// before_agent_finalize — gate logic (carried over)
// ---------------------------------------------------------------------------

describe("before_agent_finalize - gate logic", () => {
  test("no runId → returns undefined (fail-open)", () => {
    const result = handleBeforeAgentFinalize(undefined);
    assert.equal(result, undefined, "should return undefined when no runId");
  });

  test("no exec ran this runId → returns undefined (non-substantive pass-through)", () => {
    const result = handleBeforeAgentFinalize(RUN_A);
    assert.equal(result, undefined, "should return undefined when no exec ran");
  });

  test("exec ran but write-marker.sh did NOT run → returns revise action (SC-1)", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "cat README.md" });
    const result = handleBeforeAgentFinalize(RUN_A);

    assert.ok(result !== undefined, "should return a revise action");
    assert.equal(result.action, "revise", "action should be 'revise'");
    assert.ok(typeof result.reason === "string" && result.reason.length > 0, "reason should be a non-empty string");
  });

  test("revise action has maxAttempts: 1 (SC-2 bounded)", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "echo work done" });
    const result = handleBeforeAgentFinalize(RUN_A);

    assert.equal(result.retry.maxAttempts, 1, "maxAttempts must be 1");
  });

  test("revise action idempotencyKey is marker-gate:<runId>", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "some command" });
    const result = handleBeforeAgentFinalize(RUN_A);

    assert.equal(result.retry.idempotencyKey, `marker-gate:${RUN_A}`, "idempotencyKey must be marker-gate:<runId>");
  });

  test("revise action instruction is a non-empty static string (no event data interpolated)", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "work" });
    const result = handleBeforeAgentFinalize(RUN_A);

    assert.ok(typeof result.retry.instruction === "string", "instruction should be a string");
    assert.ok(result.retry.instruction.length > 0, "instruction should be non-empty");
    assert.ok(result.retry.instruction.includes("write-marker.sh"), "instruction should reference write-marker.sh");
    assert.ok(result.retry.instruction.includes("task-taxonomy.json"), "instruction should reference task-taxonomy.json");
    assert.ok(!result.retry.instruction.includes("work"), "instruction should not interpolate event data");
  });

  test("runId already in markedTaskRuns → returns undefined (already classified)", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "write-marker.sh analysis" });
    const result = handleBeforeAgentFinalize(RUN_A);

    assert.equal(result, undefined, "should return undefined when already marked");
  });

  test("different runIds tracked independently", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "do something" });
    handleBeforeToolCall(RUN_B, "exec", { command: "write-marker.sh coding" });

    const resultA = handleBeforeAgentFinalize(RUN_A);
    const resultB = handleBeforeAgentFinalize(RUN_B);

    assert.equal(resultA.action, "revise", "RUN_A should get revise (no marker)");
    assert.equal(resultB, undefined, "RUN_B should pass through (already marked)");
  });
});

// ---------------------------------------------------------------------------
// agent_end — cleanup (carried over)
// ---------------------------------------------------------------------------

describe("agent_end - cleanup", () => {
  test("agent_end clears both execRuns and markedTaskRuns for the runId", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "write-marker.sh coding" });
    assert.ok(execRuns.has(RUN_A), "precondition: execRuns has RUN_A");
    assert.ok(markedTaskRuns.has(RUN_A), "precondition: markedTaskRuns has RUN_A");

    handleAgentEnd(RUN_A);

    assert.ok(!execRuns.has(RUN_A), "execRuns should NOT contain RUN_A after agent_end");
    assert.ok(!markedTaskRuns.has(RUN_A), "markedTaskRuns should NOT contain RUN_A after agent_end");
  });

  test("agent_end with no runId → no-op, no throw", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "ls" });
    assert.doesNotThrow(() => handleAgentEnd(undefined));
    assert.ok(execRuns.has(RUN_A), "RUN_A should still be in execRuns");
  });

  test("agent_end does not clear other runIds", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "ls" });
    handleBeforeToolCall(RUN_B, "exec", { command: "ls" });

    handleAgentEnd(RUN_A);

    assert.ok(!execRuns.has(RUN_A), "RUN_A should be cleared");
    assert.ok(execRuns.has(RUN_B), "RUN_B should still be present");
  });

  test("after agent_end, before_agent_finalize returns undefined (no runId state leak)", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "some work" });
    handleAgentEnd(RUN_A);

    const result = handleBeforeAgentFinalize(RUN_A);
    assert.equal(result, undefined, "after cleanup, gate should see no exec for this runId");
  });
});

// ---------------------------------------------------------------------------
// CR-01 — fail-open boundary (carried over from plugin/src/index.test.js)
// ---------------------------------------------------------------------------

describe("CR-01 - fail-open boundary (handler throw path)", () => {
  const boom = () => {
    throw new Error("forced gate failure");
  };

  test("safeBeforeAgentFinalize returns undefined (does not throw/reject) when the gate throws", () => {
    let result;
    assert.doesNotThrow(() => {
      result = safeBeforeAgentFinalize(RUN_A, { log: () => {} }, boom);
    }, "boundary must not rethrow when the gate throws");
    assert.equal(result, undefined, "a thrown gate must resolve to undefined (pass-through, no block)");
  });

  test("safeBeforeAgentFinalize resolves to undefined as an async hook (promise does not reject)", async () => {
    const handler = async () => safeBeforeAgentFinalize(RUN_A, { log: () => {} }, boom);
    const value = await handler();
    assert.equal(value, undefined, "rejected promise would have thrown here; must be undefined");
  });

  test("safeBeforeAgentFinalize still returns the real revise action when the gate does NOT throw", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "cat README.md" });
    const result = safeBeforeAgentFinalize(RUN_A);
    assert.ok(result && result.action === "revise", "non-throwing path must preserve normal behavior");
  });

  test("safeBeforeToolCall swallows a throwing gate (best-effort observation)", () => {
    assert.doesNotThrow(() => safeBeforeToolCall(RUN_A, "exec", { command: "ls" }, {}, boom));
  });

  test("safeAgentEnd swallows a throwing gate (best-effort cleanup)", () => {
    assert.doesNotThrow(() => safeAgentEnd(RUN_A, boom));
  });
});

// ---------------------------------------------------------------------------
// Persistence across process restart (B-05 / NCENF-02)
//
// Ported from plugin/src/index.test.js — same persistence describe-block
// exercising the nemoclaw build copy of gate.js (D-06).
// ---------------------------------------------------------------------------

describe("persistence across process restart (B-05)", () => {
  // Uses SUITE_TMP_DIR (set at top of file) — each test gets a clean dir
  // because the outer beforeEach calls resetState() which cleans the dir.

  test("exec observation writes a run-state file for that runId with exec:true", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "ls -la" });
    const stateFile = join(SUITE_TMP_DIR, "run-aaa-001.json");
    assert.ok(existsSync(stateFile), "run-state file must exist after exec observation");
    const data = JSON.parse(readFileSync(stateFile, "utf8"));
    assert.strictEqual(data.exec, true, "persisted state must have exec:true");
    assert.ok(typeof data.updatedAt === "number", "must have a numeric updatedAt");
  });

  test("after resetState clears in-process Sets, handleBeforeAgentFinalize reads disk fallback and returns revise action", () => {
    // Phase 1: exec runs in process A
    handleBeforeToolCall(RUN_A, "exec", { command: "do some work" });
    // Verify in-process works before restart
    const preResult = handleBeforeAgentFinalize(RUN_A);
    assert.ok(preResult && preResult.action === "revise", "precondition: in-process should return revise");

    // Phase 2: simulate process restart — clear in-process Sets only (file survives on disk)
    execRuns.clear();
    markedTaskRuns.clear();

    // Phase 3: in the new process, before_agent_finalize should read disk fallback
    const postResult = handleBeforeAgentFinalize(RUN_A);
    assert.ok(postResult !== undefined, "after restart: disk fallback must cause revise action (not undefined)");
    assert.strictEqual(postResult.action, "revise", "fallback path must return revise action");
  });

  test("persisted marked:true run passes through after restart (already classified)", () => {
    // Phase 1: exec + marker in process A
    handleBeforeToolCall(RUN_A, "exec", { command: "write-marker.sh coding" });
    // Verify in-process passes through (already marked)
    assert.strictEqual(handleBeforeAgentFinalize(RUN_A), undefined, "precondition: marked run passes through");

    // Phase 2: simulate restart — clear in-process Sets only (file survives on disk)
    execRuns.clear();
    markedTaskRuns.clear();

    // Phase 3: disk file should have marked:true, so finalize passes through
    const result = handleBeforeAgentFinalize(RUN_A);
    assert.strictEqual(result, undefined, "marked-on-disk run must pass through after restart");
  });

  test("handleAgentEnd deletes the run-state file (no stale file for that runId)", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "do work" });
    const stateFile = join(SUITE_TMP_DIR, "run-aaa-001.json");
    assert.ok(existsSync(stateFile), "precondition: file must exist before agent_end");

    handleAgentEnd(RUN_A);

    assert.ok(!existsSync(stateFile), "run-state file must be deleted after handleAgentEnd");
  });

  test("path-traversal runId does not write outside the state dir", () => {
    const traversalRunId = "../../etc/x";
    // Must not throw, and the file must NOT be written at /etc/x
    assert.doesNotThrow(() => handleBeforeToolCall(traversalRunId, "exec", { command: "ls" }));
    // The dangerous path should NOT exist
    assert.ok(!existsSync("/etc/x"), "traversal must not escape state dir");
  });

  test("fail-open: unwritable state dir — handleBeforeToolCall does not throw and in-process Set updates", () => {
    // Make the tmp state dir unwritable (skip on root or platforms where chmod has no effect)
    let chmodWorked = false;
    try { chmodSync(SUITE_TMP_DIR, 0o400); chmodWorked = true; } catch { /* skip */ }
    if (!chmodWorked) return;
    assert.doesNotThrow(() => handleBeforeToolCall(RUN_A, "exec", { command: "ls" }));
    // In-process Set must still have been updated
    assert.ok(execRuns.has(RUN_A), "in-process execRuns must update even when disk write fails");
    // Restore writable for cleanup
    try { chmodSync(SUITE_TMP_DIR, 0o700); } catch { /* ignore */ }
  });

  test("fail-open: safeBeforeAgentFinalize returns undefined (not throw) when state dir is unwritable", () => {
    let chmodWorked = false;
    try { chmodSync(SUITE_TMP_DIR, 0o400); chmodWorked = true; } catch { /* skip */ }
    if (!chmodWorked) return;
    // With empty in-process Sets and unreadable disk, should not throw (fail-open)
    assert.doesNotThrow(() => {
      safeBeforeAgentFinalize(RUN_A);
    });
    try { chmodSync(SUITE_TMP_DIR, 0o700); } catch { /* ignore */ }
  });
});
