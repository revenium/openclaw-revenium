#!/usr/bin/env bash
# =============================================================================
# write-marker.sh — Validate task_type and append an ISO8601 marker entry.
#
# Called by SKILL.md TASK CLASSIFICATION section. Validates <task_type> against
# the taxonomy allowlist, resolves the current session id via
# scripts/session-store.sh's SQLite-backed store_current_session_id (D-10), and
# appends {"ts":"<ISO8601Z>","task_type":"<label>","completion_id":"<id>"}
# under fcntl.LOCK_EX + O_APPEND. completion_id is the responseId (D-05) of the
# most recent usage-bearing assistant completion in the session, resolved via
# store_last_completion_id; omitted if not resolvable (so report.sh falls back
# to Approach D timestamp correlation).
#
# Usage:
#   bash ~/.openclaw/skills/revenium/scripts/write-marker.sh <task_type>
#
# Exit codes:
#   0  — marker written (prints "marker written: <path>" to stdout)
#   1  — unknown task_type (not in taxonomy allowlist); no marker written
#
# Security: ASVS V4 (markers/ mode 0700), ASVS V5 (allowlist + sid guard),
#           env-passing heredoc (T-04-09), fcntl.LOCK_EX (T-04-07).
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"
. "${SCRIPT_DIR}/session-store.sh"

if [[ $# -lt 1 || -z "${1:-}" ]]; then
  warn "write-marker.sh: usage: write-marker.sh <task_type>"
  exit 1
fi

TASK_TYPE_ARG="$1"

# Truncate to 64 chars for log-injection mitigation (03-PATTERNS T-04-08)
TASK_TYPE_LOG="${TASK_TYPE_ARG:0:64}"

info "write-marker: writing marker for task_type='${TASK_TYPE_LOG}'"

# --- D-10: resolve the current session id (and its last completion id) from
# the SQLite store, in the enclosing bash — never inside the Python heredoc,
# which cannot source bash. Both store_* functions already fail open (they
# emit an empty string and return 0 on any unresolvable case), so a plain
# command substitution is the project's fail-open idiom here: on failure the
# variable is simply empty, never aborting this script.
#
# WR-03: an empty RESOLVED_SESSION_ID is ambiguous on its own — it means
# either "the store legitimately has no non-cron session yet" (a fresh host)
# or "the store could not be read at all" (permission denied, corrupt file,
# locked past busy_timeout). Both degrade to the same pseudo-<epoch> fallback
# below with no visible difference. Qualifying the empty answer against
# store_probe — ONLY on this empty-answer path, so the happy path costs
# nothing — distinguishes the two and gives an operator debugging repeated
# pseudo-id attribution a log line pointing at the real cause. This must
# never abort: store_warn_if_unreadable always returns 0.
RESOLVED_SESSION_ID=$(store_current_session_id 2>/dev/null || true)
RESOLVED_COMPLETION_ID=""
if [[ -n "${RESOLVED_SESSION_ID}" ]]; then
  RESOLVED_COMPLETION_ID=$(store_last_completion_id "${RESOLVED_SESSION_ID}" 2>/dev/null || true)
else
  store_warn_if_unreadable "write-marker" || true
fi

TASK_TYPE="${TASK_TYPE_ARG}" \
TAXONOMY_FILE="${TAXONOMY_FILE}" \
MARKERS_DIR="${MARKERS_DIR}" \
SESSIONS_DIR="${SESSIONS_DIR}" \
OPENCLAW_HOME="${OPENCLAW_HOME}" \
RESOLVED_SESSION_ID="${RESOLVED_SESSION_ID}" \
RESOLVED_COMPLETION_ID="${RESOLVED_COMPLETION_ID}" \
python3 - <<'PY'
import json, os, time, fcntl, re, sys

# --- Read inputs from environment (env-passing heredoc; never interpolate) ---
tt          = os.environ['TASK_TYPE']
tax_file    = os.environ['TAXONOMY_FILE']
markers_dir = os.environ['MARKERS_DIR']
sessions_dir = os.environ['SESSIONS_DIR']
openclaw_home = os.environ.get('OPENCLAW_HOME', '')
resolved_session_id = os.environ.get('RESOLVED_SESSION_ID', '')
resolved_completion_id = os.environ.get('RESOLVED_COMPLETION_ID', '')

# --- Taxonomy allowlist validation (ASVS V5 / T-04-04) ---
try:
    with open(tax_file, encoding='utf-8') as fh:
        taxonomy = json.load(fh)
    labels = set(taxonomy.get('labels', {}) if isinstance(taxonomy.get('labels'), dict) else taxonomy.get('labels', []))
except Exception as exc:
    raise SystemExit(f"write-marker: cannot load taxonomy: {exc}")

if tt not in labels:
    raise SystemExit(f"unknown task_type: {tt}")

# --- Resolve current session id (D-10) ---
# The bash-side scripts/session-store.sh :: store_current_session_id already
# picked the newest non-cron session across the SQLite store (ORDER BY
# session_nodes.updated_at DESC, tie-broken by session_key). This supersedes
# the old "newest non-cron *.jsonl in SESSIONS_DIR" heuristic: session_nodes
# maintains updated_at on every append, a strictly better signal than file
# mtime, which a concurrent/subagent session could steal (WR-03) — and
# created_via is a schema-enforced enum rather than a key-prefix guess parsed
# out of sessions.json. The resolved value crossed from bash into this
# heredoc through the environment (never interpolated into the heredoc body).
#
# Identifier change (D-05): the marker's completion identifier used to be the
# transcript record's top-level .id; it is now the responseId, resolved via
# store_last_completion_id, because report.sh's Phase A exact-match
# correlation compares the marker's value against the transaction id, which
# IS the responseId. If these two values ever drift apart, nothing errors —
# the correlation silently falls through to the Phase D timestamp path and
# produces plausible but wrong labels.
if resolved_session_id:
    sid = resolved_session_id
    completion_id = resolved_completion_id or None
else:
    # No non-cron session found anywhere in the store — use a pseudo sid. We
    # deliberately do NOT fall back to cron sessions: filing a marker under a
    # cron session id guarantees it is never correlated to a real user turn.
    sid = f"pseudo-{int(time.time())}"
    completion_id = None

# --- Path-traversal guard (ASVS V5 / T-04-06) ---
if not re.fullmatch(r'[0-9a-fA-F-]+|pseudo-[0-9]+', sid):
    raise SystemExit(f"unsafe sid: {sid!r}")

# --- Create markers dir mode 0700 (ASVS V4 / T-04-07) ---
os.makedirs(markers_dir, mode=0o700, exist_ok=True)

# --- Build the marker record with ISO8601 ts (Pitfall 2 / NP-1) ---
# completion_id: id of the most recent assistant completion (Approach A key).
# Omit the field entirely when not resolvable so report.sh can detect its
# absence and apply the Approach D fallback without inspecting an empty string.
marker_path = os.path.join(markers_dir, f"{sid}.jsonl")
rec = {
    "ts": time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    "task_type": tt
}
if completion_id:
    rec["completion_id"] = completion_id

# --- Append under fcntl.LOCK_EX + O_APPEND (T-04-07) ---
# Use json.dumps with compact separators so no raw label bytes hit the file
# unescaped (T-04-04); O_APPEND is atomic at the OS level, flock prevents
# interleaving from concurrent write-marker.sh invocations.
with open(marker_path, 'ab', buffering=0) as fh:
    fcntl.flock(fh, fcntl.LOCK_EX)
    fh.write((json.dumps(rec, separators=(',', ':')) + '\n').encode('utf-8'))

print(f"marker written: {marker_path}")
sys.exit(0)
PY
