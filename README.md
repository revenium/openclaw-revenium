# Revenium OpenClaw Skill

Budget enforcement and token metering for [OpenClaw](https://docs.openclaw.ai) agents using the [Revenium](https://docs.revenium.io/for-ai-agents) platform. Tracks AI spend, enforces configurable budget guardrails, and reports usage automatically — so agents never silently blow through your token budget.

## Prerequisites

- [OpenClaw](https://docs.openclaw.ai) installed and running
- `revenium` CLI on your system PATH
- `jq` installed on the host (used by the metering cron to parse session files)
- A Revenium API key, Team ID, Tenant ID, and User ID

Install the `revenium` CLI:

```bash
# macOS / Linux (Homebrew)
brew install revenium/tap/revenium

# or download from https://docs.revenium.io/for-ai-agents
```

Install `jq` if missing:

```bash
# Ubuntu/Debian
sudo apt-get install -y jq

# macOS
brew install jq
```

## Installation

### 1. Clone and install the skill

```bash
git clone <this-repo> revenium-openclaw
cd revenium-openclaw
mkdir -p ~/.openclaw/skills/revenium
cp SKILL.md ~/.openclaw/skills/revenium/SKILL.md
cp -r scripts ~/.openclaw/skills/revenium/scripts
```

### 2. Configure sandbox access

OpenClaw agents run in a sandbox that cannot read `~/.openclaw/skills/` by default. Without this step, the agent will ask for Exec approval every time it tries to read the skill file.

Add a read-only bind mount to the `agents.defaults.sandbox.docker.binds` array in `~/.openclaw/openclaw.json`:

```bash
nano ~/.openclaw/openclaw.json
```

Find the `binds` array inside `agents.defaults.sandbox.docker` and add the skills mount:

```json
"docker": {
  "binds": [
    "/home/you/.openclaw/skills:/workspace/skills:ro",
    ...existing binds...
  ]
}
```

Replace `/home/you` with your home directory path.

After saving, restart the OpenClaw gateway for the change to take effect.

### 3. Verify

```bash
openclaw skills list
```

You should see `revenium` in the list. If not, confirm `revenium` is on your PATH — the skill requires it via binary gating.

### 4. Install the metering cron

A background cron job reads OpenClaw session JSONL files every minute, ships token usage to Revenium via `revenium meter completion`, and updates the local budget status file. This runs on the host, outside the sandbox.

```bash
bash ~/.openclaw/skills/revenium/scripts/install-cron.sh
```

To verify it's working:

```bash
# Run the reporter manually
bash ~/.openclaw/skills/revenium/scripts/cron.sh

# Watch the log
tail -f ~/.openclaw/revenium-metering.log
```

To uninstall the cron:

```bash
bash ~/.openclaw/skills/revenium/scripts/uninstall-cron.sh
```

## Setup

Setup happens automatically the first time the agent tries to perform an operation. The agent will:

1. Ask for your **Revenium API key**, **Team ID**, **Tenant ID**, and **User ID**
2. Optionally ask for your **organization name** (for Revenium reporting attribution)
3. Ask for a **budget threshold** (e.g., `5.00`)
4. Ask for a **budget period** (DAILY, WEEKLY, MONTHLY, or QUARTERLY)
5. Create a budget alert in Revenium and save the alert ID to `~/.openclaw/skills/revenium/config.json`

Setup is atomic — if any step fails, no partial config is written.

## How It Works

### Token Metering

A background cron job (installed in step 4 above) runs every minute and:

1. Reads OpenClaw session JSONL files from `~/.openclaw/agents/main/sessions/`
2. Extracts token usage for each assistant completion (input, output, cache read, cache write tokens)
3. Ships each event to Revenium via `revenium meter completion` with:
   - Model name and provider (derived from the model string)
   - Token counts and stop reason
   - The user's input message and the assistant's response
   - The session's system prompt
   - Organization name (if configured)
   - Agent identifier set to `OpenClaw`
   - Model source (e.g., `bedrock`) and streaming flag
4. Tracks reported events in a ledger file to avoid duplicates
5. Checks budget status and writes the result to `budget-status.json`

### Budget Enforcement

Before every turn (completions, tool calls, responses — any action that incurs AI cost), the agent reads the local `budget-status.json` file written by the cron:

- **Within budget** — proceeds silently, no interruption
- **Budget exceeded** — warns the user with current spend vs. threshold and asks for permission to continue
- **Status unavailable** — proceeds with caution (fail-open)

This avoids a network round-trip to Revenium on every turn — the cron keeps the local status file current.

### `/revenium` Command

Run `/revenium` at any time to:

- **View budget status** — current spend, threshold, percent used, remaining
- **Reconfigure** — update your API key, budget amount, or period (the old alert is deleted and a new one is created)

## Configuration

The skill stores its config at `~/.openclaw/skills/revenium/config.json`:

```json
{
  "alertId": "75BjG5",
  "organizationName": "my-org"
}
```

- `alertId` — the Revenium budget alert ID (required, created during setup)
- `organizationName` — optional, used for attribution in Revenium reporting

Your API key, Team ID, Tenant ID, and User ID are stored separately by the `revenium` CLI (at `~/.config/revenium/config.yaml`).

The cron also writes `~/.openclaw/skills/revenium/budget-status.json` with the latest budget check result — this is what the agent reads to enforce the guard.

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
