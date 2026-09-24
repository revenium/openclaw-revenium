#!/usr/bin/env bash
# Spike 008 (SPIKE-01, candidate (a)) — read-only, WAL-aware direct SQLite probe.
#
# Sources:
#   .planning/phases/17-live-host-fact-finding-spike/17-RESEARCH.md
#     §"Session Read Path" candidate (a), §"Pattern 1", §"Code Examples", §"Don't Hand-Roll"
#     (mechanics cross-checked from sqlite.org/forum + sqlite/sqlite doc/wal-lock.md)
#   .planning/spikes/007-live-2-0-host-provisioning/README.md
#     ("sqlite3 CLI cannot mix a PRAGMA and a dot-command in one semicolon-joined string")
#   .planning/spikes/001-nemoclaw-bootstrap/probe-host-compat.sh (pass/warn/fail scaffolding shape)
#
# Does NOT write to either SQLite store, does NOT take a lock beyond a plain
# read-only connection, and does NOT retry/backoff around a busy read — a
# SQLITE_BUSY result is itself the finding this probe exists to surface, per
# RESEARCH.md's explicit "Don't Hand-Roll" guidance. If a read stalls or
# fails, that is recorded as-is, not silently retried past.
#
# Every connection uses a read-only URI (`file:<path>?mode=ro`) plus an
# explicit `PRAGMA busy_timeout=5000` in the same invocation — the CLI does
# not set a busy timeout implicitly, so omitting this would make an
# occasional multi-second stall indistinguishable from a clean read.
#
# Run as two independent cells; neither cell's result is generalized to the
# other (RESEARCH.md Pitfall 3):
#   HOST-LOCAL — standalone path's store, resolved from
#     .planning/spikes/007-live-2-0-host-provisioning/versions-resolved.txt
#     ("standalone: sqlite-store-path=...").
#   SSHFS      — NemoClaw-path store reached through the host-side share
#     mount established in plan 17-01
#     ("nemoclaw-sandbox: sqlite-store-path=/sandbox/.openclaw/...", surfaced
#     host-side at ~/nemoclaw-<sandbox>-mount/agents/main/agent/openclaw-agent.sqlite).
#
# Usage (run on the live host, ubuntu@52.90.9.242):
#   HOST_DB="$HOME/.openclaw/agents/main/agent/openclaw-agent.sqlite" \
#   SSHFS_DB="$HOME/nemoclaw-revenium-2-0-mount/agents/main/agent/openclaw-agent.sqlite" \
#   bash probe-sqlite-direct.sh
set -u

HOST_DB="${HOST_DB:-$HOME/.openclaw/agents/main/agent/openclaw-agent.sqlite}"
SSHFS_DB="${SSHFS_DB:-$HOME/nemoclaw-revenium-2-0-mount/agents/main/agent/openclaw-agent.sqlite}"

run_ro() {
  # $1 = db path, $2.. = sqlite3 args after -cmd busy_timeout
  local db="$1"; shift
  sqlite3 -cmd "PRAGMA busy_timeout=5000;" "file:${db}?mode=ro" "$@"
}

probe_cell() {
  local label="$1" db="$2"
  echo "=== CELL ${label}: journal_mode ==="
  run_ro "${db}" "PRAGMA journal_mode;"

  echo "=== CELL ${label}: schema (verbatim, appended to schema-capture.sql.txt) ==="
  {
    echo "-- CELL ${label} -- $(date -u +%Y-%m-%dT%H:%M:%SZ) -- ${db}"
    run_ro "${db}" ".schema"
  } >> schema-capture.sql.txt

  echo "=== CELL ${label}: table count ==="
  run_ro "${db}" ".tables" | tr -s ' ' '\n' | grep -c .

  echo "=== CELL ${label}: sessions (session_windows) ==="
  run_ro "${db}" "SELECT session_id, session_key, model_provider, model FROM session_windows ORDER BY created_at DESC LIMIT 10;"

  echo "=== CELL ${label}: session parentage columns (session_nodes) ==="
  run_ro "${db}" "SELECT session_key, current_session_id, parent_session_key, spawned_by, fork_source_session_key, created_via FROM session_nodes ORDER BY updated_at DESC LIMIT 10;"

  echo "=== CELL ${label}: transcript_events row/type counts ==="
  run_ro "${db}" "SELECT json_extract(event_json,'\$.type'), count(*) FROM transcript_events WHERE event_json IS NOT NULL GROUP BY 1;"
}

probe_cell "HOST-LOCAL" "${HOST_DB}"
probe_cell "SSHFS" "${SSHFS_DB}"

echo "=== Per-cell summary: token usage / model id / toolCalls / session parentage recoverable? ==="
echo "See sample-rows.txt for the labelled per-field verdicts captured from this probe's live run."
