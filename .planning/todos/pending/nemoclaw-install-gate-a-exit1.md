---
id: nemoclaw-install-gate-a-exit1
title: "install.sh --nemoclaw exits 1 at Phase 15 Gate A (B-01/NCENF-01) on live Nemotron host"
created: 2026-06-10
source: 16-03 live validation (Re-run 3)
relates_phase: 15
severity: medium
tags: [nemoclaw, enforcement, gate-a, b-05, install-exit-code]
---

## Problem

On the live NemoClaw host (34.224.27.67, sandbox `revenium-spike`), running the
documented install path `bash install.sh --nemoclaw` completes the **skill deploy**
half successfully (SC1 proven: `✓ revenium skill confirmed ready in sandbox`,
`openclaw skills list` → `✓ ready  💰 revenium`) and, after the Phase 16 `--force`
fix, the **enforcement plugin** now installs cleanly (`Installed plugin: revenium-enforcement`).

However the **overall install still exits 1** at Phase 15's enforcement verification
**Gate A** (`scripts/post-install-nemoclaw.sh:241`, `# Gate A (B-01 / NCENF-01)`):

```
openclaw agent --json --message ping
  → Error: No target session selected. Use --agent <id>
guard directive NOT injected — could not parse currentTurn.promptChars ... Aborting.
```

This is the known **B-05 Nemotron limitation** (Nemotron routes exec via
`tool_search_code` so the enforcement marker/directive chain does not fire as
expected) that Phase 15 already renegotiated. It is **out of scope for Phase 16**
(skill-deploy + docs), which is why 16-03 was signed off with SC1+SC2 verified.

## Why it matters

A runbook where `bash install.sh --nemoclaw` returns a non-zero exit code is a poor
operator experience even though the skill itself deploys and is `✓ ready`. The
exit-1 comes entirely from the Phase 15 enforcement Gate A health-check, not from
skill deployment.

## Suggested next step

Reopen the Phase 15 Gate A / B-05 thread (see memory `b05-nemotron-tool-search-code-exec`):
observe enforcement via transcript / `tool_search_code` interception rather than the
`openclaw agent --json --message ping` promptChars probe, OR scope Gate A so it does
not fail the overall NemoClaw install when running against a Nemotron-backed sandbox.

## Evidence

`.planning/phases/16-skill-deploy-docs/16-VALIDATION.md` → `## LIVE VALIDATION` →
`### Re-run 3 (post --force fix, fully doc-driven, end-to-end exit 0)`.
