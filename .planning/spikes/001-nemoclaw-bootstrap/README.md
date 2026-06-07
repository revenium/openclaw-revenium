---
spike: 001
name: nemoclaw-bootstrap
type: standard
validates: "Given a clean host, when NemoClaw install.sh runs, then NemoClaw + OpenShell come up and an OpenClaw agent completes one turn"
verdict: INVALIDATED
related: []
tags: [infra, install, nemoclaw, openshell]
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

**Verdict: INVALIDATED (on this host).** This machine cannot host a NemoClaw bootstrap.

Probe output on this host:
```
Host: Darwin arm64
Operating system   ✗ macOS — UNSUPPORTED by NemoClaw (Linux-only stack)
Docker             ⚠ installed but daemon not reachable
RAM                ✓ 64 GB
Free disk ($HOME)  ✓ 161 GB
NVIDIA GPU         ⚠ no nvidia-smi
Node.js            ✓ v23.9.0
Summary: 3 pass, 2 warn, 1 fail
VERDICT: INCOMPATIBLE
```

**Why this matters / impact on remaining spikes:** The idea itself (a parallel install path for
NemoClaw/OpenShell) is NOT invalidated — only the *spike target* is. Spikes 002–005 all require
a live NemoClaw/OpenShell sandbox, which fundamentally needs a **Linux host with Docker**
(ideally with an NVIDIA GPU for the GPU-passthrough path). They are **blocked** until such a
host is provisioned.

**Surprise:** The installer's macOS handling is graceful-skip, not hard-fail — so a naive "run
install.sh on my Mac" would *appear* to partially succeed (Node bootstrap, repo clone) while
silently never provisioning the sandbox. That false-positive is itself a documentation hazard
worth noting for the real build's install path.

**Reusable fact captured:** NemoClaw config dir = `~/.nemoclaw/` (analog of `~/.openclaw/`).
