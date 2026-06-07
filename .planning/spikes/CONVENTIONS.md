# Spike Conventions

Patterns and facts established across the NemoClaw/OpenShell support spikes. New spikes follow
these unless the question requires otherwise.

## Target environment

- **NemoClaw is Linux + Docker only** (macOS unsupported — spike 001). Min ~8 GB RAM (add swap if
  below) and ~20 GB disk. NVIDIA GPU optional (`nvidia-ctk` for passthrough); without one,
  inference is routed to NVIDIA cloud.
- **Spike host:** `34.224.27.67` (Ubuntu 26.04, x86_64, no GPU). SSH: `ssh -i ~/.ssh/agent-sandbox.pem ubuntu@34.224.27.67`.
- **Sandbox:** `revenium-spike` (OpenShell 0.0.44, docker backend; container `openshell-revenium-spike-<uuid>`). Agent: OpenClaw v2026.5.22. Inference: `nvidia/nemotron-3-super-120b-a12b` via `https://integrate.api.nvidia.com`.

## Stack layering

- **OpenShell** = hardened sandbox agents run *inside* (the analog of the skill's current Docker sandbox).
- **NemoClaw** = orchestration/security layer (CLI `nemoclaw`, config `~/.nemoclaw/`) that deploys + supervises agents in OpenShell. Agents: OpenClaw (default) / Hermes.

## Install (non-interactive, validated — spike 001)

```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | \
  NEMOCLAW_NON_INTERACTIVE=1 NEMOCLAW_NON_INTERACTIVE_SUDO_MODE=prompt \
  NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 NEMOCLAW_PROVIDER=build \
  NEMOCLAW_SANDBOX_NAME=<name> NEMOCLAW_POLICY_MODE=suggested \
  NVIDIA_API_KEY=nvapi-... bash
```
- A fresh login is required between the Docker-group add and onboarding; run detached with
  `setsid … </dev/null` to dodge an apt SIGTTIN hang under tmux+tee.
- Verify: `nemoclaw <name> status`; one turn: `nemoclaw <name> exec -- openclaw agent --message "…" --session-id x --json`.

## Paths

| What | Path |
|------|------|
| NemoClaw config (host) | `~/.nemoclaw/` |
| NemoClaw CLI (host) | `~/.local/bin/nemoclaw` (export PATH) |
| Preset YAMLs (host) | `~/.nemoclaw/source/nemoclaw-blueprint/policies/presets/` |
| OpenClaw config/state (in-sandbox) | `/sandbox/.openclaw/` (HOME=`/sandbox`, user `sandbox`) |
| Skills (in-sandbox) | `/sandbox/.openclaw/skills/<name>/` |
| Sandbox TLS trust store | `/etc/openshell-tls/ca-bundle.pem` |
| Egress proxy (in-sandbox) | `10.200.0.1:3128` (env in `/etc/profile.d/nemoclaw-proxy.sh`) |

## CLI primitives (the build leans on these, not bespoke hacks)

- `nemoclaw <name> exec [--timeout s] -- <cmd>` — one-shot in-sandbox command. **Synchronous; high
  per-call latency (full OpenClaw plugin re-init each call); hang-prone — do NOT use for a polling loop.**
  No newlines in args (gRPC rejects them) — keep commands single-line.
- `nemoclaw <name> skill install <path>` — deploys a SKILL.md dir to the sandbox. Does NOT run the
  skill's `post-install.sh` (no AGENTS.md injection, no cron, no status seed).
- `nemoclaw <name> policy-add --from-file <yaml> [--yes|--dry-run]` — add a network/filesystem policy
  preset. Hot-reloads (version bump, no rebuild).
- `nemoclaw <name> share mount <sbx-path> <local>` — SSHFS-mount sandbox FS on host (needs `sshfs`).
  Bidirectional, instant. **The preferred host↔sandbox state channel.**

## Egress policy (spike 002)

- Egress is deny-by-default through the proxy; default `suggested` allowlist = `brew, huggingface,
  npm, openclaw-pricing, pypi` (note: brew preset also reaches github.com).
- **Revenium API (`api.revenium.ai`) is NOT allowed by default** — ship + apply a custom preset
  (`.planning/spikes/002-openshell-egress/revenium-policy.yaml`). Installing the CLI via brew also
  needs `release-assets.githubusercontent.com` (github release CDN) — see `003-.../gh-release-policy.yaml`.
- Custom preset schema: `preset:{name,description}` + `network_policies:<key>:{name,endpoints:[{host,port,access,tls}],binaries:[{path}]}`. `tls: skip` = L4 CONNECT passthrough (use for HTTPS clients / Node undici).

## revenium CLI in-sandbox (spike 003)

- No Linux brew bottle → `brew install` falls back to source build (needs gcc). **Fetch the release
  tarball directly** (`revenium-cli_<v>_linux_amd64.tar.gz`) and install the binary to `/sandbox/.local/bin`.
- Auth via `REVENIUM_API_KEY` (+ team/tenant/owner) env or `~/.config/revenium/config.yaml`. Set
  `SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem`. Default API `https://api.revenium.ai/profitstream`.

## Metering loop (spike 004)

- Run **host-side**: host cron + `share mount` of `/sandbox/.openclaw`; read OpenClaw session logs
  from the mount, meter with the **host** revenium CLI (open egress), write `guardrail-status.json`
  back through the mount (instantly visible to the agent). NOT per-tick `exec`, NOT in-sandbox cron
  (none exists). `sshfs` is a host prerequisite.

## Per-turn directive injection (spike 005 — OPEN)

- SKILL.md is on-demand; a dropped AGENTS.md is not auto-read in-sandbox; NemoClaw's per-turn
  `<nemoclaw-runtime>` preamble (`nemoclaw/src/runtime-context.ts`) is not file/config-extensible.
  The viable seam for the MANDATORY guardrail directive is an **OpenClaw plugin hook**
  (e.g. `before_agent_finalize`) — the nemoclaw plugin already runs every turn.

## Operational hazards

- Repeated `exec` calls that hold streams accumulate as hung host `node … exec` processes — guard
  with timeouts; the gateway itself stayed healthy through a pile-up.
- `pkill -f "<pattern>"` self-matches the kill command's own cmdline over SSH (drops the session,
  exit 255) — kill by PID via a `ps | grep | awk | xargs kill` pipeline that filters on `node` instead.
