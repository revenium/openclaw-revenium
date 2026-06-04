# Phase 9: Guardrail Event Metering - Context

**Gathered:** 2026-06-04
**Status:** Ready for planning

<domain>
## Phase Boundary

Make every guardrail **enforcement event** observable in Revenium as a discrete `GUARDRAIL` transaction. Three event types: a **halt** (autonomous-mode hard-limit block), a **warn** (a rule crossing its soft `warnThreshold` while still under `hardLimit`), and a **shadow** would-have-halted. Each event is metered once per onset (transition-gated + ledger-deduped), attributed to the work it interrupted, and fully fail-open so metering can never break enforcement. Also: remove the dead/buggy operation-type `GUARDRAIL` heuristic from `report.sh`.

In scope: emitting GUARDRAIL transactions from `guardrail-check.sh`; adding warn-onset transition detection; a dedup ledger; attribution lookup; removing the report.sh heuristic.
Out of scope (deferred): per-tick API-poll overhead metering; the non-autonomous hard-block "warned" signal as a separate transaction; tool-event metering (Phase 10).
</domain>

<decisions>
## Implementation Decisions

### Which "warn" to meter
- **D-01:** "Warn" = the **soft warn-threshold** signal — a rule whose per-rule `state` becomes `'warn'` (currentValue ≥ `warnThreshold` but < `hardLimit`). Fires in BOTH autonomous and non-autonomous mode. This is the "approaching budget" meaning.
- **D-02 [informational]:** The top-level non-autonomous `warned` field (hardLimit breached but autonomousMode off → warn-and-ask) is **NOT** metered as a guardrail transaction in this phase (deferred). Only soft-threshold warn, halt, and shadow are metered. *(Negative/out-of-scope decision — nothing to implement; tracked as deferred below, not by any plan.)*
- **D-03:** `guardrail-check.sh` currently emits only `HALT_TRANSITION` (D-11) and `shadow_transitions` (D-12). **Warn-onset transition detection must be ADDED** — mirror the existing `shadow_transitions` prev-vs-now comparison (`prev_rules_by_id[ruleId].state != 'warn'` and now `== 'warn'`), so it fires once per warn onset, not every tick while warned, and re-fires after a warn→ok→warn recovery cycle.

### Event types & task_type labels
- **D-04:** Three GUARDRAIL transactions, distinguished by `--task-type`:
  - halt → `budget_guardrail_halt` (from existing `halt_transition` / `haltedRule`)
  - warn → `budget_guardrail_warn` (new warn-onset detection)
  - shadow → `budget_guardrail_shadow` (from existing `shadow_transitions`)
- **D-05:** Mechanism = `revenium meter completion --operation-type GUARDRAIL` (zero tokens), `--stop-reason COST_LIMIT`. Revenium renders `operationType` as the transaction "type" column, so GUARDRAIL shows alongside Chat/Tool Call (stakeholder-confirmed).

### Where it's emitted
- **D-06:** Emit the meter calls **directly from `guardrail-check.sh`** (it owns the transition signals). Do NOT route through report.sh. This means guardrail-check.sh must gain a self-contained, fail-open `revenium meter completion` invocation + attribution lookup + dedup ledger read/write.

### Attribution
- **D-07:** Each guardrail transaction carries:
  - `--agent openclaw-<root_session_id>` of the **most-recent active root session** (newest non-cron session file in `SESSIONS_DIR`, resolved to its root via `get-root-session-id.py`).
  - `--agentic-job-id` of the **most-recently-opened open job** read from the jobs ledger (`JOB:<id>:created:` lines minus `JOB:<id>:outcome:` lines; pick the newest still-open).
- **D-08:** If **no** job is open at event time: omit `--agentic-job-id` (still attach `--agent`). If multiple are open: use the most-recently-opened one (single event, not one-per-job).

### Synthetic completion fields
- **D-09:** Model/provider = **descriptive constants** marking this as a non-AI system event (e.g. `--provider revenium --model guardrail-enforcement`). Zero input/output/total tokens, zero cost. Exact strings are Claude's discretion (see below) but must be stable/constant, not derived from session data.

### Dedup / idempotency
- **D-10:** Primary dedup = the prev-vs-now **state-transition detection** in the Python block (only the onset edge fires), mirroring how `shadow_transitions` already works. Secondary backstop = a new ledger `revenium-guardrail.ledger` keyed per `GUARDRAIL:<type>:<ruleId>:<onset-marker>` so a crash/re-run within the same episode never double-emits. Halt may reuse the existing `haltedAt` value as its onset-marker (mirrors the `JOB:halt:<haltedAt>` pattern in report.sh handle_halt).

### Fail-open (non-negotiable)
- **D-11:** All metering is best-effort and MUST NOT change guardrail-check.sh's exit-0 fail-open posture: the status-file write, halt/warn/shadow notifications, and the cron tick must all succeed even if every meter call fails. Metering runs AFTER the status file is durably written and notifications are dispatched.

### report.sh cleanup
- **D-12:** Remove the dead operation-type `GUARDRAIL` branch in `report.sh` (the `select(.type=="toolCall")|.arguments | grep "budget-status.json"` check at ~line 849). It targets the wrong filename and would tag every turn. After removal, report.sh completions are only ever `CHAT` (stopReason stop) or `TOOL_CALL` (stopReason toolUse).

### Claude's Discretion
- Exact constant strings for `--model`/`--provider` (D-09), the precise ledger onset-marker format for warn/shadow (D-10), and the `--request-duration`/timestamp values for the synthetic completion. Planner/researcher to finalize, consistent with the locked decisions above.
- Whether warn/shadow attribution reuses the exact same lookup helper as halt (likely yes — one shared `_emit_guardrail_event` shell function).
</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### The enforcement script being modified
- `scripts/guardrail-check.sh` — the cron enforcement stage. Key regions: Python state block (lines ~129–332) computes per-rule `state` ('ok'/'warn'/'block'), `halt_transition`, `halted_rule`, `shadow_transitions`; emits `KEY=value` lines (HALT_TRANSITION, HALTED_*, SHADOW_TRANSITIONS) parsed by the bash tail (lines ~335–446). Warn-onset detection + meter emission get added here. Preserve all D-09..D-15 decisions and the exit-0 fail-open posture.
- `scripts/report.sh` — §D-12 dead GUARDRAIL heuristic to remove (~line 849); also the reference for the patterns to mirror: `post_to_revenium` meter-completion argv builder (~line 240), `--agent "${REVENIUM_AGENT_PREFIX}${root_sid}"`, jobs-ledger open-job scan in `handle_halt` (~lines 1086–1105: `JOB:<id>:created` minus `JOB:<id>:outcome` via regex), and the `JOB:halt:<haltedAt>` dedup gate.
- `scripts/common.sh` — path constants: `GUARDRAIL_STATUS_FILE`, `SESSIONS_DIR`, `STATE_DIR`, and where to add a `GUARDRAIL_LEDGER_FILE` constant. `has_guardrails_cli`, `ensure_path`.
- `scripts/get-root-session-id.py` — resolves a session id to its root (for D-07 `--agent` attribution).
- `scripts/cron.sh` — runs report.sh → guardrail-check.sh → prune under one flock lock; confirms guardrail-check.sh runs after report.sh each tick.

### Requirements
- `.planning/REQUIREMENTS.md` — GRDEV-01..06 (this phase).

### Reference implementation (read-only context)
- `~/.hermes/skills/revenium/scripts/` (test host only) — hermes-revenium reference; note hermes does NOT meter guardrails this way, so do not copy blindly.

No external ADRs — design decisions are captured in this CONTEXT.md.
</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`shadow_transitions` detection** (guardrail-check.sh Python, ~lines 268–287): exact template for warn-onset detection — build `prev_rules_by_id`, compare prev state to now state, emit only on the onset edge. Warn detection is the same shape with `state == 'warn'`.
- **`handle_halt` open-job scan** (report.sh ~1086–1105): the regex that derives open jobs (`created` minus `outcome`) from the jobs ledger — reuse the logic for D-07/D-08 most-recently-opened-job lookup.
- **`JOB:halt:<haltedAt>` ledger gate** (report.sh ~line 1063/1200): the exactly-once dedup pattern to mirror for the new `revenium-guardrail.ledger`.
- **`post_to_revenium` argv array** (report.sh ~240): the canonical `revenium meter completion` flag set + bash-array discipline (`cmd+=(--flag "$val")`, never eval).

### Established Patterns
- **Fail-open posture:** guardrail-check.sh exits 0 on every preflight/failure path; atomic status writes via `tempfile.mkstemp`+`os.replace`. New metering must not weaken this (D-11).
- **Env-passing heredocs (Bash 3.2 safe):** all Python heredocs pass vars via environment, never `${}` inside `<<'PY'`. Follow this for any new Python.
- **Transition-only emission:** halt notifies only on false→true (D-11); shadow only on first breach (D-12). Warn/halt/shadow metering follows the same once-per-onset rule.
- **`JOBS_CLI_CAPABLE`-style capability + preflight gating:** guardrail-check.sh already gates on `command -v revenium`, `has_guardrails_cli`, `revenium config show`. Metering rides behind the same preflights.

### Integration Points
- guardrail-check.sh bash tail (after status write + notifications) → new `_emit_guardrail_event` calls for halt/warn/shadow.
- New `GUARDRAIL_LEDGER_FILE` (e.g. `${OPENCLAW_HOME}/revenium-guardrail.ledger`) — define in common.sh, read/write in guardrail-check.sh.
- Jobs ledger (`revenium-jobs.ledger`) — read-only consumer for open-job attribution.
- `report.sh` — only change is the D-12 heuristic removal (no behavior coupling to the new path).
</code_context>

<specifics>
## Specific Ideas

- Stakeholder confirmed Revenium renders completion `operationType` as the transaction type column (CHAT→Chat, TOOL_CALL→Tool Call, GUARDRAIL→Guardrail) — this is the entire mechanism for issue 3.
- Live validation approach (from v1.1 work): test on host `172.16.1.247` via the cron pipeline + a forced halt/warn, confirm a GUARDRAIL transaction lands via `revenium ... ` and clean up after. Hermetic tests should extend `tests/` (guardrail-check has a test surface; report.sh argv tests exist).
</specifics>

<deferred>
## Deferred Ideas

- **Non-autonomous hard-block ("warned") transactions** (D-02) — could meter the warn-and-ask block state as a distinct `budget_guardrail_blocked` transaction in a future phase.
- **Per-tick guardrail API-poll overhead metering** — out of scope (volume/noise); listed as GRDEV-F1 future requirement.
- **One-per-open-job guardrail events** — rejected for v1.2 (single event, most-recently-opened job). Could revisit if per-job enforcement attribution is needed.
- **Tool registry + tool-event metering** — Phase 10.

None of these block Phase 9.
</deferred>

---

*Phase: 9-Guardrail Event Metering*
*Context gathered: 2026-06-04*
