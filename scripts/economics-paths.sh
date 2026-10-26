#!/usr/bin/env bash
# =============================================================================
# economics-paths.sh — Path, validation, key=value and lock helpers for the
# agent-economics sidecar.
#
# SOURCED (not executed). Shared by scripts/economics.sh (the cron shim), the
# sidecar provisioner and the sidecar uninstaller, so every caller agrees on
# where the runtime and the per-install state live.
#
# Locations:
#   runtime (shared, disposable):  ${REVENIUM_SIDECAR_HOME:-$HOME/.local/share/revenium-sidecar}
#   standalone state (durable):    ${XDG_STATE_HOME:-$HOME/.local/state}/revenium-economics/standalone-<hash12>/
#                                  hash12 = first 12 hex chars of sha256 of the
#                                  resolved OPENCLAW_HOME (no trailing newline)
#   NemoClaw state (durable):      $HOME/.nemoclaw/revenium-economics/<sandbox>/
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${SCRIPT_DIR}/economics-paths.sh"
#   state_dir="$(econ_resolve_state_dir "${OPENCLAW_HOME}")"
#
# SECURITY: every value used to build a path is validated first (sandbox names
#   against an allowlist, state and runtime dirs resolved with `cd -P` and
#   checked against OPENCLAW_HOME). State files are parsed line by line with
#   `case`, never sourced or evaluated, and parsed values are stripped of
#   control characters and cut to 64 characters.
#
# BASH 3.x COMPATIBILITY (mandatory): the standalone path is documented bash
# 3.x compatible (macOS default /bin/bash is 3.2). This file MUST NOT use any
# bash-4-only construct: the wait builtin's job-select flag, associative-array
# declarations, uppercase/lowercase parameter-expansion operators, the
# variable-is-set conditional test, or the array-from-stdin builtins.
# =============================================================================
# NOTE: No `set -e` here — this is a sourced library. Callers that set -e will
# keep it. Adding -e here would cause unexpected exits in the caller's context
# on any sub-expression that evaluates to non-zero.
set -uo pipefail

# ---------------------------------------------------------------------------
# Constants. The two reason lists are the only vocabulary that may reach the
# agent-visible heartbeat.
# ---------------------------------------------------------------------------
ECON_REASONS="ok not_provisioned runtime_missing crashing timeout stuck unsafe_state_dir unsafe_runtime_dir"
ECON_PROVISION_REASONS="ok unsupported_platform download_failed checksum_mismatch python_install_failed venv_failed wheel_missing wheel_install_failed conformance_failed"
ECON_INFER_BUDGET_DEFAULT=50
ECON_DELIVER_PRE_BUDGET=15
ECON_DELIVER_POST_BUDGET=30
# A holder older than its budget plus this grace is reported as stuck rather
# than busy: bounded_run should have ended it, so something (for example an
# SSHFS read in uninterruptible sleep) is wedged.
ECON_LOCK_GRACE_SECONDS=60
ECON_HEARTBEAT_NAME="economics-status.json"

# ---------------------------------------------------------------------------
# _econ_sha256_stdin — sha256 hex of stdin. macOS has no guaranteed sha256sum.
# ---------------------------------------------------------------------------
_econ_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

_econ_valid_sandbox() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

# ---------------------------------------------------------------------------
# econ_valid_enum <value> <space-separated list> — exact word match.
# ---------------------------------------------------------------------------
econ_valid_enum() {
  local value="${1:-}" list="${2:-}" word
  [[ -n "${value}" ]] || return 1
  for word in ${list}; do
    [[ "${value}" == "${word}" ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# econ_runtime_dir — print the shared sidecar runtime dir.
# ---------------------------------------------------------------------------
econ_runtime_dir() {
  printf '%s\n' "${REVENIUM_SIDECAR_HOME:-${HOME}/.local/share/revenium-sidecar}"
}

# ---------------------------------------------------------------------------
# Runtime ownership marker. REVENIUM_SIDECAR_HOME can name any directory, and
# files such as bin/uv are common elsewhere (~/.local, ~/.cargo, Homebrew
# prefixes), so neither the provisioner nor the uninstaller trusts a dir by
# its contents. The provisioner writes this marker only into a dir that was
# new or empty, builds only into a dir that carries it, and the uninstaller
# removes only a dir that carries it.
#
#   econ_runtime_owned <dir>   0 when <dir> holds a regular, user-owned
#                              marker with the expected owner line
# ---------------------------------------------------------------------------
ECON_RUNTIME_MARKER=".revenium-sidecar-runtime"
ECON_RUNTIME_OWNER="revenium-sidecar"

econ_runtime_owned() {
  local marker="${1:-}/${ECON_RUNTIME_MARKER}"
  [[ -n "${1:-}" && -f "${marker}" && ! -L "${marker}" && -O "${marker}" ]] || return 1
  [[ "$(econ_read_kv "${marker}" owner)" == "${ECON_RUNTIME_OWNER}" ]]
}

# ---------------------------------------------------------------------------
# econ_real_dir <dir> — print the physical path of <dir> (`cd -P`, no
# realpath, which older macOS lacks). A missing tail is resolved through its
# deepest existing ancestor, so a dir can be checked before it is created.
# Returns 1 for a relative path or one with `.`/`..` components: after a
# missing component the kernel never resolves `..`, so `mkdir -p` could land
# somewhere the textual check did not see.
# ---------------------------------------------------------------------------
econ_real_dir() {
  local p="${1:-}" rest="" resolved dbl="//" one="/"
  [[ "${p}" == /* ]] || return 1
  case "/${p}/" in
    */./*|*/../*) return 1 ;;
  esac
  # Pattern and replacement come from variables: bash 3.2 keeps the
  # backslashes of an escaped `/` in the replacement text.
  while [[ "${p}" == *//* ]]; do p="${p//${dbl}/${one}}"; done
  while [[ "${p}" == */ && "${p}" != "/" ]]; do p="${p%/}"; done
  while [[ ! -d "${p}" ]]; do
    rest="/${p##*/}${rest}"
    p="${p%/*}"
    [[ -n "${p}" ]] || p="/"
  done
  resolved="$(cd -P -- "${p}" 2>/dev/null && pwd -P)" || return 1
  [[ "${resolved}" == "/" ]] && resolved=""
  if [[ -z "${resolved}${rest}" ]]; then
    printf '/\n'
  else
    printf '%s%s\n' "${resolved}" "${rest}"
  fi
}

# ---------------------------------------------------------------------------
# econ_is_under <child> <parent> — true when the resolved child equals the
# resolved parent or sits beneath it. Fails closed: a path that cannot be
# resolved counts as under, so callers refuse it.
# ---------------------------------------------------------------------------
econ_is_under() {
  local child parent
  child="$(econ_real_dir "${1:-}")" || return 0
  parent="$(econ_real_dir "${2:-}")" || return 0
  [[ "${parent}" == "/" ]] && return 0
  [[ "${child}" == "${parent}" || "${child}" == "${parent}/"* ]]
}

# ---------------------------------------------------------------------------
# State dir resolution.
# ---------------------------------------------------------------------------
econ_standalone_state_dir() {
  local home="${1:-}" resolved base hash
  resolved="$(econ_real_dir "${home}")" || resolved="${home}"
  base="${XDG_STATE_HOME:-}"
  # The XDG spec says a relative XDG_STATE_HOME is invalid and must be ignored.
  [[ "${base}" == /* ]] || base="${HOME}/.local/state"
  hash="$(printf '%s' "${resolved}" | _econ_sha256_stdin)"
  printf '%s/revenium-economics/standalone-%s\n' "${base}" "${hash:0:12}"
}

econ_nemoclaw_state_dir() {
  _econ_valid_sandbox "${1:-}" || return 1
  printf '%s/.nemoclaw/revenium-economics/%s\n' "${HOME}" "$1"
}

econ_resolve_state_dir() {
  if [[ -n "${REVENIUM_ECON_STATE_DIR:-}" ]]; then
    printf '%s\n' "${REVENIUM_ECON_STATE_DIR}"
  else
    econ_standalone_state_dir "${1:-}"
  fi
}

# ---------------------------------------------------------------------------
# Ownership and mode checks. Mode is read from the `ls -ld` perms field
# because `stat` flags differ between BSD and GNU. Only the first ten
# characters are compared, so a macOS `@` or `+` suffix does not matter.
# ---------------------------------------------------------------------------
_econ_perms() {
  local out
  out="$(ls -ld -- "${1}" 2>/dev/null)" || return 1
  printf '%s\n' "${out%% *}"
}

# econ_ensure_private_dir <dir> — create <dir> (and missing parents) 0700.
# Never chmods an existing dir: a dir someone else loosened is refused by
# econ_dir_is_private instead of being silently repaired.
econ_ensure_private_dir() {
  [[ -d "${1:-}" ]] && return 0
  ( umask 077 && mkdir -p -- "$1" ) 2>/dev/null
}

econ_dir_is_private() {
  local dir="${1:-}" perms
  [[ -d "${dir}" && ! -L "${dir}" && -O "${dir}" ]] || return 1
  perms="$(_econ_perms "${dir}")" || return 1
  [[ "${perms:0:10}" == "drwx------" ]]
}

econ_dir_not_shared_writable() {
  local dir="${1:-}" perms
  [[ -d "${dir}" && -O "${dir}" ]] || return 1
  perms="$(_econ_perms "${dir}")" || return 1
  [[ "${perms:5:1}" == "-" && "${perms:8:1}" == "-" ]]
}

econ_state_dir_is_safe() {
  econ_dir_is_private "${1:-}" || return 1
  ! econ_is_under "$1" "${2:-}"
}

# ---------------------------------------------------------------------------
# econ_read_kv <file> <key> — print the value of the first `key=` line, with
# control characters removed and cut to 64 characters. Prints nothing when
# the file or key is absent.
# ---------------------------------------------------------------------------
econ_read_kv() {
  local file="${1:-}" key="${2:-}" line value
  [[ -f "${file}" && -n "${key}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    case "${line}" in
      "${key}="*)
        value="${line#*=}"
        value="$(printf '%s' "${value}" | LC_ALL=C tr -d '\000-\037\177')"
        printf '%s\n' "${value:0:64}"
        return 0
        ;;
    esac
  done < "${file}"
  return 0
}

# ---------------------------------------------------------------------------
# econ_write_kv <file> <key=value>... — atomically replace <file> with one
# line per argument (temp file in the same dir, then mv). Newlines inside an
# argument are dropped so one argument can never forge a second key.
# ---------------------------------------------------------------------------
econ_write_kv() {
  local file="${1:-}" tmp arg
  [[ -n "${file}" ]] || return 1
  shift
  tmp="$( umask 077 && mktemp "$(dirname -- "${file}")/.$(basename -- "${file}").XXXXXX" 2>/dev/null )" || return 1
  for arg in "$@"; do
    printf '%s\n' "${arg//$'\n'/}"
  done > "${tmp}" || { rm -f -- "${tmp}"; return 1; }
  mv -f -- "${tmp}" "${file}" || { rm -f -- "${tmp}"; return 1; }
}

econ_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# ---------------------------------------------------------------------------
# Infer lock. flock (Linux) releases automatically when the holder dies; the
# mkdir fallback (macOS) cannot, so a lock dir older than the budget plus
# five minutes is reclaimed. <state>/infer.started records the holder's start
# epoch so a busy caller can tell a slow holder from a stuck one.
#
#   econ_lock_acquire <state_dir> <budget_seconds>   0 = held, 1 = busy
#   econ_lock_release <state_dir>
#   econ_lock_holder_age <state_dir>                 seconds, empty if unknown
# ---------------------------------------------------------------------------
econ_lock_acquire() {
  local state="${1:-}" budget="${2:-${ECON_INFER_BUDGET_DEFAULT}}" lock_dir stale_min
  [[ -d "${state}" ]] || return 1
  [[ "${budget}" =~ ^[0-9]{1,4}$ ]] || budget="${ECON_INFER_BUDGET_DEFAULT}"
  if command -v flock >/dev/null 2>&1; then
    exec 8>"${state}/infer.lock" || return 1
    if ! flock -n 8; then
      exec 8>&-
      return 1
    fi
  else
    lock_dir="${state}/infer.lock.d"
    stale_min=$(( (10#${budget} + 59) / 60 + 5 ))
    if [[ -d "${lock_dir}" ]] && [[ -n "$(find "${lock_dir}" -prune -mmin +"${stale_min}" 2>/dev/null)" ]]; then
      rmdir "${lock_dir}" 2>/dev/null || true
    fi
    mkdir "${lock_dir}" 2>/dev/null || return 1
  fi
  printf '%s\n' "$(date +%s)" > "${state}/infer.started" 2>/dev/null || true
  return 0
}

econ_lock_release() {
  local state="${1:-}"
  rm -f -- "${state}/infer.started" 2>/dev/null || true
  if command -v flock >/dev/null 2>&1; then
    exec 8>&- 2>/dev/null || true
  else
    rmdir "${state}/infer.lock.d" 2>/dev/null || true
  fi
  return 0
}

econ_lock_holder_age() {
  local started="" now
  [[ -f "${1:-}/infer.started" ]] || return 0
  IFS= read -r started < "$1/infer.started" 2>/dev/null || true
  [[ "${started}" =~ ^[0-9]{1,12}$ ]] || return 0
  now="$(date +%s)"
  printf '%s\n' "$(( now - 10#${started} ))"
}
