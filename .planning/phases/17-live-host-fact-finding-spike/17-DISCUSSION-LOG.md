# Phase 17: Live-Host Fact-Finding Spike - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-09-23
**Phase:** 17-Live-Host Fact-Finding Spike
**Areas discussed:** Read-mechanism candidates, SPIKE-03 verdict bar, Findings artifact shape, Host & sandbox topology

---

## Read-mechanism candidates

### Q1 — Which candidate read paths should SPIKE-01 exercise on the live host?

| Option | Description | Selected |
|--------|-------------|----------|
| All three, ranked | Direct `sqlite3` (read-only, WAL-aware), real `openclaw sessions` subcommands, AND a plugin-hook sidecar writing our own append-only format. Most host time; Phase 19 starts with a proven fallback, and the sidecar is immune to schema drift. | ✓ |
| sqlite3 + sessions CLI only | Keep the spike to reading what OpenClaw already stores; a sidecar changes architecture and belongs in a Phase 19 design decision. Narrower; returns no answer if both fail. | |
| sqlite3 first, escalate on failure | Cheapest and most likely candidate first, escalate only if unworkable. Least host time; risks a second spike round on a "partially works" answer. | |

**User's choice:** All three, ranked

### Q2 — Top-line criterion deciding the winner?

| Option | Description | Selected |
|--------|-------------|----------|
| Data fidelity first | Winner yields per-completion token usage, model id, toolCalls and session parentage with zero loss; perf and durability break ties. A fast mechanism that silently drops token counts reproduces the blackout this milestone exists to fix. | ✓ |
| Unattended-cron viability first | Winner runs reliably from cron with no owner approval or lock contention; fidelity gaps patched after. `sessions export-trajectory` may require interactive/owner-approved exec. | |
| Durability against drift first | Winner survives OpenClaw changing storage again — structurally favors the sidecar. This is the second migration to break the read path. | |
| All three must pass a floor | Hard floor on all three axes, disqualify on any miss, rank survivors by fidelity. Risks "none qualified". | |

**User's choice:** Data fidelity first

### Q3 — Session-id resolution (six scripts glob the newest non-cron `*.jsonl`)

| Option | Description | Selected |
|--------|-------------|----------|
| Co-equal SPIKE-01 deliverable | Two written determinations: content reading, and how a running script identifies its own session and walks to root. `write-marker.sh`, `write-job-marker.sh`, `verify-markers.sh` and `guardrail-check.sh` need only the second. | ✓ |
| Fold into the hook matrix | Treat as a hook question — SPIKE-02 tests `subagent_spawned`/`subagent_ended` payloads. Risks model-dependent hooks with no storage-side fallback. | |
| Both, explicitly paired | Storage-side in SPIKE-01, hook-side in SPIKE-02, findings state preference and fallback. More host time, two mechanisms to document. | |

**User's choice:** Co-equal SPIKE-01 deliverable
**Notes:** Raised by Claude during codebase scout — research had named only `report.sh`, `common.sh` and `get-root-session-id.py` as JSONL readers; the actual count is six scripts, four of which never read message content.

### Q4 — SPIKE-04 pass bar for per-minute cron polling

| Option | Description | Selected |
|--------|-------------|----------|
| Concurrency soak, zero loss | Real per-minute cron over a sustained window while an agent actively produces turns; pass only on zero lock/`SQLITE_BUSY` errors and zero missed completions vs ground truth. | ✓ |
| Resource ceiling only | Tick wall-time, CPU, IO against a ceiling on an idle-ish host. Says nothing about concurrent-read data loss. | |
| Soak plus resource ceiling | Both, giving Phase 19 a regression baseline. Most evidence, longest host window. | |

**User's choice:** Concurrency soak, zero loss

---

## SPIKE-03 verdict bar

### Q1 — What evidence turns `command-dispatch: tool` into a yes?

| Option | Description | Selected |
|--------|-------------|----------|
| Determinism across models | Dispatch on every qualifying turn across ≥2 models including one from the class that previously broke observation, over a run long enough that model compliance isn't the explanation. B-05 died because a mechanism working on one model routed differently on another. | ✓ |
| Mechanism fires at all | Dispatch without the model electing to comply, on the primary model, observed live. Cheapest; Phase 21 carries cross-model risk. | |
| Beats the current gate on coverage | Measured marker coverage meets or beats the v1.3 `before_agent_finalize` gate. Matches Phase 21's own SC-2 but needs a 2.0 coverage baseline first. | |

**User's choice:** Determinism across models

### Q2 — What if it works on model A but not model B?

| Option | Description | Selected |
|--------|-------------|----------|
| Binary — anything partial is NO | Partial = NO: ATTR-01 to Future Requirements, Phase 21 deleted, marker architecture ports as-is under Phase 20. A model-gated "deterministic" dispatch is the same model dependence with a new mechanism. | ✓ |
| Three-state verdict | yes / no / yes-but-model-gated; Phase 21 scoped to passing models with the existing gate as fallback. Costs dual-path maintenance. | |
| Report evidence, decide later | No verdict; the call happens at Phase 21 planning. Phases 19–20 proceed not knowing whether an attribution rewrite is coming. | |

**User's choice:** Binary — anything partial is NO

### Q3 — Which model pair?

| Option | Description | Selected |
|--------|-------------|----------|
| Both production paths | standalone + Claude, and NemoClaw/OpenShell + Nemotron — the pairing research named, and Nemotron is the model that broke B-05. Requires both install paths live in Phase 17. | ✓ |
| Standalone path, two models | One install path, swap the configured model. Much cheaper; leaves the known-failure combination untested until Phase 22. | |
| Both paths, three models | Two production pairings plus a third model. Strongest evidence, largest Phase 17. | |

**User's choice:** Both production paths

### Q4 — Which hooks in SPIKE-02's matrix?

| Option | Description | Selected |
|--------|-------------|----------|
| Every hook the skill depends on | `before_prompt_build`, `after_tool_call`, `before_agent_finalize`, `subagent_spawned`, `subagent_ended`, plus `session_end` recorded as known-broken (#155696) rather than skipped. Each is load-bearing for a named requirement. | ✓ |
| Only the hooks being newly wired | The 2.0-new surface only; assumes existing hooks survived the version bump. | |
| Whole hook catalog | Full documented catalog for future work. Most reusable, significant extra host time. | |

**User's choice:** Every hook the skill depends on

---

## Findings artifact shape

### Q1 — Where do the determinations live?

| Option | Description | Selected |
|--------|-------------|----------|
| Spike dirs + wrap into skill | `.planning/spikes/007–011/README.md` per CONVENTIONS.md, MANIFEST rows, then wrapped into a project-local findings skill. How v1.4's six spikes fed Phases 12–16. | ✓ |
| Phase SUMMARY docs only | Standard GSD prior-phase artifacts. Fewer moving parts; anti-pattern rules cap transitive SUMMARY reads and Phase 24 is seven phases downstream. | |
| New v2.0 findings skill | Separate `spike-findings-openclaw-2-0` skill. Cleaner era separation; two skills to load, and some facts span both. | |

**User's choice:** Spike dirs + wrap into skill

### Q2 — Working code or prose for Phase 19?

| Option | Description | Selected |
|--------|-------------|----------|
| Throwaway probe + verbatim schema | Probes stay in spike dirs as evidence; artifacts include `sqlite3 .schema` and sample rows captured literally; Phase 19 writes production code from scratch. | ✓ |
| Reference implementation to lift | A working reader Phase 19 ports in. Fastest Phase 19; risks spike-grade code becoming production by inertia. | |
| Prose only | No code artifacts retained. Cheapest to review; Phase 19 re-establishes schema facts on a possibly-drifted host. | |

**User's choice:** Throwaway probe + verbatim schema

### Q3 — How do 2.0 facts land in the existing skill?

| Option | Description | Selected |
|--------|-------------|----------|
| Re-scope to whole-project findings | Broaden the skill description and CLAUDE.md routing, add a new topic reference file alongside the existing four. References are already split by topic, not milestone. | ✓ |
| Add 2.0 section, keep NemoClaw scope | Least churn; risks the routing description not matching contents so Phase 19 work never loads it. | |
| Decide at wrap-up time | Defer until findings are in hand. Leaves a gap if the phase ends without the call being made. | |

**User's choice:** Re-scope to whole-project findings

### Q4 — What counts as evidence?

| Option | Description | Selected |
|--------|-------------|----------|
| Verbatim command + output, dated | Exact command, raw output pasted (trimmed not paraphrased), host, date, and OpenClaw/NemoClaw/Node versions per claim. A claim you can't re-run is indistinguishable from one inferred from docs. | ✓ |
| Claim plus confidence rating | HIGH/MEDIUM/LOW with a one-line basis, matching the research docs' convention. A MEDIUM with no transcript can't be audited. | |
| Transcript logs attached | Full session transcripts saved alongside. Maximum auditability; large files, readers must dig. | |

**User's choice:** Verbatim command + output, dated

---

## Host & sandbox topology

### Q1 — One host or two?

| Option | Description | Selected |
|--------|-------------|----------|
| One host, both paths | `52.90.9.242` carries standalone OpenClaw + Docker and NemoClaw/OpenShell; the paths coexist by design since NemoClaw already needs a host-side OpenClaw-reading cron. Named risk: cross-contamination, so findings must record their context. | ✓ |
| Two hosts | Separate hosts, cleanest evidence. Requires a second host REQUIREMENTS.md hasn't named; doubles SPIKE-00. | |
| One host, sequential phases | Standalone completes and is torn down before NemoClaw installs. Avoids contamination without a second host; doesn't exercise the coexistence the NemoClaw path relies on. | |

**User's choice:** One host, both paths

### Q2 — What form does "reproducible" take?

| Option | Description | Selected |
|--------|-------------|----------|
| Idempotent script in-repo | `provision-2-0-host.sh` under the spike dir, re-runnable, detection-gated, recording version floors. Phases 22 and 24 are both re-provisioning events. | ✓ |
| Written runbook | Markdown checklist, no script. Easier to adapt; every re-provision is manual and drifts. | |
| Script plus cloud-init | Script and an unattended cloud-init wrapper. Best for Phases 22/24; extra artifact to keep correct. | |

**User's choice:** Idempotent script in-repo

### Q3 — Version policy, given `latest` was 2026.9.6 and NemoClaw 0.0.128 provisions 2026.9.1 in-sandbox

| Option | Description | Selected |
|--------|-------------|----------|
| Provision latest, record exactly | Install what `latest` resolves to, let NemoClaw provision what it provisions, record both verbatim. The gate floor is already fixed at 2026.8.1; the spike needs to know how the runtime behaves as users actually get it. | ✓ |
| Pin exact versions in the script | Byte-identical re-provisioning. The pin goes stale and later tests a runtime no user has. | |
| Provision at the floor exactly | Install `2026.8.1` precisely. Best for validating the gate boundary; least representative, and the in-sandbox version still isn't ours to choose. | |

**User's choice:** Provision latest, record exactly

### Q4 — Credential posture?

| Option | Description | Selected |
|--------|-------------|----------|
| Real keys, spike-scoped | Real model key and real Revenium API key, with the `api.revenium.ai` egress preset per spike 002. SPIKE-01's and SPIKE-04's bars are unanswerable without real turns; v1.4 spike 003 stalled at PARTIAL on a dummy key. | ✓ |
| Real inference, no Revenium | Genuine token counts, no meter call. Avoids spike traffic in Revenium; leaves the egress-policy step unproven on 2.0. | |
| Real keys plus a scratch Revenium scope | Throwaway source/product so spike traffic never mixes with production. Cleanest separation; more setup and teardown. | |

**User's choice:** Real keys, spike-scoped

---

## Claude's Discretion

No area was handed over wholesale. Left to the planner within the bars set above:

- Soak-window and SPIKE-03 determinism-run durations
- Spike-dir numbering granularity (one dir per SPIKE-nn vs one per question actually asked)
- Whether `MANIFEST.md`'s Requirements section accrues 2.0 constraints as they are found
- The escalation path if no read candidate clears the fidelity bar

## Deferred Ideas

- **Gate A exit-1 on the NemoClaw install path** (`nemoclaw-install-gate-a-exit1`) — belongs to Phase 20/22 where plugin gates are rebuilt against 2.0, not to a fact-finding spike.
- **Backfilling archived pre-2.0 JSONL sessions into Revenium** — already Out of Scope in REQUIREMENTS.md; noted because the SQLite investigation will surface the archived files.
- **`16-review-deferred-findings`** (reviewed, not folded) — WR-04 and IN-03 are minor docs/test polish against v1.4 code; matched on incidental keywords. Left pending.
