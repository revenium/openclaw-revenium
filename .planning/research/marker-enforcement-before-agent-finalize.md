# Research Seed: Structural Marker Enforcement via `before_agent_finalize`

**Gathered:** 2026-06-05 (live diagnosis on ClawHub host `98.82.34.123`)
**For:** a future phase — make task/job marker writing structurally enforced instead of LLM-compliance-dependent.
**Status:** Ready to seed discuss/plan.

## Problem (evidence-based)

On the **ClawHub-published** install (host `98.82.34.123`, skill `_meta.json` v0.5.8, agent model `claude-opus-4-8`):

- `post-install.sh` **did** run: `~/.openclaw/workspace/AGENTS.md` (268 lines) contains the guardrail block **and** the metering-directive sentinel (`<!-- BEGIN revenium-metering-directives -->`), `references/` is present, sandbox config + `BUDGET-GUARD.md` deployed.
- The agent **honors the start-of-turn guardrail check** (9 reads of `guardrail-status.json` in one session) — proving AGENTS.md is genuinely in the model's context.
- But it **drops the end-of-turn `write-marker.sh` gate**: markers were written for **1 of ~64 completions** in the session (1 task + 3 job markers, all batched on the setup turn, completion_id `b4746630`).

**Conclusion:** this is NOT a missing-plumbing problem (the v1.1 "directives → AGENTS.md" fix is present and working). Even Opus 4.8 will not reliably self-invoke the end-of-turn classification gate. Directive-wording tuning cannot make it reliable.

**Scope of the loss:** `report.sh` already defaults unmarked completions to `--task-type unclassified` (lines ~713–760), so unmarked turns still ship as metered `unclassified` completions. What is actually lost is **job-level association** and **task-type specificity** — the rich signal that inherently needs LLM judgment.

Contrast: the **git-clone** install on `.247` reportedly works — likely because that host's sessions happened to comply, not because of a structural difference (both installs have identical AGENTS.md directives).

## Chosen direction (user decision)

A **typed OpenClaw plugin hook (`before_agent_finalize`)** that forces the classification step before the agent is allowed to yield. This was chosen over (a) a `message:sent` file hook and (b) a `report.sh` cron backfill — both of which only harden the `unclassified` floor that already exists, and cannot produce the rich task_type/job signal.

## `before_agent_finalize` contract (OpenClaw `docs/plugins/hooks.md:339`)

> Runs only when a harness is about to accept a natural final assistant answer. NOT the `/stop` path; does not run on user abort.

Return values:
- `{ action: "revise", reason, retry?: { instruction: string; idempotencyKey?: string; maxAttempts?: number } }` → one more model pass with `instruction`.
- `{ action: "finalize", reason? }` → force finalize.
- omit → continue.

`retry.maxAttempts` bounds the extra passes (replay-safe). This solves the loop/blocking risk.

Plugin authoring: `definePluginEntry({ id, name, register(api) {...} })` from `openclaw/plugin-sdk/plugin-entry`; register handlers with `api.on(name, handler, { priority, timeoutMs })`. Install via `openclaw plugins install clawhub:<org>/<pkg>` (or npm / local path). Conversation-content hooks need `plugins.entries.<id>.hooks.allowConversationAccess: true` — **this plugin does NOT need it** (it only observes `exec` tool calls).

## Proposed plugin design — `revenium-marker-gate`

```
register(api):
  before_tool_call (or after_tool_call):
     if exec command string includes "write-marker.sh"      → markedTaskRuns.add(ctx.runId)
     if exec command string includes "write-job-marker.sh"  → markedJobRuns.add(ctx.runId)   // optional, if gating jobs too

  before_agent_finalize(event):
     if markedTaskRuns.has(ctx.runId)  → return undefined            // already classified → allow finalize
     else → return {
        action: "revise",
        reason: "turn not classified for Revenium metering",
        retry: {
          instruction: "Before finishing, classify this turn: run "
            + "`bash ~/.openclaw/skills/revenium/scripts/write-marker.sh <task_type>` "
            + "(and write-job-marker.sh if a goal arc concluded), then finish.",
          idempotencyKey: `marker-gate:${ctx.runId}`,
          maxAttempts: 1            // force at most ONE extra pass; if still unmarked, harness finalizes anyway → fail-open
        }
     }

  agent_end: delete ctx.runId from both sets   // cleanup
```

Properties: structurally enforced (agent can't yield the first time without being sent back to `write-marker.sh`), bounded (`maxAttempts: 1`), fail-open (never hard-blocks the user's reply), no conversation-access grant needed.

## Open design questions for discuss/plan

1. **Where does the plugin live + how is it distributed?** Same repo as the bash skill (new `plugin/` package) vs separate repo. It must version/ship alongside the skill on ClawHub, and `post-install.sh` may need to `openclaw plugins install` + enable it.
2. **Gate scope:** force task markers only, or also job markers? Job arcs don't conclude every turn (D-04 soft floor) — gating jobs per-turn would over-fire. Likely: gate the per-turn **task** marker; leave job declaration to the directive + a separate `session_end`/`agent_end` job-closure path.
3. **Correlating "did this run write a marker":** tracking via `before_tool_call`/`after_tool_call` on `exec` (runId in tracking set) avoids needing completion_id mid-finalize. Confirm `ctx.runId` is stable across the finalize hook and the tool hooks in the same turn.
4. **`session_end` typed hook** (reason ∈ new/reset/idle/daily/compaction/deleted/shutdown/restart) could close open jobs CANCELLED/interrupted deterministically — complements the per-turn task gate. Worth folding in.
5. **Diagnostic (`scripts/verify-markers.sh`):** report per session completions-vs-markers so the gap is measurable before/after. Low-risk, build regardless of plugin progress.
6. **Validation:** must be tested end-to-end on `98.82.34.123` (ClawHub install, opus-4-8) — confirm the revise loop fires, the agent classifies on the forced pass, and finalize proceeds when unmarked (fail-open). See [[clawhub-test-host]] in memory for ssh details (`ssh -i ~/.ssh/agent-sandbox.pem ubuntu@98.82.34.123`).

## Constraints (do NOT break)

- Budget-rule logic, `ruleIds` in `config.json`, and the `guardrail-status.json` halt/warn JSON contract are untouched.
- Preserve the skill's existing atomic-write patterns and `report.sh` completion_id correlation + `unclassified` default.
- Plugin must be fail-open: a hook error must never block the agent's reply.
