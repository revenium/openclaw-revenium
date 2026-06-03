#!/usr/bin/env bash
# =============================================================================
# write-marker.sh — Validate task_type and append an ISO8601 marker entry.
#
# Called by SKILL.md TASK CLASSIFICATION section. Validates <task_type> against
# the taxonomy allowlist, resolves the current session id (newest non-cron
# session file), and appends {"ts":"<ISO8601Z>","task_type":"<label>","completion_id":"<id>"}
# under fcntl.LOCK_EX + O_APPEND. completion_id is the .id of the most recent
# assistant completion in the session; omitted if not resolvable (so report.sh
# falls back to Approach D timestamp correlation).
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

if [[ $# -lt 1 || -z "${1:-}" ]]; then
  warn "write-marker.sh: usage: write-marker.sh <task_type>"
  exit 1
fi

TASK_TYPE_ARG="$1"

# Truncate to 64 chars for log-injection mitigation (03-PATTERNS T-04-08)
TASK_TYPE_LOG="${TASK_TYPE_ARG:0:64}"

info "write-marker: writing marker for task_type='${TASK_TYPE_LOG}'"

TASK_TYPE="${TASK_TYPE_ARG}" \
TAXONOMY_FILE="${TAXONOMY_FILE}" \
MARKERS_DIR="${MARKERS_DIR}" \
SESSIONS_DIR="${SESSIONS_DIR}" \
OPENCLAW_HOME="${OPENCLAW_HOME}" \
python3 - <<'PY'
import json, os, time, fcntl, re, sys

# --- Read inputs from environment (env-passing heredoc; never interpolate) ---
tt          = os.environ['TASK_TYPE']
tax_file    = os.environ['TAXONOMY_FILE']
markers_dir = os.environ['MARKERS_DIR']
sessions_dir = os.environ['SESSIONS_DIR']
openclaw_home = os.environ.get('OPENCLAW_HOME', '')

# --- Taxonomy allowlist validation (ASVS V5 / T-04-04) ---
try:
    with open(tax_file, encoding='utf-8') as fh:
        taxonomy = json.load(fh)
    labels = set(taxonomy.get('labels', {}) if isinstance(taxonomy.get('labels'), dict) else taxonomy.get('labels', []))
except Exception as exc:
    raise SystemExit(f"write-marker: cannot load taxonomy: {exc}")

if tt not in labels:
    raise SystemExit(f"unknown task_type: {tt}")

# --- Resolve current session id: newest non-cron *.jsonl in SESSIONS_DIR ---
# Pitfall 5: exclude cron sessions (keyed agent:main:cron:* in sessions.json)
cron_sids = set()
sessions_json = os.path.join(sessions_dir, 'sessions.json')
if os.path.exists(sessions_json):
    try:
        with open(sessions_json, encoding='utf-8') as fh:
            smap = json.load(fh)
        if isinstance(smap, dict):
            for key, val in smap.items():
                if key.startswith('agent:main:cron:'):
                    # val may be the sid string or a dict with a sid field
                    if isinstance(val, str):
                        cron_sids.add(val.split('/')[-1] if '/' in val else val)
                    elif isinstance(val, dict):
                        sid_val = val.get('id') or val.get('sessionId') or ''
                        if sid_val:
                            cron_sids.add(sid_val)
    except Exception:
        pass  # fail-open: if sessions.json unreadable, don't exclude anything

# List all *.jsonl files in sessions_dir, excluding cron sessions
try:
    all_files = [f for f in os.listdir(sessions_dir) if f.endswith('.jsonl')]
except OSError:
    all_files = []

# Remove cron-session files
non_cron = [f for f in all_files if f[:-len('.jsonl')] not in cron_sids]


# WR-03: raw mtime is a fragile signal — any concurrent/subagent session that
# touched its JSONL more recently steals attribution, and report.sh correlates
# markers strictly within the same session id, so a misfiled marker is silently
# lost to `unclassified`. Prefer the non-cron session that most recently
# appended an assistant *completion* (the conversation this marker describes);
# fall back to non-cron mtime. Never fall back to cron sessions.
#
# Also capture the .id of the most recent assistant completion so report.sh can
# correlate by exact id match (Approach A) before falling back to timestamp
# ordering (Approach D). The id is the top-level .id field on the JSONL record,
# NOT the nested message id.
def last_completion_info(fname):
    """Return (ts, completion_id) of the last assistant-message line, or (None, None).
    Reads only the tail to stay cheap on large session logs."""
    path = os.path.join(sessions_dir, fname)
    try:
        with open(path, 'rb') as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            # Read up to the last 64 KiB; enough for the final few lines.
            window = min(size, 65536)
            fh.seek(size - window)
            chunk = fh.read().decode('utf-8', 'replace')
    except OSError:
        return None, None
    best_ts = None
    best_id = None
    for line in chunk.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        if not isinstance(rec, dict):
            continue
        msg = rec.get('message')
        if rec.get('type') == 'message' and isinstance(msg, dict) and msg.get('role') == 'assistant':
            ts = rec.get('timestamp') or ''
            if ts and (best_ts is None or ts > best_ts):
                best_ts = ts
                # .id at the top-level record is the stable completion identifier
                best_id = rec.get('id') or None
    return best_ts, best_id

# Keep backward-compatible helper for session selection (uses ts only)
def last_completion_ts(fname):
    ts, _ = last_completion_info(fname)
    return ts

sid = None
completion_id = None
if non_cron:
    # First choice: session with the most recent assistant completion.
    annotated = [(f, last_completion_info(f)) for f in non_cron]
    with_completion = [(f, ts, cid) for f, (ts, cid) in annotated if ts is not None]
    if with_completion:
        newest_entry = max(with_completion, key=lambda t: t[1])
        newest = newest_entry[0]
        completion_id = newest_entry[2]  # may be None if .id absent on that record
    else:
        # No completions yet in any non-cron session — fall back to mtime,
        # still restricted to non-cron files.
        newest = max(non_cron, key=lambda f: os.path.getmtime(os.path.join(sessions_dir, f)))
        completion_id = None
    sid = newest[:-len('.jsonl')]
else:
    # No non-cron session files at all — use a pseudo sid. We deliberately do
    # NOT fall back to cron sessions: filing a marker under a cron session id
    # guarantees it is never correlated to a real user turn.
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
