# Phase 12: Parallel Install Scaffolding & Detection — Pattern Map

**Mapped:** 2026-06-07
**Files analyzed:** 4 (3 new scripts + 1 new test)
**Analogs found:** 4 / 4

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---|---|---|---|---|
| `scripts/install.sh` | dispatcher / utility | request-response (flag parse → route → exec) | `scripts/post-install.sh` lines 1–39 + `scripts/install-cron.sh` lines 22–32 | role-match (same `set -euo pipefail`, same `case` arg parse, same helper idioms) |
| `scripts/post-install-nemoclaw.sh` | installer skeleton | request-response (sequential steps, stub functions) | `scripts/post-install.sh` lines 1–119 | role-match (identical structure; different payload) |
| `scripts/probe-host-compat.sh` | preflight probe | batch (check → emit verdict → exit code) | `.claude/skills/spike-findings-openclaw-revenium/sources/001-nemoclaw-bootstrap/probe-host-compat.sh` | **exact — copy verbatim** |
| `tests/test_install_dispatcher.sh` | test | event-driven (run subprocess → assert exit code + stdout) | `tests/test_guardrail_argv.sh` + `tests/test_write_marker.sh` | exact (same PASS/FAIL counter pattern, same `mktemp -d` HOME isolation, same env-var stub injection) |

---

## Pattern Assignments

### `scripts/install.sh` (dispatcher, request-response)

**Primary analog:** `scripts/post-install.sh`
**Secondary analog:** `scripts/install-cron.sh` (for `case` arg-parse with shift-2 style)

**Byte-stability constraint:** `scripts/post-install.sh` MUST NOT be modified in any way — not even whitespace. The dispatcher invokes it as a subprocess.

**Shebang + set discipline** (`scripts/post-install.sh` line 1, 14):
```bash
#!/usr/bin/env bash
set -euo pipefail
```

**SCRIPT_DIR resolution pattern** (`scripts/post-install.sh` line 21 / `scripts/install-cron.sh` line 8):
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```
Use this exact form. `${BASH_SOURCE[0]}` is robust when the script is symlinked or sourced.

**Helper function definitions** (`scripts/post-install.sh` lines 34–39):
```bash
info()  { echo "  ✓ $*"; }
warn()  { echo "  ⚠ $*"; }
step()  { echo ""; echo "▸ $*"; }
fail()  { echo ""; echo "  ✗ $*" >&2; exit 1; }

command_exists() { command -v "$1" &>/dev/null; }
```
Copy these verbatim into `install.sh` and `post-install-nemoclaw.sh`. Do NOT import from `common.sh` — `common.sh` defines different `info`/`warn`/`error` functions that write to a log file (lines 143–145), which is wrong for the install UX.

**Flag parse pattern** (`scripts/post-install.sh` lines 25–29):
```bash
SKIP_PREREQS=false

for arg in "$@"; do
  case "${arg}" in
    --skip-prereqs) SKIP_PREREQS=true ;;
  esac
done
```
Mirror this loop for `--nemoclaw` in `install.sh`. Add a `PASSTHROUGH_ARGS=()` accumulator for flags that belong to the routed target scripts:
```bash
NEMOCLAW_FLAG=false
PASSTHROUGH_ARGS=()
for arg in "$@"; do
  case "${arg}" in
    --nemoclaw) NEMOCLAW_FLAG=true ;;
    *)          PASSTHROUGH_ARGS+=("${arg}") ;;
  esac
done
```
The `install-cron.sh` lines 22–32 show the `shift`-style `case` for multi-value flags — not needed here since `--nemoclaw` is a boolean toggle. Use the simpler `for arg in "$@"` loop from `post-install.sh`.

**Testable OS detection override** (specified in `12-RESEARCH.md` Pattern 2):
```bash
# Always use this form — never bare $(uname -s) — so tests can override.
_os="${STUB_UNAME_S:-$(uname -s)}"
```

**D-03 routing precedence** (locked by `12-CONTEXT.md` D-03, verbatim from `12-RESEARCH.md` Pattern 1):
```bash
_nemoclaw_dir="${HOME}/.nemoclaw"
_openclaw_dir="${HOME}/.openclaw"
TARGET="standalone"

if [[ "${NEMOCLAW_FLAG}" == true ]] || [[ "${NEMOCLAW:-}" == "1" ]]; then
    TARGET="nemoclaw"
elif [[ -d "${_nemoclaw_dir}" ]] && [[ ! -d "${_openclaw_dir}" ]]; then
    TARGET="nemoclaw"
fi
# Both dirs present + no flag → TARGET stays "standalone" (D-03 dual-home rule)
```
Note: use `${HOME}/.nemoclaw` (not a hardcoded path) so `HOME=$(mktemp -d)` overrides work in tests.

**macOS refusal pattern** (`12-RESEARCH.md` Pattern 2, D-05/D-06):
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
The Darwin graceful-skip trap MUST be named explicitly in the message — this is a user-safety requirement (NCINST-02), not cosmetic polish.

**Script-existence guard before exec** (`12-RESEARCH.md` Open Question 3):
```bash
[[ -f "${SCRIPT_DIR}/post-install-nemoclaw.sh" ]] \
    || fail "post-install-nemoclaw.sh not found in ${SCRIPT_DIR}"
[[ -f "${SCRIPT_DIR}/post-install.sh" ]] \
    || fail "post-install.sh not found in ${SCRIPT_DIR}"
```

**Routing dispatch** (`12-RESEARCH.md` Pattern 1 code example):
```bash
if [[ "${TARGET}" == "nemoclaw" ]]; then
    bash "${SCRIPT_DIR}/post-install-nemoclaw.sh" \
        "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"
else
    bash "${SCRIPT_DIR}/post-install.sh" \
        "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"
fi
```
The `${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}` form handles the empty-array case under `set -u` (avoids "unbound variable" on bash 4.x). This idiom appears in `scripts/post-install.sh` array usage at lines 192 and 301.

---

### `scripts/post-install-nemoclaw.sh` (installer skeleton, request-response)

**Primary analog:** `scripts/post-install.sh`

Uses the same structure: shebang → `set -euo pipefail` → constants → helper function defs → sequential `step` blocks → final success banner.

**Shebang + discipline** (copy from `post-install.sh` lines 1, 14):
```bash
#!/usr/bin/env bash
set -euo pipefail
```

**Constants block** (mirror `post-install.sh` lines 19–22 structure):
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE_SCRIPT="${SCRIPT_DIR}/probe-host-compat.sh"
```

**Helper functions** (copy verbatim from `post-install.sh` lines 34–39 — same UX icons):
```bash
info()  { echo "  ✓ $*"; }
warn()  { echo "  ⚠ $*"; }
step()  { echo ""; echo "▸ $*"; }
fail()  { echo ""; echo "  ✗ $*" >&2; exit 1; }

command_exists() { command -v "$1" &>/dev/null; }
```

**PATH extension for `~/.local/bin`** (`12-RESEARCH.md` Pattern 5 + Pitfall 6; mirrors `install-cron.sh` lines 70–83):
```bash
# NemoClaw installs its CLI at ~/.local/bin — extend PATH so command_exists works.
export PATH="${HOME}/.local/bin:${PATH}"
```

**Preflight probe invocation** (`12-RESEARCH.md` Pattern 3, D-08/D-09):
```bash
step "Running host compatibility preflight"
if ! bash "${PROBE_SCRIPT}"; then
    fail "Host compatibility check failed — NemoClaw requires a Linux host with Docker."
fi
info "Preflight complete (warnings above are non-blocking)"
```
CRITICAL: invoke as `bash "${PROBE_SCRIPT}"` (subprocess), NEVER `. "${PROBE_SCRIPT}"` (source). The probe defines `pass`, `warn`, `fail` counter variables that would collide with the parent's `fail()` function if sourced.

**NemoClaw CLI presence check** (`12-RESEARCH.md` Pattern 5, D-10; mirrors `post-install.sh` lines 64–74 structure):
```bash
step "Checking NemoClaw CLI"
if command_exists nemoclaw; then
    info "nemoclaw CLI found: $(command -v nemoclaw)"
else
    warn "nemoclaw CLI not found on PATH — ensure ~/.local/bin is in PATH"
    warn "NemoClaw installs its CLI at ~/.local/bin. Add: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi
```

**Stub function pattern** (`12-RESEARCH.md` Pattern 4, D-07):
```bash
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
```
Name as named functions (not inline comments) so Phase 13+ can replace `stub_provision_egress_policy()` with real implementation at a well-defined insertion point.

**Idempotency idiom** (`post-install.sh` lines 127–136 — `command_exists`-guarded check + warn-and-continue):
```bash
if [[ ! -f "${SOME_FILE}" ]]; then
    # ... create it
else
    info "already present — leaving untouched"
fi
```
No ledger at skeleton stage (D-11). All Phase 12 actions are naturally idempotent (preflight = read-only; stubs = no-ops).

**Non-interactive guard** (copy from `post-install.sh` lines 482–490 — protect against detached runs where `</dev/null` sends EOF to `read`):
```bash
if [[ -t 0 && -t 1 ]]; then
    # interactive prompt here
else
    info "Non-interactive shell — defaulting to ..."
fi
```
The NemoClaw skeleton has NO interactive steps this phase (all provisioning is stubbed), so no `read` calls should appear in `post-install-nemoclaw.sh`. Verify this before committing.

**Success banner** (mirror `post-install.sh` lines 737–752 style):
```bash
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  NemoClaw path skeleton complete."
echo ""
echo "  Phases 13–16 will implement sandbox provisioning."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

---

### `scripts/probe-host-compat.sh` (preflight probe, batch)

**Source:** `.claude/skills/spike-findings-openclaw-revenium/sources/001-nemoclaw-bootstrap/probe-host-compat.sh`
**Action:** Copy verbatim — all logic and exit-code contract must be preserved byte-for-byte.

**Exit-code contract** (`probe-host-compat.sh` lines 121–131):
- `exit 1` — `fail > 0` (OS non-Linux or Docker absent on non-Linux) → hard gate, stop install
- `exit 0` — `warn > 0` (RAM/disk/GPU/Node soft caps) → print warnings, continue install
- `exit 0` — `pass > 0, warn = 0, fail = 0` → clean pass, continue install

**Key design facts (do NOT alter when copying):**
- `set -u` only (line 16) — NOT `set -e`. Running it as a subprocess (`bash`) prevents `set -e` inheritance from the parent.
- Docker on Linux is a `wn` (warn), not `no` (fail) — lines 64–66. NemoClaw's own installer provisions Docker.
- Counter variable names are `pass`, `warn`, `fail` — these would collide with `post-install-nemoclaw.sh`'s `fail()` function if sourced. Always exec, never source.

**Only permitted modification:** Update the banner comment at lines 1–16 to reflect the file's new role as a first-class install-time preflight script (change "Spike 001 — NemoClaw bootstrap feasibility probe" to "Revenium NemoClaw Install — Host Compatibility Preflight"). Keep all logic identical.

---

### `tests/test_install_dispatcher.sh` (test, event-driven)

**Primary analog:** `tests/test_guardrail_argv.sh`
**Secondary analog:** `tests/test_write_marker.sh`

**File header + `set` discipline** (`tests/test_guardrail_argv.sh` lines 1–36):
```bash
#!/usr/bin/env bash
# =============================================================================
# test_install_dispatcher.sh — Integration tests for install.sh dispatcher
# =============================================================================

set -uo pipefail   # NOT set -e — test failures are soft (FAIL counter)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/scripts/install.sh"
```
Note `set -uo pipefail` without `-e` — test assertions use `|| true` to prevent early exit on expected failures.

**PASS/FAIL counter + functions** (`tests/test_guardrail_argv.sh` lines 39–43 / `tests/test_write_marker.sh` lines 19–22):
```bash
PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
```
`((PASS++)) || true` is the established idiom — the `|| true` prevents `set -e` from tripping on the arithmetic expression when the result is 0.

**`mktemp -d` HOME isolation** (`tests/test_guardrail_argv.sh` lines 68–89 `make_openclaw_home` function / `tests/test_write_marker.sh` line 28):
```bash
# Per-test: create an isolated tmp HOME with the dir structure under test.
TMP_HOME=$(mktemp -d "${TMPDIR:-/tmp}/test-inst.XXXXXX")

# Create or omit .nemoclaw/ and .openclaw/ subdirs to exercise D-03 branches:
mkdir -p "${TMP_HOME}/.nemoclaw"   # NemoClaw-only host
# mkdir -p "${TMP_HOME}/.openclaw"  # (omit for NemoClaw-only test)
```

**Cleanup trap** (`tests/test_guardrail_argv.sh` lines 106–109):
```bash
cleanup() {
  rm -rf "${TMP_FAKE_HOME}" "${ARGV_FILE}" 2>/dev/null || true
}
trap cleanup EXIT
```
Each test group should `rm -rf "${TMP_HOME}"` at the end of the group (see `test_guardrail_argv.sh` lines 219, 255 etc.). A top-level trap handles the fake HOME.

**`STUB_UNAME_S` + `HOME` env-var injection pattern** (`tests/test_guardrail_argv.sh` `run_guardrail_check` lines 128–135 — adapted for the dispatcher):
```bash
run_install() {
    local uname_s="$1"
    local home_dir="$2"
    shift 2
    STUB_UNAME_S="${uname_s}" \
    HOME="${home_dir}" \
        bash "${INSTALL_SH}" "$@" 2>&1
}
```
This makes all four D-03 branches testable on macOS without a real NemoClaw host. Override `HOME` to control `~/.nemoclaw/` and `~/.openclaw/` presence; override `STUB_UNAME_S` to control OS detection.

**Exit-code capture pattern** (`tests/test_guardrail_argv.sh` lines 451–458):
```bash
exit_code=0
output=$(STUB_UNAME_S="Darwin" HOME="${TMP_HOME}" \
    bash "${INSTALL_SH}" --nemoclaw 2>&1) || exit_code=$?
if [[ "${exit_code}" -ne 0 ]] && echo "${output}" | grep -qi "unsupported\|graceful-skip"; then
    pass "D-05/D-06: macOS + --nemoclaw exits non-zero with Darwin trap message"
else
    fail "D-05/D-06: exit=${exit_code}, message missing or wrong"
fi
```
The `|| exit_code=$?` idiom captures a non-zero exit without triggering `set -e`.

**Group structure** (pattern from `test_guardrail_argv.sh` — labeled echo headers):
```bash
echo ""
echo "--- GROUP A: D-03 auto-detect (NemoClaw-only host) ---"
# ... assertions ...
rm -rf "${TMP_HOME_A}"

echo ""
echo "--- GROUP B: D-03 explicit --nemoclaw flag ---"
# ...
```

**Summary block** (`tests/test_guardrail_argv.sh` lines 579–591):
```bash
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
```

**post-install.sh byte-stability assertion** (`12-RESEARCH.md` Pitfall 5 — add as a group):
```bash
echo ""
echo "--- GROUP byte-stable: post-install.sh not modified ---"
if git -C "${REPO_ROOT}" diff --name-only HEAD -- scripts/post-install.sh 2>/dev/null | grep -q .; then
    fail "byte-stable: scripts/post-install.sh appears modified — must be byte-stable"
else
    pass "byte-stable: scripts/post-install.sh has no uncommitted changes"
fi
```

**No PATH stub injection needed for `install.sh` tests** — unlike `test_guardrail_argv.sh` which stubs the `revenium` binary via `~/.local/bin`, the dispatcher tests exercise `install.sh` routing logic only; no external CLI is called. The NemoClaw-path test that exercises `post-install-nemoclaw.sh` will invoke `probe-host-compat.sh` as a subprocess, which will fail on Linux-check on macOS → the test should use `STUB_UNAME_S=Linux` when testing the full nemoclaw path, or intercept the probe call by checking output text only (not requiring it to succeed end-to-end).

---

## Shared Patterns

### `set -euo pipefail` discipline
**Source:** Every existing script — `scripts/post-install.sh` line 14, `scripts/common.sh` line 15 (set -uo only, sourced lib), `scripts/install-cron.sh` line 6.
**Apply to:** `scripts/install.sh`, `scripts/post-install-nemoclaw.sh`.
**NOT in:** `scripts/probe-host-compat.sh` (uses `set -u` only, line 16 — preserve verbatim).
**NOT in:** `tests/test_install_dispatcher.sh` (uses `set -uo pipefail` without `-e`, standard for test files).

### Helper function idioms (`info`/`warn`/`step`/`fail` + `command_exists`)
**Source:** `scripts/post-install.sh` lines 34–39.
**Apply to:** `scripts/install.sh`, `scripts/post-install-nemoclaw.sh`.
**Critical distinction:** These are the install-UX helpers (echo with icons). Do NOT use `common.sh`'s `info()`/`warn()` (those log to a file — lines 143–145 — wrong for the install context).

### `SCRIPT_DIR` resolution
**Source:** `scripts/post-install.sh` line 21, `scripts/install-cron.sh` line 8.
**Pattern:** `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
**Apply to:** `scripts/install.sh`, `scripts/post-install-nemoclaw.sh`.

### `mktemp -d` + `trap cleanup EXIT` for test isolation
**Source:** `tests/test_guardrail_argv.sh` lines 96–109, `tests/test_write_marker.sh` lines 28, 46–49.
**Apply to:** `tests/test_install_dispatcher.sh` — every test group gets its own `mktemp -d` HOME and cleans up after itself.

### `STUB_*` env-var convention for test overrides
**Source:** `tests/stub-revenium.sh` (canonical definition of `STUB_REVENIUM_*` convention), `tests/test_guardrail_argv.sh` (usage of `HOME=`, `OPENCLAW_HOME=`, `STUB_REVENIUM_*=`).
**Apply to:** `tests/test_install_dispatcher.sh` — use `STUB_UNAME_S=` for OS override, `HOME=` for dir-existence override. These follow the established `STUB_` prefix naming convention.

### Array expansion under `set -u`
**Source:** `scripts/post-install.sh` lines 192, 301 — `"${ARRAY[@]+"${ARRAY[@]}"}"`
**Apply to:** `scripts/install.sh` when forwarding `PASSTHROUGH_ARGS` to the routed script.

---

## No Analog Found

None. All four files have close analogs in the existing codebase.

---

## Anti-Patterns to Avoid (from RESEARCH.md)

| Anti-Pattern | Source | Why |
|---|---|---|
| Sourcing `probe-host-compat.sh` with `. "${PROBE_SCRIPT}"` | Pitfall 2 | `pass`/`warn`/`fail` counter variables collide with parent's `fail()` function; exit 1 from probe terminates the parent without error handling |
| Calling bare `$(uname -s)` in `install.sh` | Pitfall 3 / Pattern 2 | Makes OS-detection untestable on non-Linux dev machine; always use `"${STUB_UNAME_S:-$(uname -s)}"` |
| Hardcoding `~/.nemoclaw` as a literal path | Pitfall 1 | Use `"${HOME}/.nemoclaw"` so `HOME=$(mktemp -d)` override works in tests |
| Any modification to `scripts/post-install.sh` | D-01/D-02 | Byte-stable constraint; breaking it causes standalone-path regression |
| `read` calls in `install.sh` or `post-install-nemoclaw.sh` | Pitfall 4 | Detached runs via `setsid … </dev/null` cause `read` to get EOF and produce silent wrong defaults |
| Inlining probe into `post-install-nemoclaw.sh` | D-09, Pitfall 2 | Entangles variable namespaces; loses the clean exit-code contract and reusability |
| Using `common.sh` `info()`/`warn()` in install scripts | — | `common.sh` helpers write to a log file and are designed for cron context, not interactive install UX |

---

## Metadata

**Analog search scope:** `scripts/`, `tests/`, `.claude/skills/spike-findings-openclaw-revenium/sources/`
**Files read:** `scripts/post-install.sh`, `scripts/common.sh`, `scripts/install-cron.sh` (lines 1–100), `tests/test_guardrail_argv.sh`, `tests/test_write_marker.sh` (lines 1–80), `tests/stub-revenium.sh`, `.claude/skills/spike-findings-openclaw-revenium/sources/001-nemoclaw-bootstrap/probe-host-compat.sh`
**Pattern extraction date:** 2026-06-07
