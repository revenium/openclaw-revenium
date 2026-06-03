#!/usr/bin/env bash
# stub-revenium.sh — Argv-capturing revenium stub for integration tests.
#
# Place a copy or symlink named "revenium" on PATH pointing at this script.
# Set STUB_REVENIUM_ARGV_FILE to the path of a file where captured args are
# appended (one per line per invocation).
#
# Usage:
#   export STUB_REVENIUM_ARGV_FILE="$(mktemp)"
#   ln -sf "$(pwd)/tests/stub-revenium.sh" /tmp/test-bin/revenium
#   export PATH=/tmp/test-bin:$PATH
#   # ... run script under test ...
#   grep -- "--task-type" "${STUB_REVENIUM_ARGV_FILE}"

if [[ -n "${STUB_REVENIUM_ARGV_FILE:-}" ]]; then
  for arg in "$@"; do
    printf '%s\n' "${arg}" >> "${STUB_REVENIUM_ARGV_FILE}"
  done
fi
exit 0
