---
phase: 15-per-turn-enforcement-plugin
reviewed: 2026-06-09T00:00:00Z
depth: standard
files_reviewed: 4
files_reviewed_list:
  - plugin/src/gate.js
  - plugin/src/index.test.js
  - plugin-nemoclaw/src/index.test.js
  - scripts/post-install-nemoclaw.sh
findings:
  critical: 1
  warning: 4
  info: 2
  total: 7
status: issues_found
---

# Phase 15: Code Review Report

**Reviewed:** 2026-06-09T00:00:00Z
**Depth:** standard
**Files Reviewed:** 4
**Status:** issues_found

## Summary

Reviewed the Phase 15 gap-closure changes: disk-persisted exec-run state in
`plugin/src/gate.js` (B-05/NCENF-02) and the rewritten Gate A in
`scripts/post-install-nemoclaw.sh` (B-01).

The **runId path-traversal guard is sound** — I traced every adversarial input
(`..`, `../..`, `../../etc/passwd`, `.`, `...`) through `sanitizeRunId` +
`runStatePath` and confirmed the mandatory `.json` suffix prevents any resolution
outside the state dir. The fail-open boundary wrappers (`safe*`) are correct, and
`writeFileSync` uses mode `0o600` as required.

However, two genuine defects survived the test suite (both plugin suites pass at
37/42 tests green, so neither bug is caught):

1. **BLOCKER:** Gate A's `promptChars` parse pipeline aborts under
   `set -euo pipefail` on the no-match path, so the intended
   "guard directive NOT injected" diagnostic never fires — the operator gets a
   bare `exit 1`. The gate still fails closed, but its primary error-reporting
   purpose is defeated.
2. **WARNING:** `persistRunState` can overwrite a disk `marked:true` record back
   to `marked:false` within the same run, causing a spurious revise after
   `nemoclaw recover`.

Plus a Gate A correctness gap (unscoped `promptChars` grep), test-isolation
fragility, and minor quality items.

## Critical Issues

### CR-01: Gate A `promptChars` pipeline aborts under `pipefail`, suppressing the intended failure diagnostic

**File:** `scripts/post-install-nemoclaw.sh:230-234`
**Issue:** The script runs under `set -euo pipefail` (line 30). The parse on lines 230-231:

```bash
_prompt_chars=$(echo "${_prompt_json}" | grep -oE '"promptChars"[[:space:]]*:[[:space:]]*[0-9]+' \
    | grep -oE '[0-9]+$' | head -1)
```

When `_prompt_json` is empty or lacks a `promptChars` field — which is *exactly*
the case Gate A exists to detect (guard directive not injected → `before_prompt_build`
inactive/untrusted) — the first `grep` exits 1. With `pipefail`, the command
substitution returns non-zero, and `set -e` aborts the script **at line 230**,
before reaching the `if [ -z "${_prompt_chars}" ]` check on line 232.

Reproduced:
```
$ # _prompt_json='{"foo":1}' (no promptChars), set -euo pipefail
$ bash repro.sh ; echo "exit=$?"
exit=1          # bare exit — the fail "guard directive NOT injected..." message NEVER prints
```

Impact: the carefully-worded actionable error on line 233
(`fail "guard directive NOT injected — could not parse..."`) is dead code on the
no-match path. The operator sees a bare `exit 1` with no diagnostic, defeating the
purpose of the B-01 rewrite. (The gate does still fail *closed* — the install
aborts — so this is a diagnostic-loss defect, not a fail-open security hole, but it
breaks the gate's stated contract and will badly mislead anyone debugging a real
injection failure.)

**Fix:** Make the substitution tolerant of no-match so control reaches the explicit
`-z` check. Append `|| true` to the pipeline, or disable pipefail locally:
```bash
_prompt_chars=$(echo "${_prompt_json}" \
    | grep -oE '"promptChars"[[:space:]]*:[[:space:]]*[0-9]+' \
    | grep -oE '[0-9]+$' | head -1 || true)
if [ -z "${_prompt_chars}" ]; then
    fail "guard directive NOT injected — could not parse currentTurn.promptChars ..."
fi
```

## Warnings

### WR-01: `persistRunState` overwrites disk `marked:true` → `marked:false` on a later non-string-command exec in the same run

**File:** `plugin/src/gate.js:186-191`
**Issue:** When a run first invokes `write-marker.sh` (line 201 persists
`marked:true`), then a subsequent tool call in the *same run* arrives with a
non-string `command`/`code`, control hits the guard at lines 186-191 and calls
`persistRunState(runId, false)` unconditionally — ignoring that `markedTaskRuns`
still contains the runId. This clobbers the disk record to `marked:false`.

Reproduced:
```
after marker exec:        {"exec":true,"marked":true, ...}  inProcessMarked=true
after non-string exec:    {"exec":true,"marked":false,...}  inProcessMarked=true   <-- regressed
```

Impact: after a `nemoclaw recover` (the exact scenario disk persistence exists to
survive), `handleBeforeAgentFinalize` reads disk, sees `marked:false`, and issues a
revise action for a turn that was already classified — re-prompting the agent
unnecessarily and undermining the B-05 guarantee. The normal path (line 201)
correctly OR-s in `markedTaskRuns.has(runId)`; the non-string path does not.

**Fix:** Mirror the normal path — never downgrade `marked` for an already-marked run:
```js
if (typeof cmd !== "string") {
    execRuns.add(runId);
    persistRunState(runId, markedTaskRuns.has(runId)); // preserve prior marked:true
    return;
}
```

### WR-02: Gate A `promptChars` grep is not scoped to `currentTurn` — first match wins

**File:** `scripts/post-install-nemoclaw.sh:230-231`
**Issue:** The comment (lines 214-238) and success message repeatedly say
`currentTurn.promptChars`, but the grep matches *any* `"promptChars": N` in the
JSON and `head -1` takes the first textual occurrence. If `openclaw agent --json`
ever emits a `promptChars` field outside `currentTurn` (e.g. a per-message or
summary block) that precedes `currentTurn` in output order, the gate asserts
against the wrong value.

Verified the first-match behavior:
```
$ echo '{"a":{"promptChars":50},"b":{"promptChars":1637}}' | grep -oE ... | head -1
50      # picks the wrong field; would false-FAIL the <1500 check
```

Impact: a false install abort (or, in the inverse ordering, a false pass) decoupled
from the actual injected-directive size. The 649→1637 evidence the threshold is
built on is specifically the `currentTurn` value.

**Fix:** Scope the extraction to the `currentTurn` object, or document that the JSON
is known to contain exactly one `promptChars`. A pragmatic scope: strip everything
before `"currentTurn"` first:
```bash
_prompt_chars=$(echo "${_prompt_json}" \
    | grep -oE '"currentTurn".*' \
    | grep -oE '"promptChars"[[:space:]]*:[[:space:]]*[0-9]+' \
    | grep -oE '[0-9]+$' | head -1 || true)
```
(Combine with the CR-01 `|| true` fix.)

### WR-03: Unwritable-dir tests leave `SUITE_TMP_DIR` read-only if an assertion throws

**File:** `plugin/src/index.test.js:383-404`; `plugin-nemoclaw/src/index.test.js:405-426`
**Issue:** Both fail-open tests `chmodSync(SUITE_TMP_DIR, 0o400)`, run assertions,
then `chmodSync(..., 0o700)` to restore. The restore is the last statement, not in a
`finally`. If any assertion between the two chmods throws, the restore is skipped and
the suite dir stays `0o400` — later tests' disk writes then silently fail (masked by
the gate's own fail-open), making subsequent persistence tests pass for the wrong
reason or flake. Tests pass today only because the assertions happen not to throw.

**Fix:** Wrap the body in try/finally so the chmod restore always runs:
```js
try { chmodSync(SUITE_TMP_DIR, 0o400); chmodWorked = true; } catch { return; }
try {
  assert.doesNotThrow(() => handleBeforeToolCall(RUN_A, "exec", { command: "ls" }));
  assert.ok(execRuns.has(RUN_A), ...);
} finally {
  try { chmodSync(SUITE_TMP_DIR, 0o700); } catch { /* ignore */ }
}
```

### WR-04: No test covers the WR-01 marked-downgrade path (false confidence)

**File:** `plugin/src/index.test.js:324-405`; `plugin-nemoclaw/src/index.test.js:346-427`
**Issue:** The persistence describe-blocks cover marked/unmarked-then-restart, but
never the sequence "marker exec → non-string-command exec → restart". That gap let
WR-01 through with all 37/42 tests green. A reviewer relying on the suite would
conclude the disk record is monotonic w.r.t. `marked`, which it is not.

**Fix:** Add a regression test:
```js
test("non-string-command exec after a marker does NOT downgrade disk marked:true", () => {
  handleBeforeToolCall(RUN_A, "exec", { command: "write-marker.sh coding" });
  handleBeforeToolCall(RUN_A, "exec", { command: 42, code: null });
  execRuns.clear(); markedTaskRuns.clear();              // simulate recover
  assert.strictEqual(handleBeforeAgentFinalize(RUN_A), undefined,
    "marked run must still pass through after restart");
});
```

## Info

### IN-01: Stale run-state files accumulate when `agent_end` never fires

**File:** `plugin/src/gate.js:117-128, 283-297`
**Issue:** Cleanup (`handleAgentEnd` → `rmSync`) is the only thing that removes a
run-state file. If a process is killed between `before_tool_call` and `agent_end`
(the very crash/recover scenario the feature targets), the file is orphaned. There is
no TTL/`updatedAt`-based sweep, so `${OPENCLAW_HOME}/run-state` grows unbounded across
crashes. `updatedAt` is written but never read. Not a correctness bug for a single
turn, but worth a periodic sweep or a max-age check in the disk-fallback read.
**Fix:** On the fallback read, ignore (and best-effort delete) records older than a
bounded age using the already-persisted `updatedAt`; or add a sweep on startup.

### IN-02: Duplicated test suite drifts independently of source-of-truth

**File:** `plugin-nemoclaw/src/index.test.js` (entire carried-over portion)
**Issue:** Lines 108-427 are a near-verbatim copy of `plugin/src/index.test.js`
(noted as D-06 build-copy). The two will silently diverge — e.g. a fix for WR-04
must be applied in both by hand. Consider generating the nemoclaw test from the
plugin source at build time (same mechanism as `gate.js`), or importing the shared
cases, so the copies cannot drift.
**Fix:** Treat the carried-over describe-blocks as build-generated, or extract them
into a shared spec module imported by both suites.

---

_Reviewed: 2026-06-09T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
