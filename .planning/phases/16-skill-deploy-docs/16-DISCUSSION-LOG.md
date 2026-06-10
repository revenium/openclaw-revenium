# Phase 16: Skill Deploy & Docs - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-10
**Phase:** 16-skill-deploy-docs
**Areas discussed:** Docs home & structure, ✓ ready verification, Clean-host E2E gate, Docs depth & audience

---

## Docs home & structure

| Option | Description | Selected |
|--------|-------------|----------|
| Separate docs/ file | New `docs/nemoclaw-setup.md` + one pointer link from README.md; standalone README untouched (SC4-safe) | ✓ |
| Fenced section in README.md | Append a NemoClaw section to README.md; risks contradicting/crowding standalone instructions | |
| Top-level README-nemoclaw.md | Separate doc at repo root; same SC4 safety, different location | |

**User's choice:** Separate docs/ file (Recommended)
**Notes:** SC4 requires the existing standalone README.md to stay untouched and uncontradicted; a separate file with a single pointer link is the safest layout.

---

## ✓ ready verification

| Option | Description | Selected |
|--------|-------------|----------|
| Fail-hard assertion in script | Add post-install discovery check (`skill list` grep `✓ ready`, fail-hard if absent), mirroring the D-07 smoke gate | ✓ |
| Documented manual step only | Docs tell operator to run `skill list` and confirm; no script change | |

**User's choice:** Fail-hard assertion in script (Recommended)
**Notes:** `install_skill_nemoclaw()` runs `skill install` but never asserts discovery. The assertion makes SC1 self-proving on every install rather than relying on the operator. Small code task — phase is not docs-only.

---

## Clean-host E2E gate

| Option | Description | Selected |
|--------|-------------|----------|
| Live fresh-sandbox validation gate | Checkpoint plan runs the documented path on a clean sandbox following only the docs; evidence in 16-VALIDATION.md | ✓ |
| Trust Phase 15 evidence + doc walkthrough | No new live run; rely on prior evidence + human read-through | |

**User's choice:** Live fresh-sandbox validation gate (Recommended)
**Notes:** Matches the project's "validate live, not on paper" ethos (Plans 15-03/15-07). Honest proof for SC2 — catches "works because my host was already half-set-up" undocumented-step gaps. Reuse the Phase 15 VALIDATION.md format + CRITICAL HONESTY RULE.

---

## Docs depth & audience

| Option | Description | Selected |
|--------|-------------|----------|
| Full operator runbook | Prereqs + install + ✓ ready + parallel-path guarantee + macOS error message + troubleshooting + uninstall | ✓ |
| Minimal quickstart | Prereqs + install commands + macOS note only | |

**User's choice:** Full operator runbook (Recommended)
**Notes:** SC3 explicitly calls for prerequisites + the parallel-path guarantee + the macOS constraint, so the minimal option would under-deliver.

---

## Claude's Discretion

- Exact filename/location under `docs/` (`docs/nemoclaw-setup.md` working name).
- Precise discovery command + grep pattern for the `✓ ready` assertion (confirm against NemoClaw CLI during research/execution).
- Doc section ordering/prose, as long as all required topics are present.
- Whether the validation gate reuses the existing `revenium-spike` sandbox or provisions a fresh one.

## Deferred Ideas

- Baking the skill into a custom OpenShell image (`nemoclaw onboard --from`) — out of scope per REQUIREMENTS.md Non-Goals; runtime `skill install` is sufficient.
