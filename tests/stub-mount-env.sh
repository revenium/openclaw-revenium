#!/usr/bin/env bash
# stub-mount-env.sh — Multi-tool mount/crontab/sshfs stub for hermetic tests.
#
# Phase 14 host-side metering loop test harness companion.
# Dispatch is by ${0##*/} (the symlink name the script is invoked as).
# Create symlinks named mountpoint, crontab, sshfs, fusermount, umount
# in a tmp bin directory prepended to PATH.
#
# Usage:
#   STUB_BIN=$(mktemp -d)
#   for cmd in mountpoint crontab sshfs fusermount umount; do
#     ln -sf "$(pwd)/tests/stub-mount-env.sh" "${STUB_BIN}/${cmd}"
#   done
#   export PATH="${STUB_BIN}:${PATH}"
#
# Environment switches:
#
#   STUB_MOUNT_UP (default "1")
#     Controls mountpoint exit code: 0 when STUB_MOUNT_UP=1 (default),
#     non-zero when STUB_MOUNT_UP=0.
#
#   STUB_SSHFS_RC (default "0")
#     Exit code returned by the sshfs stub.
#
#   STUB_CRONTAB_FILE (default "")
#     File path for the fake crontab. `crontab -l` prints its contents (empty
#     if unset/absent). `crontab -` or `crontab <file>` writes stdin or the
#     named file to STUB_CRONTAB_FILE. If STUB_CRONTAB_FILE is unset and a
#     write is requested, a warning is printed to stderr and the write is a
#     no-op.
#
#   STUB_MOUNT_ENV_ARGV_FILE (default "")
#     When set, every invocation appends its full argv to this file (one token
#     per line), so the harness can assert exact command shapes.
#
# SECURITY (T-14-02): this stub only string-compares argv with grep -qF / case.
# It NEVER executes or interpolates captured argv into a shell command.

# No -e: we manage exits explicitly per subcommand dispatch
set -uo pipefail

# ---------------------------------------------------------------------------
# Argv capture (always first — every token is assertable)
# ---------------------------------------------------------------------------
if [[ -n "${STUB_MOUNT_ENV_ARGV_FILE:-}" ]]; then
  for arg in "$@"; do
    printf '%s\n' "${arg}" >> "${STUB_MOUNT_ENV_ARGV_FILE}"
  done
fi

# ---------------------------------------------------------------------------
# Dispatch on the invocation name (symlink mode) or first argument (direct mode).
# When invoked as: mountpoint -q <dir>   → ${0##*/} == mountpoint
# When invoked as: bash stub-mount-env.sh mountpoint -q <dir> → $1 == mountpoint
# ---------------------------------------------------------------------------
_cmd="${0##*/}"
# If invoked as the raw script name, treat the first positional arg as the command.
case "${_cmd}" in
  stub-mount-env.sh|stub-mount-env)
    _cmd="${1:-}"
    [[ $# -gt 0 ]] && shift
    ;;
esac

case "${_cmd}" in

  # -------------------------------------------------------------------------
  # mountpoint — exits 0 when STUB_MOUNT_UP=1 (default), non-zero when =0
  # -------------------------------------------------------------------------
  mountpoint)
    if [[ "${STUB_MOUNT_UP:-1}" == "1" ]]; then
      exit 0
    else
      exit 1
    fi
    ;;

  # -------------------------------------------------------------------------
  # crontab — crontab -l prints STUB_CRONTAB_FILE; crontab - writes stdin to it
  # -------------------------------------------------------------------------
  crontab)
    # Determine mode from flags
    _mode=""
    _file_arg=""
    for _a in "$@"; do
      case "${_a}" in
        -l) _mode="list" ;;
        -)  _mode="write-stdin" ;;
        -r) _mode="remove" ;;
        -*)  ;;  # ignore other flags (e.g. -u user)
        *)  if [[ -z "${_mode}" ]]; then _mode="write-file"; _file_arg="${_a}"; fi ;;
      esac
    done

    case "${_mode:-list}" in
      list)
        if [[ -n "${STUB_CRONTAB_FILE:-}" && -f "${STUB_CRONTAB_FILE}" ]]; then
          cat "${STUB_CRONTAB_FILE}"
        fi
        exit 0
        ;;
      write-stdin)
        if [[ -n "${STUB_CRONTAB_FILE:-}" ]]; then
          cat > "${STUB_CRONTAB_FILE}"
        else
          echo "stub-mount-env[crontab]: STUB_CRONTAB_FILE not set — write is a no-op" >&2
          cat > /dev/null
        fi
        exit 0
        ;;
      write-file)
        if [[ -n "${STUB_CRONTAB_FILE:-}" ]]; then
          if [[ -n "${_file_arg}" && -f "${_file_arg}" ]]; then
            cp "${_file_arg}" "${STUB_CRONTAB_FILE}"
          else
            cat > "${STUB_CRONTAB_FILE}"
          fi
        else
          echo "stub-mount-env[crontab]: STUB_CRONTAB_FILE not set — write is a no-op" >&2
          cat > /dev/null
        fi
        exit 0
        ;;
      remove)
        if [[ -n "${STUB_CRONTAB_FILE:-}" ]]; then
          : > "${STUB_CRONTAB_FILE}"
        fi
        exit 0
        ;;
    esac
    exit 0
    ;;

  # -------------------------------------------------------------------------
  # sshfs — exits STUB_SSHFS_RC (default 0)
  # -------------------------------------------------------------------------
  sshfs)
    exit "${STUB_SSHFS_RC:-0}"
    ;;

  # -------------------------------------------------------------------------
  # fusermount / umount — exits 0 (unmount always succeeds in stub)
  # -------------------------------------------------------------------------
  fusermount|umount)
    exit 0
    ;;

  # -------------------------------------------------------------------------
  # Default — pass through (unknown invocation name)
  # -------------------------------------------------------------------------
  *)
    echo "stub-mount-env: unrecognized invocation as '${_cmd}'" >&2
    exit 0
    ;;

esac
