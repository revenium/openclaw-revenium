---
spike: 001
name: nemoclaw-bootstrap
type: standard
validates: "Given a clean host, when NemoClaw install.sh runs, then NemoClaw + OpenShell come up and an OpenClaw agent completes one turn"
verdict: VALIDATED
related: []
tags: [infra, install, nemoclaw, openshell]
host: "34.224.27.67 (Ubuntu 26.04 LTS, x86_64, no GPU)"
---

# Spike 001: NemoClaw Bootstrap

## What This Validates

Given a clean host, when NemoClaw's `install.sh` runs, then NemoClaw + OpenShell come up and
an OpenClaw agent completes one turn. This is the foundational gate — every later spike
(egress, CLI-in-sandbox, metering loop, skill discovery) needs a running NemoClaw/OpenShell
sandbox to test against.

## Research

Sources:
- [NVIDIA/NemoClaw repo](https://github.com/NVIDIA/NemoClaw)
- [NemoClaw Prerequisites (docs)](https://docs.nvidia.com/nemoclaw/get-started/prerequisites)
- [Second Talent install guide](https://www.secondtalent.com/resources/how-to-install-nvidia-nemoclaw/)
- `scripts/install.sh` (raw, read directly)

**What NemoClaw is.** An open-source reference stack for running *always-on* AI agents more
safely inside **NVIDIA OpenShell** sandboxes. It provides CLI management, hardened deployment
blueprints, routed inference, network policies, and lifecycle controls. Two agents: **OpenClaw**
(default) and **Hermes** (`NEMOCLAW_AGENT=hermes` / `nemohermes` alias). CLI: `nemoclaw`.

**Stack layering (resolves the "are they the same?" question):**
- **OpenShell** = the hardened sandbox agents run *inside* — the analog of the Revenium skill's current Docker sandbox.
- **NemoClaw** = the orchestration/security layer that deploys and supervises agents inside OpenShell.
- They are complementary layers of one stack, not two agents and not the same thing.

**Documented requirements:**

| Requirement | Value |
|-------------|-------|
| OS | **Linux only** — no macOS; Windows via WSL2 only |
| Runtime | Docker (installer manages docker group + systemd on Linux) |
| RAM | >= 8 GB (OOM-killer risk below; >= 8 GB swap mitigates) |
| Disk | >= 20 GB free |
| GPU (optional) | NVIDIA GPU passthrough via `sudo nvidia-ctk runtime configure --runtime=docker` |
| Config dir | **`~/.nemoclaw/`** (config, session state, backups) |

**OS gating found in `scripts/install.sh` (read directly):**
```
case "$(uname -s)" in
  Darwin | MINGW* | MSYS*) return 0 ;;   # skips Docker setup, does not error
esac
...
if [[ "$(uname -s)" != "Linux" ]]; then return 0; fi   # Linux-only npm fix
```
The installer does **not hard-error** on macOS — it *skips* the Docker/systemd/NVIDIA-CDI steps.
But skipping those steps means no OpenShell sandbox runtime is provisioned, so the agent stack
never actually comes up. Combined with the docs' explicit "Linux only" statement, macOS is a
dead end for a real bootstrap.

## How to Run

```bash
bash .planning/spikes/001-nemoclaw-bootstrap/probe-host-compat.sh
```

Non-destructive: checks the host against NemoClaw's documented requirements and the real OS
gating. Installs nothing, no sudo, no system mutation. (A system-mutating NVIDIA installer that
sudo-installs Docker and edits user groups is deliberately NOT run on the user's work laptop.)

## What to Expect

A per-requirement pass/warn/fail table and a one-line VERDICT. On a macOS host: OS = FAIL →
`VERDICT: INCOMPATIBLE`, exit 1.

## Investigation Trail

1. Tried to read NemoClaw docs prerequisites/quickstart at guessed `/latest/.../*.html` URLs → all 404.
2. Web search surfaced the authoritative requirement: **"NemoClaw is Linux only, with no macOS or Windows support."** Plus 8 GB RAM / 20 GB disk / Docker / optional `nvidia-ctk` GPU passthrough.
3. Read `scripts/install.sh` raw to confirm OS gating empirically. Found the installer *skips* (not errors) on Darwin/Windows — a softer gate than expected, but it means the sandbox runtime simply isn't set up off-Linux.
4. Discovered config dir is `~/.nemoclaw/` — the analog of `~/.openclaw/`. Reusable for spikes 003/004/005.
5. Built a non-destructive `probe-host-compat.sh` and ran it on this host.

## Results

**Verdict: VALIDATED on a Linux host (`34.224.27.67`, Ubuntu 26.04, x86_64, no GPU).**
INVALIDATED on macOS (the original probe target — kept below as a documented constraint).

### macOS attempt (INVALIDATED — expected)
```
Host: Darwin arm64
Operating system   ✗ macOS — UNSUPPORTED by NemoClaw (Linux-only stack)
Docker             ⚠ installed but daemon not reachable
Summary: 3 pass, 2 warn, 1 fail → VERDICT: INCOMPATIBLE
```
The installer graceful-skips on Darwin (no hard error) — a naive "run it on my Mac" would
*appear* to partially succeed while never provisioning the sandbox. Documentation hazard for
the real install path: **detect + refuse off-Linux explicitly.**

### Linux host (VALIDATED — full stack up, agent turn completed)
Provisioned Ubuntu 26.04 host. Sequence that worked (all non-interactive):
1. Added 8 GB swap (host had 7.7 GB RAM; NemoClaw warns <8 GB → OOM risk).
2. Ran the bootstrap **fully non-interactively** via env vars (see "Non-interactive install" below).
3. Installer: added swap-safe Docker (29.5.3) → added user to `docker` group → Node 22 (nvm) →
   NemoClaw CLI v0.0.55 → configured Nemotron inference → built the OpenShell sandbox image
   (80-step Docker build) → sandbox `revenium-spike` reached **Phase: Ready**. Total ~656s (~11 min).
4. Ran one agent turn through the Gateway:
   ```
   nemoclaw revenium-spike exec --timeout 170 -- \
     openclaw agent --message "Reply with exactly: SPIKE001_OK" --session-id spike001 --json
   ```
   Result: `finalAssistantVisibleText: "SPIKE001_OK"`, `winnerModel: nvidia/nemotron-3-super-120b-a12b`,
   `result: success`, `fallbackUsed: false`. **A real end-to-end turn completed.**

### Non-interactive install recipe (validated)
```bash
curl -fsSL https://www.nvidia.com/nemoclaw.sh | \
  NEMOCLAW_NON_INTERACTIVE=1 \
  NEMOCLAW_NON_INTERACTIVE_SUDO_MODE=prompt \
  NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 \
  NEMOCLAW_PROVIDER=build \              # build = NVIDIA cloud (alias: cloud)
  NEMOCLAW_SANDBOX_NAME=revenium-spike \
  NEMOCLAW_POLICY_MODE=suggested \
  NVIDIA_API_KEY=nvapi-... \            # skips the credential prompt
  bash
```
Gotcha: a **fresh login session** is required between the Docker-group add and the rest of
onboarding (`newgrp docker` / re-run). Running the installer detached with `setsid … </dev/null`
(no controlling tty) avoids an apt SIGTTIN job-control hang seen under `tmux`+`tee`.

### Reusable facts captured (critical for the parallel install path + spikes 002–005)

**Host-side config/CLI:**
- NemoClaw config dir: `~/.nemoclaw/`; CLI: `nemoclaw` (PATH: `~/.local/bin`).
- The sandbox is a Docker container `openshell-<name>-<uuid>`; OpenShell 0.0.44 (docker backend).

**CLI primitives that map directly onto the remaining spikes:**
- `nemoclaw <name> exec [--timeout s] -- <cmd>` — run a command non-interactively in the sandbox (→ 003, agent turns).
- `nemoclaw <name> skill install <path>` — official **skill deploy into the sandbox** (→ 005).
- `nemoclaw <name> policy-add | policy-remove | policy-list [--from-file|--from-dir]` — network/filesystem egress policy presets (→ 002).
- `nemoclaw <name> hosts-add <host> <ip>` — sandbox `/etc/hosts` alias.
- `nemoclaw <name> share mount <sbx-path> <local>` — mount sandbox FS on the host.
- `nemoclaw <name> gateway-token` / `dashboard-url` — gateway auth.

**Inside the sandbox:**
- OpenClaw config/state: `/sandbox/.openclaw/` and `/sandbox/.nemoclaw/`; OpenClaw runs as a plugin (`openclaw plugins enable nemoclaw`).
- One agent turn: `openclaw agent --message "…" --session-id <id> [--json]` (routes via Gateway → inference.local → Nemotron).
- Egress goes through a **managed proxy at `10.200.0.1:3128`** (env in `/etc/profile.d/nemoclaw-proxy.sh`).

**Egress allowlist (default `suggested` policy) — directly seeds spike 002:**
`npm, pypi, huggingface, brew, openclaw-pricing`. **The Revenium API host is NOT in this list**,
so outbound metering calls will be blocked by default and require a custom `policy-add`.

**Impact:** The idea (parallel install path) is strongly de-risked — NemoClaw exposes first-class
`skill install`, `policy-add`, and `exec` primitives, so the parallel path can be built on
supported CLI rather than hacks. Spikes 002–005 are unblocked on this host.
