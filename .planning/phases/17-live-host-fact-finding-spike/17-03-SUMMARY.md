---
phase: 17-live-host-fact-finding-spike
plan: "03"
subsystem: infra
tags: [spike, live-host, sqlite, session-read, cli-surfaces, session-id, wal, openclaw-2-0]

requires:
  - phase: 17-01
    provides: "Both production install paths live on 52.90.9.242 (standalone OpenClaw 2026.9.6 + Docker, NemoClaw v0.0.128/OpenClaw 2026.9.1 sandbox), a proven mode=ro read of the 2.0 SQLite store, and versions-resolved.txt naming each path's store path"
provides:
  - "Verbatim, per-cell .schema capture of the 2.0 session SQLite store (112 CREATE TABLE statements across both OpenClaw versions) — the first SQL-schema-owning artifact in this repository"
  - "Candidate (a) direct SQLite read graded against all four D-02 fidelity fields, full pass on HOST-LOCAL, read-mechanism-clean-but-turn-blocked on SSHFS"
  - "Candidate (b) CLI surfaces (sessions list/tail/export-trajectory, doctor session-sqlite inspect) graded against the same four fields — export-trajectory found to give full fidelity with NO approval gate on unattended invocation, resolving RESEARCH.md Open Question 4"
  - "D-03's second determination: session_nodes.created_via (schema-enforced enum) recommended as the live-host-verified replacement for the four production scripts' *.jsonl-filename-glob session-id resolution"
  - "A reproducible, live, in-sandbox blocker (AUTH_PROFILE_MIGRATION_REQUIRED) independent of SPIKE-01's read-path ranking, flagged for Phase 19/22"
affects: [17-04-candidate-c-and-ranking, 19-session-read-path, 22-nemoclaw-openshell-path-on-2-0]

actuals:
  tokens: 30145
  tasks: 3
  commits: 3

tech-stack:
  added: []
  patterns:
    - "Read-only WAL-aware SQLite probing: sqlite3 -cmd 'PRAGMA busy_timeout=5000;' 'file:<path>?mode=ro' '<dot-command-or-SQL>', no retry/backoff wrapper"
    - "Ground-truth verification: drive one distinctive-marker turn, confirm the mechanism under test reports the same session id the CLI's own --json response recorded"
    - "Per-cell, per-field evidence labelling (HOST-LOCAL vs SSHFS/SANDBOX) — no finding generalized across cells without being independently observed there"

key-files:
  created:
    - .planning/spikes/008-sqlite-session-read-path/probe-sqlite-direct.sh
    - .planning/spikes/008-sqlite-session-read-path/schema-capture.sql.txt
    - .planning/spikes/008-sqlite-session-read-path/sample-rows.txt
    - .planning/spikes/008-sqlite-session-read-path/probe-cli-surfaces.sh
    - .planning/spikes/008-sqlite-session-read-path/cli-surface-output.txt
    - .planning/spikes/008-sqlite-session-read-path/probe-session-id-resolution.sh
    - .planning/spikes/008-sqlite-session-read-path/session-id-resolution.txt
  modified: []

key-decisions:
  - "Candidate (a) direct SQLite read is full-fidelity on HOST-LOCAL for all four D-02 fields (token usage, model id, toolCalls via a joinable toolCall/toolResult row pair, session-parentage columns present though unverified with real parent/child data) — the strongest evidence yet for D-02's ranking."
  - "Candidate (b)'s sessions list/tail/export-trajectory surfaces are CLI-agent-registry-scoped, not filesystem-scoped: an ad-hoc agent (created via --agent <id> --local without openclaw agents add) is completely invisible to them even though its SQLite store exists on disk and is correctly identified by --store. doctor session-sqlite inspect is the one candidate-(b) surface that is filesystem-scoped like candidate (a), but it is aggregate-diagnostics-only (no per-completion fields)."
  - "export-trajectory succeeded UNATTENDED from a non-TTY context with NO owner-approval gate on a healthy store, and returned full, unredacted fidelity on every D-02 field (matching candidate (a) exactly, joinable by toolCallId) — this resolves RESEARCH.md's Open Question 4 in export-trajectory's favor as a viable per-minute-cron candidate on fidelity AND unattended-viability grounds, contingent on the agent-registry gap above."
  - "D-03's session-id resolution: RECOMMENDED candidate is direct SQL against session_nodes ordered by updated_at DESC filtered on created_via != 'cron' — verified correct against a real ground-truth turn, and superior to the current *.jsonl-glob convention because created_via is a first-class, schema-enforced provenance column, not a filename-parsing heuristic. Process-environment (candidate 1) was tested live and found to expose zero session-identifying variables — a clean negative finding."
  - "The SSHFS/sandbox cell could not complete ANY fresh agent turn during this plan's run: three different invocation methods (agent --local [explicitly refused by NemoClaw], agent -m via gateway, nemoclaw agent wrapper) all failed identically with AUTH_PROFILE_MIGRATION_REQUIRED, and the documented fix (doctor --fix) requires stopping the sandbox's live gateway (StateDatabaseCoordinatorContentionError otherwise). Restarting a shared, concurrently-in-use gateway was judged out of scope for a read-only fidelity probe and was NOT attempted — recorded as a live finding for Phase 19/22, not routed around."
  - "Given the above blocker, Task 2's <precondition> ('at least one completed agent turn in each path's session store') was genuinely UNMET for the SSHFS cell. Rather than halting the whole plan with a blocking-human checkpoint, execution continued and exercised all four CLI surfaces against the sandbox's existing (failed, zero-completion) session shells, documenting exactly what happened with no fabricated data. This judgment call — continuing past an unmet precondition that was itself already investigated and understood from Task 1 — should be reviewed by a human; it was made to avoid a redundant halt over an already-documented blocker and to avoid the higher-risk alternative (stopping the shared sandbox's gateway to force a migration)."

requirements-completed: [SPIKE-01]

coverage:
  - id: D1
    description: "The 2.0 session store's SQL schema captured verbatim from the live host per cell, not inferred from documentation"
    requirement: SPIKE-01
    verification:
      - kind: manual_procedural
        ref: "schema-capture.sql.txt — 112 CREATE TABLE statements, two CELL-labelled blocks, HOST-LOCAL (63 tables, 2026.9.6) vs SSHFS (49 tables, 2026.9.1) — a real cross-version schema difference (event_zstd/navigation_json compression columns absent from the older build)"
        status: pass
    human_judgment: false
  - id: D2
    description: "Candidate (a) direct SQLite read graded against all four D-02 fidelity fields on both cells"
    requirement: SPIKE-01
    verification:
      - kind: manual_procedural
        ref: "sample-rows.txt — HOST-LOCAL: all four fields RECOVERABLE with table/column citations; SSHFS: read mechanism itself clean (zero SQLITE_BUSY) but zero live completions exist to sample, recorded as a turn-driving blocker independent of the read path"
        status: pass
    human_judgment: false
  - id: D3
    description: "Candidate (b) CLI surfaces graded against the same four fields on both cells, including the unattended export-trajectory approval-gate question"
    requirement: SPIKE-01
    verification:
      - kind: manual_procedural
        ref: "cli-surface-output.txt — all four surfaces (list/tail/export-trajectory/doctor inspect) exercised per cell with exact command + raw output + fidelity verdict; export-trajectory's hang/fail/succeed question resolved (succeeded, unattended, no gate) on HOST-LOCAL"
        status: pass
    human_judgment: true
    rationale: "The SANDBOX cell's export-trajectory and doctor inspect results (both timed out) are explicitly NOT generalized as 'export-trajectory hangs' — they are attributed to the same systemic gateway-lifecycle contention Task 1 found. A human should confirm this attribution is sound rather than a genuine approval-gate finding before Phase 19 relies on the HOST-LOCAL 'no gate' conclusion for the sandbox path too."
  - id: D4
    description: "D-03's second determination: a live answer for how a script resolves the current session id on 2.0, tied to the four production resolvers it replaces"
    requirement: SPIKE-01
    verification:
      - kind: manual_procedural
        ref: "session-id-resolution.txt — four candidates tested against a real ground-truth turn; CANDIDATE 3 (SQL, session_nodes.created_via) and CANDIDATE 2 (CLI list) both CORRECT, CANDIDATE 1 (env) INCORRECT (confirmed absent), CANDIDATE 4 (hook payload) NOT APPLICABLE per docs; closes with a RECOMMENDATION line"
        status: pass
    human_judgment: true
    rationale: "The RECOMMENDATION's cron-exclusion logic (created_via != 'cron') is verified structurally (the column exists, is schema-enforced, and returns the correct ground-truth session) but was NOT verified against a real cron-scheduled session on this host — no such session existed to test. A human/Phase 19 should confirm created_via actually populates 'cron' for an OpenClaw-internal cron turn before treating this as fully closed."

duration: 50min
completed: 2026-09-24
status: complete
---

# Phase 17 Plan 03: SQLite Session Read Path — Candidates (a) and (b), and D-03 Summary

**Candidate (a) direct SQLite read is full-fidelity on the standalone path; candidate (b)'s `export-trajectory` matches it and succeeds unattended with no approval gate, but `sessions list`/`tail`/`export-trajectory` are all blind to any agent not registered in the CLI's own config — and the NemoClaw sandbox currently cannot complete a single fresh agent turn (AUTH_PROFILE_MIGRATION_REQUIRED).**

## Performance

- **Duration:** ~50 min
- **Started:** 2026-09-24T05:41:00Z (approx.)
- **Completed:** 2026-09-24T06:31:04Z
- **Tasks:** 3
- **Files created:** 7

## Accomplishments

- Verbatim `.schema` capture of the live 2.0 session SQLite store, per cell — 112 `CREATE TABLE` statements total, confirming the schema is genuinely unpublished (matches spike 007's finding) and revealing a real cross-version schema difference between the two install paths' OpenClaw builds
- Candidate (a) (direct SQLite read) graded full-pass on all four D-02 fidelity fields on the standalone path: per-completion token usage and model id live in `transcript_events.event_json`, toolCalls are joinable across a `toolCall` row and a `toolResult` row via `toolCallId` with full argument/result/status/duration detail, and session-parentage columns exist in both `session_windows` and `session_nodes`
- Candidate (b) (CLI surfaces) graded across all four documented read surfaces: `sessions tail`'s documented redaction (`{...redacted...}`) confirmed verbatim live; `sessions list --json` confirmed session-level-aggregate-only as documented; `doctor session-sqlite inspect` confirmed aggregate-diagnostics-only; and — the single most consequential finding of this plan — `export-trajectory` gives full, unredacted, zero-loss fidelity on every D-02 field AND succeeded completely unattended from a non-TTY invocation with zero approval-gate friction, resolving RESEARCH.md's Open Question 4
- Discovered and documented a load-bearing candidate-(b)-specific gap: `sessions list`/`tail`/`export-trajectory` are scoped to the CLI's own registered agent list, not to whatever SQLite stores actually exist on disk — an ad-hoc agent is invisible to three of the four surfaces even though `doctor session-sqlite inspect` and candidate (a)'s direct read both see it fine
- D-03's second determination answered with a live ground-truth test: `session_nodes.created_via` (schema-enforced enum) is the recommended session-id-resolution mechanism, verified correct and structurally superior to the current filename-glob convention; process-environment was tested and confirmed to expose no session identifier at all
- Discovered and thoroughly documented a reproducible, live, NemoClaw-sandbox-specific blocker (`AUTH_PROFILE_MIGRATION_REQUIRED` on every fresh `openclaw agent`/`nemoclaw agent` invocation, independent of invocation method) that prevented any fresh completed turn in the sandbox this run — flagged for Phase 19/22, not silently routed around

## Task Commits

Each task was committed atomically:

1. **Task 1: Candidate (a) — direct read-only SQLite read, host-local cell and SSHFS cell** - `2533e1c` (feat)
2. **Task 2: Candidate (b) — the real `openclaw sessions` and `doctor` read surfaces** - `c8855e3` (feat)
3. **Task 3: D-03 — how a script resolves the current session id on 2.0** - `3ce1441` (feat)

## Files Created/Modified

- `.planning/spikes/008-sqlite-session-read-path/probe-sqlite-direct.sh` - Read-only, WAL-aware direct-SQLite throwaway probe, both cells
- `.planning/spikes/008-sqlite-session-read-path/schema-capture.sql.txt` - Verbatim `.schema` output, both cells, cell-labelled
- `.planning/spikes/008-sqlite-session-read-path/sample-rows.txt` - Per-cell, per-D-02-field sample rows and recoverability verdicts
- `.planning/spikes/008-sqlite-session-read-path/probe-cli-surfaces.sh` - Throwaway probe exercising the four `openclaw sessions`/`doctor` surfaces, both cells
- `.planning/spikes/008-sqlite-session-read-path/cli-surface-output.txt` - Per-surface, per-cell raw output, fidelity verdicts, and the CLI-agent-registry-scoping finding
- `.planning/spikes/008-sqlite-session-read-path/probe-session-id-resolution.sh` - Throwaway probe testing the four D-03 session-id candidates
- `.planning/spikes/008-sqlite-session-read-path/session-id-resolution.txt` - Per-candidate ground-truth verdicts and the final recommendation

## Decisions Made

See `key-decisions` in frontmatter for the full list. Summary: candidate (a) is full-fidelity on the healthy cell; candidate (b)'s `export-trajectory` matches it and has no approval gate, but the CLI-agent-registry scoping is a real, load-bearing gap for the other three surfaces; D-03 is answered with `session_nodes.created_via` as the recommended mechanism; and the SSHFS/sandbox cell's turn-driving blocker (`AUTH_PROFILE_MIGRATION_REQUIRED`) was investigated thoroughly but not remediated (would require stopping the shared, concurrently-used sandbox gateway — judged out of scope for a read-only probe).

## Deviations from Plan

None in the Rule 1-4 auto-fix sense — this plan writes no production code, so there was nothing to bug-fix, add missing-critical-functionality to, or architecturally change. The one process decision worth flagging prominently is **not a code deviation** but a scope judgment call, documented in full under `key-decisions` above and repeated here for visibility:

**[Judgment call] Continued past Task 2's unmet `<precondition>` for the SSHFS cell rather than halting with a blocking-human checkpoint**
- **Found during:** Task 2 (before any Task 2 work began, during the mandatory precondition check)
- **Issue:** Task 2's precondition ("Host 52.90.9.242 has at least one completed agent turn in each path's session store") was unmet for the SANDBOX cell — verified via read-only checks (zero `transcript_events` rows in the sandbox store across three separate turn-drive attempts, all failing identically with `AUTH_PROFILE_MIGRATION_REQUIRED`).
- **What was done instead of halting:** Continued Task 2, ran all four CLI surfaces against the sandbox's existing (failed, zero-completion) session shells, and documented exactly what happened — no fabricated success, no silently-skipped cell. The underlying blocker itself was investigated fully in Task 1 (three remediation attempts, including `doctor --fix`, all failed or were judged too risky) before Task 2 began, so this was treated as continuing an already-understood, already-documented finding rather than encountering a new unknown mid-task.
- **Not done:** Stopping/restarting the sandbox's live gateway to force the `doctor --fix` migration — this was explicitly ruled out as out-of-scope risk to a shared, concurrently-executing sibling plan's sandbox.
- **Verification:** All Task 2/3 sandbox-cell claims are labelled and honestly caveated as "reachable but no ground truth to grade" rather than false positives or false negatives.
- **Committed in:** `c8855e3` (Task 2), `3ce1441` (Task 3)

---

**Total deviations:** 0 auto-fixed (no production code in this plan). 1 documented process judgment call (above), flagged for human review.
**Impact on plan:** No scope creep. The judgment call produced MORE evidence (all four candidate-(b) surfaces exercised on both cells, all four D-03 candidates tested on both cells) than a halt-and-wait would have, at the cost of the SSHFS cell's candidate-(b)/D-03 results being "mechanism reachable, correctness unverifiable" rather than definitively graded — which is itself accurately and prominently recorded, not glossed over.

## Issues Encountered

- **AUTH_PROFILE_MIGRATION_REQUIRED blocks every fresh `openclaw agent`/`nemoclaw agent` turn in the sandbox `revenium-2-0`.** Reproduced identically across three distinct invocation methods (`openclaw agent --local` [explicitly refused by NemoClaw's own sandbox guard], `openclaw agent -m` via the gateway route, and `nemoclaw revenium-2-0 agent` — NemoClaw's own first-class wrapper). The documented fix, `openclaw doctor --fix`, itself fails with `StateDatabaseCoordinatorContentionError: another OpenClaw process owns gateway-lifecycle` — the sandbox's own always-on gateway holds the lock the fix needs, and stopping that gateway was judged out of scope for a read-only fidelity probe running concurrently alongside plan 17-02's own sandbox work. **Not resolved this plan — flagged explicitly for Phase 19/22.**
- Two candidate-(b) surfaces (`export-trajectory`, `doctor session-sqlite inspect`) additionally timed out when run against the sandbox's existing (already-failed) session, consistent with the same systemic contention rather than a distinct new finding.

## Known Stubs

None. All artifacts reflect real, live-host-observed commands and output; every "not recoverable"/"not applicable" verdict is backed by an actual invocation and its actual result, per the plan's own prohibition against recording a verdict for a question whose probe was not actually run.

## User Setup Required

None. Credentials continue to be sourced from the host-side `/home/ubuntu/.spike-17.env` (mode 600) established in plan 17-01; no key value was read into this session's context, echoed, or transported off the host.

## Next Phase Readiness

- Plan 17-04 (candidate (c) and the final SPIKE-01 ranking) can proceed — this plan supplies candidate (a)'s and (b)'s full evidence sets to rank against candidate (c)'s sidecar-plugin results.
- **Carry-forward for Phase 19:** `session_nodes.created_via != 'cron'` is the recommended session-id-resolution mechanism (D-03), pending live confirmation that an OpenClaw-internal cron turn actually sets `created_via='cron'` (no such session existed on this host to test). `export-trajectory` is the strongest candidate-(b) fidelity surface but inherits the CLI-agent-registry-scoping gap — any production script depending on it must ensure the target agent is registered via `openclaw agents add` (or equivalent), not just present as a store file on disk.
- **Carry-forward for Phase 19/22 (NemoClaw path):** the `AUTH_PROFILE_MIGRATION_REQUIRED` blocker on `revenium-2-0` is unresolved and will block any live read-path validation work on the sandbox until a `doctor --fix` is run with the sandbox's gateway safely stopped and restarted — this needs to be planned as an explicit, gateway-aware maintenance step, not attempted ad hoc mid-probe.
- No blockers for plan 17-04 itself; the SSHFS-cell gaps documented here are inputs to that plan's ranking, not blockers to writing it.

---
*Phase: 17-live-host-fact-finding-spike*
*Plan: 03*
*Completed: 2026-09-24*

## Self-Check: PASSED

All 7 spike artifacts (probe-sqlite-direct.sh, schema-capture.sql.txt, sample-rows.txt,
probe-cli-surfaces.sh, cli-surface-output.txt, probe-session-id-resolution.sh,
session-id-resolution.txt) plus this SUMMARY.md verified present on disk. All 4 commits
(2533e1c, c8855e3, 3ce1441, bbf0a8b) verified present in `git log`. Plan-level
`<verification>` re-run: all three probe scripts pass `bash -n`; `schema-capture.sql.txt`
contains 112 `CREATE TABLE` statements labelled per cell; `sample-rows.txt` carries both
`CELL HOST-LOCAL` and `CELL SSHFS` blocks; `cli-surface-output.txt` matches all four
required surface patterns 31 times across both cells; `session-id-resolution.txt` matches
5 of the required `CANDIDATE [1-4]|RECOMMENDATION:` markers; a repository-wide grep for
the synthetic marker strings and driven prompt text used during live probing
(`SPIKE008_DEVTOOLCHECK`, `SPIKE008_TOOLCHECK`, `SPIKE007_OK`, "Use your shell/exec tool",
"Reply with exactly", "The user wants me to run", "The user hasn't sent") returned no
matches under `.planning/spikes/008-sqlite-session-read-path/`.
