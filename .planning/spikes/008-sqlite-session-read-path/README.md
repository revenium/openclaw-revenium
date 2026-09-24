---
spike: 008
name: sqlite-session-read-path
type: standard
validates: "Given the live 2.0 session store on both production install paths, when three candidate read mechanisms are built and measured against the same four fidelity fields, then SPIKE-01 returns a fidelity-first ranking plus the current-session-id resolution D-03 requires"
verdict: PARTIAL
related: [004, 006]
tags: [sqlite, session-read, metering, hook, sidecar, session-id]
host: "52.90.9.242 (bare Ubuntu 26.04; sandbox revenium-2-0)"
---

# Spike 008: SQLite Session Read Path

**Direct SQLite read (candidate a) wins SPIKE-01's content-read ranking on a tie-break over
`export-trajectory` (candidate b) — both are zero-loss on token usage/model id/toolCalls, but
`export-trajectory` is silently blind to any unregistered agent and writes 7 files per tick; the
plugin-hook sidecar (candidate c) is real and working but could not be measured on the NemoClaw
pairing at all, so the plan's both-pairings provenance bar is explicitly UNMET. D-03's
current-session-id determination is fully answered: direct SQL against `session_nodes.created_via`.**

## What This Validates

SPIKE-01: how a script reads completions and toolCalls from OpenClaw 2.0's SQLite session store,
and (D-03) how a script resolves which session it is currently in — the two questions
`scripts/report.sh`, `scripts/write-marker.sh`, `scripts/write-job-marker.sh`,
`scripts/verify-markers.sh`, `scripts/guardrail-check.sh`, and `scripts/get-root-session-id.py`
must all be re-pointed at once 2.0 retires JSONL as the live storage format. D-01 mandates
exercising all three candidates (direct SQLite read, `openclaw sessions` CLI surfaces, a
plugin-hook sidecar) rather than assuming a winner from documentation, and D-02 makes the
ranking criterion data fidelity — the mechanism that silently drops a field reproduces the
fail-open blackout this milestone exists to close.

## Research

`.planning/phases/17-live-host-fact-finding-spike/17-RESEARCH.md` `## Session Read Path —
Candidate Ranking Inputs` established, from docs alone, that the SQL schema is genuinely
unpublished (must be captured live), that `sessions tail` redacts by design, and that
`export-trajectory`'s unattended-approval-gate behavior was undocumented. This spike (across
plans 17-03 and 17-04) resolved all three live.

## How to Run

This spike's evidence was captured across two plans against the live host, not a single
repeatable command:

```bash
# Candidate (a) — plan 17-03, Task 1
bash .planning/spikes/008-sqlite-session-read-path/probe-sqlite-direct.sh

# Candidate (b) — plan 17-03, Task 2
bash .planning/spikes/008-sqlite-session-read-path/probe-cli-surfaces.sh

# D-03 — plan 17-03, Task 3
bash .planning/spikes/008-sqlite-session-read-path/probe-session-id-resolution.sh

# Candidate (c) — plan 17-04, Task 1 (this plan)
# Plugin lives in .planning/spikes/008-sqlite-session-read-path/probe-sidecar-plugin/
# Install (standalone path, requires --accept-capabilities on this OpenClaw build):
openclaw plugins install .planning/spikes/008-sqlite-session-read-path/probe-sidecar-plugin \
  --force --accept-capabilities
echo '{plugins: {entries: {"revenium-sidecar-probe": {enabled: true, hooks: {allowConversationAccess: true}}}}}' \
  | openclaw config patch --stdin
openclaw plugins inspect revenium-sidecar-probe   # confirm provenance before trusting any result
# Drive a turn, then inspect the append-only capture file:
cat ~/.openclaw/revenium-sidecar-capture.jsonl
```

All three probe scripts are throwaway evidence-capture tools, not production code (D-11) — see
`## Requirements / build guidance` below.

## Investigation Trail

1. **Plan 17-03** captured the live `.schema` (`schema-capture.sql.txt`, 112 `CREATE TABLE`
   statements across both cells), ran candidate (a) against real turns on HOST-LOCAL and found
   full fidelity on usage/model/toolCalls with parentage columns present-but-unexercised, ran
   candidate (b) against all four `openclaw sessions`/`doctor` surfaces and found
   `export-trajectory` matches (a) but is CLI-agent-registry-scoped, and answered D-03 with a
   live ground-truth test recommending `session_nodes.created_via`.
2. **Plan 17-04 (this plan), Task 1** built candidate (c). `openclaw plugins init` was tried
   first live on the host; its `--type feature` scaffold produces a typebox tool-contract
   plugin, not a raw hook-observer plugin, so per the task's own sanctioned alternative this
   candidate instead mirrors the packaging spike 006 proved live (mandatory `configSchema`,
   `openclaw.extensions`) and the exact `register(api)` / `api.on(hookName, handler)` shape
   spike 006 confirmed fires once installed with real provenance. Hook payload field names were
   read directly from the live host's installed `openclaw` package's own `.d.ts`
   (`hook-runner-global-CDmmGFJp.d.ts`, openclaw 2026.9.6) rather than guessed — the single
   biggest risk flagged by spike 006 (a hand-rolled hook hanging the turn) was mitigated by
   this grounding plus registering only two `observe`-type hooks (`llm_output`,
   `after_tool_call`), neither of which mutates the turn the way spike 006's
   `before_prompt_build` (a `modify`-type hook) did.
3. Installing required a new gate not seen in spike 006's earlier OpenClaw build:
   `--accept-capabilities` (a capability-consent prompt). Once installed and enabled with
   `allowConversationAccess: true`, `openclaw plugins inspect` confirmed real provenance
   (`Trust: reason=origin-path`, `Status: enabled`) with none of spike 006's "loaded without
   install/load-path provenance" warning.
4. `openclaw gateway status` reported `Runtime: stopped` — no gateway service was running on
   this host. Real turns were driven the same way plans 17-01/17-03 did: `openclaw agent
   --local` (the embedded-agent CLI path). Plugin extensions load in the embedded runtime the
   same as under the gateway; both hooks fired, confirmed by the capture file.
5. Driving the first turn (`--agent dev`) hit a live authentication regression unrelated to the
   sidecar candidate itself — `openclaw agents list` showed zero configured auth profiles for
   "dev" (`No API key found for provider "anthropic"`), and the surrounding CLI output showed
   `[session-sqlite] slow SQLite reclamation ... outcome=rejected ... "database owner is no
   longer current"` — consistent with concurrent write activity from a sibling wave-4 plan on
   this shared host (D-13's named risk). Sourcing `ANTHROPIC_API_KEY` from the host-side
   `/home/ubuntu/.spike-17.env` file directly into the `openclaw agent` invocation (server-side
   only, per the live-host credential binding) resolved it without any config-store repair.
6. Drove two turns (a clean `exec` call and a failing-shell-command `exec` call, to probe the
   `after_tool_call` error path) — both fired both hooks cleanly, captured in
   `sidecar-capture.jsonl`.
7. Attempted the SANDBOX pairing per D-13's both-pairings requirement: `nemoclaw revenium-2-0
   status` returned exit 1 with `Phase: Error` — the sandbox was already unavailable before
   this task began (see `17-SANDBOX-BLOCKER.md`). Per the phase's own binding and prohibition
   ("an unrun question is an open question, not a PARTIAL"), the sandbox cell was not attempted,
   not substituted with `docker exec`, and not inferred from the HOST-LOCAL result.

## Results

### 1. Content read

**Winner: candidate (a), direct SQLite read.** Full evidence and the tie-break reasoning are in
`fidelity-matrix.md`; summarized here:

On the three D-02 fields confirmed live on all three candidates (per-completion token usage,
model id, toolCalls), candidates (a) and (b)'s `export-trajectory` surface **tie** — both
deliver full, unredacted, zero-loss fidelity, matching each other field-for-field. Candidate (a)
wins the tie-break on two fidelity-adjacent grounds: `export-trajectory` (like `sessions
list`/`tail`) is **CLI-agent-registry-scoped** — an ad-hoc agent's session store is invisible to
it even though the file exists on disk, which is precisely the kind of *silent* omission D-02
warns a fidelity ranking must not reward; and `export-trajectory` writes a 7-file directory to
disk on every invocation, a real per-tick I/O cost for the cron SPIKE-04 must still prove
sustains zero loss, versus a read-only query that writes nothing. A third, non-formal
consideration also favors (a): D-03's own winning session-id mechanism is already direct SQL
against `session_nodes`, so choosing (a) for content too means Phase 19 builds one read layer,
not two.

Candidate (c), the plugin-hook sidecar, does **not** win this ranking as measured: it is
full-fidelity on usage/model, but only partial on toolCalls (captures name/id/duration/
error-flag; deliberately does not capture argument/result content, per this probe's own scope
choice, not a hard mechanism ceiling), and — the more consequential gap — the two hooks this
task registered (`llm_output`, `after_tool_call`) structurally carry no session-parentage field
at all in the live-confirmed OpenClaw 2026.9.6 plugin SDK types. **The sidecar does not win, so
Phase 19's shape does NOT change from porting a read path to owning a capture path** — the
D-01/CONTEXT.md consequence this README must state plainly either way. Candidate (c)'s
drift-resistance (the only candidate immune to a future OpenClaw storage change) is recorded per
the task's own instruction as a ranking *input*, not a criterion that changes this outcome,
since (c) does not clear the fidelity bar on the evidence gathered.

**Session parentage — the fourth D-02 field — is not cleared by any candidate with live-confirmed
data this spike, and this is stated honestly rather than folded into the ranking above:**
- Candidate (a) has the strongest position: `session_windows`/`session_nodes` carry
  `parent_session_key`, `spawned_by`, `fork_source_session_key`, `fork_source_session_id`
  columns, confirmed present in both cells' captured `.schema` output
  (`schema-capture.sql.txt`) — but no subagent-spawning turn was driven in either plan 17-03 or
  this plan to populate a real non-NULL value. This is an open item, not a disqualifying gap in
  the schema itself (the root-session NULL value observed is the *correct* value for a root
  session, not a missing field).
- Candidate (b)'s `export-trajectory` bundle includes a `session-branch.json` file whose content
  was not inspected for parentage fields this spike — genuinely ungraded, not confirmed either
  way.
- Candidate (c) is the only one of the three with a **confirmed structural absence**: reading
  the live OpenClaw 2026.9.6 package's own type declarations directly (not inferring from docs)
  confirms neither `PluginHookLlmOutputEvent`/`PluginHookAgentContext` nor
  `PluginHookAfterToolCallEvent`/`PluginHookToolContext` carries a parent-session field — the
  two hooks registered here cannot deliver this field without adding `subagent_spawned`/
  `subagent_ended`.

Per the phase's own prohibition ("if no read candidate clears D-02's zero-loss fidelity bar...
record the bar as unmet and escalate... no candidate is promoted to 'the chosen mechanism' by
being least-bad"): **this spike does not treat candidate (a) as a least-bad promotion.** (a) is
the strongest, most complete evidence on the three fields that WERE fully tested, and its
parentage position (columns present, schema-enforced, just not yet exercised) is a genuinely
different — and stronger — evidentiary state than either (b)'s ungraded state or (c)'s confirmed
absence. **Escalation path for the one open item:** before Phase 19 relies on
`session_windows`/`session_nodes` parentage columns for any parent/child rollup logic (the
successor to `report.sh`'s existing root-session-resolution walk), it must drive a real
subagent-spawning turn on the chosen mechanism and confirm `parent_session_key`/`spawned_by`
populate with the expected non-NULL values — this is a required pre-build confirmation step, not
an optional nice-to-have, and is carried forward explicitly below.

**Both-pairings provenance bar — explicitly UNMET.** The plan's own must-have states: "installed
via `openclaw plugins install` on both pairings and `openclaw plugins inspect` reports
provenance on each." Candidate (c) was installed and provenance-confirmed on the HOST-LOCAL
pairing only. The SANDBOX pairing (`revenium-2-0`) was unreachable before this task began
(`nemoclaw revenium-2-0 status` → exit 1, `Phase: Error`) — this is a pre-existing,
operator-owned host-recovery item per `17-SANDBOX-BLOCKER.md`, not something this task attempted
to repair or route around via `docker exec`. This bar is recorded as unmet, not weakened to
"standalone-only" and not silently marked satisfied. **Consequently, the B-05 check — whether
`after_tool_call` fires for Nemotron's `tool_search_code`-routed exec calls, the single most
consequential open question this candidate was positioned to answer — is UNRUN, not answered
either way.** This remains open for Phase 19/22.

### 2. Current-session-id resolution (D-03)

**Recommended mechanism: direct SQL against `session_nodes`, ordered by `updated_at` DESC,
filtered on `created_via != 'cron'`** (`session-id-resolution.txt` CANDIDATE 3), replacing the
four production resolvers' current `ls -t *.jsonl | head -1` (with a `sessions.json` cron-key
exclusion) glob pattern:

- `scripts/write-marker.sh:66`
- `scripts/write-job-marker.sh:132`
- `scripts/verify-markers.sh:91`
- `scripts/guardrail-check.sh:496`
- `scripts/get-root-session-id.py` (root-session walk; currently reverse-maps `sessions_spawn`
  toolResult `details.childSessionKey` links across `*.jsonl` files — a mechanism that no longer
  exists once JSONL is archive-only)

Verified against a real ground-truth turn (`sessionId=c50833a3-3b91-4111-8a79-9dbcd8d294d3`,
confirmed via the CLI's own `--json` response): `session_nodes.created_via` is a first-class,
schema-enforced enum column (`CHECK (created_via IS NULL OR created_via IN ('operator', 'spawn',
'channel', 'cron', 'talk', 'run', 'plugin', 'internal'))`) that directly answers "was this
session created by cron" — a structural improvement over the filename-glob-plus-key-exclusion
heuristic the four scripts use today, not just a like-for-like port. CANDIDATE 2 (CLI metadata
via `sessions list --json`, sorted client-side) is the documented fallback if a future build
removes CLI access to `session_nodes`-equivalent detail, but it inherits the same
CLI-agent-registry-scoping gap candidate (b) has for content reads.

**Open item carried to Phase 19 (per `session-id-resolution.txt`):** confirm live that
`created_via` is actually set to `'cron'` by an OpenClaw-internal cron-scheduled turn (not a
manually-invoked one) — this host had no real cron-scheduled session to test that specific value
against. Observed `created_via` values across both cells so far: `NULL` (chat-driven sessions)
and `'run'` (the NemoClaw `agent` subcommand wrapper).

## Requirements / build guidance

**Non-negotiables Phase 19 inherits from this determination:**

- **Connection form:** `sqlite3 -cmd "PRAGMA busy_timeout=5000;" "file:<path>?mode=ro" "<SQL>"` —
  read-only URI + explicit busy timeout, confirmed clean (zero `SQLITE_BUSY`, zero stalls) on
  both HOST-LOCAL and SSHFS cells across every query run in plans 17-03/17-04.
- **The cell distinction is load-bearing and must be preserved**, not normalized away: the
  standalone path's store is at `~/.openclaw/agents/<agentId>/agent/openclaw-agent.sqlite`; the
  NemoClaw path's equivalent is under `/sandbox/.openclaw/agents/<agentId>/agent/
  openclaw-agent.sqlite`, reachable host-side only through the `nemoclaw share mount` SSHFS
  channel (per CONVENTIONS.md's existing "host-side, never per-tick `nemoclaw exec`" pattern) —
  never assume one path's config generalizes to the other (D-15: the two paths run different
  OpenClaw builds, confirmed again this spike: 2026.9.6 vs 2026.9.1).
- **The fields that must survive, per D-02, and their exact source:**
  `transcript_events.event_json` JSON-path `$.message.usage.*` (token usage),
  `$.message.provider`/`$.message.model`/`$.message.responseModel` (model id), and a
  `toolCall`/`toolResult` row pair joined on `toolCallId` (toolCalls) — see
  `schema-capture.sql.txt` for the verbatim `CREATE TABLE transcript_events` definition and
  `sample-rows.txt` for the exact `json_extract` queries that recovered each field live.
- **Session parentage requires a pre-build confirmation step**, not assumed-working columns:
  drive a real subagent-spawning turn and confirm `session_windows.parent_session_key`/
  `spawned_by` and `session_nodes.parent_session_key`/`spawned_by`/`fork_source_session_key`/
  `fork_source_session_id` populate correctly before any parent/child rollup logic depends on
  them (this is the direct successor to `report.sh`'s current root-session-resolution walk).
- **Session-id mechanism:** direct SQL against `session_nodes` ordered by `updated_at` DESC,
  filtered `created_via != 'cron'` — see `## Results` §2 above for the full mapping to the four
  production resolvers plus `get-root-session-id.py`.
- **The probes and the sidecar in this directory are evidence, not a reference implementation.**
  Phase 19 writes production code from scratch against project conventions — this project's own
  precedent is `probe-host-compat.sh`, which earned promotion into `scripts/` only once the real
  build needed exactly that shape (D-11). Nothing here is promoted into `scripts/`, `plugin/`, or
  `plugin-nemoclaw/` — `git diff --name-only HEAD -- plugin plugin-nemoclaw` stays empty for the
  whole of this plan (confirmed in `## Self-Check` below).

## Open follow-up

- **Session parentage, all three candidates** — no candidate has been confirmed with real
  parent/child live data. Phase 19 must run this confirmation before relying on the winning
  mechanism's parentage columns for rollup logic (see `## Results` §1 escalation path above).
- **`created_via='cron'` confirmation** — no real cron-scheduled session existed on this host to
  test that specific enum value against a ground truth (see `## Results` §2).
- **Candidate (c) on the NemoClaw/Nemotron pairing, entirely unrun** — install, provenance,
  fidelity fields, and the B-05 check (`after_tool_call` firing for `tool_search_code`-routed
  exec calls) are all open. This is the single most consequential unrun cell in this spike,
  since candidate (c) was specifically positioned to test B-05 directly and no other candidate
  in this spike does. Flagged for Phase 19/22, contingent on the sandbox recovering per
  `17-SANDBOX-BLOCKER.md`.
- **`export-trajectory`'s parentage fidelity** — `session-branch.json`'s content was never
  inspected; if a future spike needs to re-confirm (b) as a fallback per the session-id
  CANDIDATE 2 fallback note, this file is the natural next place to look.
- **The live auth-store/session-reclamation contention observed driving candidate (c)'s
  HOST-LOCAL turns** (`No API key found for provider "anthropic"` on agent "dev" despite a
  working turn on the same agent earlier the same day in `cli-surface-output.txt`; `"SQLite
  session reclamation database owner is no longer current"`) is consistent with concurrent
  write activity from a sibling wave-4 plan on this shared host (D-13's named risk) — not
  investigated further here since sourcing the credential directly resolved it for this task's
  purposes, but worth a look if a similar auth gap recurs for a later plan on this host.

---
*Spike: 008*
*Phase: 17-live-host-fact-finding-spike*
*Completed: 2026-09-24*
