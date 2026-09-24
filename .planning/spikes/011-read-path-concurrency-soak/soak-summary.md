# Spike 011 (SPIKE-04) — Soak Summary

Host: 52.90.9.242. Date: 2026-09-24. Standalone OpenClaw 2026.9.6 (eb377ac),
Node v24.21.0. Mechanism under test: candidate (a) direct SQLite read (the
SPIKE-01-selected mechanism), `sqlite3 -cmd "PRAGMA busy_timeout=5000;"
"file:<path>?mode=ro" "SELECT count(*) FROM transcript_events WHERE
json_extract(event_json,'$.message.role')='assistant';"` — one invocation
per tick, no retry wrapper. Ground truth: the plan 17-04 sidecar plugin
(`probe-sidecar-plugin/`, registering `llm_output`), an independently
maintained completion count from a mechanism SPIKE-01 did NOT select,
counted via `grep -c '"hook":"llm_output"'` against its own capture file —
never the same mechanism as the read under test, per D-04.

## Per-cell totals

| Cell | Ticks | Lock errors | Non-zero rc | Completions (last tick, cumulative) | Ground truth (last tick, cumulative) | Delta interpretation |
|---|---|---|---|---|---|---|
| **HOST-LOCAL** | 62 | **0** | **0** | 56 (started at 24; monotonically non-decreasing every tick) | 18 (started at 9; monotonically non-decreasing every tick) | See "Reading the completions/ground-truth delta" below — NOT a missed-completion signal |
| **SSHFS** | **0 — NOT RUN** | n/a | n/a | n/a | n/a | Sandbox `revenium-2-0` remained `Phase: Error` for the entire plan window (confirmed at Task 1 start and re-confirmed at 16:29Z, soak completion); never attempted, never routed around via `docker exec`, per `17-SANDBOX-BLOCKER.md` |

Window: 2026-09-24T15:28:01Z to 2026-09-24T16:29:02Z (61 minutes, 62 ticks —
exceeds the 60-tick minimum for the one cell that could run). Live agent
traffic ran throughout most of this window: 8 automated traffic-generator
turns (tool-calling, ~5-6 min apart) plus earlier manual testing that
included a subagent spawn/end pair and two `session_end` fires, and a second
independent subagent spawn/kill pair captured mid-soak (16:04-16:09Z).

## Reading the completions/ground-truth delta — investigated, not assumed

The raw totals (56 SQL-counted completions vs. 18 ground-truth completions)
do NOT match 1:1, and this was investigated directly against the raw store
rather than left unexplained:

- Traced a specific ground-truth-confirmed `runId`
  (`0fb6d183-c95a-4670-8929-3de2d6af8f85`, one `llm_output` fire at
  15:40:08.508Z) against `transcript_events`: **5 separate rows** carry that
  same `runId` in `$.message.__openclaw.runId`, each with its own distinct
  `usage.totalTokens` value (e.g. seq 136: 21490 tokens; seq 141: 21754
  tokens — genuinely different completions, not duplicate rows). A second
  traced `runId` (`c8f31b93-…`) showed 3 such rows.
- **Conclusion: the two mechanisms count at different granularities.** The
  direct SQL read (the mechanism under test) persists one row per individual
  model API call, including intermediate tool-decision calls within a single
  multi-step agent turn. The sidecar's `llm_output` hook (the ground-truth
  mechanism) fires fewer times per turn than the number of underlying model
  calls that turn actually made — contradicting RESEARCH.md's docs-derived
  assumption that `llm_output` "exposes a usage object per completion" in a
  1:1 sense with every model API call. This is a live-host finding this spike
  surfaces, not something inferable from documentation.
- **This is the OPPOSITE signature of a fail-open miss.** A `SQLITE_BUSY`/
  lock-contention-caused miss would make the read-under-test's count
  UNDER-report relative to ground truth (the read fails to see data that
  exists). What was observed is the read-under-test reporting MORE
  completions than the ground truth, and every one of the sampled excess SQL
  rows corresponds to a real, distinctly-timestamped, distinctly-tokened
  model call — not a duplicate, not garbage, not a phantom row.
- One edge case was found and is recorded honestly rather than glossed:
  `runId` `c70e70fc-…` (an `llm_output` fire at 15:58:10.272Z) had a naive
  substring search return only the corresponding USER message's
  `idempotencyKey` (which happens to equal that runId string), not a
  matching assistant completion row — meaning the substring-match tracing
  method used here is not perfectly reliable for every runId, and a from-
  scratch production implementation must join on a structurally-correct key
  (not a `LIKE` scan), a concrete requirement for Phase 19's read layer.

## D-04's bar, graded honestly, per cell

D-04's bar is **zero lock errors AND zero missed completions**.

**HOST-LOCAL — zero lock errors: PASS, definitively.** `lock_errors=0` and
`rc=0` on all 62 ticks, no exceptions, no `SQLITE_BUSY`, no stalls. The
`completions` and `ground_truth` columns are each independently monotonically
non-decreasing across the entire 62-tick window — neither ever went
backward, which is what a genuine drop/miss would look like.

**HOST-LOCAL — zero missed completions: NOT CLEANLY MEASURABLE AS DESIGNED,
and NOT recorded as a pass by assumption.** The chosen ground-truth mechanism
counts at a coarser grain than the read-under-test, so the raw numeric delta
cannot be read as "9 completions missed." No evidence of an actual read-path
failure (lock contention, a stale/incomplete read, a `SQLITE_BUSY` event) was
found anywhere in the 62-tick log or in the traced sample rows. This is
recorded as an **open measurement-design finding for Phase 19**, not folded
into a false PASS and not inflated into a false FAIL — per the phase's own
prohibition against asserting a behavior not directly observed.

**SSHFS — both halves: UNRUN.** The sandbox never became reachable during
this plan's execution window. Recorded as an open question, not a PARTIAL,
not a fail, not inferred from the HOST-LOCAL cell — per the phase's binding
and `17-SANDBOX-BLOCKER.md`.

**Resource metrics (recorded, not the pass bar):** tick duration ranged
123-707ms (median ~240ms); host load (1-min avg) ranged 2.37-8.86 across the
window (2 vCPU host, per spike 007's provisioning record) — recorded for
completeness per D-04's explicit instruction that these are not the bar.
