---
phase: 17-live-host-fact-finding-spike
plan: "04"
subsystem: infra
tags: [spike, live-host, plugin, sidecar, llm_output, after_tool_call, fidelity, determination]

requires:
  - phase: 17-03
    provides: "Candidates (a) direct SQLite read and (b) openclaw sessions CLI surfaces graded against the four D-02 fidelity fields on both cells, plus D-03's live ground-truth session-id resolution test"
provides:
  - "Candidate (c), the plugin-hook sidecar, built from a sanctioned packaging shape (mirroring spike 006's proven package.json/openclaw.plugin.json packaging plus the register(api)/api.on(hookName, handler) shape), installed with real provenance on the HOST-LOCAL pairing, and measured live: full fidelity on token usage and model id, partial on toolCalls (metadata only, by design), confirmed-structurally-absent on session parentage"
  - "SPIKE-01's fidelity-first ranking across all three candidates: (a) direct SQLite read wins on a tie-break over (b) export-trajectory (CLI-agent-registry scoping + per-tick I/O favor (a)); (c) sidecar does not win as measured"
  - "008/README.md — the consumable SPIKE-01 determination carrying both the content-read ranking and D-03's session-id resolution answer, with the both-pairings provenance bar stated plainly as UNMET"
affects: [19-session-read-path, 22-nemoclaw-openshell-path-on-2-0]

actuals:
  tokens: 11025
  tasks: 2
  commits: 2

tech-stack:
  added: []
  patterns:
    - "Plugin-hook sidecar packaging: mirror a real compiled plugin's register(api)/api.on(hookName, handler) shape rather than openclaw plugins init's --type feature scaffold, which produces a typebox tool-contract plugin unsuited to raw hook observation"
    - "Ground-truth hook-payload typing: read the field names directly from the live host's installed openclaw package's own .d.ts rather than inferring from docs or prior spikes, to de-risk a hand-authored hook plugin"
    - "Server-side-only credential sourcing for live-host turn-driving: `set -a; . ~/.spike-17.env; set +a` in the same SSH command as the invocation, never echoed or transported off the host"

key-files:
  created:
    - .planning/spikes/008-sqlite-session-read-path/probe-sidecar-plugin/package.json
    - .planning/spikes/008-sqlite-session-read-path/probe-sidecar-plugin/openclaw.plugin.json
    - .planning/spikes/008-sqlite-session-read-path/probe-sidecar-plugin/index.js
    - .planning/spikes/008-sqlite-session-read-path/sidecar-capture.jsonl
    - .planning/spikes/008-sqlite-session-read-path/fidelity-matrix.md
    - .planning/spikes/008-sqlite-session-read-path/README.md
  modified: []

key-decisions:
  - "Candidate (c)'s packaging mirrors spike 006's proven shape (plain ESM index.js, register(api)/api.on) rather than openclaw plugins init's --type feature scaffold, because the feature scaffold's defineFeaturePlugin/typebox-contract shape does not support raw hook registration at all — confirmed live on the host before committing to a shape."
  - "Ranking winner: candidate (a) direct SQLite read, on a tie-break over (b) export-trajectory. Both are zero-loss on token usage/model id/toolCalls; (a) wins because (b) is CLI-agent-registry-scoped (silently blind to an unregistered agent — exactly the kind of silent omission D-02 warns a fidelity ranking must not reward) and writes 7 files to disk per invocation, versus a read-only query that writes nothing."
  - "Session parentage is recorded as unmet by ALL THREE candidates with live-confirmed data — not silently folded into a positive verdict for the winner, and not used to declare 'no candidate clears the bar' either, since candidate (a)'s schema-present-but-unexercised position is genuinely stronger evidence than candidate (b)'s ungraded state or candidate (c)'s confirmed-absent state. An explicit Phase 19 pre-build confirmation step (drive a real subagent-spawning turn, confirm the parentage columns populate) is named as a required follow-up, not an optional nice-to-have."
  - "Candidate (c) does not win the ranking as measured — it is full on usage/model, partial on toolCalls (by design, T-17-05 hygiene), and the two hooks registered (llm_output, after_tool_call) structurally cannot deliver session parentage at all, confirmed against the live OpenClaw 2026.9.6 plugin SDK's own type declarations. Its drift-resistance is recorded as a ranking input per the task's instruction, not elevated to change the outcome."
  - "The plan's both-pairings provenance bar ('installed via openclaw plugins install on both pairings and openclaw plugins inspect reports provenance on each') is UNMET, stated plainly, not weakened to standalone-only and not marked satisfied. nemoclaw revenium-2-0 status returned exit 1 (Phase: Error) before this task began — a pre-existing, operator-owned host-recovery item per 17-SANDBOX-BLOCKER.md. The B-05 check (after_tool_call firing for Nemotron's tool_search_code-routed exec calls) — the single most consequential question candidate (c) was positioned to answer — is therefore UNRUN, not answered either way."
  - "A live auth-store gap was hit driving candidate (c)'s HOST-LOCAL turns (agent 'dev' had zero configured auth profiles despite a working turn on the same agent earlier the same day, per 17-03's own evidence) — resolved by sourcing ANTHROPIC_API_KEY server-side from the host's mode-600 credential file directly into the openclaw agent invocation, without any config-store repair. Symptoms observed alongside it (SQLite session-reclamation 'database owner is no longer current') are consistent with concurrent write activity from a sibling wave-4 plan on the shared host (D-13's named risk) and were not investigated further, since sourcing the credential resolved it for this task's purposes."

requirements-completed: [SPIKE-01]

coverage:
  - id: D1
    description: "Candidate (c), the plugin-hook sidecar, built from a sanctioned scaffold/mirrored-shape and installed with real provenance on the HOST-LOCAL pairing"
    requirement: SPIKE-01
    verification:
      - kind: manual_procedural
        ref: "sidecar-capture.jsonl — `openclaw plugins inspect revenium-sidecar-probe` output quoted verbatim (Status: enabled, Trust: reason=origin-path, no inert-hooks warning), plus two real live turns' capture records showing both hooks fired"
        status: pass
    human_judgment: false
  - id: D2
    description: "Candidate (c) graded against all four D-02 fidelity fields on the HOST-LOCAL pairing; SANDBOX pairing recorded as not run with the exact blocking reason, not inferred"
    requirement: SPIKE-01
    verification:
      - kind: manual_procedural
        ref: "fidelity-matrix.md and sidecar-capture.jsonl — usage/model RECOVERABLE, toolCalls PARTIAL (by design), session parentage ABSENT (confirmed against live .d.ts, not inferred); SANDBOX cell NOT RUN with the nemoclaw status exit-1/Phase:Error evidence cited"
        status: pass
    human_judgment: false
  - id: D3
    description: "All three candidates ranked fidelity-first per D-02, with the tie-break named explicitly and the drift-resistance observation recorded as an input"
    requirement: SPIKE-01
    verification:
      - kind: manual_procedural
        ref: "fidelity-matrix.md ## Ranking and ## Tie-break sections — (a) wins over (b) on CLI-agent-registry-scoping + per-tick I/O; (c) ranked third with the specific field-level reasons named"
        status: pass
    human_judgment: true
    rationale: "The ranking call on session parentage (treating candidate (a)'s schema-present-but-unexercised columns as a stronger evidentiary position than 'the bar is unmet by all three, escalate') is a judgment call within the phase's own stated discretion ('the escalation path if no read candidate clears the fidelity bar' is explicitly Claude's Discretion per CONTEXT.md). A human should confirm this reasoning — that structural column presence is meaningfully different from candidate (c)'s confirmed structural absence — is sound before Phase 19 treats (a) as the settled winner rather than reopening the ranking."
  - id: D4
    description: "008/README.md carries both of D-03's determinations (content read AND current-session-id resolution) in two clearly separated Results sub-sections, with the both-pairings provenance bar and the B-05 unrun status stated plainly"
    requirement: SPIKE-01
    verification:
      - kind: manual_procedural
        ref: "README.md ## Results §1 (Content read) and §2 (Current-session-id resolution) — both present, both named against schema-capture.sql.txt / session-id-resolution.txt evidence, both-pairings bar and B-05 status stated in prose under §1, not left implicit"
        status: pass
    human_judgment: false

duration: 47min
completed: 2026-09-24
status: complete
---

# Phase 17 Plan 04: Sidecar Capture Candidate & SPIKE-01 Determination Summary

**Direct SQLite read (candidate a) wins SPIKE-01's fidelity ranking on a tie-break over `export-trajectory`; the plugin-hook sidecar (candidate c) is real, installed with provenance, and measured, but does not win, and its NemoClaw-pairing evidence is entirely unrun because the sandbox was already down before this task began.**

## Performance

- **Duration:** 47 min
- **Started:** 2026-09-24T14:00:00Z (approx.)
- **Completed:** 2026-09-24T14:47:29Z
- **Tasks:** 2
- **Files created:** 6

## Accomplishments

- Built candidate (c), the plugin-hook sidecar, mirroring spike 006's proven packaging (not `openclaw plugins init`'s `--type feature` scaffold, which was tried live first and found to produce an incompatible tool-contract plugin type) and grounding every hook-payload field name in the live host's own installed `openclaw` package `.d.ts` rather than guessing
- Installed the sidecar on the HOST-LOCAL standalone pairing with real, confirmed provenance (`openclaw plugins inspect` — no inert-hooks warning) and drove two real live turns; both `llm_output` and `after_tool_call` fired cleanly, capturing full-fidelity token usage and model id, and partial (metadata-only, by design) toolCall detail
- Confirmed, by reading the live plugin SDK's own type declarations, that the two hooks registered structurally cannot deliver session-parentage data at all — a definitive negative finding, not an inference
- Ranked all three SPIKE-01 candidates fidelity-first: (a) direct SQLite read and (b) `export-trajectory` tie on the three fully-tested fields, with (a) winning the tie-break on CLI-agent-registry-scoping and per-tick I/O footprint; (c) ranks third as measured
- Wrote `008/README.md`, the consumable SPIKE-01 determination carrying both D-03 answers (content-read ranking and current-session-id resolution), stating the both-pairings provenance bar as explicitly UNMET rather than weakened or silently satisfied
- Recorded session parentage honestly as unconfirmed by all three candidates with live data, distinguishing candidate (a)'s schema-present-but-unexercised position from candidate (c)'s confirmed-absent position, and named an explicit Phase 19 pre-build confirmation step rather than either fabricating a pass or stalling the whole determination

## Task Commits

Each task was committed atomically:

1. **Task 1: Build, install and measure the sidecar capture candidate** - `7e3acba` (feat)
2. **Task 2: Rank the three candidates and write the SPIKE-01 determination** - `635e730` (docs)

## Files Created/Modified

- `.planning/spikes/008-sqlite-session-read-path/probe-sidecar-plugin/package.json` - Plugin packaging (type=module, main, openclaw.extensions)
- `.planning/spikes/008-sqlite-session-read-path/probe-sidecar-plugin/openclaw.plugin.json` - Plugin manifest (id, activation.onStartup, mandatory configSchema)
- `.planning/spikes/008-sqlite-session-read-path/probe-sidecar-plugin/index.js` - Registers exactly `llm_output` and `after_tool_call`, appends structural-only records
- `.planning/spikes/008-sqlite-session-read-path/sidecar-capture.jsonl` - Live capture evidence, labelled per pairing (HOST-LOCAL full, SANDBOX recorded not-run)
- `.planning/spikes/008-sqlite-session-read-path/fidelity-matrix.md` - Three-candidate x four-field comparison table with cell column and tie-break reasoning
- `.planning/spikes/008-sqlite-session-read-path/README.md` - SPIKE-01 determination: both D-03 answers, evidence-backed

## Decisions Made

See `key-decisions` in frontmatter for the full list. Summary: candidate (a) direct SQLite read wins the content-read ranking on a tie-break over candidate (b)'s `export-trajectory`; candidate (c) the sidecar does not win as measured (Phase 19's shape stays a read-path port, not a capture path); session parentage is honestly recorded as unconfirmed by all three candidates rather than glossed into a false pass; the both-pairings provenance bar is stated plainly as unmet; and a live host auth-store gap (likely caused by concurrent sibling-plan activity on the shared host) was worked around by sourcing the credential server-side rather than repairing any config store.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Sourced ANTHROPIC_API_KEY server-side to unblock turn-driving after a live auth-store gap**
- **Found during:** Task 1 (driving the first live turn to exercise the sidecar's hooks)
- **Issue:** `openclaw agent --agent dev --local ...` failed with `No API key found for provider "anthropic"` even though 17-03's own evidence shows a working turn on the same agent earlier the same day — the CLI output additionally showed `"SQLite session reclamation database owner is no longer current"`, consistent with concurrent write activity from a sibling wave-4 plan on this shared host.
- **Fix:** Sourced `ANTHROPIC_API_KEY` from the host-side mode-600 `/home/ubuntu/.spike-17.env` file directly in the same SSH command as the `openclaw agent` invocation (`set -a; . ~/.spike-17.env; set +a; openclaw agent ...`), per the live-host credential binding. No config-store repair, no `openclaw doctor --fix`, was attempted.
- **Files modified:** None (no repository or persistent host-config change — a one-shot env override at invocation time)
- **Verification:** The turn completed successfully immediately after (`winnerModel: claude-sonnet-4-6`, `stopReason: stop`), and both sidecar hooks fired, confirmed in `sidecar-capture.jsonl`.
- **Committed in:** `7e3acba` (Task 1 commit) — the workaround is documented in `README.md`'s Investigation Trail, not a code change

---

**Total deviations:** 1 auto-fixed (1 blocking). **Impact:** No scope creep — the fix was a one-shot, non-persistent invocation-time env override that unblocked evidence-gathering without touching any config store other Wave 4 sibling plans might depend on.

## Issues Encountered

- **The NemoClaw sandbox `revenium-2-0` was unavailable before this task began** (`nemoclaw revenium-2-0 status` → exit 1, `Phase: Error`) — confirmed live at the start of this task, matching `17-SANDBOX-BLOCKER.md` exactly. Per the binding, this was not attempted, not repaired, and not routed around via `docker exec`. Consequence: candidate (c) has zero evidence on the NemoClaw pairing, and the B-05 check (whether `after_tool_call` fires for Nemotron's `tool_search_code`-routed exec calls) is entirely unrun — the single most consequential open item this plan leaves for Phase 19/22.
- **A live auth-store gap on the standalone pairing's "dev" agent** — see Deviations above. Not a sidecar-mechanism failure; resolved without persistent state changes.

## Known Stubs

None. All artifacts reflect real, live-host-observed commands and output. The SANDBOX pairing's "not run" status is recorded as an open question with its exact blocking evidence cited, never as a fabricated or inferred result, per the phase's own prohibition against recording a verdict for an unrun probe.

## User Setup Required

None. Credentials continued to be sourced from the host-side `/home/ubuntu/.spike-17.env` (mode 600) established in plan 17-01; no key value was read into this session's context, echoed, or transported off the host.

## Next Phase Readiness

- SPIKE-01 is fully answerable from `008/README.md` alone: the content-read winner (candidate a, direct SQLite read), the tie-break reasoning against candidate (b), why candidate (c) does not win, and D-03's session-id resolution answer (`session_nodes.created_via != 'cron'`, named against all four production resolvers plus `get-root-session-id.py`).
- **Carry-forward for Phase 19 (required pre-build step, not optional):** drive a real subagent-spawning turn on the standalone pairing and confirm `session_windows`/`session_nodes` parentage columns (`parent_session_key`, `spawned_by`, `fork_source_session_key`, `fork_source_session_id`) populate correctly before any parent/child rollup logic depends on them — no candidate in this spike confirmed this field with live data.
- **Carry-forward for Phase 19:** confirm live that `session_nodes.created_via` is actually set to `'cron'` by an OpenClaw-internal cron-scheduled turn (not a manually-invoked one) — no such session existed on this host to test against.
- **Carry-forward for Phase 19/22 (NemoClaw path):** candidate (c)'s entire SANDBOX-pairing evidence set, including the B-05 check, is unrun and blocked on the sandbox's `AUTH_PROFILE_MIGRATION_REQUIRED`/`Phase: Error` recovery (operator-owned, per `17-SANDBOX-BLOCKER.md`). Once recovered, Task 1's exact install/enable/drive sequence in this plan's `README.md` `## How to Run` is directly re-runnable against the sandbox pairing.
- No blockers for the next plan in this phase; this plan's gaps are all forward-carried, evidence-backed open items, not silent unknowns.

---
*Phase: 17-live-host-fact-finding-spike*
*Plan: 04*
*Completed: 2026-09-24*

## Self-Check: PASSED

All 6 spike artifacts (probe-sidecar-plugin/package.json, probe-sidecar-plugin/openclaw.plugin.json,
probe-sidecar-plugin/index.js, sidecar-capture.jsonl, fidelity-matrix.md, README.md) plus this
SUMMARY.md verified present on disk via `[ -f ]`. Both commits (7e3acba, 635e730) verified present
in `git log --oneline`. Plan-level `<verification>` re-run:
`node -e "require('./openclaw.plugin.json')"` confirms `id`/`activation`/`configSchema` present;
`node -e "require('./package.json')"` confirms `type: module`/`main`/`openclaw.extensions` array;
`index.js` registers exactly two `api.on(` calls (`llm_output`, `after_tool_call`), no others;
`sidecar-capture.jsonl` is non-empty (135 lines) with labelled `PAIRING: HOST-LOCAL` and
`PAIRING: SANDBOX` header blocks; `fidelity-matrix.md` matches all four D-02 field terms 7 times;
`README.md` matches `spike: 008` + a three-state `verdict:` line (2 matches), the four production
resolvers plus `get-root-session-id.py` (8 matches), and `52.90.9.242` (1 match); `git diff
--name-only HEAD -- plugin plugin-nemoclaw` returns empty. A grep across
`.planning/spikes/008-sqlite-session-read-path/` for the driven-turn marker strings used in this
plan's own probing (`SIDECAR_TURN_OK`, `SIDECAR_ERROR_TURN_OK`, `Reply with exactly`, `Run the
shell command`) returned no matches, confirming the redaction fix applied during this task holds.
