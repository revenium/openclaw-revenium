---
name: spike-findings-openclaw-revenium
description: Implementation blueprint from spike experiments for adding optional NemoClaw/OpenShell support to the Revenium OpenClaw skill, and for live-host verification of OpenClaw 2.0 session storage, plugin hooks, and command-dispatch behavior. Requirements, proven patterns, and verified knowledge. Auto-load during NemoClaw/OpenShell implementation work.
---

<context>
## Project: openclaw-revenium

Adding **optional NemoClaw / OpenShell support** to the Revenium OpenClaw skill via a **parallel
install path** — deploying the budget-guardrail + metering skill into an OpenClaw agent running
under NemoClaw inside an OpenShell hardened sandbox, without disturbing the existing standalone
OpenClaw + Docker path. NemoClaw = orchestration/security layer (CLI `nemoclaw`); OpenShell = the
sandbox agents run inside.

Also covers **live-host fact-finding for the v2.0 OpenClaw cut-over** — verifying, on a real
`>=2026.8.1` host, how the skill must read completions/toolCalls from 2.0's SQLite session store,
which plugin hooks fire per pairing, and whether `command-dispatch: tool` can make marker-writing
dispatch deterministic.

Spike session (v1.4, NemoClaw/OpenShell): wrapped 2026-06-07. Validated live on Ubuntu host
34.224.27.67 (sandbox `revenium-spike`).

Spike session (v2.0, live-host 2.0 facts): wrapped 2026-09-24. Validated live on Ubuntu host
52.90.9.242 (standalone OpenClaw 2026.9.6 + Docker, and NemoClaw v0.0.128 sandbox `revenium-2-0`).
</context>

<requirements>
## Requirements (non-negotiable — every reference honors these)

- Parallel install path only — the existing standalone OpenClaw + Docker path must remain untouched.
- Target host must be **Linux + Docker** (macOS unsupported); detect + refuse off-Linux explicitly
  (NemoClaw's installer graceful-skips on Darwin → false success).
- Build on NemoClaw's first-class CLI primitives (`skill install`, `policy-add`, `share mount`, `exec`), not bespoke docker hacks.
- Inside the sandbox, OpenClaw config/state is `/sandbox/.openclaw/` (not `~/.openclaw/`).
- Ship + apply a custom `revenium` egress policy (`api.revenium.ai`) — not allowed by default.
- Metering runs **host-side** over a `share mount`, not per-tick `exec` and not an in-sandbox cron.
- The per-turn guardrail directive needs an **OpenClaw plugin hook** — `skill install`/AGENTS.md do not deliver it.
</requirements>

<findings_index>
## Feature Areas

| Area | Reference | Key Finding |
|------|-----------|-------------|
| Install & bootstrap | references/install-and-bootstrap.md | Linux-only; non-interactive env-var install; run detached to avoid apt SIGTTIN; ~11 min |
| Sandbox egress policies | references/sandbox-egress-policies.md | Deny-by-default proxy; ship + `policy-add` a host-scoped `revenium` preset for `api.revenium.ai` |
| Revenium CLI & metering | references/revenium-cli-and-metering.md | No Linux brew bottle → tarball install; `SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem`; loop host-side via `share mount`, NOT per-tick `exec` |
| Skill deploy & enforcement | references/skill-deploy-and-enforcement.md | `skill install` gives discovery only; per-turn directive needs a plugin `before_prompt_build` hook — mechanism proven (spike 006), author from `openclaw plugins init` |
| Live-host OpenClaw 2.0 facts | references/live-host-2-0-facts.md | Direct read-only SQLite wins the session-read fidelity ranking; all six hooks confirmed only on standalone+Claude; `command-dispatch: tool` does NOT achieve deterministic dispatch — both-pairings coverage is UNMET, re-verify before Phase 19/22 relies on it |

## Spike verdicts

| # | Spike | Verdict |
|---|-------|---------|
| 001 | nemoclaw-bootstrap | VALIDATED (Linux) / INVALIDATED (macOS) |
| 002 | openshell-egress | VALIDATED |
| 003 | revenium-cli-in-sandbox | VALIDATED |
| 004 | background-metering-loop | VALIDATED |
| 005 | skill-discovery-and-directives | PARTIAL (directive injection needs a plugin) |
| 006 | plugin-directive-injection | PARTIAL (plugin `before_prompt_build` mechanism proven viable; author from official scaffold) |
| 007 | live-2-0-host-provisioning | VALIDATED (both production paths live on 52.90.9.242; tracer turn read back from 2.0 SQLite store; egress preset confirmed with a real key) |
| 008 | sqlite-session-read-path | PARTIAL (direct SQLite read wins the fidelity tie-break; both-pairings provenance bar UNMET — sandbox unreachable) |
| 009 | hook-firing-matrix-2-0 | PARTIAL (all six hooks fired live on standalone/Claude; sandbox pairing entirely UNRUN, B-05 unanswered) |
| 010 | command-dispatch-tool-verdict | INVALIDATED (NO — mechanism inapplicable to this call shape; ATTR-01 moved to Future Requirements, Phase 21 deleted) |
| 011 | read-path-concurrency-soak | PARTIAL (HOST-LOCAL: 62-tick zero-lock-error PASS; SSHFS cell required but UNRUN, NEMO-03 unanswered) |

## Source Files

Original spike source files (probe, policy YAMLs, tick scripts, READMEs) preserved in `sources/`.
</findings_index>

<metadata>
## Processed Spikes

- 001-nemoclaw-bootstrap
- 002-openshell-egress
- 003-revenium-cli-in-sandbox
- 004-background-metering-loop
- 005-skill-discovery-and-directives
- 006-plugin-directive-injection
- 007-live-2-0-host-provisioning
- 008-sqlite-session-read-path
- 009-hook-firing-matrix-2-0
- 010-command-dispatch-tool-verdict
- 011-read-path-concurrency-soak
</metadata>
