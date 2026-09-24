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

### Finding 4 — NemoClaw's default "latest" install resolves BELOW the v0.0.128 floor;
### `NEMOCLAW_INSTALL_TAG` is the documented pin mechanism

The non-interactive installer (`curl -fsSL https://www.nvidia.com/nemoclaw.sh | ... bash`) does
**not** resolve "latest" to the newest published git tag. Reading the fetched installer script
(`resolve_release_tag()` / `checkout_release_version()`) shows it walks `git ls-remote --tags
origin 'refs/tags/v*'` to find a **maintained last-known-good** release and explicitly rejects
prereleases — a different, more conservative notion of "latest" than D-15 anticipated. On this
host, that resolved to **NemoClaw v0.0.124**, even though v0.0.128 and v0.0.129 already existed as
real, non-prerelease tags (confirmed via a read-only `git ls-remote --tags origin` against the
installer's own source checkout at `~/.nemoclaw/source/nemoclaw-blueprint`). The in-sandbox
OpenClaw that v0.0.124 manages was **`2026.7.1`** — below the project's `>=2026.8.1` hard floor,
i.e. **not 2.0 at all**. The installer's own error-handling code documents the escape hatch:
`NEMOCLAW_INSTALL_TAG=v<X>` pins to an explicit release. Re-running with
`NEMOCLAW_INSTALL_TAG=v0.0.128` triggered a clean upgrade (`revenium-2-0  NemoClaw image
v0.0.124 → v0.0.128`, sandbox rebuild, `OpenClaw v2026.7.1 → v2026.9.1`) — exactly matching
RESEARCH.md's A1 assumption (`v0.0.128` bundles OpenClaw `2026.9.1`) once explicitly requested.
`provision-2-0-host.sh` now defaults `NEMOCLAW_INSTALL_TAG` to the project's stated floor rather
than trusting the installer's own "latest," and records this as a deliberate pin, not the
installer's organic resolution — **Phase 22/24 must know that a plain re-run of the documented
install command, without this override, currently lands you on a pre-2.0 NemoClaw-managed
OpenClaw.**

### Finding 5 — NemoClaw v0.0.128's CLI renamed `policy-add`/`policy-list` to `policy add`/`policy list`

CONVENTIONS.md (established on NemoClaw v0.0.55 during the v1.4 spikes) documents `nemoclaw <name>
policy-add --from-file <yaml>` and a corresponding `policy-list`. On v0.0.128, `nemoclaw --help`
lists these as **space-separated subcommands** — `policy add` / `policy list` / `policy remove` /
`policy get` — under a `Policy Presets:` section; the hyphenated forms are not recognized. The
first Task 2 run silently "succeeded" at applying the policy (exit 0, discarded stderr) but the
verification step's `policy-list` check also used the stale hyphenated form and reported a false
negative. Corrected in `provision-2-0-host.sh`; recorded here so Phase 22 doesn't rediscover it.

### Finding 6 — a live SSHFS share mount goes stale across a sandbox rebuild

Mounting `/sandbox/.openclaw` before the NemoClaw v0.0.124→v0.0.128 upgrade left a mount table
entry that returned `Input/output error` on any file access afterward — the upgrade destroys and
recreates the underlying sandbox container, invalidating the existing SSHFS session even though
`mount` still lists it. `nemoclaw <name> share status <mount-point>` correctly reported `○ Not
mounted (expected at ...)` despite the stale kernel mount table entry. Fixed by checking mount
*readability* (`ls "$mount" >/dev/null`), not just presence in `mount` output, and unmounting
(`fusermount3 -uz`) before remounting when stale — a concrete instance of the SSHFS-cache-lag
hazard CONVENTIONS.md already flagged in the abstract, now reproduced and handled in the script.

### Evidence triplet — NemoClaw/OpenShell path provisioned on the same host

**Command:**
```bash
ssh -i ~/.ssh/hermes-sandbox.pem ubuntu@52.90.9.242 'bash ~/provision-2-0-host.sh > ~/provision-run.log 2>&1'
```
**Raw output** (final section of `provision-run.log`, clean idempotent re-run):
```
NemoClaw                           ✓ already installed (v0.0.128 >= v0.0.128)
NemoClaw                           ✓ nemoclaw v0.0.128 (>= v0.0.128)
NemoClaw sandbox                   ✓ revenium-2-0 is up
NemoClaw sandbox OpenClaw          ✓ OpenClaw 2026.9.1 (ad6fe23)
Egress preset                      ✓ revenium already applied
Share mount                        ✓ already mounted and readable at /home/ubuntu/nemoclaw-revenium-2-0-mount
In-sandbox SQLite store            ✓ found at /sandbox/.openclaw/agents/main/agent/openclaw-agent.sqlite (host mount: /home/ubuntu/nemoclaw-revenium-2-0-mount/agents/main/agent/openclaw-agent.sqlite)
--------------------------------------------------
Summary: 14 pass, 0 warn, 0 fail

VERDICT: COMPATIBLE — standalone + NemoClaw paths provisioned successfully.
```
**Interpretation:** both production install paths are live on `52.90.9.242` simultaneously (D-13).
The NemoClaw-managed OpenClaw (`2026.9.1`) and the standalone-path OpenClaw (`2026.9.6`) are
different versions, as D-15 anticipated — not normalized to match. The `revenium` egress preset
(`api.revenium.ai:443`, `tls: skip`) is applied to the sandbox (confirmed both via `policy list`
showing `● revenium [user-added] — custom OpenShell policy` and in the full `policy explain`-style
status dump's `network_policies.nemoclaw_custom__revenium__revenium` block). The host-side SSHFS
share mount of `/sandbox/.openclaw` is live and readable, and the in-sandbox SQLite store resolves
to a path under `/sandbox/.openclaw/agents/main/agent/` (surfaced host-side at the mount point) —
confirming this is a genuinely different filesystem root from the standalone path's
`~/.openclaw/agents/main/agent/`, per D-15/D-13. **Host:** 52.90.9.242. **Date:** 2026-09-24.
**Versions in effect:** NemoClaw `v0.0.128`, in-sandbox OpenClaw `2026.9.1 (ad6fe23)`, standalone
OpenClaw `2026.9.6 (eb377ac)`, Node `v24.21.0`, Docker `29.8.1`.

### Finding 7 — a real key surfaces a 4th outcome spike 003's signal table didn't anticipate:
### HTTP 400 "Missing request parameter: teamId", not 200 or 403

Spike 003's signal table anticipated exactly three outcomes for `revenium sources list --output
json`: authenticated 200, server-side 403 (key rejected), or a transport failure (preset not
working). The real Revenium key used here produced a **fourth**, equally real outcome: an
authenticated-layer HTTP 400 validation error, `"Missing request parameter: teamId"` (CLI exit
code 4 — the CLI's own `--help` documents `4  Validation error (bad request)`, distinct from `2
Authentication error (invalid or missing API key)`). This is decisive, not ambiguous: a dummy or
invalid key fails at the CLI's **authentication** layer (exit 2); this key cleared authentication
and failed at the **validation** layer (exit 4) because the account behind this key is
multi-team-scoped and requires an explicit `--team-id`/`REVENIUM_TEAM_ID`, which this spike's
credential set (`user_setup` provisioned only `ANTHROPIC_API_KEY`/`NVIDIA_API_KEY`/
`REVENIUM_API_KEY`) does not include. Per the task's explicit instruction, this was recorded as-is
and not retried with a different key, a guessed team-id, or a widened policy.

### Evidence triplet — `api.revenium.ai` egress preset confirmed working (D-16; closes spike 003 PARTIAL)

**CLI delivery:** the `revenium` CLI (v1.5.0, fetched **host-side** from the official GitHub
release tarball — brew still has no Linux bottle per spike 003 — and placed into the sandbox via
the share mount at `/sandbox/.openclaw/bin-transfer/revenium`, not an in-sandbox fetch, avoiding
any widening of sandbox egress for the GitHub release CDN).

**Command:**
```bash
nemoclaw revenium-2-0 exec -- sh -lc \
  "SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem REVENIUM_API_KEY=\$REVENIUM_API_KEY \
   /sandbox/.openclaw/bin-transfer/revenium sources list --output json"
```
(`$REVENIUM_API_KEY` sourced host-side from `/home/ubuntu/.spike-17.env` via `set -a; . ~/.spike-17.env; set +a` — never inlined literally, never echoed.)

**Raw output** (see `revenium-egress-check.txt` for the full verbatim capture; redaction filter
applied defensively, no key pattern present in this response):
```json
{
  "error": "Request failed (HTTP 400): Missing request parameter: teamId",
  "exit_code": 4,
  "status": 400
}
```
**Interpretation:** the request reached `api.revenium.ai`, passed TLS, and was processed by
Revenium's authenticated API layer (proven by CLI exit code 4 — validation — not exit code 2 —
authentication rejected, and not a connection/proxy/TLS-level failure of any kind). This closes
spike 003's PARTIAL: its one open item, "authenticated meter call: not yet run — blocked on a
valid Revenium API key," is answered — a valid, real key **was** used and it authenticated
successfully. The remaining gap (an account-scoping `teamId` this key's account requires) is a
credential-completeness finding for the milestone, not an egress or auth failure, and is out of
scope for this spike to resolve (it would require the user to provision an additional
team/tenant/owner id, which `user_setup` did not request). **Host:** 52.90.9.242, sandbox
`revenium-2-0`. **Date:** 2026-09-24. **Versions in effect:** NemoClaw `v0.0.128`, in-sandbox
OpenClaw `2026.9.1 (ad6fe23)`, revenium CLI `1.5.0 (0f5f3a7)`.

**Scope discipline:** exactly one read-only API call was made; no meter transaction was submitted;
no tick/cron script in this repo references `REVENIUM_API_KEY` as a result of this spike.

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
- NemoClaw-sandbox agentId is also `main`; in-sandbox SQLite store resolves under
  `/sandbox/.openclaw/agents/main/agent/openclaw-agent.sqlite` — surfaced host-side at the share
  mount point (e.g. `~/nemoclaw-revenium-2-0-mount/agents/main/agent/openclaw-agent.sqlite`).
- Sandbox name used: `revenium-2-0`. Share mount point: `~/nemoclaw-<sandbox>-mount`.
- Credential file: `/home/ubuntu/.spike-17.env` (mode 600; `ANTHROPIC_API_KEY`, `NVIDIA_API_KEY`,
  `REVENIUM_API_KEY`) — spike-scoped, delete at teardown; future phases should use their own file
  and pass it via `CREDENTIAL_ENV_FILE` (the script no longer hardcodes the filename).
- NemoClaw's non-pinned "latest" install resolution is NOT the newest tag — use
  `NEMOCLAW_INSTALL_TAG=v<X>` to pin to a specific release when the maintained-lkg default lands
  below a required floor (Finding 4).
- NemoClaw v0.0.128's policy subcommands are `policy add` / `policy list` / `policy remove` /
  `policy get` (space-separated) — the hyphenated `policy-add`/`policy-list` from CONVENTIONS.md
  (written against v0.0.55) are no longer recognized (Finding 5).
- A share mount surviving in `mount` output does not mean it is live after a sandbox rebuild —
  verify with a real filesystem access, not just mount-table presence (Finding 6).
