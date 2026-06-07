# Spike Manifest

## Idea

Add **optional NemoClaw / OpenShell support** to the Revenium OpenClaw skill. Today the skill
is tightly coupled to a standalone OpenClaw + Docker sandbox install (`~/.openclaw/`,
`~/.openclaw/openclaw.json` `agents.defaults.sandbox.docker`, `openclaw gateway restart`,
ClawHub install). NemoClaw is NVIDIA's orchestration/security stack that runs *always-on*
agents (OpenClaw default, or Hermes) inside **OpenShell** hardened sandboxes (capability drops,
process limits, network policies). The goal is a **parallel install path** that deploys the same
budget-guardrail + metering skill into an OpenClaw agent running under NemoClaw/OpenShell —
without disturbing the existing standalone OpenClaw path.

## Stack relationship (established during research)

- **OpenShell** = the hardened sandbox agents run *inside* (NVIDIA). Analog of the current Docker sandbox.
- **NemoClaw** = orchestration/security stack running always-on agents inside OpenShell. Agents: OpenClaw (default) + Hermes (`nemohermes`, `NEMOCLAW_AGENT=hermes`).
- CLI: `nemoclaw` / `nemohermes`. Install via `install.sh` / `uninstall.sh`. Skills dir: `./skills/`, `.agents/skills/`.

## Requirements

_(Design decisions that emerge from spiking. Non-negotiable for the real build. Updated as spikes progress.)_

- Parallel install path only — the existing standalone OpenClaw + Docker path must remain untouched.
- NemoClaw target host must be **Linux + Docker** (macOS unsupported — confirmed spike 001). GPU passthrough needs an NVIDIA GPU + `nvidia-ctk`.
- NemoClaw config dir is **`~/.nemoclaw/`** (analog of `~/.openclaw/`) — the parallel install path keys off this.
- Install path must NOT silently no-op on macOS: NemoClaw's own `install.sh` graceful-skips off-Linux, which would falsely appear to succeed. The Revenium parallel path should detect + refuse off-Linux explicitly.
- The parallel path should build on NemoClaw's first-class CLI primitives — `nemoclaw <name> skill install <path>`, `policy-add`, `exec` — not bespoke docker hacks.
- Inside the sandbox, OpenClaw config/state lives at `/sandbox/.openclaw/` (NOT `~/.openclaw/`); skills deploy via `nemoclaw skill install`. Egress is forced through a managed proxy `10.200.0.1:3128`.
- Default `suggested` egress allowlist = npm, pypi, huggingface, brew, openclaw-pricing. **Revenium API egress is not allowed by default** — the install path must add a custom network policy for the Revenium API host.

## Spikes

| # | Name | Type | Validates | Verdict | Tags |
|---|------|------|-----------|---------|------|
| 001 | nemoclaw-bootstrap | standard | Given a clean host, when NemoClaw `install.sh` runs, then NemoClaw + OpenShell come up and an OpenClaw agent completes one turn | **VALIDATED** (Linux host 34.224.27.67; agent turn completed via Nemotron). INVALIDATED on macOS. | infra, install, nemoclaw, openshell |
| 002 | openshell-egress | standard | Given an agent in an OpenShell sandbox, when it calls the Revenium API over HTTPS, then egress succeeds (default policy or documented allowance) | PENDING | network, egress, openshell, metering |
| 003 | revenium-cli-in-sandbox | standard | Given the revenium binary + state dir + REVENIUM_* env in the OpenShell sandbox, when `revenium config show` + a meter call run inside, then the CLI is authenticated and meters | PENDING | sandbox, cli, credentials, bind-mount |
| 004 | background-metering-loop | standard | Given NemoClaw always-on lifecycle + OpenShell process limits, when the per-minute metering job runs, then guardrail-status.json stays current without tripping limits | PENDING | cron, lifecycle, process-limits |
| 005 | skill-discovery-and-directives | standard | Given the revenium skill in NemoClaw's skills dir, when an agent turn runs, then the guardrail/marker directives reach agent context (else AGENTS.md-equivalent needed) | PENDING | skill-loading, directives, agents-md |
