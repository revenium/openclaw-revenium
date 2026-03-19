---
name: revenium
description: "Mandatory Revenium budget enforcement for every agent operation. Checks token spend against your configured budget before each tool call, warns when thresholds are exceeded, and handles first-time setup and reconfiguration."
metadata: {"openclaw":{"emoji":"💰","version":"0.1.0","homepage":"https://docs.revenium.io/for-ai-agents","requires":{"bins":["revenium"],"anyBins":["jq"]},"user-invocable":true,"install":[{"kind":"brew","formula":"revenium/tap/revenium","bins":["revenium"]},{"kind":"brew","formula":"jq","bins":["jq"]}]}}
---

## Path Resolution

All file paths in this skill use `~/.openclaw/skills/revenium/` as the skill directory. When using file tools (read, write, edit), pass paths with `~/` — the tool resolves `~` to `$HOME` automatically. When running shell commands via exec/bash, use the explicit `$HOME/.openclaw/skills/revenium/` form so the shell expands `$HOME` correctly.

## Operation Guard

**MANDATORY — DO NOT SKIP THIS SECTION. EVER.**

BEFORE performing ANY action that incurs AI cost — including responding to the user, generating completions, executing tool calls, or any other LLM operation — you MUST check the Revenium budget. This is not optional. This is not a suggestion. You MUST do this every single time, for every turn, no exceptions. If the budget is exceeded, you MUST NOT generate a response or call any tools until the user grants permission.

### Budget Check Procedure

The budget status is maintained by a background cron job that checks Revenium every minute and writes the result to `~/.openclaw/skills/revenium/budget-status.json`. You read this local file — do NOT call the Revenium API directly.

1. **Read budget status.** Read the file `~/.openclaw/skills/revenium/budget-status.json`. If it does not exist, the cron has not run yet — tell the user "Budget status not yet available. The metering cron may not be installed. Run `bash ~/.openclaw/skills/revenium/scripts/install-cron.sh` to set it up." Then proceed with the operation.

2. **Parse the status.** Extract these fields from the JSON:
   - `currentValue` — current spend in the budget period
   - `threshold` — the budget limit
   - `percentUsed` — percentage of budget consumed
   - `exceeded` — boolean, whether the budget has been exceeded
   - `lastChecked` — when the cron last updated this file

3. **Evaluate the result:**

   **If `exceeded` is false (budget OK):** Proceed silently. Do NOT mention the budget to the user.

   **If `exceeded` is true (budget blown):** Read `autonomousMode` from `~/.openclaw/skills/revenium/config.json`.

   **If `autonomousMode` is `false` or absent (default — interactive mode):**

   You MUST STOP. Do NOT execute any operation, do NOT generate a response. Tell the user:

   > "Your Revenium budget has been exceeded. You have spent $CURRENT_VALUE of your $THRESHOLD budget (PERCENT_USED%). Last checked: LAST_CHECKED. Would you like to continue anyway?"

   Replace the values with the actual numbers from the file.

   - **If the user says yes / continue / approved:** Proceed with the operation.
   - **If the user says no / stop / cancel:** STOP. Do NOT execute the operation. Tell the user: "Operation cancelled. Run `/revenium` to adjust your budget."

   **If `autonomousMode` is `true`:**

   Check the `halted` field in `~/.openclaw/skills/revenium/budget-status.json`.

   - **If `halted` is `true`:** You MUST STOP immediately. Do NOT execute any operation, do NOT generate any response beyond this message:

     > "Budget enforcement halt is active. $CURRENT_VALUE of $THRESHOLD budget used (PERCENT_USED%). A notification has been sent to your configured channel. To resume, run: `bash ~/.openclaw/skills/revenium/scripts/clear-halt.sh`"

     Replace the values with the actual numbers from the file. Do NOT proceed under any circumstances until `halted` is `false`.

   - **If `halted` is `false` but `exceeded` is `true`:** The user has explicitly cleared the halt — this is an approval to proceed. Continue with the operation.

### If budget-status.json is missing or unreadable

- Tell the user: "Budget status unavailable. Proceeding with caution."
- Proceed with the operation — fail open, do not block the user.

## Setup

At the start of any operation, check: does `~/.openclaw/skills/revenium/config.json` exist?

- **If YES** and the user has NOT requested reconfiguration: setup is complete. Proceed to the Operation Guard section. Do NOT re-run setup.
- **If NO**: you MUST run the Setup Flow below before proceeding. Do NOT execute any operations until setup is complete.

### Setup Flow

Follow these steps in order. If any step fails, STOP. Do NOT write `config.json`. Do NOT proceed with operations.

1. **Check for existing API key.** Run:
   ```
   revenium config show
   ```
   If the output shows an API Key is already set (not empty), skip to step 3. The key is already configured.

2. **If no API key is configured:** Collect the following from the user. Ask for each value and wait for their response:

   - **API Key**: "Please provide your Revenium API key."
   - **Team ID**: "Please provide your Revenium Team ID."
   - **Tenant ID**: "Please provide your Revenium Tenant ID."
   - **User ID**: "Please provide your Revenium User ID."

   Then configure the CLI by running each command in order:
   ```
   revenium config set key API_KEY
   revenium config set team-id TEAM_ID
   revenium config set tenant-id TENANT_ID
   revenium config set user-id USER_ID
   ```
   Replace the placeholder values with the user's actual responses. If any command returns a non-zero exit code: tell the user what went wrong, tell them to run `/revenium` when ready, and STOP. Do NOT write `config.json`.

3. **Prompt for organization name (optional).** Ask the user: "What is your organization name for Revenium reporting? (optional — press Enter to skip)" If the user provides a value, call it `ORG_NAME`. If they skip, leave it empty.

4. **Prompt for budget amount.** Ask the user: "What budget threshold would you like to set? (numeric amount, e.g., 5.00)" Wait for the user's response. Call this value `AMOUNT`.

5. **Prompt for budget period.** Ask the user: "Which budget period would you like?" and present these four options:
   - DAILY
   - WEEKLY
   - MONTHLY
   - QUARTERLY

   Wait for the user's selection. Call this value `PERIOD`.

6. **Prompt for autonomous mode.** Ask the user: "Will this agent run autonomously (without a user present)? If yes, budget exceedance will halt all operations and notify you. (yes/no, default: no)"

   - **If yes:** Set `AUTONOMOUS_MODE` to `true`. Then:
     - Ask: "Which OpenClaw channel should receive budget alerts?" Present supported types: `slack`, `discord`, `telegram`, `whatsapp`, `signal`, `googlechat`, `msteams`, `mattermost`, `imessage`
     - Wait for the user's selection. Call this value `NOTIFY_CHANNEL`.
     - Ask: "What is the notification target on that channel?" Explain that the format varies by channel:
       - Slack: `user:<id>` or `channel:<id>`
       - Discord: `user:<id>` or `channel:<id>`
       - Telegram: chat id or `@username`
       - WhatsApp: E.164 phone number
       - Signal: `+E.164` or `group:<id>`
       - Teams: conversation id
     - Wait for the user's response. Call this value `NOTIFY_TARGET`.
   - **If no (default):** Set `AUTONOMOUS_MODE` to `false`. Skip notification channel prompts.

7. **Generate the alert name.** Set `ALERT_NAME` to `"OpenClaw {Period} Budget"` where `{Period}` is the title-cased version of the selected period:
   - DAILY -> "OpenClaw Daily Budget"
   - WEEKLY -> "OpenClaw Weekly Budget"
   - MONTHLY -> "OpenClaw Monthly Budget"
   - QUARTERLY -> "OpenClaw Quarterly Budget"

   Do NOT ask the user for a name. This is automatic.

9. **Delete any existing budget alerts.** Before creating a new alert, you MUST check for and remove pre-existing OpenClaw budget alerts to prevent duplicates. Run:
   ```
   revenium alerts budget list --json
   ```
   Parse the JSON output and look for any alerts whose name starts with `"OpenClaw "`. For EACH matching alert, delete it:
   ```
   revenium alerts budget delete EXISTING_ALERT_ID --yes
   ```
   If the list command fails or returns no results, that is fine — proceed to the next step. If a delete fails, log a warning but continue.

10. **Create the budget alert.** Run:
   ```
   revenium alerts budget create --name "ALERT_NAME" --threshold AMOUNT --period PERIOD --json
   ```
   If the exit code is non-zero: tell the user what went wrong, tell them to run `/revenium` when ready, and STOP. Do NOT write `config.json`.

11. **Extract the alert ID.** From the JSON response, extract the `"id"` field. This is a short alphanumeric string (e.g., `"75BjG5"`). Call this value `ALERT_ID`.

   **CRITICAL:** Do NOT use `anomalyId` from `budget get` responses — that is an integer and will cause HTTP 400 errors when passed to `budget get`. The correct value is the string `"id"` from the `budget create` response.

   To extract reliably, pipe the create output through:
   ```
   python3 -c "import json,sys; d=json.load(sys.stdin); print(d['id'])"
   ```

12. **Write config.json.** This MUST be the FINAL step — only write after ALL previous steps have succeeded. Write `~/.openclaw/skills/revenium/config.json` with pretty-printed JSON containing the alert ID, optional organization name, and autonomous mode settings:
   ```
   python3 -c "
   import json
   config = {'alertId': 'ALERT_ID'}
   org = 'ORG_NAME'
   if org:
       config['organizationName'] = org
   autonomous = AUTONOMOUS_MODE  # True or False
   config['autonomousMode'] = autonomous
   if autonomous:
       config['notifyChannel'] = 'NOTIFY_CHANNEL'
       config['notifyTarget'] = 'NOTIFY_TARGET'
   print(json.dumps(config, indent=2))
   " > ~/.openclaw/skills/revenium/config.json
   ```
   Replace `ALERT_ID`, `ORG_NAME`, `AUTONOMOUS_MODE`, `NOTIFY_CHANNEL`, and `NOTIFY_TARGET` with the actual values. If the user skipped the organization name, omit it. If autonomous mode is false, omit `notifyChannel` and `notifyTarget`.

13. **Install the metering cron.** Run:
   ```
   bash ~/.openclaw/skills/revenium/scripts/install-cron.sh
   ```
   This registers a background job that ships token usage to Revenium every minute and keeps the local budget status file current. If the cron is already installed, this is a no-op.

14. **Confirm to the user.** Tell the user setup is complete. Show: the alert name, the threshold amount, the period, the organization name (if provided), and autonomous mode status (including notification channel and target if configured).

### Error Handling

On ANY failure during the Setup Flow: report what went wrong, tell the user to run `/revenium` when they are ready to try again, and STOP. Do NOT retry. Do NOT write a partial `config.json`. The absence of `config.json` is the signal that setup has not completed.

## `/revenium` Command

When the user invokes `/revenium`:

### If Setup Is Complete (config.json exists)

1. **Show budget status.** Read `alertId` from `~/.openclaw/skills/revenium/config.json`, then run:
   ```
   revenium alerts budget get ALERT_ID --json
   ```
   Display the current spend versus threshold to the user (current value, threshold, percent used, remaining).

2. **Show autonomous mode status.** Read `~/.openclaw/skills/revenium/config.json` and display:
   - **Autonomous mode:** enabled or disabled
   - **Notification channel:** the configured channel type and target (if autonomous mode is enabled), or "not configured"
   - **Halt status:** Read `~/.openclaw/skills/revenium/budget-status.json` and check the `halted` field. Display "ACTIVE (since HALTED_AT)" if `halted` is `true`, or "inactive" if `halted` is `false` or absent.
   - If halt is active, also show: "To resume operations, run: `bash ~/.openclaw/skills/revenium/scripts/clear-halt.sh`"

3. **Offer reconfiguration.** Ask the user: "Would you like to update your budget configuration?" If the user declines, STOP — no further action.

### If Setup Is NOT Complete (no config.json)

Run the Setup Flow from the Setup section above.

### Reconfiguration Flow

When the user requests reconfiguration:

1. **Read existing alert ID.** Read `alertId` from `~/.openclaw/skills/revenium/config.json`. Call this value `OLD_ALERT_ID`.

2. **Delete the old alert.** Run:
   ```
   revenium alerts budget delete OLD_ALERT_ID --yes
   ```
   If this fails (e.g., alert already deleted or not found): log a warning but continue. The goal is to prevent orphaned alerts.

3. **Delete config.json.** Remove `~/.openclaw/skills/revenium/config.json`.

4. **Run the full Setup Flow** from the Setup section above. This collects fresh API key, budget amount, period, and creates a new alert from scratch.

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