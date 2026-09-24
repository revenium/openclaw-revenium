# Phase 13: Sandbox Provisioning — Egress, CLI & Authenticated Metering - Pattern Map

**Mapped:** 2026-06-08
**Files analyzed:** 6
**Analogs found:** 6 / 6

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `scripts/post-install-nemoclaw.sh` | provisioning script | request-response + CRUD | `scripts/post-install-nemoclaw.sh` (Phase 12 skeleton) | exact — this is the file being extended |
| `scripts/revenium-policy.yaml` | config/preset | file-I/O | `.claude/skills/spike-findings-openclaw-revenium/sources/002-openshell-egress/revenium-policy.yaml` | exact copy |
| `scripts/gh-release-policy.yaml` | config/preset | file-I/O | `.claude/skills/spike-findings-openclaw-revenium/sources/003-revenium-cli-in-sandbox/gh-release-policy.yaml` | exact copy |
| `tests/test_nemoclaw_provisioning.sh` | test | request-response | `tests/test_install_dispatcher.sh` | role-match |
| `tests/stub-nemoclaw.sh` | test utility | request-response | `tests/stub-revenium.sh` | exact pattern |

---

## Pattern Assignments

### `scripts/post-install-nemoclaw.sh` (provisioning script — modified)

**Analog:** `scripts/post-install-nemoclaw.sh` (Phase 12 skeleton) + `scripts/post-install.sh` (credential model)

**Script header + set discipline** (post-install-nemoclaw.sh lines 1-22):
```bash
#!/usr/bin/env bash
# [header comment block]

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROBE_SCRIPT="${SCRIPT_DIR}/probe-host-compat.sh"
```

**New constants to add** (after existing constants — per RESEARCH.md §Existing Code Integration):
```bash
LEDGER_FILE="${HOME}/.nemoclaw/revenium-nemoclaw.ledger"
REVENIUM_CLI_VERSION="v1.2.0"
REVENIUM_CLI_TARBALL_SHA256="cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67"
REVENIUM_CLI_URL="https://github.com/revenium/revenium-cli/releases/download/${REVENIUM_CLI_VERSION}/revenium-cli_${REVENIUM_CLI_VERSION#v}_linux_amd64.tar.gz"
```

**Helper idioms** (post-install-nemoclaw.sh lines 33-38 — copy verbatim; same in post-install.sh lines 34-39):
```bash
info()  { echo "  ✓ $*"; }
warn()  { echo "  ⚠ $*"; }
step()  { echo ""; echo "▸ $*"; }
fail()  { echo ""; echo "  ✗ $*" >&2; exit 1; }

command_exists() { command -v "$1" &>/dev/null; }
```

**PATH extension idiom** (post-install-nemoclaw.sh line 43 — keep as-is):
```bash
export PATH="${HOME}/.local/bin:${PATH}"
```

**Ledger helper pattern** (from RESEARCH.md §Ledger Format — introduces two functions):
```bash
ledger_has() {
    local key="$1"
    grep -q "^${key}=" "${LEDGER_FILE}" 2>/dev/null
}

ledger_set() {
    local key="$1" val="$2"
    mkdir -p "$(dirname "${LEDGER_FILE}")"
    { grep -v "^${key}=" "${LEDGER_FILE}" 2>/dev/null || true; \
      echo "${key}=${val}"; } > "${LEDGER_FILE}.tmp" && \
      mv "${LEDGER_FILE}.tmp" "${LEDGER_FILE}"
}
```

**Step guard / idempotency pattern** (mirror of command_exists guard in post-install-nemoclaw.sh lines 88-94):
```bash
# Pattern: ledger-gate at top of every real step function
if ledger_has "revenium-policy-applied"; then
    info "Revenium egress policy already applied (ledger) — skipping."
    return 0
fi
```

**Preflight guard pattern** (post-install-nemoclaw.sh lines 72-80 — unchanged, already correct):
```bash
step "Running host compatibility preflight"

[[ -f "${PROBE_SCRIPT}" ]] \
    || fail "probe-host-compat.sh not found at ${PROBE_SCRIPT}"

if ! bash "${PROBE_SCRIPT}"; then
    fail "Host compatibility check failed — NemoClaw requires a Linux host with Docker."
fi
info "Preflight complete (warnings above are non-blocking)"
```

**Conditional env var read pattern** (post-install.sh lines 246-260 — mirrors the REVENIUM_* model for write_revenium_creds):
```bash
[[ -n "${REVENIUM_API_KEY:-}" ]] \
    || fail "REVENIUM_API_KEY not set — export it before running the install"
```

**Warn-and-skip for optional env vars** (post-install.sh lines 256-260):
```bash
if [[ -z "${REV_KEY}" ]]; then
  warn "Revenium API key not set yet."
  warn "Set credentials on the host, then re-run post-install.sh to inject them."
fi
```

**File-not-found guard** (used throughout post-install-nemoclaw.sh lines 74-75):
```bash
[[ -f "${preset_src}" ]] || fail "revenium-policy.yaml not found at ${preset_src}"
```

**Egress probe + error classification** (RESEARCH.md §Pattern 1 — D-04 proxy-block vs reach distinction):
```bash
local http_code
http_code=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
    'curl -sS -o /dev/null -w "%{http_code}" https://api.revenium.ai/ 2>/dev/null' 2>/dev/null || echo "000")

if [[ "${http_code}" == "000" ]]; then
    fail "sandbox cannot reach api.revenium.ai — policy gap detected. Check that the revenium preset was applied: nemoclaw ${SANDBOX_NAME} policy-list"
fi
info "Egress to api.revenium.ai confirmed (HTTP ${http_code})"
```

**In-sandbox tarball deliver + SHA256 verify** (RESEARCH.md §Pattern 2 — D-01/D-02, exit code 2 = checksum mismatch):
```bash
nemoclaw "${SANDBOX_NAME}" exec -- sh -lc "
    set -e
    cd /tmp
    curl -fsSL -o rev.tgz '${tarball_url}'
    actual_sha=\$(sha256sum rev.tgz | awk '{print \$1}')
    if [ \"\${actual_sha}\" != '${expected_sha256}' ]; then
        echo \"CHECKSUM_MISMATCH:\${actual_sha}\" >&2
        exit 2
    fi
    tar xzf rev.tgz
    mkdir -p /sandbox/.local/bin
    install -m755 ./revenium /sandbox/.local/bin/revenium
    echo 'CLI_DELIVERED_OK'
" || {
    local rc=$?
    if [[ $rc -eq 2 ]]; then
        fail "revenium CLI sha256 mismatch — tarball may be tampered. Aborting install."
    fi
    fail "revenium CLI delivery failed (exit ${rc})"
}
```

**cli-delivered ledger value format** (RESEARCH.md §Pitfall 3 — version:sha256, not a boolean):
```bash
# cli-delivered stores version:tarball-sha256 so a version bump invalidates the key
local expected_cli_ledger="v1.2.0:cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67"
# Compare stored value against expected to detect version bumps:
stored=$(grep "^cli-delivered=" "${LEDGER_FILE}" | cut -d= -f2-)
if [[ "${stored}" == "${expected_cli_ledger}" ]]; then
    info "revenium CLI v1.2.0 already delivered and verified (ledger) — skipping."
    return 0
fi
warn "cli-delivered ledger entry exists but version/sha256 differs — re-delivering."
```

**Config.yaml write via nemoclaw exec** (RESEARCH.md §Pattern 3 — D-05, chmod 600, in-sandbox HOME = /sandbox):
```bash
nemoclaw "${SANDBOX_NAME}" exec -- sh -lc "
    mkdir -p /sandbox/.config/revenium
    cat > /sandbox/.config/revenium/config.yaml <<'YAML'
${config_content}
YAML
    chmod 600 /sandbox/.config/revenium/config.yaml
"
```

**Meter probe** (RESEARCH.md §Pattern 4 — D-06; all required flags; SSL_CERT_FILE; --task-type for synthetic tagging):
```bash
local now
now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

local meter_output
meter_output=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc "
    SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem \
    /sandbox/.local/bin/revenium meter completion \
        --model claude-sonnet-4-5 \
        --provider anthropic \
        --input-tokens 1 \
        --output-tokens 1 \
        --total-tokens 2 \
        --stop-reason END \
        --request-time '${now}' \
        --completion-start-time '${now}' \
        --response-time '${now}' \
        --request-duration 1000 \
        --task-type install-smoke-test \
        --output json 2>&1
" 2>&1) || true
```

**Success check pattern for meter probe** (RESEARCH.md §Pattern 4):
```bash
if echo "${meter_output}" | grep -qiE '"status"\s*:\s*"?(200|201|202|accepted|ok)"?|Metered successfully'; then
    ledger_set "meter-probe-passed" "1"
    info "Meter probe passed — authenticated meter call succeeded"
else
    fail "Meter probe failed. Output: ${meter_output}. Check REVENIUM_API_KEY and egress policy."
fi
```

**Success banner** (post-install-nemoclaw.sh lines 110-119 — replace Phase 12 skeleton message):
```bash
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  NemoClaw provisioning complete."
echo ""
echo "  Delivered:"
echo "    revenium CLI v1.2.0 at /sandbox/.local/bin/revenium"
echo "    credentials at /sandbox/.config/revenium/config.yaml"
echo "    meter probe passed (authenticated 2xx confirmed)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

---

### `scripts/revenium-policy.yaml` (config/preset — new file)

**Analog:** `.claude/skills/spike-findings-openclaw-revenium/sources/002-openshell-egress/revenium-policy.yaml`

**Full content to copy verbatim** (spike file, all 27 lines):
```yaml
# [descriptive comment block explaining tls: skip rationale]

preset:
  name: revenium
  description: "Revenium metering + guardrail API egress (api.revenium.ai)"

network_policies:
  revenium:
    name: revenium
    endpoints:
      - host: api.revenium.ai
        port: 443
        access: full
        tls: skip
    binaries:
      - { path: /** }
```

**Key constraint:** The `tls: skip` line is non-negotiable — L7 REST mode breaks Node 22 undici CONNECT tunnels. Remove the spike-specific comment header (referencing "Spike 002") and replace with a production-appropriate one referencing Phase 13.

---

### `scripts/gh-release-policy.yaml` (config/preset — new file)

**Analog:** `.claude/skills/spike-findings-openclaw-revenium/sources/003-revenium-cli-in-sandbox/gh-release-policy.yaml`

**Full content to copy verbatim** (spike file, all 18 lines — includes BOTH GitHub CDN hosts):
```yaml
preset:
  name: revenium-cli-install
  description: "Egress for installing the revenium CLI via GitHub release CDN"
network_policies:
  revenium_cli_install:
    name: revenium_cli_install
    endpoints:
      - host: release-assets.githubusercontent.com
        port: 443
        access: full
        tls: skip
      - host: objects.githubusercontent.com
        port: 443
        access: full
        tls: skip
    binaries:
      - { path: /** }
```

**Key constraint:** Both `release-assets.githubusercontent.com` AND `objects.githubusercontent.com` must be present — the CDN redirects between them; omitting either breaks the tarball fetch silently.

---

### `tests/test_nemoclaw_provisioning.sh` (test — new file)

**Analog:** `tests/test_install_dispatcher.sh`

**Script header + boilerplate** (test_install_dispatcher.sh lines 1-30):
```bash
#!/usr/bin/env bash
# =============================================================================
# test_nemoclaw_provisioning.sh — Hermetic tests for post-install-nemoclaw.sh
# provisioning logic (Phase 13: egress policy, CLI delivery, creds, meter probe)
#
# Strategy:
#   Stub nemoclaw with a configurable script on PATH.
#   Control behavior via STUB_NEMOCLAW_* env switches.
#   Pre-populate LEDGER_FILE via env override for skip/resume tests.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
POST_INSTALL="${REPO_ROOT}/scripts/post-install-nemoclaw.sh"
STUB_SH="${SCRIPT_DIR}/stub-nemoclaw.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
```

**Cleanup + trap pattern** (test_install_dispatcher.sh lines 36-44):
```bash
declare -a TMP_HOMES=()

cleanup() {
  for d in "${TMP_HOMES[@]+"${TMP_HOMES[@]}"}"; do
    rm -rf "${d}" 2>/dev/null || true
  done
}
trap cleanup EXIT
```

**Isolated tmp HOME helper** (test_install_dispatcher.sh lines 50-61 — adapt for ledger + env setup):
```bash
make_home() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/test-nem-prov.XXXXXX")
  TMP_HOMES+=("${d}")
  mkdir -p "${d}/.nemoclaw"
  echo "${d}"
}
```

**Stub-on-PATH invocation pattern** (test_guardrail_argv.sh lines 96-99):
```bash
TMP_LOCAL_BIN="${TMP_FAKE_HOME}/.local/bin"
mkdir -p "${TMP_LOCAL_BIN}"
ln -sf "${STUB_SH}" "${TMP_LOCAL_BIN}/nemoclaw"
export PATH="${TMP_LOCAL_BIN}:${PATH}"
```

**Script-under-test invocation pattern** (test_install_dispatcher.sh lines 68-75):
```bash
run_provision() {
  local home_dir="$1"
  shift
  STUB_NEMOCLAW_ARGV_FILE="${ARGV_FILE}" \
  LEDGER_FILE="${home_dir}/.nemoclaw/revenium-nemoclaw.ledger" \
  HOME="${home_dir}" \
      bash "${POST_INSTALL}" "$@" 2>&1
}
```

**Assert-output pattern** (test_install_dispatcher.sh lines 104-115):
```bash
if echo "${output}" | grep -qi "pattern"; then
  pass "GROUP-X: expected pattern found"
else
  fail "GROUP-X: expected pattern NOT found"
fi
```

**Summary + exit** (test_install_dispatcher.sh lines 249-260):
```bash
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
exit 0
```

**Group labels to implement** (from RESEARCH.md §Test Map):
- GROUP A: HTTP=000 probe triggers policy-gap error (NCEGRESS-01 SC2)
- GROUP B: HTTP=403 (server response) does NOT trigger policy-gap error
- GROUP C: SHA256 mismatch aborts install (NCCLI-01)
- GROUP D: SHA256 match proceeds to install
- GROUP E: `cli-delivered` ledger key with matching version skips re-delivery
- GROUP F: `meter-probe-passed` ledger key skips re-probe
- GROUP G: Success run — all 5 ledger keys written

---

### `tests/stub-nemoclaw.sh` (test utility — new file)

**Analog:** `tests/stub-revenium.sh`

**Header + security comment** (stub-revenium.sh lines 1-83):
```bash
#!/usr/bin/env bash
# stub-nemoclaw.sh — Argv-capturing nemoclaw stub for integration tests.
#
# Place a copy or symlink named "nemoclaw" on PATH pointing at this script.
# Set STUB_NEMOCLAW_ARGV_FILE to the path of a file where captured args are
# appended (one per line per invocation).
#
# Environment switches:
#
#   STUB_NEMOCLAW_CURL_HTTP_CODE=<code>
#     Controls the in-sandbox curl probe response (default: "403").
#     Set to "000" for proxy-block test (NCEGRESS-01 SC2).
#
#   STUB_NEMOCLAW_SHA256_MATCH=<0|1>
#     Controls whether the tarball sha256 matches (default: "1").
#     Set to "0" to test NCCLI-01 mismatch-abort path.
#
#   STUB_NEMOCLAW_METER_FAIL=1
#     Forces the meter probe to fail (emit bad JSON, exit non-zero).
#
# SECURITY: this stub only string-COMPAREs positional args and captures them
# with `printf '%s\n'`. It never `eval`s or string-interpolates captured argv.
```

**Argv capture** (stub-revenium.sh lines 88-92 — identical pattern):
```bash
if [[ -n "${STUB_NEMOCLAW_ARGV_FILE:-}" ]]; then
  for arg in "$@"; do
    printf '%s\n' "${arg}" >> "${STUB_NEMOCLAW_ARGV_FILE}"
  done
fi
```

**Subcommand dispatch structure** (stub-revenium.sh lines 97-236 — adapt for nemoclaw commands):
```bash
# policy-add dispatch
if [[ "$1" == *"policy-add"* ]] || { [[ $# -ge 2 ]] && [[ "$2" == "policy-add" ]]; }; then
  echo "Policy version loaded."
  exit 0
fi

# exec dispatch — returns configurable curl output or sha256 behavior
if [[ "$1" == *"exec"* ]] || { [[ $# -ge 2 ]] && [[ "$2" == "exec" ]]; }; then
  # Detect probe type from argv
  if printf '%s\n' "$@" | grep -qF 'http_code'; then
    echo "${STUB_NEMOCLAW_CURL_HTTP_CODE:-403}"
  elif printf '%s\n' "$@" | grep -qF 'sha256sum'; then
    if [[ "${STUB_NEMOCLAW_SHA256_MATCH:-1}" == "0" ]]; then
      echo "CHECKSUM_MISMATCH:badhash" >&2; exit 2
    else
      echo "cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67  rev.tgz"
    fi
  elif printf '%s\n' "$@" | grep -qF 'meter completion'; then
    if [[ -n "${STUB_NEMOCLAW_METER_FAIL:-}" ]]; then
      echo '{"error":"unauthorized"}' >&2; exit 1
    fi
    echo '{"status":"ok"}'
  fi
  exit 0
fi
```

**Default exit 0** (stub-revenium.sh line 236):
```bash
# Default — exit 0
exit 0
```

---

## Shared Patterns

### set -euo pipefail discipline
**Source:** `scripts/post-install-nemoclaw.sh` line 22, `scripts/install.sh` line 7, `scripts/post-install.sh` line 14
**Apply to:** `post-install-nemoclaw.sh` (already present — preserve), both new test files (use `set -uo pipefail` without `-e` per test_install_dispatcher.sh line 7)
```bash
# In scripts: strict mode
set -euo pipefail

# In tests: no -e (PASS/FAIL counters must not abort on assertion failures)
set -uo pipefail
```

### SCRIPT_DIR resolution
**Source:** `scripts/post-install-nemoclaw.sh` line 27, `scripts/install.sh` line 28
**Apply to:** All new bash scripts
```bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
```

### info/warn/step/fail helpers
**Source:** `scripts/post-install-nemoclaw.sh` lines 33-37 (canonical for provisioning scripts)
**Apply to:** `post-install-nemoclaw.sh` (keep existing definitions); do NOT redefine in tests (tests use `pass()`/`fail()` instead)
```bash
info()  { echo "  ✓ $*"; }
warn()  { echo "  ⚠ $*"; }
step()  { echo ""; echo "▸ $*"; }
fail()  { echo ""; echo "  ✗ $*" >&2; exit 1; }
```

### command_exists guard
**Source:** `scripts/post-install-nemoclaw.sh` line 38, `scripts/install.sh` line 38
**Apply to:** Any capability check before invoking `nemoclaw`
```bash
command_exists() { command -v "$1" &>/dev/null; }
```

### Test pass/fail counters
**Source:** `tests/test_install_dispatcher.sh` lines 30-31
**Apply to:** `tests/test_nemoclaw_provisioning.sh`
```bash
PASS=0
FAIL=0

pass() { echo "PASS: $1"; ((PASS++)) || true; }
fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
```

### argv-capture idiom (no eval)
**Source:** `tests/stub-revenium.sh` lines 88-92, `tests/test_guardrail_argv.sh` line 118-120
**Apply to:** `tests/stub-nemoclaw.sh` + assertions in `tests/test_nemoclaw_provisioning.sh`
```bash
# Capture: printf '%s\n' "$@" >> file (never eval)
# Assert with awk:
argv_vals() {
  awk -v flag="$1" '$0==flag{getline;print}' "${ARGV_FILE}" 2>/dev/null || true
}
```

### LEDGER_FILE override for hermetic tests
**Source:** D-07 (RESEARCH.md) + `tests/test_guardrail_argv.sh` pattern of injecting OPENCLAW_HOME
**Apply to:** `tests/test_nemoclaw_provisioning.sh` — pass `LEDGER_FILE=<tmpdir>/.nemoclaw/revenium-nemoclaw.ledger` as env var to `post-install-nemoclaw.sh` so tests control ledger state without touching the real `~/.nemoclaw/`
```bash
LEDGER_FILE="${home_dir}/.nemoclaw/revenium-nemoclaw.ledger" \
HOME="${home_dir}" \
    bash "${POST_INSTALL}" 2>&1
```

---

## No Analog Found

No files in this phase are without an analog. All pattern elements have direct matches in the existing codebase. The only novel patterns (ledger functions, proxy-block error classification, in-sandbox exec + sha256 flow) are documented in RESEARCH.md §Code Examples and §Architecture Patterns, which are themselves derived from validated spike findings.

---

## Metadata

**Analog search scope:** `scripts/`, `tests/`, `.claude/skills/spike-findings-openclaw-revenium/sources/`
**Files scanned:** 9 (post-install-nemoclaw.sh, post-install.sh, common.sh, install.sh, probe-host-compat.sh, test_install_dispatcher.sh, stub-revenium.sh, test_guardrail_argv.sh, both spike YAML files)
**Pattern extraction date:** 2026-06-08
