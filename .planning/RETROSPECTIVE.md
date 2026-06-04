# Project Retrospective

*A living document updated after each milestone. Lessons feed forward into future planning.*

## Milestone: v1.0 — Budget Guardrails & Metering

**Shipped:** 2026-06-03
**Phases:** 4 | **Plans:** 14 | **Tasks:** 26

### What Was Built
- A global OpenClaw skill that gates on the `revenium` binary and loads via single-line JSON metadata (Phase 1).
- Agent-guided setup of API key + budget rules with idempotent re-runs (Phase 2).
- Guardrails-native enforcement replacing the legacy alert model: `setup-guardrails.sh`, `guardrail-check.sh`, atomic `guardrail-status.json`, halt + warn-and-ask flow (Phase 3).
- Task-type metering (8-label taxonomy, TASK CLASSIFICATION directive, `--task-type` on every completion) and root-session attribution (`--agent openclaw-<root>`, `AGENT:STARTS_WITH` rules, per-task budget picker) (Phase 4).

### What Worked
- **Wave-based parallel execution** with worktree isolation (Phase 4: Wave 2 ran 04-02/04-03 concurrently on disjoint files) merged cleanly with a post-merge test gate.
- **Live debugging against the real Revenium tenant** turned a vague "all three broken" report into precise root causes fast — the `revenium metrics completions` query immediately showed two of three were actually working (agent attribution) and isolated the real bug (task-type correlation).
- **Adversarial code review caught real defects** (timestamp injection, silent metering loss) that unit tests passed over.

### What Was Inefficient
- **A 50% test flake was nearly shipped as "pre-existing/defer."** It was actually a real production bug (`pipefail`+SIGPIPE on `revenium … --help | grep -q` randomly skipping the per-task picker). Lesson: a coin-flip "flake" with fixed inputs is a bug, not noise — chase it.
- **PROJECT.md drifted three phases behind reality** — still described the alert model after Phase 3 replaced it. Per-phase PROJECT.md evolution was skipped until milestone close.
- **The NP-1 timestamp-precedence correlation design was wrong from the start** — it assumed markers precede completions, but the agent writes the marker via a tool call *after* the turn's completion. Caught only by live data, after ship.

### Patterns Established
- **`set -euo pipefail` + external-producer pipes are dangerous:** `cmd | grep -q` SIGPIPEs the producer; capture into a variable then grep via here-string instead.
- **Env-passing heredoc discipline:** never interpolate untrusted session data into `python3 -c` strings (pass via env, read `os.environ`).
- **Verify attribution/metering against the live platform**, not just argv-capture stubs — stubs proved the call shape but not ingestion or schema.

### Key Lessons
1. A reproducible ~50/50 failure with deterministic inputs is a real defect (often hash/scheduling/SIGPIPE), never "just flaky."
2. For agent-written side-channel data (markers), correlate by a stable key (completion_id), not by timestamp ordering — turn lifecycle makes ordering unreliable.
3. Evolve PROJECT.md per phase, not just at milestone close, or it silently rots.
4. "It's not working" often means "the data is right but the *view/rule* doesn't match it" — the legacy `AGENT:IS:OpenClaw` rule couldn't see `openclaw-<sid>` spend.

### Cost Observations
- Model mix: executors/verifier/debugger on sonnet; orchestration on opus.
- Notable: worktree-isolated parallel waves + delegated subagents kept orchestrator context lean across a large phase + full review + debug cycle.

---

## Milestone: v1.1 — Agentic Job Tracking

**Shipped:** 2026-06-04
**Phases:** 4 (5–8) | **Plans:** 10 | **Tasks:** 14

### What Was Built
- Job declaration foundation: 11-label `job-taxonomy.json` + `write-job-marker.sh` (sanitize→allowlist→flock+O_APPEND) + arc-boundary JOB DECLARATION directive (Phase 5).
- Job lifecycle wiring: ledger-gated `jobs create` / `--agentic-job-*` stamping / `jobs outcome`, 409-as-success, fail-open behind a `JOBS_CLI_CAPABLE` probe (Phase 6).
- Root-session job rollup: subagent completions inherit the root session's job; root-only gates prevent duplicate/sub-session jobs (Phase 7).
- Halt → CANCELLED: `handle_halt()` closes open jobs CANCELLED or mints a synthetic `guardrail-halt-<hex>` interrupted job (Phase 8).

### What Worked
- **Ported a proven model (hermes-revenium job tracking) onto a new substrate** (agent-written markers) instead of inventing — kept the data model stable while swapping the transport.
- **Capability-probe + fail-open everywhere** meant the entire job layer could ship without ever endangering v1.0 task-type metering.

### What Was Inefficient
- **The whole pipeline never fired in production** — OpenClaw loads `SKILL.md` on-demand, so the "declare every turn" directives were never in the agent's context. Found only by live debugging on the test host *after* ship; fixed by moving completion-gate directives into `AGENTS.md` via `post-install.sh`.
- **Retrospective was skipped at the v1.1 close** (backfilled here at v1.2) — the milestone-close retrospective step is easy to drop.

### Patterns Established
- **Per-turn agent directives must live in `AGENTS.md`, not `SKILL.md`** — SKILL.md is on-demand; AGENTS.md is read before every response. Only a hard *completion-gate* framing reliably triggers the agent.
- **Marker-race tolerance:** when a correlated id may not be resolvable yet (root job id on first tick), omit-and-retry rather than ship a wrong/sub-session id.

### Key Lessons
1. A feature can pass every hermetic test and still never execute in production if its *trigger* lives in a file the runtime doesn't load — verify the trigger path live, not just the logic.
2. The retrospective + UAT steps at milestone close are the easiest to skip and the ones you most regret skipping.

### Cost Observations
- Model mix: executors/verifier on sonnet; orchestration + live debug on opus.
- Notable: marker architecture reused wholesale from v1.0 kept v1.1 cheap — 4 phases in one day.

---

## Milestone: v1.2 — Metering Completeness

**Shipped:** 2026-06-04
**Phases:** 2 (9–10) | **Plans:** 6 | **Tasks:** 10

### What Was Built
- Guardrail-event metering: one zero-token `GUARDRAIL` transaction per halt/warn/shadow onset, transition-gated + ledger-deduped + attributed to root agent/open job, fail-open Section M in `guardrail-check.sh`; dead `report.sh` GUARDRAIL heuristic removed (Phase 9).
- Tool registry + tool-event metering: `TOOLS_CLI_CAPABLE` probe, create-once `revenium tools create`, per-`toolCall` `meter tool-event` with explicit `--success` and no double-count against `TOOL_CALL` completions; anchored prefix-safe ledger dedup (Phase 10).

### What Worked
- **The v1.1 lesson paid off immediately** — both phases were built fail-open and capability-probed from the start; no production-trigger surprises this milestone.
- **Adversarial code review caught two real BLOCKERs** — unanchored ledger dedup false-matching prefixes (`read` vs `read-file`); fixed and locked with a prefix-collision regression test before ship.
- **RED→GREEN argv harnesses per phase** (`test_guardrail_argv.sh`, `test_report_tool_argv.sh`) gave a crisp definition-of-done for each metering contract.

### What Was Inefficient
- **The `--tool-type` enum was wrong until probed live** — `BUILTIN` is rejected server-side (use `CUSTOM`/`MCP_SERVER`); dry-run/stubs never caught it. Same "stubs prove shape, not acceptance" lesson as v1.0, recurring.
- **Phase 9 live E2E (guardrail halt → GUARDRAIL transaction) still deferred** — the one scenario that needs a forced halt on the real host carried out of the milestone again.

### Patterns Established
- **Ledger dedup must be anchored/exact-match** (`grep -qxF`, not substring) — substring dedup silently swallows any id that is a prefix of another.
- **Probe strict server-side enums against the live tenant** — argv stubs accept anything; the API does not.

### Key Lessons
1. Carrying the same "verify against the live platform, not stubs" lesson into design (fail-open + probe-first) eliminated the post-ship scramble that defined v1.0 and v1.1.
2. Substring matching on identifiers is a latent dedup/attribution bug class — anchor it by default.
3. A UAT scenario that needs destructive live state (forcing a halt) will keep deferring unless explicitly scheduled — track it as a standing follow-up, not a per-milestone afterthought.

### Cost Observations
- Model mix: executors/verifier/code-reviewer on sonnet; orchestration on opus.
- Sessions: smallest milestone (2 phases) — leaned on prior infrastructure; argv-harness-first kept rework low.

---

## Cross-Milestone Trends

### Process Evolution

| Milestone | Phases | Plans | Key Change |
|-----------|--------|-------|------------|
| v1.0 | 4 | 14 | Established GSD wave execution, code-review + debug gates, live-tenant verification |
| v1.1 | 4 | 10 | Reused marker architecture wholesale; learned per-turn directives must live in AGENTS.md |
| v1.2 | 2 | 6 | Designed fail-open + probe-first from the start — no post-ship production-trigger scramble |

### Cumulative Quality

| Milestone | Tests | Notable |
|-----------|-------|---------|
| v1.0 | ~39 (bash + python) | 2 critical review findings fixed; 1 production correlation bug fixed post-ship |
| v1.1 | 71 cumulative hermetic | Pipeline shipped non-functional (SKILL.md not loaded), fixed live via AGENTS.md injection |
| v1.2 | + guardrail/tool argv harnesses | 2 code-review BLOCKERs (unanchored ledger dedup) fixed + regression-locked pre-ship |

### Top Lessons (Verified Across Milestones)

1. (v1.0, recurs v1.2) Stubs prove call *shape*, not platform *acceptance* — deterministic-input flakes are bugs; verify against the live tenant (and probe strict server-side enums).
2. (v1.1) A feature's *trigger* must live where the runtime actually reads it — passing tests ≠ executing in production.
3. (v1.2) Anchor identifier matching (dedup, attribution) by default; substring matching is a latent bug class.
4. (v1.1→v1.2) Carry hard-won "verify live" lessons into *design* (fail-open, probe-first) — it eliminates the post-ship scramble.
5. (all) Milestone-close retrospective + destructive live-UAT scenarios are the easiest steps to skip and the ones most regretted.
