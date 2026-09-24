---
spike: 009
name: hook-firing-matrix-2-0
type: standard
validates: "Given a live 2.0 host, when an observer plugin registering the six hooks D-08 fixes in advance is installed with real provenance on both production pairings and driven with real traffic, then a twelve-cell matrix records fired/not-fired plus payload keys for each hook per pairing, and upstream issue #155696 is confirmed or retired for session_end"
verdict: PARTIAL
related: [006, 008]
tags: [plugin, hook, matrix, cross-model, nemotron, claude]
host: "52.90.9.242 (bare Ubuntu 26.04; sandbox revenium-2-0)"
versions: "standalone pairing (the only pairing these results were captured on): OpenClaw 2026.9.6 (eb377ac), Node v24.21.0, Docker 29.8.1. Sandbox pairing, unreached this spike: NemoClaw v0.0.128 / OpenClaw 2026.9.1 (ad6fe23). Source: 007-live-2-0-host-provisioning/versions-resolved.txt"
---

# Spike 009: Hook-Firing Matrix 2.0 (SPIKE-02)

**All six D-08 hooks fired live on the standalone OpenClaw 2026.9.6 + Claude pairing, with full payload-key evidence and the #155696 session_end question confirmed for this pairing — but the plan's both-pairings provenance bar is explicitly UNMET: the NemoClaw/OpenShell + Nemotron pairing was unreachable for the entire duration of this plan, so the B-05 question (does after_tool_call fire for Nemotron's tool_search_code-routed exec calls) remains entirely UNRUN, not answered either way.**

## What This Validates

SPIKE-02: a live, per-model matrix of the six hooks the skill depends on
(`before_prompt_build`, `after_tool_call`, `before_agent_finalize`,
`subagent_spawned`, `subagent_ended`, `session_end`), fired or not-fired per
production pairing, so model-dependent gaps of the B-05 class are known
before porting rather than discovered in production. `session_end` is
recorded as observed — never skipped as known-broken — because either
outcome (confirmed or retired) is useful for upstream issue #155696.

## Research

`.planning/phases/17-live-host-fact-finding-spike/17-RESEARCH.md` §`## Hook
Catalog (confirmed live-docs, feeds SPIKE-02)` — the full confirmed hook
catalog (no rename, no removal of any D-08 hook), per-hook type/timeout
detail, the `subagent_ended`-carries-no-`agentId` correlation note, the
`session_end` reason enum, and the `allowConversationAccess`/
`allowPromptInjection` permission-gate finding (the latter documented as
defaulting to *allowed*). `.planning/spikes/006-plugin-directive-injection/`
and `.planning/spikes/008-sqlite-session-read-path/probe-sidecar-plugin/` —
the proven packaging shape this task's observer mirrors.

## How to Run

```bash
scp -i ~/.ssh/hermes-sandbox.pem -r probe-hook-observer ubuntu@52.90.9.242:/tmp/revenium-hook-observer
ssh -i ~/.ssh/hermes-sandbox.pem ubuntu@52.90.9.242 \
  'openclaw plugins install /tmp/revenium-hook-observer --force --accept-capabilities'
# Configuration A: allowPromptInjection explicit
echo '{plugins: {entries: {"revenium-hook-observer": {enabled: true, hooks: {allowConversationAccess: true, allowPromptInjection: true}}}}}' \
  | ssh -i ~/.ssh/hermes-sandbox.pem ubuntu@52.90.9.242 'openclaw config patch --stdin'
# Configuration B: allowPromptInjection omitted (removed, not just unset to false)
ssh -i ~/.ssh/hermes-sandbox.pem ubuntu@52.90.9.242 \
  'openclaw config unset plugins.entries.revenium-hook-observer.hooks.allowPromptInjection'
ssh -i ~/.ssh/hermes-sandbox.pem ubuntu@52.90.9.242 'openclaw plugins inspect revenium-hook-observer'
# Drive turns (set -a; . ~/.spike-17.env; set +a sources credentials server-side, never echoed):
ssh -i ~/.ssh/hermes-sandbox.pem ubuntu@52.90.9.242 \
  'export PATH="$HOME/.npm-global/bin:$PATH:$HOME/.local/bin"; set -a; . ~/.spike-17.env; set +a; \
   openclaw agent --agent dev --message "..." --local --model anthropic/claude-sonnet-4-6 --json'
# Inspect: cat ~/.openclaw/revenium-hook-observer-capture.jsonl
```

The Nemotron/NemoClaw side of this command sequence (substituting `nemoclaw
revenium-2-0 exec` for the standalone `openclaw` calls, per plan 17-04's
proven install/enable/restart pattern) is directly re-runnable once the
sandbox recovers — nothing about it changed for this plan.

## Investigation Trail

1. Confirmed the sandbox blocker was still current before starting:
   `nemoclaw revenium-2-0 status` → `Phase: Error`, matching
   `17-SANDBOX-BLOCKER.md` exactly and unchanged since plan 17-04. Not
   attempted, not repaired, not routed around via `docker exec`, per the
   phase's binding.
2. Built `probe-hook-observer/` mirroring the packaging spike 006/plan 17-04
   proved (`type: module`/`main`/`openclaw.extensions` in package.json;
   `id`/`activation.onStartup`/`configSchema` in the manifest), with payload
   field names ground-truthed directly from the live host's installed
   `openclaw` package `.d.ts` (`hook-runner-global-CDmmGFJp.d.ts`, openclaw
   2026.9.6) — not guessed.
3. Installed on the HOST-LOCAL standalone pairing with `--accept-capabilities`
   (a newer capability-consent gate than spike 006 needed). `openclaw plugins
   inspect revenium-hook-observer` confirmed real provenance (`Trust:
   reason=origin-path`) before any firing/non-firing result was trusted.
4. Discovered the standalone agent configuration has shifted since spike
   007/008: `openclaw agents list` now shows only `dev` configured (`main` no
   longer resolves as an agent id — `Unknown agent id "main"`). Used `dev`
   throughout, consistent with plan 17-04's own precedent.
5. Drove a turn under Configuration A (`allowPromptInjection: true`
   explicit) — `before_prompt_build` and `before_agent_finalize` fired.
6. Removed `allowPromptInjection` via `openclaw config unset` (confirmed via
   `openclaw config get` showing only `allowConversationAccess` remaining in
   the plugin's `hooks` object) and drove a second turn — `before_prompt_build`
   **still fired**. Restored the key afterward for the remainder of the
   traffic window.
7. Drove a tool-calling turn (`exec`) — `after_tool_call` fired with full
   metadata.
8. Attempted a subagent-spawn turn via `--local` embedded execution —
   `sessions_spawn` tool calls failed validation, then failed with `"published
   reply runtime missing for dev"` — a live-host constraint of embedded/
   `--local` execution without a running gateway, not a bug in this task's
   probe. Started the standalone Gateway in the foreground
   (`openclaw gateway run`, no OS service installed — scope-bounded to this
   plan's own pairing, no sandbox/systemd changes) and retried through it
   with an explicit `--model` (the gateway's default model,
   `openai/gpt-6-astra`, has no configured auth). The gateway-routed retry
   succeeded: `sessions_spawn` completed, `subagent_spawned` and
   `subagent_ended` both fired.
9. `session_end` fired twice as a side effect of the subagent session
   cleanup (`reason: "deleted"`), captured naturally rather than forced.
10. Verified live, from the installed OpenClaw package's own type
    declarations (not docs), that `PluginHookSessionEndEvent`'s field list
    (`sessionId`, `sessionKey`, `messageCount`, `durationMs`, `reason`,
    `sessionFile`, `transcriptArchived`, `nextSessionId`, `nextSessionKey`)
    contains no message-content field at all — the observer's dynamic
    `hasMessageContent` scan (not hardcoded) evaluated `false` on both live
    fires, consistent with #155696's claim for this pairing.
11. Re-confirmed the sandbox was still `Phase: Error` immediately before
    writing this determination — the blocker never lifted during this
    plan's execution window.

## Results

### The twelve-cell matrix

See `hook-matrix.md` for the full table. Summary: all six hooks **FIRED**
on the standalone OpenClaw + Claude (HOST-LOCAL) pairing, each with full
payload-key evidence quoted in `hook-fire-log.txt`. All six sandbox-pairing
cells are **UNRUN** — not a fail, not inferred from the HOST-LOCAL column,
per the phase's own prohibition against recording a verdict for a probe that
was never run.

### Both-pairings provenance bar — explicitly UNMET

D-07 requires the matrix to cover both production pairings. This plan
confirmed the sandbox was unreachable (`Phase: Error`) at Task 1's start and
re-confirmed it unchanged immediately before this determination was
written. The observer was never installed on the NemoClaw/OpenShell
pairing. **This bar is stated plainly as unmet, not weakened to
standalone-only and not silently marked satisfied.**

### The B-05 question — UNRUN, not answered either way

Whether `after_tool_call` fires for Nemotron's `tool_search_code`-routed
exec calls — the single most consequential question this matrix exists to
answer — requires the sandbox pairing. It remains open, carried forward
unchanged from `008/README.md`'s own "Open follow-up" section. As a
directly relevant side-observation (not the answer itself): on the
standalone/Claude pairing, `after_tool_call` **does** fire for
`tool_search_code`-routed calls (several `hook-fire-log.txt` records carry a
`toolCallId` prefixed `tool_search_code:...`), confirming the routing
mechanism itself does not universally suppress the hook — whatever suppresses
it on Nemotron (if it does) is model/pairing-specific, not inherent to
`tool_search_code` routing as a concept.

### `allowPromptInjection` side observation

Confirmed live: omitting `allowPromptInjection` from the plugin's config
entirely did not stop `before_prompt_build` from firing on this pairing —
the documented default-allowed behavior holds. See `hook-matrix.md`'s
labelled note for the full evidence and the PLUG-02 consequence.

### #155696 — confirmed for this pairing

`session_end`'s live-confirmed payload shape carries no message-content
field, and both live fires evaluated `hasMessageContent: false` via a
dynamic (not hardcoded) scan. **For the standalone OpenClaw 2026.9.6 +
Claude pairing, this confirms #155696's claim** — the fallback `session_end`
carried no message content for SQLite-backed sessions is closed for this
pairing. The sandbox pairing's `session_end` behavior remains unconfirmed
(UNRUN), so this is a pairing-specific confirmation, not a project-wide
retirement of the upstream issue.

### `subagent_ended` correlation, confirmed live

`subagent_ended`'s payload structurally does NOT carry `agentId` (confirmed
by inspecting `eventKeys` on the live fire, not by reading the type
declaration alone) — correlation with the spawning turn runs through
`targetSessionKey` matching the prior `subagent_spawned.childSessionKey`,
confirmed matching byte-for-byte on the one live pair captured
(`agent:dev:subagent:5ecccc34-baf9-4c9c-b36c-5a382e4d63f9` on both sides).
PLUG-04/READ-03's root-session-resolution design can rely on this
correlation path.

## Requirements / build guidance

**Non-negotiables Phase 19/20 inherit from this determination:**

- All six D-08 hooks are confirmed present, correctly named, and firing on
  the standalone/Claude pairing on OpenClaw `2026.9.6` — no rename, no
  removal, matching RESEARCH.md's docs-derived catalog exactly.
- `subagent_ended` correlation MUST go through `targetSessionKey` ==
  `subagent_spawned.childSessionKey`, never `agentId` (absent structurally).
- `allowPromptInjection` need not be explicitly granted for
  `before_prompt_build` to fire on this OpenClaw build — PLUG-02 should
  still set it explicitly for forward-compatibility, but is not blocked by
  its current absence.
- **The Nemotron/NemoClaw pairing's entire hook-firing behavior — all six
  hooks, including the B-05-critical `after_tool_call` cell — remains
  completely unverified.** Phase 19/22 MUST NOT assume parity with the
  Claude pairing's results above. Re-run this plan's `probe-hook-observer/`
  install sequence against the sandbox pairing (via `nemoclaw revenium-2-0
  exec`, per plan 17-04's proven pattern) as a required pre-build step once
  the sandbox recovers.
- Subagent-spawn turns on the standalone pairing require the Gateway
  running (`openclaw gateway run` or the installed service) — embedded
  `--local` execution fails `sessions_spawn` with `"published reply runtime
  missing"`. This is worth flagging for Phase 19/22's own test harnesses.

## Open follow-up

- **The entire NemoClaw/OpenShell + Nemotron pairing, including the B-05
  question** — carried forward unresolved from `008/README.md`, unresolved
  again here. This is the single largest open item blocking Phase 19/22 from
  planning with confidence around cross-model hook behavior.
- **Only one live subagent pair was captured** — `subagent_spawned`/
  `subagent_ended` each fired exactly once. This is sufficient to confirm the
  correlation mechanism structurally, but Phase 19's PLUG-04/READ-03
  implementation should still exercise multiple concurrent subagents before
  relying on the correlation at scale.
- **`session_end` reasons other than `"deleted"` remain unobserved this
  spike** — the enum also includes `new`, `reset`, `idle`, `daily`,
  `compaction`, `shutdown`, `restart`, `unknown`. Only `deleted` fired live,
  as a side effect of subagent session cleanup. A future probe exercising a
  session idle-timeout or daily rollover would extend this coverage.

---
*Spike: 009*
*Phase: 17-live-host-fact-finding-spike*
*Completed: 2026-09-24*
