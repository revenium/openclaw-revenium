# Revenium OpenClaw Skill

Budget enforcement for OpenClaw agents using the [Revenium](https://docs.revenium.io/for-ai-agents) platform. The agent checks token spend against your configured budget before every operation and warns when thresholds are exceeded.

## Prerequisites

- [OpenClaw](https://docs.openclaw.ai) installed and running
- `revenium` CLI on your system PATH ([install guide](https://docs.revenium.io/for-ai-agents))
- A Revenium API key

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

A background cron job reads OpenClaw session JSONL files every minute and ships token usage to Revenium via `revenium meter completion`. This runs on the host, outside the sandbox.

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
2. Ask for a **budget threshold** (e.g., `5.00`)
3. Ask for a **budget period** (DAILY, WEEKLY, MONTHLY, or QUARTERLY)
4. Create a budget alert in Revenium and save the alert ID to `~/.openclaw/skills/revenium/config.json`

Setup is atomic — if any step fails, no partial config is written.

## Usage

Once configured, the agent automatically checks your budget before every operation:

- **Within budget** — proceeds silently, no interruption
- **Budget exceeded** — warns you with current spend vs. threshold and asks for permission to continue

### `/revenium` Command

Run `/revenium` at any time to:

- **View budget status** — current spend, threshold, percent used, remaining
- **Reconfigure** — update your API key, budget amount, or period (the old alert is deleted and a new one is created)

### Grace Mode (coming soon)

Choose between:
- **Warn-and-ask** (default) — agent warns and asks permission when budget is exceeded
- **Hard stop** — agent refuses to continue when budget is exceeded

## Configuration

The skill stores a single config file at `~/.openclaw/skills/revenium/config.json`:

```json
{
  "alertId": "75BjG5"
}
```

Your API key is stored separately by the `revenium` CLI (via `revenium config set key`).

## Uninstalling

```bash
bash scripts/uninstall-cron.sh
rm -rf ~/.openclaw/skills/revenium
```

Optionally clean up your Revenium budget alert:

```bash
revenium alerts budget list
revenium alerts budget delete <alert-id> --yes
```
