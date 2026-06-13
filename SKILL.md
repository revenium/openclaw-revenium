---
name: revenium
description: "MANDATORY guardrail check BEFORE EVERY OPERATION — read guardrail-status.json first, always, no exceptions. Enforces Revenium guardrails-native budget rules, warns on threshold exceedance, halts autonomous agents on guardrail block, and meters usage into Revenium."
metadata: {"openclaw":{"emoji":"💰","version":"0.2.0","homepage":"https://docs.revenium.io/for-ai-agents","requires":{"bins":["revenium"],"anyBins":["openclaw"]},"user-invocable":true,"install":[{"kind":"brew","formula":"revenium/tap/revenium","bins":["revenium"]},{"kind":"npm","package":"openclaw","bins":["openclaw"]}]}}
---

## ABSOLUTE FIRST — HALT CHECK (NON-NEGOTIABLE)

OpenClaw hooks for structural enforcement (pre-turn / pre-tool-call injection) are not yet confirmed. This HALT CHECK section is therefore the **primary enforcement gate**, not a backstop — treat it as mandatory, not optional. Execute it on every turn without exception.

Before you read ANY other part of this file, before you write ANY response, before you make ANY tool call:

1. Read `~/.openclaw/skills/revenium/guardrail-status.json`
2. Check the `halted` field
3. If `halted` is `true`, read the `haltedRule` block

**If `halted` is `true`:**

YOUR ENTIRE RESPONSE MUST BE EXACTLY THIS AND NOTHING ELSE (substitute values from `guardrail-status.json::haltedRule`):

> Guardrail halt active — rule '[haltedRule.name]' ([haltedRule.metricType], [haltedRule.windowType]) at [haltedRule.currentValue] of [haltedRule.hardLimit] hard-limit. To resume: `bash ~/.openclaw/skills/revenium/scripts/clear-halt.sh`

- Do NOT make any tool calls
- Do NOT fetch any data
- Do NOT append any content
- Do NOT continue reading this skill file
- Do NOT answer the user's question
- ONLY output the halt message above with actual `haltedRule` field values substituted

**If `halted` is `false`, proceed to the Guardrail Check Procedure below.**

This is not optional. This is not guidance. If you output ANYTHING other than the halt message when `halted: true`, you are violating this skill's requirements.

## Guardrail Check Procedure

**MANDATORY — execute before EVERY response, EVERY tool call, EVERY operation.** This applies to ALL tasks — not just Revenium-related ones.

The guardrail status is maintained by a background cron job that checks Revenium every minute (default; configurable) and writes the result to `~/.openclaw/skills/revenium/guardrail-status.json`. You read this local file — do NOT call the Revenium API directly.

1. **Read guardrail status.** Read `~/.openclaw/skills/revenium/guardrail-status.json`. If it does not exist, tell the user "Guardrail status not yet available. The metering cron may not be installed. Run `bash ~/.openclaw/skills/revenium/scripts/install-cron.sh` to set it up." Then proceed with the operation.

2. **Parse the status.** Extract `halted`, `warned`, and (when `warned` is true) `warnedRules` from the JSON.

3. **Evaluate:**

   **If `halted` is `true`:** Follow the HALT CHECK above — output ONLY the halt message using `haltedRule` fields, and stop.

   **Else if `warned` is `true`:** BEFORE doing any other work this turn, execute the warn-and-ask branch:

   - Read the `warnedRules` array from `~/.openclaw/skills/revenium/guardrail-status.json`.
   - For each entry in `warnedRules`, surface a spend-context warning line: "Budget warning — rule '[name]' ([metricType], [windowType]) at [currentValue] of [hardLimit] hard-limit."
   - Then ask the user for permission to continue: "This rule's hard limit has been reached and you are in warn-and-ask mode (autonomous mode disabled). Do you want me to proceed anyway, or stop?"
   - WAIT for the user's answer. Do NOT perform the requested operation or any tool calls until the user grants permission.
   - If the user declines, stop without performing the operation. If the user grants permission, proceed with the operation for this turn.

   **Else (both `halted` and `warned` are `false`):** Proceed silently. Do NOT mention the guardrail status to the user.

### If guardrail-status.json is missing or unreadable

- Tell the user: "Guardrail status unavailable. Proceeding with caution."
- Proceed with the operation — fail open, do not block the user.

## TASK CLASSIFICATION

**MANDATORY — NON-NEGOTIABLE. Execute before EVERY yield back to the user on a substantive turn.** Skipping leaves the metering pipeline blind and pollutes attribution with `unclassified` rows.

### Trigger (binary — no judgment calls)

Classify the turn if ANY of these are true:

- You called any tool other than read-only file inspection. Reading a file alone does not count. Bash commands, writes, edits, searches, and any other tool ALL count.
- You produced > 200 words of new content in your response.
- The user asked a question that required multi-step reasoning to answer.

Skip ONLY when ALL of the following are true:
- Your entire response is ≤ 2 sentences.
- You called zero tools.

There is no "borderline / when in doubt skip" path. If you can argue either side, you have already triggered rule (a), (b), or (c) — classify.

### Required action

**Step 1 — pick a `task_type` label.** Choose the closest-fitting label from the fixed 8-label taxonomy:

| Label | When to use |
|-------|-------------|
| `research` | Reading docs, exploring code, searching to learn before acting |
| `analysis` | Diagnosing a problem, profiling, or characterizing a system |
| `generation` | Writing new code, tests, configuration, or documentation from scratch |
| `review` | Reviewing docs, designs, or diffs for correctness or fit |
| `code_review` | Reviewing code for correctness, style, or architectural fit |
| `refactor` | Restructuring existing code without changing observable behavior |
| `planning` | Producing a plan, roadmap, design doc, or task breakdown |
| `debugging` | Reproducing and fixing a defect or unexpected behavior |

Default to `unclassified` only when no label fits and the marker write fails or is skipped on a non-substantive turn.

**Step 2 — call write-marker.sh.** Run:

```
bash ~/.openclaw/skills/revenium/scripts/write-marker.sh <task_type>
```

Replace `<task_type>` with the label you chose in Step 1.

- **Confirmation:** `marker written: <path>` — the marker was appended successfully.
- **Non-zero exit or no `marker written:` output:** protocol error — log the error but do not block your response.
- **Attribution when no marker is written:** `unclassified` (the cron defaults to this if no marker precedes the completion timestamp).

See `references/task-classification.md` for the full trigger rules, worked examples, and the blocklist of read-only tools.

### Why this matters

The background cron (`cron.sh`) ships each conversation completion line to Revenium with a `--task-type` flag derived from the marker that most recently preceded the completion's timestamp. Without a marker, every completion is attributed as `unclassified`, making per-task-type budget rules and spend analytics meaningless.

## JOB DECLARATION

**MANDATORY — NON-NEGOTIABLE. Execute at BOTH arc boundaries: OPEN the job when a goal-arc begins, CLOSE it when the arc concludes (completed, definitively failed, or abandoned).** A job = a goal-arc. Most requests are one arc = one job. Opening at the start makes the job visible in Revenium while it runs and attributes the arc's spend to it as it accrues; closing records the outcome.

Unlike TASK CLASSIFICATION (which fires per-turn), JOB DECLARATION fires at goal-arc boundaries. Aim for at least one open+close pair per session in which any real work occurred.

### Trigger (binary — no judgment calls)

**OPEN (status RUNNING)** when the user gives you a goal that needs real work — any multi-step task, tool-using work, or substantive creative/analytical request. Open it BEFORE diving into the work. Skip opening only for trivial exchanges (≤ 2 sentences, zero tools).

**CLOSE (terminal status)** if ANY of these are true:

1. You completed the goal and self-verified (tests passed, build green, question fully answered) → **SUCCESS**.
2. The arc has definitively failed (goal objectively unachievable with approaches available in this session) → **FAILED**.
3. The user pivoted to a new goal before this arc concluded → close the abandoned arc **CANCELLED** first, then OPEN the new arc.

There is no "borderline / when in doubt skip" path. When in doubt: close **CANCELLED** (see status bar below). If you reach the end of an arc you never opened, declare once with the full flags and a terminal status (the original one-shot form — still fully supported).

### Required action

**Step 1 — pick a `job_type` label.** Choose the closest-fitting label from the fixed 11-label taxonomy:

| Label | When to use |
|-------|-------------|
| `feature_development` | Implementing a new capability, endpoint, component, or user-facing behavior from scratch |
| `bug_fix` | Diagnosing and correcting a specific defect or regression in existing behavior |
| `code_review` | Reviewing a diff, PR, or code block for correctness, style, security, or architectural fit |
| `refactoring` | Restructuring existing code to improve clarity, reduce duplication, or improve maintainability without changing behavior |
| `research` | Investigating a technology, approach, library, or unfamiliar codebase before making implementation decisions |
| `debugging` | Reproducing, isolating, and diagnosing the root cause of an unexpected failure or error |
| `testing` | Writing, expanding, or fixing a test suite — unit, integration, end-to-end, or performance tests |
| `documentation` | Writing or updating developer documentation, runbooks, API references, or inline code comments |
| `devops` | Work on infrastructure, CI/CD, deployment configuration, monitoring, or operational tooling |
| `planning` | Producing a plan, design document, task breakdown, or architectural decision record before implementation |
| `interrupted` | Terminal job type for an arc cut short by a budget halt or explicit user cancellation before completion |

**Step 2 — mint an `agentic_job_id`.** Construct a kebab-case goal slug plus a 4-character hex entropy suffix:

```
<kebab-case-goal-description>-<4hex>
```

Example: `add-pagination-endpoint-3b1e`

The slug should be 3–6 words describing the goal. Generate 4 random hex characters as the suffix. You own and mint this ID — no external system generates it.

**Step 3 — OPEN the job at arc start.** Run:

```
bash ~/.openclaw/skills/revenium/scripts/write-job-marker.sh \
  --job-id <agentic_job_id> \
  --job-name "<short human-readable goal description>" \
  --job-type <label_from_step_1> \
  --status RUNNING
```

The script remembers the open job for this session, so closing doesn't require repeating the id.

**Step 4 — CLOSE the job at arc end.** Run:

```
bash ~/.openclaw/skills/revenium/scripts/write-job-marker.sh \
  --close --status SUCCESS|FAILED|CANCELLED \
  [--failure-reason "<brief plain-text cause>"]
```

If `--close` errors with "no open job recorded" (or you never opened the arc), declare once with the full flags from Step 3 and a terminal status instead of RUNNING — the original one-shot form, fully supported.

**Status bar:**
- **`RUNNING`:** the arc is underway (open form only — never a final state).
- **`SUCCESS`:** positive, checkable evidence established in the session (tests passed, build green, question fully answered). "Made the change but could not verify" = CANCELLED, not SUCCESS.
- **`FAILED`:** definitive negative terminal state (the fix didn't fix, build cannot pass, goal objectively unachievable). Include `--failure-reason` with a brief plain-text cause (FAILED-only — never pass `--failure-reason` for SUCCESS, CANCELLED, or RUNNING).
- **`CANCELLED`:** catch-all and uncertainty-bias default. When in doubt: CANCELLED.

**Confirmation and error handling:**
- **`job marker written: <path>`** — the marker was appended successfully.
- **Non-zero exit or no `job marker written:` output:** protocol error — log the error but do not block your response (fail-loud-but-don't-block).

### Why this matters

The cron stage reads job markers from `markers/{sid}.jsonl` and ships them to Revenium's agentic job lifecycle API (`jobs create` → `meter completion --agentic-job-*` → `jobs outcome`). Without a job marker, completions are attributed only at the session level — no job-level spend visibility, no outcome tracking. Job declarations are what make per-job spend and success observable in Revenium.

See `references/job-declaration.md` for the full arc definition, pivot-cancel rule, granularity floor, and worked examples (SUCCESS, CANCELLED-because-unverified, FAILED, pivot-cancel sequence).

## Path Resolution

All file paths in this skill use `~/.openclaw/skills/revenium/` as both the skill directory and the runtime state directory. When using file tools (read, write, edit), pass paths with `~/` — the tool resolves `~` to `$HOME` automatically. When running shell commands via exec/bash, use the explicit `$HOME/.openclaw/skills/revenium/` form so the shell expands `$HOME` correctly.

## Setup

At the start of any operation, check: does `~/.openclaw/skills/revenium/config.json` exist AND contain a non-empty `ruleIds` array (present and not `[]`)?

- **If YES** and the user has NOT requested reconfiguration: setup is complete. Proceed to the guardrail check. Do NOT re-run setup.
- **If NO** (file missing, or `ruleIds` absent, or `ruleIds` is `[]`): you MUST run the Setup Flow below before proceeding. Do NOT execute any operations until setup is complete.

**Note on legacy installs:** `config.json` may carry a legacy `alertId` field from a Phase 2 install. That field is deprecated and ignored for the setup gate — `ruleIds` is the sole signal. An `alertId`-only config.json (no `ruleIds`, or `ruleIds` is `[]`) triggers the Setup Flow just as if the file were missing. The old `alertId` is left as an orphan in `config.json` and ignored.

### Setup Flow

Follow these steps in order. If any step fails, STOP and explain the failure. Do NOT prompt the user for budget details yourself, and do NOT write any rule IDs into `config.json` yourself.

1. **Verify the Revenium CLI is configured.** Run:
   ```
   revenium config show
   ```
   The sandbox is authenticated via `REVENIUM_*` environment variables that post-install.sh injects from the host's `~/.config/revenium/` config — OpenClaw blocks mounting credential paths into the sandbox, so credentials are passed as env vars, not a live mount. If `revenium config show` reports a non-empty API Key, skip to step 3. If the CLI is not on PATH, tell the user to install it (`brew install revenium/tap/revenium` on macOS) and STOP.

2. **If no API key is configured:** credentials must be set on the HOST and then injected into the sandbox by re-running post-install. `revenium config set ...` run from inside the agent session cannot persist or reach the sandbox.

   Collect the following from the user:

   - **API Key**: "Please provide your Revenium API key."
   - **Team ID**: "Please provide your Revenium Team ID."
   - **Tenant ID**: "Please provide your Revenium Tenant ID."
   - **Owner ID**: "Please provide your Revenium Owner ID."

   Then instruct the user to run these commands in their HOST terminal (outside the agent session), one at a time:
   ```
   revenium config set key API_KEY
   revenium config set team-id TEAM_ID
   revenium config set tenant-id TENANT_ID
   revenium config set owner-id OWNER_ID
   ```
   The sandbox does NOT see host credential changes live — they are injected as a snapshot at install time. After the user sets them on the host, they must re-run post-install and restart the gateway so the new credentials reach the sandbox:
   ```
   bash ~/.openclaw/skills/revenium/scripts/post-install.sh
   openclaw gateway restart
   ```
   Then re-run `revenium config show` inside the agent session to confirm the API Key is now visible. If it is still empty, STOP and tell the user to run `/revenium` when ready.

3. **Run the setup script:**
   ```
   bash ~/.openclaw/skills/revenium/scripts/setup-guardrails.sh --interactive
   ```
   The script prompts the operator for budget hard-limit, period, organization name, autonomous mode + notification channel/target, and shadow mode. On success, it creates the Revenium guardrails budget rules via `revenium guardrails budget-rules create` and writes the resulting `ruleIds` array into `~/.openclaw/skills/revenium/config.json`. You do NOT prompt the user for budget details yourself, and you do NOT write any rule IDs into `config.json` yourself — the script owns the entire interaction and the entire write.

   Capture the exit code and act on it:
   - **Exit 0, final output line `Created N rule(s). config.json updated. ruleIds=[...]`**: succeeded. Proceed to step 4.
   - **Exit 0, final output line `Cancelled.`**: operator cancelled. STOP without proceeding to step 4.
   - **Non-zero exit**: failure. Tell the user the failure message verbatim, instruct them to address it and re-run `/revenium`. STOP. Do NOT proceed to step 4.

   If the user asks to set up in shadow mode, run `setup-guardrails.sh --interactive --shadow-mode` instead. By default, rules created via `--interactive` are enforcing.

4. **Install the metering cron:**
   ```
   bash ~/.openclaw/skills/revenium/scripts/install-cron.sh
   ```
   This registers a background job that ships token usage to Revenium every minute (the default interval; configurable via `--interval <minutes>` or `config.json` `cronIntervalMinutes`) and keeps `guardrail-status.json` current. Re-running updates the existing entry in place.

### Error Handling

On ANY failure during the Setup Flow: report what went wrong, tell the user to run `/revenium` when they are ready to try again, and STOP. Do NOT retry. The absence of a valid `ruleIds` array in `config.json` is the signal that setup has not completed.

## `/revenium` Command

When the user invokes `/revenium`:

**Bare invocation = act, don't interrogate.** `/revenium` with no arguments (or no actionable request attached) is a command, not an open question. Do NOT ask the user what they want, do NOT present a menu of options, and do NOT ask for an "underlying task" — this skill IS the task when invoked directly. Route immediately:

- **Setup complete** (config.json has a non-empty `ruleIds` array) → run the status flow below and present the report.
- **Setup NOT complete** → start the Setup Flow from the Setup section, beginning with its first step.

Only when the user attaches an explicit request to the command (e.g. `/revenium reconfigure`, "change my budget", "why was I halted?") should you do that instead.

### If Setup Is Complete (config.json has a non-empty `ruleIds` array)

**Before displaying status, check for legacy filter rules (D-08, one-time):**

Phase 3 introduced `--agent "openclaw-{root_session_id}"` per-session naming (D-07). Any budget rules created before this migration still filter `AGENT:IS:OpenClaw`, which now matches nothing — spend from all sessions is silently dropped.

1. **Read `~/.openclaw/skills/revenium/config.json`.** Check for a `_legacyNoticeShown` field.
   - If `_legacyNoticeShown` is `true`: skip the legacy detection entirely (notice already delivered).
   - If absent or `false`: proceed to step 2.

2. **Detect legacy rules.** Run:

   ```
   revenium guardrails budget-rules list --output json
   ```

   Parse the JSON response. If any rule contains a filter with `AGENT:IS:OpenClaw` (exact string match, case-sensitive), a legacy rule is present.

   Alternatively, if the CLI call fails (network error, auth failure), check whether `config.json` has a `schemaVersion` field — a missing `schemaVersion` indicates a pre-D-07 install. Either detection mechanism is acceptable; the live rule list is preferred when available.

3. **If a legacy rule is detected:** surface EXACTLY ONCE the following notice — byte-for-byte, including the em-dash (—) and the apostrophe in "won't":

   > Your budget rules use the old filter and won't track spend — run reconfigure.

   Then tell the user: "To fix this, choose **reconfigure** below, which will delete and recreate your rules using the current `AGENT:STARTS_WITH:openclaw-` filter."

   **Why this matters:** After the D-07 migration, the agent ships `--agent "openclaw-<session-id>"` on every transaction. The Revenium server matches budget rules by their `AGENT` filter dimension. Rules that filter `AGENT:IS:OpenClaw` look for an agent named exactly `OpenClaw`, but no transactions carry that name anymore — so the rules never fire, spend is never tracked, and budget enforcement is silently disabled. The user MUST reconfigure (via `setup-guardrails.sh --interactive`) to recreate rules with the new `AGENT:STARTS_WITH:openclaw-` filter. Repo edits cannot fix server-side rules.

   **Do NOT act unilaterally.** Do NOT call `setup-guardrails.sh` without user request, do NOT delete or recreate any rule without explicit user action, and do NOT modify any rule in `config.json`. The user must choose to reconfigure (honors Phase 3 D-02, per D-08).

4. **Persist the one-time flag.** After surfacing the notice (or confirming no legacy rules exist), write `"_legacyNoticeShown": true` into `~/.openclaw/skills/revenium/config.json` using an atomic temp-then-rename write so the notice does not repeat on subsequent `/revenium` invocations. Atomic write pattern (03-PATTERNS "Atomic JSON Write"):

   ```python
   import json, os, tempfile
   path = os.path.expanduser("~/.openclaw/skills/revenium/config.json")
   with open(path, "r") as f:
       cfg = json.load(f)
   cfg["_legacyNoticeShown"] = True
   tmp = path + ".tmp"
   with open(tmp, "w") as f:
       json.dump(cfg, f, indent=2)
       f.write("\n")
   os.replace(tmp, path)
   ```

   Run this via a bash `python3 -c` invocation or `execute_code` — do NOT write the file with a text editor or cat/echo (not atomic).

---

1. **Show rule IDs and per-rule state.** Read `ruleIds` from `~/.openclaw/skills/revenium/config.json`, then read per-rule state from `~/.openclaw/skills/revenium/guardrail-status.json`. For each rule in `rules[]`, display:
   - Rule name
   - `state` (ok / warn / block)
   - `currentValue` vs `hardLimit`
   - `shadowMode` (true = observe-only, not blocking)

2. **Show autonomous mode and halt state.** Read `~/.openclaw/skills/revenium/config.json` and display:
   - **Autonomous mode:** enabled or disabled
   - **Halt status:** Read `~/.openclaw/skills/revenium/guardrail-status.json` and check `halted`. Display "ACTIVE (since [haltedAt])" if `halted` is `true`, or "inactive" if `false`.
   - If halt is active, also show: "To resume operations, run: `bash ~/.openclaw/skills/revenium/scripts/clear-halt.sh`"

3. **Offer actions.** Ask the user: "Would you like to **reconfigure** (change rules/settings) or **done**?"

   - **`reconfigure`:** Run `bash ~/.openclaw/skills/revenium/scripts/setup-guardrails.sh --interactive`. The script handles delete-and-recreate of existing rules. Capture the exit code using the same contract as Setup Flow step 3 above.
   - **`done`:** STOP — no further action.

### If Setup Is NOT Complete (config.json missing, or `ruleIds` absent or `[]`)

Run the Setup Flow from the Setup section above.

## Troubleshooting

### Binary Not Found

If `revenium` is not found on PATH:
- STOP all operations that require guardrail checking
- Tell the user: "The `revenium` CLI is not installed or not on your PATH. Install it from https://docs.revenium.io/for-ai-agents and ensure it is available in your shell."

### API Key Invalid

If `revenium config show` reports no API key or an invalid key:
- STOP all operations that require guardrail checking
- Tell the user: "Your Revenium API key is missing or invalid inside the sandbox. The sandbox is authenticated via environment variables injected from your host's `~/.config/revenium/` config — it is NOT a live mount. Fix the credentials on the host: run `revenium config set key <KEY>` (plus `team-id`, `tenant-id`, `owner-id` as needed) in your HOST terminal, then re-run `bash ~/.openclaw/skills/revenium/scripts/post-install.sh` and restart the gateway so the new credentials reach the sandbox. Then run `/revenium` to resume setup."

### Network Errors

If any `revenium` CLI command fails due to network issues:
- Tell the user: "Unable to reach the Revenium API. Check your network connection and try again."
- Do NOT proceed with the operation until guardrail status is confirmed.

> Reminder: Check guardrail-status.json before your next response.
