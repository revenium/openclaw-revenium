---
name: revenium
description: "Mandatory Revenium budget enforcement for every agent operation. Checks token spend against your configured budget before each tool call, warns when thresholds are exceeded, and handles first-time setup and reconfiguration."
metadata: {"openclaw":{"emoji":"💰","version":"0.1.0","homepage":"https://docs.revenium.io/for-ai-agents","requires":{"bins":["revenium"]},"user-invocable":true}}
---

## Operation Guard

BEFORE executing any tool call, you MUST check the Revenium budget.

[Phase 3 will fill this section with the full budget check flow, warn-and-ask logic, and hard-stop mode.]

## Setup

When no configuration exists at `{baseDir}/config.json`, you MUST run the setup flow before any operation.

[Phase 2 will fill this section with API key configuration, budget alert creation, and anomaly ID persistence.]

## `/revenium` Command

When the user invokes `/revenium`:
- If setup is complete: show current budget status, then offer to reconfigure
- If setup is not complete: run setup flow

[Phase 2 will fill this section with the full slash command behavior.]

## Troubleshooting

### Binary Not Found

If `revenium` is not found on PATH:
- STOP all operations that require budget checking
- Tell the user: "The `revenium` CLI is not installed or not on your PATH. Install it from https://docs.revenium.io/for-ai-agents and ensure it is available in your shell."

### API Key Invalid

If `revenium config show` reports no API key or an invalid key:
- STOP all operations that require budget checking
- Tell the user: "Your Revenium API key is missing or invalid. Run `/revenium` to reconfigure."

### Network Errors

If any `revenium` CLI command fails due to network issues:
- Tell the user: "Unable to reach the Revenium API. Check your network connection and try again."
- Do NOT proceed with the operation until budget status is confirmed.
