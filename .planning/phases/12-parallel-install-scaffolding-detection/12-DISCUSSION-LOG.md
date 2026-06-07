# Phase 12: Parallel Install Scaffolding & Detection - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-07
**Phase:** 12-parallel-install-scaffolding-detection
**Areas discussed:** Routing architecture, macOS refusal trigger & UX, Skeleton depth (vs Phase 13), Detection signals & idempotency

---

## Routing architecture

| Option | Description | Selected |
|--------|-------------|----------|
| New install.sh dispatcher | Thin top-level entry detects target, calls post-install.sh (standalone) or a new NemoClaw script; standalone file untouched | ✓ |
| Branch inside post-install.sh | Detection block early-routes within post-install.sh; risks regressing the standalone path | |
| Separate scripts, doc-routed | Operator runs the right script manually per README; no enforced detection | |

**User's choice:** New install.sh dispatcher
**Notes:** Keeps post-install.sh byte-stable as the untouched standalone path (protects SC2).

### Both-homes precedence

| Option | Description | Selected |
|--------|-------------|----------|
| Require explicit --nemoclaw flag | Default to standalone; only take NemoClaw path with --nemoclaw / NEMOCLAW=1 | ✓ |
| Auto-prefer NemoClaw | Take NemoClaw path automatically when ~/.nemoclaw + Docker + Linux present | |
| Prompt the operator | Interactively ask; breaks non-interactive/detached install | |

**User's choice:** Require explicit --nemoclaw flag (when both homes exist)

---

## macOS refusal trigger & UX

### NemoClaw path trigger

| Option | Description | Selected |
|--------|-------------|----------|
| Flag-only, always | NemoClaw path only with --nemoclaw, regardless of detected dirs | |
| Auto when only ~/.nemoclaw | Auto-take NemoClaw path when ~/.nemoclaw present and ~/.openclaw absent; flag still needed when both exist | ✓ |

**User's choice:** Auto when only ~/.nemoclaw (flag still required when both homes exist)

### Refusal trigger

| Option | Description | Selected |
|--------|-------------|----------|
| Only when NemoClaw requested | macOS + (flag or detected NemoClaw target) → refuse; macOS standalone still works | ✓ |
| Any macOS NemoClaw signal | Refuse on any nemoclaw artifact; a stray ~/.nemoclaw would block standalone too | |

**User's choice:** Only when NemoClaw requested

### Refusal message

| Option | Description | Selected |
|--------|-------------|----------|
| Explain + point to a Linux host | macOS unsupported (Linux-only stack), call out the Darwin graceful-skip trap, direct to Linux+Docker host | ✓ |
| Terse one-liner | Just the message + exit 1 | |
| Suggest standalone instead | Refuse, then suggest dropping --nemoclaw to run standalone | |

**User's choice:** Explain + point to a Linux host

---

## Skeleton depth (vs Phase 13)

### Depth

| Option | Description | Selected |
|--------|-------------|----------|
| Detect + preflight, stub the rest | Routing + Linux/Docker gate + macOS refusal + host preflight probe; provisioning stubbed as Phase 13+ | ✓ |
| Detect + route only | Routing + refusal + hello-world skeleton; preflight defers to Phase 13 | |
| Detect + preflight + dir scaffolding | Option 1 plus sandbox-side dir scaffolding; reaches into Phase 13 concerns | |

**User's choice:** Detect + preflight, stub the rest

### Preflight gate strength

| Option | Description | Selected |
|--------|-------------|----------|
| Hard gate on fail, warn on caveats | OS/Docker FAIL → exit non-zero; RAM/disk/GPU WARN → continue (spike script's contract) | ✓ |
| Fully advisory | Run probe, print, never block | |
| Skip the probe in Phase 12 | Only relevant if 'route only' chosen | |

**User's choice:** Hard gate on fail, warn on caveats

### Probe location

| Option | Description | Selected |
|--------|-------------|----------|
| Copy into scripts/ | First-class install-time script; spike sources aren't shipped with the skill | ✓ |
| Inline into install.sh | Fold checks into dispatcher; loses reusability + clean exit-code contract | |

**User's choice:** Copy into scripts/

---

## Detection signals & idempotency

### Detection signals

| Option | Description | Selected |
|--------|-------------|----------|
| ~/.nemoclaw dir is the identity signal | Dir presence routes; nemoclaw CLI + Linux + Docker are capability checks owned by the probe | ✓ |
| Require dir AND nemoclaw CLI | Both must be present; partially-installed host wouldn't route | |
| nemoclaw CLI is the signal | command -v nemoclaw as primary signal; PATH timing makes it flaky post-install | |

**User's choice:** ~/.nemoclaw dir is the identity signal

### Idempotency

| Option | Description | Selected |
|--------|-------------|----------|
| command_exists guards + safe re-checks | Mirror post-install.sh idiom; read-only detection/preflight; no ledger at skeleton stage | ✓ |
| Add a ledger now | revenium-nemoclaw.ledger like the metering ledgers; more machinery than the skeleton needs | |

**User's choice:** command_exists guards + safe re-checks

---

## Claude's Discretion

- Exact NemoClaw path script filename, flag/env surface beyond `--nemoclaw`/`NEMOCLAW=1`, stub function naming, and exact wording of the macOS refusal + `Phase 13+` stub notices.
- How detection logic is unit-tested on a non-Linux dev machine (env/path overrides or mocked checks) within existing `tests/` conventions.

## Deferred Ideas

- Sandbox provisioning (egress, in-sandbox CLI) → Phase 13.
- Host-side metering loop → Phase 14.
- Per-turn enforcement plugin → Phase 15.
- Skill deploy + docs → Phase 16.
- `revenium-nemoclaw.ledger` for exactly-once provisioning gating → Phase 13+.
