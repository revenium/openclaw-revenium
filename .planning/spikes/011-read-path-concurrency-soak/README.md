---
spike: 011
name: read-path-concurrency-soak
type: standard
validates: "Given the SPIKE-01-selected direct SQLite read mechanism, when it is polled every minute for at least 60 consecutive ticks per cell while an agent actively produces live traffic, then the soak reports zero lock/SQLITE_BUSY errors and zero missed completions against an independently-derived ground truth, measured separately for the host-local and SSHFS-mounted cells"
verdict: PARTIAL
related: [004, 008]
tags: [cron, sqlite, wal, concurrency, sshfs, soak]
host: "52.90.9.242 (bare Ubuntu 26.04; sandbox revenium-2-0)"
---

# Spike 011: Read-Path Concurrency Soak (SPIKE-04)

**The HOST-LOCAL cell ran a clean 62-tick, 61-minute per-minute soak with zero lock errors and zero stalls — a definitive pass on that half of D-04's bar. The "zero missed completions" half could not be cleanly measured as designed: investigation traced the numeric gap between the read-under-test and the chosen ground truth to a genuine granularity mismatch between the two mechanisms, not to any observed read-path failure — recorded honestly as an open measurement-design finding, not forced into a false pass or fail. The SSHFS cell — required, not optional, per this plan's own must-haves — is entirely UNRUN: the sandbox never became reachable during this plan's execution window, so NEMO-03 remains unanswered.**

## What This Validates

SPIKE-04: confirmation that the SQLite session-read mechanism SPIKE-01
selected (candidate (a), direct read-only SQL) sustains real per-minute cron
polling under live, concurrently-written agent traffic without degrading —
measured against D-04's bar of zero lock/`SQLITE_BUSY` errors and zero
missed completions against an independently-derived ground truth, run as two
cells (host-local SQLite, SSHFS-mounted SQLite) because a network filesystem
carrying a live SQLite database is a materially different risk profile.

## Research

`.planning/phases/17-live-host-fact-finding-spike/17-RESEARCH.md`
§`## Concurrency Soak Design Inputs` (the `scripts/verify-markers.sh`
ground-truth template, the `scripts/cron.sh`/`nemoclaw-cron-tick.sh`
flock/timeout precedent) and §`## Common Pitfalls` Pitfall 2 (the
`busy_timeout` stall signature) and Pitfall 3 (SSHFS vs. host-local must not
be conflated). `.planning/spikes/004-background-metering-loop/
revenium-mount-tick.sh` — the validated host-cron-over-SSHFS tick shape this
soak's SSHFS cell (had it run) would have exercised.

## How to Run

```bash
# HOST-LOCAL cell (this plan's run)
crontab -e   # add:
* * * * * CELL=HOST-LOCAL \
  SQLITE_PATH=/home/ubuntu/.openclaw/agents/dev/agent/openclaw-agent.sqlite \
  GROUND_TRUTH_FILE=/home/ubuntu/.openclaw/revenium-sidecar-capture.jsonl \
  LOG_FILE=/home/ubuntu/soak-log.txt TICK_TIMEOUT_SECS=30 \
  bash /tmp/soak-tick.sh >> /home/ubuntu/soak-cron.log 2>&1
# Drive live traffic (tool calls, a subagent spawn, a session termination)
# for at least 60 ticks, then:
grep -c '^tick ' /home/ubuntu/soak-log.txt   # expect >= 60
crontab -l | grep -v spike-011-soak | crontab -   # remove when done

# SSHFS cell (NOT run this plan — sandbox unavailable):
# Same invocation with CELL=SSHFS and SQLITE_PATH pointed at
# ~/nemoclaw-revenium-2-0-mount/agents/main/agent/openclaw-agent.sqlite,
# per plan 17-01's proven mount pattern. Directly re-runnable once the
# sandbox recovers per 17-SANDBOX-BLOCKER.md.
```

## Investigation Trail

1. Confirmed the SPIKE-01-selected mechanism from `008/README.md`: direct
   SQLite read, `sqlite3 -cmd "PRAGMA busy_timeout=5000;"
   "file:<path>?mode=ro" "<SQL>"`.
2. Wrote `soak-tick.sh` reusing `scripts/cron.sh`'s flock discipline (a
   single `flock -n` lock, no queueing) with a bounded 30s per-tick timeout.
   First deployment revealed two bugs, both fixed before the real soak
   started (see `## Deviations` in the plan SUMMARY):
   - `date +%s%3N` produced a 19-digit garbage epoch value on this host's
     GNU date build (the `%3N` width modifier is not honored the way BSD
     date honors it) — fixed to plain `%N` (nanoseconds) with a
     post-hoc divide-by-1000000 for milliseconds.
   - This build's `sqlite3 -cmd` batch mode echoes the `PRAGMA busy_timeout`
     setter's own value ahead of the `SELECT` result — fixed by taking the
     LAST output line, not the first, as the completions count.
   - The pre-fix log (16 corrupted ticks) was archived
     (`soak-log-pre-fix.txt`, not committed) and the real soak restarted
     clean with the fixed script.
3. Installed a real per-minute crontab entry (not a sleep-loop substitute)
   for the HOST-LOCAL cell and let it run 62 consecutive ticks
   (2026-09-24T15:28:01Z to 16:29:02Z).
4. Drove live traffic throughout: an automated 8-iteration traffic generator
   (tool-calling turns, ~5-6 min apart) plus earlier manual testing (task 1
   of this plan) that produced a subagent spawn/end pair and two
   `session_end` fires; a second, independent subagent spawn occurred
   mid-soak and was killed by its parent turn's own timeout — a naturally
   occurring failure-path observation, not manufactured.
5. Attempted to also start the SSHFS cell: `nemoclaw revenium-2-0 status`
   was re-checked before Task 2 began and immediately after the soak
   completed (16:29Z) — both times `Phase: Error`. Per the phase's binding,
   this was not attempted, not repaired, not routed around via
   `docker exec`. The crontab entry was removed after the target tick count
   was reached (D-14-style teardown discipline — leaving no ticking cron
   behind after this plan's execution window closes).
6. On completion, found the read-under-test's cumulative completions count
   (56) did not match the ground truth's cumulative count (18) at face
   value. Rather than report this raw delta as either a pass or a fail,
   traced individual `runId`s from the ground-truth capture directly against
   `transcript_events` — see `soak-summary.md` `## Reading the
   completions/ground-truth delta` for the full trace, confirming a
   granularity mismatch (the SQL read persists one row per individual model
   API call; the ground-truth hook fires fewer times per multi-step turn
   than the number of underlying model calls) rather than a lock-contention
   miss.

## Results

### HOST-LOCAL — zero lock errors: CONFIRMED PASS

62/62 ticks, `lock_errors=0` and `rc=0` on every single tick, zero
`SQLITE_BUSY`, zero stalls (tick duration 123-707ms throughout). Both the
`completions` and `ground_truth` counters are independently monotonically
non-decreasing across the entire window — neither ever decreased, which is
exactly what a genuine dropped-read would look like and did not happen.
**This half of D-04's bar is definitively met for this cell.**

### HOST-LOCAL — zero missed completions: NOT CLEANLY MEASURABLE AS DESIGNED

The raw totals (56 vs. 18) reflect a **measurement-granularity mismatch**
between the read-under-test (counts every persisted assistant-role
transcript row, including intermediate tool-decision calls within one agent
turn) and the ground-truth mechanism (the sidecar's `llm_output` hook, which
fires fewer times per multi-step turn than the number of underlying model
calls — contradicting RESEARCH.md's docs-derived assumption of a strict
1:1 "usage object per completion" relationship). Traced sample `runId`s
directly against `transcript_events` and found the read-under-test's excess
rows are real, distinctly-tokened, distinctly-timestamped model completions
— not duplicates, not corruption. **The direction of this mismatch is the
opposite of a fail-open miss**: a lock-contention-caused loss would make the
read-under-test under-report relative to ground truth; what was observed is
over-reporting, traced to real data the ground-truth mechanism simply never
counted at that grain. No SQLITE_BUSY event, no stall, and no case of the
read-under-test's count decreasing or erroring was found anywhere in the
62-tick log. This is recorded as an **open finding for Phase 19** — the
production read layer needs a precisely-defined "one completion" unit
(e.g., dedupe by `responseId` or filter to one canonical message per model
call) and a ground-truth mechanism that counts at the same grain — not as a
PASS-by-default and not as a FAIL invented from an uninterpreted number.

### SSHFS — UNRUN, NEMO-03 unanswered

The sandbox `revenium-2-0` remained `Phase: Error` for this plan's entire
execution window (2026-09-24, confirmed at both Task 1's start and
immediately after the soak's completion at 16:29Z). **Per this plan's own
must-have ("the soak runs as two cells... because a network filesystem
carrying a live SQLite database is a materially different risk profile"),
this cell was required, not optional, and it did not run.** No SSHFS
tick data exists. **NEMO-03 ("the host-side metering loop reads the 2.0
session store over the SSHFS `nemoclaw share mount`") remains entirely
unanswered by this plan** — its answer depends specifically on this cell,
which never ran. This is stated as an open question, not a PARTIAL and not a
fail, per the phase's own prohibition and `17-SANDBOX-BLOCKER.md`.

### Verdict rationale

`PARTIAL` — not `VALIDATED` (the both-cells bar this plan's own must-haves
set is unmet: only one of two required cells ran, and even that cell's
"zero missed completions" half could not be cleanly confirmed as designed)
and not `INVALIDATED` (no evidence of an actual concurrency-caused loss was
found on the cell that did run — the read mechanism held up cleanly under
61 minutes of real per-minute polling against live-written state, with zero
lock contention).

## Requirements / build guidance

**Non-negotiables Phase 19/22 inherit from this determination:**

- The direct SQLite read mechanism (`file:<path>?mode=ro` +
  `PRAGMA busy_timeout=5000`, no retry wrapper) sustains real per-minute
  cron polling against a live-written HOST-LOCAL store with zero lock
  contention over a 61-minute, 62-tick window. This is proven, not assumed.
- **Phase 19's read layer must define "one completion" precisely** — do not
  assume a raw `COUNT(*) FROM transcript_events WHERE
  json_extract(event_json,'$.message.role')='assistant'` corresponds 1:1 to
  the number of billable/metered completions a turn produced; a single
  multi-step turn can produce multiple such rows (verified: up to 5 for one
  turn in this soak). `report.sh`'s successor should dedupe/group by a
  structural key (e.g. `responseId`, or exactly one row per `runId` chosen
  by a defined rule), not raw row count.
- **The SSHFS cell is a hard prerequisite for NEMO-03 and remains
  unanswered.** Phase 22 (NemoClaw path on 2.0) MUST NOT assume the
  host-local result generalizes to the SSHFS-mounted path — re-run this
  plan's `soak-tick.sh` with `CELL=SSHFS` against the sandbox's mounted
  store as a required pre-build step once the sandbox recovers.
- `soak-tick.sh`'s two live-host bugs (the `%3N` epoch-millis format and the
  `-cmd` PRAGMA-echo quirk) are recorded so Phase 19's own tooling does not
  rediscover them: use plain `%N` for nanosecond epochs on this host's
  `date` build, and always take the LAST line of a multi-statement
  `sqlite3 -cmd` invocation's output, never the first.

## Open follow-up

- **The SSHFS cell, entirely** — carried forward, unresolved, blocking
  NEMO-03. Once the sandbox recovers, this plan's exact `soak-tick.sh`
  invocation (substituting `CELL=SSHFS` and the mount-relative SQLite path)
  is directly re-runnable.
- **The completion-granularity mismatch** — Phase 19 needs to settle on a
  canonical completion-counting definition before treating either mechanism
  traced here as ground truth for production metering; this soak's own
  ground-truth choice (the sidecar's `llm_output` hook) is now known to
  undercount relative to raw model-call granularity and should not be
  assumed correct without further investigation.
- **The one untraceable `runId`** (`c70e70fc-…`) — a `LIKE`-based substring
  trace found only a coincidental match (a user message's
  `idempotencyKey`), not the actual completion row. A from-scratch Phase 19
  implementation must join on a structurally-correct key, not a substring
  scan, and should re-verify this specific edge case.

---
*Spike: 011*
*Phase: 17-live-host-fact-finding-spike*
*Completed: 2026-09-24*
