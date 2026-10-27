#!/usr/bin/env bash
# =============================================================================
# uninstall-sidecar.sh — Remove the economics sidecar runtime, keep its state.
#
# Removes the shared runtime (uv, the managed CPython and the venv) that
# provision-sidecar.sh built. Every state dir is kept: they hold the ledgers,
# cursors and redacted turn cache that make delivery exactly-once, so a later
# reinstall picks up where it stopped and sends nothing twice.
#
# On a NemoClaw host the runtime is shared by every sandbox, which is why the
# per-sandbox uninstallers do not call this script.
#
# Usage:
#   bash scripts/uninstall-sidecar.sh [--purge-cache]
#
#   --purge-cache  also delete the redacted turn cache (<state>/turns/) of each
#                  state dir; cursors, heartbeat state, model.key and every
#                  ledger stay in place.
#
# Exit codes:
#   0  runtime removed, or nothing to remove
#   1  refused (unsafe or unmarked runtime dir, or bad usage); nothing removed
#
# SECURITY: acts only on a directory that carries the ownership marker the
#   provisioner writes (.revenium-sidecar-runtime), never `/` or $HOME, and
#   never a state dir. Inside it, only the entries the provisioner creates
#   are removed; the directory itself is removed only when nothing else is
#   left in it. A runtime built before the marker existed is refused with
#   guidance. With --purge-cache the only other removal target is a `turns`
#   subdirectory of a state dir the current user owns.
#
# BASH 3.x COMPATIBILITY: no bash-4-only constructs (macOS /bin/bash is 3.2).
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=economics-paths.sh
. "${SCRIPT_DIR}/economics-paths.sh"

info() { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }

PURGE_CACHE=0
for arg in "$@"; do
  case "${arg}" in
    --purge-cache) PURGE_CACHE=1 ;;
    -h|--help)
      echo "Usage: uninstall-sidecar.sh [--purge-cache]"
      exit 0
      ;;
    *)
      echo "Usage: uninstall-sidecar.sh [--purge-cache]" >&2
      echo "Unknown option: ${arg:0:64}" >&2
      exit 1
      ;;
  esac
done

# Mirrors econ_standalone_state_dir's base: a relative XDG_STATE_HOME is
# invalid per the XDG spec and ignored.
standalone_state_base() {
  local base="${XDG_STATE_HOME:-}"
  [[ "${base}" == /* ]] || base="${HOME}/.local/state"
  printf '%s/revenium-economics\n' "${base}"
}

STANDALONE_BASE="$(standalone_state_base)"
NEMOCLAW_BASE="${HOME}/.nemoclaw/revenium-economics"

# state_dirs — print every per-install state dir under both bases.
state_dirs() {
  local d
  for d in "${STANDALONE_BASE}"/standalone-* "${NEMOCLAW_BASE}"/*; do
    if [[ -d "${d}" ]]; then printf '%s\n' "${d}"; fi
  done
}

refuse() {
  warn "$*"
  warn "Nothing was removed."
  exit 1
}

# ---------------------------------------------------------------------------
# 1. Runtime
# ---------------------------------------------------------------------------
RUNTIME_RAW="$(econ_runtime_dir)"
REMOVED_RUNTIME=0

if [[ ! -e "${RUNTIME_RAW}" && ! -L "${RUNTIME_RAW}" ]]; then
  echo "No economics sidecar runtime found."
else
  # Resolve symlinks and refuse `.`/`..` components, so the checks below and
  # the removal see the same physical directory.
  RUNTIME_DIR="$(econ_real_dir "${RUNTIME_RAW}")" \
    || refuse "Refusing: the runtime path ${RUNTIME_RAW:0:200} is relative or contains . or .. components."
  HOME_REAL="$(econ_real_dir "${HOME}")" || HOME_REAL="${HOME}"

  [[ -d "${RUNTIME_DIR}" ]] \
    || refuse "Refusing: ${RUNTIME_DIR:0:200} is not a directory."
  [[ "${RUNTIME_DIR}" != "/" && "${RUNTIME_DIR}" != "${HOME_REAL}" ]] \
    || refuse "Refusing: the runtime path resolves to ${RUNTIME_DIR:0:200} (/ or your home directory). Check REVENIUM_SIDECAR_HOME."
  if ! econ_runtime_owned "${RUNTIME_DIR}"; then
    if [[ -f "${RUNTIME_DIR}/INSTALLED" || -f "${RUNTIME_DIR}/PROVISION_STATUS" ]]; then
      refuse "Refusing: ${RUNTIME_DIR:0:200} has no ${ECON_RUNTIME_MARKER} marker. It may be a runtime from an earlier version, which wrote none: check that it holds only bin/uv, python/, venv/, cache/ and the INSTALLED, PROVISION_STATUS and provision.log files, then remove it by hand."
    fi
    refuse "Refusing: ${RUNTIME_DIR:0:200} has no ${ECON_RUNTIME_MARKER} marker, so it is not a sidecar runtime this installer created. Check REVENIUM_SIDECAR_HOME."
  fi
  # A runtime that contains a state base would take the ledgers with it.
  if econ_is_under "${STANDALONE_BASE}" "${RUNTIME_DIR}" \
     || econ_is_under "${NEMOCLAW_BASE}" "${RUNTIME_DIR}"; then
    refuse "Refusing: ${RUNTIME_DIR:0:200} contains sidecar state, which must be kept."
  fi

  # Only what the provisioner creates. econ_write_kv's interrupted temp
  # files are named .<file>.XXXXXX.
  for entry in bin/uv python venv venv.new venv.old cache \
               INSTALLED PROVISION_STATUS provision.log; do
    rm -rf -- "${RUNTIME_DIR:?}/${entry}"
  done
  rm -f -- "${RUNTIME_DIR}"/.INSTALLED.* "${RUNTIME_DIR}"/.PROVISION_STATUS.* \
    "${RUNTIME_DIR}/${ECON_RUNTIME_MARKER}".*
  rmdir -- "${RUNTIME_DIR}/bin" 2>/dev/null || true  # kept when it holds other files
  REMOVED_RUNTIME=1
  if [[ "$(ls -A "${RUNTIME_DIR}")" == "${ECON_RUNTIME_MARKER}" ]]; then
    rm -f -- "${RUNTIME_DIR}/${ECON_RUNTIME_MARKER}"
    rmdir -- "${RUNTIME_DIR}" || warn "Could not remove the empty directory ${RUNTIME_DIR}"
    info "Removed the economics sidecar runtime at ${RUNTIME_DIR}"
  else
    info "Removed the economics sidecar runtime from ${RUNTIME_DIR}"
    warn "Kept ${RUNTIME_DIR} and its ${ECON_RUNTIME_MARKER} marker: it also holds files the provisioner did not create."
  fi
fi

# ---------------------------------------------------------------------------
# 2. Report what was kept, and who is affected
# ---------------------------------------------------------------------------
if [[ "${REMOVED_RUNTIME}" -eq 1 ]]; then
  KEPT=0
  for base in "${STANDALONE_BASE}" "${NEMOCLAW_BASE}"; do
    if [[ -d "${base}" ]]; then
      if [[ "${KEPT}" -eq 0 ]]; then echo ""; echo "  Sidecar state kept:"; fi
      echo "    ${base}"
      KEPT=1
    fi
  done
  if [[ "${KEPT}" -eq 1 ]]; then
    echo "  These hold the ledgers, cursors and redacted turn cache. A reinstall"
    echo "  reuses them, so nothing is sent to Revenium twice. Delete them by hand"
    echo "  only if the sidecar will not be reinstalled."
  fi

  if crontab -l 2>/dev/null | grep -qF "revenium-metering"; then
    warn "Metering cron entries are still installed. Their ticks will report the sidecar as not provisioned until post-install is re-run, and the agent will tell the user once."
  fi

  SANDBOX_COUNT=0
  for d in "${NEMOCLAW_BASE}"/*; do
    if [[ -d "${d}" ]]; then SANDBOX_COUNT=$((SANDBOX_COUNT + 1)); fi
  done
  if [[ "${SANDBOX_COUNT}" -gt 1 ]]; then
    warn "The runtime was shared by ${SANDBOX_COUNT} NemoClaw sandboxes on this host; job tracking has stopped for all of them."
  fi
fi

# ---------------------------------------------------------------------------
# 3. Optional: purge the redacted turn cache only
# ---------------------------------------------------------------------------
if [[ "${PURGE_CACHE}" -eq 1 ]]; then
  PURGED=0
  while IFS= read -r sd; do
    [[ -n "${sd}" ]] || continue
    # Only a real dir this user owns; a symlinked state dir could point the
    # removal somewhere else.
    if [[ -L "${sd}" || ! -O "${sd}" ]]; then
      warn "Skipping ${sd}: not a directory owned by you."
      continue
    fi
    if [[ -d "${sd}/turns" || -L "${sd}/turns" ]]; then
      rm -rf -- "${sd}/turns"
      info "Removed turn cache ${sd}/turns"
      PURGED=1
    fi
  done < <(state_dirs)
  if [[ "${PURGED}" -eq 0 ]]; then
    echo "No turn cache found."
  fi
fi

exit 0
