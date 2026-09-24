# Phase 12: Parallel Install Scaffolding & Detection - Context

**Gathered:** 2026-06-07
**Status:** Ready for planning

<domain>
## Phase Boundary

A detection gate in the install tooling that routes between three targets:
1. **Linux + NemoClaw** → the new parallel install path (skeletal but gated this phase)
2. **Standalone OpenClaw** (no `~/.nemoclaw/`) → the existing `post-install.sh` path, unchanged — no regression
3. **macOS requesting NemoClaw** → an explicit refusal with non-zero exit (not a silent no-op)

The NemoClaw path this phase is a **skeleton**: routing + macOS refusal + host preflight are real and testable; sandbox provisioning (egress, in-sandbox CLI, host-side metering loop, enforcement plugin) are **stubbed** functions deferred to Phases 13–16.

**Consumes:** NCINST-01, NCINST-02.

</domain>

<decisions>
## Implementation Decisions

### Routing architecture
- **D-01:** Add a new thin top-level dispatcher script — `install.sh` — that detects the target and routes. It does NOT replace `post-install.sh`; the existing `post-install.sh` remains the untouched standalone path (protects SC2 / no regression).
- **D-02:** The NemoClaw path lives in a separate script (e.g. `post-install-nemoclaw.sh`), invoked by the dispatcher — not a branch inside `post-install.sh`. Keep the standalone file byte-stable.
- **D-03:** Trigger model for entering the NemoClaw path:
  - `--nemoclaw` flag (or `NEMOCLAW=1` env) is passed, **OR**
  - `~/.nemoclaw/` is present **and** `~/.openclaw/` is absent (auto-detect a NemoClaw-only host).
  - When **both** `~/.openclaw/` and `~/.nemoclaw/` exist → require the explicit `--nemoclaw` flag; default to standalone otherwise.
  - No flag + standalone-only (or neither dir) → standalone path.
- **D-04:** Dispatcher must work non-interactively / detached (spike 001 runs installs via `setsid … </dev/null`). No interactive prompt for path selection — disambiguation is the explicit flag, not a question.

### macOS refusal (NCINST-02)
- **D-05:** The macOS refusal fires **only when the NemoClaw path would be entered** on macOS (i.e. `--nemoclaw` passed, or a NemoClaw target auto-detected). macOS **without** any NemoClaw signal continues to run the standalone path normally — do not break the existing mac standalone install.
- **D-06:** On refusal: print an explanatory message (macOS is unsupported — NemoClaw/OpenShell is a Linux-only stack; call out that NemoClaw's own installer graceful-skips on Darwin, which falsely looks like success while never provisioning the sandbox; direct the operator to a Linux + Docker host) and **exit non-zero**.

### Skeleton depth (Phase 12 vs Phase 13 boundary)
- **D-07:** Phase 12 NemoClaw path does: routing + Linux/Docker gate + macOS refusal + **host preflight probe** (RAM/disk/Docker-reachable/GPU). Sandbox provisioning steps (egress `policy-add`, in-sandbox revenium CLI delivery, host-side metering loop, `before_prompt_build` plugin) are **stub functions that print a `Phase 13+` notice** and return cleanly. No provisioning, no sandbox-side dir scaffolding this phase.
- **D-08:** Reuse `probe-host-compat.sh`'s contract as the gate: OS/Docker **FAIL → exit non-zero and stop**; RAM/disk/GPU/Node **WARN → print and continue**. Mirrors the spike script's existing exit codes (1 on fail, 0 on warn).
- **D-09:** Copy `probe-host-compat.sh` into `scripts/` as a first-class, install-time script (the spike-findings skill `sources/` are not shipped with the skill, so the probe must be present on the target at install time). Keep it standalone (not inlined) to preserve its reusability and clean exit-code contract.

### Detection signals & idempotency
- **D-10:** **Identity vs capability split.** `~/.nemoclaw/` directory presence = the *identity* signal that routes ("this is a NemoClaw host"), mirroring the existing `~/.openclaw/` detection. The `nemoclaw` CLI on PATH + Linux kernel + Docker reachable = *capability* checks owned by the preflight probe (hard gate). The dir routes; the probe validates.
- **D-11:** Idempotency via the existing `post-install.sh` idiom: `command_exists`-guarded actions + warn-and-continue when already done. Detection and preflight are read-only (naturally idempotent); stubs do nothing. **No ledger** at the skeleton stage — a `revenium-nemoclaw.ledger` can be introduced in Phase 13+ when real provisioning steps need exactly-once gating.

### Claude's Discretion
- Exact filename of the NemoClaw path script (`post-install-nemoclaw.sh` suggested), the precise flag/env surface beyond `--nemoclaw`/`NEMOCLAW=1`, stub function naming, and the exact wording of the macOS refusal and `Phase 13+` stub notices.
- How detection logic is unit-tested on a non-Linux dev machine (e.g. env/path overrides or mocked `uname`/dir checks) — planner/researcher to determine; the existing `tests/` hermetic-harness conventions apply.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Spike findings (primary build basis)
- `.claude/skills/spike-findings-openclaw-revenium/references/install-and-bootstrap.md` — Linux-only gate, non-interactive env-var install, detached `setsid` to avoid apt SIGTTIN, the Darwin graceful-skip trap, host config at `~/.nemoclaw/`, CLI on `~/.local/bin`. **The core Phase 12 reference.**
- `.claude/skills/spike-findings-openclaw-revenium/sources/001-nemoclaw-bootstrap/probe-host-compat.sh` — the non-destructive host compatibility probe to copy into `scripts/`; defines the OS/Docker/RAM/disk/GPU checks and exit-code contract (1=fail, 0=warn/pass).
- `.claude/skills/spike-findings-openclaw-revenium/SKILL.md` — requirements + spike-verdict index; the non-negotiable constraints list.

### Phase scope
- `.planning/ROADMAP.md` § Phase 12 — goal + 4 success criteria.
- `.planning/REQUIREMENTS.md` — NCINST-01 (parallel install path, standalone untouched), NCINST-02 (detect Linux+Docker target, refuse macOS explicitly).

### Existing code to preserve / extend
- `scripts/post-install.sh` — the current install entry point and the standalone path (macOS/Homebrew-centric); must stay untouched / regression-free. Establishes the `info/warn/step/fail` + `command_exists` idioms to mirror.
- `scripts/common.sh`, `scripts/install-cron.sh` — shared helpers + cron install conventions.
- `tests/` — hermetic bash/python test harness conventions for the detection/refusal logic.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `probe-host-compat.sh` (spike sources): ready-made, non-destructive Linux/Docker/RAM/disk/GPU probe with a fail/warn exit-code contract — copy into `scripts/` and use as the preflight hard gate.
- `post-install.sh` helper idioms (`info`/`warn`/`step`/`fail`, `command_exists`): reuse verbatim in `install.sh` + the NemoClaw path script for consistent UX and idempotency.

### Established Patterns
- `command_exists`-guarded, warn-and-continue idempotency (no auto-restart, warn-and-note) — the project-wide install pattern; the skeleton follows it instead of introducing a ledger.
- `set -euo pipefail` discipline across all scripts.
- macOS/Homebrew assumptions live entirely in `post-install.sh` — the NemoClaw path must NOT inherit them (it's Linux + prebuilt-tarball, per later phases).

### Integration Points
- New `install.sh` dispatcher becomes the documented single entry point; `post-install.sh` becomes one of its two routed targets (standalone). README/ClawHub install instructions will reference `install.sh` (doc update lands in Phase 16).

</code_context>

<specifics>
## Specific Ideas

- The macOS refusal must explicitly name the "Darwin graceful-skip = false success" trap in its message — this is the exact failure mode the requirement (NCINST-02) exists to prevent.
- Trigger precedence is deliberately asymmetric: a NemoClaw-only host auto-routes (no flag needed), but a dual-home host requires the explicit `--nemoclaw` flag to avoid hijacking an existing standalone install.

</specifics>

<deferred>
## Deferred Ideas

- **Sandbox provisioning** (egress `policy-add`, in-sandbox revenium CLI tarball delivery, `SSL_CERT_FILE`/`REVENIUM_*` wiring) — Phase 13 (NCEGRESS-01, NCCLI-01/02). Stubbed this phase.
- **Host-side metering loop** (`nemoclaw share mount` + host cron refreshing `guardrail-status.json`) — Phase 14 (NCMETER-01).
- **Per-turn enforcement plugin** (`before_prompt_build`, authored from `openclaw plugins init` scaffold) — Phase 15 (NCENF-01/02), flagged highest-risk.
- **Skill deploy via `nemoclaw skill install` + docs/README update** — Phase 16 (NCDEPLOY-01/02).
- **`revenium-nemoclaw.ledger`** for exactly-once provisioning gating — introduce in Phase 13+ when real provisioning steps exist; not needed for the read-only skeleton.

</deferred>

---

*Phase: 12-parallel-install-scaffolding-detection*
*Context gathered: 2026-06-07*
