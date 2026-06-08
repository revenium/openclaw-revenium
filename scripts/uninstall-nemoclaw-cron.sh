#!/usr/bin/env bash
# =============================================================================
# Uninstall Revenium NemoClaw Metering Cron Job
#
# Removes the per-sandbox crontab entry for the named sandbox.
# Optionally unmounts the SSHFS mount for that sandbox (fail-open).
#
# Usage:
#   uninstall-nemoclaw-cron.sh <sandbox-name>
#   export REVENIUM_SANDBOX_NAME=<name> && uninstall-nemoclaw-cron.sh
#
# The sandbox-scoped marker "# revenium-metering-nemoclaw:<sandbox>" is
# matched exactly via grep -vF — the standalone "# revenium-metering" entry
# and other sandboxes' entries are never touched (T-14-07).
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Sandbox name (required): env-var or positional arg.
# ---------------------------------------------------------------------------
SANDBOX_NAME="${REVENIUM_SANDBOX_NAME:-${1:-}}"
if [[ -z "${SANDBOX_NAME}" ]]; then
  echo "Usage: uninstall-nemoclaw-cron.sh <sandbox-name>" >&2
  echo "  or: export REVENIUM_SANDBOX_NAME=<name>" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# Per-sandbox marker (exact, sandbox-scoped).
# grep -vF on this string will NOT match the standalone "# revenium-metering"
# entry nor another sandbox's "# revenium-metering-nemoclaw:<other>" marker.
# ---------------------------------------------------------------------------
CRON_MARKER="# revenium-metering-nemoclaw:${SANDBOX_NAME}"

# ---------------------------------------------------------------------------
# Idempotent check — exit 0 if no matching entry (nothing to remove).
# ---------------------------------------------------------------------------
if ! crontab -l 2>/dev/null | grep -qF "${CRON_MARKER}"; then
  echo "No NemoClaw cron entry found for sandbox '${SANDBOX_NAME}'."
  exit 0
fi

# ---------------------------------------------------------------------------
# Remove ONLY lines matching the sandbox-scoped marker (T-14-07).
# Capture first, then write back — avoids the read/write race on the same
# file when the stub (or real) crontab write truncates before the read side
# has finished (mirroring the two-step pattern in install-nemoclaw-cron.sh).
# ---------------------------------------------------------------------------
REMAINING="$(crontab -l 2>/dev/null | grep -vF "${CRON_MARKER}" || true)"
if [[ -n "${REMAINING}" ]]; then
  printf '%s\n' "${REMAINING}" | crontab -
else
  echo "" | crontab -
fi
echo "Revenium NemoClaw metering cron removed for sandbox '${SANDBOX_NAME}'."

# ---------------------------------------------------------------------------
# Optional unmount (fail-open, T-14-08).
# If the SSHFS mount for this sandbox is present, unmount it.
# Any failure here is tolerated — cron removal already succeeded above.
# ---------------------------------------------------------------------------
MNT="${HOME}/sbx-openclaw-${SANDBOX_NAME}"
if mountpoint -q "${MNT}" 2>/dev/null; then
  fusermount -u "${MNT}" 2>/dev/null || umount "${MNT}" 2>/dev/null || true
  echo "Mount at ${MNT} unmounted."
fi
