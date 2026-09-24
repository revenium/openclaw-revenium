---
name: probe-dispatch-test
description: "THROWAWAY SPIKE PROBE (SPIKE-03) — tests whether command-dispatch: tool fires from an agent-initiated action, not a human-typed slash command. Not for production use, not the project's revenium skill."
command-dispatch: tool
command-tool: exec
command-arg-mode: raw
user-invocable: true
---

# Probe Dispatch Test (throwaway — SPIKE-03 scope probe)

This skill exists only to answer one question for `.planning/phases/17-live-host-fact-finding-spike/17-02-PLAN.md`
Task 1: can `command-dispatch: tool` be triggered by an agent-initiated action
(mid-turn, as part of the agent's own tool-call flow), or does it only fire
for a human-typed `/probe_dispatch_test ...` slash-command message?

`command-dispatch: tool` routes the slash command's raw argument string
directly to the `exec` tool, bypassing model judgment for that invocation
(per `command-tool: exec` + `command-arg-mode: raw`). The dispatched command
appends one timestamped line to `/tmp/probe-dispatch-run.log` so a dispatch
is directly countable without inference.

Do NOT use this skill for anything other than the SPIKE-03 scope probe. It is
not the production `revenium` skill and carries no guardrail/metering logic.
