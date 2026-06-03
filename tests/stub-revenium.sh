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
#
# Environment switches (Phase 6 additions):
#
#   STUB_REVENIUM_NO_JOBS=1
#     When set, the dual capability probe fails: `jobs --help` exits 1, which
#     forces JOBS_CLI_CAPABLE=false in report.sh. Use for fail-open fixtures.
#     `meter completion` and `config show` are UNAFFECTED.
#
#   STUB_REVENIUM_409_FOR=<agentic-job-id>
#     When set and the invocation is `jobs create` or `jobs outcome` and that
#     id appears among the arguments, emit a 409-style conflict error to stderr
#     and exit 1. This exercises the 409-as-success idempotency path (D-06).
#     Takes precedence over STUB_REVENIUM_JOBS_FAIL for the same invocation.
#
#   STUB_REVENIUM_JOBS_FAIL=1
#     When set, `jobs create` and `jobs outcome` emit a generic NON-409 error
#     to stderr and exit 1. `meter completion` and `config show` are UNAFFECTED.
#     This is the CR-02/D-12 decoupling seam: a jobs-CLI failure must NOT wedge
#     completion metering or the offset gate.
#
# SECURITY (T-04-09 / V5): this stub only string-COMPAREs positional args and
# captures them with `printf '%s\n'`. It never `eval`s or string-interpolates
# captured argv into a command.

# ---------------------------------------------------------------------------
# 1. Argv capture (UNCHANGED — keep first so every token is assertable)
# ---------------------------------------------------------------------------
if [[ -n "${STUB_REVENIUM_ARGV_FILE:-}" ]]; then
  for arg in "$@"; do
    printf '%s\n' "${arg}" >> "${STUB_REVENIUM_ARGV_FILE}"
  done
fi

# ---------------------------------------------------------------------------
# 2. Capability-probe and config responses
# ---------------------------------------------------------------------------

# config show → exit 0 silently (satisfies report.sh:106 guard)
if [[ "$1 $2" == "config show" ]]; then
  exit 0
fi

# jobs --help → exit 0 unless STUB_REVENIUM_NO_JOBS forces probe failure
if [[ "$1 $2" == "jobs --help" ]]; then
  if [[ -n "${STUB_REVENIUM_NO_JOBS:-}" ]]; then
    exit 1
  fi
  echo "usage: revenium jobs <subcommand>"
  exit 0
fi

# meter completion --help → print a line with --agentic-job-id so the dual
# probe sets JOBS_CLI_CAPABLE=true. ONLY for this --help invocation, never
# for real meter completion posts.
if [[ "$1 $2 $3" == "meter completion --help" ]]; then
  echo "  --agentic-job-id string    ID of the agentic job to attribute this completion to"
  exit 0
fi

# ---------------------------------------------------------------------------
# 3. jobs create / jobs outcome — optional 409 or non-409 failure
# ---------------------------------------------------------------------------
if [[ "$1 $2" == "jobs create" || "$1 $2" == "jobs outcome" ]]; then
  # 409 fake (takes precedence): opt-in via STUB_REVENIUM_409_FOR
  if [[ -n "${STUB_REVENIUM_409_FOR:-}" ]] && printf '%s\n' "$@" | grep -qF -- "${STUB_REVENIUM_409_FOR}"; then
    echo "Error: 409 Conflict: job already exists" >&2
    exit 1
  fi

  # Non-409 jobs-fail switch (CR-02/D-12 decoupling seam)
  if [[ -n "${STUB_REVENIUM_JOBS_FAIL:-}" ]]; then
    echo "Error: 500 jobs service unavailable" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 4. Default — exit 0 (meter completion posts, etc. succeed silently)
# ---------------------------------------------------------------------------
exit 0
