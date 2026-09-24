---
phase: 16
phase_name: "skill-deploy-docs"
project: "Revenium OpenClaw Skill"
generated: "2026-06-13"
counts:
  decisions: 7
  lessons: 7
  patterns: 5
  surprises: 6
missing_artifacts:
  - "16-UAT.md"
---

# Phase 16 Learnings: skill-deploy-docs (+ v1.4.1 post-ship hardening)

> Scope note: Phase 16 closed the v1.4 milestone, then live UAT reopened the install
> path and a post-ship session (2026-06-12/13) hardened jobs/enforcement end-to-end.
> The post-ship items below are sourced from the v1.4.1 addenda written into this
> phase's VERIFICATION.md, STATE.md, and the fix commits on origin/main — they are
> included here because Phase 16 is the milestone-closing record.

## Decisions

### Anchored `✓ ready` assertion (CR-01)
The skill-deploy readiness grep was hardened from an unanchored `ready` substring to `grep -Eq '(^|[[:space:]])ready([[:space:]]|$)'` after review showed `not-ready`/`already` false-positives, with adversarial regression tests (GROUP I-d/I-e) locking it.

**Rationale:** A false `✓ ready` is worse than a failed install — it reports enforcement that doesn't exist.
**Source:** 16-REVIEW.md (CR-01, WR-03), 16-VERIFICATION.md

### `--force` idempotent plugin install (authorized deviation)
`openclaw plugins install --force` added mid-validation when re-installs failed on pre-existing extension dirs in SSHFS mounts.

**Rationale:** The install must be re-runnable; discovered live, fixed in-phase as an authorized deviation because it was immediately testable.
**Source:** 16-03-SUMMARY.md

### Ledger pre-seeding for hermetic test isolation
GROUP I tests pre-seed Phase 13/14 ledger keys so the skill-deploy function is exercisable without sshfs (unavailable in the hermetic env), plus a `REVENIUM_SKILL_DIR` override hook for the SKILL.md-guard case.

**Rationale:** Test one ledger-gated step without dragging in the infrastructure of every prior step.
**Source:** 16-01-SUMMARY.md

### Out-of-scope limitations become structured follow-up todos
The install exit-1 at Gate A was explicitly scoped out of Phase 16 and recorded as `.planning/todos/pending/nemoclaw-install-gate-a-exit1.md` with source, severity, and phase metadata — rather than blocking the phase or being silently dropped.

**Rationale:** Honest sign-off requires the limitation to be tracked, not buried in a checkpoint note.
**Source:** 16-03-SUMMARY.md

### Gate A/B probes rewritten for OpenClaw v2026.5.22 (v1.4.1)
Gate A derives the default agent from `openclaw agents list` and passes `--agent <id>`; Gate B asserts `Status: loaded` + `allowConversationAccess: true` instead of grepping hook names the version no longer emits.

**Rationale:** The original probes encoded one OpenClaw version's output shapes; the gates must assert capabilities, not incidental CLI text.
**Source:** 16-VERIFICATION.md (v1.4.1 addendum), commit 323a2c6

### Declare-at-start job lifecycle, strictly additive (post-ship)
Jobs open with a `RUNNING` marker at arc start (visible in Revenium in-flight, completions interval-stamped for per-job spend) and close via `--close` at arc end — while the original one-shot terminal marker remains fully supported so existing deployments (NemoClaw's baked directive) are untouched.

**Rationale:** End-only declaration made in-flight work invisible and left most of an arc's spend unattributed; additivity was the hard constraint ("do not break NemoClaw").
**Source:** commit 7633ea4, STATE.md

### Per-turn `before_prompt_build` injection as the primary compliance driver (post-ship)
Both plugins now prepend the metering directives to every turn; the finalize-revise gate is retained only as a backstop for side-effect-free turns.

**Rationale:** It is the only mechanism that empirically held compliance (see Lessons); proven first on NemoClaw, then ported to the standalone plugin.
**Source:** commit b622d88

---

## Lessons

### "Milestone shipped" ≠ "works on a clean host"
v1.4 was marked shipped with all phases verified, yet the first true clean-host UAT found the install path broken end-to-end (~14 fixes). Per-phase verification composed differently than a fresh operator run.

**Context:** Phase-level gates passed individually; the integration seams (host CLI absent, per-host ledger, stale probes) only surfaced doc-driven from scratch.
**Source:** 16-VERIFICATION.md (v1.4.1 addendum)

### Root-cause before accepting a "known limitation"
The install exit-1 was attributed to the B-05 Nemotron limitation and accepted at sign-off; it was actually two stale verification probes against a newer OpenClaw. The accepted-limitation label delayed the real fix and leaked a false claim into downstream docs.

**Context:** A plausible existing limitation is a magnet for misattribution; the falsified claim ("install exits non-zero") was even picked up by a downstream writing agent.
**Source:** .planning/todos/completed/nemoclaw-install-gate-a-exit1.md, 16-VERIFICATION.md

### Runtime upgrades can silently void hook contracts
OpenClaw 2026.6.6 refuses `before_agent_finalize` revise actions on turns with side effects ("requested revision after potential side effects; finalizing") — disabling the v1.3 enforcement loop for exactly the turns it gated. It worked on 2026.6.1; nothing errored, coverage just collapsed.

**Context:** Structural enforcement needs version-drift canaries; a hook that registers successfully can still be vetoed at decision time.
**Source:** commit b622d88, memory/openclaw-2026-6-6-revise-veto.md

### Ambient directives do not hold LLM compliance on long sessions
The agent quoted the AGENTS.md metering directive verbatim from its own context and still wrote zero markers. Per-turn prepended context (fresh each turn) produced full compliance on the first try — same model, same box.

**Context:** Where an instruction sits in context matters more than whether it is in context.
**Source:** commit b622d88

### Coupling job creation to completion metering loses markers under a 1-minute cron
`jobs create` only fired while metering the marker's exact completion; mid-arc completions are routinely metered ticks before the arc-end marker exists, so the marker was never consumed — silently. Fixed with a per-session, ledger-gated sweep that runs before the offset early-return.

**Context:** Any "B happens while processing A" coupling breaks when A and B arrive in different polling windows.
**Source:** commit 50a3916

### Scope-only dedup adopts other tenants' resources
`find_existing_rules` matched budget rules by filter/period/groupBy only — on a shared tenant it would have adopted and renamed another host's rule. Deployment identity (the name label) had to join the match key.

**Context:** "Same scope" is not "same owner" on shared infrastructure.
**Source:** commit db3bb89, 16-VERIFICATION.md context

### Push before doc-driven validation
Re-run 1's "undocumented manual steps" were artifacts of Phase 16 code not yet being on GitHub — the docs referenced a repo state that didn't exist publicly yet.

**Context:** A doc-driven clean-host test validates the published artifact, not the working tree.
**Source:** 16-03-SUMMARY.md

---

## Patterns

### Live-validation honesty protocol
Record verbatim command output; never claim a pass without captured evidence; if validation fails, record the failure and stop rather than fabricating. Paired with the multi-re-run protocol: Re-run 1 discovers, Re-run 2 validates post-push, Re-run 3 confirms the fix.

**When to use:** Any live/host validation gate, especially with a human checkpoint.
**Source:** 16-03-SUMMARY.md

### Hermetic stubs + live smoke as a mandatory pair
The hermetic suite (stub-nemoclaw) proves logic; live runs catch what stubs can't model (CLI flag enums, output shapes, SSHFS behavior, version drift). Phase 16 institutionalized both ends.

**When to use:** Anything that shells out to an external CLI or remote system.
**Source:** 16-01-SUMMARY.md, 16-03-SUMMARY.md

### Shell-function shadowing for cross-cutting call-site hardening
A `nemoclaw()` function shadowing the binary added timeout ceilings to every call site in one diff (`timeout` execs via PATH, so test stubs keep working; `command` bypasses for the fallback).

**When to use:** Retrofit a guard (timeout, retry, logging) onto many call sites of an external binary without touching them.
**Source:** commit db3bb89

### Compliance-mechanism hierarchy for agent obligations
Per-turn prompt injection (works) > structural finalize-revise (vetoed on side-effect turns ≥ 2026.6.6; backstop only) > ambient AGENTS.md/SKILL.md (recall without compliance). Design agent-side obligations top-down on this ladder.

**When to use:** Any feature that depends on the agent reliably performing a bookkeeping action.
**Source:** commit b622d88, memory/openclaw-2026-6-6-revise-veto.md

### Adversarial regression test for every review BLOCKER
CR-01's fix shipped with GROUP I-d encoding the exact false-positive (`not-ready` must reject) — the review finding became a permanent test, not just a patch.

**When to use:** Every code-review BLOCKER whose failure mode is expressible as a fixture.
**Source:** 16-REVIEW.md (WR-03), 16-01-SUMMARY.md

---

## Surprises

### OpenClaw vetoes finalize-revise on side-effect turns
A validated, shipped enforcement mechanism (v1.3 revise loop) had been silently dead since an OpenClaw upgrade — discovered only by reading the gateway file log during live debugging.

**Impact:** Marker coverage collapsed without any error signal; required a new primary mechanism (per-turn injection).
**Source:** commit b622d88

### Agents do most file work via `write`/`edit` tools, not exec
The v1.3 gate only observed exec/bash tool calls; a file-creating turn produced zero observations. The "substantive turn" definition had a structural blind spot.

**Impact:** Even where revise worked, tool-using-but-non-exec turns escaped enforcement; gate now observes all non-read-only tools.
**Source:** commit a33a90e

### Revenium 429-blocks metering ingestion while a budget rule is breached
`meter completion` returns HTTP 429 "Budget limit exceeded" during a breach — spend visibility goes dark exactly when over budget, and `jobs create` is blocked too.

**Impact:** Test windows with tripped budgets pause the whole attribution pipeline; flagged to the Revenium team as possibly unintended for ingestion endpoints.
**Source:** memory/nemoclaw-006-live-validation.md (observed live 2026-06-12)

### Homebrew's Linux build sandbox broke a previously-working install
New Homebrew defaults require rootless bwrap; fresh Ubuntu 24.04 AppArmor restrictions made `brew install revenium` fail with a bubblewrap chicken-and-egg — with zero changes in this repo.

**Impact:** "It worked last week" failures can be pure ecosystem drift; post-install now probes and scopes `HOMEBREW_NO_SANDBOX_LINUX=1` to the single install call.
**Source:** commit d508785

### `budget-rules update` cannot change thresholds
The CLI's update verb only accepts name/filters/notification channels — changing a limit requires delete + recreate + re-pointing config.json `ruleIds`.

**Impact:** Every budget-limit change during testing was a 3-step rule swap; shaped the runbook guidance.
**Source:** memory/nemoclaw-006-live-validation.md

### A single unguarded exec hung the install for a full hour
The D-02 ready-assert (`nemoclaw exec -- openclaw skills list`) had no timeout; a wedged in-sandbox gateway turned it into an indefinite hang with no output.

**Impact:** Drove the timeout-wrapper pattern; the same wedge explains the operator-visible "moseying" stalls.
**Source:** commit db3bb89, 16-VERIFICATION.md context
