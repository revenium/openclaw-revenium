---
status: resolved
slug: task-type-always-unclassified
trigger: "Phase 4 task-type metering is always unclassified in Revenium despite valid markers being written"
created: 2026-06-03T00:00:00Z
updated: 2026-06-03T14:46:00Z
phase: 04-task-metering-attribution
---

# Debug Session: task-type always "unclassified"

## Symptoms

- **Expected:** `revenium meter completion` calls carry `--task-type <label>` matching the task marker written for that turn; the completion appears in Revenium with the correct `taskType` (e.g. `generation`).
- **Actual:** Every metered completion shows `taskType: unclassified` in Revenium, even when a valid marker with a real label exists.
- **Errors:** None — the pipeline runs cleanly (cron fires every minute, "Done. Processed 2 session file(s)." logged). The failure is silent: the default `unclassified` is always used.
- **Timeline:** Phase 4 (task-metering-attribution) shipped this turn. Never observed working in production.
- **Reproduction:** Run an OpenClaw session that writes a marker; wait for cron tick; query `revenium metrics completions` — taskType is `unclassified`.

## Root Cause (ESTABLISHED via live debugging — verify, do not re-derive from scratch)

`scripts/report.sh` correlates a completion to a task marker using the NP-1 **timestamp-precedence** rule: "pick the latest marker where `marker_ts <= completion_ts`" (strictly *before* the completion). The marker-correlation Python block is around `scripts/report.sh:474-525` (builds/reads `markers_cache_file`, sorted `ts<TAB>task_type`).

The marker is written by the agent via a tool call (`scripts/write-marker.sh`) that executes **after** the turn's LLM completion has already been produced. So the marker's timestamp is *later* than the completion it is meant to classify, and `marker_ts <= completion_ts` is never true → fallback to `unclassified`.

### Evidence (live, team DZxzEl)
- Session `f710c608-5688-4a67-9ed9-d463e41737da`: completions metered at `13:47:28`, `13:47:32`, `13:47:36`, `13:47:44` Z.
- Its only marker: `{"ts":"2026-06-03T13:54:28Z","task_type":"generation"}` — ~7 minutes *after* all four completions.
- `revenium metrics completions` shows those four as `taskType: unclassified`; zero completions exist after the marker timestamp.
- A manual `revenium meter completion ... --task-type generation` posts and shows `taskType: generation` correctly → the CLI and flag mapping are healthy.

### Confirmed healthy (do NOT re-investigate)
- Cron is installed and firing every minute (`crontab -l` shows `cron.sh`; metering log shows regular ticks).
- `write-marker.sh` writes valid markers to `~/.openclaw/skills/revenium/markers/{sid}.jsonl` (mode 0700); marker content is correct.
- Marker dir path matches between writer and reader (`${SKILL_DIR}/markers`).
- `revenium` CLI: `--task-type` maps to `taskType`, `--agent` maps to `agent` (verified by dry-run + real posts).
- `--agent`/root-session attribution works at the data level (completions carry `openclaw-<sid>`).

## Resolution

### root_cause
`report.sh` used NP-1 timestamp-precedence (`marker_ts <= completion_ts`) to correlate markers to completions. Because `write-marker.sh` runs as a tool call AFTER the LLM produces the completion, the marker's timestamp is always later than the completion it classifies. The `<=` condition is never satisfied, so every completion falls through to the `unclassified` default.

### fix
Two-phase correlation (Approach A + D fallback):

**Phase A (exact id match, primary):** `write-marker.sh` now captures the `.id` of the most recent assistant completion and writes it to the marker as `completion_id`. `report.sh` checks for an exact `marker.completion_id == completion.id` match first. This is robust across all turn orderings.

**Phase D (timestamp fallback, for legacy markers):** When no id-match exists (old markers without `completion_id`, or a completion that has no corresponding id-keyed marker), `report.sh` picks the **earliest marker whose `marker_ts >= completion_ts`** (first marker written after the completion). Markers with a `completion_id` are excluded from Phase D to prevent cross-turn bleed.

The cache format was extended from `ts\ttask_type` to `ts\ttask_type\tcompletion_id` (backward-compatible; empty 3rd field for legacy markers).

### verification
- All four test suites pass: `test_get_root_session_id.py` (7), `test_write_marker.sh` (12, +2 new), `test_report_argv.sh` (9, updated fixtures + new Phase A / anti-bleed cases), `test_setup_guardrails_argv.sh` (11).
- Live check (team DZxzEl): posted a fixture completion via `report.sh` with a Phase A marker (completion_id keyed); `revenium metrics completions --output json` showed `taskType: generation` on that completion. Confirmed working.

### files_changed
- `scripts/write-marker.sh`: refactored `last_completion_ts` → `last_completion_info` returning `(ts, id)`; marker record now includes `completion_id` when resolvable, omits it otherwise.
- `scripts/report.sh`: extended markers cache to 3-column `ts\ttask_type\tcompletion_id`; replaced NP-1 `marker_ts <= completion_ts` logic with two-phase A+D correlation.
- `tests/test_write_marker.sh`: added tests 4 (completion_id present when session has assistant completion) and 5 (completion_id absent when no assistant completion).
- `tests/test_report_argv.sh`: updated Session A fixture to real marker-after-completion ordering; added Session C (Phase A exact match) and Session D (anti-bleed: id-keyed marker must not steal label from other turns).

## Evidence

- timestamp: 2026-06-03 — Live: session f710c608 completions at 13:47:2x–13:47:44Z, sole marker at 13:54:28Z (generation); all completions report taskType=unclassified; no completions after the marker. Manual meter with --task-type generation → taskType=generation. Confirms strict-precedence correlation is the defect.
- timestamp: 2026-06-03 — Fix verified live: report.sh with Phase A fixture (completion_id=comp-live-1780497864, marker ts after completion ts) → Revenium shows taskType=generation on that completion.

## Eliminated

- hypothesis: revenium CLI does not support --task-type / wrong flag name — ELIMINATED (dry-run shows --task-type → taskType; real post succeeded).
- hypothesis: markers not being written / wrong path — ELIMINATED (valid marker present at correct path with correct content).
- hypothesis: cron not running / report.sh not executing — ELIMINATED (cron fires every minute; log shows regular processing).
- hypothesis: token/field parsing (WR-07) drops the completion — ELIMINATED (completions ARE metered, just unclassified).
