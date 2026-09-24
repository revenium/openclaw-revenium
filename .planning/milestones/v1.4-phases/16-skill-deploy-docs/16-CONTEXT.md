# Phase 16: Skill Deploy & Docs - Context

**Gathered:** 2026-06-10
**Status:** Ready for planning

<domain>
## Phase Boundary

Finish the NemoClaw install path so it is **operator-runnable and honestly proven**:

1. The Revenium skill deploys into the NemoClaw sandbox via `nemoclaw skill install` and is discovered by the agent as `✓ ready` — with the installer **asserting** that ready state, not just running the install.
2. Operators have a complete, standalone runbook for the NemoClaw install path: prerequisites, the parallel-path guarantee, and the macOS-unsupported constraint.

**Requirements:** NCDEPLOY-01 (deploy + `✓ ready` discovery), NCDEPLOY-02 (operator docs).

**Already in place from prior phases (do NOT rebuild):**
- The deploy *mechanism* — `install_skill_nemoclaw()` in `scripts/post-install-nemoclaw.sh` runs `nemoclaw <name> skill install <path>` (pulled forward into Phase 15 per D-08, exercised on the live sandbox). What's missing is an explicit `✓ ready` assertion.
- macOS refusal + Linux/NemoClaw/standalone detection (Phase 12, NCINST-02). Phase 16 **documents** this; it does not re-implement detection.
- The combined `revenium-enforcement` plugin install + smoke gate (Phase 15). Out of scope here.

This phase does NOT touch the standalone OpenClaw + Docker path or its `README.md` instructions (beyond a single pointer link).
</domain>

<decisions>
## Implementation Decisions

### Docs home & structure
- **D-01:** NemoClaw operator docs live in a **separate file** under `docs/` (e.g. `docs/nemoclaw-setup.md`), NOT inside `README.md`. The only edit to `README.md` is a single short pointer link to the new doc. This keeps the existing 316-line standalone README intact and uncontradicted (satisfies SC4).

### `✓ ready` verification
- **D-02:** Add a **fail-hard discovery assertion** to `scripts/post-install-nemoclaw.sh` after `install_skill_nemoclaw()`: run `nemoclaw <name> skill list` (or equivalent discovery command — researcher/planner to confirm exact invocation), grep for the revenium skill showing `✓ ready`, and **fail hard** if it is absent — mirroring the existing D-07 plugin smoke-gate style. This makes SC1 self-proving on every install rather than relying on the operator to eyeball it. (Small code task; the phase is not docs-only.)

### Clean-host E2E gate
- **D-03:** Phase 16 includes a **live fresh-sandbox validation gate** (a checkpoint plan, in the spirit of Plans 15-03 / 15-07). Run the documented install path on a clean sandbox (`34.224.27.67` or equivalent) following **only the new docs**, and record evidence (commands, exit codes, observed `✓ ready`) in a `16-VALIDATION.md`. This is the honest proof for SC2 ("no undocumented manual steps") — it surfaces any step that works only because a host was already half-configured. Follow the same CRITICAL HONESTY RULE used in Phase 15: record real output, never claim a pass that did not happen.

### Docs depth & audience
- **D-04:** The NemoClaw doc is a **full operator runbook**, covering: prerequisites (Linux, Docker, NemoClaw installed, `sshfs`), the install command sequence, `✓ ready` verification, the **parallel-path guarantee** explainer (standalone OpenClaw path is untouched), the **macOS-unsupported** constraint **with its exact error message**, plus troubleshooting and uninstall. Fully satisfies SC3.

### Claude's Discretion
- Exact filename/location under `docs/` (`docs/nemoclaw-setup.md` is the working name).
- The precise discovery command and grep pattern for the `✓ ready` assertion — confirm against NemoClaw CLI behavior during research/execution (the spike findings note discovery via `skill install` gives listing; verify the `skill list`/inspect surface).
- Doc section ordering and prose, as long as all D-04 topics are present.
- Whether the live-validation gate reuses the existing `revenium-spike` sandbox or provisions a fresh one — pick whichever more honestly tests "clean host" without leaving the shared host broken.
</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase scope & requirements
- `.planning/ROADMAP.md` § "Phase 16: Skill Deploy & Docs" — goal, SC1–SC4, depends-on Phase 15.
- `.planning/REQUIREMENTS.md` § "Skill Deploy & Docs (NCDEPLOY)" — NCDEPLOY-01, NCDEPLOY-02 + traceability table (note: NCDEPLOY-01 deploy step pulled into Phase 15 per D-08).

### Deploy mechanism (already wired — extend, don't rebuild)
- `scripts/post-install-nemoclaw.sh` — `install_skill_nemoclaw()` (~line 117) runs `nemoclaw skill install`; the call site is in the main install sequence (~line 515). The `✓ ready` assertion (D-02) attaches here. The D-07 plugin smoke gate is the style template for the fail-hard check.

### Docs to mirror / not contradict
- `README.md` — the standalone OpenClaw + Docker install path (316 lines: Prerequisites, Installation steps 1–5, Setup, How It Works, Configuration, Uninstalling, Troubleshooting incl. a macOS note). The NemoClaw doc must parallel this structure without changing it (SC4). The single README pointer link is the only allowed edit.
- `SKILL.md`, `BUDGET-GUARD.md` — skill manifest / guardrail behavior, for accurate cross-references in the new doc.

### NemoClaw install path knowledge (spike findings)
- `.claude/skills/spike-findings-openclaw-revenium/SKILL.md` — load during NemoClaw work (CLAUDE.md routing mandates it).
- `.claude/skills/spike-findings-openclaw-revenium/references/install-and-bootstrap.md` — Linux-only; prerequisites; macOS graceful-skip → false success (why the explicit refusal + doc matter); ~11 min bootstrap.
- `.claude/skills/spike-findings-openclaw-revenium/references/skill-deploy-and-enforcement.md` — `skill install` gives discovery; what `✓ ready` looks like.

### Live validation precedent (format to follow)
- `.planning/phases/15-per-turn-enforcement-plugin/15-VALIDATION.md` — the evidence format (commands / exit codes / observed output) and CRITICAL HONESTY RULE the D-03 gate should reuse.
- `.planning/phases/15-per-turn-enforcement-plugin/15-07-PLAN.md` — checkpoint-plan + blocking-human-verify structure to model the validation plan on.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/post-install-nemoclaw.sh` — ledger-keyed install helpers (`ledger_has`/`ledger_set`), `step`/`info`/`fail` logging, and the D-07 python3 preflight + marker smoke gate. The `✓ ready` assertion (D-02) should reuse this same helper vocabulary and fail-hard idiom; add a ledger key if the check is expensive to repeat.
- `README.md` — the canonical doc tone/structure to mirror for the NemoClaw runbook (numbered steps, fenced command blocks, blockquote caveats, a Troubleshooting section).

### Established Patterns
- **Live-validation honesty gate** (Plans 15-03 / 15-05 / 15-07): code change → live sandbox run → evidence recorded in `*-VALIDATION.md` → blocking human checkpoint. D-03 follows this exact pattern.
- **Fail-hard install gates** (D-07 in `post-install-nemoclaw.sh`): preflight/smoke checks that abort the install with an actionable message rather than completing silently. D-02 extends this.
- **Parallel-path discipline**: every NemoClaw addition is additive and must not alter the standalone path (NCINST-01 / SC4).

### Integration Points
- D-02 `✓ ready` assertion → slots into `post-install-nemoclaw.sh` immediately after `install_skill_nemoclaw()` (before or alongside the existing plugin smoke gate).
- D-01 doc pointer → one link added to `README.md`; new file under `docs/`.
- D-03 validation gate → exercises the whole `post-install-nemoclaw.sh` path on a clean sandbox, reusing the Phase 13/14/15 host (`34.224.27.67`).

</code_context>

<specifics>
## Specific Ideas

- The macOS doc section must include the **exact error message** the detector emits (pull the literal string from the Phase 12 detection code so docs and code agree verbatim).
- The `✓ ready` assertion should fail with an actionable message (what to check / how to re-run), consistent with the existing `fail "..."` calls.
- Live validation should follow **only the written docs** — a tester who deviates from the doc would mask undocumented steps, defeating SC2.

</specifics>

<deferred>
## Deferred Ideas

- **Baking the skill into a custom OpenShell image** (`nemoclaw onboard --from`) — explicitly out of scope per REQUIREMENTS.md "Non-Goals"; runtime `skill install` + plugin install is sufficient. Revisit only if runtime install proves insufficient.

None other — discussion stayed within phase scope.

</deferred>

---

*Phase: 16-skill-deploy-docs*
*Context gathered: 2026-06-10*
