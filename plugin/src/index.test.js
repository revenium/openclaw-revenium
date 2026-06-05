/**
 * index.test.js — node:test unit suite for the revenium-marker-gate plugin.
 *
 * Tests the pure gate logic in ./gate.js directly (no openclaw peer needed,
 * no tsc needed). Covers all <behavior> cases from 11-01-PLAN.md:
 *
 * SC-1 (revise on unclassified exec turn):
 *   before_agent_finalize returns a bounded revise when exec ran but write-marker.sh did not.
 *
 * SC-2 (bounded + fail-open):
 *   maxAttempts === 1; undefined returned for non-substantive / already-marked / no-runId.
 *
 * Run: node --test src/index.test.js  (from plugin/ directory)
 */
import { test, describe, beforeEach } from "node:test";
import assert from "node:assert/strict";
import {
  execRuns,
  markedTaskRuns,
  resetState,
  handleBeforeToolCall,
  handleBeforeAgentFinalize,
  handleAgentEnd,
} from "./gate.js";

// Shared runIds for tests
const RUN_A = "run-aaa-001";
const RUN_B = "run-bbb-002";

// Reset module-level state before each test to prevent leakage.
beforeEach(() => {
  resetState();
});

// ---------------------------------------------------------------------------
// before_tool_call — exec tool tracking
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
    // Simulate code-mode exec normalization: command arrives under params.code, not params.command.
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
    // Should not throw and should not add anything
    assert.doesNotThrow(() => handleBeforeToolCall(undefined, "exec", { command: "ls" }));
    assert.equal(execRuns.size, 0);
  });

  test("non-string params.command AND non-string params.code → guarded, adds to execRuns, no throw", () => {
    // Both params fields are non-string; the guard should prevent .includes() on them.
    assert.doesNotThrow(() => handleBeforeToolCall(RUN_A, "exec", { command: 42, code: null }));
    // runId still added to execRuns (conservative: we know exec ran, just not what command)
    assert.ok(execRuns.has(RUN_A), "execRuns should contain runId even when command is non-string");
    assert.ok(!markedTaskRuns.has(RUN_A), "markedTaskRuns should NOT contain runId");
  });
});

// ---------------------------------------------------------------------------
// before_agent_finalize — gate logic
// ---------------------------------------------------------------------------

describe("before_agent_finalize - gate logic", () => {
  test("no runId → returns undefined (fail-open)", () => {
    const result = handleBeforeAgentFinalize(undefined);
    assert.equal(result, undefined, "should return undefined when no runId");
  });

  test("no exec ran this runId → returns undefined (non-substantive pass-through)", () => {
    // Don't call handleBeforeToolCall for this runId
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
    // The instruction must reference write-marker.sh
    assert.ok(
      result.retry.instruction.includes("write-marker.sh"),
      "instruction should reference write-marker.sh"
    );
    // The instruction must reference task-taxonomy.json
    assert.ok(
      result.retry.instruction.includes("task-taxonomy.json"),
      "instruction should reference task-taxonomy.json"
    );
    // The instruction must NOT interpolate dynamic data from params
    // (verify it does not contain the actual command value from params)
    assert.ok(!result.retry.instruction.includes("work"), "instruction should not interpolate event data");
  });

  test("runId already in markedTaskRuns → returns undefined (already classified)", () => {
    // Simulate: exec ran AND marker was written
    handleBeforeToolCall(RUN_A, "exec", { command: "write-marker.sh analysis" });
    const result = handleBeforeAgentFinalize(RUN_A);

    assert.equal(result, undefined, "should return undefined when already marked");
  });

  test("different runIds tracked independently", () => {
    // RUN_A: exec ran, no marker → should get revise
    handleBeforeToolCall(RUN_A, "exec", { command: "do something" });
    // RUN_B: exec ran WITH marker → should pass through
    handleBeforeToolCall(RUN_B, "exec", { command: "write-marker.sh coding" });

    const resultA = handleBeforeAgentFinalize(RUN_A);
    const resultB = handleBeforeAgentFinalize(RUN_B);

    assert.equal(resultA.action, "revise", "RUN_A should get revise (no marker)");
    assert.equal(resultB, undefined, "RUN_B should pass through (already marked)");
  });
});

// ---------------------------------------------------------------------------
// agent_end — cleanup
// ---------------------------------------------------------------------------

describe("agent_end - cleanup", () => {
  test("agent_end clears both execRuns and markedTaskRuns for the runId", () => {
    // Set up: exec ran + marker written
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
    // RUN_A should still be in execRuns (wasn't cleaned up)
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

    // Now if somehow the same runId reappears in a new turn (shouldn't happen, but test it)
    const result = handleBeforeAgentFinalize(RUN_A);
    assert.equal(result, undefined, "after cleanup, gate should see no exec for this runId");
  });
});
