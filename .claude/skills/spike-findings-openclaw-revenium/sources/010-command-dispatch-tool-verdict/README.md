---
spike: 010
name: command-dispatch-tool-verdict
type: standard
validates: "Given the probe-dispatch-test skill's `command-dispatch: tool` / `command-tool` / `command-arg-mode: raw` frontmatter deployed to the live 52.90.9.242 host, when the skill's slash command is triggered by a human-typed message and separately by an agent-initiated mid-turn instruction, then the mechanism routes the raw argument directly to the declared tool with no model involvement (deterministic dispatch), on at least the standalone/Claude production pairing"
verdict: INVALIDATED
related: [006]
tags: [skill, command-dispatch, determinism, attribution, cross-model]
host: "52.90.9.242 (bare Ubuntu 26.04; sandbox revenium-2-0)"
---

# Spike 010: command-dispatch: tool Verdict (SPIKE-03)

## What This Validates

Whether the `command-dispatch: tool` SKILL.md frontmatter field can make marker-writing dispatch
deterministic instead of model-judgment-dependent — the only requirement in this milestone whose
answer changes the shape of the milestone (Phase 21 exists or doesn't) rather than the shape of an
implementation. This spike runs the cheap scope check first (can the mechanism even be triggered by
an agent-initiated action, or only by a human-typed slash command?) before spending any live-host
time on the expensive two-model determinism soak D-05 would otherwise require.

## Research

Sources: `.planning/phases/17-live-host-fact-finding-spike/17-RESEARCH.md` §`## command-dispatch:
tool — Critical Scope Finding` (the documented scope: `command-dispatch: "tool"` "route[s] the slash
command directly to a tool, circumventing model processing"; `command-tool` names the receiving
tool; `command-arg-mode` defaults `raw`) and §`## Common Pitfalls` Pitfall 1 (run the scope probe
before any soak — a failure to fire on the first model tested could be a scope problem, not a model
problem). `.planning/spikes/006-plugin-directive-injection/README.md` (plugin authoring precedent:
build from the official `openclaw plugins init` scaffold, never hand-roll — its hand-stubbed plugin
hung a turn). Live-fetched `docs.openclaw.ai/tools/creating-skills` and
`docs.openclaw.ai/tools/slash-commands` this session (2026-09-24) confirmed the field table verbatim
and one load-bearing architectural fact RESEARCH.md's static-docs pass did not have: "The Gateway
handles commands sent as standalone messages starting with `/`" — command-dispatch is documented as
an inbound-message-ingestion-time router, not a hook reachable from inside an agent's own tool-call
flow.

## How to Run

```bash
# Deploy the throwaway probe skill (never the production SKILL.md) to the standalone path:
scp .planning/spikes/010-command-dispatch-tool-verdict/probe-skill/SKILL.md \
  ubuntu@52.90.9.242:~/.openclaw/workspace/skills/probe-dispatch-test/SKILL.md

# Trigger A (human-typed, Gateway-routed — NOT --local, which bypasses the Gateway entirely):
openclaw agent --agent <id> --message "/probe_dispatch_test <raw-arg>" --model anthropic/claude-sonnet-4-6 --json

# Trigger B (agent-initiated, mid-turn):
openclaw agent --agent <id> --message "<natural-language task instructing the agent to invoke the
  skill's slash command itself, mid-turn, without the human typing it>" --model anthropic/claude-sonnet-4-6 --json

# Classify on objective telemetry (promptChars, tool-call count/diversity, wall-clock duration),
# not the model's own narrated claim about whether dispatch fired — see Investigation Trail.
```
Full reproduction detail, including the custom single-parameter tool plugin scaffold command and the
base64-transported sandbox invocation, is in `dispatch-run.log`.

## Investigation Trail

1. Built the throwaway probe skill and deployed it to the standalone path; `openclaw skills info`
   confirmed `commandVisible: true` — the skill loads and registers its slash command correctly.
2. First Trigger A attempt used `openclaw agent --local`. This never fires `command-dispatch: tool`
   for a structural reason, not a probe bug: `openclaw agent --help` documents `--local` as running
   the **embedded** agent, versus the default which runs "via the Gateway" — and the Gateway is
   exactly where command-message parsing lives per the docs quote above. Repaired by switching to
   genuine Gateway-routed invocation (a dedicated, isolated `OPENCLAW_HOME` with its own
   `auth: none` Gateway, kept separate from the shared host state plan 17-03 was concurrently using,
   per D-13's shared-host risk).
3. Second Trigger A attempt used `command-tool: exec`. The model's own account: "exec runs
   JavaScript, not a shell" — an invalid target for a raw shell-string forward. More decisively, the
   turn logged 12 tool calls across four different tools (`read`, `exec`, `terminal`, `write`) with
   the model's own narration opening "Skill read" — the shape of ordinary multi-step agentic
   reasoning, not a single deterministic forward.
4. Built a minimal, single-string-parameter tool (`probe_append`) via the official
   `openclaw plugins init --type tool` scaffold (never hand-rolled, per spike 006's own lesson),
   removing all ambiguity about command-tool's parameter shape. Re-ran Trigger A: the model's
   *narrative* now claimed a clean bypass ("did fire ... without model judgment"), but the objective
   telemetry contradicted it — `promptChars: 7173` for the turn (a full system prompt was sent to
   the model; a genuine bypass sends none) and `toolSummary.calls: 4` across two different tools
   (`exec` then `probe_append`). A model narrating its own belief about an internal runtime decision
   is not a reliable witness; this determination is based on telemetry, not self-report.
5. Ruled out a sender-authorization gap (`commands.ownerAllowFrom` / `commands.allowFrom` for the
   CLI's `cli` application-ID) — same result after explicitly allowlisting it.
6. Ran a control test, `/whoami` — a documented built-in "inline shortcut" that "run[s] immediately."
   It completed in `durationMs: 9683` (under 10s) versus every probe turn's 90–150+ seconds. This
   qualitative, objective difference confirms the harness does correctly reach OpenClaw's real
   command-handling layer — ruling out "broken probe" as the explanation for the probe's own
   non-firing.
7. Ran Trigger B (agent-initiated, mid-turn) on the same, now-validated harness: the model called
   `probe_append` directly as an ordinary tool call and again narrated a claim ("Human: fires,
   Agent-initiated: doesn't") that the objective telemetry from step 4 does not support — step 4's
   "human-typed" turn showed the identical multi-tool-call, full-context shape as this run.
8. Attempted the NemoClaw/Nemotron pairing's Trigger A. Blocked by an
   `AUTH_PROFILE_MIGRATION_REQUIRED` error requiring `openclaw doctor --fix` against the shared
   sandbox's `openclaw-agent.sqlite`. Declined to run it: per the threat model's T-17-02 and D-13,
   plan 17-03 was concurrently investigating that exact SQLite store as its own subject matter, and a
   doctor-driven migration is precisely the cross-plan perturbation the threat register requires
   avoiding. Recorded as an attempted-but-blocked cell, not a firing or non-firing observation.

## Results

**NO — mechanism inapplicable to this call shape.**

`command-dispatch: tool` does not achieve deterministic, zero-model-involvement dispatch for either
trigger shape tested on the standalone/Claude production pairing, on OpenClaw `2026.9.6 (eb377ac)`
(host `52.90.9.242`, 2026-09-24). This is a documented scope/functionality finding, not a failed
cross-model determinism result and not a broken-probe artifact — see the evidence below and the
Investigation Trail's control test (step 6), which independently confirms the test harness correctly
reaches OpenClaw's real command-handling layer.

**Why "inapplicable" rather than "model-gated":** the mechanism failed to fire even for its own
documented, easier case — a human-typed (Gateway-routed) slash-command message — on the *first and
only* model/pairing where it was fully tested (standalone/Claude). Per D-06's framing, a genuine
"model-gated" verdict requires the mechanism to work on at least one model and fail on another; here
it did not work on the one pairing where a complete Trigger A/Trigger B comparison was possible, so
there is no cross-model gating to report — only a single-pairing negative that, per D-06, resolves to
NO regardless. Extending this to "inapplicable to this call shape" (rather than treating it as an
unresolved single-model finding) is additionally supported by an architectural fact: `command-dispatch:
tool` is documented as intercepting inbound Gateway messages beginning with `/`, sent as a message's
only content — a code path an agent's own mid-turn tool-call flow structurally never re-enters,
regardless of model. That architectural constraint applies identically to every model OpenClaw can run,
which is why the negative generalizes rather than requiring a second model to confirm it.

**Evidence, command → raw output → interpretation:**

1. Skill correctly wired (host 52.90.9.242, 2026-09-24, OpenClaw 2026.9.6 (eb377ac)):
   ```
   $ openclaw skills info probe-dispatch-test --json
   "eligible": true, "modelVisible": true, "userInvocable": true, "commandVisible": true
   ```
   Interpretation: the probe skill loads and its command is discoverable — not a deployment failure.

2. Trigger A, clean harness + clean tool (host 52.90.9.242, 2026-09-24, OpenClaw 2026.9.6 (eb377ac)):
   ```
   $ openclaw agent --agent dev --message "/probe_dispatch_test TRIGGER-A-clean-<ts>" \
       --model anthropic/claude-sonnet-4-6 --json
   "promptChars": 7173, "toolSummary": {"calls": 4, "tools": ["exec","probe_append"]}
   ```
   Interpretation: a full system prompt was sent and the model made 4 calls across two tools — a
   normal agentic turn, not a bypass. (The turn's own narration claimed success; telemetry says
   otherwise — see Investigation Trail step 4.)

3. Control test proving harness validity (host 52.90.9.242, 2026-09-24, OpenClaw 2026.9.6 (eb377ac)):
   ```
   $ openclaw agent --agent dev --message "/whoami" --model anthropic/claude-sonnet-4-6 --json
   "durationMs": 9683
   ```
   Interpretation: a documented "runs immediately" inline shortcut completed in under 10s, versus
   90–150+ seconds for every probe turn — this harness demonstrably reaches the real command layer.

4. Trigger B, agent-initiated (host 52.90.9.242, 2026-09-24, OpenClaw 2026.9.6 (eb377ac)):
   ```
   $ openclaw agent --agent dev --message "<instruct the agent to invoke the command itself>" \
       --model anthropic/claude-sonnet-4-6 --json
   "toolSummary": {"calls": 2, "tools": ["probe_append","exec"]}
   ```
   Interpretation: the agent called the tool directly as an ordinary tool call, not via any
   slash-command re-entry — consistent with the architectural constraint above.

Full raw output for every claim, including the sandbox-pairing attempt and the exact repair sequence,
is in `dispatch-run.log`.

**Consequence for ATTR-01 and Phase 21 (D-06):** because the verdict is NO, ATTR-01 moves to
`REQUIREMENTS.md` → `## Future Requirements` → `### Attribution`, Phase 21 is deleted from the
roadmap, and the existing marker architecture ports as-is under Phase 20. Plan `17-06` applies this
mechanically. D-06's stated rationale applies squarely here: ATTR-01 exists to remove model
dependence, and shipping a mechanism that does not deterministically fire at all (on the only pairing
where it was fully tested) would mean falling back to the existing agent-written-marker architecture
anyway — maintaining two marker paths for no gain, exactly what PITFALLS.md names as what made the
CalVer line fragile.

## Requirements / build guidance

- **Do not scope any Phase 20/21 work around `command-dispatch: tool` as an attribution mechanism.**
  It does not deterministically dispatch on OpenClaw `2026.9.6` for either a human-typed or an
  agent-initiated trigger, on the one pairing where it was fully tested.
- **The existing agent-written-marker architecture is the confirmed, only viable path** for
  task-type/job attribution going into Phase 20 — it ports as-is, per D-06's NO-branch consequence.
- **If a future OpenClaw release changes this behavior,** re-run this spike's exact harness
  (`dispatch-run.log`'s "How to Run" commands) rather than assuming the field now works from docs
  alone — the whole reason this spike exists is that the documented behavior did not match the
  live-observed behavior on this runtime.
- **Classify by objective telemetry (promptChars, tool-call count/diversity, duration), never by the
  model's own narrated claim about whether a mechanism bypassed it** — this spike's Investigation
  Trail (steps 4 and 7) shows the model confidently asserting outcomes its own telemetry contradicts.

## Open follow-up

- **Whether restructuring marker-writing as an agent-invoked slash command could make the mechanism
  applicable is an open design question this spike does not decide.** The architectural constraint
  observed here (command-dispatch fires only on inbound Gateway messages, not on an agent's own
  mid-turn tool-call flow) suggests that even a slash-command restructuring would not help, since
  the agent still cannot re-enter Gateway message ingestion from inside its own turn — but this
  spike tested the mechanism as currently documented and skill-authorable, not every conceivable
  workaround, and does not close that door definitively.
- **The NemoClaw/Nemotron pairing's Trigger A was never completed** (blocked by an
  `AUTH_PROFILE_MIGRATION_REQUIRED` error, declined to fix to avoid perturbing plan 17-03's
  concurrent work on the same sandbox SQLite store). The standalone-pairing finding is not expected
  to differ there — `command-dispatch: tool` is documented as a Gateway/core-OpenClaw feature, not a
  per-model or per-install-path behavior — but that expectation is not an observed fact. If a future
  phase needs the sandbox pairing specifically re-verified, first resolve the auth-profile migration
  on a freshly-provisioned sandbox (not the shared one), then re-run this spike's Trigger A harness.
- **`openclaw plugins install`'s atomic final-move step stalled indefinitely** on this host across
  multiple attempts (`openclaw update repair` and `openclaw doctor --fix` both completed without
  clearing it); the fully-built plugin package had to be moved into `extensions/<id>/` manually from
  the installer's own completed install-stage directory. This is a live-host operational finding
  worth flagging to whichever future phase next needs `openclaw plugins install` on this host class —
  not a SPIKE-03-specific blocker, since the manual relocation fully unblocked this spike's own work.
