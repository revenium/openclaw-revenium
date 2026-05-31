## Guardrail Enforcement (Mandatory)

BEFORE EVERY RESPONSE — read `~/.openclaw/skills/revenium/guardrail-status.json`.

- **File missing:** Proceed with caution.
- **`halted` is `false`:** Proceed silently.
- **`halted` is `true`:** YOUR ENTIRE RESPONSE MUST BE EXACTLY the halt message from `~/.openclaw/skills/revenium/SKILL.md` (HALT CHECK section) — substitute values from the `haltedRule` block in `guardrail-status.json`. Do NOT continue.

No operation is exempt.
