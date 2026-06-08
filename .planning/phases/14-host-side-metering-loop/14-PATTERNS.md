# Phase 14: Host-Side Metering Loop - Pattern Map

**Mapped:** 2026-06-08
**Files analyzed:** 3 new files
**Analogs found:** 3 / 3

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---|---|---|---|---|
| `scripts/nemoclaw-cron-tick.sh` | utility (cron wrapper) | request-response + file-I/O | `scripts/cron.sh` + spike `revenium-mount-tick.sh` | exact (composed) |
| `scripts/install-nemoclaw-cron.sh` | utility (installer) | CRUD + file-I/O | `scripts/install-cron.sh` | exact |
| `scripts/uninstall-nemoclaw-cron.sh` | utility (uninstaller) | CRUD | `scripts/uninstall-cron.sh` | exact |

**Modified file (no new code — stub replacement only):**

| Modified File | Role | Change | Pattern Source |
|---|---|---|---|
| `scripts/post-install-nemoclaw.sh` | provisioner | Replace `stub_install_metering_loop` body (lines 103-105) with real call to `install-nemoclaw-cron.sh` | `scripts/post-install-nemoclaw.sh` lines 103-109 + ledger pattern lines 63-83 |

---

## Pattern Assignments

### `scripts/nemoclaw-cron-tick.sh` (utility, file-I/O + request-response)

**Analogs:**
- Primary: `scripts/cron.sh` (the thin wrapper drives `cron.sh` via `OPENCLAW_HOME` override)
- Supplementary: `.claude/skills/spike-findings-openclaw-revenium/sources/004-background-metering-loop/revenium-mount-tick.sh` (mount-health check + `exit 3` pattern)

**Purpose:** Host cron tick for the NemoClaw install path. Checks mount health, re-establishes mount if down (D-03), sources host-side auth env (D-02), then delegates entirely to `cron.sh` with `OPENCLAW_HOME` pointed at the mount (D-01). Never writes `guardrail-status.json` directly (SC4 — shared scripts do that). On any mount failure: log + `exit 3`, write nothing (D-05).

**Shebang + set pattern** (`scripts/cron.sh` lines 1-8):
```bash
#!/usr/bin/env bash
# =============================================================================
# Revenium NemoClaw Cron Tick
# Host-side metering loop for the NemoClaw/OpenShell install path.
# =============================================================================

set -euo pipefail
```

**SKILL_DIR resolution pattern** (`scripts/cron.sh` line 10):
```bash
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
```

**Mount-health check + exit 3 pattern** (spike `revenium-mount-tick.sh` lines 7-8):
```bash
MNT="$HOME/sbx-openclaw"
[ -d "$MNT/skills" ] || exit 3   # mount gone -> let cron log a failure
```
The NemoClaw tick extends this to attempt remount before giving up (D-03):
```bash
MNT="${HOME}/sbx-openclaw-${SANDBOX_NAME}"
if ! mountpoint -q "${MNT}" 2>/dev/null || ! [[ -d "${MNT}/skills" ]]; then
  echo "$(date -u +%FT%TZ) [nemoclaw-tick] mount down — attempting remount: ${SANDBOX_NAME}" \
    >> "${LOG_FILE}"
  if ! nemoclaw "${SANDBOX_NAME}" share mount /sandbox/.openclaw "${MNT}" 2>>"${LOG_FILE}"; then
    echo "$(date -u +%FT%TZ) [nemoclaw-tick] remount failed — skipping tick (rc=3)" \
      >> "${LOG_FILE}"
    exit 3
  fi
fi
```

**Host auth env sourcing pattern — overrides OPENCLAW_HOME default** (`scripts/cron.sh` lines 24-31, D-02 variant):
```bash
# Source host-side revenium auth (D-02: NOT the mount's revenium.env,
# which would resolve to the sandbox's key inside OPENCLAW_HOME).
HOST_ENV_FILE="${HOME}/.nemoclaw/revenium-host.env"
if [[ -f "${HOST_ENV_FILE}" ]]; then
  set -o allexport
  # shellcheck source=/dev/null
  source "${HOST_ENV_FILE}"
  set +o allexport
fi
```

**OPENCLAW_HOME delegation to cron.sh** (`scripts/cron.sh` lines 12-22 informs what to override):
```bash
# D-01: Drive the shared cron.sh with OPENCLAW_HOME pointed at the mount.
# cron.sh resolves report.sh/guardrail-check.sh relative to SKILL_DIR (its own dirname),
# and resolves session logs, config.json, guardrail-status.json relative to OPENCLAW_HOME.
# By setting OPENCLAW_HOME=<mount>, those paths all resolve through the SSHFS mount.
OPENCLAW_HOME="${MNT}" bash "${SKILL_DIR}/scripts/cron.sh"
```

**Tick history log pattern** (spike `revenium-mount-tick.sh` line 13):
```bash
echo "$(date -u +%FT%TZ) tick=$N rc=$?" >> /tmp/rev-mt.history
```
Production version uses a named path under `~/.nemoclaw/`:
```bash
LOG_FILE="${HOME}/.nemoclaw/revenium-nemoclaw-metering.log"
echo "$(date -u +%FT%TZ) [nemoclaw-tick] sandbox=${SANDBOX_NAME} rc=$?" >> "${LOG_FILE}"
```

**D-05: Write-nothing-on-failure contract.** The tick must NOT call `cron.sh` (which calls `guardrail-check.sh`) when the mount is down. The mount-health block above `exit 3`s before ever reaching the delegation line, so `guardrail-status.json`'s `updatedAt` simply freezes — Phase 15 uses that freeze to detect stale status.

---

### `scripts/install-nemoclaw-cron.sh` (utility, CRUD + file-I/O)

**Analog:** `scripts/install-cron.sh` (exact role match — installer that manages a crontab entry)

**Purpose:** Installs the per-sandbox NemoClaw metering cron entry. Hard-gates on `sshfs` (D-04). Establishes the mount. Writes the host-side `revenium.env`. Idempotent per sandbox via a sandbox-scoped marker (D-07). Reuses the `cronIntervalMinutes` precedence logic from `install-cron.sh` (D-08).

**Shebang + set + constants** (`scripts/install-cron.sh` lines 1-11):
```bash
#!/usr/bin/env bash
# =============================================================================
# Install Revenium NemoClaw Metering Cron Job
# =============================================================================

set -euo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRON_SCRIPT="${SKILL_DIR}/scripts/nemoclaw-cron-tick.sh"
# Per-sandbox marker (D-07): distinct from standalone "# revenium-metering"
CRON_COMMENT="# revenium-metering-nemoclaw:${SANDBOX_NAME}"
```

**Argument parsing pattern** (`scripts/install-cron.sh` lines 20-32):
```bash
DEFAULT_INTERVAL=1
INTERVAL_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval)    INTERVAL_ARG="${2:-}"; shift 2 ;;
    --interval=*)  INTERVAL_ARG="${1#*=}"; shift ;;
    --sandbox)     SANDBOX_NAME="${2:-}"; shift 2 ;;
    --sandbox=*)   SANDBOX_NAME="${1#*=}"; shift ;;
    -h|--help)
      echo "Usage: install-nemoclaw-cron.sh --sandbox <name> [--interval <minutes 1-59>]"
      exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done
```

**OPENCLAW_HOME probe + config.json interval fallback** (`scripts/install-cron.sh` lines 34-57):
```bash
OPENCLAW_HOME="${OPENCLAW_HOME:-}"
if [[ -z "${OPENCLAW_HOME}" ]]; then
  for candidate in "${HOME}/.openclaw" "/home/ubuntu/.openclaw"; do
    if [[ -d "${candidate}/agents" ]]; then OPENCLAW_HOME="${candidate}"; break; fi
  done
  OPENCLAW_HOME="${OPENCLAW_HOME:-${HOME}/.openclaw}"
fi
CONFIG_FILE="${OPENCLAW_HOME}/skills/revenium/config.json"

CONFIG_INTERVAL=""
if [[ -z "${INTERVAL_ARG}" && -f "${CONFIG_FILE}" ]]; then
  CONFIG_INTERVAL=$(CONFIG_FILE="${CONFIG_FILE}" python3 - <<'PY'
import json, os
try:
    v = json.load(open(os.environ['CONFIG_FILE'])).get('cronIntervalMinutes')
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        print(int(v))
except Exception:
    pass
PY
  )
fi

INTERVAL="${INTERVAL_ARG:-${CONFIG_INTERVAL:-${DEFAULT_INTERVAL}}}"

if ! [[ "${INTERVAL}" =~ ^[0-9]+$ ]] || [[ "${INTERVAL}" -lt 1 || "${INTERVAL}" -gt 59 ]]; then
  echo "ERROR: interval must be an integer between 1 and 59 minutes (got '${INTERVAL}')." >&2
  exit 2
fi
```

**sshfs preflight hard-gate (D-04)** — no analog; modeled on `post-install-nemoclaw.sh` lines 303-310 preflight pattern:
```bash
# Hard-gate: sshfs must be present before installing a cron that requires it (D-04).
# Attempt auto-install; if that fails, abort with an actionable message.
if ! command -v sshfs &>/dev/null; then
  echo "sshfs not found — attempting install..."
  if command -v apt-get &>/dev/null; then
    apt-get install -y sshfs || true
  elif command -v dnf &>/dev/null; then
    dnf install -y fuse-sshfs || true
  fi
  if ! command -v sshfs &>/dev/null; then
    echo "ERROR: sshfs not available and auto-install failed." >&2
    echo "  Install sshfs manually (e.g. apt-get install sshfs) then re-run." >&2
    exit 1
  fi
fi
```

**Sandbox name validation** (modeled on `post-install-nemoclaw.sh` lines 331-334):
```bash
SANDBOX_NAME="${REVENIUM_SANDBOX_NAME:-${SANDBOX_NAME:-}}"
if [[ -z "${SANDBOX_NAME}" ]]; then
    echo "ERROR: sandbox name required. Pass --sandbox <name> or export REVENIUM_SANDBOX_NAME." >&2
    exit 2
fi
```

**Host-side revenium.env write (D-02):**
```bash
# Write host-side auth env (D-02). Key must NOT appear as a CLI flag or in logs.
HOST_ENV_DIR="${HOME}/.nemoclaw"
HOST_ENV_FILE="${HOST_ENV_DIR}/revenium-host.env"
mkdir -p "${HOST_ENV_DIR}"
{
  printf 'REVENIUM_API_KEY=%s\n' "${REVENIUM_API_KEY}"
  [[ -n "${REVENIUM_TEAM_ID:-}" ]]   && printf 'REVENIUM_TEAM_ID=%s\n'   "${REVENIUM_TEAM_ID}"
  [[ -n "${REVENIUM_TENANT_ID:-}" ]] && printf 'REVENIUM_TENANT_ID=%s\n' "${REVENIUM_TENANT_ID}"
  [[ -n "${REVENIUM_OWNER_ID:-}" ]]  && printf 'REVENIUM_OWNER_ID=%s\n'  "${REVENIUM_OWNER_ID}"
} > "${HOST_ENV_FILE}"
chmod 600 "${HOST_ENV_FILE}"
```

**Mount establishment:**
```bash
MNT="${HOME}/sbx-openclaw-${SANDBOX_NAME}"
mkdir -p "${MNT}"
if ! mountpoint -q "${MNT}" 2>/dev/null; then
  nemoclaw "${SANDBOX_NAME}" share mount /sandbox/.openclaw "${MNT}" \
    || { echo "ERROR: mount failed — is ${SANDBOX_NAME} running?" >&2; exit 1; }
fi
```

**Cron PATH baking** (`scripts/install-cron.sh` lines 70-83):
```bash
CRON_PATH="/usr/local/bin:/usr/bin:/bin"
for p in \
  /home/linuxbrew/.linuxbrew/bin \
  /opt/homebrew/bin \
  "${HOME}/go/bin" \
  "${HOME}/.local/bin"; do
  [[ -d "${p}" ]] && CRON_PATH="${p}:${CRON_PATH}"
done
if command -v brew &>/dev/null; then
  BREW_BIN="$(brew --prefix 2>/dev/null)/bin"
  [[ -d "${BREW_BIN}" ]] && CRON_PATH="${BREW_BIN}:${CRON_PATH}"
fi
```

**Cron line with sandbox env vars:**
```bash
CRON_LINE="${CRON_SCHEDULE} PATH=${CRON_PATH} REVENIUM_SANDBOX_NAME=${SANDBOX_NAME} bash ${CRON_SCRIPT} >> ${HOME}/.nemoclaw/revenium-nemoclaw-metering.log 2>&1 ${CRON_COMMENT}"
```

**Idempotent crontab install (D-07: per-sandbox marker)** (`scripts/install-cron.sh` lines 93-98 — adapt marker to be sandbox-scoped):
```bash
# Idempotent per-sandbox: drop only THIS sandbox's existing entry, then append new one.
# The marker "# revenium-metering-nemoclaw:<sandbox>" is unique per sandbox,
# so multiple sandboxes on one host coexist without collision (D-07).
ACTION="installed"
if crontab -l 2>/dev/null | grep -qF "${CRON_COMMENT}"; then
  ACTION="updated"
fi
EXISTING="$(crontab -l 2>/dev/null | grep -vF "${CRON_COMMENT}" || true)"
{ [[ -n "${EXISTING}" ]] && printf '%s\n' "${EXISTING}"; printf '%s\n' "${CRON_LINE}"; } | crontab -
```

**Note:** the standalone entry `# revenium-metering` is untouched because `grep -vF "# revenium-metering-nemoclaw:${SANDBOX_NAME}"` does not match the standalone marker — no prefix-collision risk.

---

### `scripts/uninstall-nemoclaw-cron.sh` (utility, CRUD)

**Analog:** `scripts/uninstall-cron.sh` (exact role match — 15-line uninstaller)

**Full analog** (`scripts/uninstall-cron.sh` lines 1-14):
```bash
#!/usr/bin/env bash
# =============================================================================
# Uninstall Revenium Metering Cron Job
# =============================================================================

set -euo pipefail

if ! crontab -l 2>/dev/null | grep -q "revenium-metering"; then
  echo "No Revenium cron job found."
  exit 0
fi

crontab -l 2>/dev/null | grep -v "revenium-metering" | crontab -
echo "✅ Revenium metering cron removed."
```

**NemoClaw variant — sandbox-scoped removal + optional unmount:**
```bash
#!/usr/bin/env bash
# =============================================================================
# Uninstall Revenium NemoClaw Metering Cron Job
# =============================================================================

set -euo pipefail

# Sandbox name (required)
SANDBOX_NAME="${REVENIUM_SANDBOX_NAME:-${1:-}}"
if [[ -z "${SANDBOX_NAME}" ]]; then
  echo "Usage: uninstall-nemoclaw-cron.sh <sandbox-name>" >&2
  echo "  or: export REVENIUM_SANDBOX_NAME=<name>" >&2
  exit 2
fi

CRON_MARKER="# revenium-metering-nemoclaw:${SANDBOX_NAME}"

if ! crontab -l 2>/dev/null | grep -qF "${CRON_MARKER}"; then
  echo "No NemoClaw cron entry found for sandbox '${SANDBOX_NAME}'."
  exit 0
fi

crontab -l 2>/dev/null | grep -vF "${CRON_MARKER}" | crontab -
echo "Revenium NemoClaw metering cron removed for sandbox '${SANDBOX_NAME}'."

# Optional unmount (fail-open: if mount not present, skip silently)
MNT="${HOME}/sbx-openclaw-${SANDBOX_NAME}"
if mountpoint -q "${MNT}" 2>/dev/null; then
  fusermount -u "${MNT}" 2>/dev/null || umount "${MNT}" 2>/dev/null || true
  echo "Mount at ${MNT} unmounted."
fi
```

---

### `scripts/post-install-nemoclaw.sh` — stub replacement only (lines 103-109)

**No new file.** The Phase 13 stub `stub_install_metering_loop` (lines 103-105) is replaced with a real call to `install-nemoclaw-cron.sh`. The ledger pattern is already established — if a ledger key is introduced, follow the existing `ledger_has` / `ledger_set` pattern (lines 63-83).

**Stub to replace** (`scripts/post-install-nemoclaw.sh` lines 103-105):
```bash
stub_install_metering_loop() {
    warn "Phase 14+: host-side metering loop deferred — skipping."
}
```

**Replacement pattern** (modeled on `deliver_revenium_cli` ledger gate, lines 175-208):
```bash
install_metering_loop() {
    if ledger_has "metering-loop-installed"; then
        info "NemoClaw metering loop already installed (ledger) — skipping."
        return 0
    fi

    step "Installing host-side metering loop"
    bash "${SCRIPT_DIR}/install-nemoclaw-cron.sh" --sandbox "${SANDBOX_NAME}" \
        || fail "install-nemoclaw-cron.sh failed"

    ledger_set "metering-loop-installed" "1"
    info "Metering loop installed (cron active for sandbox '${SANDBOX_NAME}')"
}
```

The call site at line 351 (`stub_install_metering_loop`) becomes `install_metering_loop`.

---

## Shared Patterns

### OPENCLAW_HOME Override (env-driven path resolution)
**Source:** `scripts/cron.sh` lines 12-22, `scripts/report.sh` lines 16-26
**Apply to:** `nemoclaw-cron-tick.sh`, `install-nemoclaw-cron.sh`
```bash
OPENCLAW_HOME="${OPENCLAW_HOME:-}"
if [[ -z "${OPENCLAW_HOME}" ]]; then
  for candidate in "${HOME}/.openclaw" "/home/ubuntu/.openclaw"; do
    if [[ -d "${candidate}/agents" ]]; then
      OPENCLAW_HOME="${candidate}"
      break
    fi
  done
  OPENCLAW_HOME="${OPENCLAW_HOME:-${HOME}/.openclaw}"
fi
```
In `nemoclaw-cron-tick.sh`, this probe is NOT used for the host OpenClaw state — it is only needed to locate `config.json` for the interval default. The mount path `${MNT}` is passed directly as `OPENCLAW_HOME` to `cron.sh`.

### Env-file sourcing (set -o allexport / +o allexport)
**Source:** `scripts/cron.sh` lines 24-31
**Apply to:** `nemoclaw-cron-tick.sh` (for host auth env)
```bash
if [[ -f "${ENV_FILE}" ]]; then
  set -o allexport
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +o allexport
fi
```

### Preflight hard-gate pattern (fail on missing tool)
**Source:** `scripts/post-install-nemoclaw.sh` lines 303-310
**Apply to:** `install-nemoclaw-cron.sh` (sshfs gate, D-04)
```bash
[[ -f "${PROBE_SCRIPT}" ]] \
    || fail "probe-host-compat.sh not found at ${PROBE_SCRIPT}"

if ! bash "${PROBE_SCRIPT}"; then
    fail "Host compatibility check failed — NemoClaw requires a Linux host with Docker."
fi
```

### Ledger-gated step (idempotent provisioning)
**Source:** `scripts/post-install-nemoclaw.sh` lines 63-83
**Apply to:** `post-install-nemoclaw.sh` stub replacement (`install_metering_loop`)
```bash
ledger_has() {
    local key="$1"
    grep -q "^${key}=" "${LEDGER_FILE}" 2>/dev/null
}

ledger_set() {
    local key="$1" val="$2"
    WORK_DONE=1
    local ledger_dir
    ledger_dir="$(dirname "${LEDGER_FILE}")"
    mkdir -p "${ledger_dir}"
    { grep -v "^${key}=" "${LEDGER_FILE}" 2>/dev/null || true; \
      echo "${key}=${val}"; } > "${LEDGER_FILE}.tmp" && \
      mv "${LEDGER_FILE}.tmp" "${LEDGER_FILE}"
}
```

### guardrail-status.json `updatedAt` field (TTL contract, D-05/D-06)
**Source:** `scripts/guardrail-check.sh` lines 166, 313-318 (Python block)
**Apply to:** `nemoclaw-cron-tick.sh` (understanding what NOT to overwrite)

The shared `guardrail-check.sh` writes the status atomically (D-14) including `updatedAt`:
```python
now = datetime.now(timezone.utc).isoformat()
# ...
data = {
    'halted': new_halted,
    'warned': new_warned,
    # ...
    'lastChecked': now,   # also serves as updatedAt for TTL
    'rules': new_rules,
}
# Atomic write (D-14 / Pattern 4): write-tmp-rename in the same directory.
tmp_fd, tmp_path = tempfile.mkstemp(
    dir=str(status_file.parent),
    prefix='.guardrail-status-',
    suffix='.tmp'
)
```
The NemoClaw tick wrapper must NEVER write to `guardrail-status.json` directly. The shared script does it. On mount failure the tick `exit 3`s before `cron.sh` is called, so `updatedAt` freezes — Phase 15 reads the frozen `lastChecked` field to detect stale status.

**Optional post-write `_maxAgeSeconds` stamp (D-06)** — if the planner decides to add the TTL hint field, do it AFTER `cron.sh` returns, reading the file through the mount:
```bash
# D-06: stamp _maxAgeSeconds post-write (do not edit guardrail-check.sh — SC4).
# Append/update field in the already-written JSON via python3.
MAX_AGE_SECONDS=$(( INTERVAL * 60 * 3 ))   # 3× the tick interval
python3 - <<PY
import json, os
p = "${MNT}/skills/revenium/guardrail-status.json"
try:
    d = json.loads(open(p).read())
    d['_maxAgeSeconds'] = ${MAX_AGE_SECONDS}
    open(p, 'w').write(json.dumps(d, indent=2) + '\n')
except Exception:
    pass
PY
```

### Fail-open / error logging convention
**Source:** `scripts/guardrail-check.sh` (throughout — every error path exits 0; `warn` helper)
**Source:** `scripts/cron.sh` lines 91-94 (`|| true` on each workhorse call)
**Apply to:** `nemoclaw-cron-tick.sh`

The tick wraps the `cron.sh` delegation with `|| true` and logs, mirroring the flock block:
```bash
OPENCLAW_HOME="${MNT}" bash "${SKILL_DIR}/scripts/cron.sh" || {
  echo "$(date -u +%FT%TZ) [nemoclaw-tick] cron.sh exited non-zero (rc=$?) — check host env" \
    >> "${LOG_FILE}"
}
```

---

## No Analog Found

All three new files have strong analogs. No files are without a pattern source.

---

## Metadata

**Analog search scope:** `scripts/`, `.claude/skills/spike-findings-openclaw-revenium/sources/004-background-metering-loop/`
**Files scanned:** 8 (cron.sh, install-cron.sh, uninstall-cron.sh, post-install-nemoclaw.sh, guardrail-check.sh, report.sh lines 1-60, probe-host-compat.sh lines 1-50, revenium-mount-tick.sh)
**Pattern extraction date:** 2026-06-08
