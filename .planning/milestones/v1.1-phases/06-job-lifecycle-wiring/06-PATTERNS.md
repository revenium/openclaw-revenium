# Phase 6: Job Lifecycle Wiring - Pattern Map

**Mapped:** 2026-06-03
**Files analyzed:** 3 (1 modified core script, 1 new test, 1 modified test stub)
**Analogs found:** 3 / 3 (every new/modified surface has a concrete in-repo or Hermes analog)

> This is a bash/shell phase. There are no controllers/components/models. "Role" is mapped
> to the bash equivalents (config block, function, heredoc, ledger gate, test harness) and
> "Data flow" describes how data moves (file-read → correlate → CLI-emit → ledger-write).
>
> Every excerpt below is a VERIFIED file:line range. Hermes excerpts are the **proven
> implementation to ADAPT, not copy** — the four OpenClaw divergences (no `--environment`,
> no `--outcome-type`, single arc-close in-loop create+outcome, no `owning_job_id` rollup)
> are called out at every site.

---

## File Classification

| New/Modified File | Role (bash) | Data Flow | Closest Analog | Match Quality |
|-------------------|-------------|-----------|----------------|---------------|
| `scripts/report.sh` — config block | config/path decl | declare path → `touch` at startup | `report.sh:29,34,111` (`LEDGER_FILE`/`OFFSETS_FILE` + `touch`) | exact (same file) |
| `scripts/report.sh` — `JOBS_CLI_CAPABLE` probe | startup guard | dual `--help` probe → cache boolean | Hermes `hermes-report.sh:34-43`; idiom also `common.sh has_guardrails_cli` | exact (proven port) |
| `scripts/report.sh` — markers-cache read (job rows) | inline Python heredoc | read `markers/{sid}.jsonl` → emit job rows | `report.sh:339-359` (existing task-type read) | exact (extend in place) |
| `scripts/report.sh` — job correlation | inline Python heredoc | completion_id exact → ts fallback | `report.sh:489-552` (two-phase task_type lookup) | exact (reuse engine) |
| `scripts/report.sh` — `--agentic-job-*` append | function (`post_to_revenium`) | param → conditional `cmd+=()` | `report.sh:256-274` (`--trace-id`/`--is-streamed`/`--organization-name`) | exact (mirror block) |
| `scripts/report.sh` — `jobs create` | in-loop CLI call + ledger gate | ledger-gate → CLI → 409-net → ledger-write | Hermes `hermes-report.sh:874-918` | role-match (adapt: no `--environment`) |
| `scripts/report.sh` — `jobs outcome` | in-loop CLI call + ledger gate | 3 gates → CLI → 409-net → ledger-write | Hermes `hermes-report.sh:1176-1273` | role-match (adapt: no `--outcome-type`) |
| `scripts/report.sh` — ledger dedup idiom | ledger gate | `grep -q "^JOB:..."` | `report.sh:659` (`grep -q "^TX:${tx_id}$"`) | exact (same idiom) |
| `tests/test_report_jobs_argv.sh` (NEW) | test harness | fixture → run → argv/ledger assert | `tests/test_report_argv.sh` (full file) | exact (clone structure) |
| `tests/stub-revenium.sh` (MODIFIED) | test double | capture argv → optional 409 exit | `tests/stub-revenium.sh:15-20` (existing capture) | exact (extend) |

---

## Pattern Assignments

### `scripts/report.sh` — config-block path declaration (config/path decl)

**Analog:** `scripts/report.sh:29,34,111` (this same file; declare alongside the existing ledger/offsets paths).

**Existing path block** (`report.sh:28-34`):
```bash
SESSIONS_DIR="${OPENCLAW_HOME}/agents/main/sessions"
LEDGER_FILE="${OPENCLAW_HOME}/revenium-reported.ledger"
LOG_FILE="${OPENCLAW_HOME}/revenium-metering.log"
SKILL_DIR="${OPENCLAW_HOME}/skills/revenium"
CONFIG_FILE="${SKILL_DIR}/config.json"
BUDGET_STATUS_FILE="${SKILL_DIR}/budget-status.json"
OFFSETS_FILE="${OPENCLAW_HOME}/revenium-offsets.json"
```
**New line to add here** (D-10; env-override mirrors Hermes):
```bash
JOBS_LEDGER_FILE="${REVENIUM_JOBS_LEDGER_FILE:-${OPENCLAW_HOME}/revenium-jobs.ledger}"
```

**Existing `touch`** (`report.sh:111`, after the `revenium config show` guard):
```bash
touch "${LEDGER_FILE}"
```
**New sibling `touch` to add immediately after** (mirrors Hermes `hermes-report.sh:52`):
```bash
touch "${JOBS_LEDGER_FILE}"
```
> NOTE: `report.sh` does NOT source `common.sh` (verified: it defines its own paths at 28-34
> and sources nothing). The new path goes HERE, not in `common.sh`. Hermes puts
> `JOBS_LEDGER_FILE` in its `common.sh:31` — that divergence is intentional for OpenClaw.

---

### `scripts/report.sh` — `JOBS_CLI_CAPABLE` dual-probe (startup guard)

**Analog:** `../hermes-revenium/skills/revenium/scripts/hermes-report.sh:34-43` (proven port). The same two-subcommand-probe idiom already lives in OpenClaw's `common.sh has_guardrails_cli` (precedent).

**Hermes source to adapt** (`hermes-report.sh:34-43`):
```bash
JOBS_CLI_CAPABLE=false
if revenium jobs --help >/dev/null 2>&1 && \
   revenium meter completion --help 2>&1 | grep -q -- '--agentic-job-id'; then
  JOBS_CLI_CAPABLE=true
else
  warn "revenium jobs/--agentic-job-id not available — job work skipped; metering continues as v1.0."
fi
```
**Placement in OpenClaw:** at startup, AFTER the `revenium config show` guard (`report.sh:106-109`) and the existing `touch "${LEDGER_FILE}"` (`report.sh:111`), BEFORE `main` (`report.sh:728`). One probe per cron tick; cache the boolean for the whole tick (D-11).

> DO NOT port Hermes' `job_outcome_queue=()` script-global (`hermes-report.sh:45-49`). That
> accumulator exists only because Hermes splits create (arc-open) from outcome (arc-close)
> across sessions. OpenClaw fires both in-loop from one arc-close marker (D-09) — no queue.

---

### `scripts/report.sh` — markers-cache read extended for `kind:"job"` rows (inline Python heredoc)

**Analog:** `scripts/report.sh:339-359` (the existing once-per-session markers read). Extend this read to emit job rows (recommended over a sibling read — keeps one file-read per session, NP-1).

**Existing read — the filter that silently drops job markers** (`report.sh:339-359`):
```bash
_MARKER_FILE="${marker_file}" python3 - <<'PY' 2>/dev/null >> "${markers_cache_file}" || true
import json, os, sys
mf = os.environ.get('_MARKER_FILE', '')
rows = []
try:
    with open(mf, encoding='utf-8') as fh:
        for line in fh:
            line = line.strip()
            if not line: continue
            try:
                r = json.loads(line)
            except Exception:
                continue
            if isinstance(r, dict) and r.get('ts') and r.get('task_type'):
                rows.append((r['ts'], r['task_type'], r.get('completion_id', '')))
except Exception:
    pass
rows.sort(key=lambda x: x[0])
for ts, tt, cid in rows:
    sys.stdout.write(f"{ts}\t{tt}\t{cid}\n")
PY
```
**Why it drops jobs:** job markers have no `task_type`, so `r.get('ts') and r.get('task_type')`
is falsy (Pitfall 2). Branch on `r.get('kind') == 'job'` to capture them.

**Extension shape (research Pattern 5):** emit job rows to a SEPARATE cache file (or a
distinct line-prefix) so the per-completion correlation can scan them independently. Job row
fields needed downstream: `agentic_job_id`, `job_name`, `job_type`, `status`,
`failure_reason`, `completion_id` (+ `ts` for fallback). Discriminator is `kind == "job"`;
absence of `kind` = task marker (Phase 5 D-11).

> Env-passing heredoc discipline (T-04-09): pass `marker_file` via `_MARKER_FILE` env, never
> `${VAR}` inside `<<'PY'`. The existing read already does this — preserve it.

---

### `scripts/report.sh` — per-completion job correlation (inline Python heredoc)

**Analog:** `scripts/report.sh:489-552` (the two-phase task_type lookup — the EXACT correlation engine to reuse).

**The proven two-phase pattern** (`report.sh:524-548`) — Phase A exact `completion_id`, Phase D earliest-marker-after-completion fallback:
```python
# --- Phase A: exact completion_id match ---
if cid:
    for ts, tt, marker_cid in rows:
        if marker_cid and marker_cid == cid:
            chosen = tt
            break

# --- Phase D: earliest marker at or after completion ts (fallback) ---
if chosen == 'unclassified':
    cts = parse_ts(cts_raw)
    for ts, tt, marker_cid in rows:
        if marker_cid:
            continue
        mts = parse_ts(ts)
        if mts is not None and cts is not None:
            if mts >= cts:
                chosen = tt
                break
        else:
            if ts >= cts_raw:
                chosen = tt
                break
```
**Critical: reuse the EXACT `parse_ts` helper** (`report.sh:501-507`) for datetime-parsed
comparison — NOT lexicographic string compare (Pitfall 5 / WR-02). Job-marker ts is
second-precision `...Z`; completion ts is ms `...000Z`; lexicographic compare wrongly
excludes a same-second marker (`Z`=0x5A > `.`=0x2E):
```python
def parse_ts(s):
    try: return datetime.fromisoformat(s.replace('Z', '+00:00'))
    except Exception: pass
    for fmt in ('%Y-%m-%dT%H:%M:%S.%fZ', '%Y-%m-%dT%H:%M:%SZ'):
        try: return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc)
        except Exception: pass
    return None
```
**For jobs:** match the closing job marker to its same-tick completion via this same
completion_id-exact → ts-fallback logic, resolving `(agentic_job_id, job_name, job_type,
status, failure_reason)` instead of `task_type`. Stamp only the same-tick completion (D-01);
prior-tick already-`TX:`-ledgered completions are NEVER re-stamped (D-02, Pitfall 6).

---

### `scripts/report.sh` — `--agentic-job-*` append in `post_to_revenium` (function)

**Analog:** `scripts/report.sh:256-274` (the existing optional-flag append blocks — `--trace-id`, `--model-source`, `--is-streamed`, `--organization-name`).

**The exact block-style to mirror** (`report.sh:256-274`):
```bash
# Add trace ID to correlate related completions within a conversation turn
if [[ -n "${trace_id}" ]]; then
  cmd+=(--trace-id "${trace_id}")
fi
# ...
# Add streaming flag if the API was a stream type
if [[ "${is_streamed}" == "true" ]]; then
  cmd+=(--is-streamed)
fi
# Add organization name if configured
if [[ -n "${ORG_NAME}" ]]; then
  cmd+=(--organization-name "${ORG_NAME}")
fi
```
**New block to add (research Pattern 4)** — gated on `JOBS_CLI_CAPABLE` AND non-empty id:
```bash
if [[ "${JOBS_CLI_CAPABLE}" == "true" && -n "${agentic_job_id}" ]]; then
  cmd+=(--agentic-job-id "${agentic_job_id}")
  [[ -n "${agentic_job_name}" ]] && cmd+=(--agentic-job-name "${agentic_job_name}")
  [[ -n "${agentic_job_type}" ]] && cmd+=(--agentic-job-type "${agentic_job_type}")
fi
```
**Signature change:** `post_to_revenium` currently takes 21 positional params (`report.sh:213-233`, `task_type` is `${21}`). Append three new params `${22}` `${23}` `${24}` (`agentic_job_id`/`agentic_job_name`/`agentic_job_type`), each defaulting empty (`local agentic_job_id="${22:-}"`).
**Call site:** `report.sh:663-675` — append the three resolved job values after `"${task_type:-unclassified}"`.

> Array discipline (V5 / Tampering): always `cmd+=(--flag "$val")`, never `eval` or unquoted
> expansion. The existing function does this for every flag — preserve it. Hermes' analog at
> `hermes-report.sh:1063-1075` adds the SAME three flags but wraps them in `owning_job_id`
> root-rollup logic — DO NOT port that branch (Phase 7); OpenClaw stamps the single matched
> same-tick completion only.

---

### `scripts/report.sh` — `jobs create` (in-loop CLI call + ledger gate)

**Analog:** `../hermes-revenium/skills/revenium/scripts/hermes-report.sh:874-918` (proven create stage — adapt, narrow per D-04).

**Hermes source to adapt** (`hermes-report.sh:879-918`):
```bash
local jobs_cmd=(
  revenium jobs create
  --agentic-job-id "${clean_job_id}"
  --quiet
)
if [[ -n "${job_name}" ]]; then
  jobs_cmd+=(--name "${job_name}")
fi
if [[ -n "${job_type}" ]]; then
  jobs_cmd+=(--type "${job_type}")
fi
# Hermes-only — OMIT in OpenClaw (D-04):
# if [[ -n "${job_env_source}" ]]; then jobs_cmd+=(--environment "${job_env_source}"); fi

local jobs_cmd_output jobs_cmd_exit
jobs_cmd_output=$("${jobs_cmd[@]}" 2>&1) && jobs_cmd_exit=0 || jobs_cmd_exit=$?

local jobs_success=false
if [[ "${jobs_cmd_exit}" -eq 0 ]]; then
  jobs_success=true
elif echo "${jobs_cmd_output}" | grep -qi "409\|already.exist\|conflict"; then
  jobs_success=true
fi

if [[ "${jobs_success}" == "true" ]]; then
  local now_ts
  now_ts=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
  echo "JOB:${clean_job_id}:created:${now_ts}" >> "${JOBS_LEDGER_FILE}"
  info "Job created: agentic_job_id=${clean_job_id}"
else
  warn "jobs create failed: id=${clean_job_id} exit=${jobs_cmd_exit} — metering continues"
fi
```
**Ledger gate (skip if already created)** — wrap the whole block, mirroring `hermes-report.sh:874-877`:
```bash
if grep -q "^JOB:${clean_job_id}:created:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
  :   # already created — idempotent skip (D-06)
else
  # ... cmd array + 409-net + ledger write above ...
fi
```
**OpenClaw divergences from this Hermes block:**
- OMIT `--environment` entirely (D-04) — no `job_env_source` plumbing.
- Wire shape: `revenium jobs create --agentic-job-id X --name "..." --type "..." --quiet`.
- DO NOT push to a `job_outcome_queue` (Hermes line 872) — single-session in-loop (D-09).
- Use OpenClaw's OWN exit locals (`jobs_cmd_exit`); NEVER touch `failed_count`/`reported_count` (Pitfall 1 / D-12 — keep out of the CR-02 offset gate at `report.sh:693`).
- NEVER `return`/`exit` on failure (Pitfall, anti-pattern) — would skip `_cleanup_session_tmp` at `report.sh:700` and leak temp files. `warn` and continue.

---

### `scripts/report.sh` — `jobs outcome` (in-loop CLI call + ledger gate)

**Analog:** `../hermes-revenium/skills/revenium/scripts/hermes-report.sh:1176-1273` (proven outcome stage — adapt, narrow per D-07/D-08).

**Three gates to port verbatim** (`hermes-report.sh:1176-1198`):
```bash
# Gate 1 — already closed → idempotent skip (D-09)
if grep -q "^JOB:${outcome_id}:outcome:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
  continue   # OpenClaw in-loop: use the loop's skip path, not 'continue' of a post-loop for
fi
# Gate 2 — create not yet confirmed → defer to next tick (D-09)
if ! grep -q "^JOB:${outcome_id}:created:" "${JOBS_LEDGER_FILE}" 2>/dev/null; then
  warn "outcome deferred: id=${outcome_id} — JOB:...:created not yet confirmed"
  # ... (optional Hermes stale-warn at 1182-1196 — adopt or simplify per Claude's discretion)
fi
```
**Outcome cmd array (NARROWED — NO `--outcome-type`)** (`hermes-report.sh:1212-1216`, with the SUCCESS→CONVERTED block at 1221-1223 DELETED per D-07):
```bash
local outcome_cmd=(
  revenium jobs outcome "${outcome_id}"     # id is POSITIONAL, not a flag
  --result "${outcome_status}"
  --quiet
)
# HERMES-ONLY — DELETE for OpenClaw (D-07):
# if [[ "${outcome_status}" == "SUCCESS" ]]; then outcome_cmd+=(--outcome-type CONVERTED); fi
```
**`--metadata` for `failure_reason` (FAILED only, json.dumps via env heredoc, D-08)** — adapt `hermes-report.sh:1230-1251`, DROPPING Hermes' `source` field (OpenClaw has no source column):
```bash
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
```
**409-as-success + ledger-write-last** — port verbatim from `hermes-report.sh:1252-1273`:
```bash
outcome_cmd_output=$("${outcome_cmd[@]}" 2>&1) && outcome_cmd_exit=0 || outcome_cmd_exit=$?
outcome_success=false
if [[ "${outcome_cmd_exit}" -eq 0 ]]; then
  outcome_success=true
elif echo "${outcome_cmd_output}" | grep -qi "409\|already.exist\|conflict"; then
  outcome_success=true
fi
if [[ "${outcome_success}" == "true" ]]; then
  outcome_now_ts=$(python3 -c "import time; print(f'{time.time():.3f}')" 2>/dev/null || date +%s)
  echo "JOB:${outcome_id}:outcome:${outcome_now_ts}:${outcome_status}" >> "${JOBS_LEDGER_FILE}"
  info "Outcome reported: agentic_job_id=${outcome_id} result=${outcome_status}"
else
  warn "outcome failed: id=${outcome_id} exit=${outcome_cmd_exit} — retries next tick"
fi
```
**OpenClaw divergences:**
- NO `--outcome-type` ever (D-07) — delete Hermes lines 1221-1223.
- `--metadata` carries ONLY `failure_reason` (FAILED-only); drop Hermes' `source` field.
- Enum guard (`case ... SUCCESS|FAILED|CANCELLED`, `hermes-report.sh:1200-1209`) is
  belt-and-suspenders: OpenClaw markers are already uppercase + allowlisted at write time
  (`write-job-marker.sh:111`). Cheap to keep; not required (no mapping needed — `--result`
  enum == marker `status` allowlist 1:1).
- Single-tick natural order is create → stamp → outcome (D-09); same in-loop scope, NOT a
  post-loop `for` over a queue. Gate-2 makes a failed create safe (Pitfall 3).
- Job-CLI exit stays OUT of `failed_count`/CR-02 gate (D-12, Pitfall 1).

---

### `scripts/report.sh` — ledger dedup idiom (ledger gate)

**Analog:** `scripts/report.sh:659` (the existing `TX:` completion-dedup gate — same `grep -q "^PREFIX:..."` idiom).

**Existing idiom** (`report.sh:659`):
```bash
if grep -q "^TX:${tx_id}$" "${LEDGER_FILE}" 2>/dev/null; then
  continue
fi
```
**Job ledger gates (D-10) — same idiom, new prefixes, separate file:**
```bash
grep -q "^JOB:${id}:created:"  "${JOBS_LEDGER_FILE}"   # create gate
grep -q "^JOB:${id}:outcome:"  "${JOBS_LEDGER_FILE}"   # outcome gate
```
**Row shapes to write verbatim** (D-10, Hermes `hermes-report.sh:913,1268`):
```
JOB:add-pagination-3b1e:created:1717430400.123
JOB:add-pagination-3b1e:outcome:1717430460.456:SUCCESS
```
> The `TX:` gate at `report.sh:659` and the `revenium-reported.ledger` / `revenium-offsets.json`
> files stay UNTOUCHED (D-02, D-10). The jobs ledger is a SEPARATE file keeping the hot-path
> completion-dedup ledger single-purpose.

---

### `tests/test_report_jobs_argv.sh` (NEW — test harness)

**Analog:** `tests/test_report_argv.sh` (full file — clone its structure).

**Structural elements to clone** (`test_report_argv.sh:31-186`):
- pass/fail counters + final exit (`:38-42`, `:294-299`):
  ```bash
  PASS=0; FAIL=0
  pass() { echo "PASS: $1"; ((PASS++)) || true; }
  fail() { echo "FAIL: $1"; ((FAIL++)) || true; }
  # ... Results: ${PASS} passed, ${FAIL} failed; exit 1 if FAIL>0
  ```
- tmp `OPENCLAW_HOME` build (`:47-64`): `mktemp -d`, `agents/main/sessions`, `skills/revenium/markers`, empty `revenium-offsets.json` (`{}`), `touch revenium-reported.ledger`, `config.json`.
- **NEW for jobs:** `touch "${TMP_HOME}/revenium-jobs.ledger"` (or let `report.sh` create it) and inspect it after the run.
- stub on PATH via fake HOME `.local/bin` (`:158-177`): `ln -sf stub-revenium.sh .../revenium`; `export STUB_REVENIUM_ARGV_FILE=$(mktemp)`.
- run under stubbed env (`:182-186`): `OPENCLAW_HOME=... HOME=${TMP_FAKE_HOME} bash "${REPORT_SH}"`.
- argv assertions via one-token-per-line grep/awk (`:191`, `:263-264`):
  ```bash
  awk '/^--result$/{getline; print}' "${ARGV_FILE}"        # outcome status
  awk '/^--agentic-job-id$/{getline; print}' "${ARGV_FILE}" # stamped id
  grep -c "^create$"  "${ARGV_FILE}"                        # create-count == 1
  grep -c "^outcome$" "${ARGV_FILE}"                        # outcome-count == 1
  ```

**Fixtures to add (Wave 0, JLIFE-01..05):** a session with a `kind:"job"` marker
(`completion_id` = a same-tick completion's `.id`) for the SUCCESS path; a FAILED job with
`failure_reason` (assert `--metadata` present); a CANCELLED job (assert no `--metadata`); a
fail-open stub whose `jobs --help` exits non-zero or whose `meter completion --help` lacks
`--agentic-job-id` (assert zero `^jobs$`/`agentic-job` tokens, `--task-type`/`--agent` still
ship); a re-run idempotency check (run report.sh twice → exactly one `^create$` / one
`^outcome$` / one `JOB:...:created:` ledger row).

> Job-marker JSON shape to mirror in fixtures — from `write-job-marker.sh`:
> `{"kind":"job","ts":"...Z","sid":"...","agentic_job_id":"...","job_name":"...","job_type":"...","status":"SUCCESS|FAILED|CANCELLED","failure_reason":"...","completion_id":"..."}`.
> The existing task-marker fixtures (`MARKER_C` at `:131`, `MARKER_D` at `:156`) show the
> `completion_id` exact-match shape to reuse.

**Pitfall 4 (DECISION REQUIRED by planner):** `test_report_argv.sh:285-289` asserts NO
`--agentic-job-*` appears. Its Sessions A-D carry no job markers, so it stays GREEN if left
alone. **Recommendation:** leave `test_report_argv.sh` untouched (job-free); put ALL job
markers in the new `test_report_jobs_argv.sh`. The planner must state this explicitly so a
"passing" suite is not silently broken.

---

### `tests/stub-revenium.sh` (MODIFIED — test double)

**Analog:** `tests/stub-revenium.sh:15-20` (the existing argv-capture block — extend, don't replace).

**Existing capture (unchanged, keep first)** (`stub-revenium.sh:15-20`):
```bash
if [[ -n "${STUB_REVENIUM_ARGV_FILE:-}" ]]; then
  for arg in "$@"; do
    printf '%s\n' "${arg}" >> "${STUB_REVENIUM_ARGV_FILE}"
  done
fi
exit 0
```
**Extension (research §Stub extension)** — between capture and `exit 0`, fake a 409 when a test opts in via `STUB_REVENIUM_409_FOR`:
```bash
if [[ "$1 $2" == "jobs create" || "$1 $2" == "jobs outcome" ]]; then
  if [[ -n "${STUB_REVENIUM_409_FOR:-}" ]] && printf '%s\n' "$@" | grep -q -- "${STUB_REVENIUM_409_FOR}"; then
    echo "Error: 409 Conflict: job already exists" >&2
    exit 1
  fi
fi
```
> The stub must keep capturing ALL argv (so `jobs`/`create`/`outcome`/`--agentic-job-*`
> tokens are assertable) and default to `exit 0`. The 409 branch (exit 1 + conflict string)
> exercises the 409-as-success path (D-06) — the stub's only non-zero exit. For the fail-open
> test (JLIFE-04) a SEPARATE stub whose `jobs --help` exits non-zero / `meter completion
> --help` omits `--agentic-job-id` forces `JOBS_CLI_CAPABLE=false`.

---

## Shared Patterns

### Env-passing Python heredoc discipline (T-04-09)
**Source:** `scripts/report.sh:180-187` (`get_offset`), `:194-206` (`set_offset`), `:339-359` (markers read), `:489-552` (correlation), `:570-587` (duration).
**Apply to:** EVERY new inline Python in this phase (job-marker parse, `failure_reason`
json.dumps for `--metadata`, any ts math).
```bash
VAR="${untrusted_value}" python3 - <<'PY' 2>/dev/null || true
import os
v = os.environ.get('VAR', '')   # NEVER ${VAR} inside <<'PY'
PY
```
`failure_reason` is agent-supplied prose (quotes/braces) — json.dumps via env is the only
safe path to a `--metadata` JSON arg (V5 Tampering mitigation).

### Bash-array CLI assembly (never `eval`)
**Source:** `scripts/report.sh:235-289` (`post_to_revenium` cmd array); Hermes `hermes-report.sh:880-894,1212-1216`.
**Apply to:** every new CLI call (`jobs create`, `jobs outcome`, `--agentic-job-*` append).
```bash
local cmd=( revenium jobs create --agentic-job-id "${id}" --quiet )
[[ -n "${name}" ]] && cmd+=(--name "${name}")
out=$("${cmd[@]}" 2>&1) && exit=0 || exit=$?
```
Phase-5 marker sanitization (`:`/`|`/newline→`_`, `write-job-marker.sh:88-113`) is the
upstream net; array discipline is the downstream net (V5 / argument-injection).

### Fail-open: capture-exit-and-warn, never abort (D-12 / JLIFE-04)
**Source:** `scripts/report.sh:291-302` (`post_to_revenium` exit handling); Hermes `hermes-report.sh:896-918,1252-1273`.
**Apply to:** every job-CLI call site.
- Use OWN exit locals (`jobs_cmd_exit`, `outcome_cmd_exit`); NEVER touch `failed_count`/`reported_count`.
- NEVER `return`/`exit` out of `process_session` on a job error (skips `_cleanup_session_tmp` at `report.sh:700`, leaks temp files, drops remaining completions).
- Job failures MUST stay out of the CR-02 offset gate (`report.sh:693`) — that gate is driven
  solely by `post_to_revenium` success (Pitfall 1; wiring job failures in would re-meter /
  double-bill).

### 409-as-success idempotency net
**Source:** Hermes `hermes-report.sh:903-907` (create), `:1255-1259` (outcome).
**Apply to:** `jobs create` AND `jobs outcome`.
```bash
if [[ "${exit}" -eq 0 ]]; then success=true
elif echo "${out}" | grep -qi "409\|already.exist\|conflict"; then success=true; fi
```
Backstop for a crash between API call and ledger write (the local ledger gates the common
path). Assumption A1: live OpenClaw-Revenium conflict string assumed identical to Hermes;
verify with one live duplicate call at UAT (non-blocking).

### Ledger-gated idempotency
**Source:** `scripts/report.sh:659` (`TX:` gate); Hermes `hermes-report.sh:874-877,1176-1181`.
**Apply to:** create (`^JOB:<id>:created:`), outcome (`^JOB:<id>:outcome:`), separate `revenium-jobs.ledger`. Ledger row is the LAST statement of each success branch.

---

## No Analog Found

None. Every new/modified surface maps to a concrete analog — in-repo (`report.sh` optional-flag
blocks, two-phase correlation, `TX:` ledger gate, env heredocs, `test_report_argv.sh`
harness) or in Hermes (probe, create, outcome, 409-net). Phase 6 is composition + narrowing,
not invention.

---

## Metadata

**Analog search scope:** `scripts/report.sh` (full, 729 lines), `tests/stub-revenium.sh`
(full), `tests/test_report_argv.sh` (full), `../hermes-revenium/.../hermes-report.sh` (lines
30-59, 855-924, 1055-1085, 1176-1275).
**Files scanned:** 4 source files read; all line-number landmarks cross-checked against
RESEARCH.md's corrected code map (research §State of the Art) and verified accurate.
**Pattern extraction date:** 2026-06-03
