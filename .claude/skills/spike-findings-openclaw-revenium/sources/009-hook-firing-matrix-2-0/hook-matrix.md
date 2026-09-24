# Spike 009 (SPIKE-02) — Hook-Firing Matrix

Host: 52.90.9.242. Date: 2026-09-24. Observer: `probe-hook-observer/` (id
`revenium-hook-observer`), installed with real provenance (`openclaw plugins
install` + `openclaw plugins inspect` confirming `Trust: reason=origin-path`)
on the HOST-LOCAL standalone pairing. Raw evidence: `hook-fire-log.txt`.

Six rows — exactly the six hooks D-08 fixes in advance. Two pairing columns per
D-07/D-13. Each cell states fired / did-not-fire, the payload keys actually
received (never payload values — T-17-05), and the v2.0 requirement the hook
is load-bearing for.

**Sandbox pairing (NemoClaw/OpenShell + Nemotron): every cell below is UNRUN,
not a fail and not inferred from the HOST-LOCAL column.** The sandbox
`revenium-2-0` remains `Phase: Error` per `17-SANDBOX-BLOCKER.md` — confirmed
still down at the start of this plan's Task 1 (`nemoclaw revenium-2-0 status`
→ `Phase: Error`, unchanged from 17-04) and re-confirmed before this
determination was written. No sandbox cell was attempted, and none was routed
around via `docker exec`, per the phase's binding.

| Hook | Load-bearing requirement | Standalone OpenClaw + Claude (HOST-LOCAL) | NemoClaw/OpenShell + Nemotron (SANDBOX) |
|---|---|---|---|
| `before_prompt_build` | PLUG-03 (per-turn guardrail directive injection) | **FIRED** (16 records across the traffic window). Payload keys: `prompt`, `messages`. No `result` returned (observer never mutates the turn). Confirmed under BOTH permission configurations (see note below). | **UNRUN** — sandbox unavailable, see `17-SANDBOX-BLOCKER.md` |
| `after_tool_call` | PLUG-05 (exec observation) | **FIRED** (35 records across the traffic window, including the full 61-minute soak). Payload keys: `toolName`, `params`, `runId`, `toolCallId`, `result`, `error`, `durationMs`. Example: `toolName=exec`, `hasResult=true`, `hasError=false`, `durationMs=3208`. | **UNRUN** — see note below on the B-05 consequence |
| `before_agent_finalize` | The v1.3 structural-marker-enforcement compliance gate (`revenium-marker-gate`) | **FIRED** (7 records). Payload keys: `runId`, `sessionId`, `sessionKey`, `provider`, `model`, `cwd`, `transcriptPath`, `stopHookActive`, `lastAssistantMessage`, `messages`. No `result` returned. | **UNRUN** — see `17-SANDBOX-BLOCKER.md` |
| `subagent_spawned` | PLUG-04/READ-03 (root-session resolution via hooks, replacing cross-session marker-file resolution) | **FIRED** (2 records — two independent subagent spawns during the window). Payload keys: `runId`, `childSessionKey`, `agentId`, `label`, `requester`, `threadRequested`, `mode`, `resolvedModel`, `resolvedProvider`. `childSessionKey=agent:dev:subagent:5ecccc34-…`/`agent:dev:subagent:ce4e1330-…`, `agentId=dev` present on THIS hook (contrast with `subagent_ended` below). | **UNRUN** — see `17-SANDBOX-BLOCKER.md` |
| `subagent_ended` | PLUG-04/READ-03 (root-session resolution) | **FIRED** (2 records, TWO distinct outcomes observed live). Payload keys: `targetSessionKey`, `targetKind`, `reason`, `sendFarewell`, `accountId`, `runId`, `endedAt`, `outcome`, `error`. **No `agentId` field** — confirmed structurally (absent from `eventKeys`) on both records, matching the read_first note exactly: correlation runs through `targetSessionKey` matching the prior `subagent_spawned.childSessionKey` (confirmed matching, byte-for-byte, on both pairs). Record 1: `reason="subagent-complete"`, `outcome="ok"` (clean completion). Record 2: `reason="subagent-killed"`, `outcome="killed"`, `hasError=true` (the subagent was killed — its parent turn's `timeout` wrapper expired before the subagent finished; a naturally-occurring, not manufactured, failure-path observation). | **UNRUN** — see `17-SANDBOX-BLOCKER.md` |
| `session_end` | The compliance gate's session-boundary awareness; #155696 (see note below) | **FIRED** (2 records, both subagent-session cleanups). Payload keys: `sessionId`, `sessionKey`, `messageCount`, `durationMs`, `reason`, `sessionFile`, `transcriptArchived`, `nextSessionId`, `nextSessionKey`. Observed `reason="deleted"` both times; `hasMessageContent=false` both times (dynamic scan, not hardcoded — see #155696 note below). | **UNRUN** — see `17-SANDBOX-BLOCKER.md` |

## `after_tool_call` / Nemotron — the B-05 row note

This is the single cell this spike exists to close, and it is **UNRUN, not
answered either way.** Whether `after_tool_call` fires for Nemotron's
`tool_search_code`-routed exec calls (the B-05 gap — Nemotron routes `exec`
through `tool_search_code` rather than `before_tool_call`, so the structural
task-classification observation never fired historically) requires the
NemoClaw/Nemotron pairing, and that pairing has been unreachable
(`nemoclaw revenium-2-0 status` → `Phase: Error`) since before plan 17-04
began. This is carried forward, unresolved, to Phase 19/22 exactly as
17-04's `008/README.md` already flagged it — this plan does not narrow the
gap, because the sandbox never became reachable during its execution window
either.

## `allowPromptInjection` side observation (labelled note, not a row)

Installed the observer in two permission configurations on HOST-LOCAL and
drove a live turn under each:

- **Configuration A** — `allowConversationAccess: true`,
  `allowPromptInjection: true` (both explicit). `before_prompt_build` fired
  (`sessionKey=agent:dev:main`, `messagesCount=8`).
- **Configuration B** — `allowConversationAccess: true` only;
  `allowPromptInjection` **omitted** via `openclaw config unset
  plugins.entries.revenium-hook-observer.hooks.allowPromptInjection`
  (confirmed via `openclaw config get` showing only `allowConversationAccess`
  in the `hooks` object). `before_prompt_build` **still fired**
  (`sessionKey=agent:dev:main`, `messagesCount=10`, timestamp
  `2026-09-24T15:07:18.668Z`, distinct run from Configuration A's turn).

**Finding: the documented default-allowed behavior for `allowPromptInjection`
holds live.** Omitting the permission entirely did not stop
`before_prompt_build` from firing. This means PLUG-02 (Phase 20 — "set
`allowPromptInjection` alongside `allowConversationAccess`") may be a smaller
change than currently assumed for the standalone pairing: the hook already
fires without an explicit grant. PLUG-02 should still SET the permission
explicitly for forward-compatibility and to avoid depending on an undocumented
default persisting across an OpenClaw upgrade, but the compliance gate itself
does not appear to be blocked by its current absence on this build
(`2026.9.6`). This observation is standalone-pairing-only — the sandbox
pairing's default behavior for this permission is UNRUN, same as every other
sandbox cell above.

## `session_end` / #155696 finding

Every field in `PluginHookSessionEndEvent`'s live-confirmed type shape
(`sessionId`, `sessionKey`, `messageCount`, `durationMs`, `reason`,
`sessionFile`, `transcriptArchived`, `nextSessionId`, `nextSessionKey`) is
either an identifier, a count, a boolean, or a path — **none of them is a
message-content field.** The observer's `hasMessageContent` check is computed
dynamically (scans all received keys for anything matching
`/message|content|text|prompt/i` with a non-empty value, `messageCount`
excluded as a count not content) rather than hardcoded to this expectation,
and on both live fires it evaluated `false`. This is consistent with — and,
on the HOST-LOCAL/Claude pairing specifically, **confirms** — upstream issue
#155696's claim that the `session_end` payload carries no message content for
SQLite-backed sessions. See `009/README.md` for the full determination
(the sandbox pairing's `session_end` behavior remains unconfirmed, so this is
a standalone-pairing-only confirmation, not a project-wide retirement of the
issue).
