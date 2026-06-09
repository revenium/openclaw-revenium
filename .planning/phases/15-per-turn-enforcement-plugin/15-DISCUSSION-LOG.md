# Phase 15: Per-Turn Enforcement Plugin - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-08
**Phase:** 15-per-turn-enforcement-plugin
**Areas discussed:** Guard directive content, Plugin packaging, Marker-gate sandbox adaptation, Install & validation gate

---

## Guard directive content

### Q1 — What should revenium-guard inject into every turn?

| Option | Description | Selected |
|--------|-------------|----------|
| Reuse BUDGET-GUARD.md verbatim | Inject exact BUDGET-GUARD.md (full halt/warn-and-ask branching); one source of truth; plugin stays pure/static | ✓ |
| Minimal pointer directive | Short "read status file per SKILL.md" pointer; smaller footprint but enforcement detail only in on-demand SKILL.md (spike-005 gap) | |
| Embed live status state | Plugin reads guardrail-status.json at hook time and injects resolved state; robust but fs I/O every turn (spike-006 hang surface) | |

**User's choice:** Reuse BUDGET-GUARD.md verbatim (D-01)
**Notes:** Identical enforcement semantics to standalone; single maintained directive for both paths.

### Q2 — How does BUDGET-GUARD.md text reach the plugin's prependContext?

| Option | Description | Selected |
|--------|-------------|----------|
| Inline at build time | Build step bakes the string into committed dist/index.js; pure/static, no hook-time fs; edits need rebuild+redeploy | ✓ |
| Read skill file at hook time | Plugin reads BUDGET-GUARD.md each turn; always in sync but fs I/O + hang/scanner surface | |

**User's choice:** Inline at build time (D-02)
**Notes:** Safest against spike-006 hang + install safety scanner; mirrors marker-gate's tsc/dist discipline.

### Q3 — Should the guard directive enforce staleness (Phase 14 D-05/D-06 hand-off)?

| Option | Description | Selected |
|--------|-------------|----------|
| Plugin appends stale clause (NemoClaw only) | Guard injects BUDGET-GUARD.md + a NemoClaw-only freshness clause; standalone untouched | |
| Add staleness to BUDGET-GUARD.md (both paths) | Edit BUDGET-GUARD.md itself; one source of truth; touches standalone enforcement contract | ✓ |
| Defer staleness to a later phase | Ship verbatim; reopen the deferred fail-safe-on-stale risk | |

**User's choice:** Add staleness to BUDGET-GUARD.md (D-03)
**Notes:** One directive for both paths. Flagged: standalone regression-test surface; must be a no-op when the freshness field is absent.

### Q4 — How does the agent decide the status is "too old"?

| Option | Description | Selected |
|--------|-------------|----------|
| Self-describing field in the status | Directive reads `_maxAgeSeconds` from the status; absent → skip check; path-agnostic | ✓ |
| Fixed threshold in the directive | Hardcoded constant; simplest but unaware of configured interval; brittle | |
| Derive from configured interval | Adaptive but agent has no clean way to read the cron interval at turn time | |

**User's choice:** Self-describing `_maxAgeSeconds` field (D-04)
**Notes:** Verified Phase 14's `nemoclaw-cron-tick.sh` already stamps `_maxAgeSeconds` (underscore prefix); standalone `guardrail-check.sh` does not write it → standalone unaffected. Directive reads exact field name `_maxAgeSeconds`.

---

## Plugin packaging

### Q1 — One plugin or two?

| Option | Description | Selected |
|--------|-------------|----------|
| Two separate plugins | revenium-guard + revenium-marker-gate reused as-is; matches roadmap phrasing; zero marker regression; two installs | |
| One combined plugin | Single revenium-enforcement with all four hooks; one install/trust/restart; diverges from standalone marker-gate | ✓ |

**User's choice:** One combined plugin (D-05)
**Notes:** Accepted the divergence risk, mitigated by Q2.

### Q2 — How to avoid duplicating Phase 11 marker logic?

| Option | Description | Selected |
|--------|-------------|----------|
| Reuse gate.js verbatim | Combined plugin imports existing plugin/src/gate.js unchanged, adds only before_prompt_build; one source of truth; Phase 11 tests still apply | ✓ |
| Fork the marker logic | Copy logic into combined plugin; reintroduces two-codebases-to-sync; not recommended | |

**User's choice:** Reuse gate.js verbatim (D-06)
**Notes:** gate.js stays single source of truth; standalone keeps its own thin wrapper. Planner note: combined manifest needs onStartup:true + allowConversationAccess:true.

---

## Marker-gate sandbox adaptation

### Q1 — How to handle in-sandbox runtime deps?

| Option | Description | Selected |
|--------|-------------|----------|
| Install-time preflight + live smoke | Deploy verbatim; hard-gate on python3 + deployed write-marker.sh + a smoke marker visible over the mount | ✓ |
| Deploy verbatim, trust the runtime | Less install work; silent "attribution never flows" on missing dep (spike-005 failure class) | |
| Remove the python3 dependency | Pure bash/jq rewrite of write-marker.sh; large blast radius on a hardened shared script; not recommended | |

**User's choice:** Install-time preflight + live smoke (D-07)
**Notes:** Confirmed gate.js is observe-only (returns a revise directive) and write-marker.sh writes a local markers/<sid>.jsonl (no revenium CLI/egress/SSL_CERT) — both path-agnostic via OPENCLAW_HOME=/sandbox/.openclaw. No plugin code adaptation needed.

### Q2 — Skill-deploy ordering (marker chain needs the skill, but skill install is Phase 16)

| Option | Description | Selected |
|--------|-------------|----------|
| Pull skill install into Phase 15 | Run `nemoclaw skill install` before the plugin step; Phase 16 = docs only; makes SC3 honestly verifiable here | ✓ |
| Assume skill already deployed | Document prerequisite; validate on 34.224.27.67 where the spike deployed it; install-path wiring waits for 16 | |
| Add explicit Phase 15→16 dependency | Reorder/split phases; cleaner boundaries but couples execution order, defers live SC3 to 16 | |

**User's choice:** Pull skill install into Phase 15 (D-08)
**Notes:** Order becomes 13 → 14 → 15a skill install → 15b plugin install → 15c preflight+smoke → 16 docs. Flag a ROADMAP/REQUIREMENTS note (NCDEPLOY-01 deploy step moves earlier).

---

## Install & validation gate

### Q1 — Install-time validation strictness

| Option | Description | Selected |
|--------|-------------|----------|
| Fail-hard with live sentinel turn-test | Install → trust → recover → real gateway turn asserts injection + plugins inspect; abort non-zero on failure | ✓ |
| Warn-and-continue (match standalone) | Mirror post-install.sh soft inspect; never abort; silently-inert plugin ships "successfully" | |

**User's choice:** Fail-hard with live turn-test (D-09)
**Notes:** Independent of the locked fail-OPEN runtime contract (SC4). Justified by NCENF-01 being the highest-risk requirement.

### Q2 — How does the turn-test detect injection?

| Option | Description | Selected |
|--------|-------------|----------|
| Check finalPromptText (prompt-side) | Wrap directive in `<revenium-guard>` tag; assert tag in finalPromptText; deterministic; real turns stay clean | ✓ |
| Require agent to echo sentinel (reply-side) | Spike's REVENIUM_GUARD_ACTIVE echo; pollutes every turn; conflates injection with model compliance | |

**User's choice:** Check finalPromptText prompt-side (D-10)
**Notes:** Reconciles with D-01 verbatim directive (no sentinel in BUDGET-GUARD.md). Supersedes the spike's reply-side sentinel.

### Q3 — How does the built plugin reach the sandbox?

| Option | Description | Selected |
|--------|-------------|----------|
| Via the Phase 14 share mount | Ensure mount, copy plugin to <mount>/extensions/revenium-enforcement/, then openclaw plugins install; reuses standing infra | ✓ |
| Via nemoclaw exec + tar copy | Stream dir over exec; self-contained, decoupled from mount state; separate delivery path to maintain | |

**User's choice:** Via the Phase 14 share mount (D-11)
**Notes:** Exactly the spike-006 layout; reuses Phase 14's mount-establish/self-heal helper.

---

## Claude's Discretion

- Combined plugin directory/name (e.g. `plugin-nemoclaw/`) and its tsc build config (inline BUDGET-GUARD.md + bundle gate.js → committed dist/index.js).
- Ledger idempotency keying for the real `install_enforcement_plugin()` replacing `stub_install_enforcement_plugin`.
- NemoClaw plugin-uninstall counterpart (model on `uninstall-nemoclaw-cron.sh`).
- Exact `recover`/restart invocation and the smoke-test mount handle source.

## Deferred Ideas

- Operator docs / prerequisites / macOS-unsupported note → Phase 16 (NCDEPLOY-02).
- Adding `_maxAgeSeconds` to standalone `guardrail-check.sh` → out of scope; revisit if standalone wants stale-protection.
- Removing python3 from `write-marker.sh` (pure bash/jq) → rejected; confirmed via preflight instead.
- Active degraded signal via one-shot `exec` → already deferred in Phase 14 in favor of the `_maxAgeSeconds` contract now consumed here.
