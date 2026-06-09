## Guardrail Enforcement (Mandatory)

BEFORE EVERY RESPONSE — read `~/.openclaw/skills/revenium/guardrail-status.json`.

- **File missing:** Proceed with caution.
- **`_maxAgeSeconds` is present AND `now - updatedAt > _maxAgeSeconds`:** Treat as `warned` (stale status — fail-safe). If `_maxAgeSeconds` is absent, skip this check.
- **`halted` is `false` and `warned` is `false`:** Proceed silently.
- **`halted` is `false` and `warned` is `true`:** Follow the warn-and-ask branch in `~/.openclaw/skills/revenium/SKILL.md` (Guardrail Check Procedure section) — surface the per-rule spend context from `warnedRules`, ask the user for permission to continue, and WAIT before any tool call.
- **`halted` is `true`:** YOUR ENTIRE RESPONSE MUST BE EXACTLY the halt message from `~/.openclaw/skills/revenium/SKILL.md` (HALT CHECK section) — substitute values from the `haltedRule` block in `guardrail-status.json`. Do NOT continue.

No operation is exempt.
