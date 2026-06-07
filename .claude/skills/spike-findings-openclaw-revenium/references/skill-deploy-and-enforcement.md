# Skill Deploy & Per-Turn Enforcement

## Requirements

- The revenium skill's **MANDATORY guardrail directive must reach the agent every turn** — its whole
  enforcement model depends on the check running before every operation.

## How to Build It

1. **Deploy the skill** (first-class, validated):
   ```bash
   nemoclaw <name> skill install <path-to-skill-dir>
   ```
   Validates SKILL.md, uploads to `/sandbox/.openclaw/skills/<name>/`; agent lists it `✓ ready`
   (`openclaw skills list`). Skill paths resolve: SKILL.md uses `~/.openclaw/…` and in-sandbox
   HOME=`/sandbox`, so `~/.openclaw` = `/sandbox/.openclaw`. ✓
2. **Separately wire the per-turn directive** — `skill install` does NOT do this. The proven gap:
   - SKILL.md is loaded **on-demand** (progressive disclosure), so the "before every operation"
     instruction is only seen *after* the skill is already invoked — self-defeating.
   - There is **no AGENTS.md** in-sandbox, and a dropped `/sandbox/AGENTS.md` is **not auto-read**.
   - NemoClaw injects a per-turn `<nemoclaw-runtime>` preamble (src `nemoclaw/src/runtime-context.ts`)
     but it is **not file/config-extensible**.
   - **→ Inject via an OpenClaw plugin `before_prompt_build` hook** returning `{ prependContext: <directive> }`.
     Proven viable in spike 006: the `nemoclaw` plugin uses exactly this and its block reaches every
     turn. Author the plugin from `openclaw plugins init` (or mirror the nemoclaw plugin's compiled-ESM
     structure) — a hand-stubbed plugin loaded but hung the turn. Requirements: package.json needs
     `openclaw.extensions: ["./index.js"]`; manifest needs `configSchema`; install via
     `openclaw plugins install` (untrusted/hand-placed plugins load but their hooks are inert);
     `nemoclaw <name> recover` to reload; validate via the gateway turn path.
3. **Also do what `skill install` skips:** seed `guardrail-status.json` (write it via the share mount,
   see metering ref) and stand up the metering loop. Neither is created by `skill install`.

## What to Avoid

- **Assuming `skill install` = working enforcement.** It gives discovery only. Empirically the agent,
  asked what mandatory checks it must run, answered **"NONE"** with the skill installed and "ready".
- **Betting on AGENTS.md in-sandbox** — not auto-read here (unlike the host install path). Don't port
  the host `post-install.sh` AGENTS.md-injection step verbatim; use the plugin route.

## Constraints

- `skill install` does not run the skill's `post-install.sh` (no AGENTS.md injection, no cron, no
  status seed). The per-turn injection mechanism (plugin) is the one **unproven** piece — a good
  candidate for a follow-up spike before the real build.

## Origin

Synthesized from spike: 005. Sources: `sources/005-skill-discovery-and-directives/`.
