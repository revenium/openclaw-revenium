#!/usr/bin/env bash
# Spike 008 (SPIKE-01, D-03's second determination) — how does a script running
# inside or alongside an agent turn learn which session it is in, on 2.0?
#
# Sources:
#   scripts/write-marker.sh (~line 66), scripts/write-job-marker.sh (~line 132),
#     scripts/verify-markers.sh (~line 91), scripts/guardrail-check.sh (~line 496) —
#     the four current-session resolvers this candidate set must replace. All four
#     glob the newest non-cron *.jsonl filename in SESSIONS_DIR and never read
#     message content.
#   scripts/get-root-session-id.py — the root-session walk sitting on top of the
#     same filename convention (child->parent via sessions_spawn toolResult lines).
#   scripts/common.sh — OPENCLAW_HOME resolution + sandbox normalization.
#   .planning/spikes/008-sqlite-session-read-path/schema-capture.sql.txt — the
#     captured schema; candidate 3 selects only identifiers present there
#     (session_nodes.created_via, .updated_at — confirmed columns).
#
# Throwaway evidence-gathering probe (D-11) — not production code.
#
# Candidates tested, in order (per plan 17-03 Task 3):
#   1. Process environment — env handed to a tool/exec subprocess during a turn.
#   2. CLI metadata — `openclaw sessions list --json`, most-recent-interaction.
#   3. Direct SQL — session_nodes ordered by updated_at, created_via != 'cron'.
#   4. Hook payload — subagent_spawned/subagent_ended session-key fields
#      (documented shape only; full live hook matrix is plan 17-05/SPIKE-02's job).
#
# Ground truth established by driving a real turn with a distinctive marker
# (SPIKE008_ENVDUMP_DONE) and confirming which session id the CLI's own
# --json response reports it landed under, then checking whether each
# candidate's answer matches.
#
# Usage (run on the live host, ubuntu@52.90.9.242):
#   bash probe-session-id-resolution.sh candidate1 <marker-text>
#   bash probe-session-id-resolution.sh candidate2 <agent-id>
#   bash probe-session-id-resolution.sh candidate3 <sqlite-path>
set -u

CANDIDATE="${1:?usage: probe-session-id-resolution.sh candidate1|candidate2|candidate3 ...}"

candidate1_env() {
  # Have the agent's own exec tool dump its environment and grep for anything
  # session/agent-identifying. No retry loop; a real agent turn is driven once.
  local marker="${2:?marker text}"
  echo "--- CANDIDATE 1: process environment (subprocess env during a live tool call) ---"
  echo "Drive one real turn whose exec tool call runs: env | sort > /tmp/spike008-env-dump.txt"
  echo "Then grep the dump for OPENCLAW_/SESSION_/AGENT_ID-shaped variables:"
  grep -iE 'OPENCLAW|SESSION|AGENT_ID|SESSION_KEY|SESSION_ID' /tmp/spike008-env-dump.txt || echo "(no session-identifying var found)"
}

candidate2_cli() {
  local agent="${2:?agent id}"
  echo "--- CANDIDATE 2: CLI metadata (openclaw sessions list --json, most recent interaction) ---"
  openclaw sessions list --agent "${agent}" --json 2>&1 \
    | python3 -c "
import json,sys
d=json.load(sys.stdin)
sessions=[s for s in d.get('sessions',[]) if not s.get('key','').split(':')[-1] == 'cron']
sessions.sort(key=lambda s: s.get('lastInteractionAt') or s.get('updatedAt') or 0, reverse=True)
print(json.dumps(sessions[0] if sessions else None, indent=2))
"
}

candidate3_sql() {
  local db="${2:?sqlite path}"
  echo "--- CANDIDATE 3: direct SQL (session_nodes ordered by updated_at, created_via != cron) ---"
  sqlite3 -cmd "PRAGMA busy_timeout=5000;" "file:${db}?mode=ro" \
    "SELECT session_key, current_session_id, created_via, updated_at FROM session_nodes WHERE created_via IS NULL OR created_via != 'cron' ORDER BY updated_at DESC LIMIT 1;"
}

case "${CANDIDATE}" in
  candidate1) candidate1_env "$@" ;;
  candidate2) candidate2_cli "$@" ;;
  candidate3) candidate3_sql "$@" ;;
  *) echo "unknown candidate: ${CANDIDATE}" >&2; exit 1 ;;
esac
