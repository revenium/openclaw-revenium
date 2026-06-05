#!/usr/bin/env bash
# =============================================================================
# verify-markers.sh — Per-session completions-vs-markers diagnostic.
#
# Reports for each non-cron session: completion count, marker count, gap, and
# coverage %, then prints a summary line. Used to measure the classification
# gap before / after the before_agent_finalize plugin lands (SC-4).
#
# Usage:
#   bash ~/.openclaw/skills/revenium/scripts/verify-markers.sh
#
# Output (stdout only — interactive diagnostic, NOT a cron stage):
#   session_id | completions | markers | gap | coverage%
#   ...
#   TOTAL: <completions> completions, <markers> markers, <gap> gap, <pct>% coverage
#
# Read-only: writes no files, does not tee, does not invoke guardrail or
# config writers (SC-5 / D-07 preservation).
#
# NOTE (WR-01): this script deliberately does NOT source common.sh. Sourcing it
# runs `mkdir -p "${STATE_DIR}"` at source time, which would materialize the
# skill state dir tree as a side effect — violating the read-only contract above
# (surprising on a host where the skill is not yet installed). We instead derive
# the two path constants we need (SESSIONS_DIR, MARKERS_DIR) inline, mirroring
# common.sh's OPENCLAW_HOME discovery and constant definitions exactly, with no
# directory creation. common.sh is left untouched so report.sh / guardrail-check.sh
# keep their existing behavior.
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# OPENCLAW_HOME discovery — mirrors common.sh (multi-candidate probe).
# ---------------------------------------------------------------------------
if [[ -z "${OPENCLAW_HOME:-}" ]]; then
  _oc_home=""
  for _candidate in "${HOME}/.openclaw" "/home/ubuntu/.openclaw"; do
    if [[ -d "${_candidate}/agents" ]]; then
      _oc_home="${_candidate}"
      break
    fi
  done
  OPENCLAW_HOME="${_oc_home:-${HOME}/.openclaw}"
  unset _oc_home _candidate
fi

# ---------------------------------------------------------------------------
# Path constants needed by this diagnostic — mirror common.sh exactly.
# STATE_DIR is the collapsed skill dir; MARKERS_DIR / SESSIONS_DIR are read-only
# inputs here. NO mkdir — read-only (WR-01 / SC-5).
# ---------------------------------------------------------------------------
STATE_DIR="${OPENCLAW_HOME}/skills/revenium"
MARKERS_DIR="${STATE_DIR}/markers"
SESSIONS_DIR="${OPENCLAW_HOME}/agents/main/sessions"

# Pass path constants via env — never interpolate bash variables inside <<'PY'
SESSIONS_DIR="${SESSIONS_DIR}" \
MARKERS_DIR="${MARKERS_DIR}" \
python3 - <<'PY'
import json, os, sys

sessions_dir = os.environ['SESSIONS_DIR']
markers_dir  = os.environ['MARKERS_DIR']

# ---------------------------------------------------------------------------
# Build cron-session exclusion set (mirrors write-marker.sh logic exactly)
# Keys starting agent:main:cron: in sessions.json are cron sessions.
# ---------------------------------------------------------------------------
cron_sids = set()
sessions_json = os.path.join(sessions_dir, 'sessions.json')
if os.path.exists(sessions_json):
    try:
        with open(sessions_json, encoding='utf-8') as fh:
            smap = json.load(fh)
        if isinstance(smap, dict):
            for key, val in smap.items():
                if key.startswith('agent:main:cron:'):
                    if isinstance(val, str):
                        cron_sids.add(val.split('/')[-1] if '/' in val else val)
                    elif isinstance(val, dict):
                        sid_val = val.get('id') or val.get('sessionId') or ''
                        if sid_val:
                            cron_sids.add(sid_val)
    except Exception:
        pass  # fail-open: unreadable sessions.json → no cron exclusions

# ---------------------------------------------------------------------------
# Gather non-cron session files
# ---------------------------------------------------------------------------
try:
    all_files = [f for f in os.listdir(sessions_dir) if f.endswith('.jsonl')]
except OSError:
    all_files = []

non_cron = [f for f in all_files if f[:-len('.jsonl')] not in cron_sids]

# ---------------------------------------------------------------------------
# count_completions: count assistant-message records in a session JSONL.
# Each record with type=="message" and message.role=="assistant" is one
# completion. Fail-open on malformed lines (matches write-marker.sh discipline).
# ---------------------------------------------------------------------------
def count_completions(session_path):
    count = 0
    try:
        with open(session_path, encoding='utf-8') as fh:
            for line in fh:
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
                if (rec.get('type') == 'message'
                        and isinstance(msg, dict)
                        and msg.get('role') == 'assistant'):
                    count += 1
    except OSError:
        pass
    return count

# ---------------------------------------------------------------------------
# count_task_markers: count TASK marker records in a marker JSONL.
# A task marker has 'task_type' and kind != 'job' (job markers are excluded
# per D-03 — they're write-job-marker.sh records, not task classifications).
# Fail-open on malformed lines.
# ---------------------------------------------------------------------------
def count_task_markers(marker_path):
    count = 0
    try:
        with open(marker_path, encoding='utf-8') as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except Exception:
                    continue
                if isinstance(rec, dict) and 'task_type' in rec and rec.get('kind') != 'job':
                    count += 1
    except OSError:
        pass
    return count

# ---------------------------------------------------------------------------
# Per-session report
# ---------------------------------------------------------------------------
total_completions = 0
total_markers = 0

# Sort sessions for deterministic output
non_cron_sorted = sorted(non_cron)

print(f"{'session_id':<44} {'completions':>11} {'markers':>7} {'gap':>5} {'coverage%':>9}")
print("-" * 80)

for fname in non_cron_sorted:
    sid = fname[:-len('.jsonl')]
    session_path = os.path.join(sessions_dir, fname)
    marker_path  = os.path.join(markers_dir, f"{sid}.jsonl")

    completions = count_completions(session_path)
    markers     = count_task_markers(marker_path)
    gap         = completions - markers
    if completions > 0:
        pct = round(markers / completions * 100)
    else:
        pct = 0

    total_completions += completions
    total_markers     += markers

    print(f"{sid:<44} {completions:>11} {markers:>7} {gap:>5} {pct:>8}%")

# ---------------------------------------------------------------------------
# Summary line
# ---------------------------------------------------------------------------
total_gap = total_completions - total_markers
if total_completions > 0:
    total_pct = round(total_markers / total_completions * 100)
else:
    total_pct = 0

print("-" * 80)
print(f"TOTAL: {total_completions} completions, {total_markers} markers, {total_gap} gap, {total_pct}% coverage")
PY
