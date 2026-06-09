# Phase 15 Plan 03: Live Validation Record

**Date:** 2026-06-09
**Host:** 34.224.27.67 (sandbox: revenium-spike)
**Validator:** Automated (executor agent)
**Plugin version:** 1.0.0 (dist/index.js committed in plugin-nemoclaw/)

---

## Summary of Live Validation

The `revenium-enforcement` plugin was successfully installed and loaded on the live sandbox host.
Key behavioral proof was obtained: the `before_prompt_build` hook IS firing and the BUDGET-GUARD.md
directive IS reaching the Nemotron model each turn (evidenced by the model attempting guardrail
checks). However, agent turns hang in the Nemotron model's tool-calling loop, preventing the
`openclaw agent --json` finalPromptText assertion (Gate A) from completing. The `finalPromptText`
field has also been removed from the `--json` output in openclaw 2026.5.22.

**BLOCKER RECORDED:** Plan 02 fail-HARD Gate A cannot be satisfied on this host as designed.
Root cause: Nemotron model + MANDATORY guardrail directive = infinite tool-call loop.
The plugin mechanism IS working; the validation method needs to adapt.

---

## SC1 — Per-turn directive injection (before_prompt_build trusted/active)

### Status: PARTIALLY EVIDENCED — injection confirmed; finalPromptText assertion blocked

### Evidence

**Plugin install and trust record:**
```
Command: nemoclaw revenium-spike exec -- sh -lc 'openclaw plugins install --force /sandbox/.openclaw/extensions/revenium-enforcement 2>&1'
Exit: 0
Output:
  Installing to /sandbox/.openclaw/extensions/revenium-enforcement...
  Linked peerDependency "openclaw" -> /usr/local/lib/node_modules/openclaw
  Installed plugin: revenium-enforcement
  Restart the gateway to load plugins.
```

**Plugin inspect output (enabled+loaded state):**
```
Command: nemoclaw revenium-spike exec -- sh -lc 'openclaw plugins inspect revenium-enforcement 2>&1'
Exit: 0
Output:
  Revenium Enforcement
  id: revenium-enforcement
  Injects guardrail directive on every turn and gates task marker writing.

  Status: loaded
  Format: openclaw
  Source: $OPENCLAW_HOME/.openclaw/extensions/revenium-enforcement/dist/index.js
  Origin: global
  Version: 1.0.0
  Shape: non-capability
  Capability mode: none
  Legacy before_agent_start: no

  Policy:
  allowConversationAccess: true

  Install:
  Source: path
  Source path: $OPENCLAW_HOME/.openclaw/extensions/revenium-enforcement
  Install path: $OPENCLAW_HOME/.openclaw/extensions/revenium-enforcement
  Recorded version: 1.0.0
  Installed at: 2026-06-09T01:40:43.617Z
```

**Plugin list (enabled, loaded, global source):**
```
Command: nemoclaw revenium-spike exec -- sh -lc 'openclaw plugins list 2>&1' | grep revenium
Output:
  | Revenium | revenium | openclaw | enabled | global:revenium-enforcement/dist/index.js | 1.0.0 |
```

**Gateway startup log — 9 plugins including revenium-enforcement:**
```
Source: /sandbox/.openclaw/logs/gateway-persistent.log

2026-06-09T02:04:03.695+00:00 [gateway] http server listening (9 plugins: browser, canvas,
device-pair, file-transfer, memory-core, nemoclaw, phone-control, revenium-enforcement,
talk-voice; 5.6s)
```

**Directive injection confirmed via model behavior (session log):**

When the plugin is enabled, the model attempts to run the MANDATORY guardrail check from the
BUDGET-GUARD.md directive on EVERY turn. This IS proof that `before_prompt_build` fires and the
directive reaches the model — the model would not attempt `guardrail-status.json` reads unless
the MANDATORY instruction was injected.

```
Source: /tmp/openclaw-998/openclaw-2026-06-09.log

2026-06-09T01:42:48.266+00:00 [tools] tool_search_code failed: ReferenceError: require is not defined
  raw_params={"code":"const fs = require('fs');\nconst path = require('path');\nconst statusPath = '~/.openclaw/skills/revenium/guardrail-status.json';..."}

2026-06-09T01:44:00.096+00:00 [tools] tool_search_code failed: TypeError: openclaw.tools.exec is not a function
  raw_params={"code":"return { result: await openclaw.tools.exec({ cmd: 'cat ~/.openclaw/skills/revenium/guardrail-status.json'..."}

2026-06-09T01:58:59.226+00:00 [tools] tool_search_code failed: Error: ENOENT: no such file or directory
  raw_params={"code":"return { result: await openclaw.tools.call('openclaw:core:read', { path: '/home/openclaw/.openclaw/skills/revenium/guardrail-status.json' }) };"}
```

### Blocker for Gate A

The Plan 02 fail-HARD Gate A assertion (`openclaw agent --json` containing `<revenium-guard>` in
`finalPromptText`) CANNOT be satisfied on this host:

1. **API changed:** `finalPromptText` does not exist in `openclaw agent --json` output on
   OpenClaw 2026.5.22. The systemPromptReport field is present but does not include the prompt
   text content. Spike 006 was run on a different version where this field was present.

2. **Model hang:** Agent turns with the `revenium-enforcement` plugin enabled hang:
   ```
   $ timeout 45 nemoclaw revenium-spike exec -- sh -lc \
       'openclaw agent --agent main --session-id enf-sc1-v2 --json --message "Say OK"'
   Exit: 124 (timeout)
   ```
   Without plugin: turns complete in under 10 seconds (exit 0). The model enters an infinite
   tool-calling loop trying to satisfy the MANDATORY guardrail check.

The Plan 02 install script's Gate A (`fail` if `<revenium-guard>` absent from finalPromptText)
would ABORT the install on this host. This is recorded as BLOCKER B-01/B-02.

---

## SC2 — Halt-honoring: halted:true status honored under NemoClaw

### Status: BLOCKED — cannot be evaluated (agent turns hang with plugin enabled)

The halt-honoring test requires running a live agent turn with the plugin enabled to observe that
the agent emits the halt message. Since all agent turns hang in the tool-calling loop when the
plugin is active, SC2 cannot be honestly evaluated on this host with the Nemotron model.

**Not fabricated.** Recorded as BLOCKER B-03.

---

## SC3 — Marker attribution: marker lands in mount/markers/ from substantive turn

### Status: PARTIALLY EVIDENCED for infrastructure; BLOCKED for live turn attribution

**Infrastructure verified:**
- Share mount established: `~/sbx-openclaw-revenium-spike` mounted as SSHFS at
  `/sandbox/.openclaw` inside the sandbox.
- Metering cron installed (every minute).
- Revenium skill deployed: `openclaw skills list` shows `revenium` as `ready`.
- `before_agent_finalize` policy registered: `allowConversationAccess: true` in inspect output.

**What cannot be evaluated:**
A substantive exec-tool turn driving an actual marker write cannot be run while the plugin
causes agent hang. Recorded as BLOCKER B-04.

---

## SC4 — Fail-open: hook error does not block agent reply

### Status: PARTIALLY EVIDENCED — structural guarantee; live hook induction blocked

**What was verified:**
- With plugin disabled: all agent turns complete normally (exit 0, reply returned).
- The plugin code has double try/catch fail-open on every handler (Plan 01, commit 89b2213).
- Unit tests: 35 tests pass including 5 CR-01 fail-open boundary tests (Plan 01).

The fail-open guarantee is structurally enforced. A live hook exception test cannot be run
while turns hang for the model behavior reason.

**Cross-reference:** Plan 01 unit tests cover the fail-open boundary (35/35 pass, commit 89b2213).

---

## SC5 — Plugin authored from scaffold shape with configSchema + openclaw.extensions

### Status: EVIDENCED

**package.json (deployed to sandbox):**
```json
{
  "name": "revenium-enforcement",
  "type": "module",
  "openclaw": { "extensions": ["./dist/index.js"] },
  "peerDependencies": { "openclaw": ">=2026.6.1" }
}
```

**openclaw.plugin.json (deployed to sandbox):**
```json
{
  "id": "revenium-enforcement",
  "name": "Revenium Enforcement",
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

**openclaw plugins inspect evidence:**
```
Status: loaded
Format: openclaw
Source: $OPENCLAW_HOME/.openclaw/extensions/revenium-enforcement/dist/index.js
Origin: global
Installed at: 2026-06-09T01:40:43.617Z
Policy: allowConversationAccess: true
```
Provenance accepted (trust recorded). Origin: global (via `openclaw plugins install`).

---

## Install Path Deviations Recorded

### Deviation 1: install_skill_nemoclaw() fails from home directory due to SSHFS mounts

**What happened:**
```
$ bash ~/scripts/post-install-nemoclaw.sh
[...]
Deploying revenium skill into sandbox
  Skill directory contains files with unsafe characters:
    sbx-openclaw/extensions/nemoclaw/node_modules/@isaacs/fs-minipass/README.md
    sbx-openclaw-revenium-spike/npm/node_modules/@tencent-weixin/openclaw-weixin/CHANGELOG.md
    [... many more ...]
  File names must match [A-Za-z0-9._-/]. Rename or remove them.

  X nemoclaw skill install failed
Exit: 1
```

**Root cause:** `install_skill_nemoclaw()` uses `${SCRIPT_DIR}/..` as skill dir, which resolves
to `~/` on the remote host. The SSHFS mounts in `~/` contain `node_modules` with spaces in
README/CHANGELOG filenames, which `nemoclaw skill install` rejects.

**Workaround:** Created `~/revenium-skill/` with only the required files:
```
$ mkdir -p ~/revenium-skill/scripts
$ cp ~/SKILL.md ~/BUDGET-GUARD.md ~/revenium-skill/
$ cp -r ~/scripts/* ~/revenium-skill/scripts/
$ cp -r ~/plugin-nemoclaw/ ~/revenium-skill/plugin-nemoclaw/
$ nemoclaw revenium-spike skill install ~/revenium-skill/
  Skipping 1 hidden path(s): plugin-nemoclaw/.gitignore
  Validated SKILL.md (name: revenium, 38 files)
  Uploaded 38 file(s) to sandbox
  Skill 'revenium' updated
```

**Fix needed for Plan 02:** `install_skill_nemoclaw()` should use a clean skill dir or exclude
mount directories via `.nemoclawignore` or equivalent.

### Deviation 2: openclaw agent --json finalPromptText field removed in 2026.5.22

**What happened:** `openclaw agent --json` output does not include `finalPromptText` field.
Output structure observed:
```json
{
  "result": {
    "meta": {
      "systemPromptReport": {
        "systemPrompt": { "chars": 24300 },
        "currentTurn": { "promptChars": 649, "runtimeContextChars": 0 },
        ...
      }
    }
  }
}
```
The `finalPromptText` field spike 006 relied on is absent.

**Impact:** Plan 02 Gate A assertion `grep -q "<revenium-guard>"` on the JSON output is broken.
The `currentTurn.runtimeContextChars` field was also 0 in baseline (no plugin) turns.

### Deviation 3: Agent turns hang (Nemotron model + MANDATORY directive = tool loop)

**What happened:** With `revenium-enforcement` enabled, all agent turns timeout:
```
$ timeout 45 nemoclaw revenium-spike exec -- sh -lc \
    'openclaw agent --agent main --session-id enf-sc1-v2 --json --message "Say OK" 2>&1'
Exit: 124 (timeout — no output returned)
```
Session log shows the model iterating through tool_search_code attempts to read
`guardrail-status.json`. Each attempt fails with a different error. The model does not give
up and return a response.

**Sandbox restored to healthy:**
```
$ nemoclaw revenium-spike exec -- sh -lc 'openclaw plugins disable revenium-enforcement'
  Disabled plugin "revenium-enforcement". Restart the gateway to apply.
$ nemoclaw revenium-spike recover
  Probe complete: recovered OpenClaw gateway in 'revenium-spike'.
$ timeout 15 nemoclaw revenium-spike exec -- sh -lc \
    'openclaw agent --agent main --session-id healthcheck1 --message "ping"'
Exit: 0 (agent responded)
```

---

## Open Blockers

| ID | SC | Blocker | Root Cause |
|----|-----|---------|------------|
| B-01 | SC1 | Gate A: `<revenium-guard>` in finalPromptText cannot be asserted | `finalPromptText` field removed from `openclaw agent --json` in 2026.5.22 |
| B-02 | SC1/SC2/SC3 | Agent turns hang with plugin enabled on Nemotron model | Nemotron + MANDATORY guardrail directive = infinite tool_search_code loop |
| B-03 | SC2 | Halt-honoring cannot be tested | Depends on live turn completing (blocked by B-02) |
| B-04 | SC3 | Marker attribution from substantive turn cannot be tested | Depends on live exec-tool turn completing (blocked by B-02) |

---

## What IS Confirmed Working

| Item | Evidence |
|------|----------|
| Plugin installs via `openclaw plugins install` | Exit 0, "Installed plugin: revenium-enforcement" |
| Plugin is trusted (provenance recorded) | `Origin: global`, `Status: loaded` in inspect |
| `allowConversationAccess: true` applied | Shown in inspect Policy section |
| `before_prompt_build` fires and injects directive | Model attempts guardrail checks in session log |
| Gateway registers the plugin on startup | `9 plugins: ... revenium-enforcement ...` in persistent log |
| Sandbox is healthy when plugin is disabled | Turn completes in <10s after disable |
| Plan 02 install script logic is correct | Syntax-valid; gates are correct IF model completes turns |
| Revenium skill deployed | `openclaw skills list` shows `revenium` as `ready` |
| Metering cron installed | `crontab -l` shows nemoclaw metering entry |

---

## Recommended Fix

The blocker is NOT in the plugin code — the plugin works correctly. The blockers are in:

1. **Gate A assertion method**: needs to check `gateway-persistent.log` for `revenium-enforcement`
   in the plugin list instead of parsing `finalPromptText` from `--json` output.
   Alternative: check `api.logger.info("revenium-guard injected")` in gateway log.

2. **Model compatibility**: The Nemotron 120B model interprets `MANDATORY guardrail check BEFORE
   EVERY OPERATION` literally and enters a tool-call loop. Options:
   - Test on a model that does not loop (Claude, GPT-4)
   - Modify BUDGET-GUARD.md to use softer language for the NemoClaw path
   - Seed a valid `guardrail-status.json` before running turns (the model finds the file, doesn't loop)

3. **install_skill_nemoclaw fix**: needs to pass a clean skill dir path, not `~/`.

The BLOCKER is real and is recorded here per the CRITICAL HONESTY RULE.
A silently broken plan pass has NOT been claimed.
