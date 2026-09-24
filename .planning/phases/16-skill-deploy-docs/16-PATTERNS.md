# Phase 16: Skill Deploy & Docs - Pattern Map

**Mapped:** 2026-06-10
**Files analyzed:** 4 (2 modified, 1 new, 1 modified-minimal)
**Analogs found:** 4 / 4

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `scripts/post-install-nemoclaw.sh` | utility/install | request-response (fail-hard gates) | Same file — Gate A/B/C/D in `install_enforcement_plugin()` lines 209–270 | self-analog (exact) |
| `docs/nemoclaw-setup.md` | docs | N/A | `README.md` lines 1–316 | role-match (structure mirror) |
| `tests/test_nemoclaw_provisioning.sh` | test | batch (assertion groups) | Same file — Groups A–H lines 136–372 | self-analog (exact) |
| `README.md` | docs | N/A | `README.md` lines 18–90 (Installation section) | self-analog (minimal pointer edit) |

---

## Pattern Assignments

### `scripts/post-install-nemoclaw.sh` (utility/install — MODIFY)

**Changes required:**
1. Add `SKILL.md` path guard inside `install_skill_nemoclaw()` before the `nemoclaw skill install` call (lines 131–133).
2. Add `✓ ready` discovery assertion inside `install_skill_nemoclaw()` after the `nemoclaw skill install` call succeeds but before `ledger_set`.
3. Remove the "Phase 16 still pending" line at line 540.

**Analog:** Same file — `install_enforcement_plugin()` Gate A (lines 226–238) for the in-sandbox exec + fail-hard pattern; `install_skill_nemoclaw()` itself (lines 121–137) for the ledger-gate wrapper.

---

**Logging helpers** (lines 52–55):
```bash
info()  { echo "  ✓ $*"; }
warn()  { echo "  ⚠ $*"; }
step()  { echo ""; echo "▸ $*"; }
fail()  { echo ""; echo "  ✗ $*" >&2; exit 1; }
```

**Ledger-gate wrapper pattern** — existing `install_skill_nemoclaw()` (lines 121–137):
```bash
install_skill_nemoclaw() {
    if ledger_has "skill-installed-nemoclaw"; then
        info "Revenium skill already deployed to sandbox (ledger) — skipping."
        return 0
    fi

    step "Deploying revenium skill into sandbox"
    local skill_dir
    skill_dir="${SCRIPT_DIR}/.."
    nemoclaw "${SANDBOX_NAME}" skill install "${skill_dir}" \
        || fail "nemoclaw skill install failed"

    ledger_set "skill-installed-nemoclaw" "1"
    info "Revenium skill deployed to sandbox '${SANDBOX_NAME}'"
}
```

**SKILL.md path guard** — insert after `skill_dir="${SCRIPT_DIR}/.."` (after line 131), before the `nemoclaw skill install` call:
```bash
# Guard: SKILL.md must be present at the resolved path; if it is absent, the
# path resolved to ~/ or another wrong location (e.g., due to SSHFS mounts).
if [[ ! -f "${skill_dir}/SKILL.md" ]]; then
    fail "SKILL.md not found at ${skill_dir} — cannot determine skill root. Run the install from the skill directory: bash ~/.openclaw/skills/revenium/scripts/post-install-nemoclaw.sh"
fi
```

**In-sandbox exec + fail-hard gate style** — Gate A (lines 226–238):
```bash
local _min_prompt_chars=1500
local _prompt_json _prompt_chars
_prompt_json=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
    "openclaw agent --json --message 'ping' 2>/dev/null" 2>/dev/null || true)
_prompt_chars=$(echo "${_prompt_json}" | grep -oE '"promptChars"[[:space:]]*:[[:space:]]*[0-9]+' \
    | grep -oE '[0-9]+$' | head -1 || true)
if [ -z "${_prompt_chars}" ]; then
    fail "guard directive NOT injected — could not parse currentTurn.promptChars from openclaw agent --json. before_prompt_build may be inactive or untrusted. Aborting."
fi
if [ "${_prompt_chars}" -lt "${_min_prompt_chars}" ]; then
    fail "guard directive NOT injected — currentTurn.promptChars=${_prompt_chars} below ${_min_prompt_chars}; before_prompt_build inactive or untrusted. Aborting."
fi
info "Gate A passed: currentTurn.promptChars=${_prompt_chars} >= ${_min_prompt_chars} — directive injected"
```

**`✓ ready` discovery assertion** — add after `nemoclaw skill install` succeeds, before `ledger_set "skill-installed-nemoclaw"` (between lines 133 and 135). Mirrors Gate A/B style exactly:
```bash
# Assert ✓ ready in-sandbox (D-02 discovery assertion)
local _skill_list
_skill_list=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
    "openclaw skills list 2>/dev/null" 2>/dev/null || true)
if ! echo "${_skill_list}" | grep "revenium" | grep -q "ready"; then
    fail "revenium skill NOT ready after install — 'openclaw skills list' did not show ready state for revenium. Inspect the sandbox: nemoclaw ${SANDBOX_NAME} status"
fi
info "revenium skill confirmed ready in sandbox"
```

**Critical: `|| true` on every pipeline inside `$()`** — this is the CR-01 pattern from Gate A (line 229). Under `set -euo pipefail`, a `grep` that finds no match (exit 1) inside `$()` causes silent abort without printing the `fail` message. The `|| true` guard is mandatory on every in-sandbox command substitution.

**Success banner edit** — remove line 540:
```bash
# DELETE this line:
echo "  Phase 16 (skill deploy + docs) still pending."
```

---

### `docs/nemoclaw-setup.md` (docs — NEW)

**Analog:** `README.md` lines 1–316 — the canonical section structure, prose tone, fenced-code-block style, and blockquote-caveat format to mirror.

**README.md section skeleton** (lines 1–316 verbatim section headers and their line ranges):

| README.md Section | Line Range | NemoClaw Parallel Section |
|-------------------|-----------|---------------------------|
| `## Prerequisites` | 6–16 | Prerequisites (Linux, Docker, NemoClaw, sshfs, env vars, no brew) |
| `### 1. Install the skill from ClawHub` | 20–28 | Step 1: Run `post-install-nemoclaw.sh` |
| `### 2. Run post-install setup` | 30–54 | Step 2: Verify `✓ ready` |
| `### 3. Set Revenium credentials` | 59–73 | Step 3: Credentials via env vars (not `revenium config set`) |
| `### 4. Restart the OpenClaw gateway` | 76–82 | Step 4: Verify meter probe |
| `### 5. Verify` | 84–90 | (covered by Step 2 assertion) |
| `## Setup` | 168–182 | Setup (same — agent-driven via SKILL.md) |
| `## How It Works` | 184–227 | How It Works (NemoClaw: host-side metering loop via share mount, not Docker bind-mount) |
| `## Configuration` | 233–268 | Configuration (same config.json; credentials at `/sandbox/.config/revenium/config.yaml`, not `~/.config`) |
| `## Uninstalling` | 273–285 | Uninstalling (add: clear cron, uninstall plugin, `nemoclaw skill remove`) |
| `## Troubleshooting` | 287–312 | Troubleshooting (macOS refusal exact string; SSHFS unsafe-filename error; sandbox restart) |

**README.md prose tone patterns to copy** (lines 38–51, blockquote caveat pattern):
```markdown
> **About the VirusTotal warning:** ClawHub may display a warning that this skill is "flagged as suspicious by VirusTotal Code Insight." ...

> **Already have prerequisites installed?** Pass `--skip-prereqs` to skip Homebrew installs and fail immediately if anything is missing.
```

**README.md fenced command block pattern** (lines 22–24):
```markdown
```bash
clawhub install --force --dir ~/.openclaw/skills revenium
```
```

**README.md verify step pattern** (lines 85–90) — the `✓ ready` target output format to document:
```markdown
```bash
openclaw skills list
```

You should see `revenium` in the list (`✓ ready`). ...
```

**Expected output shape** (from README.md line 152):
```
✓ ready  💰 revenium
```

**macOS exact error string** — from `scripts/install.sh` lines 76–84, the literal output the operator sees (the `fail` helper prepends `  ✗ `):
```
  ✗ NemoClaw is unsupported on macOS.

  NemoClaw/OpenShell is a Linux-only stack. IMPORTANT: NemoClaw's own
  installer graceful-skips on Darwin (exits 0 without provisioning the
  sandbox) — this looks like success but never installs anything.

  To use the NemoClaw path, provision a Linux host (bare-metal, VM, or
  cloud) with Docker. The standalone OpenClaw path (default, no --nemoclaw
  flag) continues to work on macOS.
```

**Required cross-references to include in the runbook:**
- `SKILL.md` — skill manifest; enforcement directives
- `BUDGET-GUARD.md` — the guardrail directive content (explains why the plugin is mandatory)
- `README.md` — pointer back to standalone path ("For standalone OpenClaw + Docker, see README.md")

**D-04 required sections checklist** (all must appear):
- Prerequisites: Linux, Docker, NemoClaw installed, `sshfs`, `revenium` binary (tarball, not brew), env vars
- Install command sequence
- `✓ ready` verification
- Parallel-path guarantee explainer (standalone path untouched)
- macOS-unsupported constraint with exact error message above
- Troubleshooting
- Uninstall

---

### `tests/test_nemoclaw_provisioning.sh` (test — MODIFY)

**Changes required:** Add a new test group (GROUP I or GROUP H continuation) covering:
- (a) SKILL.md guard fires with actionable message when `SKILL.md` is absent at the resolved skill path
- (b) `✓ ready` assertion fails hard when `openclaw skills list` in-sandbox does not contain "ready" near "revenium"
- (c) `✓ ready` assertion passes when output matches expected shape

**Analog:** Same file — existing groups follow a consistent pattern. The closest match is GROUP A (lines 136–169, proxy-block fail-hard gate) and GROUP G (lines 316–343, full-success run + ledger key assertions).

**Test harness boilerplate** (lines 33–56):
```bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROVISION_SH="${REPO_ROOT}/scripts/post-install-nemoclaw.sh"
STUB_SH="${SCRIPT_DIR}/stub-nemoclaw.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
```

**`make_home` helper** (lines 84–102) — creates isolated tmp HOME with `.nemoclaw/` ledger dir, stub `nemoclaw` symlink on PATH, and stub probe script:
```bash
make_home() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-nemo-prov.XXXXXX")
  TMP_HOMES+=("${d}")
  mkdir -p "${d}/.nemoclaw" "${d}/.local/bin"
  ln -sf "${SCRIPT_DIR}/stub-nemoclaw.sh" "${d}/.local/bin/nemoclaw"
  cat > "${d}/stub-probe-host-compat.sh" << 'EOF'
#!/usr/bin/env bash
echo "  ✓ [stub] host compatibility preflight passed (test mode)"
exit 0
EOF
  chmod +x "${d}/stub-probe-host-compat.sh"
  echo "${d}"
}
```

**`run_provision` helper** (lines 110–132) — runs `post-install-nemoclaw.sh` with stub env, captures combined stdout+stderr:
```bash
run_provision() {
  local home_dir="$1"
  local argv_file="$2"
  shift 2

  local ledger_file="${home_dir}/.nemoclaw/revenium-nemoclaw.ledger"
  local stub_probe="${home_dir}/stub-probe-host-compat.sh"

  STUB_NEMOCLAW_ARGV_FILE="${argv_file}" \
  LEDGER_FILE="${ledger_file}" \
  HOME="${home_dir}" \
  PATH="${home_dir}/.local/bin:${PATH}" \
  REVENIUM_SANDBOX_NAME="${REVENIUM_SANDBOX_NAME:-test-sandbox}" \
  REVENIUM_API_KEY="${REVENIUM_API_KEY:-test-key}" \
  PROBE_SCRIPT="${stub_probe}" \
  "$@" \
  bash "${PROVISION_SH}" 2>&1
}
```

**GROUP-A fail-hard assertion pattern** (lines 147–169) — template for "script exits non-zero + output contains expected wording":
```bash
exit_code_a=0
output_a=$(STUB_NEMOCLAW_CURL_HTTP_CODE=000 \
           run_provision "${TMP_HOME_A}" "${ARGV_A}" 2>&1) || exit_code_a=$?

if echo "${output_a}" | grep -qi "api.revenium.ai"; then
  pass "GROUP-A: output mentions api.revenium.ai on proxy block"
else
  fail "GROUP-A: api.revenium.ai NOT in output on proxy block"
fi

if [[ "${exit_code_a}" -ne 0 ]]; then
  pass "GROUP-A: run exits non-zero on proxy block"
else
  fail "GROUP-A: run exited 0 on proxy block — expected non-zero (install should abort)"
fi
```

**Ledger pre-population pattern** (lines 267–270, GROUP E style) — for tests that need to pre-seed ledger state:
```bash
echo "cli-delivered=v1.2.0:cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67" \
  > "${LEDGER_E}"
```

**New GROUP I stub extension required** — to test the SKILL.md guard and `✓ ready` assertion, `stub-nemoclaw.sh` must handle:
1. `skill install` subcommand: exit 0 (default pass) or exit 1 (controlled via `STUB_NEMOCLAW_SKILL_INSTALL_RC`).
2. `exec` with `openclaw skills list` payload: echo `STUB_NEMOCLAW_SKILLS_LIST_OUTPUT` (default: `✓ ready  💰 revenium`) or a non-matching string (via `STUB_NEMOCLAW_SKILL_NOT_READY=1`).

The existing stub at `tests/stub-nemoclaw.sh` (lines 98–156) uses the `exec` subcommand dispatcher with `grep -qF` payload inspection — the new cases append to this dispatcher in the same style:
```bash
# --- openclaw skills list (skill discovery assertion) ---
if grep -qF "openclaw skills list" "${_payload_file}"; then
  rm -f "${_payload_file}"
  if [[ -n "${STUB_NEMOCLAW_SKILL_NOT_READY:-}" ]]; then
    echo "No skills installed."
    exit 0
  else
    echo "${STUB_NEMOCLAW_SKILLS_LIST_OUTPUT:-✓ ready  💰 revenium}"
    exit 0
  fi
fi
```

**Summary section pattern** (lines 376–387):
```bash
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
```

---

### `README.md` (docs — MODIFY, minimal)

**Change required:** One pointer link added to the Installation section. No other changes.

**Analog:** `README.md` lines 24–28 (the existing VirusTotal blockquote warning) — same blockquote syntax:
```markdown
> **About the VirusTotal warning:** ClawHub may display a warning ...
```

**Exact text to insert** (after the Installation section heading or after Step 5 Verify, at discretion):
```markdown
> **Running on NemoClaw/OpenShell?** See [NemoClaw Setup](docs/nemoclaw-setup.md) for the parallel install path.
```

**Placement anchor** — end of the `### 5. Verify` block (after line 90), before the `### First-time setup (automatic)` subsection at line 92. This is the logical end of the primary installation path where a NemoClaw operator would diverge.

---

## Shared Patterns

### Fail-hard `fail "..."` idiom
**Source:** `scripts/post-install-nemoclaw.sh` line 55 (definition), lines 133, 172, 184, 232–237, 248–251, 256, 263–266 (usage throughout gates)
**Apply to:** All new `fail` calls in `install_skill_nemoclaw()` modifications
```bash
fail()  { echo ""; echo "  ✗ $*" >&2; exit 1; }
```
Every `fail` message must be actionable — tell the operator what to check or how to recover. See existing messages: `"Check sandbox: nemoclaw ${SANDBOX_NAME} status"`, `"Run the install from the skill directory: bash ~/.openclaw/skills/revenium/scripts/post-install-nemoclaw.sh"`.

### `|| true` on in-sandbox command substitutions (CR-01 guard)
**Source:** `scripts/post-install-nemoclaw.sh` lines 229, 244, 302, 441
**Apply to:** All new `$()` blocks that run `nemoclaw exec` commands
```bash
_output=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
    "<command> 2>/dev/null" 2>/dev/null || true)
```
Without `|| true`, a non-zero exit from the in-sandbox command causes the script to abort under `set -euo pipefail` before the `fail` message prints. This is the CR-01 regression documented in Phase 15.

### Ledger-gate idempotency wrapper
**Source:** `scripts/post-install-nemoclaw.sh` lines 63–83 (`ledger_has`/`ledger_set`), pattern repeated in every provisioning function
**Apply to:** Any future gates that are expensive to repeat
```bash
if ledger_has "key"; then
    info "Already done (ledger) — skipping."
    return 0
fi
# ... do work ...
ledger_set "key" "1"
```
For `install_skill_nemoclaw()`, the `✓ ready` assertion runs inside the `if ! ledger_has` block — assertion passes → `ledger_set`; assertion fails → `fail` (key NOT written, re-run retries).

### Test group structure (hermetic bash)
**Source:** `tests/test_nemoclaw_provisioning.sh` lines 136–169 (GROUP A), lines 316–343 (GROUP G)
**Apply to:** All new test groups (GROUP I for SKILL.md guard + `✓ ready` assertion)
Each group follows: `make_home` → optional `STUB_*` env var → `run_provision` with exit code capture → `grep -qi` / `grep -qF` assertions → `pass` / `fail` calls. Never `eval` captured output.

### `grep -qF` (fixed-string) for ledger assertions
**Source:** `tests/test_nemoclaw_provisioning.sh` lines 249, 303–304, 328–330
**Apply to:** All new test ledger assertions
```bash
if [[ -f "${LEDGER_X}" ]] && grep -qE "^${key}=" "${LEDGER_X}" 2>/dev/null; then
```
Use `grep -qE "^key="` anchored to start of line to prevent partial-match false positives (IN-01 principle from GROUP G comment).

---

## No Analog Found

None — all four files have close analogs in the codebase.

---

## Metadata

**Analog search scope:** `scripts/`, `tests/`, `README.md`, `docs/` (does not yet exist)
**Files scanned:** `scripts/post-install-nemoclaw.sh` (541 lines), `scripts/install.sh` (106 lines), `README.md` (316 lines), `tests/test_nemoclaw_provisioning.sh` (387 lines), `tests/stub-nemoclaw.sh` (161 lines)
**Pattern extraction date:** 2026-06-10
