# Phase 16: Skill Deploy & Docs — Research

**Researched:** 2026-06-10
**Domain:** NemoClaw skill install assertion + operator documentation
**Confidence:** HIGH (all findings verified against codebase, validated reference files, and live Phase 15 evidence)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** NemoClaw operator docs live in a separate file under `docs/` (e.g. `docs/nemoclaw-setup.md`), NOT inside `README.md`. The only edit to `README.md` is a single short pointer link to the new doc.
- **D-02:** Add a fail-hard discovery assertion to `scripts/post-install-nemoclaw.sh` after `install_skill_nemoclaw()`: run the discovery command (researcher to confirm exact invocation), grep for the revenium skill showing `✓ ready`, and fail hard if absent — mirroring the existing D-07 plugin smoke-gate style.
- **D-03:** Phase 16 includes a live fresh-sandbox validation gate. Run the documented install path on a clean sandbox (34.224.27.67) following only the new docs, and record evidence in `16-VALIDATION.md`. Follow the CRITICAL HONESTY RULE from Phase 15.
- **D-04:** The NemoClaw doc is a full operator runbook covering: prerequisites (Linux, Docker, NemoClaw installed, `sshfs`), install command sequence, `✓ ready` verification, parallel-path guarantee, macOS-unsupported constraint with its exact error message, plus troubleshooting and uninstall.

### Claude's Discretion

- Exact filename/location under `docs/` (`docs/nemoclaw-setup.md` is the working name).
- The precise discovery command and grep pattern for the `✓ ready` assertion.
- Doc section ordering and prose, as long as all D-04 topics are present.
- Whether the live-validation gate reuses the existing `revenium-spike` sandbox or provisions a fresh one.

### Deferred Ideas (OUT OF SCOPE)

- Baking the skill into a custom OpenShell image (`nemoclaw onboard --from`) — out of scope per REQUIREMENTS.md "Non-Goals".

</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| NCDEPLOY-01 | The Revenium skill is deployed into the sandbox via `nemoclaw skill install` and discovered by the agent (`✓ ready`). | Deploy step already wired in `install_skill_nemoclaw()` (Phase 15 D-08). Phase 16 adds the fail-hard `✓ ready` assertion after install (D-02). Also requires fixing the SSHFS-unsafe-filename landmine in the deploy path. |
| NCDEPLOY-02 | Setup docs cover the NemoClaw install path, prerequisites, and the macOS-unsupported constraint. | New `docs/nemoclaw-setup.md` runbook (D-01/D-04). Single pointer link in `README.md`. Exact macOS error string documented below. |

</phase_requirements>

---

## Summary

Phase 16 has two deliverables: (1) a fail-hard `✓ ready` discovery assertion added to `install_skill_nemoclaw()` in `scripts/post-install-nemoclaw.sh`, and (2) a new `docs/nemoclaw-setup.md` operator runbook. The deploy mechanism itself (`nemoclaw <name> skill install <path>`) is already wired in the script at line 132; what's missing is the post-install assertion that confirms the skill is visible and `✓ ready` in-sandbox.

All the open research unknowns from CONTEXT.md have been resolved against the codebase and Phase 15 live evidence. The exact discovery command is `openclaw skills list` run in-sandbox via `nemoclaw <name> exec -- sh -lc "openclaw skills list"`, and the substring to grep for is `✓ ready` combined with the skill name `revenium`. The exact macOS error string is in `scripts/install.sh` at lines 76–84. There is also a latent landmine in `install_skill_nemoclaw()` — the `${SCRIPT_DIR}/..` path resolves to `~/` when the install runs from the home directory, and SSHFS-mounted subdirectories cause `nemoclaw skill install` to fail with "File names must contain unsafe characters" — this was worked around manually in every Phase 15 live run (Deviation 1) but was never fixed in the script. Phase 16 must fix this.

**Primary recommendation:** One small code task (D-02 assertion + SSHFS landmine fix in `install_skill_nemoclaw()`) plus one docs task (`docs/nemoclaw-setup.md` runbook) plus one live-validation gate plan (D-03, following Phase 15 evidence format).

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| `✓ ready` discovery assertion | Install script (host) | — | Runs `openclaw skills list` in-sandbox via `nemoclaw exec`; the assertion lives in `post-install-nemoclaw.sh`, same tier as the other fail-hard gates |
| SSHFS-path fix for skill install | Install script (host) | — | `install_skill_nemoclaw()` resolves skill path at install time; host-side fix before calling `nemoclaw skill install` |
| NemoClaw operator runbook | Docs (`docs/`) | README.md pointer | New standalone file; README.md gets one pointer link only |
| Live-validation gate | Human operator + validator agent | `16-VALIDATION.md` | Follows Phase 15 evidence format; blocking human checkpoint |

---

## Key Research Findings

### 1. Discovery Command (D-02) — VERIFIED

**Exact command:** `openclaw skills list` run in-sandbox:

```bash
nemoclaw "${SANDBOX_NAME}" exec -- sh -lc "openclaw skills list 2>&1"
```

**Source evidence (HIGH confidence):**

- `references/skill-deploy-and-enforcement.md` line 14–15 (spike findings): "`skill install` … agent lists it `✓ ready` (`openclaw skills list`)."
- `README.md` line 87 (standalone path verification step): `openclaw skills list` → "You should see `revenium` in the list (`✓ ready`)."
- `README.md` line 152 (local dev verify): `openclaw skills list | grep revenium     # expect: ✓ ready  💰 revenium`
- `15-VALIDATION.md` line 190: "Revenium skill deployed: `openclaw skills list` shows `revenium` as `ready`."

**Expected output shape (from README.md line 152):**
```
✓ ready  💰 revenium
```
The `✓ ready` prefix and `revenium` skill name both appear on the same line. The assertion should grep for both substrings.

**Grep pattern for the assertion:**
```bash
echo "${_skill_list_output}" | grep -q "✓ ready" && echo "${_skill_list_output}" | grep -q "revenium"
```

Or combined as a single grep for the expected co-occurrence:
```bash
echo "${_skill_list_output}" | grep -q "revenium.*ready\|ready.*revenium"
```

The simplest robust form (matching the `✓ ready  💰 revenium` shape):
```bash
echo "${_skill_list_output}" | grep "revenium" | grep -q "ready"
```

**Ledger key:** No new ledger key needed — the assertion runs every time `install_skill_nemoclaw()` does new work (i.e., the first time, not on re-runs when the ledger already shows `skill-installed-nemoclaw`). For consistency with the D-07 plugin gate pattern, the assertion can be placed inside the same block, after `nemoclaw skill install` succeeds, before `ledger_set`.

**Fail message template** (mirroring existing `fail "..."` calls in the script):
```
fail "revenium skill NOT ready in sandbox after install — 'openclaw skills list' did not show '✓ ready' for revenium. Check sandbox status: nemoclaw ${SANDBOX_NAME} status"
```

### 2. SSHFS Landmine in `install_skill_nemoclaw()` — VERIFIED, MUST FIX

**File:** `scripts/post-install-nemoclaw.sh`, lines 128–136

**Current code:**
```bash
local skill_dir
skill_dir="${SCRIPT_DIR}/.."
nemoclaw "${SANDBOX_NAME}" skill install "${skill_dir}" \
    || fail "nemoclaw skill install failed"
```

**The problem:** `SCRIPT_DIR` is `scripts/`, so `skill_dir` = the repo root. When the install script runs on a host where the repo was cloned directly to `~/` (i.e., `~/scripts/post-install-nemoclaw.sh`), `${SCRIPT_DIR}/..` resolves to `~/`. The NemoClaw host has SSHFS mounts under `~/` (e.g., `~/sbx-openclaw-revenium-spike/`) whose `node_modules` subdirectories contain filenames with spaces. `nemoclaw skill install` scans the directory recursively and rejects any file whose name contains characters outside `[A-Za-z0-9._-/]`, producing:

```
Skill directory contains files with unsafe characters:
  sbx-openclaw/extensions/nemoclaw/node_modules/@isaacs/fs-minipass/README.md
  ...
File names must match [A-Za-z0-9._-/]. Rename or remove them.
X nemoclaw skill install failed
```

This was hit on every Phase 15 live run and worked around by creating `~/revenium-skill/` staging directories manually (15-VALIDATION.md §"Deviation 1: install_skill_nemoclaw() fails from home directory due to SSHFS mounts").

**Fix approach:** Resolve the canonical repo root using `git rev-parse --show-toplevel` (or an equivalent) rather than relative `..` navigation. If the script is always invoked from within a git repo (which it is in the normal install path: cloned to `~/.openclaw/skills/revenium/`), this gives the repo root cleanly without picking up surrounding SSHFS mount directories.

Alternative: pass an absolute path by anchoring to `BASH_SOURCE[0]` with `realpath -e`:
```bash
skill_dir="$(realpath -e "${SCRIPT_DIR}/..")"
```
This still resolves to `~/` on the problem host. The real fix is to ensure the skill dir passed to `nemoclaw skill install` does NOT include SSHFS-mounted siblings. The safest approach: build the skill dir from `SKILL.md` location (guaranteed inside the repo), not from `..` navigation.

**Recommended fix pattern:**
```bash
# Anchor to the SKILL.md file which is always inside the skill root.
# This avoids resolving to ~/ when the script is run from the home directory
# and SSHFS mounts are present as siblings.
local skill_dir
skill_dir="${SCRIPT_DIR}/.."
# Guard: if SKILL.md is not present at the resolved path, the script_dir
# resolution is wrong (e.g., ~/scripts/../ = ~/ with SSHFS mounts).
if [[ ! -f "${skill_dir}/SKILL.md" ]]; then
    fail "SKILL.md not found at ${skill_dir} — cannot determine skill root. Run the install from the skill directory (e.g., bash ~/.openclaw/skills/revenium/scripts/post-install-nemoclaw.sh)"
fi
nemoclaw "${SANDBOX_NAME}" skill install "${skill_dir}" \
    || fail "nemoclaw skill install failed"
```

This turns a silent wrong-path failure into an explicit actionable error, without altering the normal install path (where the script lives at `~/.openclaw/skills/revenium/scripts/` and `SKILL.md` is at `~/.openclaw/skills/revenium/SKILL.md`).

### 3. macOS Exact Error String (D-04/SC3) — VERIFIED

**File:** `scripts/install.sh`, lines 76–84

```bash
if [[ "${TARGET}" == "nemoclaw" ]] && [[ "${_os}" == "Darwin" ]]; then
    fail "NemoClaw is unsupported on macOS.

  NemoClaw/OpenShell is a Linux-only stack. IMPORTANT: NemoClaw's own
  installer graceful-skips on Darwin (exits 0 without provisioning the
  sandbox) — this looks like success but never installs anything.

  To use the NemoClaw path, provision a Linux host (bare-metal, VM, or
  cloud) with Docker. The standalone OpenClaw path (default, no --nemoclaw
  flag) continues to work on macOS."
fi
```

The `fail` helper prepends `  ✗ ` and writes to stderr. So the literal output the operator sees begins:

```
  ✗ NemoClaw is unsupported on macOS.
```

The doc must quote this verbatim (the first line), and should note the `exit 1` / non-zero exit. The condition that triggers it: `--nemoclaw` flag passed (or `NEMOCLAW=1` env var set, or `~/.nemoclaw/` present without `~/.openclaw/`) on a Darwin host.

### 4. `install_skill_nemoclaw()` Integration Point and Call Site — VERIFIED

**File:** `scripts/post-install-nemoclaw.sh`

- **Function definition:** lines 117–137 (`install_skill_nemoclaw()`)
- **Call site:** line 515 — `install_skill_nemoclaw         # D-08: deploy skill first (marker chain precondition)`
- **Execution order:** `install_metering_loop` (line 514) → `install_skill_nemoclaw` (line 515) → `install_enforcement_plugin` (line 516)

**D-02 assertion slot:** Inside `install_skill_nemoclaw()`, after the `nemoclaw skill install` call succeeds (line 132–133) but **before** `ledger_set "skill-installed-nemoclaw" "1"` (line 135). This way:
- If the install ran but the skill is not `✓ ready`, the assertion fails hard and the ledger key is NOT written — a re-run will retry the install.
- If the assertion passes, the ledger key is written as usual.

No separate ledger key needed for the assertion; it runs as part of the same atomic install+verify block.

**Helper vocabulary available (same file):**
- `step "..."` — section header (line 54)
- `info "  ✓ ..."` — success line (line 52)
- `fail "..."` — prints `  ✗ ...` to stderr and exits 1 (line 55)
- `ledger_has "key"` / `ledger_set "key" "val"` — idempotency gate (lines 64–83)
- `SANDBOX_NAME` — already resolved before function call (line 493)

**D-07 plugin smoke gate as style template** (existing, lines 209–270 — the Gate A/B/C/D pattern): each gate uses `nemoclaw "${SANDBOX_NAME}" exec -- sh -lc "..."` to run an in-sandbox command, captures output, then calls `fail "..."` with an actionable message on failure, or `info "Gate X passed: ..."` on success. The `✓ ready` assertion should follow the same idiom:

```bash
# Assert ✓ ready in-sandbox after install (D-02)
local _skill_list
_skill_list=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
    "openclaw skills list 2>/dev/null" 2>/dev/null || true)
if ! echo "${_skill_list}" | grep "revenium" | grep -q "ready"; then
    fail "revenium skill NOT ready after install — 'openclaw skills list' did not show ready state. Check sandbox: nemoclaw ${SANDBOX_NAME} status"
fi
info "revenium skill confirmed ✓ ready in sandbox"
```

### 5. README.md Section Structure (D-01/D-04/SC4) — VERIFIED

**File:** `README.md` (316 lines, confirmed from CONTEXT.md)

**Section map** (for the parallel runbook structure):

| Section | README.md | nemoclaw-setup.md parallel |
|---------|-----------|----------------------------|
| Prerequisites | Lines 6–16 (OpenClaw, ClawHub, revenium CLI via brew, API creds) | NemoClaw prereqs: Linux, Docker, NemoClaw, sshfs, revenium binary (prebuilt, no brew), env vars |
| Installation — Step 1 | Lines 19–28 (clawhub install) | Step 1: nemoclaw skill install (or post-install-nemoclaw.sh) |
| Installation — Step 2 | Lines 30–54 (post-install.sh) | Step 2: verify `✓ ready` |
| Installation — Steps 3–5 | Lines 56–90 (creds, restart, verify) | Step 3: verify meter probe (already ran in provisioning) |
| Installing from GitHub repo | Lines 112–165 | N/A for NemoClaw (not cloned separately; skill dir is the repo itself) |
| Setup | Lines 168–182 | Same — setup flow is in SKILL.md / agent-driven |
| How It Works | Lines 184–227 | Parallel: metering loop runs host-side via `nemoclaw share mount` + cron (not Docker bind-mount) |
| Configuration | Lines 233–268 | Same config.json; credentials in /sandbox/.config/revenium/config.yaml (not ~/.config) |
| Uninstalling | Lines 274–284 | Add nemoclaw-specific uninstall (remove cron, uninstall plugin, nemoclaw skill remove) |
| Troubleshooting | Lines 287–312 | macOS refusal (exact error string); SSHFS mount issues; sandbox restart |

**Cross-references to include in the runbook:**
- `SKILL.md` — skill manifest; the enforcement directives are the reason for the plugin requirement
- `BUDGET-GUARD.md` — the guardrail directive content that the plugin injects (explains *why* the plugin is mandatory, not just `skill install`)
- `README.md` — pointer back to the standalone path ("For standalone OpenClaw + Docker, see README.md")

**The only README.md edit:** Add one line at the end of the Installation section (after Step 5 Verify) or in a new short "NemoClaw" subsection at the bottom of Installation:

```markdown
> **Running on NemoClaw/OpenShell?** See [NemoClaw Setup](docs/nemoclaw-setup.md) for the parallel install path.
```

### 6. Live Validation Gate Format (D-03) — VERIFIED

**Source:** `15-VALIDATION.md` (full evidence format) + `15-07-PLAN.md` (checkpoint-plan structure)

**Evidence format from 15-VALIDATION.md:**
- Section header: `## SC1 — <name> (<description>)`
- `### Status: PASSED / PARTIALLY EVIDENCED / STILL FAILING`
- `### Evidence` with fenced blocks: `Command: ...`, `Exit: 0`, `Output: ...`
- Blockers table at the end of the document
- `## Recommended Fixes` section for anything still failing
- CRITICAL HONESTY RULE applied explicitly at the end of each round

**Checkpoint-plan structure from 15-07-PLAN.md:**
- `type: "checkpoint:human-verify"` task with `gate: blocking`
- `<what-built>` — summary of what the preceding task deployed/ran
- `<how-to-verify>` — numbered steps for the human reviewer
- `<resume-signal>` — explicit signal strings (e.g., "approved" or "gap found: ...")

**D-03 for Phase 16:**
The clean-host validation goal is narrower than Phase 15 (no plugin gates to re-validate): run `bash scripts/post-install-nemoclaw.sh` on a clean sandbox (or re-provisioned `revenium-spike`) following **only** `docs/nemoclaw-setup.md`, and capture:
1. SC1: `nemoclaw skill install` succeeds (exit 0, "Skill 'revenium' updated" or equivalent output)
2. SC2: `openclaw skills list` in-sandbox shows `✓ ready` for `revenium`
3. SC3: The D-02 assertion in `install_skill_nemoclaw()` passes (not just that it ran — confirm the assertion line in the output)
4. SC4: No step required a manual intervention not documented in the runbook

**Sandbox choice:** Reuse `revenium-spike` on `34.224.27.67` — the skill and plugin are already installed there, but the ledger will skip already-done steps. For an honest "clean host" test the ledger key `skill-installed-nemoclaw` should be cleared first (or the validation should use a fresh sandbox name). CONTEXT.md leaves this to discretion: "pick whichever more honestly tests 'clean host' without leaving the shared host broken."

**Recommendation:** Clear `skill-installed-nemoclaw` from the ledger on `revenium-spike` and re-run, so the assertion is tested on the existing host without provisioning a new sandbox. This is equivalent to a fresh skill install while preserving the rest of the provisioned state. Alternatively, provision a new sandbox name (e.g., `revenium-docs-test`) on the same host — but this takes ~11 min and wastes resources.

---

## Architecture Patterns

### System Architecture Diagram

```
Operator runs: bash scripts/install.sh [--nemoclaw]
          |
          v
    install.sh dispatcher
    (routes on OS + ~/.nemoclaw/)
          |
    macOS + nemoclaw? ---> fail "NemoClaw is unsupported on macOS." (exit 1)
          |
          v  (Linux)
    post-install-nemoclaw.sh
          |
    [ Phase 13 provisioning: egress, CLI, creds, meter-probe ]
          |
    install_metering_loop()  [Phase 14]
          |
    install_skill_nemoclaw()  ← Phase 16 adds ✓ ready assertion here
      | nemoclaw skill install <repo_root>
      |   (uploads to /sandbox/.openclaw/skills/revenium/)
      | assert: openclaw skills list → ✓ ready
      |
    install_enforcement_plugin()  [Phase 15]
      | plugin gates A/B/C/D
          |
    Success banner
```

### Recommended Project Structure

No new directory structure changes beyond `docs/` creation:

```
docs/
└── nemoclaw-setup.md        # new in Phase 16 (D-01/D-04)
scripts/
└── post-install-nemoclaw.sh # modified: SKILL.md guard + ✓ ready assertion (D-02)
README.md                    # modified: one pointer link (D-01)
.planning/phases/16-skill-deploy-docs/
└── 16-VALIDATION.md         # new in Phase 16 (D-03)
```

### Pattern: Fail-Hard In-Sandbox Assertion

Template (mirroring Gate A/B/C/D in `install_enforcement_plugin()`):

```bash
# Source: scripts/post-install-nemoclaw.sh, lines 228–238 (Gate A style)
local _output
_output=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
    "<in-sandbox command> 2>/dev/null" 2>/dev/null || true)
if ! echo "${_output}" | grep -q "<expected_substring>"; then
    fail "<actionable description>. Check: <recovery command>"
fi
info "<Gate name> passed: <what was confirmed>"
```

The `|| true` at the end of the command substitution prevents `set -euo pipefail` from aborting if the in-sandbox command exits non-zero (analogous to the CR-01 fix in Gate A — see `15-VALIDATION.md` §"CR-01 Evidence").

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Skill discovery | Custom JSON parser or skill-status probe | `openclaw skills list` (NemoClaw path) | Official command; produces `✓ ready` output per spec |
| macOS error message | Custom OS check in docs | Quote `scripts/install.sh` lines 76–84 verbatim | Code and docs stay in sync; the literal string is already canonical |
| Validation evidence format | Custom format | Reuse Phase 15 `15-VALIDATION.md` command/exit/output block format | Consistent with all prior phases; human reviewer knows how to read it |

---

## Common Pitfalls

### Pitfall 1: SSHFS Unsafe-Filename Failure in `install_skill_nemoclaw()`
**What goes wrong:** When the script is invoked from `~/` (i.e., the repo root is `~/`), `${SCRIPT_DIR}/..` resolves to `~`. SSHFS mounts under `~/sbx-openclaw-*/` contain `node_modules` directories with filenames containing spaces, which `nemoclaw skill install` rejects with "File names must match [A-Za-z0-9._-/]". Install fails with exit 1.

**Why it happens:** `SCRIPT_DIR` is `scripts/`; `..` is the containing directory, which is `~/` when the repo is cloned to home.

**How to avoid:** Add a `SKILL.md` presence guard in `install_skill_nemoclaw()` before calling `nemoclaw skill install`. If `SKILL.md` is absent at `${SCRIPT_DIR}/..`, fail with an actionable "cannot determine skill root" message. In the normal install path (`~/.openclaw/skills/revenium/`), `SKILL.md` is always present.

**Warning signs:** Error message contains "File names must contain unsafe characters" or "File names must match [A-Za-z0-9._-/]".

**Evidence:** `15-VALIDATION.md` §"Deviation 1: install_skill_nemoclaw() fails from home directory due to SSHFS mounts" (observed on every Phase 15 live run; worked around with `~/revenium-skill/` staging — never fixed in script).

### Pitfall 2: `✓ ready` assertion uses `set -euo pipefail` without `|| true`
**What goes wrong:** Under `set -euo pipefail`, a grep that finds no match (exit 1) inside a command substitution causes the script to abort silently without printing the fail message. This is exactly the CR-01 regression from Phase 15 (Gate A). The `|| true` guard is mandatory on every pipeline inside `$()`.

**Why it happens:** `set -euo pipefail` propagates non-zero exits from subshells inside `$()`.

**How to avoid:** Always append `|| true` to the pipeline that captures output from in-sandbox commands:
```bash
_skill_list=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
    "openclaw skills list 2>/dev/null" 2>/dev/null || true)
```
Then evaluate the captured output separately with `grep -q` inside an `if !` block.

**Evidence:** CR-01 fix in `scripts/post-install-nemoclaw.sh` lines 229–231; `15-VALIDATION.md` §"CR-01 Evidence" (the old code aborted silently before printing its diagnostic message).

### Pitfall 3: Docs Contradict README.md (SC4)
**What goes wrong:** `docs/nemoclaw-setup.md` describes a step or prerequisite that conflicts with `README.md` (e.g., says "install revenium via brew" on the NemoClaw path, but NemoClaw uses a tarball-delivered binary). Or it implies the standalone and NemoClaw paths are the same.

**How to avoid:** The NemoClaw runbook must explicitly describe the NemoClaw-specific delivery (`post-install-nemoclaw.sh` delivers the binary into the sandbox as a prebuilt tarball — NOT via Homebrew). The parallel-path guarantee section must state that the standalone path is unchanged and the two paths do not share install scripts.

**Warning signs:** Any step in the runbook that references `brew install revenium` or `openclaw gateway restart` (standalone-path concepts) without qualification.

### Pitfall 4: Success Banner Still Says "Phase 16 still pending"
**What goes wrong:** `scripts/post-install-nemoclaw.sh` line 540 explicitly says:
```
echo "  Phase 16 (skill deploy + docs) still pending."
```
This banner will be wrong after Phase 16 ships.

**How to avoid:** Update the success banner to reflect Phase 16 complete. This is a small but required edit to avoid confusing operators after the phase ships.

### Pitfall 5: Validation Run Follows the Script, Not the Docs (SC2/D-03)
**What goes wrong:** The D-03 clean-host validation run uses the operator's existing knowledge of `post-install-nemoclaw.sh` rather than following only `docs/nemoclaw-setup.md`. This masks undocumented steps and defeats SC2 ("no undocumented manual steps required").

**How to avoid:** The validation plan must explicitly state "follow only the new docs" and flag any step that requires console access, environment variable knowledge, or tooling not documented in the runbook.

---

## Code Examples

### D-02 Discovery Assertion (to add to `install_skill_nemoclaw()`)

```bash
# Source: pattern from scripts/post-install-nemoclaw.sh Gate A (lines 228–238)
# Add after nemoclaw skill install succeeds, before ledger_set

# Assert ✓ ready in-sandbox (D-02 discovery assertion)
local _skill_list
_skill_list=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
    "openclaw skills list 2>/dev/null" 2>/dev/null || true)
if ! echo "${_skill_list}" | grep "revenium" | grep -q "ready"; then
    fail "revenium skill NOT ready after install — 'openclaw skills list' did not show ready state for revenium. Inspect the sandbox: nemoclaw ${SANDBOX_NAME} status"
fi
info "revenium skill confirmed ready in sandbox"
```

### SKILL.md Guard (to add at top of `install_skill_nemoclaw()`)

```bash
# Source: defensive pattern — confirmed missing in current code
local skill_dir
skill_dir="${SCRIPT_DIR}/.."
# Guard: SKILL.md must be present at the resolved path; if it is absent, the
# path resolved to ~/ or another wrong location (e.g., due to SSHFS mounts).
if [[ ! -f "${skill_dir}/SKILL.md" ]]; then
    fail "SKILL.md not found at ${skill_dir} — cannot determine skill root. Run the install from the skill directory: bash ~/.openclaw/skills/revenium/scripts/post-install-nemoclaw.sh"
fi
```

### macOS Exact Error Output (for `docs/nemoclaw-setup.md`)

The exact error that `scripts/install.sh` emits on macOS with `--nemoclaw` (source: `scripts/install.sh` lines 76–84):

```
  ✗ NemoClaw is unsupported on macOS.

  NemoClaw/OpenShell is a Linux-only stack. IMPORTANT: NemoClaw's own
  installer graceful-skips on Darwin (exits 0 without provisioning the
  sandbox) — this looks like success but never installs anything.

  To use the NemoClaw path, provision a Linux host (bare-metal, VM, or
  cloud) with Docker. The standalone OpenClaw path (default, no --nemoclaw
  flag) continues to work on macOS.
```

Exit code: 1 (non-zero).

### README.md Pointer Link (the only allowed edit)

Insert as a blockquote inside or after the Installation section. Exact placement at discretion:

```markdown
> **Running on NemoClaw/OpenShell?** See [NemoClaw Setup](docs/nemoclaw-setup.md) for the parallel install path.
```

---

## Runtime State Inventory

> Omitted — this is not a rename/refactor phase.

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|-----------------|--------------|--------|
| Skill deploy assumed complete after `nemoclaw skill install` | `nemoclaw skill install` + explicit `openclaw skills list` assertion | Phase 16 (this phase) | Fail-hard on silent deploy failure rather than proceeding with an incomplete install |
| SSHFS-unsafe path resolved silently to wrong dir | Explicit `SKILL.md` presence guard before `nemoclaw skill install` | Phase 16 (this phase) | Actionable error instead of opaque "File names must match [A-Za-z0-9._-/]" |

---

## Open Questions

1. **`openclaw skills list` output format in-sandbox**
   - What we know: The README.md says the expected output is `✓ ready  💰 revenium`; the spike findings confirm the same. The Phase 15 validation confirms the skill was deployed and shows `openclaw skills list` as `ready` (without the exact `✓` character).
   - What's unclear: Whether the `✓` character in `✓ ready` is a literal Unicode checkmark (U+2713) in the in-sandbox output, or whether it is rendered differently in the `nemoclaw exec` output path vs. direct terminal output. The README.md grep target `✓ ready  💰 revenium` contains Unicode.
   - Recommendation: Make the grep pattern robust to both forms — match `ready` near `revenium` rather than the Unicode `✓` character literally. The pattern `grep "revenium" | grep -q "ready"` handles both renderings.

2. **`nemoclaw skill install` output on success**
   - What we know: Phase 15 validation (15-VALIDATION.md §SC3 infrastructure) shows the output as "Skill 'revenium' updated" after re-install via the staging workaround.
   - What's unclear: Whether the first-ever install (not re-install) says "Skill 'revenium' installed" or "Skill 'revenium' updated". Not critical for the assertion (we rely on `openclaw skills list` for the assertion, not the `skill install` output), but good to document in the runbook.
   - Recommendation: Document both forms in the runbook. The assertion uses `openclaw skills list`, not the `skill install` output.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `nemoclaw` CLI | All Phase 16 code tasks | ✓ (34.224.27.67) | NemoClaw (installed) | — |
| `openclaw` in-sandbox | D-02 assertion | ✓ (in sandbox) | OpenClaw 2026.5.22 | — |
| sandbox `revenium-spike` | D-03 live validation | ✓ (34.224.27.67) | Running, Phase 15 complete | provision fresh sandbox (~11 min) |

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Bash (existing `tests/test_install_dispatcher.sh`, `tests/test_nemoclaw_provisioning.sh`, `tests/test_nemoclaw_cron.sh`) |
| Config file | None — shell-based harness |
| Quick run command | `bash tests/test_install_dispatcher.sh` |
| Full suite command | `bash tests/test_install_dispatcher.sh && bash tests/test_nemoclaw_provisioning.sh && bash tests/test_nemoclaw_cron.sh` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| NCDEPLOY-01 | `install_skill_nemoclaw()` asserts `✓ ready` after install | unit (bash) | `bash tests/test_nemoclaw_provisioning.sh` | ❌ Wave 0 (new tests needed) |
| NCDEPLOY-01 | SKILL.md guard fails with actionable message when path is wrong | unit (bash) | `bash tests/test_nemoclaw_provisioning.sh` | ❌ Wave 0 |
| NCDEPLOY-02 | `docs/nemoclaw-setup.md` exists and contains all required sections | smoke | `grep -q "Prerequisites\|Uninstall\|macOS" docs/nemoclaw-setup.md` | ❌ Wave 0 (new file) |
| NCDEPLOY-02 | `README.md` pointer link present | smoke | `grep -q "nemoclaw-setup.md" README.md` | ❌ Wave 0 |

### Wave 0 Gaps

- [ ] `tests/test_nemoclaw_provisioning.sh` — add test group for `install_skill_nemoclaw()`: (a) SKILL.md guard fires when `SKILL.md` absent, (b) `✓ ready` assertion fails hard when `openclaw skills list` does not show `ready`, (c) assertion passes when output matches
- [ ] `docs/nemoclaw-setup.md` — new file (content task, not test gap)
- [ ] `README.md` — pointer link (content task, not test gap)

---

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | — |
| V3 Session Management | no | — |
| V4 Access Control | no | — |
| V5 Input Validation | yes (narrow) | `nemoclaw skill install` rejects unsafe filenames; the SKILL.md guard prevents passing wrong path |
| V6 Cryptography | no | — |

No new credential handling, no new network calls, no new secret injection in Phase 16.

---

## Package Legitimacy Audit

> No new external packages are installed in this phase. The code task modifies an existing bash script; the docs task creates a markdown file. No npm/pip/cargo installs.

**Packages removed due to slopcheck [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `openclaw skills list` in-sandbox (via `nemoclaw exec`) produces output containing `✓ ready` and `revenium` on the same line when the skill is deployed and ready | Key Research Finding §1 | The assertion uses `grep "revenium" | grep -q "ready"` as a fallback that avoids Unicode; if the output format is completely different (e.g., a table with no "ready" substring), the assertion would fail on every install. Risk is LOW — three independent sources confirm `✓ ready` substring. |
| A2 | Clearing `skill-installed-nemoclaw` from the ledger on `revenium-spike` and re-running is a valid "clean skill install" test for D-03 | Open Questions §2 | If the sandbox has state that affects the skill install result (not just the ledger key), a full fresh sandbox would give more honest evidence. Risk is LOW given the NemoClaw install path is deterministic. |

**If this table is empty:** All claims in this research were verified or cited — no user confirmation needed. (2 minor assumptions above, both LOW risk with mitigations in the pattern.)

---

## Sources

### Primary (HIGH confidence)

- `scripts/post-install-nemoclaw.sh` — full source read; function definitions, call sites, helper vocabulary confirmed at specific lines
- `scripts/install.sh` lines 76–84 — exact macOS error string quoted verbatim
- `.planning/phases/15-per-turn-enforcement-plugin/15-VALIDATION.md` — live evidence format, Deviation 1 SSHFS failure, Phase 15 skill deploy status
- `.planning/phases/15-per-turn-enforcement-plugin/15-07-PLAN.md` — checkpoint-plan structure and CRITICAL HONESTY RULE
- `.claude/skills/spike-findings-openclaw-revenium/references/skill-deploy-and-enforcement.md` — `openclaw skills list` as the discovery command, `✓ ready` output confirmed
- `README.md` lines 87, 152 — `✓ ready  💰 revenium` output shape; section structure

### Secondary (MEDIUM confidence)

- `.planning/phases/15-per-turn-enforcement-plugin/15-02-SUMMARY.md` — install_skill_nemoclaw integration point confirmed
- `.planning/phases/15-per-turn-enforcement-plugin/15-03-SUMMARY.md` — Deviation 1 workaround pattern (`~/revenium-skill/` staging)
- `SKILL.md`, `BUDGET-GUARD.md` — cross-reference targets for the runbook

---

## Metadata

**Confidence breakdown:**
- D-02 assertion command/pattern: HIGH — three independent sources confirm `openclaw skills list` and `✓ ready` + `revenium` grep
- SSHFS landmine and fix: HIGH — confirmed by Phase 15 live failure on every run (Deviation 1), root cause clear, fix pattern straightforward
- macOS error string: HIGH — verbatim from source file
- Integration point / call site: HIGH — confirmed from full script read
- Docs structure: HIGH — README.md section map confirmed by reading all 316 lines
- Live validation format: HIGH — confirmed from 15-VALIDATION.md and 15-07-PLAN.md

**Research date:** 2026-06-10
**Valid until:** 2026-07-10 (stable; OpenClaw version does not change between phases)
