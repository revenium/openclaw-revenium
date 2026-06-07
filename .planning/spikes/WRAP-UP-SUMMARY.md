# Spike Wrap-Up Summary

**Date:** 2026-06-07
**Spikes processed:** 5
**Feature areas:** install-and-bootstrap, sandbox-egress-policies, revenium-cli-and-metering, skill-deploy-and-enforcement
**Skill output:** `./.claude/skills/spike-findings-openclaw-revenium/`

## Processed Spikes

| # | Name | Type | Verdict | Feature Area |
|---|------|------|---------|--------------|
| 001 | nemoclaw-bootstrap | standard | VALIDATED (Linux) / INVALIDATED (macOS) | install-and-bootstrap |
| 002 | openshell-egress | standard | VALIDATED | sandbox-egress-policies |
| 003 | revenium-cli-in-sandbox | standard | PARTIAL | revenium-cli-and-metering |
| 004 | background-metering-loop | standard | VALIDATED | revenium-cli-and-metering |
| 005 | skill-discovery-and-directives | standard | PARTIAL | skill-deploy-and-enforcement |

## Key Findings

**Feasibility: YES.** Optional NemoClaw/OpenShell support is feasible as a parallel install path,
validated end-to-end on a live Linux host (NemoClaw + OpenShell sandbox + OpenClaw agent turn via
Nemotron cloud inference).

- **Bootstrap (001):** Linux+Docker only (macOS unsupported — refuse explicitly). Fully
  non-interactive install via env vars; run detached (`setsid </dev/null`) to dodge an apt
  job-control hang; ~11 min. Config `~/.nemoclaw/`; in-sandbox `/sandbox/.openclaw/`.
- **Egress (002):** Deny-by-default proxy (`10.200.0.1:3128`). Revenium API blocked by default;
  opened with a host-scoped custom `policy-add` preset (hot-reload, no rebuild). Kill-shot cleared.
- **CLI (003):** No Linux brew bottle → deliver the prebuilt tarball binary; auth via `REVENIUM_*`;
  TLS via `SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem`. Binary+TLS+egress proven (server 403 on
  dummy key); authenticated meter pending a real Revenium key.
- **Metering loop (004):** Run host-side over `nemoclaw share mount` (SSHFS) + host cron — NOT
  per-tick `exec` (synchronous, slow, hang-prone) and NOT an in-sandbox cron (none exists). Host-side
  metering needs no sandbox egress policy. Verified recurring ticks refresh `guardrail-status.json`.
- **Skill/enforcement (005):** `nemoclaw skill install` gives clean discovery (`✓ ready`) but NOT
  per-turn enforcement — SKILL.md is on-demand, AGENTS.md isn't auto-read, the `<nemoclaw-runtime>`
  preamble isn't extensible. The directive needs an **OpenClaw plugin hook** (the one unproven piece).

## Open items / follow-ups

1. **Close spike 003** — run an authenticated `revenium meter` call in-sandbox with a real key → VALIDATED.
2. **Spike the plugin injection (005)** — prove a `before_agent_finalize`-style OpenClaw plugin
   delivers the guardrail directive every turn. This is the main unproven mechanism before the build.

## Live environment (left running)

Host `34.224.27.67`, sandbox `revenium-spike` (NemoClaw v0.0.55, OpenShell 0.0.44, OpenClaw v2026.5.22),
inference Nemotron via NVIDIA cloud. Active egress policies include the custom `revenium` +
`revenium-cli-install` presets. SSHFS mount at `~/sbx-openclaw` (the every-minute test cron was removed).
