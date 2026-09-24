#!/usr/bin/env bash
# =============================================================================
# bounded-run.sh — Portable time-bound enforcement (GATE-03 gap-closure,
# 18-VERIFICATION gap #2 / 18-REVIEW CR-03).
#
# SOURCED (not executed). Sourced by scripts/post-install.sh (this plan) and,
# in a future plan, scripts/post-install-nemoclaw.sh's `nemoclaw()` wrapper.
# Callers MUST define warn() (the one-line
# `warn()  { echo "  ⚠ $*"; }` convention used throughout the install-family
# scripts) BEFORE sourcing this file. A defensive fallback is provided below
# for direct/hermetic sourcing (e.g. this file's own unit tests), but
# production callers should rely on their own warn() definition, not this
# fallback.
#
# Usage:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   . "${SCRIPT_DIR}/bounded-run.sh"
#   bounded_run 120 openclaw doctor --fix --non-interactive
#
# BASH 3.x COMPATIBILITY (mandatory): the standalone path is documented bash
# 3.x compatible (macOS default /bin/bash is 3.2). This file MUST NOT use any
# bash-4-only construct: the wait builtin's job-select flag, associative-array
# declarations, uppercase/lowercase parameter-expansion operators, the
# variable-is-set conditional test, or the array-from-stdin builtins.
# =============================================================================
# NOTE: No `set -e` here — this is a sourced library. Callers that set -e will
# keep it. Adding -e here would cause unexpected exits in the caller's context
# on any sub-expression that evaluates to non-zero (mirrors
# scripts/version-gate.sh and scripts/common.sh).
set -uo pipefail

# Defensive fallback: only used when sourced without a caller-defined warn()
# (e.g. this file's own hermetic unit tests). Production callers
# (post-install.sh, and later post-install-nemoclaw.sh) already define warn()
# before the source line, so this never overrides their behavior.
declare -F warn >/dev/null 2>&1 || warn() { echo "  ⚠ $*"; }

# ---------------------------------------------------------------------------
# Module-level once-flag (GATE-03 gap-closure requirement: the portable-path
# notice fires at most ONCE per shell process, not once per bounded_run call).
# Initialized empty at source time; set non-empty after the first emission.
# ---------------------------------------------------------------------------
_BOUNDED_RUN_NOTICE_EMITTED=""

# ---------------------------------------------------------------------------
# bounded_run SECONDS CMD [ARGS...]
#
# Runs CMD (via the `command` builtin — never re-entering a same-named shell
# function) under a SECONDS ceiling. Returns CMD's own exit status, except
# that it returns 124 when the ceiling expires — matching GNU `timeout`'s
# convention, so existing rc-124 branches in callers keep working unchanged.
#
# Native path: when BOUNDED_RUN_FORCE_PORTABLE is empty AND GNU `timeout`
# resolves on PATH, delegate to it directly — byte-for-byte today's behavior.
#
# Portable path: otherwise, background CMD, start a silenced watchdog subshell
# that signals ONLY the PID this function captured from $! (never a PID from
# a file, command output, or process-table pattern match), and disclose the
# mechanism swap on stderr (once per process).
# ---------------------------------------------------------------------------
bounded_run() {
  local _secs="$1"
  shift

  if [[ -z "${BOUNDED_RUN_FORCE_PORTABLE:-}" ]] && command -v timeout >/dev/null 2>&1; then
    # Native path — delegate to GNU coreutils timeout. `timeout` execs the
    # named binary via PATH itself, so a shadowing shell function is not a
    # concern on this path.
    timeout "${_secs}" "$@"
    return $?
  fi

  # Portable path.
  if [[ -z "${_BOUNDED_RUN_NOTICE_EMITTED}" ]]; then
    _BOUNDED_RUN_NOTICE_EMITTED=1
    if [[ -n "${BOUNDED_RUN_FORCE_PORTABLE:-}" ]]; then
      warn "GNU coreutils 'timeout' was bypassed (BOUNDED_RUN_FORCE_PORTABLE is set) — using the portable bash time-bound watchdog instead, ceiling ${_secs}s. Known limitation: the watchdog signals the direct child process only, not its process group, so a grandchild that ignores termination can outlive the bound. To restore the native bound: unset BOUNDED_RUN_FORCE_PORTABLE." >&2
    else
      warn "GNU coreutils 'timeout' was not found on PATH — using the portable bash time-bound watchdog instead, ceiling ${_secs}s. Known limitation: the watchdog signals the direct child process only, not its process group, so a grandchild that ignores termination can outlive the bound. To restore the native bound: install GNU coreutils (e.g. 'brew install coreutils') and add its gnubin directory to PATH." >&2
    fi
  fi

  # Run the command in the background, bypassing any shell function that
  # shadows its name (the `command` builtin is mandatory — see
  # post-install-nemoclaw.sh's nemoclaw() wrapper, the second consumer this
  # signature must fit).
  command "$@" &
  local _child_pid=$!

  # Sentinel path created lazily — only the watchdog creates the file itself,
  # so its existence after `wait` tells us the ceiling actually expired.
  local _sentinel
  _sentinel="$(mktemp -u "${TMPDIR:-/tmp}/bounded-run-sentinel.XXXXXX")"

  # Watchdog subshell — entire stdout/stderr redirected to /dev/null. This is
  # load-bearing, not hygiene: without it the watchdog inherits the caller's
  # command-substitution pipe and keeps it open for the full ceiling, turning
  # a fast command into a full-ceiling stall (T-18-11).
  (
    sleep "${_secs}"
    if kill -0 "${_child_pid}" 2>/dev/null; then
      : > "${_sentinel}"
      kill -TERM "${_child_pid}" 2>/dev/null || true
      sleep 2
      kill -0 "${_child_pid}" 2>/dev/null && kill -KILL "${_child_pid}" 2>/dev/null || true
    fi
  ) >/dev/null 2>&1 &
  local _watchdog_pid=$!

  local _rc=0
  wait "${_child_pid}" 2>/dev/null
  _rc=$?

  # Terminate the watchdog unconditionally so no watchdog outlives the
  # command it guarded, regardless of whether the ceiling ever fired.
  kill "${_watchdog_pid}" 2>/dev/null || true
  wait "${_watchdog_pid}" 2>/dev/null || true

  if [[ -f "${_sentinel}" ]]; then
    rm -f "${_sentinel}" 2>/dev/null || true
    return 124
  fi
  rm -f "${_sentinel}" 2>/dev/null || true
  return "${_rc}"
}
