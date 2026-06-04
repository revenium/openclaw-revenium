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
# Phase 8 halt-handler additions:
#
#   STUB_REVENIUM_HALT_JOBS_FAIL=1
#     When set, `jobs create` and `jobs outcome` fail with a NON-409 error ONLY
#     for halt-handler-driven calls — identified by either:
#       (a) the --agentic-job-id value beginning with "guardrail-halt-" (synthetic
#           interrupted job created by the halt handler, D-05/D-09), OR
#       (b) a --result CANCELLED argument present in the call (halt-driven close of
#           a real open job, D-04).
#     Normal per-session `jobs create`/`jobs outcome` calls (with regular job ids
#     and SUCCESS/FAILED results) are UNAFFECTED — GROUP A-H assertions remain
#     valid when this switch is set alongside a normal session fixture.
#     This is the D-10 fail-open decoupling seam: a halt-jobs failure must NOT
#     abort the tick or endanger per-session metering.
#     Detection uses `printf '%s\n' "$@" | grep -qF --` idiom (same as
#     STUB_REVENIUM_409_FOR) — no eval, no string interpolation of argv.
#
# Phase 9 guardrail-event additions:
#
#   STUB_REVENIUM_GUARDRAILS_FAIL=1
#     When set, `guardrails enforcement-rules get` exits 1 with an EOF-style
#     error. Exercises the fail-open fallback path in guardrail-check.sh.
#     `meter completion`, `config show`, and `jobs` calls are UNAFFECTED.
#
#   STUB_REVENIUM_ENFORCEMENT_JSON=<json>
#     When set, returned as the body of `guardrails enforcement-rules get`.
#     Default when unset: '{"rules":[]}'.
#
#   STUB_REVENIUM_BUDGET_RULES_JSON=<json>
#     When set, returned as the body of `guardrails budget-rules list`.
#     Default when unset: '[]'.
#
# Phase 10 tool-registry/tool-event additions:
#
#   STUB_REVENIUM_NO_TOOLS=1
#     When set, `tools --help` exits 1, forcing TOOLS_CLI_CAPABLE=false in
#     report.sh. All meter tool-event and tools create calls are unaffected in
#     terms of routing — they never reach their branches when the probe fails.
#     Use for fail-open tests. `meter completion` and `config show` are
#     UNAFFECTED.
#
#   STUB_REVENIUM_TOOLS_FAIL=1
#     When set, `tools create` exits 1 with a NON-409 error (HTTP 500 style).
#     Exercises the fail-open path where tool registration fails but tool-event
#     emission continues (the caller returns 0 on all paths). `meter tool-event`
#     and `meter completion` are UNAFFECTED.
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

# config show → emit Team ID line (satisfies report.sh:106 guard AND guardrail-check.sh
# Team ID parse at line 101). report.sh uses `revenium config show &>/dev/null` (only
# checks exit code, not output) — safe to add output here.
if [[ "$1 $2" == "config show" ]]; then
  echo "Team ID:    test-team-id"
  exit 0
fi

# guardrails --help and subcommand --help probes → exit 0 (satisfies has_guardrails_cli)
if [[ "$1" == "guardrails" && "$2" == "--help" ]]; then
  echo "usage: revenium guardrails <subcommand>"
  exit 0
fi
if [[ "$1 $2 $3" == "guardrails budget-rules --help" ]]; then
  echo "usage: revenium guardrails budget-rules <subcommand>"
  exit 0
fi
if [[ "$1 $2 $3" == "guardrails enforcement-events --help" ]]; then
  echo "usage: revenium guardrails enforcement-events <subcommand>"
  exit 0
fi

# guardrails enforcement-rules get → fixture JSON (or STUB_REVENIUM_GUARDRAILS_FAIL)
if [[ "$1 $2 $3" == "guardrails enforcement-rules get" ]]; then
  if [[ -n "${STUB_REVENIUM_GUARDRAILS_FAIL:-}" ]]; then
    echo '{"error":"EOF"}' >&2
    exit 1
  fi
  if [[ -n "${STUB_REVENIUM_ENFORCEMENT_JSON:-}" ]]; then
    echo "${STUB_REVENIUM_ENFORCEMENT_JSON}"
  else
    echo '{"rules":[]}'
  fi
  exit 0
fi

# guardrails budget-rules list → fixture JSON
if [[ "$1 $2 $3" == "guardrails budget-rules list" ]]; then
  if [[ -n "${STUB_REVENIUM_BUDGET_RULES_JSON:-}" ]]; then
    echo "${STUB_REVENIUM_BUDGET_RULES_JSON}"
  else
    echo '[]'
  fi
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

# tools --help → exit 0 unless STUB_REVENIUM_NO_TOOLS forces probe failure
if [[ "$1 $2" == "tools --help" ]]; then
  if [[ -n "${STUB_REVENIUM_NO_TOOLS:-}" ]]; then
    exit 1
  fi
  echo "usage: revenium tools <subcommand>"
  exit 0
fi

# meter tool-event --help → print a line with --tool-id so the dual probe
# sets TOOLS_CLI_CAPABLE=true. ONLY for this --help invocation, not for real
# meter tool-event posts (those fall through to the default exit 0).
if [[ "$1 $2 $3" == "meter tool-event --help" ]]; then
  echo "  --tool-id string    ID of the tool"
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

  # Halt-handler jobs-fail switch (Phase 8 D-10 fail-open seam): fails ONLY for
  # halt-driven calls — guardrail-halt- synthetic id OR --result CANCELLED.
  # Normal per-session calls (regular ids, SUCCESS/FAILED results) pass through.
  if [[ -n "${STUB_REVENIUM_HALT_JOBS_FAIL:-}" ]]; then
    if printf '%s\n' "$@" | grep -qF -- "guardrail-halt-" || \
       printf '%s\n' "$@" | grep -qF -- "CANCELLED"; then
      echo "Error: 500 halt jobs service unavailable" >&2
      exit 1
    fi
  fi
fi

# tools create — optional NON-409 failure (STUB_REVENIUM_TOOLS_FAIL seam)
# This exercises the fail-open path where registration fails but tool-event
# emission continues. Does NOT emit a 409 — 409 backstop is handled by the
# existing STUB_REVENIUM_409_FOR mechanism.
if [[ "$1 $2" == "tools create" ]]; then
  if [[ -n "${STUB_REVENIUM_TOOLS_FAIL:-}" ]]; then
    echo "Error: 500 tools service unavailable" >&2
    exit 1
  fi
  # Mirror the real API's tool-type enum enforcement: the live endpoint rejects
  # any --tool-type outside this set with HTTP 400 (confirmed against
  # api.revenium.ai — "BUILTIN" is NOT valid). Keeps the hermetic test honest so
  # an invalid classify_tool_type value is caught here, not in production.
  _stub_tt=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--tool-type" ]]; then _stub_tt="${2:-}"; break; fi
    shift
  done
  case "${_stub_tt}" in
    SDK|MCP_SERVER|AI_SERVICE|REST_API|LOCAL_FUNCTION|CUSTOM) : ;;
    *)
      echo "Error: Request failed (HTTP 400): Value '${_stub_tt}' is not valid. Allowed values: [SDK, MCP_SERVER, AI_SERVICE, REST_API, LOCAL_FUNCTION, CUSTOM]" >&2
      exit 1
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# 4. Default — exit 0 (meter completion posts, meter tool-event posts, etc.)
# ---------------------------------------------------------------------------
exit 0
