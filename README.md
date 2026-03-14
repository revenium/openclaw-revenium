# Revenium OpenClaw Skill

Budget enforcement for OpenClaw agents using the [Revenium](https://docs.revenium.io/for-ai-agents) platform. The agent checks token spend against your configured budget before every operation and warns when thresholds are exceeded.

## Prerequisites

- [OpenClaw](https://docs.openclaw.ai) installed and running
- `revenium` CLI on your system PATH ([install guide](https://docs.revenium.io/for-ai-agents))
- A Revenium API key

## Installation

### 1. Install the skill

Copy the skill to your OpenClaw managed skills directory:

```bash
mkdir -p ~/.openclaw/skills/revenium
cp SKILL.md ~/.openclaw/skills/revenium/SKILL.md
```

### 2. Configure sandbox access

OpenClaw agents run in a sandbox that cannot read `~/.openclaw/skills/` by default. Add a read-only bind mount to your OpenClaw config so the agent can access the skill without repeated Exec approvals:

```yaml
agents.defaults.sandbox.docker.binds: ["/Users/<you>/.openclaw/skills:/workspace/skills:ro"]
```

Replace `/Users/<you>` with your home directory path.

### 3. Verify

```bash
openclaw skills list
```

You should see `revenium` in the list. If not, confirm `revenium` is on your PATH — the skill requires it via binary gating.

## Setup

Setup happens automatically the first time the agent tries to perform an operation. The agent will:

1. Ask for your **Revenium API key**
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
rm -rf ~/.openclaw/skills/revenium
```

Optionally clean up your Revenium budget alert:

```bash
revenium alerts budget list
revenium alerts budget delete <alert-id> --yes
```
