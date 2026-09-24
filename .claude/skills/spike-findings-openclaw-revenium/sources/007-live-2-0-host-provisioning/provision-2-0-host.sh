#!/usr/bin/env bash
# Spike 007 — Live OpenClaw 2.0 host provisioning (SPIKE-00).
#
# UNLIKE spike 001's probe-host-compat.sh, this script IS destructive: it DOES
# install packages and DOES sudo. It brings up BOTH production install paths
# on one host (D-13): standalone OpenClaw + Docker, and NemoClaw/OpenShell.
#
# Idempotent / detection-gated (D-14): every step checks current state first
# and is a no-op on re-run. A version floor that is present but below required
# causes an explicit non-zero-exit refusal — never a silent continue.
#
# Version policy (D-15): provision at `latest`; record exactly what resolved,
# per path, in versions-resolved.txt. Do not pin, do not normalize the two
# paths' versions to match each other.
#
# Version floors:
#   OpenClaw  >= 2026.8.1
#   Node      >=24.16.0 <25  ||  >=26.1.0
#   NemoClaw  >= v0.0.128
#
# Sources: .planning/phases/17-live-host-fact-finding-spike/17-RESEARCH.md
#          §Host Provisioning; .planning/spikes/CONVENTIONS.md; D-14/D-15.
set -u

VERSIONS_FILE="${VERSIONS_FILE:-$HOME/versions-resolved.txt}"

pass=0; warn=0; fail=0
line() { printf '%-34s %s\n' "$1" "$2"; }
ok()   { line "$1" "✓ $2"; pass=$((pass+1)); }
wn()   { line "$1" "⚠ $2"; warn=$((warn+1)); }
no()   { line "$1" "✗ $2"; fail=$((fail+1)); }

# ---------------------------------------------------------------------------
# Numeric CalVer-aware version comparison. NEVER a string-prefix test — a
# prefix match on "2026.8.1" would also match "2026.8.19" coincidentally but
# breaks the moment either side has a differing digit-count component
# ("2026.8.9" vs "2026.8.10" sorts backwards lexically: '9' > '1'). sort -V
# is version-number aware and gets this right.
# ---------------------------------------------------------------------------
# version_ge DETECTED REQUIRED — returns 0 if DETECTED >= REQUIRED
version_ge() {
  local detected="$1" required="$2"
  [ "$detected" = "$required" ] && return 0
  printf '%s\n%s\n' "$required" "$detected" | sort -C -V
}

# node_version_ok VERSION — true if VERSION satisfies >=24.16.0 <25 || >=26.1.0
node_version_ok() {
  local v="${1#v}"
  local major="${v%%.*}"
  case "$major" in
    24) version_ge "$v" "24.16.0" ;;
    25) return 1 ;;
    *)
      if [ "$major" -ge 26 ] 2>/dev/null; then
        version_ge "$v" "26.1.0"
      else
        return 1
      fi
      ;;
  esac
}

# Self-test / reusable CLI entry point for the version helper (Task 4 D-14
# idempotency + explicit-refusal probe). Not used by the main provisioning
# flow below, but callable directly: `bash provision-2-0-host.sh --version-check <detected> <required>`
if [ "${1:-}" = "--version-check" ]; then
  detected="${2:?detected version required}"
  required="${3:?required version required}"
  if version_ge "$detected" "$required"; then
    echo "✓ ${detected} >= ${required}"
    exit 0
  else
    echo "✗ version ${detected} is below required ${required}"
    exit 1
  fi
fi

record_version() {
  # record_version PREFIX LABEL VALUE — appends "prefix: LABEL=VALUE"-shaped line
  local prefix="$1" label="$2" value="$3"
  printf '%s: %s=%s\n' "$prefix" "$label" "$value" >> "$VERSIONS_FILE"
}

echo "=================================================="
echo " Spike 007 — Live 2.0 host provisioning (standalone path)"
echo "=================================================="
echo
echo "Host: $(uname -a)"
echo "--------------------------------------------------"

# ---------------------------------------------------------------------------
# 1. Swapfile — host has 7.7 GiB RAM / 0 swap, below NemoClaw's ~8 GB floor.
# ---------------------------------------------------------------------------
if swapon --show 2>/dev/null | grep -q .; then
  ok "Swap" "already present ($(swapon --show --noheadings 2>/dev/null | awk '{print $3}' | head -1))"
else
  echo "Creating 8G swapfile at /swapfile..."
  sudo fallocate -l 8G /swapfile 2>/dev/null || sudo dd if=/dev/zero of=/swapfile bs=1M count=8192 status=none
  sudo chmod 600 /swapfile
  sudo mkswap /swapfile >/dev/null
  sudo swapon /swapfile
  if ! grep -q '^/swapfile ' /etc/fstab 2>/dev/null; then
    echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
  fi
  if swapon --show 2>/dev/null | grep -q .; then
    ok "Swap" "8G swapfile created and active"
  else
    no "Swap" "swapfile creation failed"
  fi
fi

# ---------------------------------------------------------------------------
# 2. sshfs — host↔sandbox state channel prerequisite (D-13, Task 2).
# ---------------------------------------------------------------------------
if command -v sshfs >/dev/null 2>&1; then
  ok "sshfs" "already installed ($(sshfs --version 2>&1 | head -1))"
else
  echo "Installing sshfs..."
  sudo apt-get update -qq && sudo apt-get install -y -qq sshfs
  if command -v sshfs >/dev/null 2>&1; then
    ok "sshfs" "installed"
  else
    no "sshfs" "installation failed"
  fi
fi

# ---------------------------------------------------------------------------
# 3. Node + OpenClaw — official installer self-provisions Node.
#    Per D-15: install at `latest`, record exactly what resolved.
# ---------------------------------------------------------------------------
# The installer writes its npm-global bin dir into ~/.bashrc for FUTURE
# interactive shells; this non-interactive script process never sources
# .bashrc, so PATH must be extended explicitly here (idempotent — safe even
# before the directory exists).
export PATH="$HOME/.npm-global/bin:$PATH"

if command -v openclaw >/dev/null 2>&1; then
  ok "OpenClaw" "already installed"
else
  echo "Installing OpenClaw (self-provisions Node)..."
  curl -fsSL https://openclaw.ai/install.sh | bash
  export PATH="$HOME/.npm-global/bin:$PATH"
  hash -r 2>/dev/null || true
fi

# Brief settle-retry: a detached, non-interactive apt/npm install can leave a
# short window where the just-installed binary isn't yet resolvable (observed
# live on this host — a fresh SSH session resolved correctly immediately
# after). Poll briefly rather than hard-failing on a transient race.
OPENCLAW_VERSION=""
for _attempt in 1 2 3 4 5; do
  hash -r 2>/dev/null || true
  if command -v openclaw >/dev/null 2>&1; then
    OPENCLAW_VERSION="$(openclaw --version 2>/dev/null | head -1)"
    [ -n "$OPENCLAW_VERSION" ] && break
  fi
  sleep 2
done
if [ -z "$OPENCLAW_VERSION" ]; then
  no "OpenClaw" "not found on PATH after install attempt"
else
  record_version "standalone" "openclaw" "$OPENCLAW_VERSION"
  # Strip any leading non-numeric label (e.g. "openclaw/2026.9.6") before compare
  OC_NUM="$(printf '%s' "$OPENCLAW_VERSION" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -n "$OC_NUM" ] && version_ge "$OC_NUM" "2026.8.1"; then
    ok "OpenClaw" "${OPENCLAW_VERSION} (>= 2026.8.1)"
  else
    no "OpenClaw" "${OPENCLAW_VERSION} is below required 2026.8.1"
  fi
fi

NODE_VERSION=""
for _attempt in 1 2 3 4 5; do
  hash -r 2>/dev/null || true
  if command -v node >/dev/null 2>&1; then
    NODE_VERSION="$(node --version 2>/dev/null)"
    node_version_ok "$NODE_VERSION" && break
  fi
  sleep 2
done
if [ -z "$NODE_VERSION" ]; then
  no "Node.js" "not found on PATH after install attempt"
else
  record_version "standalone" "node" "$NODE_VERSION"
  if node_version_ok "$NODE_VERSION"; then
    ok "Node.js" "${NODE_VERSION} (satisfies >=24.16.0 <25 || >=26.1.0)"
  else
    no "Node.js" "${NODE_VERSION} does not satisfy >=24.16.0 <25 || >=26.1.0"
  fi
fi

# ---------------------------------------------------------------------------
# 3b. SQLite session store read-only sanity check — informational only, no-op
#     if no turn has run yet (the store doesn't exist until the first agent
#     turn creates it). Read-only (mode=ro) + explicit busy_timeout, exactly
#     the connection form Phase 19's production read path must use.
# ---------------------------------------------------------------------------
STANDALONE_SQLITE_STORE="${HOME}/.openclaw/agents/main/agent/openclaw-agent.sqlite"
if [ -f "$STANDALONE_SQLITE_STORE" ]; then
  if command -v sqlite3 >/dev/null 2>&1 && \
     sqlite3 -cmd "PRAGMA busy_timeout=5000;" "file:${STANDALONE_SQLITE_STORE}?mode=ro" ".tables" >/dev/null 2>&1; then
    ok "SQLite store" "readable read-only (mode=ro, busy_timeout=5000) at ${STANDALONE_SQLITE_STORE}"
    record_version "standalone" "sqlite-store-path" "$STANDALONE_SQLITE_STORE"
  else
    wn "SQLite store" "exists but read-only probe failed"
  fi
else
  line "SQLite store" "· not yet created (no agent turn has run)"
fi

# ---------------------------------------------------------------------------
# 4. Docker — standalone path's agent sandbox runtime.
# ---------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  if sudo docker info >/dev/null 2>&1; then
    DOCKER_VERSION="$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,)"
    record_version "standalone" "docker" "$DOCKER_VERSION"
    ok "Docker" "installed and daemon reachable (${DOCKER_VERSION})"
  else
    wn "Docker" "installed but daemon not reachable"
  fi
else
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker "$USER" 2>/dev/null || true
  sudo systemctl enable --now docker >/dev/null 2>&1 || true
  if command -v docker >/dev/null 2>&1 && sudo docker info >/dev/null 2>&1; then
    DOCKER_VERSION="$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,)"
    record_version "standalone" "docker" "$DOCKER_VERSION"
    ok "Docker" "installed (${DOCKER_VERSION}) — note: docker-group membership needs a fresh login for non-sudo use"
  else
    no "Docker" "installation failed"
  fi
fi

# ---------------------------------------------------------------------------
# 5. NemoClaw/OpenShell path (D-13: same host, both paths). NemoClaw's own
#    installer owns Docker — it is NOT reinstalled here (already present from
#    step 4 above; the installer detects and reuses it).
#
#    Credential file is spike-scoped and deliberately NOT hardcoded to a
#    single spike's filename — override via CREDENTIAL_ENV_FILE for reuse in
#    Phase 22/24. Presence-checked only; the value is sourced straight into
#    the installer's environment and never echoed or logged (T-17-01).
# ---------------------------------------------------------------------------
CREDENTIAL_ENV_FILE="${CREDENTIAL_ENV_FILE:-$HOME/.spike-17.env}"
NEMOCLAW_SANDBOX_NAME="${NEMOCLAW_SANDBOX_NAME:-revenium-2-0}"
NEMOCLAW_FLOOR="0.0.128"

# Finding (2026-09-24, live host): the installer's default non-pinned "latest"
# resolution is NOT the newest published tag — it walks git tags to find a
# "maintained last-known-good" release, which on this host resolved to
# v0.0.124 even though v0.0.128/v0.0.129 already existed as real, non-prerelease
# tags. D-15's "provision at latest" therefore does not by itself clear this
# project's stated floor; the installer's own error output documents the
# escape hatch (`NEMOCLAW_INSTALL_TAG=v<X>`), which is used here to explicitly
# pin to the floor rather than silently accepting a below-floor "latest".
# Override via NEMOCLAW_INSTALL_TAG for a future phase that wants true latest.
NEMOCLAW_INSTALL_TAG="${NEMOCLAW_INSTALL_TAG:-v${NEMOCLAW_FLOOR}}"

_nemoclaw_current_version() {
  command -v nemoclaw >/dev/null 2>&1 || return 1
  nemoclaw --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

_NC_CURRENT="$(_nemoclaw_current_version || true)"
if [ -n "$_NC_CURRENT" ] && version_ge "$_NC_CURRENT" "$NEMOCLAW_FLOOR"; then
  ok "NemoClaw" "already installed (v${_NC_CURRENT} >= v${NEMOCLAW_FLOOR})"
else
  if [ ! -f "$CREDENTIAL_ENV_FILE" ]; then
    no "NemoClaw" "credential file ${CREDENTIAL_ENV_FILE} not found — cannot install without NVIDIA_API_KEY"
  else
    echo "Installing/upgrading NemoClaw to ${NEMOCLAW_INSTALL_TAG} (non-interactive)..."
    (
      set -a
      # shellcheck disable=SC1090
      . "$CREDENTIAL_ENV_FILE"
      set +a
      export NEMOCLAW_NON_INTERACTIVE=1
      export NEMOCLAW_NON_INTERACTIVE_SUDO_MODE=prompt
      export NEMOCLAW_ACCEPT_THIRD_PARTY_SOFTWARE=1
      export NEMOCLAW_PROVIDER=build
      export NEMOCLAW_SANDBOX_NAME="$NEMOCLAW_SANDBOX_NAME"
      export NEMOCLAW_POLICY_MODE=suggested
      export NEMOCLAW_INSTALL_TAG="$NEMOCLAW_INSTALL_TAG"
      curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
    )
    export PATH="$HOME/.local/bin:$PATH"
    hash -r 2>/dev/null || true
  fi
fi

NEMOCLAW_VERSION=""
for _attempt in 1 2 3 4 5; do
  hash -r 2>/dev/null || true
  if command -v nemoclaw >/dev/null 2>&1; then
    NEMOCLAW_VERSION="$(nemoclaw --version 2>/dev/null | head -1)"
    [ -n "$NEMOCLAW_VERSION" ] && break
  fi
  sleep 2
done
if [ -z "$NEMOCLAW_VERSION" ]; then
  no "NemoClaw" "not found on PATH after install attempt"
else
  record_version "nemoclaw-sandbox" "nemoclaw-cli" "$NEMOCLAW_VERSION"
  NC_NUM="$(printf '%s' "$NEMOCLAW_VERSION" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -n "$NC_NUM" ] && version_ge "$NC_NUM" "$NEMOCLAW_FLOOR"; then
    ok "NemoClaw" "${NEMOCLAW_VERSION} (>= v${NEMOCLAW_FLOOR})"
  else
    no "NemoClaw" "${NEMOCLAW_VERSION} is below required v${NEMOCLAW_FLOOR}"
  fi
fi

# Sandbox status + in-sandbox OpenClaw version (D-15: recorded separately,
# never normalized against the standalone path's version).
if command -v nemoclaw >/dev/null 2>&1 && nemoclaw "$NEMOCLAW_SANDBOX_NAME" status >/dev/null 2>&1; then
  ok "NemoClaw sandbox" "${NEMOCLAW_SANDBOX_NAME} is up"
  # Single-line exec — NemoClaw's gRPC argv rejects newlines.
  SANDBOX_OPENCLAW_VERSION="$(nemoclaw "$NEMOCLAW_SANDBOX_NAME" exec -- openclaw --version 2>/dev/null | head -1)"
  if [ -n "$SANDBOX_OPENCLAW_VERSION" ]; then
    record_version "nemoclaw-sandbox" "openclaw" "$SANDBOX_OPENCLAW_VERSION"
    ok "NemoClaw sandbox OpenClaw" "$SANDBOX_OPENCLAW_VERSION"
  else
    wn "NemoClaw sandbox OpenClaw" "could not resolve in-sandbox OpenClaw version"
  fi
else
  no "NemoClaw sandbox" "${NEMOCLAW_SANDBOX_NAME} status check failed"
fi

# ---------------------------------------------------------------------------
# 6. Egress preset — api.revenium.ai (D-16). Hot-reloads; safe to re-apply.
#    Gated on the preset already being present in `policy list`.
#    NOTE: NemoClaw v0.0.128's CLI renamed `policy-add`/`policy-list`
#    (hyphenated, per CONVENTIONS.md from the older v0.0.55-era spikes) to
#    `policy add`/`policy list` (space-separated subcommands) — a live
#    CLI-surface drift finding, recorded here so it isn't silently rediscovered.
# ---------------------------------------------------------------------------
REVENIUM_POLICY_FILE="${REVENIUM_POLICY_FILE:-$HOME/revenium-policy.yaml}"
if command -v nemoclaw >/dev/null 2>&1 && nemoclaw "$NEMOCLAW_SANDBOX_NAME" status >/dev/null 2>&1; then
  if nemoclaw "$NEMOCLAW_SANDBOX_NAME" policy list 2>/dev/null | grep -qi 'revenium'; then
    ok "Egress preset" "revenium already applied"
  elif [ -f "$REVENIUM_POLICY_FILE" ]; then
    nemoclaw "$NEMOCLAW_SANDBOX_NAME" policy add --from-file "$REVENIUM_POLICY_FILE" --yes >/dev/null 2>&1
    if nemoclaw "$NEMOCLAW_SANDBOX_NAME" policy list 2>/dev/null | grep -qi 'revenium'; then
      ok "Egress preset" "revenium applied"
    else
      no "Egress preset" "policy add did not result in a visible revenium policy"
    fi
  else
    wn "Egress preset" "revenium policy file not found at ${REVENIUM_POLICY_FILE} — skipped"
  fi
fi

# ---------------------------------------------------------------------------
# 7. Host-side share mount — the host<->sandbox state channel (D-13). Needs
#    the sshfs installed in step 2. Idempotent: gated on already-mounted.
# ---------------------------------------------------------------------------
SHARE_MOUNT_POINT="${SHARE_MOUNT_POINT:-$HOME/nemoclaw-${NEMOCLAW_SANDBOX_NAME}-mount}"
if command -v nemoclaw >/dev/null 2>&1 && nemoclaw "$NEMOCLAW_SANDBOX_NAME" status >/dev/null 2>&1; then
  # A mount entry can exist yet be stale (I/O error) after a sandbox rebuild
  # recreates the underlying container — verify liveness, not just presence,
  # per the SSHFS-cache-lag hazard documented in CONVENTIONS.md.
  if mount | grep -q "$SHARE_MOUNT_POINT" && ls "$SHARE_MOUNT_POINT" >/dev/null 2>&1; then
    ok "Share mount" "already mounted and readable at ${SHARE_MOUNT_POINT}"
  else
    if mount | grep -q "$SHARE_MOUNT_POINT"; then
      wn "Share mount" "stale mount detected at ${SHARE_MOUNT_POINT} — unmounting before remount"
      fusermount3 -uz "$SHARE_MOUNT_POINT" >/dev/null 2>&1 || sudo umount -l "$SHARE_MOUNT_POINT" >/dev/null 2>&1 || true
    fi
    mkdir -p "$SHARE_MOUNT_POINT"
    nemoclaw "$NEMOCLAW_SANDBOX_NAME" share mount /sandbox/.openclaw "$SHARE_MOUNT_POINT" >/dev/null 2>&1
    sleep 2
    if mount | grep -q "$SHARE_MOUNT_POINT" && ls "$SHARE_MOUNT_POINT" >/dev/null 2>&1; then
      ok "Share mount" "mounted /sandbox/.openclaw at ${SHARE_MOUNT_POINT}"
    else
      no "Share mount" "mount attempt did not result in a visible, readable mount"
    fi
  fi

  # Resolve the in-sandbox SQLite store path from the live filesystem — do
  # NOT assume the standalone `~/.openclaw/` layout carries over (HOME is
  # /sandbox, user `sandbox`, per CONVENTIONS.md).
  HOST_MOUNT_SQLITE_STORE="$(find "$SHARE_MOUNT_POINT/agents" -maxdepth 3 -iname 'openclaw-agent.sqlite' 2>/dev/null | head -1)"
  if [ -n "$HOST_MOUNT_SQLITE_STORE" ]; then
    # Record the path AS SEEN INSIDE the sandbox (HOME=/sandbox, user `sandbox`),
    # not the host-side mount point — the mount point is a host convenience,
    # the in-sandbox path is what production code (Phase 19+) actually uses.
    SANDBOX_SQLITE_STORE="/sandbox/.openclaw/${HOST_MOUNT_SQLITE_STORE#"$SHARE_MOUNT_POINT/"}"
    record_version "nemoclaw-sandbox" "sqlite-store-path" "$SANDBOX_SQLITE_STORE"
    ok "In-sandbox SQLite store" "found at ${SANDBOX_SQLITE_STORE} (host mount: ${HOST_MOUNT_SQLITE_STORE})"
  else
    line "In-sandbox SQLite store" "· not yet created (no in-sandbox agent turn has run)"
  fi
fi

echo "--------------------------------------------------"
echo "Summary: ${pass} pass, ${warn} warn, ${fail} fail"
echo
if [ "$fail" -gt 0 ]; then
  echo "VERDICT: INCOMPATIBLE — one or more version floors unmet or install failed."
  exit 1
elif [ "$warn" -gt 0 ]; then
  echo "VERDICT: USABLE WITH CAVEATS — review warnings above."
  exit 0
else
  echo "VERDICT: COMPATIBLE — standalone + NemoClaw paths provisioned successfully."
  exit 0
fi
