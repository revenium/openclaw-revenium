---
phase: 17-live-host-fact-finding-spike
plan: "05"
subsystem: infra
tags: [spike, live-host, hooks, matrix, cross-model, soak, concurrency, cron, sqlite]

requires:
  - phase: 17-04
    provides: "Candidate (c) sidecar plugin (probe-sidecar-plugin/) installed with provenance on HOST-LOCAL, serving as this plan's independent ground-truth mechanism; SPIKE-01's selection of candidate (a) direct SQLite read as the mechanism this plan's soak measures"
provides:
  - "SPIKE-02 determination: all six D-08 hooks fired live on the standalone OpenClaw + Claude pairing with full payload-key evidence; both-pairings provenance bar explicitly UNMET (sandbox never reachable); B-05 remains UNRUN; #155696 confirmed for this pairing; allowPromptInjection default-allowed behavior confirmed live"
  - "SPIKE-04 determination: HOST-LOCAL's zero-lock-errors half of D-04 confirmed PASS over a real 62-tick, 61-minute per-minute soak; zero-missed-completions recorded as not cleanly measurable as designed (a genuine ground-truth/read-path granularity mismatch, investigated and traced, not a lock-contention miss); SSHFS cell entirely UNRUN, NEMO-03 unanswered"
affects: [19-session-read-path, 20-plugin-2-0-sdk-compliance, 22-nemoclaw-openshell-path-on-2-0, 23-hard-halt-version-canary-live-validation]

actuals:
  tokens: 25660
  tasks: 3
  commits: 3

tech-stack:
  added: []
  patterns:
    - "Hook-observer plugin packaging mirrors the proven spike 006/plan 17-04 shape (package.json type=module/main/openclaw.extensions; manifest id/activation.onStartup/configSchema); payload field names ground-truthed live from the installed openclaw package's own .d.ts, never guessed"
    - "Permission-configuration A/B testing via openclaw config unset (not just omission in a patch call) to produce a genuinely absent key, confirmed via openclaw config get before trusting the firing result"
    - "Soak-tick.sh reuses scripts/cron.sh's flock + bounded-timeout discipline as a real per-minute crontab entry, not a sleep-loop substitute — the only way to genuinely satisfy 'at least 60 consecutive per-minute ticks'"
    - "Ground truth for a concurrency soak comes from the SPIKE-01-non-selected mechanism (here, the sidecar's independent llm_output capture count), never the same mechanism as the read under test"
    - "When a numeric delta between two independently-derived counts doesn't match, trace individual sample records back to raw evidence before declaring a verdict — the investigation here found a granularity mismatch, not a miss, and reported that honestly instead of forcing a pass or fail"

key-files:
  created:
    - .planning/spikes/009-hook-firing-matrix-2-0/probe-hook-observer/package.json
    - .planning/spikes/009-hook-firing-matrix-2-0/probe-hook-observer/openclaw.plugin.json
    - .planning/spikes/009-hook-firing-matrix-2-0/probe-hook-observer/index.js
    - .planning/spikes/009-hook-firing-matrix-2-0/hook-fire-log.txt
    - .planning/spikes/009-hook-firing-matrix-2-0/hook-matrix.md
    - .planning/spikes/009-hook-firing-matrix-2-0/README.md
    - .planning/spikes/011-read-path-concurrency-soak/soak-tick.sh
    - .planning/spikes/011-read-path-concurrency-soak/soak-log.txt
    - .planning/spikes/011-read-path-concurrency-soak/soak-summary.md
    - .planning/spikes/011-read-path-concurrency-soak/README.md
  modified: []

key-decisions:
  - "Ran a real per-minute crontab entry for the soak (not a compressed sleep-loop), because D-04's bar is explicitly 'per-minute' and there is no faithful substitute — this cost roughly 61 minutes of real wall-clock time, spent generating live traffic and preparing the write-up in parallel"
  - "Started the standalone Gateway in the foreground (openclaw gateway run, no OS service installed) after embedded --local execution refused subagent_spawned with 'published reply runtime missing for dev' — scoped strictly to the standalone/HOST-LOCAL pairing, no sandbox or systemd changes, and this is the only way this plan's traffic could exercise subagent_spawned/subagent_ended at all"
  - "When the read-under-test's completion count (56) didn't match the ground truth's count (18), investigated by tracing individual runIds against transcript_events rather than reporting the raw delta as a pass or fail. Found a genuine granularity mismatch (the SQL read persists one row per model API call; the ground-truth llm_output hook fires fewer times per multi-step turn) — the opposite signature of a fail-open miss. Recorded as an open measurement-design finding for Phase 19, not folded into a false PASS"
  - "SPIKE-04's verdict is PARTIAL, not VALIDATED — HOST-LOCAL's zero-lock-errors half is a confirmed pass, but the zero-missed-completions half is not cleanly measurable as designed, and the SSHFS cell (this plan's own must-have: 'required, not optional') never ran. Not INVALIDATED either — no evidence of an actual concurrency-caused loss was found"
  - "SPIKE-02's verdict is PARTIAL — all six hooks confirmed firing live on HOST-LOCAL with full evidence, but the both-pairings provenance bar is explicitly unmet since the sandbox never became reachable, and B-05 (after_tool_call on Nemotron's tool_search_code routing) remains entirely unanswered"
  - "#155696 is confirmed, not retired, for the standalone/Claude pairing: session_end's live-confirmed payload schema carries no message-content field at all, and a dynamic (non-hardcoded) content scan evaluated false on both live fires"

requirements-completed: [SPIKE-02, SPIKE-04]

coverage:
  - id: D1
    description: "Hook-observer plugin built and installed with real provenance on the HOST-LOCAL standalone pairing, registering exactly the six D-08 hooks, exercised under both allowPromptInjection permission configurations"
    requirement: SPIKE-02
    verification:
      - kind: manual_procedural
        ref: "openclaw plugins inspect revenium-hook-observer output quoted verbatim (Trust: reason=origin-path) in 009/README.md's Investigation Trail; before_prompt_build fired under both Configuration A (allowPromptInjection explicit) and Configuration B (omitted via openclaw config unset, confirmed via openclaw config get)"
        status: pass
    human_judgment: false
  - id: D2
    description: "A shared live-traffic window produced both datasets: a 62-tick, 61-minute per-minute soak on HOST-LOCAL and a full per-hook fire record for all six D-08 hooks on the same pairing"
    requirement: SPIKE-04
    verification:
      - kind: manual_procedural
        ref: "soak-log.txt (62 tick records, lock_errors=0/rc=0 throughout) and hook-fire-log.txt (all six hooks fired: 16/35/7/2/2/2 records, including two distinct subagent_ended outcomes)"
        status: pass
    human_judgment: false
  - id: D3
    description: "009/README.md and 011/README.md, both PARTIAL determinations, are self-contained and honestly graded, with every claim carrying the exact command, raw output, host, date, and versions in effect"
    requirement: SPIKE-02
    verification:
      - kind: manual_procedural
        ref: "009/README.md and 011/README.md — spike: number + three-state verdict + evidence-standard citations throughout, per D-12"
        status: pass
    human_judgment: true
    rationale: "The plan's own <verify> block includes a human-check: 'Read 009/README.md and 011/README.md as a Phase 19/20/23 planner who has read nothing else. Confirm the hook matrix tells you which hooks you may build on per pairing, that the soak result is stated per cell rather than averaged, and that every claim is one you could re-run from the text alone.' This is a legibility/usefulness judgment a human downstream planner should confirm, not an automated assertion."
  - id: D4
    description: "SPIKE-04's zero-lock-errors/zero-missed-completions bar is graded per cell with observed numbers, and the completions/ground-truth delta is investigated rather than left as an uninterpreted number"
    requirement: SPIKE-04
    verification:
      - kind: manual_procedural
        ref: "soak-summary.md ## Reading the completions/ground-truth delta and ## D-04's bar, graded honestly, per cell — traced individual runIds against transcript_events (5 rows for one llm_output fire, 3 for another), confirming a granularity mismatch rather than a lock-contention miss"
        status: pass
    human_judgment: true
    rationale: "Whether the investigated granularity-mismatch explanation is sufficient to avoid recording D-04 as a straightforward FAIL (rather than the more nuanced 'not cleanly measurable as designed' this SUMMARY records) is a judgment call about how strictly to read the plan's literal 'zero missed completions' wording against evidence that shows no actual loss. A human should confirm this reasoning is sound before Phase 19 treats HOST-LOCAL's concurrency behavior as settled."

duration: 1h 47min
completed: 2026-09-24
status: complete
---

# Phase 17 Plan 05: Hook-Firing Matrix & Concurrency Soak Summary

**Twelve-cell SPIKE-02 hook matrix and SPIKE-04's concurrency soak, both graded PARTIAL: all six D-08 hooks fired live on the standalone OpenClaw + Claude pairing over a real 62-tick, 61-minute per-minute soak with zero lock errors, but the NemoClaw/OpenShell sandbox never became reachable during this plan's entire execution window — leaving the B-05 question, the SSHFS soak cell, and NEMO-03 all entirely unrun and carried forward, unresolved, to Phase 19/22.**

## Performance

- **Duration:** 1h 47min
- **Started:** 2026-09-24T14:52:15Z (approx., first live-host probe)
- **Completed:** 2026-09-24T16:39:00Z
- **Tasks:** 3
- **Files created:** 10

## Accomplishments

- Built `probe-hook-observer/`, an observer plugin registering exactly the six D-08 hooks (`before_prompt_build`, `after_tool_call`, `before_agent_finalize`, `subagent_spawned`, `subagent_ended`, `session_end`), with payload field shapes ground-truthed live from the installed OpenClaw package's own `.d.ts`, mirroring the proven packaging shape from spike 006/plan 17-04
- Installed the observer with real provenance on the HOST-LOCAL standalone pairing and exercised both `allowPromptInjection` permission configurations — confirmed live that omitting the permission entirely still let `before_prompt_build` fire, matching the documented default-allowed behavior
- Ran a real per-minute crontab-driven concurrency soak for 62 consecutive ticks (61 minutes) on the HOST-LOCAL cell: zero lock/`SQLITE_BUSY` errors, zero non-zero return codes, on every single tick — fixed two live-host bugs (a `date +%s%3N` epoch-millis format bug and a `sqlite3 -cmd` PRAGMA-output-ordering quirk) discovered mid-deployment before the real soak began
- Drove a shared live-traffic window covering both spikes at once: tool-calling turns, two independent subagent spawn/end pairs (one clean completion, one killed by timeout — two distinct `subagent_ended` outcomes observed live), and two `session_end` fires (`reason="deleted"`), confirming all six hooks fire on this pairing with full payload-key evidence
- Investigated the soak's completions/ground-truth numeric delta directly against raw SQLite evidence rather than reporting it uninterpreted — traced individual `runId`s and found a genuine measurement-granularity mismatch between the two mechanisms, not a lock-contention-caused loss (the opposite signature of what D-04's bar is worried about)
- Confirmed live, from the OpenClaw package's own type declarations and a dynamic content scan, that upstream issue #155696 is confirmed (not retired) for this pairing: `session_end`'s payload carries no message content field at all
- Wrote both determinations (`009/README.md`, `011/README.md`) as `PARTIAL` verdicts, stating plainly — never weakened, never inferred — that the sandbox pairing's entire hook matrix, the SSHFS soak cell, the B-05 question, and NEMO-03 all remain unanswered because the NemoClaw sandbox `revenium-2-0` stayed `Phase: Error` for this plan's entire execution window (reconfirmed at both Task 1's start and immediately after the soak completed)

## Task Commits

Each task was committed atomically:

1. **Task 1: Hook-observer plugin covering all six D-08 hooks, installed on both pairings** - `59df82a` (feat)
2. **Task 2: Run the shared live-traffic window — hook observation and the concurrency soak together** - `347bd21` (feat)
3. **Task 3: Write the SPIKE-02 and SPIKE-04 determinations** - `4d55a05` (docs)

## Files Created/Modified

- `.planning/spikes/009-hook-firing-matrix-2-0/probe-hook-observer/package.json` - Plugin packaging (type=module, main, openclaw.extensions)
- `.planning/spikes/009-hook-firing-matrix-2-0/probe-hook-observer/openclaw.plugin.json` - Plugin manifest (id, activation.onStartup, configSchema)
- `.planning/spikes/009-hook-firing-matrix-2-0/probe-hook-observer/index.js` - Registers exactly the six D-08 hooks, structural-metadata-only records
- `.planning/spikes/009-hook-firing-matrix-2-0/hook-fire-log.txt` - Labelled raw evidence: HOST-LOCAL/Config-A, HOST-LOCAL/Config-B, SANDBOX (not run)
- `.planning/spikes/009-hook-firing-matrix-2-0/hook-matrix.md` - Six-hook x two-pairing table with fired/UNRUN cells and payload-key evidence
- `.planning/spikes/009-hook-firing-matrix-2-0/README.md` - SPIKE-02 determination (verdict PARTIAL)
- `.planning/spikes/011-read-path-concurrency-soak/soak-tick.sh` - Per-minute cron tick reusing cron.sh's flock discipline, no retry wrapper
- `.planning/spikes/011-read-path-concurrency-soak/soak-log.txt` - 62 tick records, HOST-LOCAL cell, zero lock errors
- `.planning/spikes/011-read-path-concurrency-soak/soak-summary.md` - Per-cell totals plus the investigated completions/ground-truth delta
- `.planning/spikes/011-read-path-concurrency-soak/README.md` - SPIKE-04 determination (verdict PARTIAL)

## Decisions Made

See `key-decisions` in frontmatter for the full list. Summary: ran a genuine 61-minute real-time per-minute crontab soak rather than any compressed substitute; started the standalone Gateway in the foreground (scoped to that pairing only) to unblock subagent-spawn testing after embedded execution refused it; investigated rather than assumed the meaning of the soak's completions/ground-truth numeric mismatch, tracing it to a measurement-granularity difference rather than a lock-contention miss; graded both SPIKE-02 and SPIKE-04 as PARTIAL, with the both-pairings/both-cells gaps stated plainly rather than weakened.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Plan's literal provenance verify command required a per-plugin argument**
- **Found during:** Task 1 (confirming observer provenance)
- **Issue:** The plan's verify command (`openclaw plugins inspect` with no argument) fails on this OpenClaw build: `Provide a plugin id or use --all.`
- **Fix:** Ran `openclaw plugins inspect revenium-hook-observer` (the actual plugin id) instead — confirmed provenance (`Trust: reason=origin-path`) and satisfied the verify's intent (count >= 1 for `provenance|installed`, case-insensitive)
- **Files modified:** None (verification-command adaptation only, documented in 009/README.md's Investigation Trail)
- **Verification:** `openclaw plugins inspect revenium-hook-observer | grep -ci 'provenance\|installed'` → 1
- **Committed in:** `59df82a` (Task 1 commit)

**2. [Rule 1 - Bug] `date +%s%3N` produced a 19-digit garbage epoch-millis value on this host's GNU date build**
- **Found during:** Task 2 (first soak-tick.sh deployment)
- **Issue:** `soak-tick.sh` used `date +%s%3N` expecting a 13-digit millisecond epoch; live testing produced 19-digit garbage (e.g. `1790263618989950582`), corrupting every `duration_ms` field
- **Fix:** Switched to plain `date +%s%N` (nanoseconds, which is clean on this build) and divided by 1,000,000 in the script for milliseconds
- **Files modified:** `.planning/spikes/011-read-path-concurrency-soak/soak-tick.sh`
- **Verification:** Re-deployed and confirmed `duration_ms` values are sane (123-707ms range) across all 62 post-fix ticks
- **Committed in:** `347bd21` (Task 2 commit — the fix is in the committed script; the pre-fix corrupted log was archived host-side, not committed)

**3. [Rule 1 - Bug] This host's `sqlite3 -cmd` batch mode echoes the PRAGMA setter's own value ahead of the SELECT result**
- **Found during:** Task 2 (same deployment as above)
- **Issue:** `sqlite3 -cmd "PRAGMA busy_timeout=5000;" "file:...?mode=ro" "SELECT count(*) ..."` printed two lines (`5000` then the actual count), and the script's original `out=$(...)` capture treated the whole multi-line string as the count, always failing the `^[0-9]+$` regex and silently defaulting to `completions=0`
- **Fix:** Changed the script to take the LAST non-empty output line via `tail -n1` as the actual count, documented inline as a build-specific quirk
- **Files modified:** `.planning/spikes/011-read-path-concurrency-soak/soak-tick.sh`
- **Verification:** Manual `sqlite3` test confirmed the two-line output pattern; post-fix ticks show correct, monotonically non-decreasing completion counts
- **Committed in:** `347bd21` (Task 2 commit)

**4. [Rule 3 - Blocking] Embedded `--local` execution refused `sessions_spawn` with "published reply runtime missing for dev"**
- **Found during:** Task 2 (attempting to generate a subagent-spawn turn for the shared traffic window)
- **Issue:** `openclaw agent --agent dev --local ...` failed the `sessions_spawn` tool call validation and then errored with a live-host-specific message indicating the embedded/`--local` execution path lacks the async reply-routing runtime subagent completion needs
- **Fix:** Started the standalone Gateway in the foreground (`openclaw gateway run`, no OS service installed — no systemd/launchd changes, scoped strictly to the standalone pairing) and retried the same turn through it (non-`--local`, explicit `--model` since the gateway's default model has no configured auth). The gateway-routed retry succeeded; `subagent_spawned`/`subagent_ended` both fired
- **Files modified:** None (host-side runtime state only; no repository change)
- **Verification:** `hook-fire-log.txt` records two full subagent spawn/end pairs captured after this fix
- **Committed in:** `347bd21` (Task 2 commit — the fix is a host-side action documented in `009/README.md`'s Investigation Trail, not a code change)

---

**Total deviations:** 4 auto-fixed (1 blocking-verification-adaptation, 2 bugs, 1 blocking-runtime-workaround). **Impact:** No scope creep. All four were necessary to produce real evidence rather than a stalled or corrupted probe; none touched `plugin/`, `plugin-nemoclaw/`, or `scripts/`, and none touched the NemoClaw sandbox.

## Issues Encountered

- **The NemoClaw sandbox `revenium-2-0` remained `Phase: Error` for this plan's entire execution window** — confirmed at Task 1's start and re-confirmed immediately after the soak completed (16:29Z). Per `17-SANDBOX-BLOCKER.md`, not attempted, not repaired, not routed around via `docker exec`. Consequence: the entire sandbox column of the hook matrix, the B-05 question, the SSHFS soak cell, and NEMO-03 are all UNRUN, carried forward unresolved to Phase 19/22 — the single largest open item this plan leaves behind.
- **Two of Task 2's plan-authored automated `<verify>` checks fail literally, as an expected and documented consequence of the sandbox blocker, not a defect:** `grep -c '^tick ' soak-log.txt` returns 62 (plan's literal bar: >= 120, i.e. >= 60 per cell x 2 cells) and the distinct-`cell=` check returns 1 (plan's literal bar: >= 2). Both bars assume both cells run; only HOST-LOCAL could. This is recorded here explicitly rather than silently passed over, per the executor's own instruction to log an unsatisfiable criterion with its reason rather than skip it silently. The HOST-LOCAL cell alone clears its own 60-tick minimum (62 ticks) with zero lock errors.
- **The completions/ground-truth numeric delta (56 vs. 18) initially looked like a possible missed-completion signal** — investigated directly rather than assumed; traced to a genuine measurement-granularity mismatch between the two mechanisms (see `soak-summary.md`), not a lock-contention-caused loss. See `key-decisions` for the full reasoning.
- **The standalone Gateway (started via `openclaw gateway run` in the foreground for Task 2) is still running on the host** — not stopped as part of this plan's teardown, since the plan's explicit teardown instruction covered only the soak's crontab entry (removed, confirmed via `crontab -l`). This is host-side runtime state, not a repository artifact; flagged here for visibility, not treated as requiring action from this plan.

## Known Stubs

None. Every recorded fact in `hook-matrix.md`, `hook-fire-log.txt`, `soak-log.txt`, and `soak-summary.md` reflects real, live-host-observed commands and output. The sandbox pairing and SSHFS cell are recorded as "not run" with the exact blocking evidence cited (`nemoclaw revenium-2-0 status` → `Phase: Error`, re-confirmed twice), never as fabricated or inferred results, per the phase's own prohibition against recording a verdict for an unrun probe.

## User Setup Required

None. Credentials continued to be sourced from the host-side `/home/ubuntu/.spike-17.env` (mode 600) established in plan 17-01; no key value was read into this session's context, echoed, or transported off the host. Verified via a credential-pattern grep across every committed artifact in this plan — zero matches.

## Next Phase Readiness

- SPIKE-02 is answerable from `009/README.md` alone: a twelve-cell matrix (six fired live, six UNRUN), the both-pairings provenance bar stated as unmet, the `allowPromptInjection` side observation, and #155696's confirmed-for-this-pairing answer.
- SPIKE-04 is answerable from `011/README.md` alone: HOST-LOCAL's zero-lock-errors pass, the investigated (not assumed) completions/ground-truth delta, and the SSHFS cell's UNRUN status with NEMO-03 stated as unanswered.
- **Carry-forward for Phase 19/22 (required pre-build step, not optional):** re-run this plan's `probe-hook-observer/` install sequence and `soak-tick.sh` (with `CELL=SSHFS`) against the NemoClaw sandbox pairing once it recovers per `17-SANDBOX-BLOCKER.md` — this closes both the B-05 question and NEMO-03, neither of which any prior plan in this phase has answered either.
- **Carry-forward for Phase 19:** the production read layer needs a precisely-defined "one completion" unit (dedupe by `responseId` or an equivalent structural key) rather than a raw `COUNT(*)` of assistant-role transcript rows, which this plan found can be 1:5 relative to actual top-level agent turns.
- **Carry-forward for Phase 19/20:** `allowPromptInjection` need not be explicitly granted for `before_prompt_build` to fire on OpenClaw `2026.9.6`; PLUG-02 should still set it explicitly for forward-compatibility, but is not blocked by its current absence.
- No blockers for the next plan in this phase; this plan's gaps are all forward-carried, evidence-backed open items, not silent unknowns. This is the phase's last plan gated on live-host sandbox access — the sandbox blocker is now the single item standing between this phase's determinations and full (not partial) SPIKE-02/SPIKE-04 verdicts.

---
*Phase: 17-live-host-fact-finding-spike*
*Plan: 05*
*Completed: 2026-09-24*

## Self-Check: PASSED

All 10 created files verified present on disk via `[ -f ]`:
`probe-hook-observer/package.json`, `probe-hook-observer/openclaw.plugin.json`,
`probe-hook-observer/index.js`, `009/hook-fire-log.txt`, `009/hook-matrix.md`,
`009/README.md`, `011/soak-tick.sh`, `011/soak-log.txt`, `011/soak-summary.md`,
`011/README.md`. All three task commits (`59df82a`, `347bd21`, `4d55a05`)
verified present via `git log --oneline`. Plan-level `<verification>` re-run:
`index.js` registers exactly 6 `api.on(` calls (before_prompt_build,
after_tool_call, before_agent_finalize, subagent_spawned, subagent_ended,
session_end), no others; `openclaw.plugin.json` carries `id`/`activation`/
`configSchema` (Node manifest check passes); `hook-matrix.md` has one row per
D-08 hook and two pairing columns; `soak-summary.md` names both `HOST-LOCAL`
and `SSHFS` and reports them separately (never averaged); `009/README.md` and
`011/README.md` each carry a `spike:` number and a three-state `verdict:`
line; `009/README.md` matches `155696` (6 occurrences) and states the
confirmed-for-this-pairing finding explicitly; `git diff --name-only HEAD --
plugin plugin-nemoclaw scripts` (against the pre-Task-1 base) returns empty.
A credential-pattern grep (`sk-ant-`, `nvapi-`, `REVENIUM_API_KEY=`,
`"api-key":`) across every file changed in this plan's three commits returned
zero matches. `soak-log.txt` contains exactly 62 `^tick ` records, all
`cell=HOST-LOCAL`, `lock_errors=0`, `rc=0` — the two plan-authored automated
checks requiring >=120 total ticks / >=2 distinct cells fail literally, as
documented above under Issues Encountered (expected consequence of the
sandbox blocker, not a defect).
