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
# creates the state directory tree at source time as a side effect, violating
# the read-only contract above (surprising on a host where the skill is not
# yet installed). common.sh is left untouched so report.sh / guardrail-check.sh
# keep their existing behavior.
#
# D-10 (Phase 19 plan 19-06): session enumeration and completion counting are
# now delegated to scripts/session-store.sh, which is explicitly documented as
# safe for this file to source (unlike common.sh) — it never creates STATE_DIR
# as a side effect (plan 19-01), and its own header lists verify-markers.sh
# among its intended sourcing callers. MARKERS_DIR is still mirrored locally
# (session-store.sh has no opinion on marker files), matching this file's
# pre-existing no-source-common.sh convention.
#
# Completion-counting unit (D-04): a completion is one DISTINCT responseId,
# not one assistant-role row — a single multi-step turn can emit up to five
# assistant rows live (19-CONTEXT.md D-04), and this script is the project's
# ground-truth counter for marker coverage. Counting raw rows here while the
# metering tick counts distinct response ids would silently under-report the
# coverage gap against real multi-step turns — exactly the wrong direction for
# a diagnostic whose purpose is to surface that gap. store_completions already
# groups by responseId (min seq) for this reason; this script inherits that
# unit by construction rather than by a parallel reimplementation that could
# drift from it.
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=/dev/null
. "${SCRIPT_DIR}/session-store.sh"

# MARKERS_DIR mirrors common.sh's constant (STATE_DIR/markers) — mirrored
# locally rather than obtained by sourcing common.sh (WR-01). STATE_DIR itself
# comes from session-store.sh's own OPENCLAW_HOME-derived default, which
# mirrors common.sh's derivation exactly (see session-store.sh's own header).
MARKERS_DIR="${STATE_DIR}/markers"

# ---------------------------------------------------------------------------
# Enumerate non-cron sessions from the store (D-10) and count each one's
# completions in the metered unit (D-04), entirely in bash — no Python
# subprocess needed for this part, since store_list_sessions/store_completions
# are bash functions from the sourced library. Written to a temp file (never
# interpolated into the Python heredoc below) so the per-session report can
# still be produced from a single env-passed source, matching this project's
# env-passing-heredoc convention.
# ---------------------------------------------------------------------------
COMPLETIONS_TMP="$(mktemp "${TMPDIR:-/tmp}/verify-markers-completions.XXXXXX")"
trap 'rm -f "${COMPLETIONS_TMP}"' EXIT

declare -a _vm_sids=()
while IFS=$'\x1f' read -r _vm_sid _vm_skey _vm_created_via _vm_updated_at; do
  [[ -z "${_vm_sid}" ]] && continue
  _vm_sids+=("${_vm_sid}")
done < <(store_list_sessions)

if [[ "${#_vm_sids[@]}" -gt 0 ]]; then
  for _vm_sid in "${_vm_sids[@]}"; do
    printf '%s\n' "${_vm_sid}"
  done | LC_ALL=C sort -u > "${COMPLETIONS_TMP}.sids"

  while IFS= read -r _vm_sid; do
    [[ -z "${_vm_sid}" ]] && continue
    _vm_count=$(store_completions "${_vm_sid}" | grep -c . || true)
    printf '%s\t%s\n' "${_vm_sid}" "${_vm_count:-0}" >> "${COMPLETIONS_TMP}"
  done < "${COMPLETIONS_TMP}.sids"
  rm -f "${COMPLETIONS_TMP}.sids"
fi

# Pass path constants via env — never interpolate bash variables inside <<'PY'
COMPLETIONS_FILE="${COMPLETIONS_TMP}" \
MARKERS_DIR="${MARKERS_DIR}" \
python3 - <<'PY'
import json, os, sys

completions_file = os.environ['COMPLETIONS_FILE']
markers_dir      = os.environ['MARKERS_DIR']

# ---------------------------------------------------------------------------
# Read the bash-computed per-session completion counts (D-10/D-04). Each line
# is "<sid>\t<completions>", already restricted to non-cron sessions and
# already counted in the metered distinct-responseId unit by store_completions.
# ---------------------------------------------------------------------------
session_completions = []
try:
    with open(completions_file, encoding='utf-8') as fh:
        for line in fh:
            line = line.rstrip('\n')
            if not line:
                continue
            parts = line.split('\t')
            if len(parts) != 2:
                continue
            sid, count_str = parts
            try:
                count = int(count_str)
            except ValueError:
                count = 0
            session_completions.append((sid, count))
except OSError:
    pass  # fail-open: no completions file (e.g. store unreadable) -> empty report

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

# Sort sessions for deterministic output (mirrors the old sorted(non_cron)).
session_completions_sorted = sorted(session_completions, key=lambda t: t[0])

print(f"{'session_id':<44} {'completions':>11} {'markers':>7} {'gap':>5} {'coverage%':>9}")
print("-" * 80)

for sid, completions in session_completions_sorted:
    marker_path = os.path.join(markers_dir, f"{sid}.jsonl")

    markers = count_task_markers(marker_path)
    gap     = completions - markers
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
