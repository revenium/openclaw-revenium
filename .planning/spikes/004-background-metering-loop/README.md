---
spike: 004
name: background-metering-loop
type: standard
validates: "Given NemoClaw always-on lifecycle + OpenShell process limits, when the per-minute metering job runs, then guardrail-status.json stays current without tripping limits"
verdict: VALIDATED
related: [001, 002, 003, 005]
tags: [cron, lifecycle, process-limits, share-mount, architecture]
host: "34.224.27.67 (sandbox revenium-spike)"
---

# Spike 004: Background Metering Loop

## What This Validates

Can a recurring metering job keep `guardrail-status.json` current for the in-sandbox agent,
without tripping OpenShell process limits? The existing skill runs a host crontab (`*/N`) that
meters OpenClaw session logs and refreshes the status file. Under NemoClaw, OpenClaw runs *inside*
the sandbox, so the question is where/how the loop runs.

## Research / two candidate models

1. **In-sandbox daemon** — run a loop/cron inside the sandbox container.
2. **Per-tick `nemoclaw exec`** — host cron calls `nemoclaw <name> exec -- <meter one-shot>` each tick.
3. **Host share-mount** — `nemoclaw <name> share mount` exposes the sandbox FS on the host via
   SSHFS; a host cron reads OpenClaw session logs and writes `guardrail-status.json` back through
   the mount, metering via the host's revenium CLI (host has unrestricted egress).

## How to Run

```bash
# Mount the sandbox openclaw dir on the host (one-time):
sudo apt-get install -y sshfs
nemoclaw revenium-spike share mount /sandbox/.openclaw ~/sbx-openclaw

# Host cron tick writes the status file through the mount (no exec):
#   * * * * * /tmp/revenium-mount-tick.sh     (script in this spike dir)
# Verify it stays fresh:
cat ~/sbx-openclaw/skills/revenium/guardrail-status.json
nemoclaw revenium-spike exec -- cat /sandbox/.openclaw/skills/revenium/guardrail-status.json
```

## What to Expect

The status file's `_tick`/`updatedAt` advance every minute, and an in-sandbox read returns the
identical content the host wrote.

## Investigation Trail

1. Confirmed the host is a normal Linux box with a working `crontab` (the scheduler exists host-side).
2. **In-sandbox scheduling primitives are absent:** `crontab`/`cron`/`crond`/`systemctl`/`atd` are all missing inside the sandbox; `ulimit -u` isn't even supported (busybox `sh`). So an in-sandbox cron is not available out of the box.
3. **Tried launching an in-sandbox detached loop via `exec`** (`setsid … &`). Two problems surfaced:
   - `nemoclaw exec` is **synchronous** — it holds the gRPC stream open until its `--timeout` even when the payload is backgrounded, so it's a poor way to spawn a daemon.
   - My nested-quoted heartbeat never actually started (the `pgrep -fc` "matches" were false self-matches), and worse: **repeated `exec` calls that held streams piled up as hung host-side processes** (10+ stuck `node … exec` procs). The gateway stayed healthy, but this is a real fragility.
   - Per-call latency is high: every `exec` re-initialises the full OpenClaw plugin stack (prints the NemoClaw plugin banner each time). A per-minute cron of these is heavy and hang-prone.
4. **Pivoted to the share-mount model.** Installed `sshfs`; `nemoclaw revenium-spike share mount /sandbox/.openclaw ~/sbx-openclaw` succeeded ("changes appear in the sandbox instantly").
5. Wrote `guardrail-status.json` from the host **through the mount** (no exec). A single in-sandbox `exec` read returned the **identical** content → host writes are instantly visible to the agent.
6. Installed a host crontab (`* * * * * /tmp/revenium-mount-tick.sh`) writing the status via the mount. Observed recurring ticks:
   ```
   2026-06-07T15:01:56Z tick=1 rc=0   (manual seed)
   2026-06-07T15:02:01Z tick=2 rc=0   (cron)
   2026-06-07T15:03:01Z tick=3 rc=0   (cron)
   status: {"halted":false,"warned":false,"updatedAt":...,"_tick":3,"_via":"host-mount-cron"}
   ```
7. Removed the every-minute cron after capturing evidence (left the host tidy).

## Results

**Verdict: VALIDATED — the recurring metering loop is feasible, via the host share-mount model.**
A host crontab refreshes `guardrail-status.json` through an SSHFS mount of `/sandbox/.openclaw`,
and the in-sandbox agent reads the host-written file instantly. No in-sandbox daemon, no
OpenShell process-limit concerns, no per-tick plugin re-init.

**Architectural finding (the main output of this spike):**
- ✅ **Recommended:** host cron + `nemoclaw share mount`. The host reads OpenClaw session logs from
  `~/sbx-openclaw/...` and meters with the **host** revenium CLI — which means **metering egress
  needs no sandbox network policy at all** (only the in-sandbox agent's own calls would; the
  spike-002 policy is still needed if anything inside the sandbox calls Revenium directly).
- ⚠️ **Avoid:** per-tick `nemoclaw exec` for metering. It's synchronous, slow (full plugin
  re-init/tick), and hang-prone (streams accumulate as zombie host procs). Fine for occasional
  one-shots, wrong for a per-minute loop.
- ⚠️ **In-sandbox daemon** would require baking a supervised process into the image via
  `nemoclaw onboard --from <Dockerfile>` (no in-sandbox cron exists). Heavier; only needed if
  metering must run without a host-side agent.

**Requirements for the build:**
- The NemoClaw parallel install path should run the metering loop **host-side** against a
  `share mount` of `/sandbox/.openclaw`, not via `exec` and not as an in-sandbox cron.
- `sshfs` is a host prerequisite for the mount (apt/dnf) — add to the install path's preflight.
- The loop owns seeding + refreshing `guardrail-status.json` at `<mount>/skills/revenium/` (spike
  005 showed `skill install` does not create it).

**Surprises / carry-forward:**
- The mount is bidirectional and instant — an elegant host↔sandbox state channel that also solves
  spike 005's directive problem partially (the host can write files the agent reads), though NOT
  the per-turn injection (that still needs a plugin — see 005).
- `exec` stream/zombie accumulation is a real operational hazard worth a guard in any tooling that
  shells into the sandbox repeatedly.
