# Phase 15: Per-Turn Enforcement Plugin - Pattern Map

**Mapped:** 2026-06-08
**Files analyzed:** 6 new/modified files
**Analogs found:** 6 / 6

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---|---|---|---|---|
| `plugin-nemoclaw/src/index.ts` | plugin entry / wiring | event-driven | `plugin/src/index.ts` | exact |
| `plugin-nemoclaw/src/guard.js` (build helper) | build-time utility | transform | `plugin/src/gate.js` (structure) + spike `revenium-guard/index.js` (guard logic) | exact |
| `plugin-nemoclaw/openclaw.plugin.json` | config / manifest | — | `plugin/openclaw.plugin.json` + spike `revenium-guard/openclaw.plugin.json` | exact |
| `plugin-nemoclaw/package.json` | config / build | — | `plugin/package.json` + spike `revenium-guard/package.json` | exact |
| `plugin-nemoclaw/src/index.test.js` | test | event-driven | `plugin/src/index.test.js` | exact |
| `scripts/post-install-nemoclaw.sh` (edit: replace `stub_install_enforcement_plugin`) | install script | request-response | `scripts/post-install-nemoclaw.sh` `install_metering_loop()` + `scripts/post-install.sh` §7c | exact |
| `BUDGET-GUARD.md` (edit: add `_maxAgeSeconds` freshness rule) | directive / config | — | `scripts/nemoclaw-cron-tick.sh` Step 4 (source of the field) | role-match |

---

## Pattern Assignments

### `plugin-nemoclaw/src/index.ts` (plugin entry, event-driven)

**Analogs:** `plugin/src/index.ts` (primary wiring shape) + spike `revenium-guard/index.js` (guard hook shape)

**Imports pattern** (`plugin/src/index.ts` lines 15-20):
```typescript
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import {
  safeBeforeToolCall,
  safeBeforeAgentFinalize,
  safeAgentEnd,
} from "./gate.js";
```
For the combined plugin, also import the inlined directive constant:
```typescript
import { GUARD_DIRECTIVE } from "./guard.js";  // build-time inlined string
import {
  safeBeforeToolCall,
  safeBeforeAgentFinalize,
  safeAgentEnd,
} from "../plugin/src/gate.js";  // verbatim — D-06; exact relative path resolved at build
```

**Plugin entry + id pattern** (`plugin/src/index.ts` lines 22-26):
```typescript
export default definePluginEntry({
  id: "revenium-enforcement",
  name: "Revenium Enforcement",
  description: "Injects guardrail directive on every turn and gates task marker writing.",
  register(api) {
```

**Guard hook pattern** (spike `revenium-guard/index.js` lines 4-13, adapted for D-10 tag wrapping):
```typescript
// before_prompt_build: NOT a conversation hook — no allowConversationAccess needed.
// Injects BUDGET-GUARD.md contents (baked at build, D-02) with <revenium-guard> tag (D-10).
api.on("before_prompt_build", () => {
  try {
    return {
      prependContext: "<revenium-guard>\n" + GUARD_DIRECTIVE + "\n</revenium-guard>",
    };
  } catch {
    return undefined; // fail-open: never block the turn
  }
});
```

**Marker hooks pattern** (`plugin/src/index.ts` lines 33-57 — copy verbatim, change only plugin name in log strings):
```typescript
// before_tool_call: NOT a conversation hook — no allowConversationAccess needed.
api.on("before_tool_call", async (event, ctx) => {
  try {
    safeBeforeToolCall(ctx?.runId, event?.toolName, event?.params);
  } catch { /* fail-open */ }
});

// before_agent_finalize: IS a conversation hook — requires allowConversationAccess: true
api.on("before_agent_finalize", async (_event, ctx) => {
  try {
    return safeBeforeAgentFinalize(ctx?.runId, { log: (msg: string) => api.log?.(msg) });
  } catch {
    return undefined; // fail-open
  }
});

// agent_end: IS a conversation hook — requires allowConversationAccess: true
api.on("agent_end", async (_event, ctx) => {
  try {
    safeAgentEnd(ctx?.runId);
  } catch { /* fail-open */ }
});
```

**Fail-open guarantee comment** (`plugin/src/index.ts` lines 29-32):
```typescript
// FAIL-OPEN GUARANTEE (CR-01): every handler body is wrapped in try/catch so
// a throw from the gate logic can NEVER reject the hook promise. The safe*
// wrappers in gate.js contain the same containment (so the property is
// unit-testable without the openclaw peer); the local try/catch here is a
// defensive second layer that also guards the ctx/event dereferences below.
```

---

### `plugin-nemoclaw/src/guard.js` (build-time inliner + guard constant)

**Analogs:** spike `revenium-guard/index.js` (guard logic); `plugin/src/gate.js` (module shape)

This file is a pure ESM module (no TypeScript, no openclaw dependency) that exports the directive string baked in at build time. The build step reads `BUDGET-GUARD.md` and writes this file's `GUARD_DIRECTIVE` const before `tsc` runs (D-02).

**Module shape** (modeled on `plugin/src/gate.js` lines 1-10 — plain ESM, no dependencies):
```js
/**
 * guard.js — Baked-in guardrail directive for the revenium-enforcement plugin.
 *
 * GENERATED at build time by scripts/bake-directive.js.
 * Source of truth: BUDGET-GUARD.md (edit there, then rebuild).
 * Do NOT hand-edit this file.
 */

export const GUARD_DIRECTIVE = `<BUDGET-GUARD.md contents here>`;
```

The build script (`scripts/bake-directive.js`, a new Node script) pattern:
```js
// Reads ../../BUDGET-GUARD.md, escapes backticks/backslashes, writes guard.js.
import { readFileSync, writeFileSync } from "node:fs";
const raw = readFileSync("../../BUDGET-GUARD.md", "utf8");
const escaped = raw.replace(/\\/g, "\\\\").replace(/`/g, "\\`").replace(/\$\{/g, "\\${");
writeFileSync(
  "src/guard.js",
  `// GENERATED — do not edit. Source: BUDGET-GUARD.md\nexport const GUARD_DIRECTIVE = \`${escaped}\`;\n`
);
```

The `build` script in `package.json` chains: `node scripts/bake-directive.js && tsc`.

---

### `plugin-nemoclaw/openclaw.plugin.json` (manifest)

**Analogs:** `plugin/openclaw.plugin.json` (primary) + spike `revenium-guard/openclaw.plugin.json` (guard-specific fields)

**Full manifest pattern** (merge of both analogs; D-05/D-06 decisions applied):
```json
{
  "id": "revenium-enforcement",
  "name": "Revenium Enforcement",
  "description": "Injects guardrail directive on every turn and gates task marker writing.",
  "version": "1.0.0",
  "activation": { "onStartup": true },
  "contracts": { "tools": [] },
  "configSchema": {
    "type": "object",
    "properties": {},
    "additionalProperties": false
  }
}
```

Key differences from `plugin/openclaw.plugin.json` (line 6):
- `"activation": { "onStartup": true }` — REQUIRED for `before_prompt_build` to register at startup (D-06); Phase 11 used `false`.
- `"configSchema"` object required — omitting it is a hard manifest failure (D-06 spike finding).

---

### `plugin-nemoclaw/package.json` (package + build contract)

**Analogs:** `plugin/package.json` (primary) + spike `revenium-guard/package.json` (`openclaw.extensions` shape)

**Full package pattern** (`plugin/package.json` lines 1-21, adapted):
```json
{
  "name": "revenium-enforcement",
  "version": "1.0.0",
  "type": "module",
  "openclaw": {
    "extensions": [
      "./dist/index.js"
    ]
  },
  "scripts": {
    "build": "node scripts/bake-directive.js && tsc"
  },
  "peerDependencies": {
    "openclaw": ">=2026.6.1"
  },
  "devDependencies": {
    "@types/node": "^25.9.1",
    "typescript": "^5.0.0"
  }
}
```

Critical fields (each omission is a hard failure per D-06 spike findings):
- `"openclaw": { "extensions": ["./dist/index.js"] }` — tells the loader where the compiled entry is (spike `revenium-guard/package.json` line 7).
- `"type": "module"` — required for ESM plugin shape.
- `dist/index.js` must be **committed** — host has no tsc (Phase 11 Pitfall 2).

---

### `plugin-nemoclaw/tsconfig.json`

**Analog:** `plugin/tsconfig.json` (copy verbatim)

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "declaration": false,
    "skipLibCheck": true,
    "allowJs": true,
    "checkJs": false
  },
  "include": ["src/**/*.ts"],
  "exclude": ["src/**/*.test.js", "src/**/*.test.ts", "node_modules"]
}
```

---

### `plugin-nemoclaw/src/index.test.js` (test, event-driven)

**Analog:** `plugin/src/index.test.js` (copy structure verbatim; extend for guard hook)

**Test file header + imports pattern** (`plugin/src/index.test.js` lines 1-36):
```js
import { test, describe, beforeEach } from "node:test";
import assert from "node:assert/strict";
import {
  execRuns,
  markedTaskRuns,
  resetState,
  handleBeforeToolCall,
  handleBeforeAgentFinalize,
  handleAgentEnd,
  safeBeforeAgentFinalize,
  safeBeforeToolCall,
  safeAgentEnd,
} from "../../plugin/src/gate.js";   // verbatim import from shared gate

beforeEach(() => { resetState(); });
```

**New guard hook test block to add** (extends the existing test shape):
```js
describe("before_prompt_build - guard directive injection", () => {
  test("returns prependContext containing <revenium-guard> tag (D-10)", () => {
    const { GUARD_DIRECTIVE } = await import("./guard.js");
    // Simulate the hook return value
    const result = {
      prependContext: "<revenium-guard>\n" + GUARD_DIRECTIVE + "\n</revenium-guard>",
    };
    assert.ok(result.prependContext.includes("<revenium-guard>"), "must contain opening tag");
    assert.ok(result.prependContext.includes("</revenium-guard>"), "must contain closing tag");
    assert.ok(result.prependContext.includes(GUARD_DIRECTIVE), "must contain full directive");
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
```

All existing test blocks from `plugin/src/index.test.js` (exec tracking, gate logic, cleanup, CR-01 fail-open boundary) are carried over unchanged — they import from `../../plugin/src/gate.js` which is the shared source.

---

### `scripts/post-install-nemoclaw.sh` (edit: replace `stub_install_enforcement_plugin`)

**Analog:** `install_metering_loop()` pattern in the same file (lines 103-115) + `scripts/post-install.sh` §7c (lines 617-641)

**Ledger-gated function shell** (modeled on `install_metering_loop()`, `post-install-nemoclaw.sh` lines 103-115):
```bash
install_enforcement_plugin() {
    if ledger_has "enforcement-plugin-installed"; then
        info "Enforcement plugin already installed (ledger) — skipping."
        return 0
    fi

    step "Installing revenium-enforcement plugin (NemoClaw)"

    # ... (body below) ...

    ledger_set "enforcement-plugin-installed" "1"
    info "Enforcement plugin installed and validated"
}
```

**Skill install step (D-08)** — pulled from `nemoclaw skill install` mechanic, runs before plugin step:
```bash
install_skill_nemoclaw() {
    if ledger_has "skill-installed-nemoclaw"; then
        info "Revenium skill already deployed to sandbox (ledger) — skipping."
        return 0
    fi

    step "Deploying revenium skill into sandbox"
    nemoclaw "${SANDBOX_NAME}" skill install "${SKILL_DIR}" \
        || fail "nemoclaw skill install failed"

    ledger_set "skill-installed-nemoclaw" "1"
    info "Revenium skill deployed to sandbox '${SANDBOX_NAME}'"
}
```

**Mount-establish + plugin copy pattern (D-11)** (modeled on `install-nemoclaw-cron.sh` Step 4, lines 126-131):
```bash
# Ensure mount is live (reuse Phase 14 pattern)
MNT="${HOME}/sbx-openclaw-${SANDBOX_NAME}"
mkdir -p "${MNT}"
if ! mountpoint -q "${MNT}" 2>/dev/null; then
    nemoclaw "${SANDBOX_NAME}" share mount /sandbox/.openclaw "${MNT}" \
        || fail "mount failed — is ${SANDBOX_NAME} running?"
fi

# Copy committed plugin dir to mount (= in-sandbox /sandbox/.openclaw/extensions/)
PLUGIN_SRC="${SCRIPT_DIR}/../plugin-nemoclaw"
PLUGIN_DST="${MNT}/extensions/revenium-enforcement"
rm -rf "${PLUGIN_DST}"
cp -r "${PLUGIN_SRC}" "${PLUGIN_DST}"
```

**In-sandbox plugin install + config-patch pattern (D-09)** (modeled on `post-install.sh` §7c lines 621-636):
```bash
# Install (provenance-trusted: plugins install enforces the trust gate)
nemoclaw "${SANDBOX_NAME}" exec -- openclaw plugins install \
    /sandbox/.openclaw/extensions/revenium-enforcement \
    || fail "openclaw plugins install failed — plugin will be untrusted/inert"

# Config patch: enable + allowConversationAccess (required for before_agent_finalize + agent_end)
nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
    "echo '{plugins: {entries: {\"revenium-enforcement\": {enabled: true, hooks: {allowConversationAccess: true}}}}}' | openclaw config patch --stdin" \
    || fail "plugin config patch failed"

# Recover to load the plugin
nemoclaw "${SANDBOX_NAME}" recover \
    || fail "nemoclaw recover failed after plugin install"
```

**Fail-hard validation gate (D-09, D-10)** — stricter than standalone's warn-and-continue:
```bash
# Assert <revenium-guard> tag appears in finalPromptText (D-10)
_prompt_json=$(nemoclaw "${SANDBOX_NAME}" exec -- \
    sh -lc "openclaw agent --json --message 'ping' 2>/dev/null" || true)
if ! echo "${_prompt_json}" | grep -q "<revenium-guard>"; then
    fail "guard directive NOT injected — <revenium-guard> absent from finalPromptText. Aborting."
fi
info "Guard directive injection confirmed (<revenium-guard> in finalPromptText)"

# Assert hooks trusted/active via plugins inspect (D-09)
_inspect=$(nemoclaw "${SANDBOX_NAME}" exec -- \
    sh -lc "openclaw plugins inspect revenium-enforcement 2>/dev/null" || true)
if ! echo "${_inspect}" | grep -q "before_prompt_build"; then
    fail "before_prompt_build hook NOT active — plugin may be untrusted. Aborting."
fi
info "Plugin hooks confirmed active (before_prompt_build in inspect output)"
```

**Python3 preflight + marker smoke gate (D-07)** — hard-gate pattern from Phase 13/14:
```bash
# Assert python3 present in-sandbox (write-marker.sh dependency)
nemoclaw "${SANDBOX_NAME}" exec -- sh -lc "python3 --version" &>/dev/null \
    || fail "python3 not found in sandbox — write-marker.sh will silently fail. Aborting."

# Write a test marker and confirm it appears in <mount>/markers/
nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
    "bash ~/.openclaw/skills/revenium/scripts/write-marker.sh testing" \
    || fail "marker smoke test failed — write-marker.sh not functional in sandbox"

TEST_MARKER_GLOB="${MNT}/markers/*.jsonl"
if ! ls ${TEST_MARKER_GLOB} &>/dev/null; then
    fail "marker smoke test: no marker file appeared in ${MNT}/markers/ — mount or path broken"
fi
info "Marker smoke test passed — markers visible over mount"
```

**Callsite in the main execution block** (replace `stub_install_enforcement_plugin()` call, model on the existing call order around line 117):
```bash
install_skill_nemoclaw         # D-08: deploy skill first (marker chain precondition)
install_enforcement_plugin     # D-05/D-09/D-10/D-11: plugin + validation gate
```

---

### `BUDGET-GUARD.md` (edit: add `_maxAgeSeconds` freshness rule)

**Analog:** `scripts/nemoclaw-cron-tick.sh` Step 4 (lines 82-93) — source that stamps the field; `BUDGET-GUARD.md` current contents (lines 1-11) — insertion point.

**Current directive** (`BUDGET-GUARD.md` lines 1-11):
```markdown
## Guardrail Enforcement (Mandatory)

BEFORE EVERY RESPONSE — read `~/.openclaw/skills/revenium/guardrail-status.json`.

- **File missing:** Proceed with caution.
- **`halted` is `false` and `warned` is `false`:** Proceed silently.
- **`halted` is `false` and `warned` is `true`:** Follow the warn-and-ask branch...
- **`halted` is `true`:** YOUR ENTIRE RESPONSE MUST BE EXACTLY the halt message...

No operation is exempt.
```

**Field being checked** (`nemoclaw-cron-tick.sh` lines 82-93 — the exact Python that stamps it):
```python
d['_maxAgeSeconds'] = ${MAX_AGE_SECONDS}   # = interval_minutes * 60 * 3
```
Written to `guardrail-status.json` alongside `updatedAt` (existing field written by `guardrail-check.sh`).

**Freshness rule to insert** (after the "File missing" bullet, before "halted is false" bullets — D-03/D-04):
```markdown
- **`_maxAgeSeconds` is present AND `now - updatedAt > _maxAgeSeconds`:** Treat as `warned` (stale status — fail-safe). If `_maxAgeSeconds` is absent, skip this check.
```

Exact insertion rule for planner: add the freshness bullet as the **second** bullet (after "File missing"), so the order becomes:
1. File missing → proceed with caution
2. **NEW:** `_maxAgeSeconds` present AND stale → treat as warned
3. `halted false, warned false` → proceed silently
4. `halted false, warned true` → warn-and-ask
5. `halted true` → halt

**Regression constraint (D-04):** The rule's `if _maxAgeSeconds is absent → skip` branch means standalone `guardrail-check.sh` (which never writes `_maxAgeSeconds`) is completely unaffected.

---

## Shared Patterns

### Ledger idempotency
**Source:** `scripts/post-install-nemoclaw.sh` lines 63-83 (`ledger_has` / `ledger_set`)
**Apply to:** All new functions in `post-install-nemoclaw.sh`
```bash
ledger_has() {
    local key="$1"
    grep -q "^${key}=" "${LEDGER_FILE}" 2>/dev/null
}
ledger_set() {
    local key="$1" val="$2"
    WORK_DONE=1
    local ledger_dir; ledger_dir="$(dirname "${LEDGER_FILE}")"
    mkdir -p "${ledger_dir}"
    { grep -v "^${key}=" "${LEDGER_FILE}" 2>/dev/null || true; \
      echo "${key}=${val}"; } > "${LEDGER_FILE}.tmp" && \
      mv "${LEDGER_FILE}.tmp" "${LEDGER_FILE}"
}
```
Ledger keys for Phase 15: `skill-installed-nemoclaw`, `enforcement-plugin-installed`.

### Fail-open hook contract (CR-01)
**Source:** `plugin/src/index.ts` lines 29-32 + `plugin/src/gate.js` lines 150-205
**Apply to:** Every `api.on(...)` handler in `plugin-nemoclaw/src/index.ts`

Every handler body is wrapped in `try/catch`. For `before_agent_finalize`: catch returns `undefined`. For observe/cleanup hooks: catch is silent. The `safe*` wrappers in `gate.js` are the first containment layer; the `try/catch` in `index.ts` is the second defensive layer.

### `nemoclaw <sbx> exec` newline constraint
**Source:** `scripts/post-install-nemoclaw.sh` lines 206-208 + comments at lines 255-260
**Apply to:** All `nemoclaw exec` calls in `install_enforcement_plugin()`

NemoClaw exec rejects any argv element containing a newline (gRPC InvalidArgument). Multi-line payloads must be base64-encoded on the host and decoded in-sandbox, OR the `sh -lc` string must be single-line. Never use heredoc argv style.

### Mount establish + health check
**Source:** `scripts/install-nemoclaw-cron.sh` lines 126-131 + `scripts/nemoclaw-cron-tick.sh` lines 44-50
**Apply to:** `install_enforcement_plugin()` mount step + marker smoke step
```bash
MNT="${HOME}/sbx-openclaw-${SANDBOX_NAME}"
mkdir -p "${MNT}"
if ! mountpoint -q "${MNT}" 2>/dev/null; then
  nemoclaw "${SANDBOX_NAME}" share mount /sandbox/.openclaw "${MNT}" \
    || { echo "ERROR: mount failed" >&2; exit 1; }
fi
```

### `allowConversationAccess` config patch
**Source:** `scripts/post-install.sh` lines 624-628
**Apply to:** `install_enforcement_plugin()` config patch step

Without this patch, `before_agent_finalize` and `agent_end` are silently blocked by the openclaw registry (verified against openclaw 2026.6.1). The patch is safe to re-run (JSON5 merge). The combined plugin also needs `enabled: true`.

### Fail-hard vs fail-open distinction
**Source:** `scripts/post-install.sh` lines 617, 632-636 (warn-and-continue) vs `scripts/post-install-nemoclaw.sh` `fail()` helper (line 55)
**Apply to:** `install_enforcement_plugin()` validation steps (D-09)

Standalone install uses `warn` + continue. NemoClaw enforcement install uses `fail` (abort non-zero) for the turn-test and inspect assertions — because NCENF-01 is the highest-risk requirement and a silently-broken plugin is worse than a failed install.

---

## No Analog Found

All files have close analogs. No files require falling back to RESEARCH.md patterns exclusively.

| File | Note |
|---|---|
| `plugin-nemoclaw/scripts/bake-directive.js` | No prior build-time inliner exists; planner uses the Node `fs.readFileSync`/`writeFileSync` pattern described above |

---

## Metadata

**Analog search scope:** `plugin/`, `scripts/`, `BUDGET-GUARD.md`, `.claude/skills/spike-findings-openclaw-revenium/sources/006-plugin-directive-injection/`
**Files scanned:** 12
**Pattern extraction date:** 2026-06-08
