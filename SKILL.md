---
name: revenium
description: "Mandatory Revenium budget enforcement for every agent operation. Checks token spend against your configured budget before each tool call, warns when thresholds are exceeded, and handles first-time setup and reconfiguration."
metadata: {"openclaw":{"emoji":"💰","version":"0.1.0","homepage":"https://docs.revenium.io/for-ai-agents","requires":{"bins":["revenium"]},"user-invocable":true}}
---

## Operation Guard

**MANDATORY — DO NOT SKIP THIS SECTION. EVER.**

BEFORE performing ANY action that incurs AI cost — including responding to the user, generating completions, executing tool calls, or any other LLM operation — you MUST check the Revenium budget. This is not optional. This is not a suggestion. You MUST do this every single time, for every turn, no exceptions. If the budget is exceeded, you MUST NOT generate a response or call any tools until the user grants permission.

### Budget Check Procedure

1. **Read the alert ID.** Read `alertId` from `{baseDir}/config.json`. If config.json does not exist, STOP and run the Setup Flow instead.

2. **Check budget status.** Run:
   ```
   revenium alerts budget get ALERT_ID --json
   ```
   Replace `ALERT_ID` with the value from config.json.

3. **Parse the response.** Extract these fields from the JSON output:
   - `currentValue` — current spend in the budget period
   - `threshold` — the budget limit
   - `percentUsed` — percentage of budget consumed
   - `exceeded` — boolean, whether the budget has been exceeded

4. **Evaluate the result:**

   **If `exceeded` is false (budget OK):** Proceed with the operation silently. Do NOT mention the budget to the user.

   **If `exceeded` is true (budget blown):** You MUST STOP. Do NOT execute the operation. Tell the user:

   > "Your Revenium budget has been exceeded. You have spent $CURRENT_VALUE of your $THRESHOLD budget (PERCENT_USED%). Would you like to continue anyway?"

   Replace the values with the actual numbers from the response.

   - **If the user says yes / continue / approved:** Proceed with the operation.
   - **If the user says no / stop / cancel:** STOP. Do NOT execute the operation. Tell the user: "Operation cancelled. Run `/revenium` to adjust your budget."

### If the budget check fails

If `revenium alerts budget get` returns a non-zero exit code (network error, invalid ID, etc.):
- Tell the user: "Unable to check budget status. Proceeding with caution."
- Proceed with the operation — fail open, do not block the user.

## Setup

At the start of any operation, check: does `{baseDir}/config.json` exist?

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

3. **Prompt for budget amount.** Ask the user: "What budget threshold would you like to set? (numeric amount, e.g., 5.00)" Wait for the user's response. Call this value `AMOUNT`.

4. **Prompt for budget period.** Ask the user: "Which budget period would you like?" and present these four options:
   - DAILY
   - WEEKLY
   - MONTHLY
   - QUARTERLY

   Wait for the user's selection. Call this value `PERIOD`.

5. **Generate the alert name.** Set `ALERT_NAME` to `"OpenClaw {Period} Budget"` where `{Period}` is the title-cased version of the selected period:
   - DAILY -> "OpenClaw Daily Budget"
   - WEEKLY -> "OpenClaw Weekly Budget"
   - MONTHLY -> "OpenClaw Monthly Budget"
   - QUARTERLY -> "OpenClaw Quarterly Budget"

   Do NOT ask the user for a name. This is automatic.

6. **Create the budget alert.** Run:
   ```
   revenium alerts budget create --name "ALERT_NAME" --threshold AMOUNT --period PERIOD --json
   ```
   If the exit code is non-zero: tell the user what went wrong, tell them to run `/revenium` when ready, and STOP. Do NOT write `config.json`.

7. **Extract the alert ID.** From the JSON response, extract the `"id"` field. This is a short alphanumeric string (e.g., `"75BjG5"`). Call this value `ALERT_ID`.

   **CRITICAL:** Do NOT use `anomalyId` from `budget get` responses — that is an integer and will cause HTTP 400 errors when passed to `budget get`. The correct value is the string `"id"` from the `budget create` response.

   To extract reliably, pipe the create output through:
   ```
   python3 -c "import json,sys; d=json.load(sys.stdin); print(d['id'])"
   ```

8. **Write config.json.** This MUST be the FINAL step — only write after ALL previous steps have succeeded. Write `{baseDir}/config.json` with pretty-printed JSON containing the alert ID:
   ```
   python3 -c "import json; print(json.dumps({'alertId': 'ALERT_ID'}, indent=2))" > {baseDir}/config.json
   ```
   Replace `ALERT_ID` with the actual extracted value.

9. **Confirm to the user.** Tell the user setup is complete. Show: the alert name, the threshold amount, and the period.

### Error Handling

On ANY failure during the Setup Flow: report what went wrong, tell the user to run `/revenium` when they are ready to try again, and STOP. Do NOT retry. Do NOT write a partial `config.json`. The absence of `config.json` is the signal that setup has not completed.

## `/revenium` Command

When the user invokes `/revenium`:

### If Setup Is Complete (config.json exists)

1. **Show budget status.** Read `alertId` from `{baseDir}/config.json`, then run:
   ```
   revenium alerts budget get ALERT_ID --json
   ```
   Display the current spend versus threshold to the user (current value, threshold, percent used, remaining).

2. **Offer reconfiguration.** Ask the user: "Would you like to update your budget configuration?" If the user declines, STOP — no further action.

### If Setup Is NOT Complete (no config.json)

Run the Setup Flow from the Setup section above.

### Reconfiguration Flow

When the user requests reconfiguration:

1. **Read existing alert ID.** Read `alertId` from `{baseDir}/config.json`. Call this value `OLD_ALERT_ID`.

2. **Delete the old alert.** Run:
   ```
   revenium alerts budget delete OLD_ALERT_ID --yes
   ```
   If this fails (e.g., alert already deleted or not found): log a warning but continue. The goal is to prevent orphaned alerts.

3. **Delete config.json.** Remove `{baseDir}/config.json`.

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