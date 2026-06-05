# Phase 11: Structural Marker Enforcement via before_agent_finalize plugin - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-04
**Phase:** 11-structural-marker-enforcement-via-before-agent-finalize-plug
**Areas discussed:** Plugin home & distribution, Gate scope (task vs task+job), session_end job closure, Packaging & build format

---

## Plugin home & distribution

### Where the plugin lives

| Option | Description | Selected |
|--------|-------------|----------|
| Same repo, new plugin/ dir | Add a plugin/ package inside this repo; versions + ships with the bash skill on ClawHub as one unit | ✓ |
| Separate repo + ClawHub pkg | Standalone repo published as its own ClawHub plugin package; two repos to version-sync | |
| Same repo, top-level files | Plugin source as top-level .ts files (no nested package) | |

**User's choice:** Same repo, new plugin/ dir
**Notes:** One release / one PR surface, kept in lockstep with the bash skill.

### Install flow

| Option | Description | Selected |
|--------|-------------|----------|
| post-install.sh automates it | post-install.sh runs `openclaw plugins install` (local path) + writes plugins.entries.<id> enable config, idempotent | ✓ |
| Manual + documented | User runs install themselves; README documents it | |
| ClawHub installs it natively | Rely on ClawHub to install the plugin when the skill installs (needs research to confirm support) | |

**User's choice:** post-install.sh automates it
**Notes:** Matches the v1.1 lesson — un-automated steps silently don't run in production. Exact invocation + enable-config shape flagged as a research item.

---

## Gate scope (task vs task+job)

### What the gate forces

| Option | Description | Selected |
|--------|-------------|----------|
| Task marker only | Gate the per-turn TASK marker only; job declaration stays directive-driven + session_end/report.sh | ✓ |
| Task + job markers | Also require write-job-marker.sh per turn — over-fires (job arcs don't conclude every turn) | |
| Task always, job if arc signal | Force task always; job only on arc-conclusion signal — fuzzy without conversation access | |

**User's choice:** Task marker only

### Gate trigger (definition of "substantive turn")

| Option | Description | Selected |
|--------|-------------|----------|
| Turn that ran any exec tool | Gate finalize only when the turn invoked ≥1 exec tool call and didn't run write-marker.sh | ✓ |
| Every natural finalize | Gate every before_agent_finalize regardless of tool activity — noisy on chat-only replies | |
| Defer to research | Let researcher determine the cleanest signal from SDK context | |

**User's choice:** Turn that ran any exec tool
**Notes:** Structural, observable from exec-only, low false-fire; pure-chat turns pass through.

---

## session_end job closure

| Option | Description | Selected |
|--------|-------------|----------|
| Defer — keep phase narrow | Phase 11 = task gate + verify-markers.sh only; job closure stays with report.sh/JHALT | ✓ |
| Fold in session_end closure | Add a session_end hook that closes open jobs deterministically — expands scope | |
| Fold in, observe-only first | Add the hook but only log/diagnose closures this phase | |

**User's choice:** Defer — keep phase narrow
**Notes:** Ships the high-value fix (reliable task markers) fast; session_end becomes its own phase/backlog item.

---

## Packaging & build format

| Option | Description | Selected |
|--------|-------------|----------|
| Prebuilt JS committed in-repo | Author in TS, build to a self-contained JS file (deps bundled), commit the artifact | |
| Ship TS, build on host | Ship .ts source; rely on host toolchain to compile — fragile | |
| Defer to research | Let researcher determine what shape `openclaw plugins install` consumes and pick most host-robust | ✓ |

**User's choice:** Defer to research
**Notes:** Strong lean toward the most host-robust shape (no build-on-host dependency), consistent with the v1.1 lesson behind the install-automation decision.

---

## Claude's Discretion

- Packaging / build format — research item (most host-robust shape `openclaw plugins install` consumes; lean prebuilt self-contained artifact).
- `maxAttempts` value (seed proposes 1) — planner may tune.
- Forced-pass `retry.instruction` wording + `idempotencyKey` — planner/researcher detail.
- `ctx.runId` stability across tool hooks + finalize hook, and `agent_end` cleanup semantics — researcher to confirm against the SDK/host.

## Deferred Ideas

- `session_end` deterministic job-closure hook — its own future phase.
- Per-turn job marker gating — rejected (over-fires).
- Carried-forward milestone candidates: JCLASS-01, JGUARD-01, JOUT-01, GRDEV-F1.
