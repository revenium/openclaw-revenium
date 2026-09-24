# Phase 12: Parallel Install Scaffolding & Detection — Research

**Researched:** 2026-06-07
**Domain:** Bash install dispatcher / host detection / NemoClaw bootstrap
**Confidence:** HIGH (pre-spiked; primary evidence from live experiments on 34.224.27.67)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Add a new thin top-level dispatcher script — `install.sh` — that detects the target and routes. It does NOT replace `post-install.sh`; the existing `post-install.sh` remains the untouched standalone path.
- **D-02:** The NemoClaw path lives in a separate script (e.g. `post-install-nemoclaw.sh`), invoked by the dispatcher — not a branch inside `post-install.sh`. Keep the standalone file byte-stable.
- **D-03:** Trigger model: `--nemoclaw` flag OR `NEMOCLAW=1` env → NemoClaw path. `~/.nemoclaw/` present AND `~/.openclaw/` absent → auto-detect NemoClaw-only host. Both dirs present → require explicit `--nemoclaw` flag; default to standalone otherwise. No flag + standalone-only or neither dir → standalone path.
- **D-04:** Dispatcher must work non-interactively / detached — no interactive prompt for path selection.
- **D-05:** macOS refusal fires ONLY when NemoClaw path would be entered on macOS. macOS without NemoClaw signal continues the standalone path normally.
- **D-06:** On macOS+NemoClaw refusal: print explanatory message naming the Darwin graceful-skip trap; exit non-zero.
- **D-07:** Phase 12 NemoClaw path does routing + Linux/Docker gate + macOS refusal + host preflight probe. Sandbox provisioning steps are stub functions printing a `Phase 13+` notice, returning cleanly.
- **D-08:** Preflight gate contract: OS/Docker FAIL → exit non-zero and stop. RAM/disk/GPU/Node WARN → print and continue.
- **D-09:** Copy `probe-host-compat.sh` into `scripts/` as a first-class install-time script. Keep it standalone (not inlined).
- **D-10:** `~/.nemoclaw/` directory presence = identity signal that routes. `nemoclaw` CLI + Linux + Docker = capability checks owned by the preflight probe.
- **D-11:** Idempotency via `command_exists`-guarded actions + warn-and-continue. No ledger at skeleton stage.

### Claude's Discretion

- Exact filename of the NemoClaw path script (`post-install-nemoclaw.sh` suggested), the precise flag/env surface beyond `--nemoclaw`/`NEMOCLAW=1`, stub function naming, exact wording of the macOS refusal and `Phase 13+` stub notices.
- How detection logic is unit-tested on a non-Linux dev machine.

### Deferred Ideas (OUT OF SCOPE)

- Sandbox provisioning (egress `policy-add`, in-sandbox revenium CLI tarball delivery, `SSL_CERT_FILE`/`REVENIUM_*` wiring) — Phase 13.
- Host-side metering loop (`nemoclaw share mount` + host cron) — Phase 14.
- Per-turn enforcement plugin (`before_prompt_build`) — Phase 15.
- Skill deploy via `nemoclaw skill install` + docs/README update — Phase 16.
- `revenium-nemoclaw.ledger` for exactly-once provisioning gating — Phase 13+.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| NCINST-01 | Operator can install onto a NemoClaw/OpenShell target via a parallel install path that leaves the standalone path untouched | Dispatcher architecture (D-01/D-02), byte-stability of `post-install.sh`, routing logic (D-03) |
| NCINST-02 | The install path detects a NemoClaw/OpenShell target (Linux+Docker) and refuses explicitly on macOS rather than silently no-opping | macOS refusal pattern (D-05/D-06), Darwin graceful-skip trap naming, non-zero exit |
</phase_requirements>

---

## Summary

Phase 12 is a pure bash scripting phase with no new external dependencies. The work is almost entirely predetermined by 12-CONTEXT.md decisions (D-01 through D-11) and the spike-findings skill, which contains live-validated patterns from host 34.224.27.67. The primary risk is not "what to build" — that is fully specified — but "how to test it hermetically on a macOS dev machine without a Linux+NemoClaw target."

The three deliverables are: (1) `scripts/install.sh` — the thin dispatcher; (2) `scripts/post-install-nemoclaw.sh` — the NemoClaw path skeleton; (3) `scripts/probe-host-compat.sh` — copied verbatim from spike sources. The detection/routing logic is the most structurally interesting piece because it uses environment overrides that make it directly testable without a real NemoClaw host.

The existing `tests/` harness is a bash-native pattern (no test framework, `PASS`/`FAIL` counters, `mktemp` for isolation, env-var overrides for stub injection) that translates directly to testing the new dispatcher and NemoClaw skeleton.

**Primary recommendation:** Implement the dispatcher using env-variable overrides for `uname`, `HOME`, and dir-existence checks so all routing branches can be exercised hermetically in `tests/test_install_dispatcher.sh` on the macOS dev machine — exactly the same pattern the existing test suite uses to stub `revenium`.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Target detection (OS, dirs, flags) | Install Dispatcher (`install.sh`) | — | Pure routing; must be stateless + testable |
| macOS refusal | Install Dispatcher (`install.sh`) | — | Fires before invoking any path script; early exit |
| Host preflight (OS/Docker/RAM/disk) | Preflight probe (`probe-host-compat.sh`) | NemoClaw path invokes it | Standalone script with exit-code contract; reusable |
| Standalone install | `post-install.sh` (existing, unmodified) | — | Byte-stable per D-01/D-02 |
| NemoClaw path skeleton | `post-install-nemoclaw.sh` (new) | — | Receives control from dispatcher after preflight passes |
| Stub functions (Phase 13+ deferred) | `post-install-nemoclaw.sh` | — | Print notice, return 0 — no real work this phase |
| Idempotency | `post-install-nemoclaw.sh` | `probe-host-compat.sh` (read-only) | `command_exists` guard + warn-and-continue; no ledger |

---

## Standard Stack

### Core

No new external libraries. This phase is pure bash.

| Script | Source | Purpose |
|--------|--------|---------|
| `scripts/install.sh` | New (authored this phase) | Thin dispatcher: detects target, routes to `post-install.sh` or `post-install-nemoclaw.sh` |
| `scripts/post-install-nemoclaw.sh` | New (authored this phase) | NemoClaw path skeleton; all provisioning steps are stubs |
| `scripts/probe-host-compat.sh` | Copied from `.claude/skills/spike-findings-openclaw-revenium/sources/001-nemoclaw-bootstrap/probe-host-compat.sh` | Host preflight: OS/Docker/RAM/disk/GPU/Node checks with fail/warn exit-code contract |
| `scripts/post-install.sh` | Existing — MUST NOT BE MODIFIED | Standalone path (macOS/Homebrew-centric) |
| `scripts/common.sh` | Existing — read-only reference | Helper idioms to mirror |

### Supporting

| Idiom | Source | Purpose |
|-------|--------|---------|
| `info`/`warn`/`step`/`fail` | `post-install.sh` lines 34–37 | Consistent UX output; mirror in `install.sh` and `post-install-nemoclaw.sh` |
| `command_exists` | `post-install.sh` line 39 | Idempotency guard; mirror verbatim |
| `set -euo pipefail` | All existing scripts | Error discipline; required in new scripts |
| `NEMOCLAW_NON_INTERACTIVE=1` env | `install-and-bootstrap.md` | Non-interactive install env var from spike — confirms detached operation pattern |
| `setsid … </dev/null` pattern | `install-and-bootstrap.md` | Avoids apt SIGTTIN in detached runs; documented constraint for D-04 |

### No Alternatives Considered

All choices are locked by CONTEXT.md decisions. There are no discretion-area stack choices to make for this phase.

---

## Package Legitimacy Audit

> **Not applicable.** Phase 12 installs zero external packages — it is pure bash. No `npm install`, `pip install`, or equivalent is performed.

---

## Architecture Patterns

### System Architecture Diagram

```
Operator runs: bash install.sh [--nemoclaw] [--skip-prereqs]
        │
        ▼
┌─────────────────────────────────────────────────────────┐
│  install.sh — Dispatcher                                │
│                                                         │
│  1. Parse flags: --nemoclaw, NEMOCLAW=1 env             │
│  2. Detect dirs: ~/.nemoclaw/, ~/.openclaw/             │
│  3. Determine target via routing precedence (D-03)      │
│                                                         │
│  Routing decision ──────────────────────────────────┐  │
│     NEMOCLAW path?                                   │  │
│       └─ is macOS? ──► REFUSE + exit 1              │  │
│       └─ is Linux? ──► probe-host-compat.sh         │  │
│                             │ FAIL ──► exit 1        │  │
│                             │ WARN/PASS ──► nemoclaw │  │
│                             │              path ──┐  │  │
│     STANDALONE path? ──────────────────────────── ┼ ─┘  │
└────────────────────────────────────────────────── ┼ ────┘
                                                    │
          ┌─────────────────────────────────────────┤
          │                                         │
          ▼                                         ▼
  post-install-nemoclaw.sh                  post-install.sh
  (NemoClaw path skeleton)                  (standalone path — UNCHANGED)
  │
  ├─ step "Checking NemoClaw CLI"     (command_exists nemoclaw → warn+continue)
  ├─ stub_provision_egress_policy()   (Phase 13 — prints notice, returns 0)
  ├─ stub_deliver_revenium_cli()      (Phase 13 — prints notice, returns 0)
  ├─ stub_install_metering_loop()     (Phase 14 — prints notice, returns 0)
  └─ stub_install_enforcement_plugin()(Phase 15 — prints notice, returns 0)
```

### Recommended Project Structure

```
scripts/
├── install.sh              # NEW — thin dispatcher (entry point)
├── post-install-nemoclaw.sh # NEW — NemoClaw path skeleton
├── probe-host-compat.sh    # NEW (copied from spike sources)
├── post-install.sh         # EXISTING — standalone path, byte-stable
├── common.sh               # EXISTING — shared helpers
└── install-cron.sh         # EXISTING — cron installer

tests/
├── test_install_dispatcher.sh   # NEW — routing + macOS refusal + idempotency
├── stub-revenium.sh             # EXISTING
└── ... (existing tests unchanged)
```

### Pattern 1: Dispatcher Routing Logic

**What:** `install.sh` determines which path to run using three signals in strict precedence.

**Exact routing precedence (D-03):**

```bash
# Source: CONTEXT.md D-03 (locked decision)
# Priority 1: Explicit flag or env
if [[ "${NEMOCLAW_FLAG}" == true ]] || [[ "${NEMOCLAW:-}" == "1" ]]; then
    TARGET="nemoclaw"
# Priority 2: NemoClaw-only host (identity dir present, standalone absent)
elif [[ -d "${HOME}/.nemoclaw" ]] && [[ ! -d "${HOME}/.openclaw" ]]; then
    TARGET="nemoclaw"
# Priority 3: Dual-home → require explicit flag; default to standalone
elif [[ -d "${HOME}/.nemoclaw" ]] && [[ -d "${HOME}/.openclaw" ]]; then
    TARGET="standalone"   # no explicit flag → standalone (D-03)
# Priority 4: No NemoClaw signal → standalone
else
    TARGET="standalone"
fi
```

**When to use:** This exact precedence is locked; implement it verbatim.

**Testability:** Override `HOME` to a `mktemp -d` dir, create or omit `.nemoclaw/` and `.openclaw/` subdirs, set or unset `NEMOCLAW=1` / `--nemoclaw` flag. All four branches are fully exercisable on macOS.

### Pattern 2: macOS Refusal (D-05/D-06)

**What:** Fire ONLY after routing resolves to NemoClaw path AND `uname -s` returns Darwin.

**Contract:** Print an explanatory message that explicitly names the Darwin graceful-skip trap. Exit non-zero.

**Why the message must name the trap:** The entire reason NCINST-02 exists is to prevent operators from believing a successful run happened when NemoClaw's own installer silently skipped on macOS. The error message is a user-safety requirement, not just polish.

```bash
# Source: CONTEXT.md D-06, spike-findings SKILL.md requirements section
if [[ "$(uname -s)" == "Darwin" ]]; then
    fail "NemoClaw is unsupported on macOS.

  NemoClaw/OpenShell is a Linux-only stack. IMPORTANT: NemoClaw's own
  installer graceful-skips on Darwin (exits 0 without provisioning the
  sandbox) — this looks like success but never installs anything.

  To run the NemoClaw path, use a Linux host (bare-metal, VM, or cloud)
  with Docker. AWS/GCP/Azure Ubuntu instances are confirmed targets.

  The standalone OpenClaw path (default) continues to work on macOS."
    exit 1
fi
```

**Testability:** Wrap the `uname -s` call so `STUB_UNAME_S` env var overrides the return value. Test runner sets `STUB_UNAME_S=Darwin` to simulate macOS from a Linux CI runner, or vice versa.

```bash
# In install.sh — testable OS detection
_os="${STUB_UNAME_S:-$(uname -s)}"
if [[ "${_os}" == "Darwin" ]]; then ...
```

**Important:** macOS WITHOUT a NemoClaw signal (no flag, no `~/.nemoclaw/`, `NEMOCLAW` unset) must NOT fire this refusal — it falls through to `post-install.sh`. This is D-05.

### Pattern 3: Preflight Probe Integration (D-08/D-09)

**What:** `post-install-nemoclaw.sh` calls `probe-host-compat.sh` as the first action after macOS check passes. The probe's exit-code contract controls whether install continues.

**Exit-code contract (from `probe-host-compat.sh` lines 121–131):**
- `exit 1` → OS is non-Linux or Docker absent on non-Linux → hard fail → `post-install-nemoclaw.sh` must propagate non-zero exit.
- `exit 0` with warnings → RAM/disk/GPU/Node warn → continue install.
- `exit 0` clean → all checks passed.

```bash
# Source: probe-host-compat.sh contract (D-08)
PROBE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/probe-host-compat.sh"

step "Running host compatibility preflight"
if ! bash "${PROBE_SCRIPT}"; then
    fail "Host compatibility check failed — NemoClaw requires Linux + Docker."
fi
info "Preflight passed (warnings above are non-blocking)"
```

**Why keep it standalone (not inlined):** The probe has its own `set -u` and a clean exit-code contract. Inlining would entangle its `pass`/`warn`/`fail` counter variables with the parent script. Standalone = testable in isolation, reusable in Phase 13+.

**Note on Docker on Linux:** The probe treats missing Docker on Linux as `wn` (warn), not `no` (fail), because NemoClaw's installer can provision Docker. This is correct per `probe-host-compat.sh` lines 64–66.

### Pattern 4: Stub Functions (D-07)

**What:** Phase 13–16 provisioning steps are represented as named stub functions that print a notice and return 0.

**Naming convention (Claude's discretion — recommended):**
```bash
# Source: CONTEXT.md D-07
stub_provision_egress_policy() {
    warn "Phase 13+: egress policy provisioning not yet implemented — skipping."
}

stub_deliver_revenium_cli() {
    warn "Phase 13+: in-sandbox revenium CLI delivery not yet implemented — skipping."
}

stub_install_metering_loop() {
    warn "Phase 14+: host-side metering loop not yet implemented — skipping."
}

stub_install_enforcement_plugin() {
    warn "Phase 15+: per-turn enforcement plugin not yet implemented — skipping."
}
```

**Why named functions, not inline comments:** Named functions give the planner a concrete insertion point — Phase 13 replaces `stub_provision_egress_policy()` with real implementation. The stub structure makes the phase boundary explicit and testable.

**Idempotency:** Stubs always return 0 with no side effects. Running `post-install-nemoclaw.sh` twice produces identical output — this is the natural idempotency of Phase 12 (D-11).

### Pattern 5: `command_exists` Idempotency Guard

**What:** Follow `post-install.sh`'s existing idiom for idempotency — check before acting, warn-and-continue if already done.

```bash
# Mirror of post-install.sh line 39 — use verbatim in new scripts
command_exists() { command -v "$1" &>/dev/null; }

# Example guard in post-install-nemoclaw.sh
step "Checking NemoClaw CLI"
if command_exists nemoclaw; then
    info "nemoclaw CLI found: $(command -v nemoclaw)"
else
    warn "nemoclaw CLI not found on PATH — is ~/.local/bin in PATH?"
    warn "NemoClaw installs its CLI at ~/.local/bin. Add to PATH: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
```

**Note:** `~/.local/bin` is where NemoClaw installs the `nemoclaw` CLI (confirmed in `install-and-bootstrap.md` Constraints section). The probe already checks this as an informational item via the Node.js check.

### Anti-Patterns to Avoid

- **Modifying `post-install.sh` in any way.** Even adding a comment or fixing whitespace breaks the "byte-stable" guarantee. The dispatcher invokes it unmodified.
- **Interactive prompts in the dispatcher.** D-04 explicitly forbids this. `setsid … </dev/null` detached runs would hang waiting for input.
- **Firing the macOS refusal on standalone-path invocations.** D-05: macOS + no NemoClaw signal = standalone path continues normally. Only when the NemoClaw target is selected does the OS check fire.
- **Calling `uname -s` without a stub override variable.** Makes the routing test suite platform-dependent. Always use `_os="${STUB_UNAME_S:-$(uname -s)}"`.
- **Checking `~/.nemoclaw/` existence relative to a hardcoded path.** Use `${HOME}/.nemoclaw` so env-override testing (`HOME=$(mktemp -d)`) works.
- **Inlining `probe-host-compat.sh`.** The probe has its own variable namespace (`pass`, `warn`, `fail` counters). Sourcing it would collide with the parent script's `fail()` function.
- **Setting `set -e` in common.sh.** The file comment warns against this (it's a sourced library). New scripts that source helpers must own their own `set -euo pipefail`.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Host OS/Docker/RAM/disk/GPU checks | Custom detection logic | `probe-host-compat.sh` (spike source) | Already validated on live host; correct exit-code contract for Docker-on-Linux (warn, not fail); handles `/proc/meminfo` vs macOS `sysctl` correctly |
| Idempotency ledger | `revenium-nemoclaw.ledger` or custom state file | `command_exists` guard + warn-and-continue | D-11 explicitly defers ledger to Phase 13; skeleton is naturally idempotent |
| PATH extension in detached context | Custom PATH probe | Mirror `install-cron.sh` lines 70–83 pattern | Existing logic already handles Homebrew + `~/.local/bin` breadth |

**Key insight:** The spike delivered a working probe script that encodes all the platform detection subtleties. Copying it is strictly correct; rewriting it risks introducing regressions.

---

## Common Pitfalls

### Pitfall 1: Darwin Graceful-Skip Misunderstanding
**What goes wrong:** Developer tests the macOS refusal by running `install.sh --nemoclaw` on macOS and sees a non-zero exit. But they also run `install.sh` (no flag) on macOS with `~/.nemoclaw/` present and expect it to auto-detect NemoClaw — but the routing logic (D-03) requires BOTH: no `--nemoclaw` flag AND only `~/.nemoclaw/` present (no `~/.openclaw/`). If both dirs exist on the test machine, the router defaults to standalone silently.
**Why it happens:** Developer misreads D-03 dual-home case — both dirs present requires explicit flag.
**How to avoid:** Test all four D-03 branches explicitly in `test_install_dispatcher.sh` with separate `mktemp -d` HOME setups.
**Warning signs:** macOS refusal not firing when expected; standalone path running when NemoClaw expected.

### Pitfall 2: `probe-host-compat.sh` `fail()` Function Collision
**What goes wrong:** `post-install-nemoclaw.sh` defines `fail()` (matching `post-install.sh` line 37). If `probe-host-compat.sh` is sourced (`. "${PROBE_SCRIPT}"`) instead of executed (`bash "${PROBE_SCRIPT}"`), the probe's `no()` function would not conflict — but the probe's exit 1 would terminate the sourcing script immediately, bypassing the parent's error handling.
**Why it happens:** Sourcing vs executing a subshell — different exit-code propagation semantics.
**How to avoid:** Always invoke the probe as `bash "${PROBE_SCRIPT}"` (subprocess), never `. "${PROBE_SCRIPT}"`. Check exit code with `if ! bash ...`.
**Warning signs:** Install exits unexpectedly after preflight; `pass`/`warn`/`fail` counter variables leaking into parent scope.

### Pitfall 3: `set -euo pipefail` + Probe Warn Path
**What goes wrong:** `post-install-nemoclaw.sh` uses `set -euo pipefail`. The probe exits 0 on warnings — but intermediate commands inside the probe script itself might trigger early exit. If `probe-host-compat.sh` is run in a subshell with `set -e` inherited, the probe's `wn` calls (which end with `warn=$((warn+1))`) return 0, so this is not an issue. The probe uses `set -u` not `set -e`.
**Why it happens:** `set -euo pipefail` in parent; probe uses only `set -u`.
**How to avoid:** The probe is explicitly `set -u` only (line 16 of source). No `set -e`. Running it as `bash "${PROBE_SCRIPT}"` gives it its own subshell with only `set -u`. No issue in practice, but implementer should verify probe's shebang/set line is preserved when copying.
**Warning signs:** Probe exits 1 unexpectedly on a warn-only host.

### Pitfall 4: Non-Interactive Detached Runs and `read` in Dispatcher
**What goes wrong:** The dispatcher or NemoClaw skeleton contains a `read` call (e.g., for autonomousMode like `post-install.sh` step 6 uses). When run detached via `setsid … </dev/null`, `read` gets immediate EOF and sets the variable to empty, producing silent wrong defaults.
**Why it happens:** `post-install.sh` already handles this (lines 484–490: checks `if [[ -t 0 && -t 1 ]]`). If the new scripts copy `post-install.sh` patterns without copying this guard, they regress.
**How to avoid:** The NemoClaw skeleton has no interactive steps this phase (all provisioning is stubbed). `install.sh` must not prompt. Verify no `read` calls exist in new scripts.
**Warning signs:** Config seeded with wrong defaults; install silently exits early in detached cron context.

### Pitfall 5: `post-install.sh` Byte-Stability Verification
**What goes wrong:** During wave review, someone notices a minor issue in `post-install.sh` and "fixes" it as part of this PR. The standalone-path regression test (success criterion 2) should catch this, but only if the test actually compares file contents or runs `post-install.sh` in isolation.
**Why it happens:** Scope creep during implementation.
**How to avoid:** In the test suite, add a `sha256sum` or `md5sum` check against the expected hash of `post-install.sh` — or at minimum assert that no file modifications were made to it.
**Warning signs:** git diff shows `scripts/post-install.sh` in the changed files list.

### Pitfall 6: PATH Not Including `~/.local/bin` for `nemoclaw` CLI Check
**What goes wrong:** `command_exists nemoclaw` returns false even on a correctly installed NemoClaw host because `~/.local/bin` is not in PATH in the install context.
**Why it happens:** `install-and-bootstrap.md` notes the CLI lives at `~/.local/bin`. NemoClaw installs it there, but `~/.local/bin` is not in the default system PATH on many Linux distros.
**How to avoid:** In `post-install-nemoclaw.sh`, call `ensure_path` (or inline the `~/.local/bin` addition) before `command_exists nemoclaw`. Mirror the `install-cron.sh` CRON_PATH construction pattern.
**Warning signs:** `command_exists nemoclaw` fails on a freshly installed host; `warn` fires unnecessarily.

---

## Code Examples

### Dispatcher Skeleton

```bash
#!/usr/bin/env bash
# scripts/install.sh — Revenium OpenClaw Skill: Parallel Install Dispatcher
# Source: CONTEXT.md D-01/D-02/D-03/D-04
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()  { echo "  ✓ $*"; }
warn()  { echo "  ⚠ $*"; }
step()  { echo ""; echo "▸ $*"; }
fail()  { echo ""; echo "  ✗ $*" >&2; exit 1; }

# --- Parse flags ---
NEMOCLAW_FLAG=false
PASSTHROUGH_ARGS=()
for arg in "$@"; do
  case "${arg}" in
    --nemoclaw) NEMOCLAW_FLAG=true ;;
    *) PASSTHROUGH_ARGS+=("${arg}") ;;
  esac
done

# --- Testable OS detection (STUB_UNAME_S override for hermetic tests) ---
_os="${STUB_UNAME_S:-$(uname -s)}"

# --- Determine target (D-03 routing precedence) ---
_nemoclaw_dir="${HOME}/.nemoclaw"
_openclaw_dir="${HOME}/.openclaw"
TARGET="standalone"

if [[ "${NEMOCLAW_FLAG}" == true ]] || [[ "${NEMOCLAW:-}" == "1" ]]; then
    TARGET="nemoclaw"
elif [[ -d "${_nemoclaw_dir}" ]] && [[ ! -d "${_openclaw_dir}" ]]; then
    TARGET="nemoclaw"
fi
# Both dirs present + no flag → TARGET stays "standalone" (D-03 dual-home rule)

# --- macOS refusal for NemoClaw path (D-05/D-06) ---
if [[ "${TARGET}" == "nemoclaw" ]] && [[ "${_os}" == "Darwin" ]]; then
    fail "NemoClaw is unsupported on macOS.

  NemoClaw/OpenShell is a Linux-only stack. IMPORTANT: NemoClaw's own
  installer graceful-skips on Darwin (exits 0 without provisioning the
  sandbox) — this looks like success but never installs anything.

  To use the NemoClaw path, provision a Linux host (bare-metal, VM, or
  cloud) with Docker. The standalone OpenClaw path (default, no --nemoclaw
  flag) continues to work on macOS."
fi

# --- Route ---
if [[ "${TARGET}" == "nemoclaw" ]]; then
    bash "${SCRIPT_DIR}/post-install-nemoclaw.sh" "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"
else
    bash "${SCRIPT_DIR}/post-install.sh" "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"
fi
```

### NemoClaw Skeleton Skeleton

```bash
#!/usr/bin/env bash
# scripts/post-install-nemoclaw.sh — Revenium: NemoClaw install path skeleton
# Source: CONTEXT.md D-02/D-07/D-08/D-09/D-10/D-11
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE_SCRIPT="${SCRIPT_DIR}/probe-host-compat.sh"

info()  { echo "  ✓ $*"; }
warn()  { echo "  ⚠ $*"; }
step()  { echo ""; echo "▸ $*"; }
fail()  { echo ""; echo "  ✗ $*" >&2; exit 1; }
command_exists() { command -v "$1" &>/dev/null; }

# Extend PATH to include ~/.local/bin (NemoClaw CLI location)
export PATH="${HOME}/.local/bin:${PATH}"

# --- Preflight (D-08/D-09) ---
step "Running host compatibility preflight"
if ! bash "${PROBE_SCRIPT}"; then
    fail "Host compatibility check failed — NemoClaw requires a Linux host."
fi
info "Preflight complete (warnings above are non-blocking)"

# --- Check NemoClaw CLI (D-10 identity vs capability) ---
step "Checking NemoClaw CLI"
if command_exists nemoclaw; then
    info "nemoclaw CLI found: $(command -v nemoclaw)"
else
    warn "nemoclaw CLI not on PATH — ensure ~/.local/bin is in PATH"
fi

# --- Phase 13–16 stub functions (D-07) ---
stub_provision_egress_policy() {
    warn "Phase 13+: egress policy provisioning deferred — skipping."
}
stub_deliver_revenium_cli() {
    warn "Phase 13+: in-sandbox revenium CLI delivery deferred — skipping."
}
stub_install_metering_loop() {
    warn "Phase 14+: host-side metering loop deferred — skipping."
}
stub_install_enforcement_plugin() {
    warn "Phase 15+: per-turn enforcement plugin deferred — skipping."
}

# --- Run stubs (idempotent no-ops) ---
stub_provision_egress_policy
stub_deliver_revenium_cli
stub_install_metering_loop
stub_install_enforcement_plugin

echo ""
echo "NemoClaw path skeleton complete. Phases 13–16 will implement provisioning."
```

### Test Dispatcher Pattern (hermetic, macOS-compatible)

```bash
# tests/test_install_dispatcher.sh — routing + macOS refusal + idempotency
# Source: CONTEXT.md Claude's Discretion (testing approach)
# Pattern mirrors existing tests/ harness conventions

set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/scripts/install.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }

# run_install <uname_stub> <home_dir> <extra_args...>
run_install() {
    local uname_s="$1"; local home="$2"; shift 2
    STUB_UNAME_S="${uname_s}" HOME="${home}" \
        bash "${INSTALL_SH}" "$@" 2>&1
}

# Branch 1: Linux + NemoClaw-only dir → routes to nemoclaw path
TMP_HOME=$(mktemp -d /tmp/test-inst.XXXXXX)
mkdir -p "${TMP_HOME}/.nemoclaw"
# (no .openclaw/ dir)
output=$(run_install "Linux" "${TMP_HOME}" || true)
# Check post-install-nemoclaw.sh ran (not post-install.sh)
if echo "${output}" | grep -q "preflight\|host compatibility\|Phase 13"; then
    pass "D-03 auto-detect: NemoClaw-only host routes to nemoclaw path"
else
    fail "D-03 auto-detect: NemoClaw-only host did NOT route to nemoclaw path"
fi
rm -rf "${TMP_HOME}"

# Branch 2: macOS + --nemoclaw → refusal with non-zero exit
TMP_HOME=$(mktemp -d /tmp/test-inst.XXXXXX)
mkdir -p "${TMP_HOME}/.nemoclaw"
exit_code=0
output=$(STUB_UNAME_S="Darwin" HOME="${TMP_HOME}" bash "${INSTALL_SH}" --nemoclaw 2>&1) || exit_code=$?
if [[ "${exit_code}" -ne 0 ]] && echo "${output}" | grep -qi "unsupported\|linux-only\|graceful-skip"; then
    pass "D-05/D-06: macOS + --nemoclaw exits non-zero with Darwin trap message"
else
    fail "D-05/D-06: macOS + --nemoclaw exit=${exit_code}, message missing or exit was 0"
fi
rm -rf "${TMP_HOME}"
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Single `post-install.sh` entry point | `install.sh` dispatcher + separate path scripts | Phase 12 (this phase) | Preserves byte-stability of standalone path; enables parallel paths |
| No host detection | OS/Docker/RAM/disk/GPU preflight via `probe-host-compat.sh` | Phase 12 (this phase) | Hard gate on incompatible hosts; warn-and-continue for soft caps |
| Trusting macOS install silently succeeds | Explicit macOS refusal with Darwin graceful-skip explanation | Phase 12 (this phase) | Prevents false-success UX (NemoClaw's installer graceful-skips on Darwin) |

**NemoClaw-specific constraints (verified in spike 001):**
- Host config lives at `~/.nemoclaw/` [VERIFIED: install-and-bootstrap.md]
- CLI installed at `~/.local/bin/nemoclaw` (not `/usr/local/bin`) [VERIFIED: install-and-bootstrap.md]
- NemoClaw's installer exits 0 on macOS without provisioning the sandbox — the "graceful-skip" trap [VERIFIED: spike 001 verdict, SKILL.md requirements]
- Non-interactive install requires `NEMOCLAW_NON_INTERACTIVE=1` env var [VERIFIED: install-and-bootstrap.md]
- Detached install must use `setsid … </dev/null` to avoid apt SIGTTIN [VERIFIED: install-and-bootstrap.md]

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `post-install-nemoclaw.sh` is the right filename for the NemoClaw path script | Architecture Patterns | Cosmetic only; planner can choose any name — CONTEXT.md lists this as Claude's Discretion |
| A2 | `STUB_UNAME_S` is the right env-var name for test OS mocking | Code Examples | Test suite uses different variable name — easy to change |
| A3 | Stub function names (`stub_provision_egress_policy`, etc.) are the right naming scheme | Architecture Patterns | Phase 13 implementer chooses different names — easy rename; no production impact |

---

## Open Questions (RESOLVED)

1. **Does `probe-host-compat.sh` need any adaptation for install context vs spike context?**
   - What we know: The probe is designed as a non-destructive, standalone script with no dependencies beyond bash + standard Unix utilities. It reads `/proc/meminfo`, calls `uname`, `docker info`, `df`, and `nvidia-smi`.
   - What's unclear: The probe's header says "Spike 001 — NemoClaw bootstrap feasibility probe". Should the banner/header be updated to reflect its new role as a first-class install-time preflight script?
   - RESOLVED: Update the comment header when copying to `scripts/`. Keep all logic and exit-code contract byte-for-byte identical. (Reflected in Plan 12-01 Task 1.)

2. **Should `install.sh` accept and forward `--skip-prereqs` to `post-install.sh`?**
   - What we know: `post-install.sh` accepts `--skip-prereqs` (line 28). The dispatcher passes `PASSTHROUGH_ARGS` to both targets.
   - What's unclear: Should `--skip-prereqs` also suppress the preflight probe in the NemoClaw path?
   - RESOLVED: Forward `--skip-prereqs` as-is to both paths via `PASSTHROUGH_ARGS`. The NemoClaw preflight probe stays mandatory this phase given the hard-gate contract (D-08); probe suppression is not wired to this flag. (Reflected in Plan 12-02 Task 1.)

3. **Does the dispatcher need to handle the case where neither `post-install.sh` nor `post-install-nemoclaw.sh` is found (e.g., partially extracted tarball)?**
   - RESOLVED: Add a `[[ -f "${SCRIPT}" ]] || fail "..."` guard before each `bash "${SCRIPT}"` invocation. Minimal code, prevents confusing "bash: file not found" errors. (Reflected in Plan 12-02 Task 1 script-existence guards.)

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| bash | All new scripts | ✓ | macOS: 3.2.57 (system) / zsh default; Linux: 5.x | — |
| `uname` | OS detection in dispatcher | ✓ | POSIX standard | `STUB_UNAME_S` env override for tests |
| `mktemp` | Test harness | ✓ | POSIX standard | — |
| NemoClaw CLI (`nemoclaw`) | Real NemoClaw path execution | ✗ on dev machine | — | `command_exists` guard → warn-and-continue; not needed for Phase 12 skeleton |
| Docker | Preflight check only | N/A | Probe WARNs if absent on Linux | warn-and-continue per D-08 |

**Missing dependencies with no fallback:** None — Phase 12 skeleton produces correct behavior (stub functions, warnings) even without a real NemoClaw install. Testing is fully hermetic via env overrides.

**Missing dependencies with fallback:** NemoClaw CLI — `command_exists` guard plus warn output.

---

## Validation Architecture

> `workflow.nyquist_validation` is `true` in `.planning/config.json` — this section is required.

### Test Framework

| Property | Value |
|----------|-------|
| Framework | bash (native, no framework) — mirrors all existing `tests/*.sh` files |
| Config file | none — tests are run directly |
| Quick run command | `bash tests/test_install_dispatcher.sh` |
| Full suite command | `bash tests/test_install_dispatcher.sh && bash tests/test_guardrail_argv.sh && bash tests/test_write_marker.sh` (regression check) |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| NCINST-01 | Linux+NemoClaw host enters NemoClaw path without touching standalone install | integration | `bash tests/test_install_dispatcher.sh` | ❌ Wave 0 |
| NCINST-01 | Standalone OpenClaw host continues existing path — no regression | integration | `bash tests/test_install_dispatcher.sh` | ❌ Wave 0 |
| NCINST-01 | NemoClaw skeleton path is idempotent (run twice = same result) | integration | `bash tests/test_install_dispatcher.sh` | ❌ Wave 0 |
| NCINST-02 | macOS + NemoClaw signal → explicit error message + non-zero exit | integration | `bash tests/test_install_dispatcher.sh` | ❌ Wave 0 |
| NCINST-02 | macOS without NemoClaw signal → standalone path runs normally | integration | `bash tests/test_install_dispatcher.sh` | ❌ Wave 0 |
| NCINST-01/02 | `post-install.sh` byte-stability (no modifications) | regression | `git diff --name-only scripts/post-install.sh` (expect empty) | ✅ (git) |

### Four Success Criteria → Observable Behaviors

| Success Criterion | Observable Behavior | Test Mechanism |
|-------------------|---------------------|----------------|
| SC1: Linux+NemoClaw host enters NemoClaw path | `post-install-nemoclaw.sh` is invoked; `post-install.sh` is NOT invoked; output contains "preflight" and "Phase 13+" stubs | `HOME` with `~/.nemoclaw/` only, `STUB_UNAME_S=Linux`, check output contains "Phase 13+" and does NOT contain "Revenium skill installed" |
| SC2: Standalone host continues unchanged | `post-install.sh` is invoked; output contains "Revenium skill installed" footer | `HOME` with `~/.openclaw/` only, no `--nemoclaw` flag |
| SC3: macOS prints explicit error, exits non-zero | Exit code ≠ 0; stderr/stdout contains "unsupported" + "graceful-skip" | `STUB_UNAME_S=Darwin` + `--nemoclaw` flag OR `~/.nemoclaw/` only; assert exit ≠ 0 + message |
| SC4: NemoClaw skeleton is idempotent | Running `post-install-nemoclaw.sh` twice produces identical output; no error on second run | Call with same `HOME` twice; compare output; assert exit 0 both times |

### Sampling Rate

- **Per task commit:** `bash tests/test_install_dispatcher.sh`
- **Per wave merge:** `bash tests/test_install_dispatcher.sh && bash tests/test_write_marker.sh && bash tests/test_guardrail_argv.sh` (regression coverage)
- **Phase gate:** Full suite green before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `tests/test_install_dispatcher.sh` — covers all NCINST-01/02 test cases above
- [ ] `scripts/install.sh` — dispatcher (new file, Wave 1 deliverable)
- [ ] `scripts/post-install-nemoclaw.sh` — NemoClaw skeleton (new file, Wave 1 deliverable)
- [ ] `scripts/probe-host-compat.sh` — copy from spike sources (Wave 1 deliverable)

*(No new test framework or conftest needed — existing bash conventions apply.)*

---

## Security Domain

> `security_enforcement` not explicitly set to `false` in config — section required.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | Install scripts do not authenticate |
| V3 Session Management | no | No session state |
| V4 Access Control | partial | `chmod 700` on marker dirs (existing pattern from `post-install.sh`) — NemoClaw skeleton follows same pattern |
| V5 Input Validation | yes | `--nemoclaw` flag parsing; no `eval` of arguments (existing `case` pattern) |
| V6 Cryptography | no | No crypto in install scripts |

### Known Threat Patterns for Install Scripts

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Argument injection via `--nemoclaw` flag or `NEMOCLAW` env | Tampering | Use `case` switch (existing pattern), never `eval`. `NEMOCLAW=1` is boolean — only check for `== "1"`, not eval it. |
| Leftover temp files on failure | Information Disclosure | `trap cleanup EXIT` pattern (established in test suite — production scripts should also `trap` cleanup of any tmpfiles created) |
| Unsanitized HOME override (test only) | Tampering | The `HOME` override is test-only (`STUB_*` prefix convention). Production scripts use `${HOME}` directly. |

---

## Sources

### Primary (HIGH confidence)

- `.claude/skills/spike-findings-openclaw-revenium/references/install-and-bootstrap.md` — Linux-only gate, non-interactive env-var install, detached `setsid` pattern, Darwin graceful-skip trap, `~/.nemoclaw/` host config, `~/.local/bin` CLI location
- `.claude/skills/spike-findings-openclaw-revenium/sources/001-nemoclaw-bootstrap/probe-host-compat.sh` — OS/Docker/RAM/disk/GPU checks, exit-code contract (0=warn/pass, 1=fail), verified on live host 34.224.27.67
- `.claude/skills/spike-findings-openclaw-revenium/SKILL.md` — non-negotiable requirements, spike verdicts
- `scripts/post-install.sh` — `info`/`warn`/`step`/`fail` + `command_exists` idioms (mirrored verbatim in new scripts)
- `scripts/common.sh` — `ensure_path`, `OPENCLAW_HOME` probe patterns
- `scripts/install-cron.sh` — PATH construction for `~/.local/bin` and Homebrew dirs
- `.planning/phases/12-parallel-install-scaffolding-detection/12-CONTEXT.md` — D-01 through D-11 (locked decisions)

### Secondary (MEDIUM confidence)

- `tests/test_guardrail_argv.sh` — established harness conventions: `PASS`/`FAIL` counters, `mktemp -d` HOME isolation, env-var stub injection pattern via fake `HOME/.local/bin`
- `tests/stub-revenium.sh` — argv capture pattern; `STUB_*` env-var convention for switching stub behavior

### Tertiary (LOW confidence)

- None. All claims are grounded in project-local code and spike-validated findings.

---

## Metadata

**Confidence breakdown:**

- Standard stack: HIGH — no new packages; all tooling is existing project bash + copied spike artifact
- Architecture: HIGH — D-01 through D-11 lock every structural decision; routing logic is deterministic
- Pitfalls: HIGH — pitfalls derived directly from spike findings and existing codebase patterns
- Test approach: HIGH — directly mirrors established `tests/` conventions

**Research date:** 2026-06-07
**Valid until:** 2026-08-07 (stable — no external dependencies; only invalidated by NemoClaw breaking changes or changes to existing scripts)
