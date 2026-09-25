#!/usr/bin/env bash
# =============================================================================
# write-job-marker.sh — Validate job fields and append a kind:"job" marker.
#
# New dedicated writer (D-06 — does NOT extend write-marker.sh). Called by
# SKILL.md JOB DECLARATION section at arc boundaries. Validates job_type
# against the job taxonomy allowlist, sanitizes all user fields, resolves the
# current session id via scripts/session-store.sh's SQLite-backed
# store_current_session_id (D-10), and appends a job marker under
# fcntl.LOCK_EX + O_APPEND.
#
# Usage (lifecycle — declare at arc START, close at arc END):
#   # arc start: opens the job (Revenium shows it running; spend stamps to it)
#   bash ~/.openclaw/skills/revenium/scripts/write-job-marker.sh \
#     --job-id "add-pagination-endpoint-3b1e" \
#     --job-name "Add pagination to /api/users endpoint" \
#     --job-type "feature_development" \
#     --status "RUNNING"
#
#   # arc end: closes the open job recorded for this session (id remembered
#   # via the per-session current-job state file; --job-id overrides)
#   bash ~/.openclaw/skills/revenium/scripts/write-job-marker.sh \
#     --close --status "SUCCESS"
#
# Usage (one-shot terminal form — fully supported, used when no RUNNING
# marker was declared; this is the original v1.1 contract and what older
# installed directives produce):
#   bash ~/.openclaw/skills/revenium/scripts/write-job-marker.sh \
#     --job-id "add-pagination-endpoint-3b1e" \
#     --job-name "Add pagination to /api/users endpoint" \
#     --job-type "feature_development" \
#     --status "SUCCESS"
#
#   Optional for FAILED status:
#     --failure-reason "brief plain-text cause"
#
# Exit codes:
#   0  — marker written (prints "job marker written: <path>" to stdout)
#   1  — unknown job_type, invalid status, missing mandatory flag, or --close
#        with no open job recorded; no marker written
#
# Security: ASVS V4 (markers/ mode 0700), ASVS V5 (allowlist + sid guard),
#           env-passing heredoc (T-05-03), fcntl.LOCK_EX (T-05-06),
#           sanitize() strips :, |, newline before allowlist (D-09, Pitfall 2).
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/common.sh"
. "${SCRIPT_DIR}/session-store.sh"

# ---------------------------------------------------------------------------
# Named-flag argument parser (D-07 — named flags, not positional)
# ---------------------------------------------------------------------------
JOB_ID_ARG=""
JOB_NAME_ARG=""
JOB_TYPE_ARG=""
STATUS_ARG=""
FAILURE_REASON_ARG=""
CLOSE_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job-id)         JOB_ID_ARG="$2";         shift 2 ;;
    --job-name)       JOB_NAME_ARG="$2";       shift 2 ;;
    --job-type)       JOB_TYPE_ARG="$2";       shift 2 ;;
    --status)         STATUS_ARG="$2";         shift 2 ;;
    --failure-reason) FAILURE_REASON_ARG="$2"; shift 2 ;;
    --close)          CLOSE_ARG="1";           shift ;;
    *) warn "write-job-marker.sh: unknown argument: $1"; exit 1 ;;
  esac
done

# Mandatory-flag bash-level presence check (before Python).
# --close needs only --status: id/name/type come from the per-session
# current-job state file written by the RUNNING declaration (or --job-id wins).
if [[ "${CLOSE_ARG}" == "1" ]]; then
  if [[ -z "${STATUS_ARG}" ]]; then
    warn "write-job-marker.sh: --close requires --status SUCCESS|FAILED|CANCELLED"
    exit 1
  fi
else
  if [[ -z "${JOB_ID_ARG}" || -z "${JOB_NAME_ARG}" || -z "${JOB_TYPE_ARG}" || -z "${STATUS_ARG}" ]]; then
    warn "write-job-marker.sh: missing required flag(s): --job-id, --job-name, --job-type, --status"
    exit 1
  fi
fi

# Log-injection mitigation: truncate to 64 chars (mirrors TASK_TYPE_LOG pattern, T-05-07)
JOB_TYPE_LOG="${JOB_TYPE_ARG:0:64}"
info "write-job-marker: writing job marker for job_type='${JOB_TYPE_LOG:-<from current-job state>}'"

# --- D-10: resolve the current session id (and its last completion id) from
# the SQLite store, in the enclosing bash — never inside the Python heredoc,
# which cannot source bash. Both store_* functions already fail open (they
# emit an empty string and return 0 on any unresolvable case), so a plain
# command substitution is the project's fail-open idiom here.
#
# [Rule 1 deviation, 19-06] Job markers ARE correlated by completion, just
# like task-type markers: report.sh's job_resolve Phase A does an exact
# completion_id match against the jobs cache before falling back to
# timestamp ordering (see report.sh's own "Phase A: exact completion_id
# match" comment on the job-cache scan, and the CR-01 note a few lines below
# this block — "without this the correlation silently degrades to
# timestamp-only"). Dropping completion_id resolution here (as a literal
# reading of this task's original action text would do) would silently
# regress every terminal job marker to timestamp-only correlation. Both
# values are therefore resolved exactly as write-marker.sh (Task 1) does.
RESOLVED_SESSION_ID=$(store_current_session_id 2>/dev/null || true)
RESOLVED_COMPLETION_ID=""
if [[ -n "${RESOLVED_SESSION_ID}" ]]; then
  RESOLVED_COMPLETION_ID=$(store_last_completion_id "${RESOLVED_SESSION_ID}" 2>/dev/null || true)
else
  # WR-03 (19-10): qualify the empty answer against store_probe — silent on
  # a fresh/legitimately-empty host, one bounded log line when the store is
  # actually UNREADABLE. Same shape as write-marker.sh's Task 1 call site.
  store_warn_if_unreadable "write-job-marker" || true
fi

JOB_ID="${JOB_ID_ARG}" \
JOB_NAME="${JOB_NAME_ARG}" \
JOB_TYPE="${JOB_TYPE_ARG}" \
STATUS="${STATUS_ARG}" \
FAILURE_REASON="${FAILURE_REASON_ARG}" \
CLOSE="${CLOSE_ARG}" \
JOB_TAXONOMY_FILE="${JOB_TAXONOMY_FILE}" \
MARKERS_DIR="${MARKERS_DIR}" \
SESSIONS_DIR="${SESSIONS_DIR}" \
OPENCLAW_HOME="${OPENCLAW_HOME}" \
RESOLVED_SESSION_ID="${RESOLVED_SESSION_ID}" \
RESOLVED_COMPLETION_ID="${RESOLVED_COMPLETION_ID}" \
python3 - <<'PY'
import json, os, time, fcntl, re, sys

# --- Read inputs from environment (env-passing heredoc; never interpolate) ---
job_id_raw        = os.environ['JOB_ID']
job_name_raw      = os.environ['JOB_NAME']
job_type_raw      = os.environ['JOB_TYPE']
status_raw        = os.environ['STATUS']
failure_reason_raw = os.environ.get('FAILURE_REASON', '')
close_mode        = os.environ.get('CLOSE', '') == '1'
tax_file          = os.environ['JOB_TAXONOMY_FILE']
markers_dir       = os.environ['MARKERS_DIR']
sessions_dir      = os.environ['SESSIONS_DIR']
openclaw_home     = os.environ.get('OPENCLAW_HOME', '')
resolved_session_id = os.environ.get('RESOLVED_SESSION_ID', '')
resolved_completion_id = os.environ.get('RESOLVED_COMPLETION_ID', '')

# --- Sanitize all user fields BEFORE allowlist checks (D-09, Pitfall 2) ---
def sanitize(value, maxlen=256):
    """Replace :, |, newline, carriage-return with _ and cap length."""
    return re.sub(r'[:\|\n\r]', '_', str(value))[:maxlen]

job_id         = sanitize(job_id_raw)
job_name       = sanitize(job_name_raw)
job_type       = sanitize(job_type_raw)   # validated against allowlist below
status         = sanitize(status_raw)     # validated against allowlist below
failure_reason = sanitize(failure_reason_raw)

# NOTE: taxonomy + status allowlist validation moved BELOW sid resolution —
# --close fills job_id/name/type from the per-session current-job state file,
# which is keyed by sid, so the fields aren't final until the sid is known.

# --- Resolve current session id (D-10) ---
# The bash-side scripts/session-store.sh :: store_current_session_id already
# picked the newest non-cron session across the SQLite store (ORDER BY
# session_nodes.updated_at DESC, tie-broken by session_key). This supersedes
# the old "newest non-cron *.jsonl in SESSIONS_DIR" heuristic (WR-03): the
# store's updated_at is maintained on every append, a strictly better signal
# than file mtime, and created_via is a schema-enforced enum rather than a
# key-prefix guess parsed out of sessions.json. Both resolved values crossed
# from bash into this heredoc through the environment (never interpolated
# into the heredoc body). Job markers ARE correlated by completion (see the
# [Rule 1 deviation, 19-06] note above the bash-side resolution block), so
# both the session id and its last completion's responseId (D-05) are
# resolved here, exactly as write-marker.sh does.
if resolved_session_id:
    sid = resolved_session_id
    completion_id = resolved_completion_id or None
else:
    # No non-cron session found anywhere in the store — use a pseudo sid. We
    # deliberately do NOT fall back to cron sessions: filing a marker under a
    # cron session id guarantees it is never correlated to a real user turn.
    sid = f"pseudo-{int(time.time())}"
    completion_id = None

# --- Path-traversal guard (ASVS V5 / T-05-05) ---
if not re.fullmatch(r'[0-9a-fA-F-]+|pseudo-[0-9]+', sid):
    raise SystemExit(f"unsafe sid: {sid!r}")

# --- Create markers dir mode 0700 (ASVS V4 / T-05-06) ---
os.makedirs(markers_dir, mode=0o700, exist_ok=True)

# --- Current-job state file (lifecycle) ---
# A RUNNING declaration records {id, name, type} per session so the arc-end
# `--close --status <terminal>` doesn't need the agent to remember the id.
# Explicit --job-id always wins over the state file.
state_path = os.path.join(markers_dir, f"{sid}.current-job.json")
if close_mode and not job_id:
    try:
        with open(state_path, encoding='utf-8') as fh:
            state = json.load(fh)
        job_id   = sanitize(state.get('agentic_job_id', ''))
        if not job_name:
            job_name = sanitize(state.get('job_name', ''))
        if not job_type:
            job_type = sanitize(state.get('job_type', ''))
    except Exception:
        pass
    if not job_id:
        raise SystemExit(
            "write-job-marker: --close but no open job recorded for this session — "
            "pass --job-id (and --job-name/--job-type) explicitly")

# --- Job taxonomy allowlist validation (ASVS V5 / T-05-08, D-14) ---
try:
    with open(tax_file, encoding='utf-8') as fh:
        taxonomy = json.load(fh)
    labels = set(taxonomy.get('labels', {}) if isinstance(taxonomy.get('labels'), dict) else taxonomy.get('labels', []))
except Exception as exc:
    raise SystemExit(f"write-job-marker: cannot load job taxonomy: {exc}")

if job_type not in labels:
    raise SystemExit(f"write-job-marker: unknown job_type: {job_type!r}")

# --- Status allowlist validation (D-14) ---
# RUNNING opens an arc (lifecycle); SUCCESS/FAILED/CANCELLED are terminal.
VALID_STATUSES = {'RUNNING', 'SUCCESS', 'FAILED', 'CANCELLED'}
if status not in VALID_STATUSES:
    raise SystemExit(f"write-job-marker: invalid status: {status!r} (must be RUNNING, SUCCESS, FAILED, or CANCELLED)")
if close_mode and status == 'RUNNING':
    raise SystemExit("write-job-marker: --close requires a terminal status (SUCCESS, FAILED, or CANCELLED)")

# --- Build the job marker record (D-11, D-12) ---
# 7 mandatory fields: kind, ts, sid, agentic_job_id, job_name, job_type, status
marker_path = os.path.join(markers_dir, f"{sid}.jsonl")
rec = {
    "kind":            "job",
    "ts":              time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    "sid":             sid,
    "agentic_job_id":  job_id,
    "job_name":        job_name,
    "job_type":        job_type,
    "status":          status,
}
# Optional field: only present for FAILED with a non-empty reason (D-13, Pitfall 3)
if status == "FAILED" and failure_reason:
    rec["failure_reason"] = failure_reason

# completion_id: id of the most recent assistant completion (Approach A key).
# report.sh correlates job markers to completions by exact id; without this the
# correlation silently degrades to timestamp-only (CR-01). Mirrors write-marker.sh.
# RUNNING markers deliberately OMIT it: at arc start the most recent completion
# belongs to the PREVIOUS turn; the open marker stamps completions by interval
# (report.sh Phase C), not by id.
if completion_id and status != "RUNNING":
    rec["completion_id"] = completion_id

# --- Maintain the current-job state file ---
if status == "RUNNING":
    tmp_state = state_path + ".tmp"
    with open(tmp_state, 'w', encoding='utf-8') as fh:
        json.dump({"agentic_job_id": job_id, "job_name": job_name, "job_type": job_type}, fh)
    os.chmod(tmp_state, 0o600)
    os.replace(tmp_state, state_path)
else:
    # Terminal marker closes the arc — clear the state when it matches.
    try:
        with open(state_path, encoding='utf-8') as fh:
            if json.load(fh).get('agentic_job_id') == job_id:
                os.unlink(state_path)
    except Exception:
        pass

# --- Append under fcntl.LOCK_EX + O_APPEND (T-05-06) ---
# Use json.dumps with compact separators so no raw field bytes hit the file
# unescaped; O_APPEND is atomic at the OS level, flock prevents interleaving
# from concurrent write-job-marker.sh invocations.
with open(marker_path, 'ab', buffering=0) as fh:
    fcntl.flock(fh, fcntl.LOCK_EX)
    fh.write((json.dumps(rec, separators=(',', ':')) + '\n').encode('utf-8'))

print(f"job marker written: {marker_path}")
sys.exit(0)
PY
