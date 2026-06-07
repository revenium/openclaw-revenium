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
- The parallel install path MUST ship + apply a `revenium` network-policy preset (`api.revenium.ai`) via `nemoclaw <name> policy-add --from-file` (validated in spike 002 — `.planning/spikes/002-openshell-egress/revenium-policy.yaml`). Policy hot-reloads, no rebuild.
- Sandbox TLS trust store is `/etc/openshell-tls/ca-bundle.pem` — likely `SSL_CERT_FILE` target for the revenium CLI inside the sandbox.
- `nemoclaw <name> skill install <path>` deploys to `/sandbox/.openclaw/skills/<name>/` and the agent lists it `✓ ready` — BUT it does NOT run the skill's `post-install.sh`, so the per-turn guardrail directive, `guardrail-status.json` seed, and metering cron are all absent. The parallel install path must perform those separately.
- Per-turn directive injection: SKILL.md is on-demand, AGENTS.md is not auto-read in-sandbox, and NemoClaw's `<nemoclaw-runtime>` preamble (src `nemoclaw/src/runtime-context.ts`) is not file/config-extensible. The viable injection seam is an **OpenClaw plugin hook** (e.g. `before_agent_finalize`), since the nemoclaw plugin already runs every turn.
- Metering loop runs **host-side** against `nemoclaw <name> share mount /sandbox/.openclaw` (SSHFS), NOT via per-tick `nemoclaw exec` (synchronous, slow, hang-prone) and NOT as an in-sandbox cron (none exists). `sshfs` is a host prerequisite. Host-side metering means metering egress needs no sandbox policy (host has open egress).
- Operational hazard: repeated `nemoclaw exec` calls that hold streams accumulate as hung host processes — any tooling that shells into the sandbox repeatedly needs a guard/timeout.
- Per-turn directive injection IS achievable via an OpenClaw plugin `before_prompt_build` hook returning `{ prependContext }` (proven by the nemoclaw plugin reaching every turn). The plugin must be installed cleanly (`openclaw plugins install` → trusted/provenance; untrusted plugins load but hooks are inert), manifest needs `configSchema`, package.json needs `openclaw.extensions`. A hand-stubbed plugin hung the turn — author from `openclaw plugins init`/mirror the nemoclaw plugin, validate via the gateway path. (spike 006)

## Spikes

| # | Name | Type | Validates | Verdict | Tags |
|---|------|------|-----------|---------|------|
| 001 | nemoclaw-bootstrap | standard | Given a clean host, when NemoClaw `install.sh` runs, then NemoClaw + OpenShell come up and an OpenClaw agent completes one turn | **VALIDATED** (Linux host 34.224.27.67; agent turn completed via Nemotron). INVALIDATED on macOS. | infra, install, nemoclaw, openshell |
| 002 | openshell-egress | standard | Given an agent in an OpenShell sandbox, when it calls the Revenium API over HTTPS, then egress succeeds (default policy or documented allowance) | **VALIDATED** (blocked by default; opened via host-scoped `policy-add`, no rebuild) | network, egress, openshell, metering |
| 003 | revenium-cli-in-sandbox | standard | Given the revenium binary + state dir + REVENIUM_* env in the OpenShell sandbox, when `revenium config show` + a meter call run inside, then the CLI is authenticated and meters | **PARTIAL** (binary+TLS+egress proven, server responds 403 on dummy key; authenticated meter pending a real key) | sandbox, cli, credentials, bind-mount, tls |
| 004 | background-metering-loop | standard | Given NemoClaw always-on lifecycle + OpenShell process limits, when the per-minute metering job runs, then guardrail-status.json stays current without tripping limits | **VALIDATED** (via host cron + `share mount`; per-tick `exec` model rejected as fragile) | cron, lifecycle, process-limits, share-mount |
| 006 | plugin-directive-injection | standard | Given a custom OpenClaw plugin in the sandbox, when any agent turn runs, then a mandatory per-turn directive (guardrail check) reaches the agent context every turn | **PARTIAL** (mechanism proven viable — nemoclaw's `before_prompt_build`→`prependContext` reaches every turn; hand-rolled replica hung the turn → author from `openclaw plugins init`) | plugin, directives, enforcement, hook, before_prompt_build |
| 005 | skill-discovery-and-directives | standard | Given the revenium skill in NemoClaw's skills dir, when an agent turn runs, then the guardrail/marker directives reach agent context (else AGENTS.md-equivalent needed) | **PARTIAL** (discovery via `skill install` works; per-turn directive does NOT reach context — needs a plugin hook, not skill install/AGENTS.md) | skill-loading, directives, agents-md, plugin |
