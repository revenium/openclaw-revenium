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

## Cross-Milestone Trends

### Process Evolution

| Milestone | Phases | Plans | Key Change |
|-----------|--------|-------|------------|
| v1.0 | 4 | 14 | Established GSD wave execution, code-review + debug gates, live-tenant verification |

### Cumulative Quality

| Milestone | Tests | Notable |
|-----------|-------|---------|
| v1.0 | ~39 (bash + python) | 2 critical review findings fixed; 1 production correlation bug fixed post-ship |

### Top Lessons (Verified Across Milestones)

1. (v1.0) Deterministic-input flakes are bugs; live-platform verification beats stub argv checks.
