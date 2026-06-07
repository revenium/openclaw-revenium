---
spike: 005
name: skill-discovery-and-directives
type: standard
validates: "Given the revenium skill in NemoClaw's skills dir, when an agent turn runs, then the guardrail/marker directives reach agent context (else AGENTS.md-equivalent needed)"
verdict: PARTIAL
related: [001]
tags: [skill-loading, directives, agents-md, plugin]
host: "34.224.27.67 (sandbox revenium-spike)"
---

# Spike 005: Skill Discovery and Per-Turn Directives

## What This Validates

Given the revenium skill deployed into a NemoClaw/OpenShell sandbox, when an agent turn runs,
then (a) the skill is discovered/loadable, and (b) its **MANDATORY per-turn guardrail directive**
reaches the agent's context every turn. Part (b) is the crux — the skill's entire enforcement
model assumes the guardrail check runs *before every operation*.

## Research / prior art

The skill's enforcement depends on a directive that must be in context **every turn**, not loaded
on demand. Prior work on this skill already found (memory: `marker-directives-need-agents-md`,
`clawhub-test-host`) that OpenClaw loads SKILL.md on-demand, so per-turn directives must be injected
elsewhere — historically via `AGENTS.md` (post-install.sh step 7) and a `before_agent_finalize`
plugin. This spike tests whether that gap persists under NemoClaw.

## How to Run

```bash
# Deploy the skill bundle (SKILL.md + scripts + references + taxonomies):
nemoclaw revenium-spike skill install /tmp/revenium-skill

# Confirm discovery:
nemoclaw revenium-spike exec -- openclaw skills list      # -> "✓ ready 💰 revenium"

# Test whether the mandatory directive reaches a turn (neutral prompt):
nemoclaw revenium-spike exec -- openclaw agent \
  --message "List every MANDATORY check you must perform before answering. If none, say NONE." \
  --session-id t --json
```

## What to Expect

- Skill install: "Validated SKILL.md … Uploaded N files … installed".
- Discovery: skill appears as `✓ ready` in `openclaw skills list`.
- Directive test: if the directive reaches context, the agent lists the guardrail check; if not, "NONE".

## Investigation Trail

1. `nemoclaw revenium-spike skill install /tmp/revenium-skill` → "Validated SKILL.md (name: revenium, 21 files); Uploaded 21 file(s); Skill 'revenium' installed". **Discovery works.**
2. Landed at `/sandbox/.openclaw/skills/revenium/SKILL.md`; `openclaw skills list` shows `✓ ready 💰 revenium` (source `openclaw-managed`). Skill paths align: SKILL.md uses `~/.openclaw/…` and in-sandbox `$HOME=/sandbox`, so `~/.openclaw` = `/sandbox/.openclaw`. ✓
3. Checked for AGENTS.md (`/sandbox`, `/sandbox/.openclaw`, `/sandbox/.config/openclaw`) → **all missing**. `nemoclaw skill install` uploads files only; it does **not** run the skill's `post-install.sh` (which is what injects the guardrail check into AGENTS.md + deploys BUDGET-GUARD.md). `guardrail-status.json` also **missing** (the metering cron was never installed).
4. Neutral turn ("what mandatory checks must you run?") → agent answered **"NONE"**. The directive is NOT in context even though the skill is "ready".
5. The turn's `finalPromptText` revealed the **only** per-turn injection NemoClaw performs: a `<nemoclaw-runtime>` system preamble (sandbox identity + deny-by-default network policy). The revenium directive is absent from it.
6. Planted a sentinel `/sandbox/AGENTS.md` (+ `/sandbox/.openclaw/AGENTS.md`) and re-ran a neutral turn → sentinel did **not** appear. A dropped AGENTS.md is **not** auto-injected here.
7. Located the preamble seam: `~/.nemoclaw/source/nemoclaw/src/runtime-context.ts` generates `<nemoclaw-runtime>`. Grepped it for file/env extension points (`readFile`, `process.env`, `AGENTS`, `append`, …) → **none** — the preamble is not user-extensible by config/file.
8. Cleaned up the planted AGENTS.md files.

## Results

**Verdict: PARTIAL.**

- ✅ **Skill discovery & loading: VALIDATED.** `nemoclaw <name> skill install <path>` is a clean,
  first-class deploy: validates SKILL.md, uploads to `/sandbox/.openclaw/skills/<name>/`, and the
  agent lists it as `✓ ready`. On-demand (progressive-disclosure) loading works.
- ❌ **Mandatory per-turn directive: DOES NOT REACH CONTEXT.** Proven empirically (agent said
  "NONE"). SKILL.md is on-demand; there is no AGENTS.md; a dropped AGENTS.md is ignored; and
  NemoClaw's per-turn `<nemoclaw-runtime>` preamble is not file/config-extensible. So installing
  the skill alone does **not** enable enforcement — the same gap as standalone OpenClaw, and
  `nemoclaw skill install` does not close it (it skips `post-install.sh`).

**Requirements / build guidance that emerge:**
- The NemoClaw parallel install path must do **more than `skill install`**. It must also:
  1. Inject the guardrail directive into a **per-turn** channel (skill install does not).
  2. Seed `guardrail-status.json` and install the metering cron (skill install does neither).
- **Most promising injection mechanism:** an **OpenClaw plugin hook** (e.g. `before_agent_finalize`),
  since the `nemoclaw` plugin is already loaded in-sandbox and OpenClaw plugins run every turn —
  this matches the fix used previously for the ClawHub end-of-turn marker gate. AGENTS.md and the
  `<nemoclaw-runtime>` preamble are both dead ends for user injection here.
- **Open question for the build:** confirm exactly which workspace/path OpenClaw reads AGENTS.md
  from under NemoClaw (it was not `/sandbox` or `/sandbox/.openclaw`), OR commit to the plugin-hook
  route. `openclaw.json` has an `agents` config block worth investigating as an instructions seam.

**Surprise:** Discovery is *cleaner* than expected (first-class `skill install`), but the
enforcement-injection gap is *wider* — even the AGENTS.md escape hatch the host install relies on
isn't auto-read in the sandbox, pushing the real fix toward a plugin.
