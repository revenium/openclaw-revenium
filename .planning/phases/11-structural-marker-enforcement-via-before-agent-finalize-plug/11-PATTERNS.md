# Phase 11: Structural Marker Enforcement via before_agent_finalize plugin — Pattern Map

**Mapped:** 2026-06-04
**Files analyzed:** 9 (7 new, 1 modified, 1 new + pre-built artifact committed)
**Analogs found:** 4 / 9 (5 files are a new TypeScript tech surface with no in-repo analog)

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---|---|---|---|---|
| `plugin/src/index.ts` | plugin/middleware | event-driven | NONE — new tech surface | no analog |
| `plugin/src/index.test.js` | test | event-driven | `tests/test_write_marker.sh` | role-match (test harness structure only) |
| `plugin/package.json` | config | — | NONE — first npm package in repo | no analog |
| `plugin/openclaw.plugin.json` | config | — | NONE — first plugin manifest in repo | no analog |
| `plugin/tsconfig.json` | config | — | NONE — first TypeScript config in repo | no analog |
| `plugin/dist/index.js` | artifact | — | NONE — committed build artifact | no analog |
| `scripts/verify-markers.sh` | utility/diagnostic | batch / file-I/O | `scripts/report.sh` + `scripts/write-marker.sh` | role-match |
| `tests/test_verify_markers.sh` | test | batch | `tests/test_write_marker.sh` | exact |
| `scripts/post-install.sh` | config/installer | request-response | self (lines 502–614 = AGENTS.md injection steps §7/7b) | exact (modify existing file) |

---

## Pattern Assignments

### `plugin/src/index.ts` (plugin, event-driven) — NEW TECH SURFACE

**NO IN-REPO ANALOG.** This is the first TypeScript file and the first OpenClaw plugin in this repository. No existing file serves the same role.

**Use RESEARCH.md Pattern 1 directly.** The complete verified blueprint is in `11-RESEARCH.md` lines 188–252. Reproduce it verbatim — every line has been verified against OpenClaw 2026.6.1 source on the ClawHub host.

Key facts the planner must carry into the plan actions:

- Import path: `"openclaw/plugin-sdk/plugin-entry"` — verified subpath export of the host `openclaw` CLI
- Three hook registrations: `before_tool_call` (NOT a conversation hook), `before_agent_finalize` (IS a conversation hook), `agent_end` (IS a conversation hook)
- Tracking sets `execRuns` and `markedTaskRuns` are module-level `Set<string>` — not class fields, not closures
- `before_tool_call` checks `event.toolName === "exec"` (and as a belt-and-suspenders: `"bash"`) plus `event.params.command.includes("write-marker.sh")`
- `before_agent_finalize` returns `undefined` (pass-through) in three cases: no `runId`, no exec tool ran this turn (`!execRuns.has(runId)`), already marked (`markedTaskRuns.has(runId)`)
- The `revise` return shape: `{ action: "revise" as const, reason: string, retry: { instruction: string, idempotencyKey: \`marker-gate:\${runId}\`, maxAttempts: 1 } }`
- `agent_end` deletes both `runId` entries from both sets (memory leak prevention)
- `allowConversationAccess: true` is REQUIRED in the openclaw config for `before_agent_finalize` and `agent_end` to fire — without it the hooks are silently blocked (see RESEARCH.md Pitfall 1)

---

### `plugin/package.json` (config) — NEW TECH SURFACE

**NO IN-REPO ANALOG.** First npm package.json in the repo.

**Use RESEARCH.md verified shape directly** (`11-RESEARCH.md` lines 400–414):

```json
{
  "name": "revenium-marker-gate",
  "type": "module",
  "openclaw": {
    "extensions": ["./dist/index.js"]
  },
  "peerDependencies": {
    "openclaw": ">=2026.6.1"
  },
  "devDependencies": {
    "typescript": "^5.0.0"
  }
}
```

Critical: `"type": "module"` (ESM); `"extensions"` points to `"./dist/index.js"` (pre-built, never `./src/index.ts`). No `prepare`/`postinstall` npm scripts — the host has no `tsc`.

---

### `plugin/openclaw.plugin.json` (config) — NEW TECH SURFACE

**NO IN-REPO ANALOG.**

**Use RESEARCH.md verified manifest directly** (`11-RESEARCH.md` lines 385–396):

```json
{
  "id": "revenium-marker-gate",
  "name": "Revenium Marker Gate",
  "description": "Forces write-marker.sh before finalizing a substantive turn.",
  "version": "1.0.0",
  "activation": { "onStartup": false },
  "contracts": { "tools": [] },
  "configSchema": {}
}
```

---

### `plugin/tsconfig.json` (config) — NEW TECH SURFACE

**NO IN-REPO ANALOG.** Must compile `src/index.ts` → `dist/index.js` as ESM. Standard minimal shape:

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "outDir": "./dist",
    "rootDir": "./src",
    "strict": true,
    "declaration": false
  },
  "include": ["src/**/*.ts"]
}
```

`"module": "ESNext"` matches `"type": "module"` in package.json. The host has Node 22 which supports all ES2022 features.

---

### `plugin/dist/index.js` (artifact) — NEW TECH SURFACE

**NO IN-REPO ANALOG.** This is the compiled output of `plugin/src/index.ts`, committed to the repo so the skill tarball ships it ready-to-run. It must not be gitignored. The file is produced by running `npm run build` in the `plugin/` directory on the dev machine and committing the output. The planner should note that any code changes to `index.ts` require a rebuild + re-commit of `dist/index.js`.

---

### `plugin/src/index.test.js` (test, event-driven)

**Closest analog:** `tests/test_write_marker.sh` — same test-harness role (exercise a unit by constructing minimal synthetic inputs, assert output shape and exit code). Structure is the same: setup, invoke, assert, summary. The tech stack differs (Node.js `node:test` instead of bash), but the harness discipline is directly analogous.

**Test harness pattern from** `/Users/johndemic/Development/projects/revenium/openclaw-revenium/tests/test_write_marker.sh` **lines 1–50 and 263–272:**

```bash
# Header block pattern (lines 1–11): named script, lists test coverage
# set -uo pipefail on line 13
# PASS/FAIL counters with pass()/fail() helpers (lines 20–23)
# Minimal tmp home construction (lines 28–48)
# cleanup() registered with trap cleanup EXIT (lines 46–49)

# Summary block (lines 267–272):
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
```

**For `index.test.js` (Node.js):** The test file uses `node:test` built-in (Node 22 ships it, no install needed). The equivalent pattern:

```javascript
// plugin/src/index.test.js
// Run: node --test src/index.test.js  (from plugin/ directory)
import { test } from "node:test";
import assert from "node:assert/strict";

// Test: before_tool_call tracking adds execRuns entry
// Test: before_tool_call adds markedTaskRuns when command includes write-marker.sh
// Test: before_agent_finalize returns undefined (pass-through) when no exec ran
// Test: before_agent_finalize returns revise when exec ran but no marker
// Test: before_agent_finalize returns undefined after marker registered
// Test: agent_end cleans up both sets
```

Tests must mock the `api.on` registration calls to capture handlers, then invoke them with synthetic event/ctx objects. The plugin module cannot be imported directly without the `openclaw/plugin-sdk/plugin-entry` module available; use a lightweight stub of `definePluginEntry` in the test file.

---

### `scripts/verify-markers.sh` (utility/diagnostic, batch/file-I/O)

**Closest analog (structure):** `scripts/write-marker.sh` — same `set -uo pipefail`, sources `common.sh`, uses env-passing Python heredoc for the heavy lifting, uses `SESSIONS_DIR` and `MARKERS_DIR` from `common.sh`.

**Closest analog (session-iteration):** `scripts/report.sh` — same pattern of iterating `SESSIONS_DIR/*.jsonl`, excluding cron sessions via `sessions.json`, reading marker JSONL files from `MARKERS_DIR/${sid}.jsonl`.

**Script header + common.sh sourcing pattern** from `/Users/johndemic/Development/projects/revenium/openclaw-revenium/scripts/write-marker.sh` lines 1–27:

```bash
#!/usr/bin/env bash
# =============================================================================
# verify-markers.sh — [description]
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"
```

This gives `verify-markers.sh` access to `SESSIONS_DIR`, `MARKERS_DIR`, `get_root_session_id`, `info`, `warn`, and `error` from `common.sh` without re-declaring them.

**Cron-session exclusion + session iteration pattern** from `/Users/johndemic/Development/projects/revenium/openclaw-revenium/scripts/write-marker.sh` lines 68–94:

```python
# Inside env-passing Python heredoc:
cron_sids = set()
sessions_json = os.path.join(sessions_dir, 'sessions.json')
if os.path.exists(sessions_json):
    try:
        with open(sessions_json, encoding='utf-8') as fh:
            smap = json.load(fh)
        if isinstance(smap, dict):
            for key, val in smap.items():
                if key.startswith('agent:main:cron:'):
                    if isinstance(val, str):
                        cron_sids.add(val.split('/')[-1] if '/' in val else val)
                    elif isinstance(val, dict):
                        sid_val = val.get('id') or val.get('sessionId') or ''
                        if sid_val:
                            cron_sids.add(sid_val)
    except Exception:
        pass  # fail-open

all_files = [f for f in os.listdir(sessions_dir) if f.endswith('.jsonl')]
non_cron = [f for f in all_files if f[:-len('.jsonl')] not in cron_sids]
```

**Completion counting pattern** from `/Users/johndemic/Development/projects/revenium/openclaw-revenium/scripts/write-marker.sh` lines 108–141 (the `last_completion_info` function). For `verify-markers.sh`, count all assistant-message records in a session file rather than just the last one:

```python
def count_completions(session_path):
    count = 0
    try:
        with open(session_path, encoding='utf-8') as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if not isinstance(rec, dict):
                    continue
                msg = rec.get('message')
                if (rec.get('type') == 'message'
                        and isinstance(msg, dict)
                        and msg.get('role') == 'assistant'):
                    count += 1
    except OSError:
        pass
    return count
```

**Marker counting pattern** from `/Users/johndemic/Development/projects/revenium/openclaw-revenium/scripts/report.sh` lines 532–546 (marker file reading). For `verify-markers.sh`, count task-marker records (no `kind` field, has `task_type`):

```python
def count_task_markers(marker_path):
    count = 0
    try:
        with open(marker_path, encoding='utf-8') as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if isinstance(rec, dict) and 'task_type' in rec and rec.get('kind') != 'job':
                    count += 1
    except OSError:
        pass
    return count
```

**Output format:** tabular per-session report to stdout, summary at end. Pattern from `report.sh` logging discipline — no `tee` in a diagnostic script (interactive-only, not cron):

```bash
# Output: one line per session
# session_id | completions | markers | gap | coverage%
# Summary: total completions, total markers, total gap, coverage %
```

**Env-passing Python heredoc discipline** from `write-marker.sh` lines 40–45 (never interpolate bash variables inside `<<'PY'`; pass via env):

```bash
SESSIONS_DIR="${SESSIONS_DIR}" \
MARKERS_DIR="${MARKERS_DIR}" \
python3 - <<'PY'
import json, os, sys
sessions_dir = os.environ['SESSIONS_DIR']
markers_dir  = os.environ['MARKERS_DIR']
# ...
PY
```

---

### `tests/test_verify_markers.sh` (test, batch/file-I/O)

**Closest analog:** `tests/test_write_marker.sh` — same file role (bash integration test for a single bash script), same tmp-home construction pattern, same PASS/FAIL counter discipline, same `trap cleanup EXIT`.

**Full harness template** from `/Users/johndemic/Development/projects/revenium/openclaw-revenium/tests/test_write_marker.sh`:

**Header + setup pattern** (lines 1–50):

```bash
#!/usr/bin/env bash
# =============================================================================
# test_verify_markers.sh — Integration tests for scripts/verify-markers.sh
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERIFY_MARKERS="${REPO_ROOT}/scripts/verify-markers.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

TMP_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-vm-home.XXXXXX")
TMP_SESSIONS="${TMP_HOME}/agents/main/sessions"
TMP_STATE="${TMP_HOME}/skills/revenium"
TMP_MARKERS="${TMP_STATE}/markers"

mkdir -p "${TMP_SESSIONS}" "${TMP_STATE}" "${TMP_MARKERS}"

cleanup() { rm -rf "${TMP_HOME}"; }
trap cleanup EXIT

run_verify() {
  OPENCLAW_HOME="${TMP_HOME}" bash "${VERIFY_MARKERS}" "$@"
}
```

**Session fixture pattern** (lines 182–196 of `test_write_marker.sh`, adapted):

```bash
# Build a minimal session JSONL with N assistant completions
FAKE_SID="aabbccdd-0001-0001-0001-000000000001"
FAKE_SESSION="${TMP_SESSIONS}/${FAKE_SID}.jsonl"
# Write session header + user + assistant messages
# Use touch to control mtime
```

**Key test scenarios to cover:**
1. Session with 3 completions + 3 markers → gap = 0, coverage = 100%
2. Session with 3 completions + 1 marker → gap = 2, coverage = 33%
3. Session with 3 completions + 0 markers (no marker file) → gap = 3, coverage = 0%
4. Cron session excluded from output
5. Summary line contains correct totals

**Summary pattern** (lines 267–272 of `test_write_marker.sh`):

```bash
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
```

---

### `scripts/post-install.sh` (MODIFIED — add new step §8 for plugin install + enable)

**Analog:** The existing AGENTS.md injection steps §7 and §7b in the same file — lines 501–605.

**Step declaration pattern** from `/Users/johndemic/Development/projects/revenium/openclaw-revenium/scripts/post-install.sh` lines 501–504:

```bash
# ---------------------------------------------------------------------------
# N. [Step name]
# ---------------------------------------------------------------------------
step "[Step description]"
```

**Idempotent check-before-act pattern** (lines 509–511):

```bash
if [[ ! -f "${AGENTS_MD}" ]]; then
  warn "AGENTS.md not found at ${AGENTS_MD} — skipping guardrail injection"
elif grep -q "${GUARDRAIL_MARKER}" "${AGENTS_MD}" 2>/dev/null; then
  info "Guardrail check already present in AGENTS.md"
else
  # do the work
fi
```

**`warn` + skip pattern** for fail-open (lines 510, 569–571):

```bash
warn "thing not found — skipping"
```

**`openclaw config patch --stdin` pattern** (RESEARCH.md Pattern 2, verified on host). The new step must:

1. Call `openclaw plugins install "${SKILL_DIR}/plugin" --force` (idempotent via `--force`)
2. Pipe the config patch via stdin (JSON5 merged recursively — safe to re-run)
3. Call `openclaw plugins inspect revenium-marker-gate` and check that `hookNames` includes `before_agent_finalize` — catching the silent-block failure mode
4. Print a note that a gateway restart is required for the plugin to load in the current session

**Exact install + enable block** from RESEARCH.md Pattern 2 (`11-RESEARCH.md` lines 257–267):

```bash
# Install (idempotent via --force; overwrites previous version)
openclaw plugins install "${SKILL_DIR}/plugin" --force 2>/dev/null \
  || warn "plugin install failed — skipping"

# Enable with allowConversationAccess (required for before_agent_finalize + agent_end)
echo '{plugins: {entries: {"revenium-marker-gate": {enabled: true, hooks: {allowConversationAccess: true}}}}}' \
  | openclaw config patch --stdin 2>/dev/null \
  || warn "plugin config patch failed — skipping"
```

**Post-install verification pattern** from `/Users/johndemic/Development/projects/revenium/openclaw-revenium/scripts/post-install.sh` lines 682–695 (the existing `openclaw skills list` check):

```bash
if command_exists openclaw; then
  _skills_list="$(openclaw skills list 2>/dev/null || true)"
  if grep -q "${SKILL_NAME}" <<<"${_skills_list}"; then
    info "..."
  else
    warn "..."
  fi
fi
```

Apply the same pattern for `openclaw plugins inspect revenium-marker-gate`:

```bash
if command_exists openclaw; then
  _inspect="$(openclaw plugins inspect revenium-marker-gate 2>/dev/null || true)"
  if echo "${_inspect}" | grep -q "before_agent_finalize"; then
    info "Plugin hook before_agent_finalize confirmed active"
  else
    warn "before_agent_finalize not in plugin hookNames — allowConversationAccess may not be set"
  fi
fi
```

**Insertion point for the new step:** After the existing step §7b (line 605, after `info "Injected/updated metering directives in AGENTS.md"`) and before the existing step §8 "Configuring budget guard" (line 608). The new step becomes §8 and the current §8 becomes §9 (or the numbering is kept by appending at the end — planner's call, but ordering before the verify step at line 662 ensures the plugin is installed before the final verification pass).

---

## Shared Patterns

### `set -uo pipefail` + env-passing heredoc

**Source:** `scripts/write-marker.sh` lines 23 and 40–45; `scripts/common.sh` line 15; `scripts/report.sh` line 8
**Apply to:** `scripts/verify-markers.sh`

All new bash scripts use `set -uo pipefail`. Python logic is invoked via `python3 - <<'PY'` with env-passing (never string-interpolate bash variables inside the heredoc body).

```bash
set -uo pipefail
# ...
VAR1="${VAR1}" VAR2="${VAR2}" python3 - <<'PY'
import os
v1 = os.environ['VAR1']
v2 = os.environ['VAR2']
PY
```

### `SCRIPT_DIR` + `common.sh` sourcing

**Source:** `scripts/write-marker.sh` lines 25–26; `scripts/guardrail-check.sh` lines 19–21
**Apply to:** `scripts/verify-markers.sh`

```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"
```

This gives access to `SESSIONS_DIR`, `MARKERS_DIR`, `get_root_session_id`, `info`, `warn`, `error`, `LOG_FILE`, `STATE_DIR`.

### PASS/FAIL counter + trap cleanup EXIT

**Source:** `tests/test_write_marker.sh` lines 20–23, 46–49, 267–272
**Apply to:** `tests/test_verify_markers.sh`, `plugin/src/index.test.js`

```bash
PASS=0
FAIL=0
pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

TMP_HOME=$(mktemp -d ...)
cleanup() { rm -rf "${TMP_HOME}"; }
trap cleanup EXIT
```

### `warn` + skip fail-open pattern

**Source:** `scripts/post-install.sh` lines 510, 569–571, 673
**Apply to:** New step in `scripts/post-install.sh`

```bash
some_command 2>/dev/null || warn "command failed — skipping"
```

Every new post-install step exits without `fail` — it uses `warn` and continues, matching the existing fail-open discipline throughout the file.

---

## No Analog Found

Files where no close codebase match exists (planner must use RESEARCH.md patterns, not invent from scratch):

| File | Role | Data Flow | Reason |
|---|---|---|---|
| `plugin/src/index.ts` | plugin/middleware | event-driven | No TypeScript files or OpenClaw plugins exist in repo; use 11-RESEARCH.md Pattern 1 blueprint verbatim |
| `plugin/package.json` | config | — | No npm packages exist in repo; use 11-RESEARCH.md verified shape |
| `plugin/openclaw.plugin.json` | config | — | No plugin manifests exist in repo; use 11-RESEARCH.md verified shape |
| `plugin/tsconfig.json` | config | — | No TypeScript configs exist in repo; use standard ESM tsconfig |
| `plugin/dist/index.js` | artifact | — | Committed build artifact — generated by `npm run build`, not hand-authored |

---

## Metadata

**Analog search scope:** `scripts/`, `tests/`, repo root
**Files read:** `scripts/common.sh`, `scripts/write-marker.sh`, `scripts/report.sh` (header + process_session), `scripts/guardrail-check.sh` (header), `scripts/post-install.sh` (header + lines 490–715), `tests/test_write_marker.sh`, `tests/test_write_job_marker.sh`, `tests/test_report_argv.sh`, `tests/test_guardrail_argv.sh`
**Pattern extraction date:** 2026-06-04
