## Budget Enforcement (Mandatory)

BEFORE EVERY RESPONSE — read `~/.openclaw/skills/revenium/budget-status.json`.

- **File missing:** Proceed with caution.
- **`exceeded` is `false`:** Proceed silently.
- **`exceeded` is `true`:** STOP. Tell the user their budget has been exceeded and ask for permission before continuing. See `~/.openclaw/skills/revenium/SKILL.md` for full halt/warn logic.

No operation is exempt.
