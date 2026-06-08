# Revenium CLI & Metering Loop

## Requirements

- Inside the sandbox, OpenClaw config/state is `/sandbox/.openclaw/` (NOT `~/.openclaw/`); HOME=`/sandbox`, user `sandbox`.
- The metering loop must keep `guardrail-status.json` current for the in-sandbox agent.

## How to Build It

### CLI delivery + auth (spike 003)
- **Do NOT `brew install` the CLI in-sandbox** — there's no Linux bottle, so brew falls back to a
  source build needing gcc. Instead fetch the prebuilt release tarball:
  ```bash
  curl -fsSL -o rev.tgz https://github.com/revenium/revenium-cli/releases/download/v<ver>/revenium-cli_<ver>_linux_amd64.tar.gz
  tar xzf rev.tgz && install -m755 ./revenium <bindir>/revenium
  ```
- Auth: `REVENIUM_API_KEY` (+ `team-id/tenant-id/owner-id`) via env or `~/.config/revenium/config.yaml`.
  **In the config file the API-key field is `api-key:`, NOT `key:`** — `config set key <v>` persists it
  as `api-key:`; a hand-written `key:` line is silently ignored (`config show` → "API Key: (not set)").
  HOME=`/sandbox`, so the file is `/sandbox/.config/revenium/config.yaml` (mode 600).
- A meter **success** returns the created resource object (`{"id":...,"resourceType":"metered-event",
  "signature":...}`), **not** a `{"status":200}` envelope — classify on the resource shape, not status:2xx.
- **TLS:** set `SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem` for any in-sandbox CLI call.
- Verified: binary runs, `config show` works, and with `SSL_CERT_FILE` set the CLI reaches
  `api.revenium.ai` (a dummy key returns server-side `{"status":403}` — full integration proven;
  an authenticated meter call was not run for lack of a real key).

### Metering loop — run it HOST-SIDE via share mount (spike 004, recommended)
```bash
sudo apt-get install -y sshfs
nemoclaw <name> share mount /sandbox/.openclaw ~/sbx-openclaw   # SSHFS, bidirectional, instant
# host crontab (every minute) runs a tick that:
#   - reads OpenClaw session logs from ~/sbx-openclaw/...
#   - meters via the HOST revenium CLI (host has open egress — no sandbox policy needed)
#   - writes guardrail-status.json back to ~/sbx-openclaw/skills/revenium/  (agent reads it instantly)
```
See `sources/004-background-metering-loop/revenium-mount-tick.sh`. Verified: host writes appear
in-sandbox identically and a 1-min cron refreshes the status file across ticks.

## What to Avoid

- **Per-tick `nemoclaw exec` for the loop** — `exec` is synchronous, re-inits the full OpenClaw
  plugin stack every call (slow), and hangs/accumulates as zombie host `node … exec` processes. Fine
  for occasional one-shots; wrong for a per-minute loop. (`sources/004/revenium-tick.sh` is the
  rejected exec-based variant, kept as a landmine.)
- **In-sandbox cron** — none of `crontab/cron/crond/systemctl/atd` exist in the sandbox; an in-sandbox
  daemon would have to be baked into the image via `nemoclaw onboard --from <Dockerfile>`.
- **Newlines in `exec` args** — gRPC rejects them; keep `exec -- sh -lc "..."` payloads single-line.
- **`pkill -f "<pattern>"` over SSH** — self-matches its own cmdline and drops the session (exit 255).
  Kill by PID via `ps | grep | grep node | awk '{print $1}' | xargs kill`.

## Constraints

- `sshfs` is a host prerequisite for the mount. `/sandbox/.openclaw` is a persistent shared volume
  (cross-exec writes persist; host-mount writes are instantly visible to the agent).
- The gateway stayed healthy through an exec pile-up, but guard repeated exec calls with timeouts.

## Origin

Synthesized from spikes: 003, 004. Sources: `sources/003-revenium-cli-in-sandbox/`, `sources/004-background-metering-loop/`.
