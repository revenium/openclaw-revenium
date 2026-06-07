# Install & Bootstrap (NemoClaw + OpenShell)

## Requirements

- **Parallel install path only** — never disturb the existing standalone OpenClaw + Docker path.
- Target host MUST be **Linux + Docker**. macOS is unsupported; the parallel path must detect and
  **refuse off-Linux explicitly** (NemoClaw's own installer graceful-skips on Darwin, which falsely
  looks like success while never provisioning the sandbox).

## How to Build It

1. **Preflight the host** (reuse `sources/001-nemoclaw-bootstrap/probe-host-compat.sh`): Linux, Docker
   (installer-recoverable on Linux), ≥8 GB RAM (else add swap), ≥20 GB disk, optional NVIDIA GPU.
2. **Add swap if RAM <8 GB** (NemoClaw OOM-kills below 8 GB):
   ```bash
   sudo fallocate -l 8G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
   ```
3. **Non-interactive install** (validated):
   ```bash
   curl -fsSL https://www.nvidia.com/nemoclaw.sh | \
     NEMOCLAW_NON_INTERACTIVE=1 NEMOCLAW_NON_INTERACTIVE_SUDO_MODE=prompt \
     NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1 NEMOCLAW_PROVIDER=build \
     NEMOCLAW_SANDBOX_NAME=<name> NEMOCLAW_POLICY_MODE=suggested \
     NVIDIA_API_KEY=nvapi-... bash
   ```
   `NEMOCLAW_PROVIDER=build` = NVIDIA cloud (Nemotron). `NVIDIA_API_KEY` skips the credential prompt.
4. **Verify:** `nemoclaw <name> status` (Phase: Ready, Inference: healthy); one turn:
   `nemoclaw <name> exec -- openclaw agent --message "ping" --session-id x --json`.

## What to Avoid

- **Running the installer under `tmux`+`tee`** — apt gets SIGTTIN-stopped (job-control). Run detached:
  `setsid … </dev/null >log 2>&1` (no controlling tty → apt reads clean EOF).
- **Assuming the install completes in one shot** — the Docker-group add needs a fresh login before
  onboarding continues. Re-run the installer from a new session (a fresh SSH session already carries
  the `docker` group); detached `setsid` from that session inherits it.
- **Trusting a vanity URL blindly** — the verifiable bootstrap is `raw.githubusercontent.com/NVIDIA/NemoClaw/main/install.sh`; read it before piping to bash.

## Constraints

- ~11 min first install (80-step OpenShell image build). No GPU → inference is cloud-routed (needs `NVIDIA_API_KEY`).
- Host config: `~/.nemoclaw/`; CLI on `~/.local/bin` (export PATH). Sandbox is a docker container `openshell-<name>-<uuid>`.

## Origin

Synthesized from spike: 001. Sources: `sources/001-nemoclaw-bootstrap/`.
