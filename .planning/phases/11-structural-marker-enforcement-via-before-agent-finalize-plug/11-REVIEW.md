---
phase: 11-structural-marker-enforcement-via-before-agent-finalize-plug
reviewed: 2026-06-05T00:00:00Z
depth: standard
files_reviewed: 9
files_reviewed_list:
  - plugin/src/gate.js
  - plugin/src/index.ts
  - plugin/src/index.test.js
  - plugin/openclaw.plugin.json
  - plugin/package.json
  - plugin/tsconfig.json
  - scripts/post-install.sh
  - scripts/verify-markers.sh
  - tests/test_verify_markers.sh
findings:
  critical: 1
  warning: 6
  info: 4
  total: 11
status: issues_found
remediation:
  applied: 2026-06-05
  resolved: [CR-01, WR-01, WR-02]
  resolved_commits: [ba8e8c4, 42ce513, 3458c22]
  deferred: [WR-03, WR-04, WR-05, WR-06, IN-01, IN-02, IN-03, IN-04]
  post_fix_tests: "node 30/30, shell suites 5/5 green; dist parity verified"
---

# Phase 11: Code Review Report

**Reviewed:** 2026-06-05
**Depth:** standard
**Files Reviewed:** 9
**Status:** issues_found

## Summary

Reviewed the `revenium-marker-gate` OpenClaw plugin (`gate.js` pure logic + `index.ts`
wiring + `index.test.js`), the `verify-markers.sh` read-only diagnostic, its integration
test, and the `post-install.sh` install/enable/inspect step. Both test suites pass (21/21
node, 16/16 shell). The committed `plugin/dist/` was confirmed to match `src/` but was not
itself reviewed (out of scope per the brief).

The architecture is sound and the fail-open intent is mostly honored, but there is one real
hole in the fail-open guarantee: the host hook handlers are `async` and wrap the gate logic
with **no try/catch**, so the moment any of the gate functions throws, the rejected promise
propagates to the host's `before_agent_finalize` dispatcher rather than passing through. The
gate logic happens to be throw-free today, but the fail-open property is asserted by the
plugin's own comments and is the phase's primary safety requirement, so it must be enforced
at the boundary rather than assumed. Secondary issues: the "read-only" diagnostic actually
performs filesystem writes (via `common.sh`), the marker-detection uses a naive substring
match that both over- and under-counts, and several `post-install.sh` robustness gaps.

## Critical Issues

### CR-01: Fail-open guarantee is not enforced at the host boundary — a throw in any gate handler rejects the hook promise

**File:** `plugin/src/index.ts:28-42` (and the committed `plugin/dist/index.js`)
**Issue:** The phase's central safety requirement is that the gate must NEVER block or break
the agent reply on error. The three handlers are registered as `async` callbacks that call
the gate functions directly with no error containment:

```ts
api.on("before_agent_finalize", async (_event, ctx) => {
  return handleBeforeAgentFinalize(ctx.runId);   // throw here => rejected promise to host
});
api.on("before_tool_call", async (event, ctx) => {
  handleBeforeToolCall(ctx.runId, event.toolName, event.params);
});
```

Because the callbacks are `async`, any exception thrown synchronously inside the gate
functions becomes a **rejected promise**, not a caught error. The host's
`before_agent_finalize` dispatcher then receives a rejection instead of `undefined`. Whether
that aborts the turn, surfaces an error to the user, or is swallowed depends entirely on the
host — the plugin is no longer in control of its own fail-open promise. The gate functions
are throw-free *today* (they only do Set ops and string `.includes`), but fail-open is a
property the code claims (`gate.js:77,83`; `index.ts` header) and must be guaranteed
structurally, not by hoping the implementation never regresses. A future edit to `gate.js`
(e.g., reading taxonomy, JSON parsing, logging through a host logger that throws) silently
breaks the safety contract with zero test coverage. Note also `before_tool_call`
dereferences `event.toolName` / `event.params` and `ctx.runId` with no guard that `event`
is non-null.

**Fix:** Wrap every handler body in try/catch that swallows and (best-effort) logs, so the
boundary can never reject. For `before_agent_finalize`, a thrown error must resolve to
`undefined` (pass-through):

```ts
api.on("before_agent_finalize", async (_event, ctx) => {
  try {
    return handleBeforeAgentFinalize(ctx?.runId);
  } catch (err) {
    try { api.log?.(`[revenium-marker-gate] finalize error (fail-open): ${err}`); } catch {}
    return undefined; // fail-open: never block the reply
  }
});

api.on("before_tool_call", async (event, ctx) => {
  try {
    handleBeforeToolCall(ctx?.runId, event?.toolName, event?.params);
  } catch { /* fail-open: observation is best-effort */ }
});

api.on("agent_end", async (_event, ctx) => {
  try { handleAgentEnd(ctx?.runId); } catch { /* fail-open */ }
});
```

Add a unit test that monkeypatches/forces a throw and asserts `before_agent_finalize`
resolves to `undefined`. (Reminder: this change requires a `dist/index.js` rebuild + commit
per the file's own header.)

## Warnings

### WR-01: `verify-markers.sh` is documented "read-only / writes no files" but sourcing `common.sh` performs `mkdir`

**File:** `scripts/verify-markers.sh:18,24` → `scripts/common.sh:88,136`
**Issue:** The header explicitly promises: *"Read-only: writes no files, does not tee, does
not invoke guardrail or config writers (SC-5 / D-07 preservation)."* But line 24 sources
`common.sh`, which at line 88 unconditionally runs `mkdir -p "${STATE_DIR}"` at source time
(and `log()` does so again at 136). So merely running the diagnostic creates the skill state
directory tree if it does not exist. This violates the stated read-only contract and, on a
host where the skill is not yet installed, the diagnostic silently materializes
`~/.openclaw/skills/revenium/` as a side effect — surprising for a "measure the gap before
the plugin lands" tool.
**Fix:** Either (a) source `common.sh` only for the path-constant derivation and avoid the
write — e.g., compute `SESSIONS_DIR`/`MARKERS_DIR` inline in `verify-markers.sh` without the
side-effecting source; or (b) soften the header claim to "writes no marker/session/config
files; may create the empty state dir via common.sh." Option (a) preserves the SC-5 intent.

### WR-02: Marker detection uses a naive substring match — both false positives and false negatives

**File:** `plugin/src/gate.js:68`
**Issue:** `if (cmd.includes("write-marker.sh"))` marks a turn "classified" whenever the
command string *contains* the literal `write-marker.sh`, regardless of whether the script is
actually executed. Confirmed empirically:
- `echo "remember to run write-marker.sh later" >> notes.txt` → turn marked classified
  (false positive; no marker actually written).
- `bash my-write-marker.sh.bak` (a lookalike filename) → marked classified (false positive).
- Conversely, an alias/wrapper that runs the marker without the literal token in the command
  string would be a false negative.

Because the consequence is *under-enforcement* (the gate lets the turn finish without forcing
a real marker), it does not break fail-open, but it directly undercuts SC-1 (the whole point
of the gate). A turn that merely mentions the script in a heredoc, comment, or log line
escapes classification.
**Fix:** Tighten the match to require the script to be the thing being invoked. A pragmatic
improvement is a word-boundary / invocation-shaped regex anchored on a path separator or
shell token, e.g.:

```js
// Require write-marker.sh to appear as an invoked script, not an arbitrary substring.
const MARKER_INVOKE = /(^|[\s;|&(])(?:bash\s+|sh\s+|\.\/|\S*\/)?write-marker\.sh(\s|$)/;
if (MARKER_INVOKE.test(cmd)) {
  markedTaskRuns.add(runId);
}
```

Add tests for the mention-only and `.bak`-lookalike cases asserting they are NOT marked.

### WR-03: `idempotencyKey` is per-runId, so a re-armed run can never re-fire the gate

**File:** `plugin/src/gate.js:102-104`
**Issue:** `idempotencyKey: marker-gate:${runId}` combined with `maxAttempts: 1` means the
host will dedup the revise action across the lifetime of that `runId`. If the model's
revised pass *still* does not run `write-marker.sh`, the gate cannot ask again (correct, by
design — bounded). However, the comment block in `post-install.sh:214-221` / the test names
frame this as "one more pass." Worth confirming against the host contract that
`idempotencyKey` is scoped to the finalize attempt and not, e.g., reused if the same `runId`
legitimately finalizes twice (multi-turn agents that reuse a runId). If `runId` is reused
across turns and `agent_end` did not fire between them, `markedTaskRuns`/`execRuns` also
carry over — see WR-04. No code change strictly required, but the assumption that `runId` is
unique-per-turn is load-bearing and undocumented in `gate.js`.
**Fix:** Document the `runId`-is-per-turn assumption in `gate.js`, and if the host can reuse
`runId` across finalizes, incorporate an attempt/turn counter into the idempotency key.

### WR-04: Cross-turn state leak if `agent_end` does not fire (relies on a single cleanup event)

**File:** `plugin/src/gate.js:12-15,115-120`; `plugin/src/index.ts:40-42`
**Issue:** `execRuns` / `markedTaskRuns` are process-lifetime module Sets cleaned up only by
`handleAgentEnd`. If the host ever drops the `agent_end` event (crash mid-turn, hook
disabled, host version that does not emit it, or `allowConversationAccess` not granted so the
conversation hook never registers — the exact silent-block failure mode the install step
guards against), entries accumulate unboundedly and, worse, a reused `runId` would be seen as
"already exec'd / already marked" from a prior turn, suppressing a needed revise (false
negative). The gate has no TTL/secondary eviction. Given the install step itself warns that
`allowConversationAccess` may fail to apply (`post-install.sh:635`), the partial-registration
case (before_tool_call registers, agent_end does not) is realistic and leaves state
permanently uncleaned.
**Fix:** Add a defensive eviction: cap set size or stamp each `runId` with a timestamp and
evict entries older than N minutes on insert. At minimum, also delete the `runId` from both
sets inside `handleBeforeAgentFinalize` after computing the result (the finalize is the last
point the gate cares about that run), so cleanup does not depend solely on `agent_end`.

### WR-05: `post-install.sh` parses `config.yaml` with line-oriented `sed`, mishandling quotes/comments/nesting

**File:** `scripts/post-install.sh:249-253`
**Issue:** Revenium credentials are extracted from `~/.config/revenium/config.yaml` with
`sed -n 's/^key:[[:space:]]*//p'`. This naive YAML parse breaks on common-but-valid forms:
quoted values (`key: "abc123"` yields `"abc123"` *with* quotes, which then become part of the
injected `REVENIUM_API_KEY` env var and silently corrupt auth), trailing inline comments
(`key: abc  # prod`), or any nesting. A corrupted-but-non-empty key passes the `-z` check at
line 256, so the failure is silent and surfaces only as downstream 401s from the CLI inside
the sandbox.
**Fix:** Parse with a real YAML reader (the script already requires `python3`):

```bash
REV_KEY=$(python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])) or {}; print(d.get("key","") or "")' "${REVENIUM_CONFIG_FILE}" 2>/dev/null || true)
```

If `pyyaml` is not guaranteed, at minimum strip surrounding quotes and inline comments from
the `sed` output before exporting.

### WR-06: Plugin install/enable/inspect failures are warn-and-continue, so a broken install reports "success"

**File:** `scripts/post-install.sh:619-641,737-752`
**Issue:** Fail-open install (per the brief) is intentional, but the consequence is that
`plugin install`, the `config patch`, and even the `before_agent_finalize`-in-hookNames
verification can all fail (each `|| warn ... skipping`) and the script still prints
"Revenium skill installed successfully!" at the end. The single most important signal — "the
gate is actually active" — is reduced to a `warn` that scrolls past in a long install. There
is no non-zero exit, summary roll-up, or "DEGRADED" final banner reflecting that the gate did
not register.
**Fix:** Track a `GATE_OK` flag through the three plugin steps and reflect it in the final
banner (e.g., print "Marker gate: ACTIVE" vs "Marker gate: NOT ACTIVE — restart gateway and
re-run, or run `openclaw plugins inspect revenium-marker-gate`"). Keep fail-open (do not
`exit 1`), but make the degraded state visible at the end rather than mid-stream.

## Info

### IN-01: One-time diagnostic log uses `console.log` and a module-global latch

**File:** `plugin/src/gate.js:20,46-53`
**Issue:** `_loggedFirstExec` gates a one-shot `console.log` of the first observed
`toolName`/param keys. In a long-lived gateway this writes to the host's stdout directly
(not through a host logger) and the latch is process-global, so it fires once per process —
fine for the stated 11-03 E2E debugging purpose but stale afterward. The comment says it
"resolves open question A1," implying it is temporary scaffolding.
**Fix:** Route through the host logger if available (`opts.log`) — `index.ts` never passes
`opts`, so it always falls back to `console.log`. Plan to remove this diagnostic once A1 is
confirmed, or gate it behind a debug env var.

### IN-02: `handleBeforeToolCall` adds `runId` to `execRuns` even when the command field is missing/non-string

**File:** `plugin/src/gate.js:62-65`
**Issue:** When neither `params.command` nor `params.code` is a string, the run is still
counted as a substantive exec turn (`execRuns.add(runId)`), so the gate will demand a marker
even though the plugin could not determine what (if anything) ran. The inline comment calls
this "conservative," which is a defensible choice (an exec tool did fire), but it means a
host that delivers the command under a third, unknown field name will trigger revise prompts
on turns the agent cannot satisfy via the observed command. This is the very A1 uncertainty
the IN-01 diagnostic exists to resolve.
**Fix:** Acceptable as-is given the conservative rationale; revisit once A1 confirms the real
field name(s) and then narrow. Consider not counting truly field-less exec events.

### IN-03: `tsconfig.json` excludes `*.test.ts/js` but `allowJs` + `include: src/**/*.ts` already excludes the JS test

**File:** `plugin/tsconfig.json:14-15`
**Issue:** `include` is `src/**/*.ts` (TS only), so `src/index.test.js` is never picked up
regardless of the `exclude` entry; and `gate.js` (plain JS, imported by `index.ts`) is also
not compiled — it is shipped as-is and `dist/index.js` imports `./gate.js`. Confirm that the
build copies `gate.js` into `dist/` (the committed `dist/` contains `gate.js`, so this works
today), but `tsc` alone does not copy it — the build relies on a manual copy not expressed in
the `build` script. This is a latent footgun for the "rebuild + re-commit dist" workflow the
headers mandate.
**Fix:** Make `gate.js` part of the compiled/copied output explicitly (e.g., a `build` script
that runs `tsc && cp src/gate.js dist/gate.js`) so a clean rebuild reproduces the committed
`dist/` deterministically.

### IN-04: Integration test asserts column values with loose regexes that can match adjacent columns

**File:** `tests/test_verify_markers.sh:120,126,144,151,169,175`
**Issue:** Assertions like `grep -qE '[[:space:]]3[[:space:]]+3[[:space:]]'` match "3 then 3"
anywhere on the row. For the chosen fixtures (3 completions, distinct marker counts) this is
unambiguous, but it is positional-fragile: a session id or timestamp containing those digits,
or a future column reorder, could produce false passes/fails. Low risk given controlled
fixtures.
**Fix:** Anchor assertions to the full expected column layout (e.g., capture the row and
compare the numeric fields by awk position) rather than substring regex.

---

_Reviewed: 2026-06-05_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
