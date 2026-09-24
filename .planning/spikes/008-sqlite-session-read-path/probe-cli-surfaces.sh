#!/usr/bin/env bash
# Spike 008 (SPIKE-01, candidate (b)) — the real `openclaw sessions` / `doctor` read
# surfaces, exercised once per surface per cell.
#
# Sources:
#   .planning/phases/17-live-host-fact-finding-spike/17-RESEARCH.md
#     §"Session Read Path" candidate (b), §"Open Questions" item 4, §"State of the Art"
#     (retracted `openclaw sessions export` command — never resurrected here)
#   .planning/spikes/008-sqlite-session-read-path/sample-rows.txt (candidate (a)'s
#     per-field yardstick this candidate is compared against)
#
# Throwaway evidence-gathering probe (D-11) — not production code. Surfaces exercised,
# all four, per cell:
#   1. openclaw sessions list --json
#   2. openclaw sessions tail --session-key <key> --tail <n>
#   3. openclaw sessions export-trajectory --session-key <key> --json
#      (invoked UNATTENDED from a non-TTY context: stdin from /dev/null, under an
#      explicit `timeout`, never from an interactive shell — this is the load-bearing
#      probe for RESEARCH.md Open Question 4)
#   4. openclaw doctor --session-sqlite inspect --session-sqlite-all-agents --json
#
# Cells (D-13 — every result labelled, neither cell's result generalized to the other):
#   HOST-LOCAL (standalone path) — surfaces run directly on the host, standard PATH.
#   SANDBOX (NemoClaw/OpenShell path) — surfaces reached through
#     `nemoclaw revenium-2-0 exec --timeout <s> -- <single-line cmd>` per CONVENTIONS.md
#     (never a polling loop; single-line argv only — gRPC rejects newlines in args).
#
# Usage (run on the live host, ubuntu@52.90.9.242; requires PATH extended with
# $HOME/.npm-global/bin and $HOME/.local/bin per 007's PATH-ordering finding):
#   bash probe-cli-surfaces.sh host-local <agent-id> <session-key>
#   bash probe-cli-surfaces.sh sandbox <sandbox-name> <agent-id> <session-key>
set -u

CELL="${1:?usage: probe-cli-surfaces.sh host-local|sandbox ...}"

run_host_local() {
  local agent="$1" key="$2"
  echo "--- HOST-LOCAL: sessions list --agent ${agent} --json ---"
  openclaw sessions list --agent "${agent}" --json 2>&1

  echo "--- HOST-LOCAL: sessions tail --agent ${agent} --session-key ${key} --tail 20 ---"
  openclaw sessions tail --agent "${agent}" --session-key "${key}" --tail 20 2>&1

  echo "--- HOST-LOCAL: sessions export-trajectory --agent ${agent} --session-key ${key} --json (unattended, non-TTY, 30s timeout) ---"
  timeout 30 openclaw sessions export-trajectory --agent "${agent}" --session-key "${key}" --json < /dev/null 2>&1
  echo "EXIT=$?"

  echo "--- HOST-LOCAL: doctor --session-sqlite inspect --session-sqlite-all-agents --json ---"
  openclaw doctor --session-sqlite inspect --session-sqlite-all-agents --json 2>&1
}

run_sandbox() {
  local sandbox="$1" agent="$2" key="$3"
  echo "--- SANDBOX (${sandbox}): sessions list --agent ${agent} --json ---"
  nemoclaw "${sandbox}" exec --timeout 60 -- sh -lc "openclaw sessions list --agent ${agent} --json 2>&1"

  echo "--- SANDBOX (${sandbox}): sessions tail --agent ${agent} --session-key ${key} --tail 20 ---"
  nemoclaw "${sandbox}" exec --timeout 60 -- sh -lc "openclaw sessions tail --agent ${agent} --session-key ${key} --tail 20 2>&1"

  echo "--- SANDBOX (${sandbox}): sessions export-trajectory --agent ${agent} --session-key ${key} --json (unattended, non-TTY, 30s inner timeout) ---"
  nemoclaw "${sandbox}" exec --timeout 40 -- sh -lc "timeout 30 openclaw sessions export-trajectory --agent ${agent} --session-key ${key} --json < /dev/null 2>&1; echo EXIT=\$?"

  echo "--- SANDBOX (${sandbox}): doctor --session-sqlite inspect --session-sqlite-all-agents --json (40s inner timeout) ---"
  nemoclaw "${sandbox}" exec --timeout 50 -- sh -lc "timeout 40 openclaw doctor --session-sqlite inspect --session-sqlite-all-agents --json < /dev/null 2>&1; echo EXIT=\$?"
}

case "${CELL}" in
  host-local) run_host_local "${2:?agent-id}" "${3:?session-key}" ;;
  sandbox)    run_sandbox "${2:?sandbox-name}" "${3:?agent-id}" "${4:?session-key}" ;;
  *) echo "unknown cell: ${CELL}" >&2; exit 1 ;;
esac
