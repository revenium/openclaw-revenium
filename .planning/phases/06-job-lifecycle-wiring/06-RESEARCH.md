# Phase 6: Job Lifecycle Wiring - Research

**Researched:** 2026-06-03
**Domain:** Bash shell scripting (`report.sh`), `revenium` CLI job lifecycle, idempotent ledger-driven cron processing
**Confidence:** HIGH

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01: Best-effort stamping + server-side rollup.** Stamp `--agentic-job-id/-name/-type` **only on completions still unshipped when the closing marker is seen** (typically the arc's final tick, matched via the marker's `completion_id` exact-match, with timestamp fallback — the same correlation mechanism as task-type). The remainder of the arc's spend rolls up server-side via the existing `--agent "openclaw-<root_sid>"`.
- **D-02: Do NOT fight the `TX:` ledger / offset model.** No backfill, no re-metering of already-shipped completions. Completion ledger and offset arithmetic stay untouched.
- **D-03: A job marker with no stampable same-tick completion still fires create + outcome.** Zero same-tick completions getting the job id is expected; the job is still created and closed, spend rolls up via `--agent`.
- **D-04: Omit `--environment`.** `jobs create` ships `--agentic-job-id --name --type --quiet` only.
- **D-05: `--name` ← marker `job_name`, `--type` ← marker `job_type`** (already taxonomy-validated at write time).
- **D-06: Idempotency = ledger-gated + 409-as-success.** Skip `create` if jobs ledger already has `JOB:<id>:created:`. Treat CLI exit 0 **and** HTTP-409/"already exists"/"conflict" in output as success-equivalent before writing the ledger row.
- **D-07: Execution-result-only.** `jobs outcome <id> --result SUCCESS|FAILED|CANCELLED` (from marker `status`). **Never** send `--outcome-type`. Diverges from Hermes' SUCCESS→CONVERTED mapping.
- **D-08: `failure_reason` rides via `--metadata`** (FAILED only). Attach as `--metadata '{"failure_reason":"..."}'` (json.dumps). Omit `--metadata` otherwise.
- **D-09: Outcome gated on create confirmed.** Skip outcome if `JOB:<id>:created:` not yet in ledger (re-attempt next tick); skip + idempotent if `JOB:<id>:outcome:` already present. Same 409-as-success rule. Natural single-tick order: **create → (stamp same-tick completion) → outcome**.
- **D-10: Separate ledger file `revenium-jobs.ledger`** (sibling to `revenium-reported.ledger` under `OPENCLAW_HOME`). Row formats: `JOB:<agentic_job_id>:created:<unix_ts>` and `JOB:<agentic_job_id>:outcome:<unix_ts>:<STATUS>`. Idempotency gates: `grep -q "^JOB:<id>:created:"` / `"^JOB:<id>:outcome:"`. `touch` at startup like the existing ledger.
- **D-11: One-time CLI capability probe per tick** (`JOBS_CLI_CAPABLE`). At startup run `revenium jobs --help` AND `revenium meter completion --help | grep -- '--agentic-job-id'`; both must pass. On failure, log once and skip **all** job work — metering ships byte-identical to v1.0. Cache the boolean for the whole tick.
- **D-12: All job CLI calls are best-effort, never abort.** Capture output + exit code, `warn` on failure, never `exit`/`return` out of the session loop or block a `meter completion` call. A `jobs` failure must not advance/block the `TX:` offset logic (that gate stays driven solely by completion-post success, per CR-02).

### Claude's Discretion
- Exact placement of the job-marker read + per-completion job resolution inside `process_session` (parallel to the two-phase task_type lookup). Decide: extend the existing single markers-cache Python read to also emit job rows, or add a sibling read.
- Whether `jobs create` fires in-loop when the closing marker is encountered vs. a pre-scan pass (OpenClaw's single-session, arc-close model likely needs only the in-loop path).
- Exact `--agentic-job-name`/`--agentic-job-type` plumbing through `post_to_revenium` (new params appended to the positional arg list, conditionally added to `cmd` only when non-empty and `JOBS_CLI_CAPABLE`).
- Log/warn wording, `unix_ts` precision (Hermes uses `%.3f`), stale-job warn threshold (Hermes `REVENIUM_JOBS_STALE_SECONDS=600`) — adopt or simplify.
- Test strategy: extend `tests/stub-revenium.sh` to fake `jobs create`/`jobs outcome` and add a `report.sh` job-lifecycle test alongside `tests/test_report_argv.sh`.

### Deferred Ideas (OUT OF SCOPE)
- **Full-arc per-completion stamping / backfill** — rejected for Phase 6 (D-02).
- **Root-session job rollup** (subagent completions ship the root's `agentic_job_id`) — **Phase 7 (JROLL)**; do not implement Hermes `owning_job_id` resolution here.
- **Halt → CANCELLED interrupted-job record** — **Phase 8 (JHALT)**.
- **`--outcome-type CONVERTED` / business-outcome metrics** — JOUT-01, future milestone.
- **Per-job-type budget rules** — JGUARD-01, future milestone (observability-only this milestone).
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| JLIFE-01 | `report.sh` opens each declared job via `revenium jobs create --agentic-job-id --name --type --environment` exactly once, ledger-gated and idempotent across cron ticks | CLI flags verified live (§Standard Stack); ledger-gate + 409 pattern documented (Pattern 2); D-04 omits `--environment` |
| JLIFE-02 | Every metered completion belonging to a job is stamped with `--agentic-job-id`, `--agentic-job-name`, `--agentic-job-type` on `meter completion` | `post_to_revenium` chokepoint mapped (report.sh:212-303); three flags verified on live CLI; D-01 best-effort same-tick stamping via existing correlation |
| JLIFE-03 | Terminal outcome via `revenium jobs outcome <id> --result SUCCESS\|FAILED\|CANCELLED` once per job (ledger-gated), reading result from marker `status` | `jobs outcome` signature verified live; `--metadata` for `failure_reason` (D-08); create-confirmed gate (D-09) |
| JLIFE-04 | Job tracking fails open — any `jobs` CLI error / absent subcommand caught + logged without blocking task-type metering or guardrail checks | `JOBS_CLI_CAPABLE` dual-probe (Pattern 1); best-effort capture-exit-and-warn (Pattern 4); CR-02 offset gate must stay decoupled |
| JLIFE-05 | Jobs ledger persists created/closed job IDs so re-runs never duplicate `create`/`outcome` | Separate `revenium-jobs.ledger` (D-10); `grep -q "^JOB:..."` gates (Pattern 2/3) |
</phase_requirements>

## Summary

Phase 6 is a **pure bash modification of `scripts/report.sh`** plus a new sibling ledger file. There are NO external packages to install — the only runtime dependencies (`revenium`, `jq`, `python3`) are already guarded at the top of `report.sh`. The work is a faithful, *narrowed* port of the proven Hermes job-lifecycle machinery: the dual CLI-capability probe, ledger-gated + 409-as-success `jobs create`, per-completion `--agentic-job-*` stamping, and ledger-gated `jobs outcome`. OpenClaw narrows Hermes in four ways the planner must honor: (1) **no `--environment`** (D-04, OpenClaw has no source column); (2) **no `--outcome-type CONVERTED`** (D-07, observability-only); (3) **single-session, in-loop create+outcome from one arc-close marker** rather than Hermes' split arc-open/arc-close two-stage queue (D-09); (4) **no `owning_job_id` root-rollup machinery** (that is Phase 7).

All four `revenium` CLI surfaces were **verified against the live CLI on this machine (2026-06-03)**: `jobs create --agentic-job-id --name --type --environment --quiet`, `jobs outcome <agenticJobId> --result --metadata`, and `meter completion --agentic-job-id --agentic-job-name --agentic-job-type`. The `--result` enum is exactly `SUCCESS, FAILED, CANCELLED` (CLI marks it `(required)`), which matches the marker `status` allowlist 1:1 — no enum mapping needed.

The single highest-leverage correctness constraint is **do not disturb the `TX:` completion ledger or the offset arithmetic**. The existing CR-02 gate (`report.sh:693`) advances the offset only when `failed_count == 0`, and that gate is driven *solely* by `post_to_revenium` success. Job-CLI failures must never feed that gate, never `return`/`exit` the session loop, and never block a `meter completion` call (D-12). All job work is additive and fail-open.

**Primary recommendation:** Extend the existing markers-cache Python read in `process_session` to *also* emit `kind:"job"` rows (one cache, two row shapes), reuse the exact two-phase (completion_id → timestamp-fallback) correlation already proven for task-type, fire `jobs create` in-loop when the closing job marker is matched to a same-tick completion, stamp that completion's `meter completion` call via three new optional params on `post_to_revenium`, then fire `jobs outcome` immediately after a successful create (the single-session arc-close model collapses Hermes' two stages into one in-loop sequence). Gate everything behind `JOBS_CLI_CAPABLE` and the `revenium-jobs.ledger`.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| CLI capability probe (`JOBS_CLI_CAPABLE`) | report.sh startup (post-guards, before `main`) | — | One probe per cron tick; mirrors existing `revenium config show` guard at lines 96-109 |
| Job-marker read + correlation | `process_session` (per-session, markers-cache block) | Python heredoc | Same files (`markers/{sid}.jsonl`), same correlation engine as task-type |
| `--agentic-job-*` stamping | `post_to_revenium` (the `meter completion` cmd-array chokepoint) | — | Single place the completion command is built; mirrors `--trace-id`/`--is-streamed` optional blocks |
| `jobs create` / `jobs outcome` invocation | `process_session` (in-loop, single-session scope) | — | OpenClaw arc-close marker fires both in one tick (D-09); no cross-session queue needed |
| Cross-tick idempotency memory | `revenium-jobs.ledger` (filesystem) | — | Separate file keeps hot-path `TX:` dedup ledger single-purpose (D-10) |
| Fail-open discipline | every job-CLI call site | — | Capture exit + warn, never abort; keep out of CR-02 offset gate (D-12) |

## Standard Stack

This phase installs **no packages**. It uses only tools already present and guarded in `report.sh`.

### Core
| Tool | Version (verified) | Purpose | Why Standard |
|------|--------------------|---------|--------------|
| `revenium` CLI | Installed at `/opt/homebrew/bin/revenium`; `jobs` + `meter completion --agentic-job-*` subcommands present [VERIFIED: live CLI 2026-06-03] | `jobs create`, `jobs outcome`, `meter completion` stamping | The metering/lifecycle transport; already a hard guard at report.sh:96 |
| `jq` | `/opt/homebrew/bin/jq` [VERIFIED] | JSONL field extraction (existing) | Already guarded at report.sh:101 |
| `python3` | `/opt/homebrew/.../python3` [VERIFIED] | Marker parse, ts correlation, json.dumps for `--metadata` | Already used throughout report.sh; env-passing heredoc idiom established (T-04-09) |
| `bash` | 3.2+ compatible (no associative arrays used) | Host language | Existing report.sh constraint (bash 3.x compat, see report.sh:387) |

### Verified CLI Signatures (live CLI, 2026-06-03)

`revenium jobs create` [VERIFIED: live CLI]:
```
--agentic-job-id string   User-supplied external identifier (required) (required)
--environment string      Deployment environment (e.g. production)   ← OMIT per D-04
--name string             Human-readable job name
--type string             Job category (e.g. loan-processing)
--version string          Job version identifier                     ← not used
-q, --quiet               Suppress non-error output
```

`revenium jobs outcome <agenticJobId>` [VERIFIED: live CLI]:
```
Usage: revenium jobs outcome <agenticJobId> [flags]      ← id is a POSITIONAL arg, not a flag
--result string             Execution result: SUCCESS, FAILED, or CANCELLED (required) (required)
--metadata string           Additional metadata as JSON string
--outcome-type string       Business outcome type      ← DO NOT SEND per D-07
--outcome-value float64     ...                         ← DO NOT SEND
--outcome-currency string   ...                         ← DO NOT SEND
--reported-by string        ...                         ← DO NOT SEND
```

`revenium meter completion` (job flags) [VERIFIED: live CLI]:
```
--agentic-job-id string      Agentic job instance identifier — correlates all AI operations within one job execution
--agentic-job-name string    Human-readable agentic job name (UI display, analytics grouping)
--agentic-job-type string    Agentic job category/type (normalized to lowercase on ingest)
--agentic-job-version string ...   ← not used
```

**Critical signature facts:**
- `jobs outcome` takes the job id as a **positional** argument (`outcome <id> --result ...`), NOT `--agentic-job-id`. Mirror Hermes line 1213: `revenium jobs outcome "${outcome_id}" --result ...`.
- `--result` is CLI-`(required)` and its enum is **exactly** `SUCCESS | FAILED | CANCELLED` — identical to the marker `status` allowlist (`write-job-marker.sh:111`). No mapping.
- `meter completion` has exactly **one** `--agentic-job-id` slot — appending is REPLACE-semantics, but in Phase 6 single-session scope there is only ever one job per stamped completion, so this is a non-issue (it becomes load-bearing only in Phase 7).

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Separate `revenium-jobs.ledger` | Reuse `revenium-reported.ledger` with `JOB:` prefix | Rejected by D-10: pollutes the hot-path completion-dedup ledger; keep it single-purpose |
| In-loop create+outcome (D-09) | Hermes' two-stage `job_outcome_queue` accumulator (hermes-report.sh:49, 1163-1275) | Hermes needs the queue because it splits create (arc-open) from outcome (arc-close) across sessions; OpenClaw fires both from one arc-close marker in one session, so the queue is unnecessary complexity |
| Extend existing markers-cache read | Add a sibling Python read for job rows | Both viable (Claude's discretion); extending keeps one file-read per session (NP-1 perf), but two reads is simpler to reason about. Recommend extending. |

**Installation:** None. No `npm`/`pip`/`cargo`. Pure source edit + ledger `touch`.

## Package Legitimacy Audit

**Not applicable.** Phase 6 installs zero external packages. All runtime dependencies (`revenium`, `jq`, `python3`, `bash`) are pre-existing host tools already guarded at `report.sh:96-109`. No registry, no slopcheck surface. Nothing to audit.

## Architecture Patterns

### System Architecture Diagram

```
                    cron tick → report.sh main()
                                    │
            ┌───────────────────────┼─────────────────────────────┐
            │  STARTUP (once per tick, after existing guards)       │
            │  ─ touch revenium-jobs.ledger  (D-10)                 │
            │  ─ JOBS_CLI_CAPABLE = (jobs --help                    │
            │       AND meter completion --help|grep agentic-job-id)│  (D-11)
            └───────────────────────┬─────────────────────────────┘
                                    │
                    for each session file (process_session)
                                    │
        ┌───────────────────────────┴────────────────────────────────┐
        │  markers-cache Python read (report.sh ~332-360)              │
        │   reads markers/{sid}.jsonl ONCE, emits TWO row shapes:      │
        │    ─ task rows:  ts \t task_type \t completion_id  (today)   │
        │    ─ job rows:   ts \t agentic_job_id \t job_name \t         │
        │                  job_type \t status \t failure_reason \t     │
        │                  completion_id   (NEW: kind=="job")          │
        └───────────────────────────┬────────────────────────────────┘
                                    │
              per completion line (offset → total_lines, tail -n +N)
                                    │
        ┌───────────────────────────┴────────────────────────────────┐
        │  TWO-PHASE CORRELATION (mirror report.sh ~476-552)           │
        │   resolve task_type  (exists today)                          │
        │   resolve job        (NEW): does ANY job row match this      │
        │     completion via completion_id exact-match, then ts        │
        │     fallback? → (agentic_job_id, job_name, job_type, status, │
        │                  failure_reason)                             │
        └───────────────────────────┬────────────────────────────────┘
                                    │
            if matched job AND JOBS_CLI_CAPABLE:
                    ┌───────────────┴────────────────┐
                    │ 1. jobs create (idempotent)     │ ─ skip if JOB:<id>:created: in ledger (D-06)
                    │    409-as-success → ledger row  │ ─ best-effort, warn-not-abort (D-12)
                    └───────────────┬────────────────┘
                                    │
        ┌───────────────────────────┴────────────────────────────────┐
        │ 2. post_to_revenium(... + agentic_job_id/name/type)          │  (D-01, JLIFE-02)
        │    cmd+=(--agentic-job-id/-name/-type) ONLY when non-empty    │
        │    & JOBS_CLI_CAPABLE; existing TX: dedup + CR-02 gate        │
        │    UNCHANGED (offset advances on completion success only)     │
        └───────────────────────────┬────────────────────────────────┘
                                    │
                    ┌───────────────┴────────────────┐
                    │ 3. jobs outcome <id> --result S │ ─ skip if no JOB:<id>:created: yet (D-09)
                    │    (+ --metadata for FAILED)    │ ─ skip if JOB:<id>:outcome: present (D-09)
                    │    409-as-success → ledger row  │ ─ best-effort, warn-not-abort (D-12)
                    └─────────────────────────────────┘

    Completions NOT matched to the closing marker (prior ticks, already TX:-ledgered)
    are NEVER re-stamped (D-02); their spend rolls up server-side via --agent (D-01).
```

### Recommended Project Structure

No new files except the ledger (created at runtime). All code edits land in:
```
scripts/report.sh        # ALL Phase 6 logic (config block, probe, marker read, stamping, create/outcome)
tests/stub-revenium.sh   # extend: fake jobs create / jobs outcome (incl. 409 path)
tests/test_report_*      # new: test_report_jobs_argv.sh (or extend test_report_argv.sh)
~/.openclaw/revenium-jobs.ledger   # NEW runtime file (touch'd at startup)
```

### Pattern 1: Dual CLI-Capability Probe (D-11, JLIFE-04)
**What:** One-time per-tick boolean. Both subcommand families must answer for job work to run.
**When:** At report.sh startup, after the existing `revenium config show` guard (report.sh:106-109), before `main`.
**Example (port of hermes-report.sh:34-43):**
```bash
# Source: ../hermes-revenium/skills/revenium/scripts/hermes-report.sh:34-43
JOBS_CLI_CAPABLE=false
if revenium jobs --help >/dev/null 2>&1 && \
   revenium meter completion --help 2>&1 | grep -q -- '--agentic-job-id'; then
  JOBS_CLI_CAPABLE=true
else
  warn "revenium jobs/--agentic-job-id not available — job work skipped; metering continues as v1.0."
fi
```
Note: OpenClaw's `has_guardrails_cli()` in `common.sh:136-139` is the same two-subcommand-probe idiom; this is an established repo pattern.

### Pattern 2: Ledger-Gated + 409-as-Success Create (D-06, JLIFE-01/05)
**What:** Skip if ledger already records create; treat exit-0 OR 409/conflict in output as success; write ledger row last.
**Example (port of hermes-report.sh:874-918, narrowed — no `--environment`):**
```bash
# Source: ../hermes-revenium/skills/revenium/scripts/hermes-report.sh:874-918 (adapted, D-04)
if grep -q "^JOB:${clean_job_id}:created:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
  :   # already created — skip (idempotent)
else
  jobs_cmd=( revenium jobs create --agentic-job-id "${clean_job_id}" --quiet )
  [[ -n "${job_name}" ]] && jobs_cmd+=(--name "${job_name}")
  [[ -n "${job_type}" ]] && jobs_cmd+=(--type "${job_type}")
  # D-04: NO --environment

  jobs_cmd_output=$("${jobs_cmd[@]}" 2>&1) && jobs_cmd_exit=0 || jobs_cmd_exit=$?
  jobs_success=false
  if [[ "${jobs_cmd_exit}" -eq 0 ]]; then
    jobs_success=true
  elif echo "${jobs_cmd_output}" | grep -qi "409\|already.exist\|conflict"; then
    jobs_success=true
  fi
  if [[ "${jobs_success}" == "true" ]]; then
    now_ts=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
    echo "JOB:${clean_job_id}:created:${now_ts}" >> "${JOBS_LEDGER_FILE}"
    info "Job created: agentic_job_id=${clean_job_id}"
  else
    warn "jobs create failed: id=${clean_job_id} exit=${jobs_cmd_exit} — metering continues"
  fi
fi
```

### Pattern 3: Ledger-Gated Outcome with Create-Confirmed Gate (D-07/08/09, JLIFE-03)
**What:** Skip if outcome already in ledger; skip (retry next tick) if create not yet confirmed; send only `--result` + optional `--metadata`; 409-as-success; ledger row last.
**Example (port of hermes-report.sh:1176-1273, narrowed — NO `--outcome-type`):**
```bash
# Source: ../hermes-revenium/skills/revenium/scripts/hermes-report.sh:1176-1273 (adapted, D-07)
if grep -q "^JOB:${outcome_id}:outcome:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
  :   # already closed — idempotent skip
elif ! grep -q "^JOB:${outcome_id}:created:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
  warn "outcome deferred: id=${outcome_id} — create not yet confirmed"   # retry next tick (D-09)
else
  outcome_cmd=( revenium jobs outcome "${outcome_id}" --result "${outcome_status}" --quiet )
  # D-07: NO --outcome-type, ever.
  # D-08: failure_reason via --metadata, FAILED only, json.dumps for safe quoting.
  if [[ "${outcome_status}" == "FAILED" && -n "${failure_reason}" ]]; then
    outcome_metadata=$(FR="${failure_reason}" python3 - <<'PY' 2>/dev/null || true
import json, os
fr = os.environ.get('FR','').strip()
if fr: print(json.dumps({"failure_reason": fr}, separators=(',',':')))
PY
)
    outcome_metadata="${outcome_metadata%%$'\n'*}"
    [[ -n "${outcome_metadata}" ]] && outcome_cmd+=(--metadata "${outcome_metadata}")
  fi
  outcome_cmd_output=$("${outcome_cmd[@]}" 2>&1) && outcome_cmd_exit=0 || outcome_cmd_exit=$?
  outcome_success=false
  if [[ "${outcome_cmd_exit}" -eq 0 ]]; then outcome_success=true
  elif echo "${outcome_cmd_output}" | grep -qi "409\|already.exist\|conflict"; then outcome_success=true
  fi
  if [[ "${outcome_success}" == "true" ]]; then
    now_ts=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
    echo "JOB:${outcome_id}:outcome:${now_ts}:${outcome_status}" >> "${JOBS_LEDGER_FILE}"
    info "Outcome reported: agentic_job_id=${outcome_id} result=${outcome_status}"
  else
    warn "outcome failed: id=${outcome_id} exit=${outcome_cmd_exit} — retries next tick"
  fi
fi
```
**Status enum is already correct.** The marker's `status` is one of `SUCCESS|FAILED|CANCELLED` (enforced by `write-job-marker.sh:111`), which is exactly the `--result` enum. Hermes uppercases defensively (line 1201); OpenClaw markers are already uppercase, so a `case` guard is belt-and-suspenders, not required — but cheap to keep.

### Pattern 4: Optional `--agentic-job-*` append in `post_to_revenium` (D-01, JLIFE-02)
**What:** Three new params on `post_to_revenium`, conditionally appended to the `cmd` array exactly like the existing `--trace-id`/`--is-streamed`/`--organization-name` blocks (report.sh:256-274).
**Example:**
```bash
# Mirror the existing optional-flag blocks at report.sh:256-274
if [[ "${JOBS_CLI_CAPABLE}" == "true" && -n "${agentic_job_id}" ]]; then
  cmd+=(--agentic-job-id "${agentic_job_id}")
  [[ -n "${agentic_job_name}" ]] && cmd+=(--agentic-job-name "${agentic_job_name}")
  [[ -n "${agentic_job_type}" ]] && cmd+=(--agentic-job-type "${agentic_job_type}")
fi
```
New positional params append to the existing 21-arg `post_to_revenium` signature (report.sh:213-233) as `${22}`/`${23}`/`${24}`, defaulting empty. The call site at report.sh:663-675 passes them.

### Pattern 5: Extend the markers-cache Python read for `kind:"job"` rows
**What:** The existing read (report.sh:339-359) filters `r.get('ts') and r.get('task_type')`, which silently drops job markers (they have no `task_type`). Extend it to emit a second row shape for `kind == "job"`.
**Example (the discriminator is `kind:"job"`; absence-of-`kind` means task, per Phase 5 D-11):**
```python
# Source: report.sh:339-359 (extended). Env-passing heredoc — no ${VAR} interpolation.
if isinstance(r, dict) and r.get('kind') == 'job' and r.get('agentic_job_id'):
    # emit a JOB row (distinct prefix so the bash side can tell them apart)
    job_rows.append((r.get('ts',''), r['agentic_job_id'], r.get('job_name',''),
                     r.get('job_type',''), r.get('status',''),
                     r.get('failure_reason',''), r.get('completion_id','')))
elif isinstance(r, dict) and r.get('ts') and r.get('task_type'):
    rows.append((r['ts'], r['task_type'], r.get('completion_id','')))
```
Write job rows to a separate cache file (or a distinct line-prefix in one cache) so the per-completion correlation can scan them independently.

### Anti-Patterns to Avoid
- **Feeding job-CLI exit codes into `failed_count` / the CR-02 offset gate** (report.sh:693). A `jobs create`/`outcome` failure must NOT stop the offset from advancing — that gate is for completion-post failures only (D-12). Wiring job failures in would re-meter completions and double-bill.
- **`return`/`exit` from `process_session` on a job-CLI error.** Best-effort means warn-and-continue; an early return leaks temp files (the `_cleanup_session_tmp` at report.sh:699 would be skipped) and skips remaining completions.
- **Sending `--outcome-type` or `--environment`.** Both exist on the CLI and Hermes sends them; OpenClaw explicitly does not (D-04, D-07). A plan or test that asserts their presence is wrong.
- **Re-stamping already-`TX:`-ledgered completions** to retroactively attach `--agentic-job-id` (D-02). Accept partial per-completion stamping; the job is still fully created+closed and spend rolls up via `--agent`.
- **String-interpolating untrusted marker values into a Python program string.** Use the env-passing heredoc idiom (T-04-09) for `failure_reason` json.dumps and any marker parse — `failure_reason` is agent-supplied prose.
- **Filing the new ledger path via `common.sh`.** `report.sh` does NOT source `common.sh`; it defines its own paths at lines 28-43. Declare `JOBS_LEDGER_FILE` there, alongside `LEDGER_FILE`/`OFFSETS_FILE`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Idempotent create/close across cron ticks | A "have I seen this job?" in-memory set or timestamp-window heuristic | `grep -q "^JOB:<id>:created:"` / `:outcome:` against `revenium-jobs.ledger` (D-06/D-09) | The ledger is the proven cross-tick memory; same idiom as `TX:` completion dedup |
| Surviving a crash between API call and ledger write | A pre-write lock / transaction file | 409-as-success: API absorbs the repeat, treated as success-equivalent (D-06) | Belt-and-suspenders net beyond the local ledger; ports verbatim from Hermes |
| Matching a closing job marker to its same-tick completion | A bespoke timestamp window or "last completion" heuristic | The existing two-phase (completion_id exact → ts fallback) correlation already in report.sh:476-552 | Already proven, already tested (test_report_argv.sh Sessions A/C/D), already handles the marker-after-completion lifecycle |
| Safe quoting of `failure_reason` (agent prose) into a JSON CLI arg | sed/printf string assembly | `python3 json.dumps` via env-passing heredoc (D-08) | Agent-supplied prose can contain quotes/braces; json.dumps is the only safe path |
| Detecting CLI capability | Parsing `revenium --version` or feature flags | Dual `--help` probe (D-11) | Version-agnostic; the same idiom `common.sh:has_guardrails_cli` already uses |

**Key insight:** Every hard problem in this phase already has a battle-tested implementation either in `report.sh` (correlation, ledger dedup, offset gate, optional-flag append, env-passing heredoc) or in `hermes-report.sh` (probe, 409-as-success, create/outcome stages). Phase 6 is composition and narrowing, not invention.

## Runtime State Inventory

> Phase 6 is **additive code wiring**, not a rename/refactor/migration. This section is included because the phase introduces a new persistent ledger file and reads a new marker kind — the planner should know the state surfaces.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | New `revenium-jobs.ledger` under `OPENCLAW_HOME` (rows `JOB:<id>:created:<ts>` / `JOB:<id>:outcome:<ts>:<STATUS>`). It is created empty (`touch`) and grows monotonically. No migration of existing data. The existing `revenium-reported.ledger` (`TX:` rows) and `revenium-offsets.json` are **read/written exactly as today — untouched** (D-02, D-10). | Code edit: declare path + `touch` at startup. No data migration. |
| Live service config | Revenium server state: `jobs create`/`outcome` create/close job rows server-side via the `revenium` CLI. There is no local config file to update; idempotency is the local ledger + server 409. | None local. |
| OS-registered state | The cron entry that runs `report.sh` is unchanged — same script path, same invocation. No new cron registration. | None — verified: Phase 6 edits the script body only, not its scheduling. |
| Secrets/env vars | New OPTIONAL env knobs (Claude's discretion): `REVENIUM_JOBS_LEDGER_FILE` (override path, mirrors Hermes), `REVENIUM_JOBS_STALE_SECONDS` (stale-warn threshold, Hermes default 600). No secrets. `revenium` auth is the existing `revenium config` (guarded at report.sh:106). | None required; document any new env knob if adopted. |
| Build artifacts / installed packages | None. No compiled artifacts, no package installs, no egg-info. Pure interpreted bash/python. | None. |

**The canonical question — after every file edit, what runtime state persists the new behavior?** Only `revenium-jobs.ledger` (local, monotonic, idempotency memory) and server-side Revenium job rows (idempotent via 409). Nothing else changes on disk or in the OS.

## Common Pitfalls

### Pitfall 1: Job-CLI failure wedging the completion offset
**What goes wrong:** A `jobs create`/`outcome` error increments `failed_count` (or otherwise reaches the CR-02 gate at report.sh:693), so the offset never advances and completions re-process — or worse, double-bill.
**Why it happens:** Copy-pasting the completion error handling (which DOES drive `failed_count`) onto the job calls.
**How to avoid:** Job calls use their OWN exit-code locals (`jobs_cmd_exit`, `outcome_cmd_exit`); never touch `failed_count`/`reported_count`. The offset gate stays driven solely by `post_to_revenium`'s return (D-12).
**Warning signs:** Offsets stop advancing when the CLI is configured-but-jobs-fail; completions re-ship every tick.

### Pitfall 2: Job markers silently dropped by the existing markers-cache filter
**What goes wrong:** `kind:"job"` markers are read but ignored because the current filter requires `task_type` (report.sh:352). Result: zero jobs ever created, tests pass at unit level but no lifecycle fires.
**Why it happens:** The job marker has no `task_type` field, so `r.get('ts') and r.get('task_type')` is falsy.
**How to avoid:** Extend the filter to branch on `r.get('kind') == 'job'` (Pattern 5). Verify with a fixture that has a job marker and assert a `jobs create` argv appears.
**Warning signs:** `revenium-jobs.ledger` stays empty; no `jobs` tokens in captured argv.

### Pitfall 3: Outcome firing before create is server-side confirmed
**What goes wrong:** `jobs outcome` is sent for a job whose `create` failed (or whose create-ledger row was never written), so the server rejects an outcome for a non-existent job.
**Why it happens:** Firing outcome unconditionally in the same tick without re-checking the create gate.
**How to avoid:** The outcome path checks `grep -q "^JOB:<id>:created:"` (D-09) and defers to next tick if absent. The natural single-tick order is create → stamp → outcome, but the gate makes a failed create safe.
**Warning signs:** Server 404/400 on outcome; `warn "outcome deferred"` log lines that never resolve (a wedged job — adopt the optional stale-warn if desired).

### Pitfall 4: The existing test's "no agentic-job" assertion now fails
**What goes wrong:** `tests/test_report_argv.sh:283-289` asserts that NO `--agentic-job-*` token appears in captured argv. Phase 6 deliberately introduces those tokens for job-bearing completions, so this assertion will flip to FAIL for any fixture carrying a job marker.
**Why it happens:** That assertion encoded a v1.0/Phase-5 invariant ("jobs not wired yet") that Phase 6 lifts.
**How to avoid:** Either (a) keep `test_report_argv.sh`'s fixtures job-free so its negative assertion stays valid (none of Sessions A–D have job markers today, so it stays green as-is), and add job markers only in a NEW `test_report_jobs_argv.sh`; or (b) update assertion 283-289. **Recommend (a)** — leave the existing task-type regression test untouched, add a sibling job-lifecycle test. The planner must explicitly decide this so a "passing" suite isn't silently broken.
**Warning signs:** `test_report_argv.sh` fails on "forbidden --agentic-job-* found" after job markers are added to its fixtures.

### Pitfall 5: Lexicographic vs parsed-datetime ts comparison in correlation
**What goes wrong:** Job-marker ts (second precision `...Z`) compared lexicographically against completion ts (ms precision `...000Z`) excludes a same-second marker (`Z`=0x5A > `.`=0x2E).
**Why it happens:** Reinventing the comparison instead of reusing the existing parsed-datetime path.
**How to avoid:** Reuse the EXACT `parse_ts` + datetime compare from report.sh:501-507 / the WR-02 comment. The task-type correlation already solved this; job correlation must use the same code.
**Warning signs:** Jobs whose closing marker lands the same second as the final completion never get stamped/created.

### Pitfall 6: Stamping more than the same-tick completion (D-01/D-02 violation)
**What goes wrong:** An implementation tries to attach `--agentic-job-id` to every completion in the arc by re-reading prior-tick completions or defeating the `TX:` dedup.
**Why it happens:** Misreading JLIFE-02 ("every completion belonging to a job") as a hard per-completion guarantee rather than the best-effort + server-rollup design (D-01).
**How to avoid:** Stamp only the completion the closing marker correlates to in the current tick (via the existing correlation). Accept that prior-tick completions are attributed via `--agent` server-side. Do NOT touch the `TX:` ledger.
**Warning signs:** Attempts to re-read already-`TX:`-ledgered lines; offset/ledger manipulation in a job code path.

## Code Examples

### Config-block declaration (report.sh lines 28-43 region)
```bash
# Source: report.sh:29-34 (add alongside existing ledger/offsets paths)
LEDGER_FILE="${OPENCLAW_HOME}/revenium-reported.ledger"          # existing — UNTOUCHED
OFFSETS_FILE="${OPENCLAW_HOME}/revenium-offsets.json"            # existing — UNTOUCHED
JOBS_LEDGER_FILE="${REVENIUM_JOBS_LEDGER_FILE:-${OPENCLAW_HOME}/revenium-jobs.ledger}"  # NEW (D-10)
```
```bash
# Source: report.sh:111 (add a sibling touch after the existing one)
touch "${LEDGER_FILE}"        # existing
touch "${JOBS_LEDGER_FILE}"   # NEW — mirror Hermes hermes-report.sh:52
```
Note: Hermes declares `JOBS_LEDGER_FILE` in `common.sh:31`; OpenClaw's `report.sh` does not source `common.sh`, so the declaration goes in `report.sh`'s own config block (CONTEXT.md confirms this; verified report.sh:1-43 sources nothing).

### Stub extension for jobs (tests/stub-revenium.sh)
The current stub (lines 15-19) captures every argv token one-per-line and `exit 0`. To fake a 409 and exercise the 409-as-success path, make the stub conditionally emit a conflict string and a non-zero exit:
```bash
# Extend tests/stub-revenium.sh — capture argv (unchanged), then optionally fake a 409.
# A test sets STUB_REVENIUM_409_FOR="<agentic-job-id>" to force a conflict for create.
if [[ "$1 $2" == "jobs create" || "$1 $2" == "jobs outcome" ]]; then
  if [[ -n "${STUB_REVENIUM_409_FOR:-}" ]] && printf '%s\n' "$@" | grep -q -- "${STUB_REVENIUM_409_FOR}"; then
    echo "Error: 409 Conflict: job already exists" >&2
    exit 1
  fi
fi
exit 0
```
Argv assertions then use the same one-token-per-line grep the existing tests use: `grep -c "^jobs$"`, `grep -c "^create$"`, `grep -c "^outcome$"`, `awk '/^--result$/{getline;print}'`.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Hermes two-stage queue (arc-open create + post-loop outcome via `job_outcome_queue`, hermes-report.sh:49,1163) | OpenClaw single-session in-loop create→stamp→outcome from one arc-close marker (D-09) | Phase 6 design | Simpler; no script-global accumulator; outcome gate still protects ordering |
| Hermes `--outcome-type CONVERTED` on SUCCESS (hermes-report.sh:1221-1223) | No `--outcome-type` at all (D-07) | Phase 6 design | Stays observability-only; defers ROI to JOUT-01 |
| Hermes `--environment` from session source column (hermes-report.sh:891-894) | Omit `--environment` (D-04) | Phase 6 design | OpenClaw has no source column; Revenium default applies |
| Hermes `owning_job_id` root-rollup resolution (hermes-report.sh:1050-1075) | Single-session correlation only; root rollup deferred | Phase 6 → Phase 7 | Do NOT port the override machinery here |

**Deprecated/outdated:**
- CONTEXT.md line-number references have drifted slightly vs. current `report.sh`. **Corrected map below — use these, not CONTEXT.md's:**
  - markers-cache Python block: report.sh **332-360** (CONTEXT said ~332-360 ✓ accurate)
  - two-phase task_type lookup: report.sh **476-552** (CONTEXT said ~487-552; the block actually starts at the comment on 476, the Python heredoc at 489) 
  - CR-02 offset gate: report.sh **693** ✓ accurate
  - `post_to_revenium`: report.sh **212-303**; optional-flag append blocks **256-274**; signature/params **213-233**; call site **663-675**
  - config/ledger block: report.sh **28-34**; `touch "${LEDGER_FILE}"` **111**
  - Hermes probe: hermes-report.sh **34-43** ✓; create: **874-918** (CONTEXT said ~878-920 ✓ close); outcome: **1176-1273** (CONTEXT said ~1167-1275 ✓ close); meter stamping: **1063-1075**

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | The `revenium` server returns an HTTP-409 / "already exists" / "conflict" string in CLI output (not exit-0) for a duplicate `jobs create`/`outcome`, so the `grep -qi "409\|already.exist\|conflict"` net catches it. | Pattern 2/3 | If the real conflict string differs, the 409 net misses and a duplicate create logs a warn (harmless — the local ledger still gates the common path; the 409 net is only the crash-window backstop). Verify against a live duplicate call before/at UAT. |
| A2 | `jobs outcome` for a never-created job fails (non-zero / 4xx) rather than silently creating it. The create-confirmed gate (D-09) assumes this. | Pattern 3 | If outcome auto-creates, the gate is merely redundant — no correctness loss. Low risk. |
| A3 | The Revenium server attributes prior-tick completions (shipped without `--agentic-job-id`) to the job via the `--agent "openclaw-<root_sid>"` server-side rollup (D-01). | User Constraints D-01 | This is the core best-effort premise; if server rollup does not aggregate by agent into the job, partial attribution is lost. This is a Phase-4-established mechanism (STATE.md: "subagent→root spend rollup confirmed end-to-end"); treated as confirmed, but it is a server-side behavior not re-verified this session. |
| A4 | `unix_ts` `%.3f` precision (Hermes) vs simpler `date +%s` is cosmetic in the ledger and does not affect idempotency (gates match on `^JOB:<id>:created:` prefix, ignoring the ts). | Claude's Discretion | None — the gate ignores the ts portion. Pure cosmetic. |

**Note:** A1 and A3 are server-behavior assumptions inherited from the Hermes port and Phase 4; they are not bash-level risks. The local ledger gates (D-06/D-09) make the common path correct regardless; the 409 net (A1) only matters in the rare crash-between-API-and-ledger window.

## Open Questions

1. **Exact conflict-string the live Revenium CLI emits on duplicate create/outcome (A1).**
   - What we know: Hermes greps `409\|already.exist\|conflict` and it works in Hermes production.
   - What's unclear: Whether the OpenClaw-targeted Revenium instance/CLI version emits an identical string.
   - Recommendation: Port the same grep; verify with one live duplicate call during UAT. The local ledger already covers the common case, so this is non-blocking.

2. **Test-suite invariant flip (Pitfall 4).**
   - What we know: `test_report_argv.sh:283-289` asserts no `--agentic-job-*`. Its Sessions A–D carry no job markers, so it stays green if left alone.
   - What's unclear: Whether the planner wants to add job markers to those fixtures (breaking the assertion) or add a sibling test.
   - Recommendation: Add a NEW `test_report_jobs_argv.sh`; leave the task-type regression test untouched. Planner must state this explicitly.

3. **In-loop vs pre-scan for create (Claude's discretion).**
   - What we know: Hermes does both (pre-guard scan + in-loop). OpenClaw is single-session arc-close.
   - What's unclear: Whether any job marker could appear in a session that has zero new completions this tick (e.g., the closing marker lands but its correlated completion was already shipped — D-03's "no stampable same-tick completion" case).
   - Recommendation: The D-03 case (marker present, correlated completion already TX:-ledgered) means the in-loop completion path may `continue` past that completion (skipped as already-reported at report.sh:659). So create/outcome must NOT be gated behind "we are about to ship a completion" — they must fire whenever a closing job marker exists for the session, independent of whether a same-tick completion is stamped. Plan the create/outcome as a per-session step keyed on the presence of job markers, with stamping as an independent best-effort overlay on whatever completion (if any) correlates.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `revenium` CLI | jobs create/outcome, meter stamping (all JLIFE) | ✓ | `jobs` + `meter completion --agentic-job-*` present [VERIFIED 2026-06-03] | `JOBS_CLI_CAPABLE=false` → skip all job work, metering byte-identical to v1.0 (D-11) |
| `revenium jobs` subcommand | JLIFE-01/03/05 | ✓ | create/outcome/get/list/etc. present | Probe-gated skip (D-11) |
| `meter completion --agentic-job-id/-name/-type` | JLIFE-02 | ✓ | all three present | Probe-gated skip (D-11) |
| `python3` | marker parse, ts correlation, json.dumps metadata | ✓ | present | Existing report.sh already degrades (correlation falls back) |
| `jq` | existing JSONL extraction | ✓ | present | Hard guard at report.sh:101 |
| `bash` 3.2+ | host | ✓ | — | n/a |

**Missing dependencies with no fallback:** None.
**Missing dependencies with fallback:** None currently missing. The `JOBS_CLI_CAPABLE` probe (D-11) is the *designed* fallback for any future host where the `jobs` subcommand or `--agentic-job-*` flags are absent — job work is skipped, metering and guardrails are unaffected.

## Validation Architecture

Test seams available: (1) `stub-revenium.sh` argv capture (one token per line → grep/awk assertions), (2) `revenium-jobs.ledger` file inspection, (3) `JOBS_CLI_CAPABLE` fail-open by stubbing a CLI whose `--help` lacks `jobs`/`--agentic-job-id`. All three are pure-shell, hermetic, run in <30s.

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Plain bash integration scripts (no harness framework); `pass`/`fail` counters + final exit code (see test_report_argv.sh:38-42) |
| Config file | none — each `tests/test_*.sh` is self-contained, builds its own tmp `OPENCLAW_HOME` |
| Quick run command | `bash tests/test_report_jobs_argv.sh` (the new test) |
| Full suite command | `for t in tests/test_*.sh; do bash "$t" || exit 1; done` (no runner script exists today — see Wave 0) |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| JLIFE-01 | `jobs create` fires once for a declared job; idempotent across two `report.sh` runs (second run issues no second create) | integration (argv + ledger) | `bash tests/test_report_jobs_argv.sh` — assert exactly one `^create$` token across two runs; `revenium-jobs.ledger` has one `JOB:<id>:created:` line | ❌ Wave 0 |
| JLIFE-02 | A completion correlated to a job marker ships `--agentic-job-id/-name/-type` | integration (argv) | assert `awk '/^--agentic-job-id$/{getline;print}'` == the marker's id, and `--agentic-job-name`/`--agentic-job-type` present | ❌ Wave 0 |
| JLIFE-03 | `jobs outcome <id> --result <STATUS>` fires once, status read from marker; FAILED carries `--metadata` with `failure_reason`; SUCCESS/CANCELLED carry no `--metadata` | integration (argv + ledger) | assert `^outcome$` token, positional id, `awk '/^--result$/{getline;print}'`==status; assert `--metadata` present only for FAILED; ledger has one `:outcome:...:STATUS` line | ❌ Wave 0 |
| JLIFE-04 | With a CLI stub whose `--help` lacks `jobs`/`--agentic-job-id`, NO job tokens appear, NO `--agentic-job-*` on completions, and task-type metering + `--agent` still ship (v1.0-identical) | integration (fail-open) | run report.sh with a `JOBS_CLI_CAPABLE=false`-forcing stub; assert zero `^jobs$`/`agentic-job` tokens AND `--task-type`/`--agent` still present | ❌ Wave 0 |
| JLIFE-05 | Two consecutive runs never re-issue create or outcome (ledger gates) | integration (ledger) | run report.sh twice; assert `grep -c '^JOB:.*:created:'`==1 and `:outcome:`==1; assert no second `^create$`/`^outcome$` in run-2 argv | ❌ Wave 0 |
| JLIFE-04 (extra) | A `jobs create` 409 is treated as success (ledger row written, no error escalation) | integration (409 path) | set `STUB_REVENIUM_409_FOR=<id>`; assert ledger `:created:` row still written and exit 0 | ❌ Wave 0 |
| JLIFE-04 (extra) | A `jobs create`/`outcome` failure does NOT block completion offset advance or re-meter (CR-02 stays decoupled) | integration | stub jobs to fail (non-409 error) but completions to succeed; assert offsets advance and completions are TX:-ledgered exactly once | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `bash tests/test_report_jobs_argv.sh` (new) + `bash tests/test_report_argv.sh` (regression — must stay green, Pitfall 4)
- **Per wave merge:** `for t in tests/test_*.sh; do bash "$t" || exit 1; done`
- **Phase gate:** full suite green before `/gsd-verify-work`

### Wave 0 Gaps
- [ ] `tests/test_report_jobs_argv.sh` — new integration test covering JLIFE-01..05 (fixtures: a session with a job marker correlating to a same-tick completion (SUCCESS), a FAILED job with `failure_reason`, a CANCELLED job, and a re-run idempotency check)
- [ ] `tests/stub-revenium.sh` extension — fake `jobs create`/`jobs outcome` capture + optional `STUB_REVENIUM_409_FOR` 409 path (Code Examples §Stub extension)
- [ ] Fail-open fixture/stub — a `revenium` stub whose `jobs --help` exits non-zero OR `meter completion --help` lacks `--agentic-job-id`, to force `JOBS_CLI_CAPABLE=false` (JLIFE-04)
- [ ] Decision recorded: keep `test_report_argv.sh` job-free (recommended) so its no-`agentic-job` assertion stays valid (Pitfall 4)
- [ ] (Optional) `tests/run-all.sh` convenience runner — none exists today; the full-suite command is an ad-hoc `for` loop

## Security Domain

> `security_enforcement` is not disabled in config — included. This is a bash phase reading agent-written marker files and assembling CLI arguments; the threat surface is argument injection and untrusted-prose handling.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | `revenium config` auth pre-exists; phase adds no auth surface |
| V3 Session Management | no | n/a |
| V4 Access Control | yes | `markers/` is mode 0700 (set by `write-job-marker.sh:225`); ledger inherits `OPENCLAW_HOME` perms; no new world-readable secrets |
| V5 Input Validation | yes | Marker values (`agentic_job_id`, `job_name`, `job_type`, `status`, `failure_reason`) are agent-written. They were sanitized at write time (`:`,`|`,newline→`_`, 256-char cap, taxonomy/status allowlist — `write-job-marker.sh:88-113`). Phase 6 is the *consumer* that pushes them onto a CLI; treat them as data via bash arrays (`cmd+=(--flag "$val")` never `eval`/string-concat) and json.dumps for `--metadata`. |
| V6 Cryptography | no | none |

### Known Threat Patterns for bash + CLI-arg assembly

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Argument injection via crafted marker field reaching `revenium` argv | Tampering / EoP | Build commands as bash arrays (`cmd=( ... )`, `cmd+=(--flag "$val")`) — never `eval`, never unquoted expansion. report.sh already does this for every flag (lines 235-289). Phase 5 sanitization (`:`/`|`/newline→`_`) is the upstream net; the array discipline is the downstream net. |
| Shell/Python injection via untrusted value interpolated into a heredoc program string | Tampering / EoP | Env-passing heredoc discipline (T-04-09): pass `failure_reason` and any marker value via `VAR="$val" python3 - <<'PY'` reading `os.environ`, never `${val}` inside the program text. Established throughout report.sh (lines 180, 194, 339, 489, 570). |
| Log injection via newline/control chars in `agentic_job_id`/`job_type` written to the log | Tampering | 64-char truncation for logged values (T-04-08, mirrors `task_type_log` at report.sh:555 and `JOB_TYPE_LOG` at write-job-marker.sh:62). Apply to any job field that reaches `info`/`warn`. |
| Path traversal via sid in ledger/marker path | Tampering | sid already path-guarded at write time (`write-job-marker.sh:221`); report.sh reads `markers/${session_id}.jsonl` where `session_id` is `basename`-derived (report.sh:311). No new path constructed from a marker field. |
| `--metadata` JSON breakout via prose `failure_reason` | Tampering | json.dumps (D-08) guarantees a single well-formed JSON token; passed as one array element. |

## Sources

### Primary (HIGH confidence)
- `revenium` CLI live probes (this machine, 2026-06-03): `revenium jobs --help`, `revenium jobs create --help`, `revenium jobs outcome --help`, `revenium meter completion --help` — verified every flag name, the `--result` enum, and that `outcome` takes a positional job id.
- `scripts/report.sh` (read in full, 729 lines) — verified all line-number landmarks, the `post_to_revenium` chokepoint, the markers-cache read, the two-phase correlation, the CR-02 offset gate, and that report.sh does NOT source common.sh.
- `scripts/write-job-marker.sh` (read in full) — confirmed emitted marker fields: `kind:"job"`, `ts` (ISO8601), `sid`, `agentic_job_id`, `job_name`, `job_type`, `status`, optional `failure_reason` (FAILED-only), optional `completion_id`; status allowlist `SUCCESS|FAILED|CANCELLED`.
- `scripts/common.sh` (read in full) — confirmed `MARKERS_DIR`, `JOB_TAXONOMY_FILE`, `STATE_DIR`, `OPENCLAW_HOME`, `log/info/warn/error`, and the `has_guardrails_cli` dual-probe precedent.
- `tests/stub-revenium.sh`, `tests/test_report_argv.sh`, `tests/test_write_job_marker.sh` (read in full) — confirmed the argv-capture seam, the one-token-per-line grep/awk assertion idiom, and the existing no-`agentic-job` assertion (lines 283-289).
- `../hermes-revenium/skills/revenium/scripts/hermes-report.sh` (read lines 30-99, 855-944, 1044-1078, 1160-1279) — the proven probe (34-43), create (874-918), outcome (1176-1273), and meter-stamping (1063-1075) to port; confirmed Hermes `JOBS_LEDGER_FILE` lives in its `common.sh:31`.
- `.planning/REQUIREMENTS.md`, `.planning/ROADMAP.md` (Phase 6 §), `.planning/STATE.md`, both phase CONTEXT.md files.

### Secondary (MEDIUM confidence)
- None — every claim is verified against live tooling or read source.

### Tertiary (LOW confidence)
- Assumptions A1/A3 (server-side 409 string and `--agent` rollup behavior) — inherited from the Hermes port and Phase 4 STATE.md; server-side, not re-verified this session. Flagged in Assumptions Log.

## Metadata

**Confidence breakdown:**
- Standard stack / CLI signatures: HIGH — every flag verified against the live `revenium` CLI on this machine.
- Architecture / code map: HIGH — all of report.sh read; every line-number landmark confirmed and corrected against CONTEXT.md.
- Pitfalls: HIGH — derived directly from the read source (CR-02 gate, markers-cache filter, existing test assertion) and the locked decisions.
- Server-side behavior (409 net, `--agent` rollup): MEDIUM — assumed from Hermes/Phase-4 precedent, flagged in Assumptions Log; non-blocking because local ledger gates cover the common path.

**Research date:** 2026-06-03
**Valid until:** 2026-07-03 (stable — local source + a CLI whose surface is version-checked at runtime via the D-11 probe; re-verify CLI flags only if `revenium` is upgraded)
