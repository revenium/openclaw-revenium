# Spike 008 (SPIKE-01) — Fidelity Matrix

Host: 52.90.9.242. Date: 2026-09-24. Versions in effect: standalone OpenClaw 2026.9.6
(eb377ac), NemoClaw-managed OpenClaw 2026.9.1 (ad6fe23). Source:
`.planning/spikes/007-live-2-0-host-provisioning/versions-resolved.txt`.

Three candidates, per D-01: (a) direct read-only SQLite read; (b) the `openclaw sessions`
CLI surfaces (best surface graded per row: `export-trajectory`, the only one of the four
surfaces that is not eliminated on documented/confirmed redaction or aggregate-only
scope — see `cli-surface-output.txt`'s per-surface summary table for why `list`/`tail`/
`doctor inspect` are excluded here); (c) the plugin-hook sidecar
(`probe-sidecar-plugin/`, registering exactly `llm_output` + `after_tool_call`).

Every cell below is an observation, cited to its source evidence file, not a prediction.
`RECOVERABLE` = confirmed live with real data. `PARTIAL` = confirmed live but missing a
sub-component by design/scope. `PRESENT (schema), UNTESTED (data)` = the mechanism
structurally carries the field (confirmed via schema/type capture) but no live positive
example was observed this spike. `ABSENT` = confirmed live that the field/mechanism does
not deliver this at all. `NOT RUN` = precondition unmet, never attempted (never inferred).

## Matrix

| Candidate | Cell | Token usage (per-completion) | Model id | toolCalls | Session parentage | Evidence |
|---|---|---|---|---|---|---|
| (a) direct SQLite read | HOST-LOCAL | RECOVERABLE — full (`transcript_events.event_json.$.message.usage`: input/output/cacheRead/cacheWrite/totalTokens/cost/contextUsage) | RECOVERABLE — full (`.message.provider`/`.model`/`.responseModel`) | RECOVERABLE — full (name/id/arguments joined to result/status/exitCode/duration via `toolCallId`) | PRESENT (schema), UNTESTED (data) — `session_windows`/`session_nodes` carry `parent_session_key`/`spawned_by`/`fork_source_session_*` columns; this session is a root session (NULL is the correct value, not a gap); no subagent-spawning turn was driven to populate a real non-NULL row | `sample-rows.txt` |
| (a) direct SQLite read | SANDBOX (SSHFS-mounted) | NOT RECOVERABLE THIS RUN — read mechanism itself clean (zero SQLITE_BUSY/stalls), but zero completions exist to sample (upstream `AUTH_PROFILE_MIGRATION_REQUIRED` blocker, not a read-path failure) | NOT RECOVERABLE THIS RUN (same reason) | NOT RECOVERABLE THIS RUN — 0 `transcript_events` rows | PRESENT (schema), UNTESTED (data) — same columns confirmed present in this cell's schema too | `sample-rows.txt` |
| (b) CLI surfaces (`export-trajectory`) | HOST-LOCAL | RECOVERABLE — full, per-call AND aggregate `usage` objects, unredacted, matching (a) | RECOVERABLE — full (provider/model/responseModel) | RECOVERABLE — full (arguments + result content + status/exitCode/duration, joinable by `toolCallId`) | NOT GRADED — `session-branch.json` is in the exported file set but its content was not inspected for parentage fields this spike; distinct from `sessions list --json`'s payload, which was confirmed to omit parentage entirely | `cli-surface-output.txt` |
| (b) CLI surfaces (`export-trajectory`) | SANDBOX | NOT RUN / INCONCLUSIVE — command hit the sandbox's systemic gateway-lifecycle contention (`EXIT=124`), the same contention independently confirmed by Task 1's `AUTH_PROFILE_MIGRATION_REQUIRED` finding, not a distinct approval-gate result | (same) | (same) | (same) | `cli-surface-output.txt` |
| (c) plugin-hook sidecar | HOST-LOCAL | RECOVERABLE — full (`llm_output.usage`: input/output/cacheRead/cacheWrite/total/cost) | RECOVERABLE — full (`.provider`/`.model`/`.resolvedRef`) | PARTIAL — name/id/duration/result-presence/error-flag captured; argument VALUES and result CONTENT deliberately not captured (out of this probe's scope, not a mechanism ceiling — a production sidecar could capture them) | ABSENT — confirmed structurally: neither `PluginHookLlmOutputEvent`/`PluginHookAgentContext` nor `PluginHookAfterToolCallEvent`/`PluginHookToolContext` (openclaw 2026.9.6's own `.d.ts`) carries a parent-session field; the two hooks registered by this task cannot deliver this field at all without adding `subagent_spawned`/`subagent_ended` | `sidecar-capture.jsonl` |
| (c) plugin-hook sidecar | SANDBOX | NOT RUN — precondition unmet (`nemoclaw revenium-2-0 status` exit 1, `Phase: Error`); sidecar was never installed on this pairing | NOT RUN | NOT RUN | NOT RUN | `17-SANDBOX-BLOCKER.md`, this plan's Task 1 |

## Ranking (fidelity-first, per D-02)

On the three fields with confirmed live evidence across all three candidates on the
HOST-LOCAL cell — **per-completion token usage, model id, and toolCalls** — the ranking is:

1. **(a) direct SQLite read and (b) `export-trajectory` — TIE.** Both deliver
   full, zero-loss, live-confirmed fidelity on all three fields, matching each other
   field-for-field (both are reading/exporting the same underlying transcript data).
2. **(c) plugin-hook sidecar.** Full on usage/model; partial on toolCalls — captures
   name/id/duration/error-flag but not argument/result content, by this probe's own
   scope choice (T-17-05 hygiene + the task's own registered-hook limit), not a hard
   mechanism ceiling.

**Session parentage is the fourth field, and no candidate clears it with live-confirmed
data this spike** — this is recorded honestly rather than glossed:
- (a) has the strongest position of the three: the columns exist, are schema-enforced,
  and are present in both cells' captured `.schema` output — but no subagent-spawning
  turn was driven in this spike (17-03) or this task to populate a real non-NULL value.
  This is a genuine open item, not a disqualifying fidelity gap in the mechanism itself.
- (b)'s parentage fidelity was simply never graded — `session-branch.json` exists in its
  export bundle but its content was not inspected.
- (c) is the only candidate with a **confirmed, structural** absence: the two hooks this
  task registered (`llm_output`, `after_tool_call`) do not carry a parent-session field
  in the live-confirmed OpenClaw 2026.9.6 plugin SDK types at all.

## Tie-break: (a) vs (b) on the three fields where they tie

Per D-02, performance and drift-resistance break ties **only** between candidates that
already clear the fidelity bar — applied here to (a) vs (b):

- **CLI-agent-registry scoping (fidelity-adjacent, favors (a)).** `cli-surface-output.txt`'s
  load-bearing finding: `export-trajectory` (like `sessions list`/`tail`) is blind to any
  agent not registered via `openclaw agents add` — an ad-hoc agent's store is invisible to
  it even though the store file exists on disk and is correctly identified by direct SQLite
  access or `doctor session-sqlite inspect`. This is precisely the kind of *silent* omission
  D-02's rationale warns about ("a mechanism that is fast but silently drops... reproduces
  the exact fail-open blackout this milestone exists to close") — a production cron script
  built on `export-trajectory` would silently miss any unregistered agent's activity. (a) has
  no such dependency: it reads whatever store file exists on disk.
- **Per-tick I/O footprint (favors (a)).** `export-trajectory` writes a 7-file directory to
  disk on every invocation (`cli-surface-output.txt`: `manifest.json, events.jsonl,
  session-branch.json, tools.json, metadata.json, artifacts.json, prompts.json`, mode 700) —
  extra I/O and cleanup burden for a per-minute cron that SPIKE-04 must still prove sustains
  zero loss. A read-only `sqlite3 file:...?mode=ro` query writes nothing.
- **Drift-resistance (input, not a formal criterion here — favors neither since the tie is
  between (a) and (b), not (c)).** Both (a) and (b) depend on OpenClaw's own storage/CLI
  staying stable; only candidate (c) is immune to a future storage change, per D-01's own
  rationale for including it. This does not change the (a)/(b) tie-break outcome since (c)
  did not clear the fidelity bar on this evidence, but is recorded per the task's own
  instruction to carry the observation forward as a ranking input.
- **Build coherence (a genuine practical consideration, favors (a), not a formal D-02
  criterion).** D-03's own recommended session-id mechanism (`session-id-resolution.txt`
  CANDIDATE 3) is already direct SQL against `session_nodes`. Choosing (a) for content-read
  too means Phase 19 builds and maintains ONE read layer serving both determinations,
  instead of a SQL layer for session-id plus a separate CLI-export layer for content.

**Result: (a) direct SQLite read wins the tie-break decisively** — see `README.md` `##
Results` for the full determination, including the explicit escalation/follow-up item for
the one field (session parentage) no candidate confirmed with live data this spike.
