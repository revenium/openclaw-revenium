# Pitfalls Research

**Domain:** OpenClaw skill — CLI-wrapping budget enforcement guardrail
**Researched:** 2026-03-13
**Confidence:** MEDIUM-HIGH (YAML/skill loading pitfalls: HIGH via official docs + confirmed issues; budget check / instruction compliance pitfalls: MEDIUM via community reports; anomaly ID persistence: MEDIUM, limited official documentation)

---

## Critical Pitfalls

### Pitfall 1: YAML Frontmatter Silently Kills Skill Loading

**What goes wrong:**
A colon followed by a space (`: `) anywhere in an unquoted YAML value causes the skill to be completely dropped from discovery — no error, no warning, no entry in `openclaw skills list`. The skill simply does not exist from the agent's perspective.

**Why it happens:**
YAML interprets `key: value` as a nested mapping. Skill descriptions often contain natural-language patterns like `"Use when: budget is exceeded"` or `"NOT for: greenfield setup"`. The OpenClaw skill loader catches the YAML exception internally but discards diagnostic information entirely downstream (confirmed: [Issue #22134](https://github.com/openclaw/openclaw/issues/22134)).

**How to avoid:**
Wrap ALL string values in the frontmatter in double quotes. This is non-negotiable for the `description` field since it will almost certainly contain colons. Test loading by running `openclaw skills list` after every frontmatter change and verifying the skill appears.

```yaml
description: "Tracks token budgets via revenium-cli. Use when: starting any agent session."
```

**Warning signs:**
- Skill does not appear in `openclaw skills list` output
- No error message about the skill anywhere
- Agent doesn't recognize skill-specific commands

**Phase to address:** Earliest possible — skill scaffolding / SKILL.md authoring phase.

---

### Pitfall 2: `metadata` Field Must Be Single-Line JSON

**What goes wrong:**
The OpenClaw frontmatter parser only supports single-line frontmatter keys. If the `metadata` field spans multiple lines (e.g., for readability), the parser fails. The skill is silently dropped or loads with incorrect/empty metadata, meaning `requires.bins` and `requires.env` gates are not enforced.

**Why it happens:**
Developers format YAML for human readability. Multi-line metadata looks correct in a text editor and passes standard YAML validators, but OpenClaw's embedded parser enforces a single-line constraint not widely documented.

**How to avoid:**
Keep `metadata` as a single-line JSON object regardless of complexity:

```yaml
metadata: {"openclaw":{"requires":{"bins":["revenium"]}}}
```

If the line gets long, that is acceptable — do not add line breaks inside the JSON value.

**Warning signs:**
- `requires.bins` check is not gating skill load when binary is absent
- Skill loads but `revenium` binary absence is not caught

**Phase to address:** SKILL.md authoring phase. Verify with binary absent to confirm gate works.

---

### Pitfall 3: Binary PATH Resolution Fails in Non-Login Shell Environments

**What goes wrong:**
The `revenium` binary is on the developer's PATH in their normal terminal, but the OpenClaw agent's exec environment does not see it. The skill loads (the `requires.bins` check uses the host PATH at load time), but runtime commands fail with `command not found`.

**Why it happens:**
OpenClaw agents may run in a "phantom sandbox" state where the exec tool does not invoke a login shell and thus does not source `~/.zshrc`, `~/.zprofile`, or version-manager initializations. Binaries installed via Homebrew on Apple Silicon (`/opt/homebrew/bin`), nvm, fnm, or volta are particularly susceptible. This is a confirmed OpenClaw bug ([Issue #41549](https://github.com/openclaw/openclaw/issues/41549)).

**How to avoid:**
Use absolute paths in skill instructions when invoking `revenium`. Alternatively, document that users must ensure `revenium` is on a system-level PATH (e.g., `/usr/local/bin` or `/opt/homebrew/bin` symlinked). Add a skill setup verification step that runs `which revenium` and surfaces the resolved path to the user.

**Warning signs:**
- `requires.bins` passes (skill loads) but `revenium config set key` fails at runtime
- Error is `command not found: revenium` despite the binary being installed
- Problem occurs in headless or background agent runs but not in terminal sessions

**Phase to address:** Setup/first-run phase. Include a binary path verification step before proceeding with API key configuration.

---

### Pitfall 4: Agent Treats Skill Instructions as Suggestions, Not Mandates

**What goes wrong:**
The skill instructs the agent to "check budget status before every operation," but the agent exercises discretion and skips the check for operations it deems low-risk or when context is long. Budget enforcement is silently bypassed for some operations.

**Why it happens:**
OpenClaw skill instructions are injected into the system prompt as advisory text — the underlying LLM reasons about whether to follow them rather than enforcing them mechanically. This is a fundamental property of LLM agents, not a bug. Confirmed pattern: agents ignore `envHelp.howToGet` and other instructional content in favor of their training data ([Issue #30681](https://github.com/openclaw/openclaw/issues/30681)).

**How to avoid:**
Write the budget check instruction as a hard pre-condition with explicit "STOP" language, not as a suggestion. Frame it as a rule the agent reports on, not a task it may skip. Example phrasing: "BEFORE executing any tool call, you MUST run `revenium alerts budget get <anomaly-id>` and report the result. Do not proceed without completing this check." Avoid passive voice and conditional language.

**Warning signs:**
- Agent occasionally skips budget check for "simple" operations
- Budget exceeded but agent proceeded without warning in some sessions
- Agent describes budget check as "if applicable"

**Phase to address:** SKILL.md instruction writing phase. Test with explicit prompts that try to shortcut the budget check step.

---

### Pitfall 5: Anomaly ID Has No Native Persistence Mechanism in Skills

**What goes wrong:**
The anomaly ID returned by `revenium alerts budget create` must be stored somewhere so subsequent `revenium alerts budget get <anomaly-id>` calls can use it. There is no built-in OpenClaw skill state store — if the skill relies on the agent "remembering" the ID across sessions, it will be lost when the session resets.

**Why it happens:**
OpenClaw sessions are ephemeral by design — they reset daily (4 AM by default), on `/reset`, or on context overflow. Tool results are trimmed from in-memory context. The agent may know the anomaly ID within one session but have no recollection of it the next day. The skill format (single SKILL.md, no code files) cannot execute arbitrary file writes.

**How to avoid:**
Instruct the agent to persist the anomaly ID to a well-known file path (e.g., `~/.openclaw/skills/revenium/config.json` or `~/.config/revenium-skill/state.json`) using a shell command during setup. The budget check step should read this file before calling `revenium alerts budget get`. The setup phase should detect if the file is missing and re-run onboarding.

**Warning signs:**
- Budget checks succeed in the setup session but fail in subsequent sessions
- Agent asks for the anomaly ID on every new session
- "Budget ID not found" or equivalent errors after overnight reset

**Phase to address:** Setup/onboarding phase. Anomaly ID persistence must be designed and tested before considering setup complete.

---

### Pitfall 6: Re-running Setup Creates Duplicate Budget Alerts

**What goes wrong:**
If setup is run a second time (user re-runs onboarding, reinstalls skill, or anomaly ID file is lost), `revenium alerts budget create` creates a new alert. The user now has multiple overlapping budget alerts and the skill tracks a different anomaly ID than the one Revenium is actually enforcing.

**Why it happens:**
The CLI create command has no idempotency guard visible in the documentation. Skills lack state awareness — each setup run is independent. Users who lose their anomaly ID state file will re-run setup rather than recover the existing alert.

**How to avoid:**
The skill setup flow should call `revenium alerts budget list` first and check for existing alerts before creating a new one. If an existing alert is found, prompt the user to confirm they want to create a new one or reuse the existing anomaly ID. Document the state file location prominently so users know to back it up.

**Warning signs:**
- Multiple budget alerts appearing in the Revenium dashboard
- User reports setup was "run again" or the skill was reinstalled
- Budget check uses a stale anomaly ID that no longer reflects active monitoring

**Phase to address:** Setup/onboarding phase. Idempotency logic must be designed before setup is considered done.

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Hardcode anomaly ID directly in SKILL.md instructions | Avoids persistence logic complexity | Breaks for every user; non-distributable | Never |
| Skip `revenium alerts budget list` pre-check in setup | Simpler setup flow | Duplicate alerts on re-run | Never |
| Use agent memory/context for anomaly ID instead of file | No extra file writes | Lost on session reset; breaks overnight | Never in production |
| Omit PATH verification in setup | Fewer setup steps | Silent runtime failures with confusing errors | Never |
| Inline the budget check result format assumption | Simpler parsing instructions | Breaks if Revenium changes CLI output format | Only as MVP with a documented "verify format" step |

---

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| `revenium config set key` | Running without verifying success exit code | Check exit code and surface error to user; don't assume key was accepted |
| `revenium alerts budget create` | Assuming output format is stable | Parse anomaly ID defensively; log raw output for debugging |
| `revenium alerts budget get <id>` | Assuming network is always available | Skill instructions must define behavior on network failure — fail open or fail closed? |
| `revenium alerts budget get <id>` | Calling with a stale or wrong anomaly ID | Validate the ID format before calling; handle "not found" response explicitly |
| OpenClaw `requires.bins` | Assuming this prevents runtime failures | The check is PATH-at-load-time only; runtime PATH may differ |

---

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Network call before every operation | Noticeable delay on every agent turn | This is intentional and acceptable — but set user expectations in skill description | Immediately; not a scale issue, it is a latency-per-operation cost from day one |
| Budget check on trivial read-only operations | User friction for harmless queries | Define in skill instructions which operation types trigger the check (all tool calls, or only write/destructive operations) | From first use if check is too broad |
| Revenium API rate limiting | Budget checks start failing intermittently | Check Revenium API rate limit documentation; consider caching the result within a single session if many sequential calls are expected | Unknown threshold — investigate |

---

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Skill instructions expose the anomaly ID in plaintext conversation | Anomaly ID could be used by injected prompts to query budget data | Store ID in file, reference file path in instructions rather than embedding the ID value |
| API key stored in plaintext at predictable location | Key exposed to any process reading `~/.revenium/config` or equivalent | Document that the key is stored by `revenium-cli` itself; the skill should not store or re-display the key after initial setup |
| Skill instructs agent to echo the API key for verification | Key appears in session transcript and logs | Never instruct the agent to print or display the API key; use `revenium config verify` or equivalent if it exists |
| No validation that the budget check result is from the expected alert | A compromised or wrong anomaly ID silently reports wrong budget state | Skill setup should record the alert name/description alongside the ID so the agent can sanity-check the returned data |

---

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| Silent success on budget check (no output when under budget) | User has no confidence the check is actually running | Log a brief "Budget OK (used: X / limit: Y)" line even on success — visibility builds trust |
| Vague "budget exceeded" warning with no context | User doesn't know how much over, by what period, or whether to continue | Include spend vs threshold and period in the warning message |
| Setup asks for API key, budget amount, period in separate turns | Feels slow and interrogative | Group all setup questions together with clear explanations of why each is needed |
| "Ask permission to continue" wording is ambiguous | User doesn't know if "continue" means this one operation or all future operations for the session | Be explicit: "Do you want to proceed with THIS operation only?" vs. "Dismiss budget warnings for this session?" |
| No recovery path when anomaly ID is lost | User is stuck with broken budget enforcement until they know to re-run setup | Skill should detect missing state and offer to re-run setup automatically rather than failing with a cryptic error |

---

## "Looks Done But Isn't" Checklist

- [ ] **Budget check**: Verify the check actually runs on a fresh session the day AFTER setup — not just in the same session where the anomaly ID was created
- [ ] **YAML frontmatter**: Run `openclaw skills list` after every edit to SKILL.md and confirm the skill appears with the correct name
- [ ] **Binary gating**: Remove `revenium` from PATH temporarily and confirm the skill does not load (or loads with a clear error)
- [ ] **Idempotent setup**: Run setup twice and confirm only one budget alert exists in the Revenium dashboard
- [ ] **Network failure**: Disconnect network during a budget check and verify the skill handles it gracefully rather than crashing or silently passing
- [ ] **Over-budget warning**: Manually set a budget threshold below current spend and confirm the agent actually asks for permission rather than proceeding
- [ ] **Anomaly ID persistence**: Delete the state file and verify the skill detects the missing ID and prompts re-setup rather than calling `revenium alerts budget get` with an empty/wrong argument

---

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| YAML parse error kills skill | LOW | Fix the quoting in SKILL.md, verify with `openclaw skills list`, restart session |
| Binary not found at runtime | LOW-MEDIUM | Identify installed binary path (`which revenium`), add symlink to system PATH or update skill to use absolute path |
| Anomaly ID lost | LOW | Re-run setup; if duplicate alerts concern you, run `revenium alerts budget list` first, delete stale alert, record existing ID |
| Duplicate budget alerts | MEDIUM | Query `revenium alerts budget list`, identify correct alert, update state file with correct anomaly ID, consider deleting duplicates via Revenium dashboard |
| Agent skips budget check | MEDIUM | Rewrite SKILL.md instruction with stronger mandatory framing; test with adversarial prompts |

---

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| YAML frontmatter parse errors | Skill scaffolding (SKILL.md authoring) | Run `openclaw skills list` and confirm skill is visible |
| Single-line metadata constraint | Skill scaffolding | Remove binary from PATH; confirm skill does not load |
| Binary PATH resolution failure | Setup/onboarding phase | Test in headless agent run, not just interactive terminal |
| Agent ignores mandatory instructions | Skill instruction writing | Run adversarial test: ask agent to skip budget check; confirm refusal |
| Anomaly ID persistence | Setup/onboarding phase | Kill session, start new session, confirm budget check still works |
| Duplicate alerts on re-setup | Setup/onboarding phase | Run setup twice; verify alert count in Revenium dashboard |
| No recovery path for missing state | Setup/onboarding phase | Delete state file; confirm agent detects and offers re-setup |
| Permission fatigue from too-frequent checks | Skill instruction design | Observe real usage; refine which operations trigger checks |

---

## Sources

- [OpenClaw Skills Documentation](https://docs.openclaw.ai/tools/skills) — official skill format, requires.bins, requires.env rules
- [OpenClaw Skills Config](https://docs.openclaw.ai/tools/skills-config) — per-skill env and apiKey configuration
- [OpenClaw Session Concepts](https://docs.openclaw.ai/concepts/session) — what persists, session reset behavior
- [Issue #22134: YAML parse errors are silently dropped](https://github.com/openclaw/openclaw/issues/22134) — confirmed silent skill drop on YAML error
- [Issue #41549: PATH resolution in phantom sandbox](https://github.com/openclaw/openclaw/issues/41549) — confirmed PATH resolution bug for non-login shell exec
- [Issue #30681: Agent ignores envHelp instructions](https://github.com/openclaw/openclaw/issues/30681) — confirmed LLM discretion over-rides skill instructions
- [clawhub/docs/skill-format.md](https://github.com/openclaw/clawhub/blob/main/docs/skill-format.md) — single-line metadata constraint
- [Revenium Cost and Performance Alerts](https://docs.revenium.io/cost-and-performance-alerts) — alert configuration reference
- [LumaDock: OpenClaw Skill Troubleshooting](https://lumadock.com/tutorials/openclaw-troubleshooting-common-errors) — community-sourced failure modes
- [OpenClaw Skill Troubleshooting: 15 Common Errors](https://openclawskill.cc/blog/openclaw-skill-troubleshooting-15-common-errors) — skill loading failure patterns

---
*Pitfalls research for: OpenClaw skill — CLI-wrapping budget enforcement (revenium-cli)*
*Researched: 2026-03-13*
