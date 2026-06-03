# Phase 4: Task Metering & Attribution - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-03
**Phase:** 4-task-metering-attribution
**Areas discussed:** Task marker mechanism, Subagent root attribution, Filter migration / break, Classification trigger & per-task-type rules

---

## Task Marker Mechanism

### Granularity
| Option | Description | Selected |
|--------|-------------|----------|
| Timestamp-correlated | Marker carries ts; report.sh tags each completion with the most recent preceding marker's task_type. Per-turn accuracy. | ✓ |
| Session-level latest-wins | One task_type per session; all batched completions get the current label. Trivial but mislabels multi-task sessions. | |
| You decide | Claude picks. | |

### Storage
| Option | Description | Selected |
|--------|-------------|----------|
| Append-log JSONL | markers/<sid>.jsonl, one {ts, task_type} line per classification. Supports correlation, mirrors Hermes. | ✓ |
| Single marker file/session | markers/<sid>.json overwritten each turn. Simplest, loses history. | |
| You decide | Claude picks. | |

### Write path
| Option | Description | Selected |
|--------|-------------|----------|
| Helper script | write-marker.sh <task_type> stamps ts, validates label, resolves sid, appends. Robust. | ✓ |
| Direct file append | Agent appends JSON line via file tools. No new script but fragile. | |
| You decide | Claude picks. | |

### Pruning
| Option | Description | Selected |
|--------|-------------|----------|
| Prune in cron | Cron stage deletes markers older than ~7 days. Self-maintaining. | ✓ |
| No pruning in v1 | Let markers accumulate. Unbounded growth. | |
| You decide | Claude picks. | |

**User's choice:** Timestamp-correlated; append-log JSONL; helper script; prune in cron.
**Notes:** Full per-turn accuracy preferred over simplicity; aligns with Hermes intent and report.sh already parses per-line timestamps.

---

## Subagent Root Attribution

### v1 scope
| Option | Description | Selected |
|--------|-------------|----------|
| Resolve now, fail-open | Build resolver, ship --agent openclaw-{root}; fall back to self-sid on resolution failure. | ✓ |
| Defer correlation, self-root only | Every session reports as its own root. Doesn't satisfy criterion 4. | |
| You decide | Claude picks. | |

### Research gate
| Option | Description | Selected |
|--------|-------------|----------|
| Ship resolver + fallback | Build resolver with fail-open fallback regardless; research informs the algorithm. No phase blocked. | ✓ |
| Spike first, then decide | Pause planning for a research spike on the session model before committing. | |
| You decide | Claude picks. | |

**User's choice:** Resolve now with fail-open self-sid fallback; build the resolver with fallback baked in, no hard research gate.
**Notes:** OpenClaw has no SQLite state.db parent chain (Hermes' mechanism) — root must be derived from JSONL, where "subagent" appears. STATE.md flags this as a Phase 4 blocker to verify; fail-open keeps metering unblocked.

---

## Filter Migration / Break

### Filter shape
| Option | Description | Selected |
|--------|-------------|----------|
| STARTS_WITH:openclaw- | Base rules filter AGENT:STARTS_WITH:openclaw-; new REVENIUM_AGENT_PREFIX constant; report.sh ships --agent openclaw-{root}. | ✓ |
| Keep AGENT:IS, drop per-session | Static --agent OpenClaw; mutually exclusive with subagent rollup. | |
| You decide | Claude picks. | |

### Existing installs
| Option | Description | Selected |
|--------|-------------|----------|
| Detect + prompt reconfigure | Detect legacy AGENT:IS:OpenClaw rules / config version marker; one-time notice to reconfigure. No silent rewrite. | ✓ |
| Document only | Note breaking change in README/SKILL.md; rely on re-run. Silent guardrail failure risk. | |
| You decide | Claude picks. | |

**User's choice:** AGENT:STARTS_WITH:openclaw- + REVENIUM_AGENT_PREFIX constant; detect legacy installs and prompt reconfigure.
**Notes:** Supersedes Phase 3 D-23; honors Phase 3 D-02 no-silent-migration ethos. Changing --agent silently breaks Phase 3 AGENT:IS:OpenClaw rules, so detection guards a budget guardrail from failing silently.

---

## Classification Trigger & Per-Task-Type Rules

### Trigger
| Option | Description | Selected |
|--------|-------------|----------|
| Mirror Hermes trigger | Classify if non-read-only tool OR >200 words OR multi-step; skip if ≤2 sentences AND zero tools. | ✓ |
| Classify every turn | Always write a marker. Simpler but noisy on trivial turns. | |
| You decide | Claude picks. | |

### Per-task-type rules
| Option | Description | Selected |
|--------|-------------|----------|
| Full picker, gated on CLI | Port Hermes multi-select picker from task-taxonomy.json; each rule filters AGENT:STARTS_WITH:openclaw- AND a TASK_TYPE clause; skip gracefully if CLI lacks TASK_TYPE filter. | ✓ |
| Minimal yes/no | All 8 labels or none. Less code, less flexible. | |
| You decide | Claude picks. | |

**User's choice:** Mirror Hermes substantive-turn trigger; port the full per-task-type picker gated on confirming CLI TASK_TYPE filter support.
**Notes:** Default to `unclassified` when no marker is written. TASK_TYPE filter CLI support is an open research item; picker offer is skipped gracefully if unsupported.

---

## Claude's Discretion

- Final marker-prune age threshold (~7 days suggested).
- Legacy-install detection mechanism (live filter inspection vs config.json version marker).
- Which cron stage owns marker pruning (report.sh vs guardrail-check.sh).
- Exact root-resolution algorithm over OpenClaw JSONL (subject to research).
- Whether per-task-type rules reuse the base rule's hard-limit prompt flow or ask separately.

## Deferred Ideas

- Hermes jobs / --agentic-job-id arc correlation — out of scope for v1.
- Code-side classifier plugin + OpenClaw lifecycle hooks for automatic marker writing — blocked on hooks research; agent-driven writes used instead.
- Tool-event-level metering (tool-event-report.sh) — out of scope.
