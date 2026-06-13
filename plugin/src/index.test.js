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
import { test, describe, beforeEach, after } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, rmSync, writeFileSync, readFileSync, existsSync, chmodSync } from "node:fs";
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
} from "./gate.js";

// Shared runIds for tests
const RUN_A = "run-aaa-001";
const RUN_B = "run-bbb-002";

// Shared tmp dir for ALL tests — keeps disk writes isolated from the real
// OPENCLAW_HOME. Created once for the whole suite; resetState() cleans
// its contents before each test (because _runStateDirOverride is set).
const SUITE_TMP_DIR = mkdtempSync(join(tmpdir(), "gate-suite-"));
setRunStateDir(SUITE_TMP_DIR);

// Reset module-level state before each test to prevent leakage.
// setRunStateDir is already set to SUITE_TMP_DIR for the whole suite;
// resetState() will clean the tmp dir contents (test isolation for disk).
beforeEach(() => {
  resetState();
});

// Clean up the suite-level tmp dir after all tests.
after(() => {
  try { rmSync(SUITE_TMP_DIR, { recursive: true }); } catch { /* ignore */ }
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

  test("read-only toolName (read) is ignored — status checks never trip the gate", () => {
    handleBeforeToolCall(RUN_A, "read", { path: "/some/file" });
    assert.ok(!execRuns.has(RUN_A), "execRuns should NOT contain runId for read-only tool");
    assert.ok(!markedTaskRuns.has(RUN_A), "markedTaskRuns should NOT contain runId");
  });

  test("tool_search / tool_search_code ignored in before_tool_call (search surface is read-only here)", () => {
    handleBeforeToolCall(RUN_A, "tool_search", { query: "x" });
    handleBeforeToolCall(RUN_A, "tool_search_code", { code: "openclaw.tools.list()" });
    assert.ok(!execRuns.has(RUN_A), "execRuns should NOT contain runId");
  });

  test("non-exec WORKING tool (write) marks the run substantive (2026-06-13 file-tool blind spot)", () => {
    handleBeforeToolCall(RUN_A, "write", { path: "/tmp/zoo.txt", content: "lion" });
    assert.ok(execRuns.has(RUN_A), "execRuns should contain runId for a write tool call");
    assert.ok(!markedTaskRuns.has(RUN_A), "write tool is not a marker invocation");
  });

  test("non-exec WORKING tool (edit) marks the run substantive", () => {
    handleBeforeToolCall(RUN_A, "edit", { path: "/tmp/x", oldText: "a", newText: "b" });
    assert.ok(execRuns.has(RUN_A), "execRuns should contain runId for an edit tool call");
  });

  test("no runId → no-op, no throw", () => {
    // Should not throw and should not add anything
    assert.doesNotThrow(() => handleBeforeToolCall(undefined, "exec", { command: "ls" }));
    assert.equal(execRuns.size, 0);
  });

  // WR-02: marker detection must match the actual invocation of write-marker.sh,
  // not an arbitrary substring that merely contains the script name.
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

// ---------------------------------------------------------------------------
// CR-01 — fail-open boundary: a throw in any gate handler must NEVER reject the
// hook promise. The safe* wrappers contain the try/catch at the host boundary.
// We force the underlying handler to throw via the injectable `impl` parameter
// (the same shape index.ts wires up) and assert the boundary swallows it.
// ---------------------------------------------------------------------------

describe("CR-01 - fail-open boundary (handler throw path)", () => {
  const boom = () => {
    throw new Error("forced gate failure");
  };

  test("safeBeforeAgentFinalize returns undefined (does not throw/reject) when the gate throws", () => {
    let result;
    // Suppress the fail-open log line during the test.
    assert.doesNotThrow(() => {
      result = safeBeforeAgentFinalize(RUN_A, { log: () => {} }, boom);
    }, "boundary must not rethrow when the gate throws");
    assert.equal(result, undefined, "a thrown gate must resolve to undefined (pass-through, no block)");
  });

  test("safeBeforeAgentFinalize resolves to undefined as an async hook (promise does not reject)", async () => {
    // Mirror index.ts: the handler is an async callback returning the wrapper result.
    const handler = async () => safeBeforeAgentFinalize(RUN_A, { log: () => {} }, boom);
    const value = await handler(); // must resolve, never reject
    assert.equal(value, undefined, "rejected promise would have thrown here; must be undefined");
  });

  test("safeBeforeAgentFinalize still returns the real revise action when the gate does NOT throw", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "cat README.md" });
    const result = safeBeforeAgentFinalize(RUN_A); // default impl = real handler
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
// These tests verify that exec observations written to disk survive a simulated
// process restart (resetState() clears in-process Sets but the disk file remains),
// and that before_agent_finalize correctly reads the disk fallback to issue the
// revise action.
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

// ---------------------------------------------------------------------------
// WR-01 / WR-04 — non-string-command exec path must NOT downgrade marked:true
//
// Gap: plugin/src/gate.js line 189 called persistRunState(runId, false)
// unconditionally on the non-string-command path, overwriting a prior
// marked:true disk record. After nemoclaw recover + resetState() the disk
// record was marked:false → spurious revise for an already-classified run.
//
// Fix: change to persistRunState(runId, markedTaskRuns.has(runId)) so a prior
// marker classification is preserved when a non-string command exec follows.
// ---------------------------------------------------------------------------

describe("WR-01 / WR-04 — non-string exec path does NOT downgrade marked:true", () => {
  // Uses SUITE_TMP_DIR — each test gets a clean state from the outer beforeEach.

  test("WR-04 regression: marker exec → non-string exec → resetState → finalize returns undefined (no spurious revise)", () => {
    // Step 1: marker exec (write-marker.sh) — writes marked:true to disk
    handleBeforeToolCall(RUN_A, "exec", { command: "bash ~/.openclaw/skills/revenium/scripts/write-marker.sh coding" });
    assert.ok(markedTaskRuns.has(RUN_A), "precondition: RUN_A in markedTaskRuns after marker exec");

    // Step 2: non-string-command exec on the same runId (command is a number, not a string)
    handleBeforeToolCall(RUN_A, "exec", { command: 42 });

    // Step 3: simulate nemoclaw recover — clear in-process Sets only (disk file survives)
    resetState();
    assert.ok(!markedTaskRuns.has(RUN_A), "in-process Sets cleared after resetState");
    assert.ok(!execRuns.has(RUN_A), "in-process Sets cleared after resetState");

    // Step 4: finalize should return undefined (already marked on disk) — NOT a revise
    const result = handleBeforeAgentFinalize(RUN_A);
    assert.strictEqual(result, undefined, "WR-04: finalize must return undefined (pass-through) — marked:true must survive non-string exec");
  });

  test("WR-01: disk record after marker→non-string sequence has marked:true (not downgraded)", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "write-marker.sh coding" });
    handleBeforeToolCall(RUN_A, "exec", { command: 42 }); // non-string — must NOT overwrite marked:true

    const stateFile = join(SUITE_TMP_DIR, "run-aaa-001.json");
    assert.ok(existsSync(stateFile), "run-state file must exist");
    const data = JSON.parse(readFileSync(stateFile, "utf8"));
    assert.strictEqual(data.marked, true, "WR-01: disk marked must remain true after non-string exec (no downgrade)");
  });

  test("non-string exec on a never-marked runId still persists marked:false (no false upgrade)", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: 42 }); // no prior marker — must persist false

    const stateFile = join(SUITE_TMP_DIR, "run-aaa-001.json");
    assert.ok(existsSync(stateFile), "run-state file must exist");
    const data = JSON.parse(readFileSync(stateFile, "utf8"));
    assert.strictEqual(data.marked, false, "non-string exec on unmarked run must persist marked:false");
  });

  test("non-string exec with null params.code also preserves prior marked:true on disk", () => {
    // Another non-string variant: params.code is null
    handleBeforeToolCall(RUN_A, "exec", { command: "write-marker.sh analysis" }); // mark first
    handleBeforeToolCall(RUN_A, "exec", { command: undefined, code: null }); // non-string follow-up

    const stateFile = join(SUITE_TMP_DIR, "run-aaa-001.json");
    const data = JSON.parse(readFileSync(stateFile, "utf8"));
    assert.strictEqual(data.marked, true, "null code variant: marked:true must be preserved");
  });
});

// ---------------------------------------------------------------------------
// B-05 transcript-scan observation (B-05 / NCENF-02)
//
// Confirms that handleBeforeAgentFinalize gains a transcript-scan observation
// source that detects Nemotron's tool_search_code-based exec invocations, and
// that safeBeforeAgentFinalize properly threads the transcript to impl.
//
// Schema (confirmed live on host 34.224.27.67, session 524a4a76):
//   event.messages[N].message.role === "assistant"
//   event.messages[N].message.content[M].type === "toolCall"
//   event.messages[N].message.content[M].name === "tool_search_code"
//   event.messages[N].message.content[M].arguments.code contains "openclaw:core:exec"
// ---------------------------------------------------------------------------

// Helper: build a minimal transcript message list with a tool_search_code exec call
function makeTranscriptWithExec(cmd = "echo hello", includeMarker = false) {
  const execCode = `return await openclaw.tools.call('openclaw:core:exec', { command: '${cmd}' });`;
  const markerCode = `return await openclaw.tools.call('openclaw:core:exec', { command: 'bash ~/.openclaw/skills/revenium/scripts/write-marker.sh coding' });`;
  const messages = [
    {
      // A prior user message
      type: "message",
      message: { role: "user", content: [{ type: "text", text: "do something" }] }
    },
    {
      // Assistant calls tool_search_code with openclaw:core:exec inside
      type: "message",
      message: {
        role: "assistant",
        content: [
          {
            type: "toolCall",
            id: "call_test_exec",
            name: "tool_search_code",
            arguments: { code: execCode }
          }
        ]
      }
    },
  ];
  if (includeMarker) {
    messages.push({
      type: "message",
      message: {
        role: "assistant",
        content: [
          {
            type: "toolCall",
            id: "call_test_marker",
            name: "tool_search_code",
            arguments: { code: markerCode }
          }
        ]
      }
    });
  }
  return messages;
}

describe("transcript-scan observation (B-05)", () => {
  // Uses SUITE_TMP_DIR — each test gets clean state from the outer beforeEach.
  // All calls with transcript arg use the schema confirmed in 15-B05-SCHEMA-PROBE.md.

  test("B-05: transcript with tool_search_code exec → handleBeforeAgentFinalize returns revise (empty in-process Sets, no disk)", () => {
    const transcript = makeTranscriptWithExec("echo hello");
    // No in-process state, no disk state — only transcript evidence
    const result = handleBeforeAgentFinalize(RUN_A, transcript);
    assert.ok(result !== undefined, "B-05: must return revise action when exec in transcript");
    assert.strictEqual(result.action, "revise", "action must be 'revise'");
  });

  test("B-05: transcript with write-marker.sh exec → handleBeforeAgentFinalize returns undefined (already marked)", () => {
    const transcript = makeTranscriptWithExec("echo hello", true); // includes marker exec
    const result = handleBeforeAgentFinalize(RUN_A, transcript);
    assert.strictEqual(result, undefined, "must pass through when marker write-marker.sh is in transcript");
  });

  test("B-05: transcript with NO exec evidence → handleBeforeAgentFinalize returns undefined", () => {
    const noExecTranscript = [
      { type: "message", message: { role: "user", content: [{ type: "text", text: "just chat" }] } },
      { type: "message", message: { role: "assistant", content: [{ type: "text", text: "hello" }] } }
    ];
    const result = handleBeforeAgentFinalize(RUN_A, noExecTranscript);
    assert.strictEqual(result, undefined, "no exec in transcript → pass-through");
  });

  test("union (existing path wins): execRuns.has(runId) still triggers revise even without transcript", () => {
    // Ensure existing in-process path still works (transcript scan is UNION, not replacement)
    handleBeforeToolCall(RUN_A, "exec", { command: "cat README.md" });
    const result = handleBeforeAgentFinalize(RUN_A); // no transcript arg
    assert.ok(result !== undefined && result.action === "revise", "in-process path must still win");
  });

  test("union (disk wins): disk-fallback marked run passes through even without transcript", () => {
    handleBeforeToolCall(RUN_A, "exec", { command: "write-marker.sh coding" });
    execRuns.clear();
    markedTaskRuns.clear();
    const result = handleBeforeAgentFinalize(RUN_A); // disk has marked:true, no transcript
    assert.strictEqual(result, undefined, "disk fallback marked:true must pass through without transcript");
  });

  test("B-05: fail-open — null transcript does not throw, returns same result as no transcript", () => {
    assert.doesNotThrow(() => {
      handleBeforeAgentFinalize(RUN_A, null);
    }, "null transcript must not throw");
  });

  test("B-05: fail-open — malformed transcript (not array) does not throw", () => {
    assert.doesNotThrow(() => {
      handleBeforeAgentFinalize(RUN_A, { malformed: true });
    }, "malformed transcript must not throw");
  });

  test("B-05: revise instruction is byte-identical (no transcript content interpolated)", () => {
    const transcript = makeTranscriptWithExec("some command");
    const result = handleBeforeAgentFinalize(RUN_A, transcript);
    assert.ok(result !== undefined, "should have revise action");
    // The instruction must NOT contain the command text from the transcript
    assert.ok(!result.retry.instruction.includes("some command"), "T-11: instruction must not interpolate transcript content");
    assert.ok(result.retry.instruction.includes("write-marker.sh"), "instruction must reference write-marker.sh");
    assert.ok(result.retry.instruction.includes("classify this turn"), "instruction must be the static revise text");
  });

  test("WRAPPER-THREADING (B-05): safeBeforeAgentFinalize forwards transcript to impl — exec-in-transcript returns revise", () => {
    // This is the load-bearing path: index.ts → safeBeforeAgentFinalize(runId, transcript, opts) → impl(runId, transcript)
    const transcript = makeTranscriptWithExec("echo wrapper_test");
    // Call through the wrapper with transcript in the new non-opts position
    const result = safeBeforeAgentFinalize(RUN_A, transcript);
    assert.ok(result !== undefined, "wrapper must forward transcript — revise expected for exec-in-transcript");
    assert.strictEqual(result.action, "revise", "must return revise through the wrapper");
  });

  test("WRAPPER-THREADING (B-05): transcript with write-marker.sh through safeBeforeAgentFinalize returns undefined", () => {
    const transcript = makeTranscriptWithExec("echo test", true); // includes marker
    const result = safeBeforeAgentFinalize(RUN_A, transcript);
    assert.strictEqual(result, undefined, "marker-in-transcript through wrapper → pass-through");
  });

  test("WRAPPER-THREADING: wrapper is still fail-open when impl throws (transcript arg present)", () => {
    const boomWithTranscript = () => { throw new Error("forced failure"); };
    const transcript = makeTranscriptWithExec("echo test");
    assert.doesNotThrow(() => {
      safeBeforeAgentFinalize(RUN_A, transcript, {}, boomWithTranscript);
    }, "wrapper must still catch impl throws when transcript is present");
    const result = safeBeforeAgentFinalize(RUN_A, transcript, { log: () => {} }, boomWithTranscript);
    assert.strictEqual(result, undefined, "fail-open: must return undefined when impl throws");
  });
});

// ---------------------------------------------------------------------------
// Lifecycle enforcement extensions (2026-06-13): file-tool blind spot +
// substantive-final-text trigger + job-lifecycle revise instruction
// ---------------------------------------------------------------------------

describe("finalize - extended substantive detection (2026-06-13)", () => {
  beforeEach(() => resetState());

  const mkMsg = (parts) => ({ message: { role: "assistant", content: parts } });
  const longText = Array.from({ length: 230 }, (_, i) => `word${i}`).join(" ");

  test("substantive final text (>200 words, zero tools) → revise", () => {
    const transcript = [mkMsg([{ type: "text", text: longText }])];
    const result = handleBeforeAgentFinalize("run-lt-1", transcript);
    assert.ok(result && result.action === "revise", "long conversational turn must be gated");
  });

  test("short final text + only read tool calls → pass-through", () => {
    const transcript = [
      mkMsg([{ type: "toolCall", name: "read", arguments: { path: "/x" } },
             { type: "text", text: "All clear." }]),
    ];
    const result = handleBeforeAgentFinalize("run-lt-2", transcript);
    assert.strictEqual(result, undefined, "trivial turn must pass through");
  });

  test("file-tool (write) call in transcript, no marker → revise (blind-spot fix)", () => {
    const transcript = [
      mkMsg([{ type: "toolCall", name: "write", arguments: { path: "/tmp/zoo.txt" } },
             { type: "text", text: "Done." }]),
    ];
    const result = handleBeforeAgentFinalize("run-lt-3", transcript);
    assert.ok(result && result.action === "revise", "write-tool turn without marker must be gated");
  });

  test("direct exec toolCall in transcript invoking write-marker.sh → pass-through", () => {
    const transcript = [
      mkMsg([{ type: "toolCall", name: "write", arguments: { path: "/tmp/zoo.txt" } },
             { type: "toolCall", name: "exec",
               arguments: { command: "bash ~/.openclaw/skills/revenium/scripts/write-marker.sh generation" } },
             { type: "text", text: "Done." }]),
    ];
    const result = handleBeforeAgentFinalize("run-lt-4", transcript);
    assert.strictEqual(result, undefined, "marker invocation in transcript satisfies the gate");
  });

  test("revise instruction includes the job lifecycle (RUNNING open + --close)", () => {
    const transcript = [mkMsg([{ type: "text", text: longText }])];
    const result = handleBeforeAgentFinalize("run-lt-5", transcript);
    assert.ok(result, "expected a revise action");
    assert.ok(result.retry.instruction.includes("write-marker.sh"), "task classification present");
    assert.ok(result.retry.instruction.includes("write-job-marker.sh"), "job writer present");
    assert.ok(result.retry.instruction.includes("--status RUNNING"), "open form present");
    assert.ok(result.retry.instruction.includes("--close"), "close form present");
  });
});

describe("buildMeteringInjection (per-turn directive injection, 2026-06-13)", () => {
  test("reads the skill's directive file and wraps it in <revenium-metering> tags", async () => {
    const { buildMeteringInjection } = await import("./gate.js");
    const home = mkdtempSync(join(tmpdir(), "inj-"));
    const refDir = join(home, "skills", "revenium", "references");
    const { mkdirSync: mkd } = await import("node:fs");
    mkd(refDir, { recursive: true });
    writeFileSync(join(refDir, "agents-metering-directives.md"),
      "## Revenium Metering — Task Classification (Mandatory Completion Gate)\nrun write-marker.sh every turn\n");
    const prev = process.env.OPENCLAW_HOME;
    process.env.OPENCLAW_HOME = home;
    try {
      const inj = buildMeteringInjection();
      assert.ok(inj, "expected an injection string");
      assert.ok(inj.startsWith("<revenium-metering>"), "opening tag");
      assert.ok(inj.endsWith("</revenium-metering>"), "closing tag");
      assert.ok(inj.includes("write-marker.sh"), "directive content present");
    } finally {
      if (prev === undefined) delete process.env.OPENCLAW_HOME; else process.env.OPENCLAW_HOME = prev;
      rmSync(home, { recursive: true, force: true });
    }
  });

  test("missing directive file → null (fail-open, no injection)", async () => {
    const { buildMeteringInjection } = await import("./gate.js");
    const home = mkdtempSync(join(tmpdir(), "inj-empty-"));
    const prev = process.env.OPENCLAW_HOME;
    process.env.OPENCLAW_HOME = home;
    try {
      assert.strictEqual(buildMeteringInjection(), null);
    } finally {
      if (prev === undefined) delete process.env.OPENCLAW_HOME; else process.env.OPENCLAW_HOME = prev;
      rmSync(home, { recursive: true, force: true });
    }
  });
});
