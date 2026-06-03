# Revenium OpenClaw Skill

Budget enforcement and token metering for [OpenClaw](https://docs.openclaw.ai) agents using the [Revenium](https://www.revenium.ai) platform. Tracks AI spend, enforces configurable Revenium guardrail rules, and reports usage automatically — so agents never silently blow through your token budget.

## Prerequisites

- [OpenClaw](https://docs.openclaw.ai) installed and running
- [ClawHub](https://docs.openclaw.ai) CLI: `npm i -g clawhub`
- [Revenium](https://app.revenium.ai/connections) API key, Team ID, Tenant ID, and Owner ID

## Installation

### 1. Install the skill from ClawHub

```bash
clawhub install --force --dir ~/.openclaw/skills revenium
```

> **About the VirusTotal warning:** ClawHub may display a warning that this skill is "flagged as suspicious by VirusTotal Code Insight." This is a false positive — the skill calls the Revenium API via the `revenium` CLI and handles API keys during setup, which triggers VirusTotal's heuristic detection for "external APIs" and "crypto keys." The skill is open source and safe to install. The `--force` flag bypasses this warning.

> Installing for local development or testing from this Git repo instead of ClawHub? See [Installing from the GitHub repo](#installing-from-the-github-repo-local-development) below.

### 2. Set Revenium credentials on the host

Set your credentials in the host terminal **before** running post-install, so they get injected into the sandbox:

```bash
revenium config set key <API_KEY>
revenium config set team-id <TEAM_ID>
revenium config set tenant-id <TENANT_ID>
revenium config set owner-id <OWNER_ID>
revenium config show          # confirm the values are set
```

The `revenium` CLI stores these at `~/.config/revenium/config.yaml`.

> **Credentials reach the sandbox as a snapshot, not live.** OpenClaw's sandbox hard-blocks mounting credential paths (anything under `~/.config`), so the skill cannot bind-mount your `revenium` config into the container. Instead, post-install reads your host credentials and injects them as `REVENIUM_*` environment variables into the sandbox. This means **any time you set or rotate credentials, you must re-run post-install and restart the gateway** (steps 3–4) to refresh them. Setting `revenium config set` from inside an agent session has no effect on the sandbox.

### 3. Run post-install setup

ClawHub does not run post-install scripts, so run the setup script to install any missing prerequisites and configure OpenClaw sandbox access:

```bash
bash ~/.openclaw/skills/revenium/scripts/post-install.sh
```

This will:

1. Check for and install the `revenium` CLI and `jq` via Homebrew (if missing), and verify `python3` is available
2. Mark the skill's scripts as executable
3. Configure the Docker sandbox under `agents.defaults.sandbox.docker` in `~/.openclaw/openclaw.json`:
   - Bind-mounts `~/.openclaw` (rw — skills, sessions, logs, `guardrail-status.json`) and the Homebrew `bin`/`lib` directories containing `revenium` and `jq` (ro)
   - Sets `PATH`, `HOME`, `LD_LIBRARY_PATH`, and `SSL_CERT_FILE` in the container environment
   - Injects `REVENIUM_API_KEY` / `REVENIUM_API_URL` / `REVENIUM_TEAM_ID` / `REVENIUM_TENANT_ID` / `REVENIUM_OWNER_ID` from your host config (so the CLI inside the sandbox is authenticated **without** mounting `~/.config`)
   - Sets `dangerouslyAllowExternalBindSources: true` — required so the gateway accepts the `~/.openclaw` and Homebrew binds, which live outside the sandbox's default `~/.openclaw/workspace` root. It does **not** mount any credential path; those remain hard-blocked by OpenClaw regardless of this flag.
4. Enable `autoAllowSkills` in `~/.openclaw/exec-approvals.json` so skill-declared binaries are auto-approved
5. Seed an initial `guardrail-status.json` so the agent doesn't error before the cron's first run
6. Seed an initial `config.json` (prompts interactively for `autonomousMode`) so operators can set the halt-vs-warn behavior up front
7. Inject a mandatory guardrail check into `AGENTS.md` so enforcement is always in context
8. Deploy `BUDGET-GUARD.md` into the workspace so enforcement is injected into isolated/cron sessions too
9. Verify the installation

> **Already have prerequisites installed?** Pass `--skip-prereqs` to skip Homebrew installs and fail immediately if anything is missing.

### 4. Restart the OpenClaw gateway

Restart the gateway so the sandbox and credential changes take effect:

```bash
openclaw gateway restart
```

### 5. Verify

```bash
openclaw skills list
```

You should see `revenium` in the list (`✓ ready`). If not, confirm `revenium` is on your PATH — the skill requires it via binary gating. Note the skill directory must be a **real directory** under `~/.openclaw/skills/` — OpenClaw refuses to load a skill whose path is a symlink resolving outside the skills root.

### First-time setup (automatic)

The metering cron and guardrail rules are configured the first time you interact with the agent after installing the skill. The agent walks you through configuring your budget and creates the guardrail rules — no manual script execution needed.

To verify the cron is running after setup:

```bash
tail -f ~/.openclaw/skills/revenium/revenium-metering.log
```

To manually manage the cron:

```bash
# Reinstall
bash ~/.openclaw/skills/revenium/scripts/install-cron.sh

# Uninstall
bash ~/.openclaw/skills/revenium/scripts/uninstall-cron.sh
```

## Installing from the GitHub repo (local development)

Use this when you want to run or test unreleased changes (e.g. a feature branch) instead of the ClawHub release. The key constraints, both enforced by OpenClaw's sandbox:

- The skill must be a **real directory** inside `~/.openclaw/skills/` — **do not symlink** a clone from elsewhere. OpenClaw rejects skills whose path resolves outside the skills root (`reason=symlink-escape`).
- Credentials are injected into the sandbox as a **snapshot** at post-install time — set them first, and re-run post-install after any change.

### 1. Clone directly into the skills directory

```bash
# Private repo: authenticate first (gh auth login, or a PAT in the URL)
git clone -b <branch> \
  https://github.com/revenium/openclaw-revenium.git ~/.openclaw/skills/revenium

cd ~/.openclaw/skills/revenium
git config core.fileMode false   # post-install chmods scripts; this stops mode
                                 # changes from dirtying the tree and blocking pulls
```

### 2. Set credentials, run post-install, restart

```bash
# Set Revenium credentials on the host FIRST (snapshot into the sandbox)
revenium config set key <API_KEY>
revenium config set team-id <TEAM_ID>
revenium config set tenant-id <TENANT_ID>
revenium config set owner-id <OWNER_ID>

bash ~/.openclaw/skills/revenium/scripts/post-install.sh
openclaw gateway restart
```

### 3. Verify it loads and the agent can run

```bash
openclaw skills list | grep revenium     # expect: ✓ ready  💰 revenium
```

### Pulling updates later

```bash
cd ~/.openclaw/skills/revenium
git pull
# Re-run post-install ONLY if the sandbox config, credentials, or AGENTS.md
# injection changed; otherwise the running skill picks up script changes directly.
bash scripts/post-install.sh   # if needed
openclaw gateway restart   # if post-install was re-run
```

> Runtime state files (`config.json`, `guardrail-status.json`, `*.log`, `*.lock`) are written into the skill directory at runtime. They are ignored by git, so they will not dirty the clone or block `git pull`.

## Setup

Setup happens automatically the first time the agent tries to perform an operation (or run `/revenium` to start it manually). The agent will:

1. Confirm your **Revenium API key**, **Team ID**, **Tenant ID**, and **Owner ID** are visible in the sandbox (set on the host, per [step 2](#2-set-revenium-credentials-on-the-host))
2. Ask for a **budget threshold** (e.g., `5.00`)
3. Ask for a **budget period** (DAILY, WEEKLY, MONTHLY, or QUARTERLY)
4. Optionally enable **shadow mode** (record breaches without enforcing) and **autonomous mode** (halt-on-exceed with notifications to Slack, Discord, Telegram, etc.)
5. Create the **Revenium guardrail rules** and save their `ruleIds` to `~/.openclaw/skills/revenium/config.json`
6. Install the background metering cron (runs every 15 minutes)

Setup is atomic — if rule creation fails, no partial `ruleIds` are written.

## How It Works

A background cron job (`cron.sh`) runs every 15 minutes and performs two stages:

### 1. Token Metering (`report.sh`)

Reads OpenClaw session JSONL files, extracts token usage for each assistant completion, and ships events to Revenium via `revenium meter completion` with:

- Model name and provider (derived from the model string)
- Token counts (input, output, cache read, cache write, total from the API)
- Operation type (`CHAT`, `TOOL_CALL`, or `GUARDRAIL`)
- Trace ID linking related completions within a conversation turn
- Request timing and duration computed from JSONL timestamps
- The user's input message, assistant response, and system prompt
- Organization name, agent identifier (`OpenClaw`), model source, and streaming flag

Wrapped in a 120s `timeout` so a hung reporter can't block the guardrail check.

### 2. Guardrail Polling (`guardrail-check.sh`)

Polls Revenium guardrail enforcement rules for the rules created during setup, computes per-rule state (`block` / `warn` / `ok`), and atomically writes `~/.openclaw/skills/revenium/guardrail-status.json`. Shadow-mode rules are recorded but excluded from the halt decision. On a new halt transition it fires a one-shot notification via `openclaw message send` (autonomous mode). Fail-open: every failure path exits cleanly so a transient API error never blocks the cron.

Both scripts are bash 3.x compatible (works on macOS's default bash).

### Budget Enforcement

Before every turn (completions, tool calls, responses — any action that incurs AI cost), the agent reads the local `guardrail-status.json` file written by the cron:

- **Within budget** (`halted` and `warned` both false) — proceeds silently, no interruption
- **Budget exceeded, interactive mode** (`warned: true`) — warns the user with the breached rule's current value vs. hard limit and asks for permission to continue before doing anything
- **Budget exceeded, autonomous mode** (`halted: true`) — halts all operations; the agent's entire response is the halt message, and a notification is sent to the configured channel
- **Status unavailable** — proceeds with caution (fail-open)

This avoids a network round-trip to Revenium on every turn — the cron keeps the local status file current. To clear an autonomous halt and resume:

```bash
bash ~/.openclaw/skills/revenium/scripts/clear-halt.sh
```

### `/revenium` Command

Run `/revenium` at any time to:

- **View guardrail status** — per-rule state, current value, hard limit, and shadow-mode flag
- **Reconfigure** — recreate the guardrail rules with a new threshold, period, or mode (existing rules are deleted and new ones created)

## Configuration

The skill stores its config at `~/.openclaw/skills/revenium/config.json`:

```json
{
  "ruleIds": ["d5jng5"],
  "organizationName": "my-org",
  "autonomousMode": false,
  "notifyChannel": "slack",
  "notifyTarget": "#ops"
}
```

- `ruleIds` — the Revenium guardrail rule IDs (created during setup; their presence is the signal that setup is complete)
- `organizationName` — optional, used for attribution in Revenium reporting
- `autonomousMode` — when `true`, budget exceedance halts all operations and sends notifications; when `false` (default), the agent warns and asks for permission
- `notifyChannel` / `notifyTarget` — notification destination for autonomous-mode halt alerts

Your API key, Team ID, Tenant ID, and Owner ID are stored separately by the `revenium` CLI (at `~/.config/revenium/config.yaml`) and injected into the sandbox as `REVENIUM_*` environment variables by post-install.

The cron writes `~/.openclaw/skills/revenium/guardrail-status.json` with the latest guardrail check result — this is what the agent reads to enforce the guard.

## Uninstalling

```bash
bash ~/.openclaw/skills/revenium/scripts/uninstall-cron.sh
rm -rf ~/.openclaw/skills/revenium
```

Optionally clean up your Revenium guardrail rules:

```bash
revenium guardrails budget-rules list
revenium guardrails budget-rules delete <rule-id> --yes
```

## Support

Questions, bugs, or feature requests? Join us on [Discord](http://discord.gg/J2DbmjZ2nA).
