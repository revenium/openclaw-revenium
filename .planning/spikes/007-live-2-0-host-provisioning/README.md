---
spike: 007
name: live-2-0-host-provisioning
type: standard
validates: "Given a live OpenClaw 2.0 host, when the standalone install path is provisioned by an idempotent script and one real agent turn is run, then the turn's completion is readable back out of the 2.0 SQLite session store"
verdict: PARTIAL
related: [001, 004]
tags: [infra, install, openclaw-2-0, sqlite, provisioning]
host: "52.90.9.242 (bare Ubuntu 26.04 LTS, x86_64, no GPU)"
---

# Spike 007: Live 2.0 Host Provisioning (SPIKE-00)

## What This Validates

Given a live, reproducibly-provisioned OpenClaw 2.0 host, when the standalone OpenClaw + Docker
install path is brought up by `provision-2-0-host.sh` and one real agent turn is completed with a
real Anthropic key, then that turn's completion is readable back out of the 2.0 SQLite session
store — the end-to-end proof that the apparatus every downstream v2.0 phase depends on actually
works. This determination currently covers **Task 1 (standalone path + tracer turn) only**; the
NemoClaw/OpenShell path (Task 2), the `api.revenium.ai` egress confirmation (Task 3), and the
re-runnability + explicit-refusal proof (Task 4) are tracked below as **not yet run**.

## Research

Sources: `.planning/phases/17-live-host-fact-finding-spike/17-RESEARCH.md` §Host Provisioning
(live probe of this host, official install commands, Node/OpenClaw version floors confirmed
against the npm registry) and §Session Read Path candidate (a); `.planning/spikes/CONVENTIONS.md`;
`.planning/spikes/001-nemoclaw-bootstrap/probe-host-compat.sh` (pass/warn/fail scaffolding reused
verbatim); `.planning/phases/17-live-host-fact-finding-spike/17-01-PLAN.md` D-13/D-14/D-15.

## How to Run

```bash
scp -i ~/.ssh/hermes-sandbox.pem \
  .planning/spikes/007-live-2-0-host-provisioning/provision-2-0-host.sh \
  ubuntu@52.90.9.242:~/provision-2-0-host.sh
ssh -i ~/.ssh/hermes-sandbox.pem ubuntu@52.90.9.242 \
  'setsid bash ~/provision-2-0-host.sh > ~/provision-run.log 2>&1 < /dev/null &'
```
Run detached (`setsid ... </dev/null`) per the v1.4 spikes' apt-SIGTTIN-under-tty precedent, even
though a plain non-interactive `ssh host cmd` invocation does not itself have a controlling tty.

## Investigation Trail

1. Verified the Task 1 precondition read-only: SSH reachability (`BatchMode=yes`) and the host
   credential file `~/.spike-17.env` present at mode 600 with non-empty `ANTHROPIC_API_KEY` and
   `REVENIUM_API_KEY` — presence-only checks, no value ever printed.
2. First provisioning run failed (2 fail: OpenClaw not found on PATH, Node reported
   `v22.23.2` below floor) — see **Finding 1** below; this was a script bug, not a host defect.
3. Fixed the script's own `$HOME/.local/bin` PATH prepend (added defensively to pick up the
   installer's rc-file changes) which was unintentionally shadowing the real `/usr/bin/node`
   with a pre-existing, unrelated `~/.local/bin/node` symlink — see **Finding 2**.
4. Re-ran the corrected script: clean 6/6 pass, `VERDICT: COMPATIBLE`.
5. Ran one real turn via `openclaw agent exec` first — it completed (`SPIKE007_OK`) but left
   **no trace** under `~/.openclaw/agents/` — see **Finding 3**; `agent exec` is an isolated
   ephemeral-state entry point, not the persistent one this spike needs.
6. Switched to `openclaw agent --agent main --message ... --local --model anthropic/claude-sonnet-4-6 --json`
   (the non-`exec` entry point) — completed (`SPIKE007_OK2`) and persisted to
   `~/.openclaw/agents/main/agent/openclaw-agent.sqlite`.
7. Read the completion back with `sqlite3 -cmd "PRAGMA busy_timeout=5000;" "file:<path>?mode=ro" ...`
   — the CLI rejects mixing a PRAGMA and a dot-command in one semicolon-joined string; the working
   form passes the PRAGMA via `-cmd` and the dot-command as the trailing argument.
8. `.tables` returned 60 real table names (`transcript_events`, `session_conversations`,
   `session_windows`, `memory_index_*`, `standing_intents`, etc.) — none of which match the
   docs-conceptual `SessionEntry` field list verbatim, confirming D-11's premise that the schema
   is genuinely unpublished and must be captured live (full capture deferred to spike 008/SPIKE-01,
   this spike's job was only to prove the read path is reachable at all).
9. `SELECT ... FROM transcript_events WHERE event_json LIKE '%SPIKE007_OK2%'` returned both the
   user message row and the assistant response row, redacted of nothing (the content is this
   spike's own synthetic test string, not real user data, so T-17-05 does not apply).

## Results

### Finding 1 — first provisioning attempt failed on a script bug, not a host defect

Standalone-path first run (`provision-run-1.log`, not the committed evidence file — superseded by
the corrected run below): OpenClaw and Node both failed detection immediately after their own
install steps reported success. Root cause: **Finding 2**.

### Finding 2 — `~/.local/bin/node` on 52.90.9.242 is a pre-existing symlink to an unrelated
### Hermes-agent-bundled Node v22.23.2, NOT a clean host artifact

`52.90.9.242` is **not a bare host** as RESEARCH.md's live probe characterized it. That probe
(`which openclaw nemoclaw docker revenium sshfs node` → all empty) was accurate for those exact
binary names on the default `$PATH`, but it did not check `~/.local/bin` or `~/.hermes`. This host
carries a substantial, unrelated pre-existing install:

```
$ ls -la ~/.local/bin/ | grep -i node
lrwxrwxrwx 1 ubuntu ubuntu 34 Aug 14 00:40 node -> /home/ubuntu/.hermes/node/bin/node
lrwxrwxrwx 1 ubuntu ubuntu 33 Aug 14 00:40 npm  -> /home/ubuntu/.hermes/node/bin/npm
lrwxrwxrwx 1 ubuntu ubuntu 33 Aug 14 00:40 npx  -> /home/ubuntu/.hermes/node/bin/npx
$ ~/.hermes/node/bin/node --version
v22.23.2
$ ls ~/.hermes | wc -l    # gateway_state.json, sandboxes/, sessions/, cron/, plugins/, .env, etc.
```
`~/.hermes/` contains a fully populated, apparently-active Hermes-agent installation (gateway
lock/state files, a `.clean_shutdown` marker from Sep 15, sandbox/plugin/session directories, and
credential-pool metadata) with file timestamps spanning **2026-08-14 through 2026-09-24** — this
predates the v2.0 spike entirely and is unrelated to this project. Per RESEARCH.md's own **Pitfall
4** ("reusing a patched/leftover sandbox instead of a fresh provision"), this is the live-host
version of exactly that risk, except the pre-existing state belongs to a different agent stack
(Hermes), not a prior run of this spike. `provision-2-0-host.sh` initially added `$HOME/.local/bin`
to its own `$PATH` defensively (guessing the OpenClaw installer might need it, nvm-style); that
guess was wrong for this installer (which uses `~/.npm-global/bin` only) and it caused the script's
own `command -v node` to resolve the shadowing Hermes-bundled binary instead of the correct
NodeSource-installed `/usr/bin/node` (`v24.21.0`). **Fix:** the script no longer prepends
`~/.local/bin`; it only adds `~/.npm-global/bin` (the directory the OpenClaw installer actually
uses). This is recorded as a finding, not silently patched around, per RESEARCH.md's own framing of
Pitfall 4: the pre-existing Hermes state was not removed or touched, and downstream phases
provisioning this same host must be aware `~/.local/bin/node` resolves to an unrelated v22 runtime
and must never rely on ambient `$PATH` ordering that includes it ahead of `/usr/bin`.

**Consequence for Phase 22 (NemoClaw path on this host) and Phase 24 (fresh-host verification):**
any future provisioning or read-path script touching this host must resolve `node`/`npm`/`npx` via
an explicit, non-`~/.local/bin` path (e.g. `/usr/bin/node` or `command -v` with `~/.local/bin`
excluded), not bare `$PATH` lookup.

### Finding 3 — `openclaw agent exec` does not persist to the SQLite store; use `openclaw agent`

`openclaw agent exec` is documented as "run one isolated headless embedded agent turn." A real
turn was completed with it (`SPIKE007_OK`, session id `c11d342d-ba6d-4412-ad7e-cd3a3a74aac6`,
model `claude-sonnet-4-6`, real usage/cost fields returned), but afterward `~/.openclaw/agents/`
did not exist at all — `agent exec`'s state is ephemeral by design (consistent with its
`--state-dir <dir>` flag description, "use an existing state directory **without deleting it**",
implying the default state dir IS deleted). This is the correct behavior for `exec`'s stated
purpose (a one-off headless CI-style run) but it is **not** "the normal agent entry point" this
spike's read-path proof needs. The non-`exec` `openclaw agent` command (`--agent <id> --message
... --local --model ... --json`) is the persistent entry point and is what every downstream v2.0
phase's read-path work will actually observe in production — the tracer turn below uses this
command, not `exec`.

### Evidence triplet — standalone path provisioned

**Command:**
```bash
ssh -i ~/.ssh/hermes-sandbox.pem ubuntu@52.90.9.242 'setsid bash ~/provision-2-0-host.sh > ~/provision-run.log 2>&1 < /dev/null &'
```
**Raw output** (see `provision-run.log`, third and final run after the Finding 2 fix):
```
==================================================
 Spike 007 — Live 2.0 host provisioning (standalone path)
==================================================

Host: Linux ip-172-31-40-178 7.0.0-1006-aws #6-Ubuntu SMP PREEMPT Tue May 26 12:04:34 UTC 2026 x86_64 GNU/Linux
--------------------------------------------------
Swap                               ✓ already present (8G)
sshfs                              ✓ already installed (fusermount3 version: 3.18.2)
OpenClaw                           ✓ already installed
OpenClaw                           ✓ OpenClaw 2026.9.6 (eb377ac) (>= 2026.8.1)
Node.js                            ✓ v24.21.0 (satisfies >=24.16.0 <25 || >=26.1.0)
Docker                             ✓ installed and daemon reachable (29.8.1)
--------------------------------------------------
Summary: 6 pass, 0 warn, 0 fail

VERDICT: COMPATIBLE — standalone path provisioned successfully.
```
**Interpretation:** the standalone path — Node, OpenClaw, Docker, plus the swapfile and sshfs
prerequisites Task 2 needs — is up and each version clears its floor by numeric (`sort -C -V`)
comparison, not string-prefix. **Host:** 52.90.9.242. **Date:** 2026-09-24. **Versions in effect:**
OpenClaw `2026.9.6 (eb377ac)`, Node `v24.21.0`, Docker `29.8.1` (all captured verbatim in
`versions-resolved.txt`, prefixed `standalone:`).

### Evidence triplet — one real agent turn, read back out of the SQLite store

**Command (turn):**
```bash
export PATH="$HOME/.npm-global/bin:$PATH"
set -a; . ~/.spike-17.env; set +a
openclaw agent --agent main --message "Reply with exactly: SPIKE007_OK2" \
  --local --model anthropic/claude-sonnet-4-6 --json
```
**Raw output (trimmed to the load-bearing fields):**
```json
"finalPromptText": "Reply with exactly: SPIKE007_OK2",
"finalAssistantVisibleText": "SPIKE007_OK2",
"finalAssistantRawText": "SPIKE007_OK2",
"executionTrace": { "winnerProvider": "anthropic", "winnerModel": "claude-sonnet-4-6",
  "attempts": [{"provider":"anthropic","model":"claude-sonnet-4-6","result":"success","stage":"assistant"}],
  "fallbackUsed": false, "runner": "embedded" }
```
Run id `516d58ab-b5ef-40ee-b06c-7fd996bfa3e2`, agentId `main` (resolved live from the filesystem —
`~/.openclaw/agents/main/agent/`, not assumed).

**Command (read-back):**
```bash
sqlite3 -cmd "PRAGMA busy_timeout=5000;" \
  "file:$HOME/.openclaw/agents/main/agent/openclaw-agent.sqlite?mode=ro" \
  "SELECT session_id, seq, created_at, event_json FROM transcript_events WHERE event_json LIKE '%SPIKE007_OK2%' ORDER BY seq;"
```
**Raw output** (see `tracer-turn-readback.txt` for the full verbatim capture):
```
73f57495-1725-4ae7-8ef7-bb4608a501e9|5|1790224156671|{"type":"message",...,"message":{"role":"assistant","content":[{"type":"text","text":"SPIKE007_OK2"}],"api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-4-6",...}}
```
**Interpretation:** the exact turn completed above is present, byte-verifiable, in a read-only
(`mode=ro`), WAL-aware (`PRAGMA busy_timeout=5000`) connection against the live 2.0 SQLite store —
the tracer's end-to-end proof. **Host:** 52.90.9.242. **Date:** 2026-09-24. **Versions in effect:**
OpenClaw `2026.9.6 (eb377ac)`, Node `v24.21.0`.

### NemoClaw/OpenShell path (Task 2) — not yet run

### `api.revenium.ai` egress confirmation (Task 3) — not yet run

### Re-runnability + explicit-refusal proof (Task 4) — not yet run

## Reusable Facts Captured So Far

- Standalone-path agentId is `main`; SQLite store at `~/.openclaw/agents/main/agent/openclaw-agent.sqlite`.
- `sqlite3` CLI cannot mix a PRAGMA and a dot-command (`.tables`, `.schema`) in one
  semicolon-joined string — use `sqlite3 -cmd "PRAGMA busy_timeout=5000;" "file:...?mode=ro" "<dot-command-or-SQL>"`.
- `openclaw agent exec` is ephemeral (no persisted SQLite state); `openclaw agent --agent <id>
  --message ... --local --model provider/model --json` is the persistent, production-shaped entry
  point and is what Phase 19's read-path work must target.
- `~/.local/bin/node` on `52.90.9.242` resolves to an unrelated Hermes-bundled Node v22.23.2 — any
  script on this host must resolve Node explicitly, never via bare `$PATH` including that directory.
- OpenClaw's official installer's npm-global bin dir is `~/.npm-global/bin` (not `~/.local/bin`,
  not nvm-style) — this is where the `openclaw` binary actually lands.
