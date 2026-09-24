# Live-Host OpenClaw 2.0 Facts

## Requirements

- **Session-read mechanism:** direct, read-only SQLite (`file:<path>?mode=ro` + `PRAGMA
  busy_timeout=5000`) — no retry/backoff wrapper. Must preserve, without loss: per-completion
  token usage (`transcript_events.event_json` JSON-path `$.message.usage.*`), model id
  (`$.message.provider`/`.model`/`.responseModel`), and toolCalls (a `toolCall`/`toolResult` row
  pair joined on `toolCallId`).
- **Current-session-id resolution:** direct SQL against `session_nodes`, ordered by `updated_at`
  DESC, filtered `created_via != 'cron'` — replaces the `*.jsonl`-filename-glob convention in
  `write-marker.sh`, `write-job-marker.sh`, `verify-markers.sh`, `guardrail-check.sh`, and
  `get-root-session-id.py`'s root-session walk.
- **Version floors:** OpenClaw numeric CalVer `>=2026.8.1` (never a version-string-prefix check);
  Node `>=24.16 <25 || >=26.1`.
- **Hooks reliable per pairing:** all six (`before_prompt_build`, `after_tool_call`,
  `before_agent_finalize`, `subagent_spawned`, `subagent_ended`, `session_end`) are confirmed on
  the standalone OpenClaw + Claude pairing ONLY. The NemoClaw/OpenShell + Nemotron pairing's
  hook-firing behavior is entirely unverified — do not assume parity.

## How to Build It

1. Connect read-only and WAL-aware: `sqlite3 -cmd "PRAGMA busy_timeout=5000;"
   "file:<path>?mode=ro" "<SQL>"`. Confirmed clean (zero `SQLITE_BUSY`, zero stalls) over a
   61-minute, 62-tick per-minute soak on the HOST-LOCAL cell.
2. Standalone-path store: `~/.openclaw/agents/<agentId>/agent/openclaw-agent.sqlite`. NemoClaw
   path store: `/sandbox/.openclaw/agents/<agentId>/agent/openclaw-agent.sqlite`, reachable
   host-side only through the `nemoclaw share mount` SSHFS channel — never assume one path's
   config generalizes to the other; the two paths run different OpenClaw builds.
3. Resolve the current session id with `SELECT ... FROM session_nodes WHERE created_via != 'cron'
   ORDER BY updated_at DESC LIMIT 1` (verified against a real ground-truth turn).
4. Define "one completion" precisely before counting: a raw `COUNT(*)` of assistant-role
   `transcript_events` rows does NOT map 1:1 to a billable/metered completion — a single
   multi-step turn can produce up to 5 such rows. Dedupe by `responseId`, or select exactly one
   row per `runId` by a defined rule.
5. Before relying on `session_windows`/`session_nodes` parentage columns
   (`parent_session_key`/`spawned_by`/`fork_source_session_key`/`fork_source_session_id`) for any
   parent/child rollup logic, drive a real subagent-spawning turn and confirm they populate with
   non-NULL values — no candidate confirmed this with live data during the spike.
6. Before relying on `created_via = 'cron'` to exclude cron-scheduled sessions, confirm live that
   an OpenClaw-internal cron-scheduled turn actually sets that value — no such session existed on
   the spike host to test against.

## What to Avoid

- **`sessions tail`** — redacts message content by design (`{...redacted...}`), confirmed live.
- **`sessions list`/`export-trajectory` as a blanket content-read substitute** — both are
  CLI-agent-registry-scoped: an ad-hoc agent's store is invisible to them even though the file
  exists on disk and is correctly read by direct SQLite access. `export-trajectory` also writes a
  7-file directory to disk on every invocation — extra I/O for a per-minute cron.
- **The plugin-hook sidecar (`llm_output` + `after_tool_call`) as the primary read mechanism** —
  it is real and installable with provenance, but is only partial on toolCalls (metadata only, by
  design) and structurally cannot deliver session parentage at all (confirmed against the live
  OpenClaw plugin SDK's own type declarations, not inferred).
- **`command-dispatch: tool` as an attribution/dispatch mechanism** — confirmed NOT to achieve
  deterministic, model-free dispatch on OpenClaw 2026.9.6, for either a human-typed or an
  agent-initiated trigger, on the one pairing fully tested. The existing agent-written-marker
  architecture (`write-marker.sh`/`write-job-marker.sh`) is the confirmed, only viable attribution
  path and ports as-is.
- **Trusting NemoClaw's documented "latest" install resolution** — it resolves to a
  maintained-last-known-good tag, not the newest published tag, and can land below the project's
  floor (observed: `v0.0.124`, in-sandbox OpenClaw `2026.7.1`, pre-2.0). Pin explicitly with
  `NEMOCLAW_INSTALL_TAG=v0.0.128` (or whatever the current floor-matching release is).
- **Assuming `session_end`'s fallback carries message content** — confirmed live it does not, on
  the standalone/Claude pairing (closes upstream issue #155696 for that pairing specifically).

## Constraints

- OpenClaw numeric CalVer floor `>=2026.8.1`; Node floor `>=24.16 <25 || >=26.1`.
- **The two production install paths do not necessarily run the same OpenClaw build** — confirmed
  on the spike host: standalone `2026.9.6 (eb377ac)`, NemoClaw-managed (v0.0.128) `2026.9.1
  (ad6fe23)`. Record per-path, never normalize.
- **Both-pairings caveat:** every hook-firing, dispatch-determinism, and session-store fact in
  this file was captured on the standalone OpenClaw + Claude pairing only. The NemoClaw/OpenShell
  + Nemotron pairing — including the B-05 question (does `after_tool_call` fire for Nemotron's
  `tool_search_code`-routed exec calls?) — remains entirely unverified; the sandbox was
  unreachable (`Phase: Error`) for the remainder of the spike. Re-run once it recovers, per
  `17-SANDBOX-BLOCKER.md`.
- **The SSHFS cell is its own measurement, not inferable from HOST-LOCAL.** The concurrency soak's
  zero-lock-error result is proven only for the HOST-LOCAL cell; the SSHFS-mounted cell (required
  for NEMO-03, the host-side metering loop over `nemoclaw share mount`) never ran and must be
  measured separately, not assumed to inherit the HOST-LOCAL result.
- `command-dispatch: tool` is documented as an inbound-Gateway-message router (messages beginning
  with `/`), a code path an agent's own mid-turn tool-call flow structurally never re-enters —
  this generalizes across models, which is why the negative verdict does not require a second
  model to confirm.

## Origin

Synthesized from spike: 007, 008, 009, 010, 011. Sources: `sources/007-live-2-0-host-provisioning/`,
`sources/008-sqlite-session-read-path/`, `sources/009-hook-firing-matrix-2-0/`,
`sources/010-command-dispatch-tool-verdict/`, `sources/011-read-path-concurrency-soak/`.
