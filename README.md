# Revenium OpenClaw Skill

Budget enforcement and token metering for [OpenClaw](https://docs.openclaw.ai) agents using the [Revenium](https://www.revenium.ai) platform. Tracks AI spend, enforces configurable budget guardrails, and reports usage automatically — so agents never silently blow through your token budget.

## Prerequisites

- [OpenClaw](https://docs.openclaw.ai) installed and running
- [ClawHub](https://docs.openclaw.ai) CLI: `npm i -g clawhub`
- [Revenium](https://app.revenium.ai/connections) API key, Team ID, Tenant ID, and User ID

## Installation

### 1. Install the skill from ClawHub

```bash
clawhub install --force --dir ~/.openclaw/skills revenium
```

> **About the VirusTotal warning:** ClawHub may display a warning that this skill is "flagged as suspicious by VirusTotal Code Insight." This is a false positive — the skill calls the Revenium API via the `revenium` CLI and handles API keys during setup, which triggers VirusTotal's heuristic detection for "external APIs" and "crypto keys." The skill is open source and safe to install. The `--force` flag bypasses this warning.

### 2. Run post-install setup

ClawHub does not run post-install scripts, so run the setup script to install any missing prerequisites and configure OpenClaw sandbox access:

```bash
bash ~/.openclaw/skills/revenium/scripts/post-install.sh
```

This will:

1. Check for and install the `revenium` CLI and `jq` via Homebrew (if missing)
2. Verify `python3` is available
3. Mark the skill's scripts as executable
4. Configure Docker sandbox bind mounts in `~/.openclaw/openclaw.json` — mounts `~/.openclaw` (rw), bin directories containing `revenium` and `jq` (ro) with shared library dirs, `~/.config/revenium` (ro) for CLI credentials, and sets `PATH`, `HOME`, `LD_LIBRARY_PATH`, and `SSL_CERT_FILE` in the container environment
5. Enable `autoAllowSkills` in `~/.openclaw/exec-approvals.json` so skill-declared binaries are auto-approved
6. Seed an initial `budget-status.json` so the agent doesn't error before the cron's first run
7. Inject a mandatory budget check section into `AGENTS.md` so budget enforcement is always in context
8. Verify the installation

> **Already have prerequisites installed?** Pass `--skip-prereqs` to skip Homebrew installs and fail immediately if anything is missing.

### 3. Restart the OpenClaw gateway

Restart the gateway for sandbox changes to take effect.

### 4. Verify

```bash
openclaw skills list
```

You should see `revenium` in the list. If not, confirm `revenium` is on your PATH — the skill requires it via binary gating.

### First-time setup (automatic)

The metering cron and budget alert are configured automatically when you first interact with the agent after installing the skill. The agent will walk you through providing your Revenium credentials and configuring your budget — no manual script execution needed.

To verify the cron is running after setup:

```bash
tail -f ~/.openclaw/revenium-metering.log
```

To manually manage the cron:

```bash
# Reinstall
bash ~/.openclaw/skills/revenium/scripts/install-cron.sh

# Uninstall
bash ~/.openclaw/skills/revenium/scripts/uninstall-cron.sh
```

## Setup

Setup happens automatically the first time the agent tries to perform an operation. The agent will:

1. Ask for your **Revenium API key**, **Team ID**, **Tenant ID**, and **User ID**
2. Optionally ask for your **organization name** (for Revenium reporting attribution)
3. Ask for a **budget threshold** (e.g., `5.00`)
4. Ask for a **budget period** (DAILY, WEEKLY, MONTHLY, or QUARTERLY)
5. Optionally configure **autonomous mode** with halt-on-exceed and notifications (Slack, Discord, Telegram, etc.)
6. Create a budget alert in Revenium and save the alert ID to `~/.openclaw/skills/revenium/config.json`
7. Install the background metering cron (runs every minute)

Setup is atomic — if any step fails, no partial config is written.

## How It Works

### Token Metering

A background cron job runs every minute and:

1. **Reports usage** (`report.sh`) — reads OpenClaw session JSONL files, extracts token usage for each assistant completion, and ships events to Revenium via `revenium meter completion` with:
   - Model name and provider (derived from the model string)
   - Token counts (input, output, cache read, cache write, total from the API)
   - Operation type (`CHAT`, `TOOL_CALL`, or `GUARDRAIL`)
   - Trace ID linking related completions within a conversation turn
   - Request timing and duration computed from JSONL timestamps
   - The user's input message, assistant response, and system prompt
   - Organization name, agent identifier (`OpenClaw`), model source, and streaming flag
2. **Checks budget** (`budget-check.sh`) — fetches the current budget alert from Revenium, computes whether spend exceeds the threshold, and writes the result to `budget-status.json`

Both scripts are bash 3.x compatible (works on macOS's default bash).

### Budget Enforcement

Before every turn (completions, tool calls, responses — any action that incurs AI cost), the agent reads the local `budget-status.json` file written by the cron:

- **Within budget** — proceeds silently, no interruption
- **Budget exceeded (interactive mode)** — warns the user with current spend vs. threshold and asks for permission to continue
- **Budget exceeded (autonomous mode)** — halts all operations and sends a notification to the configured channel
- **Status unavailable** — proceeds with caution (fail-open)

This avoids a network round-trip to Revenium on every turn — the cron keeps the local status file current.

### `/revenium` Command

Run `/revenium` at any time to:

- **View budget status** — current spend, threshold, percent used, remaining
- **Reset budget** — zero out current spend by deleting and recreating the alert (preserves all settings)
- **Reconfigure** — update your API key, budget amount, or period (the old alert is deleted and a new one is created)

## Configuration

The skill stores its config at `~/.openclaw/skills/revenium/config.json`:

```json
{
  "alertId": "75BjG5",
  "organizationName": "my-org",
  "autonomousMode": false
}
```

- `alertId` — the Revenium budget alert ID (required, created during setup)
- `organizationName` — optional, used for attribution in Revenium reporting
- `autonomousMode` — when `true`, budget exceedance halts all operations and sends notifications
- `notifyChannel` / `notifyTarget` — notification destination for autonomous mode alerts

Your API key, Team ID, Tenant ID, and User ID are stored separately by the `revenium` CLI (at `~/.config/revenium/config.yaml`).

The cron writes `~/.openclaw/skills/revenium/budget-status.json` with the latest budget check result — this is what the agent reads to enforce the guard.

## Uninstalling

```bash
bash ~/.openclaw/skills/revenium/scripts/uninstall-cron.sh
rm -rf ~/.openclaw/skills/revenium
```

Optionally clean up your Revenium budget alert:

```bash
revenium alerts budget list
revenium alerts budget delete <alert-id> --yes
```

## Support

Questions, bugs, or feature requests? Join us on [Discord](http://discord.gg/J2DbmjZ2nA).
