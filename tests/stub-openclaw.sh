#!/usr/bin/env bash
# stub-openclaw.sh — Argv-capturing openclaw stub for integration tests.
#
# Phase 18 hermetic test harness companion. Place a symlink named "openclaw"
# on PATH pointing at this script (or ln -sf directly).
# Set STUB_OPENCLAW_ARGV_FILE to the path of a file where captured args are
# appended (one arg per line per invocation).
#
# Usage:
#   export STUB_OPENCLAW_ARGV_FILE="$(mktemp)"
#   mkdir -p /tmp/test-oc-bin
#   ln -sf "$(pwd)/tests/stub-openclaw.sh" /tmp/test-oc-bin/openclaw
#   export PATH=/tmp/test-oc-bin:$PATH
#   # ... run script under test ...
#   grep -- "--version" "${STUB_OPENCLAW_ARGV_FILE}"
#
# Environment switches:
#
#   STUB_OPENCLAW_VERSION_OUTPUT (default "OpenClaw 2026.9.6 (eb377ac)")
#     Overrides the line echoed for `openclaw --version`. Note: scripts/
#     version-gate.sh's require_openclaw_version() reads this same env var
#     directly (STUB_X:-$(real command) idiom) — this stub's --version arm
#     is provided for call sites that invoke the real `openclaw` binary on
#     PATH rather than the version-gate.sh env-var override.
#
#   STUB_OPENCLAW_DOCTOR_RC (default "0")
#     Exit code for `openclaw doctor` / `openclaw doctor --fix ...` (GATE-03,
#     consumed starting in plan 18-02).
#
#   STUB_OPENCLAW_DOCTOR_OUTPUT (default "Doctor: all checks passed.")
#     Output echoed for the doctor subcommand.
#
# SECURITY (T-18-SC): this stub only string-COMPAREs positional args (via a
# `case "$1" in ... esac` dispatch) and captures them with `printf '%s\n'`.
# It NEVER `eval`s or string-interpolates captured argv into a shell command.

# No -e: we manage exits explicitly per subcommand dispatch
set -uo pipefail

# ---------------------------------------------------------------------------
# 1. Argv capture (always first — every token is assertable)
# ---------------------------------------------------------------------------
if [[ -n "${STUB_OPENCLAW_ARGV_FILE:-}" ]]; then
  for arg in "$@"; do
    printf '%s\n' "${arg}" >> "${STUB_OPENCLAW_ARGV_FILE}"
  done
fi

# ---------------------------------------------------------------------------
# 2. Subcommand dispatch
# ---------------------------------------------------------------------------

# --version — echoes the stubbed OpenClaw version line and exits 0.
if [[ "${1:-}" == "--version" ]]; then
  echo "${STUB_OPENCLAW_VERSION_OUTPUT:-OpenClaw 2026.9.6 (eb377ac)}"
  exit 0
fi

# doctor [--fix] [--non-interactive] — echoes the stubbed doctor output and
# exits STUB_OPENCLAW_DOCTOR_RC (consumed by plan 18-02's GATE-03 step).
if [[ "${1:-}" == "doctor" ]]; then
  echo "${STUB_OPENCLAW_DOCTOR_OUTPUT:-Doctor: all checks passed.}"
  exit "${STUB_OPENCLAW_DOCTOR_RC:-0}"
fi

# ---------------------------------------------------------------------------
# 3. Default — any other subcommand exits 0 silently (unrecognized argv)
# ---------------------------------------------------------------------------
exit 0
