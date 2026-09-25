#!/usr/bin/env bash
# =============================================================================
# mk-session-store.sh — synthetic-SQLite fixture helper for scripts/session-store.sh
# unit tests. SOURCED (not executed) — never run this file directly.
#
# Builds real SQLite databases matching OpenClaw 2.0's session-store schema
# (session_nodes / session_windows / transcript_events), copied verbatim from
# .claude/skills/spike-findings-openclaw-revenium/sources/008-sqlite-session-read-path/schema-capture.sql.txt.
#
# This file is the ONLY writer to the fixture databases in the repo — every
# function here uses a plain read-write `sqlite3 "<db>" "<sql>"` invocation,
# NEVER scripts/session-store.sh's store_sql (which is read-only by design,
# T-19-03).
# =============================================================================
set -uo pipefail

_MK_SQLITE3_BIN="${STUB_SQLITE3_BIN:-sqlite3}"

# _mk_write <db> <sql> — internal: read-write sqlite3 invocation.
_mk_write() {
  local db="$1" sql="$2"
  "${_MK_SQLITE3_BIN}" "${db}" "${sql}"
}

# _mk_json_escape <string> — escapes a string for embedding inside a SQL
# single-quoted string literal that itself holds a JSON document: doubles
# single quotes only (SQL-level escaping). JSON-level quoting inside the
# value is the caller's responsibility (fixtures build JSON via python3
# where structure matters).
_mk_sql_quote() {
  local v="${1:-}"
  printf '%s' "${v//\'/\'\'}"
}

# ---------------------------------------------------------------------------
# mk_store <db> — creates the parent directory and the three CREATE TABLE
# statements (session_nodes, session_windows, transcript_events) copied
# verbatim from schema-capture.sql.txt, including the created_via CHECK enum
# and the event_json/event_zstd pair CHECK.
# ---------------------------------------------------------------------------
mk_store() {
  local db="$1"
  mkdir -p "$(dirname "${db}")"
  rm -f "${db}"
  _mk_write "${db}" "
CREATE TABLE session_nodes (
  session_key TEXT NOT NULL PRIMARY KEY,
  current_session_id TEXT NOT NULL,
  entry_json TEXT NOT NULL,
  legacy_acp_migration_json TEXT,
  entry_valid INTEGER NOT NULL DEFAULT 0 CHECK (entry_valid IN (-1, 0, 1)),
  updated_at INTEGER NOT NULL,
  status TEXT CHECK (status IS NULL OR status IN ('running', 'done', 'failed', 'killed', 'timeout')),
  created_at INTEGER,
  created_via TEXT CHECK (created_via IS NULL OR created_via IN ('operator', 'spawn', 'channel', 'cron', 'talk', 'run', 'plugin', 'internal')),
  created_actor_type TEXT CHECK (created_actor_type IS NULL OR created_actor_type IN ('human', 'agent', 'system')),
  created_actor_id TEXT,
  owner_actor_type TEXT,
  owner_actor_id TEXT,
  owner_assigned_by_type TEXT,
  owner_assigned_by_id TEXT,
  owner_assigned_at INTEGER,
  project_id TEXT,
  parent_session_key TEXT,
  spawned_by TEXT,
  fork_source_session_key TEXT,
  fork_source_session_id TEXT,
  fork_source_entry_id TEXT,
  label TEXT,
  display_name TEXT,
  category TEXT,
  icon TEXT,
  pinned_at INTEGER,
  archived_at INTEGER,
  last_read_at INTEGER,
  last_interaction_at INTEGER,
  last_activity_at INTEGER
) STRICT;
CREATE TABLE session_windows (
  session_id TEXT NOT NULL PRIMARY KEY,
  session_key TEXT NOT NULL,
  previous_session_id TEXT,
  reason TEXT CHECK (reason IS NULL OR reason IN ('initial', 'reset', 'rollover', 'fork', 'rewind', 'switch', 'recovery', 'compaction')),
  session_scope TEXT NOT NULL DEFAULT 'conversation' CHECK (session_scope IN ('conversation', 'shared-main', 'group', 'channel')),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  transcript_updated_at INTEGER DEFAULT NULL,
  transcript_observed_at INTEGER DEFAULT NULL,
  session_entry_provenance INTEGER NOT NULL DEFAULT 0 CHECK (session_entry_provenance IN (0, 1)),
  acp_owned INTEGER NOT NULL DEFAULT 0 CHECK (acp_owned IN (0, 1)),
  plugin_owner_id TEXT,
  hook_external_content_source TEXT CHECK (hook_external_content_source IS NULL OR hook_external_content_source IN ('gmail', 'webhook')),
  started_at INTEGER,
  ended_at INTEGER,
  status TEXT CHECK (status IS NULL OR status IN ('running', 'done', 'failed', 'killed', 'timeout')),
  chat_type TEXT CHECK (chat_type IS NULL OR chat_type IN ('direct', 'group', 'channel')),
  channel TEXT,
  account_id TEXT,
  primary_conversation_id TEXT,
  model_provider TEXT,
  model TEXT,
  agent_harness_id TEXT,
  parent_session_key TEXT,
  spawned_by TEXT,
  display_name TEXT
) STRICT;
CREATE TABLE transcript_events (
  session_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  event_json TEXT,
  created_at INTEGER NOT NULL,
  event_zstd BLOB,
  event_utf8_bytes INTEGER CHECK (event_utf8_bytes IS NULL OR event_utf8_bytes >= 0),
  navigation_json TEXT,
  PRIMARY KEY (session_id, seq),
  CHECK (
    (event_json IS NOT NULL AND event_zstd IS NULL)
    OR (
      event_json IS NULL AND event_zstd IS NOT NULL
      AND event_utf8_bytes IS NOT NULL
      AND event_utf8_bytes BETWEEN 1 AND 4194304
      AND length(event_zstd) BETWEEN 1 AND 4194304
      AND navigation_json IS NOT NULL
    )
  )
) STRICT;
"
}

# ---------------------------------------------------------------------------
# mk_session <db> <session_id> <session_key> <created_via_or_empty> <updated_at>
# ---------------------------------------------------------------------------
mk_session() {
  local db="$1" sid="$2" skey="$3" created_via="${4:-}" updated_at="$5"
  local q_sid q_skey created_via_sql
  q_sid="$(_mk_sql_quote "${sid}")"
  q_skey="$(_mk_sql_quote "${skey}")"
  if [[ -z "${created_via}" ]]; then
    created_via_sql="NULL"
  else
    created_via_sql="'$(_mk_sql_quote "${created_via}")'"
  fi
  _mk_write "${db}" "
INSERT INTO session_nodes (session_key, current_session_id, entry_json, entry_valid, updated_at, created_via)
VALUES ('${q_skey}', '${q_sid}', '{}', 0, ${updated_at}, ${created_via_sql});
INSERT INTO session_windows (session_id, session_key, created_at, updated_at)
VALUES ('${q_sid}', '${q_skey}', ${updated_at}, ${updated_at});
"
}

# ---------------------------------------------------------------------------
# mk_event <db> <session_id> <seq> <event_json> — inserts one row with
# created_at set to seq (fixture convenience — arbitrary but monotonic).
# event_json is passed via a temp file + `.read` to avoid SQL quoting
# hazards for arbitrarily complex embedded JSON.
# ---------------------------------------------------------------------------
mk_event() {
  local db="$1" sid="$2" seq="$3" event_json="$4"
  local q_sid tmp_sql
  q_sid="$(_mk_sql_quote "${sid}")"
  tmp_sql=$(mktemp "${TMPDIR:-/tmp}/mk-event.XXXXXX.sql")
  SID="${q_sid}" SEQ="${seq}" EVENT_JSON="${event_json}" python3 - "${tmp_sql}" <<'PY'
import os, sys
sql_path = sys.argv[1]
ej = os.environ['EVENT_JSON'].replace("'", "''")
with open(sql_path, 'w', encoding='utf-8') as f:
    f.write("INSERT INTO transcript_events (session_id, seq, event_json, created_at) VALUES ('%s', %s, '%s', %s);\n" % (
        os.environ.get('SID', ''), os.environ.get('SEQ', '0'), ej, os.environ.get('SEQ', '0')))
PY
  "${_MK_SQLITE3_BIN}" "${db}" < "${tmp_sql}"
  rm -f "${tmp_sql}"
}

# ---------------------------------------------------------------------------
# mk_assistant_event <db> <session_id> <seq> <response_id> <run_id> <total_tokens> [model]
# Builds the record shape verbatim from tracer-turn-readback.txt.
# ---------------------------------------------------------------------------
mk_assistant_event() {
  local db="$1" sid="$2" seq="$3" response_id="$4" run_id="$5" total_tokens="$6" model="${7:-claude-sonnet-4-6}"
  local event_json
  event_json=$(
    RID="${response_id}" RUNID="${run_id}" TT="${total_tokens}" MODEL="${model}" SEQ="${seq}" python3 - <<'PY'
import json, os
seq = int(os.environ['SEQ'])
doc = {
    "type": "message",
    "id": f"msg-id-{seq}",
    "parentId": f"parent-id-{seq}",
    "timestamp": "2026-09-24T04:29:16.671Z",
    "message": {
        "role": "assistant",
        "content": [{"type": "text", "text": "ok"}],
        "api": "anthropic-messages",
        "provider": "anthropic",
        "model": os.environ['MODEL'],
        "usage": {
            "input": 74,
            "output": 9,
            "cacheRead": 0,
            "cacheWrite": 0,
            "totalTokens": int(os.environ['TT']),
        },
        "stopReason": "stop",
        "timestamp": 1790224153946,
        "responseId": os.environ['RID'],
        "responseModel": os.environ['MODEL'],
        "__openclaw": {"runId": os.environ['RUNID']},
    },
}
print(json.dumps(doc))
PY
  )
  mk_event "${db}" "${sid}" "${seq}" "${event_json}"
}

# ---------------------------------------------------------------------------
# mk_mirror_jsonl_dir <db> <sessions_dir> — TEST-GLUE HELPER (not part of the
# 19-01-PLAN.md artifact list). Rebuilds a fresh session store at <db>
# mirroring every "*.jsonl" file already on disk under <sessions_dir> — one
# non-cron session_nodes/session_windows row per file (session id = filename
# minus .jsonl), and one transcript_events row per line (seq = 0-based line
# index, event_json = the line verbatim).
#
# Exists so the pre-existing JSONL-fixture integration tests
# (test_report_jobs_argv.sh) do not need every individual `cat > ... <<JSONL`
# fixture rewritten line-by-line against mk_session/mk_event: since
# transcript_events.event_json preserves the byte-identical JSONL record
# shape (RESEARCH Pitfall 1), mirroring the already-written files is
# sufficient for report.sh's SQL-only discovery path to find and process
# them identically to before. Call this once per run_report() invocation —
# it is cheap and rebuilding the db does not disturb the ledger/offsets
# files that carry real cross-run state.
# ---------------------------------------------------------------------------
mk_mirror_jsonl_dir() {
  local db="$1" sessions_dir="$2"
  mk_store "${db}"
  [[ -d "${sessions_dir}" ]] || return 0
  local f sid seq line updated_at=100
  for f in "${sessions_dir}"/*.jsonl; do
    [[ -e "${f}" ]] || continue
    sid="$(basename "${f}" .jsonl)"
    updated_at=$((updated_at + 1))
    mk_session "${db}" "${sid}" "agent:main:${sid}" "" "${updated_at}"
    seq=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -z "${line}" ]] && continue
      # D-04/D-05 shape gap: these pre-2.0-schema fixtures identify a
      # completion by its top-level .id, and have no .message.responseId at
      # all — a field store_completions requires (it is the real 2.0 store's
      # completion-identity column). Synthesize responseId = the record's own
      # .id for any assistant/usage row missing it, so store_completions
      # finds the row using the SAME identity value these fixtures' own
      # assertions already hardcode (e.g. "TX:comp-B1-001"). Falls back to
      # the raw line unchanged on any parse error or non-assistant line.
      line=$(printf '%s' "${line}" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    rec = json.loads(raw)
    msg = rec.get("message") if isinstance(rec, dict) else None
    if (isinstance(msg, dict) and msg.get("role") == "assistant"
            and msg.get("usage") is not None and not msg.get("responseId")):
        msg["responseId"] = rec.get("id", "")
        print(json.dumps(rec))
    else:
        print(raw)
except Exception:
    print(raw)
')
      mk_event "${db}" "${sid}" "${seq}" "${line}"
      seq=$((seq + 1))
    done < "${f}"
  done
}
