# Phase 7: Root-Session Job Rollup - Research

**Researched:** 2026-06-03
**Domain:** Bash shell scripting — report.sh multi-session job attribution, subagent
discriminator, cross-session marker reads, root-only lifecycle gates
**Confidence:** HIGH

## Summary

Phase 7 extends the single-session job lifecycle wired in Phase 6 into a multi-session
attribution model: completions from any subagent session carry the ROOT session's
`agentic_job_id`, not a subagent-local one. The subagent discriminator (`root_sid !=
session_id`) is already live in `report.sh` (line 329-330) for trace rollup. Phase 7
reuses it verbatim for the job dimension and adds three changes to `report.sh`:

1. A new once-per-subagent-session `root_aid` resolution block (cross-session read of
   `markers/{root_sid}.jsonl`, latest `kind:"job"` line wins, empty on race → omit).
2. A substitution in the per-completion job correlation: for subagents, replace the
   same-session `jobs_cache_file` result with `root_aid`/`root_job_name`/`root_job_type`.
3. A root-only gate on both the `jobs create` and `jobs outcome` blocks — subagent
   sessions short-circuit past them entirely.

The Hermes reference (`hermes-report.sh` lines 204-254, 343-347, 862-863) provides a
direct, proven implementation to port. The translation is primarily literal renaming:
Hermes uses `root_aid` / `m_owning_job_id` / unix-float ts / SQLite resolver; OpenClaw
uses `--agentic-job-id` / ISO8601 ts / JSONL childSessionKey resolver. Logic and security
idioms transfer unchanged.

**Primary recommendation:** Port the Hermes `root_aid` block verbatim (lines 204-254) as
a sibling to the existing `root_sid` resolution at report.sh line 329-330, gate both
`jobs create` (line 699) and `jobs outcome` (line 864) on `[[ "${root_sid}" == "${session_id}" ]]`,
and feed `root_aid`/`root_job_name`/`root_job_type` into the existing `--agentic-job-*`
arg slots in `post_to_revenium` for subagent sessions.

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Subagent discriminator = `root_sid != session_id`. No new detection mechanism.
- **D-02:** Subagent completions inherit the ROOT's `agentic_job_id` (override). Applies
  wholesale to all completions in a subagent session, not per `completion_id`.
- **D-03:** Ship now, job-less (best-effort) — do NOT defer completions when `root_aid`
  is empty (race window). Spend still rolls up via `--agent`.
- **D-04:** Never ship a wrong or sub-session id. If `root_aid` is empty, omit
  `--agentic-job-id` entirely — never substitute the subagent's own orphan id.
- **D-05:** Latest root job marker wins (last `kind:"job"` line in file order).
- **D-06:** Root-only `jobs create` / `jobs outcome`. Subagent sessions skip BOTH.
- **D-07:** Orphan subagent job (no root job declared) → ship job-less (drop orphan).
  Same invariant as D-04.
- **D-08:** Resolve `root_aid` from `markers/{root_sid}.jsonl` (not the jobs ledger).
  Reads latest `kind:"job"` marker's `agentic_job_id` + `job_name` + `job_type`.
- **D-09:** Resolve `root_aid` ONCE per subagent session, cached for the whole loop.
  Top-level sessions skip it entirely.
- Phase 6 single-session lifecycle (create/stamp/outcome, ledger, `JOBS_CLI_CAPABLE`,
  fail-open) must remain byte-identical for root sessions.
- No `--outcome-type` ever (Phase 6 D-07 carried).
- No backfill, no offset fighting, no completion deferral (Phase 6 D-01/D-02 carried).
- CR-02: `root_aid` lookup and any job omission must never touch the `TX:` offset gate.

### Claude's Discretion

- Exact placement of the `root_aid` resolution block in `process_session` (parallel to
  existing `root_sid` resolution at ~line 329).
- Whether to reuse/extend the existing markers-cache Python read or add a sibling read
  for the cross-session `root_aid` lookup. Hermes uses a dedicated inline heredoc; the
  env-passing-heredoc discipline (T-04-09) applies: pass `ROOT_SID`/`MARKERS_DIR` via
  env, never interpolate.
- Whether the root-only gate is an early `if [[ "${root_sid}" == "${sid}" ]]` wrapper
  around the existing create/outcome blocks, or an inline guard at each stage.
- Log/warn wording for the omit-on-race path (D-03) and orphan-drop path (D-07).
- Whether to `info`-log subagent rollup correlations (parallel to the existing `Job
  correlation:` log at ~line 688).
- Test strategy: covered in the Validation Architecture section below.

### Deferred Ideas (OUT OF SCOPE)

- Timestamp-active root-job matching (vs. latest-wins).
- Holding/deferring subagent completions until root job resolves.
- Halt → CANCELLED interrupted-job record (Phase 8 / JHALT).
- Per-completion full-arc backfill / restamp.
- `--outcome-type CONVERTED` / business-outcome metrics (JOUT-01).
- Per-job-type budget rules (JGUARD-01).
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| JROLL-01 | Completions from a subagent session ship the ROOT session's `agentic_job_id` (override), so one job spans the whole agent tree. | D-01 discriminator already live; D-08/D-09 `root_aid` resolve enables override; `post_to_revenium` arg slots 22-24 already accept job fields |
| JROLL-02 | When root job ID cannot yet be resolved (marker race), completion omits `--agentic-job-id` and is retried on next tick rather than shipping a wrong or sub-session ID. | D-03/D-04 design confirmed; `--agentic-job-*` block (line 298) already conditional on non-empty id; no new guard needed |
| JROLL-03 | Top-level sessions ship their own declared job; a subagent's internally-declared job markers are not shipped as separate jobs. | D-06 root-only gate on `jobs create` (line 699) and `jobs outcome` (line 864) |
</phase_requirements>

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Subagent detection | report.sh (per-session) | get-root-session-id.py | `root_sid` already resolved once per session; discriminator is a shell comparison, not a separate service |
| Root job ID resolution | report.sh (once per subagent session) | markers/{root_sid}.jsonl | Cross-session marker read; Python heredoc handles file parsing; result cached as bash local |
| Job id override injection | post_to_revenium() (per-completion) | — | Existing arg slots 22-24; conditional on JOBS_CLI_CAPABLE and non-empty id |
| jobs create / outcome gating | process_session() (per-job-marker) | revenium-jobs.ledger | Root-only guard wraps existing Phase 6 blocks; ledger provides cross-tick idempotency |
| Orphan-drop / race-omit policy | report.sh (per-session initialization) | — | Shell variable stays empty on race; post_to_revenium omits the flag when empty |

---

## Standard Stack

### Core (no new dependencies)

Phase 7 adds zero external dependencies. All implementation is pure bash + inline python3
heredoc (already the established pattern in report.sh).

| Component | Current Version | Purpose | Notes |
|-----------|----------------|---------|-------|
| `scripts/report.sh` | Phase 6 baseline (970 lines) | Primary file modified | All Phase 7 changes land here |
| `scripts/get-root-session-id.py` | Phase 4 / v1.0 | Resolves child→root via JSONL childSessionKey walk | No change expected; tests must exercise it |
| `tests/stub-revenium.sh` | Phase 6 extended | argv-capturing stub | Needs new env switch for Phase 7 subagent fixture scenarios |
| `tests/test_report_jobs_argv.sh` | Phase 6 (GROUP A-E) | Integration test for job lifecycle | Extended with Phase 7 subagent groups |

### Supporting (existing, reused)

| Component | Purpose | Phase 7 Role |
|-----------|---------|-------------|
| `scripts/common.sh` `MARKERS_DIR` | Path to per-session marker JSONL files | `root_aid` lookup reads `MARKERS_DIR/{root_sid}.jsonl` |
| `tests/fixtures/sessions/` | `sessions_spawn` JSONL fixture | Already has parent-with-spawn fixture; Phase 7 test extends or reuses |
| `revenium-jobs.ledger` | Cross-tick create/outcome idempotency | No schema change; Phase 7 subagent sessions never write to it |

**Installation:** None — no packages to install.

---

## Package Legitimacy Audit

Not applicable — Phase 7 installs no external packages.

---

## Architecture Patterns

### System Architecture Diagram

```
cron tick
    |
    v
report.sh main()
    |
    +---> process_session(session_file)  [per session file]
              |
              +-- root_sid = get_root_session_id(session_id)  [line 329]
              |       |
              |       +-- calls get-root-session-id.py (JSONL childSessionKey walk)
              |       +-- fail-open: returns session_id itself if no parent found
              |
              +-- [NEW Phase 7] root_sid == session_id?
              |       YES (root): root_aid = "" (skip cross-session read)
              |       NO (subagent): read markers/{root_sid}.jsonl
              |                      last kind:"job" line -> root_aid, root_job_name, root_job_type
              |                      file absent or no job lines -> root_aid = ""
              |
              +-- parse markers/{session_id}.jsonl [existing Phase 6]
              |       -> markers_cache_file (task markers)
              |       -> jobs_cache_file    (own job markers, subagent or root)
              |
              +-- per-completion loop:
              |       |
              |       +-- resolve task_type from markers_cache_file [unchanged]
              |       |
              |       +-- resolve agentic_job_id:
              |       |       root session: from jobs_cache_file (Phase 6 unchanged)
              |       |       subagent, root_aid non-empty: use root_aid (override)
              |       |       subagent, root_aid empty: agentic_job_id="" (omit)
              |       |
              |       +-- [NEW gate] jobs create: only when root_sid == session_id
              |       |
              |       +-- post_to_revenium(..., agentic_job_id, agentic_job_name, agentic_job_type)
              |       |       --agentic-job-id appended only when JOBS_CLI_CAPABLE && non-empty [unchanged]
              |       |
              |       +-- [NEW gate] jobs outcome: only when root_sid == session_id
              |
              +-- advance TX offset (CR-02 unchanged)
```

### Recommended Project Structure

No new files added. All changes are within:

```
scripts/
  report.sh             # All Phase 7 modifications
tests/
  stub-revenium.sh      # Possibly new env switch (see Validation Architecture)
  test_report_jobs_argv.sh   # New GROUP F (subagent groups)
  fixtures/
    sessions/           # New multi-hop JSONL fixture needed (root + child sessions)
    markers/            # New root job marker fixture needed
```

### Pattern 1: `root_aid` Resolution (Hermes port, adapted)

**What:** Once per subagent session (skipped for root sessions), read the root's markers
file and extract the latest `kind:"job"` record's id/name/type.

**When to use:** Immediately after the existing `root_sid` resolution block (line 329-330),
before the markers-cache parse.

```bash
# Source: hermes-report.sh lines 204-254 (adapted — env passing, no unix_float ts)
local root_aid="" root_job_name="" root_job_type=""
if [[ "${root_sid}" != "${session_id}" ]]; then
  local _root_resolve
  _root_resolve=$(
    ROOT_SID="${root_sid}" MARKERS_DIR="${MARKERS_DIR}" python3 - <<'PY' 2>/dev/null || true
import json, os
from pathlib import Path
root_sid   = os.environ.get('ROOT_SID', '')
markers_dir = os.environ.get('MARKERS_DIR', '')
if not root_sid or not markers_dir:
    raise SystemExit(0)
mpath = Path(markers_dir) / f"{root_sid}.jsonl"
if not mpath.exists():
    raise SystemExit(0)
latest_aid = latest_name = latest_type = ""
try:
    with open(mpath, encoding='utf-8') as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw: continue
            try:
                rec = json.loads(raw)
            except Exception:
                continue
            if not isinstance(rec, dict): continue
            if rec.get('kind') == 'job':
                aid = rec.get('agentic_job_id', '')
                if isinstance(aid, str) and aid:
                    for bad in ('|', '\n', '\r', ':'):
                        aid = aid.replace(bad, '_')
                    latest_aid  = aid
                    latest_name = str(rec.get('job_name', ''))
                    latest_type = str(rec.get('job_type', ''))
    if latest_aid:
        print(f"{latest_aid}\t{latest_name}\t{latest_type}")
except OSError:
    pass
PY
  )
  _root_resolve="${_root_resolve%%$'\n'*}"
  if [[ -n "${_root_resolve}" ]]; then
    root_aid="${_root_resolve%%$'\t'*}"
    local _rr2="${_root_resolve#*$'\t'}"
    root_job_name="${_rr2%%$'\t'*}"
    root_job_type="${_rr2#*$'\t'}"
  fi
fi
```

### Pattern 2: Subagent Job ID Override (in-loop, per-completion)

**What:** After the Phase 6 per-completion `agentic_job_id` resolution from `jobs_cache_file`,
override with root values when this is a subagent session.

**When to use:** Immediately after the jobs_cache_file Python resolve block (currently
ending ~line 690), before the `jobs create` block (line 699).

```bash
# Source: CONTEXT.md D-02/D-07 — subagent override replaces same-session correlation
# Override only for subagents; root sessions take the Phase 6 path unchanged.
if [[ "${root_sid}" != "${session_id}" ]]; then
  if [[ -n "${root_aid}" ]]; then
    # Inherit root's job for this completion (JROLL-01)
    agentic_job_id="${root_aid}"
    agentic_job_name="${root_job_name}"
    agentic_job_type="${root_job_type}"
  else
    # Race window or no root job declared — omit (JROLL-02 / D-03 / D-04 / D-07)
    agentic_job_id=""
    agentic_job_name=""
    agentic_job_type=""
  fi
fi
```

### Pattern 3: Root-Only Gate on `jobs create` and `jobs outcome` (JROLL-03)

**What:** Wrap both existing `jobs create` (line 699) and `jobs outcome` (line 864)
blocks with `[[ "${root_sid}" == "${session_id}" ]]`.

**When to use:** As the outermost condition on each block. The Phase 6 inner logic
(ledger-gated, 409-as-success, fail-open) is preserved byte-for-byte inside the gate.

```bash
# Source: hermes-report.sh lines 347, 863 (adapted)
# BEFORE (Phase 6):
if [[ "${JOBS_CLI_CAPABLE}" == "true" && -n "${agentic_job_id}" ]]; then
  # jobs create ...

# AFTER (Phase 7):
if [[ "${JOBS_CLI_CAPABLE}" == "true" && -n "${agentic_job_id}" \
   && "${root_sid}" == "${session_id}" ]]; then
  # jobs create ...  (unchanged inside)
```

The same compound condition wraps `jobs outcome`.

### Anti-Patterns to Avoid

- **Substituting orphan id on race:** If `root_aid` is empty, the subagent's own
  `agentic_job_id` (from `jobs_cache_file`) MUST NOT be shipped. Override to empty before
  `post_to_revenium`. D-04/D-07 are load-bearing safety invariants.
- **Re-reading the root markers file per completion:** Resolve once per session and cache
  in bash locals. Reading per completion loops re-opens the file needlessly and defeats
  the Python cold-start amortization that is explicit in D-09.
- **String-interpolating ROOT_SID into the Python heredoc:** Use env-passing (T-04-09).
  `ROOT_SID="${root_sid}" python3 - <<'PY'` — the single-quoted `'PY'` delimiter
  prevents expansion inside the script body.
- **Touching the TX: offset gate on root_aid lookup failure:** The lookup must stay
  outside the `post_to_revenium` success path. No lookup failure should affect CR-02.
- **Firing `jobs create`/`outcome` for subagent sessions that happen to have their own
  job markers:** The root-only gate must precede the `agentic_job_id` resolution check,
  not follow it. After the Phase 7 override, a subagent's `agentic_job_id` holds the
  root's id — without the gate, the subagent would also attempt to `create` a job that
  the root already created (causing spurious 409s or duplicate ledger rows).

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Cross-session parent→root walk | Custom bash glob+grep | `get-root-session-id.py` (already exists) | cycle guard, max_depth=10, fail-open, tested |
| JSON parsing in bash | bash string slicing | inline python3 heredoc (established pattern) | JSON escaping, UTF-8, malformed-line resilience |
| Latest-job-wins scan | Sort by timestamp | Linear scan, last-wins (file order = append order) | Markers are appended chronologically; no sort needed |
| `agentic_job_id` sanitization | Re-implement in bash | Existing python3 sanitize loop (`replace` for `:`/`|`/newlines) | Same logic as Phase 5 write-job-marker.sh; no new code |

**Key insight:** Every non-trivial piece of infrastructure already exists. Phase 7 is
predominantly wiring: one new read, one override block, two guarded blocks.

---

## Line Number Verification (CONTEXT.md Drift Audit)

The CONTEXT.md cited approximate line numbers. Verified against the actual current
`scripts/report.sh` (970 lines, Phase 6 complete):

| CONTEXT.md Landmark | Cited Lines | Actual Lines | Status |
|---------------------|------------|-------------|--------|
| `get_root_session_id()` wrapper | ~line 50 | lines 50-58 | **EXACT MATCH** |
| per-session `root_sid` resolution | ~lines 328-330 | lines 328-330 | **EXACT MATCH** |
| `post_to_revenium()` `--agentic-job-*` block | ~lines 298-301 | lines 296-302 | **CLOSE** (+/- 2 lines) |
| in-loop `jobs create` block | ~lines 699-724 | lines 699-727 | **CLOSE** (+3 lines) |
| `jobs outcome` block | ~lines 864-902 | lines 856-905 | **CLOSE** (-8 lines opening) |
| markers-cache Python read in `process_session` | ~lines 351-381 | lines 340-402 | **EXPANDED** (both tasks+jobs cache now; note: Phase 6 already added `jobs_cache_file`) |
| `JOBS_CLI_CAPABLE` probe | startup | lines 962-968 | unchanged location |

**Key finding — Phase 6 already wired `jobs_cache_file` parsing in the markers-cache
Python block (lines 357-401).** The same Python heredoc that emits task markers now also
emits job markers to a sibling `jobs_cache_file`. This is NOT a Phase 7 addition — it
was Phase 6's work. Phase 7 does NOT need to extend this read for the subagent case;
the `jobs_cache_file` will always be populated from the subagent's own markers. Phase 7's
new cross-session read (`root_aid` from `markers/{root_sid}.jsonl`) is a SEPARATE,
additional heredoc resolving to bash locals, executed once after line 330.

**Key finding — `post_to_revenium()` already accepts `agentic_job_id`/`agentic_job_name`/`agentic_job_type` as positional args 22-24 (lines 236-238) and the `--agentic-job-*` append block is at lines 298-302.** Phase 7 only changes WHICH values are passed at the call site (line 847-848), not the function signature or the append block itself.

**Hermes reference line numbers verified:**
- Lines 204-254: `root_aid` resolution block — confirmed, directly portable [VERIFIED: read hermes-report.sh]
- Lines 343-347: pre-loop root-only gate — confirmed, `if [[ "${root_sid}" == "${sid}" ]]` [VERIFIED: read hermes-report.sh]
- Lines 862-863: in-loop root-only gate — confirmed, same condition [VERIFIED: read hermes-report.sh]

---

## Common Pitfalls

### Pitfall 1: Subagent Creates Its Own Job (D-06 gate missing or misplaced)

**What goes wrong:** A subagent session has its own `kind:"job"` markers. After the
Phase 7 override, `agentic_job_id` holds the root's id. Without the root-only gate, the
subagent loop enters the `jobs create` block and attempts to create the root's job a
second time.

**Why it happens:** The Phase 6 condition `JOBS_CLI_CAPABLE && -n agentic_job_id` remains
true for subagents after the override. The gate must be added.

**How to avoid:** Add `&& "${root_sid}" == "${session_id}"` as a compound condition on
BOTH `jobs create` AND `jobs outcome` blocks. Test with a subagent fixture that has its
own job marker — assert zero `^create$` tokens for the subagent's invocation.

**Warning signs:** More than N `^create$` tokens where N = number of root session jobs;
`jobs create` for an id that was already created by a prior root-session run.

### Pitfall 2: Orphan Subagent id Shipped on Race (D-04 violated)

**What goes wrong:** When `root_aid` is empty (race window), the code falls through to the
Phase 6 correlation path, which resolves the subagent's OWN job marker's id from
`jobs_cache_file`. That orphan id is then shipped on `--agentic-job-id`.

**Why it happens:** The override block exits early when `root_aid` is non-empty but does
not clear `agentic_job_id` when `root_aid` is empty in the subagent case.

**How to avoid:** The override block must **always** clear `agentic_job_id=""` for
subagent sessions when `root_aid` is empty — it cannot leave the Phase 6 resolution
intact for subagents. The race-omit test (fixture: subagent with own job marker, no root
job marker) must assert ZERO `--agentic-job-id` tokens in argv.

**Warning signs:** A subagent-format id (not matching any root's job) appearing in
`--agentic-job-id` args; a `jobs create` call for an id that is never in the root's
markers file.

### Pitfall 3: `root_job_name`/`root_job_type` Not Threaded Through

**What goes wrong:** `root_aid` is resolved and overrides `agentic_job_id`, but
`agentic_job_name` and `agentic_job_type` are left at the Phase 6 same-session values
(empty, or worse, the subagent's own job name). The `post_to_revenium` call then ships
`--agentic-job-id <root_id>` with mismatched or missing name/type.

**Why it happens:** The Python heredoc in Pattern 1 emits all three fields on one line,
but the bash tab-split to populate `root_job_name`/`root_job_type` is easy to omit.

**How to avoid:** The heredoc must emit `"{root_aid}\t{root_job_name}\t{root_job_type}"`.
The bash parser must split all three into separate locals. Assert `--agentic-job-name`
is present in the subagent fixture's captured argv.

### Pitfall 4: Per-Completion Root Marker Re-Read

**What goes wrong:** The `root_aid` resolve Python heredoc is placed inside the
per-completion while loop instead of before it. On a busy session, this launches a python3
process for every completion line.

**Why it happens:** Copy-paste from the per-completion task-type or job-correlation blocks.

**How to avoid:** The `root_aid` block must be at session initialization scope (after
`root_sid` at line 329-330, before the `while IFS= read -r line; do` loop). D-09 is
explicit: resolve once per session. CI test will catch it only if the fixture has multiple
completions — verify this.

### Pitfall 5: `_cleanup_session_tmp` Does Not Know About New Locals

**What goes wrong:** The `root_aid` resolve uses no new temp files (it writes to bash
locals only), but if the implementation accidentally introduces a temp file, it must be
added to `_cleanup_session_tmp` (line 343-345).

**How to avoid:** The Hermes pattern uses only bash locals for `root_aid`; no temp file
is needed. Do not add a temp file for this read.

### Pitfall 6: Regression on Root Sessions (Phase 6 Byte-Identical Contract)

**What goes wrong:** The root-only gate or the subagent override mistakenly fires for
root sessions (`root_sid == session_id`), changing the job lifecycle for root sessions.

**How to avoid:** The existing `test_report_jobs_argv.sh` Phase 6 test suite (Groups A-E)
must continue to pass GREEN after Phase 7 changes. These tests use root-only sessions
(no `sessions_spawn` link), so their `root_sid == session_id`, and all Phase 6 lifecycle
must be unchanged.

---

## Code Examples

### Fixture: Parent Session with `sessions_spawn` Link

Verified format from `tests/fixtures/sessions/a1b2c3d4-0001-0001-0001-000000000001.jsonl`:

```jsonl
{"type":"session","version":3,"id":"<PARENT_UUID>","timestamp":"...","cwd":"/tmp/test"}
{"type":"message","id":"msg00002","parentId":"msg00001","timestamp":"...","message":{"role":"toolResult","toolName":"sessions_spawn","content":[{"type":"text","text":"{\"childSessionKey\": \"agent:main:subagent:<CHILD_UUID>\", ...}"}],"details":{"status":"accepted","childSessionKey":"agent:main:subagent:<CHILD_UUID>","runId":"run-0001"}}}
```

Key: `details.childSessionKey` must have the `agent:main:subagent:` prefix. The resolver
strips this prefix with `rsplit(":", 1)[-1]` to get the raw UUID.

### Fixture: Root Markers File with Job Marker

New fixture needed — `markers/{ROOT_UUID}.jsonl`:

```jsonl
{"kind":"job","ts":"2026-02-01T10:03:00Z","sid":"<ROOT_UUID>","agentic_job_id":"add-auth-9f3c","job_name":"Add Auth","job_type":"feature_development","status":"SUCCESS","completion_id":"comp-root-001"}
```

This is the file the `root_aid` resolver reads. It lives in `MARKERS_DIR` (i.e.,
`skills/revenium/markers/`), NOT in `agents/main/sessions/`.

### Stub Revenium Extension (JROLL tests)

No new env switch needed for Phase 7's main assertion path. The existing
`STUB_REVENIUM_NO_JOBS=1` (fail-open) and the default (jobs succeed) cover all
Phase 7 cases. The stub captures all argv; assertions check for presence or absence
of `--agentic-job-id` in the captured file.

---

## Validation Architecture

> `workflow.nyquist_validation: true` — this section is required.

### Test Framework

| Property | Value |
|----------|-------|
| Framework | bash integration tests (no external framework) |
| Config file | none — tests are standalone shell scripts |
| Quick run command | `bash tests/test_report_jobs_argv.sh` |
| Full suite command | `bash tests/test_report_argv.sh && bash tests/test_report_jobs_argv.sh && python3 -m pytest tests/test_get_root_session_id.py -v` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| JROLL-01 | Subagent completion ships root's `agentic_job_id` | integration | `bash tests/test_report_jobs_argv.sh` (GROUP F) | Wave 0 — GROUP F must be added |
| JROLL-02 | Race window → omit `--agentic-job-id` (no wrong id shipped) | integration | `bash tests/test_report_jobs_argv.sh` (GROUP G) | Wave 0 — GROUP G must be added |
| JROLL-03 | Subagent's own job markers do NOT trigger `jobs create`/`outcome` | integration | `bash tests/test_report_jobs_argv.sh` (GROUP H) | Wave 0 — GROUP H must be added |
| JROLL-03 (orphan) | Orphan subagent (no root job) ships job-less | integration | `bash tests/test_report_jobs_argv.sh` (GROUP H extended) | Wave 0 |
| Phase 6 regression | Root sessions byte-identical (Groups A-E pass) | integration | `bash tests/test_report_jobs_argv.sh` | Exists — run unchanged |
| get-root-session-id | Resolver handles multi-hop, cycle, missing dir | unit (pytest) | `python3 -m pytest tests/test_get_root_session_id.py -v` | Exists — extend for multi-hop |

### The Four Phase 7 Test Cases (from CONTEXT.md Discretion)

These are the four behavioral cases the CONTEXT.md mandates test coverage for. Each maps
to a specific GROUP in `test_report_jobs_argv.sh`:

---

**GROUP F — Subagent Inherits Root's `agentic_job_id` (JROLL-01)**

Fixture structure:
- `sessions/{ROOT_UUID}.jsonl` — root session JSONL with `sessions_spawn` tool result
  linking to `{CHILD_UUID}` (needed so `get-root-session-id.py` resolves child→root).
- `sessions/{CHILD_UUID}.jsonl` — subagent session JSONL with one completion.
- `markers/{ROOT_UUID}.jsonl` — root job marker: `kind:"job"`, `agentic_job_id: "root-job-1a2b"`,
  `job_name: "Root Job"`, `job_type: "feature_development"`, `status: "SUCCESS"`.
- `markers/{CHILD_UUID}.jsonl` — either absent or contains its own `kind:"job"` marker
  with a DIFFERENT id (to confirm it is not shipped).

Assertions:
1. `--agentic-job-id` in captured argv resolves to `root-job-1a2b` (the ROOT's id, not
   the child's own id if present).
2. `--agentic-job-name` value is `"Root Job"` (root's name, not child's).
3. `--agentic-job-type` value is `"feature_development"` (root's type).
4. Zero `^create$` tokens in the CHILD's invocation pass (only the ROOT session creates).
   Since both root and child are processed in the same `OPENCLAW_HOME`, count `^create$`
   tokens = exactly 1 (root's job), not 2.
5. The ledger `JOB:root-job-1a2b:created:...` exists exactly once.

Key requirement: the `sessions/` directory must contain both `{ROOT_UUID}.jsonl` and
`{CHILD_UUID}.jsonl` so `get-root-session-id.py` can build its reverse map and return
`ROOT_UUID` when asked to resolve `CHILD_UUID`. Without this link, the resolver returns
the input sid, making every session look like a root — the subagent detection never fires.

---

**GROUP G — Race Window → Omit (JROLL-02)**

Fixture structure:
- `sessions/{ROOT_UUID}.jsonl` — root session with `sessions_spawn` link to child.
- `sessions/{CHILD_UUID}.jsonl` — subagent session with one completion.
- `markers/{ROOT_UUID}.jsonl` — **ABSENT or EMPTY** (no `kind:"job"` line yet; simulates
  the race where the root has not yet declared its job).
- `markers/{CHILD_UUID}.jsonl` — may optionally have a `kind:"job"` marker with its own
  id (confirming D-04/D-07: the orphan id must NOT be shipped even when present).

Assertions:
1. Zero `--agentic-job-id` tokens in captured argv for the child's completions.
   (The `post_to_revenium` `--agentic-job-*` block must have been skipped entirely.)
2. `--agent` is still present (v1.0 rollup via `openclaw-{root_sid}` unchanged).
3. `--task-type` is still present (metering v1.0 path byte-identical).
4. Zero `^create$` tokens.
5. Zero `^outcome$` tokens.
6. Completion IS reported (TX: ledger entry exists) — spend ships without job id.

Note: the "retry next tick" aspect of JROLL-02 is tested by running report.sh a SECOND
time after adding a root job marker file — the child's now-already-TX:-ledgered completion
won't re-meter, but the test confirms the omit-on-first-tick path. The re-try behavior
(next tick sees root_aid) is implicitly tested by GROUP F (which has root marker already
present from tick 1).

---

**GROUP H — Subagent Job Markers Suppressed (JROLL-03)**

Fixture structure:
- `sessions/{ROOT_UUID}.jsonl` — root session with `sessions_spawn` link to child, no
  completions needed (or include root completions that DO get jobs create/outcome).
- `sessions/{CHILD_UUID}.jsonl` — subagent session with one completion.
- `markers/{ROOT_UUID}.jsonl` — root job marker (enables JROLL-01 path).
- `markers/{CHILD_UUID}.jsonl` — subagent's OWN `kind:"job"` marker with id `"sub-job-3c4d"`.

Assertions:
1. Zero `^create$` tokens for `sub-job-3c4d` — subagent's own job is never created.
2. Zero `^outcome$` tokens for `sub-job-3c4d`.
3. No `JOB:sub-job-3c4d:...` line in the jobs ledger.
4. The subagent's completion DOES ship `--agentic-job-id root-job-1a2b` (the root's id,
   not the subagent's own id) — JROLL-01 and JROLL-03 are non-conflicting.
5. If the root session also has a completion, its `jobs create`/`outcome` fires normally
   (exactly 1 `^create$` for root's job id).

**GROUP H Extension — Orphan Subagent (no root job, JROLL-02/D-07)**

Fixture: same as GROUP G but with the subagent's own job marker explicitly present.
Extra assertion: zero `--agentic-job-id` tokens (subagent's orphan id must not leak
through). Covered in GROUP G with `markers/{CHILD_UUID}.jsonl` present.

---

### Required Fixtures for Wave 0

All new fixtures live in `tests/fixtures/sessions/` (sessions_spawn JSONL) and a
new `tests/fixtures/markers/` directory (root job marker JSONL).

| Fixture | Path | Purpose | New? |
|---------|------|---------|------|
| Root parent session | `tests/fixtures/sessions/{ROOT_UUID}.jsonl` | Contains `sessions_spawn` tool result linking to child | YES |
| Child/subagent session | `tests/fixtures/sessions/{CHILD_UUID}.jsonl` | Subagent JSONL processed by report.sh | YES |
| Root markers file | `tests/fixtures/markers/{ROOT_UUID}.jsonl` | `kind:"job"` marker for root job | YES |

The existing fixture `a1b2c3d4-0001-0001-0001-000000000001.jsonl` (parent→child link) is
already present in `tests/fixtures/sessions/`. If the test builds its `OPENCLAW_HOME`
using those UUIDs, it can reference the existing fixture rather than creating new ones.
However, since `test_report_jobs_argv.sh` creates its own `TMP_HOME` from scratch (not
from `tests/fixtures/`), the test must write its own `sessions_spawn` JSONL inline
(same pattern as existing SESSION_J1/J2/J3 fixtures) or copy the fixture file.

**Preferred approach:** Write inline JSONL within `test_report_jobs_argv.sh` using
heredocs, matching the pattern of existing groups. The `sessions_spawn` line shape is:

```bash
printf '%s\n' \
  '{"type":"session","version":3,"id":"'"${ROOT_UUID}"'","timestamp":"...","cwd":"/tmp"}' \
  '{"type":"message","id":"spawn-msg","parentId":"00000000","timestamp":"...","message":{"role":"toolResult","toolName":"sessions_spawn","content":[{"type":"text","text":"{}"}],"details":{"status":"accepted","childSessionKey":"agent:main:subagent:'"${CHILD_UUID}"'","runId":"run-test"}}}' \
  > "${TMP_HOME_F}/agents/main/sessions/${ROOT_UUID}.jsonl"
```

Note: `get-root-session-id.py` pre-filters on `'"sessions_spawn"'` (raw string), so the
`toolName` value `sessions_spawn` must appear literally in the JSON string. The `content`
field is not parsed — only `message.details.childSessionKey` is read.

### Sampling Rate

- **Per task commit:** `bash tests/test_report_jobs_argv.sh`
- **Per wave merge:** `bash tests/test_report_argv.sh && bash tests/test_report_jobs_argv.sh && python3 -m pytest tests/test_get_root_session_id.py -v`
- **Phase gate:** Full suite green before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `tests/test_report_jobs_argv.sh` GROUP F — subagent inherits root `agentic_job_id` (JROLL-01)
- [ ] `tests/test_report_jobs_argv.sh` GROUP G — race window omits `--agentic-job-id` (JROLL-02)
- [ ] `tests/test_report_jobs_argv.sh` GROUP H — subagent own job markers suppressed (JROLL-03)
- [ ] Inline `sessions_spawn` fixtures within GROUP F/G/H (written as heredoc strings)
- [ ] Root markers dir and marker files within GROUP F/G/H `make_openclaw_home` extension

---

## Runtime State Inventory

Not applicable — Phase 7 is not a rename/refactor/migration phase.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| python3 | `root_aid` resolve heredoc, test assertions | Present | System python3 | get_root_session_id fail-opens to input sid; tests require python3 |
| bash | report.sh, test scripts | Present | zsh/bash | — |
| revenium CLI | metering (stubbed in tests) | Stubbed via stub-revenium.sh | — | stub covers all test cases |

**Missing dependencies with no fallback:** None.

---

## Security Domain

> `security_enforcement` not explicitly false in config — section required.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V5 Input Validation | YES | Sanitize `root_aid` values (`:`/`|`/newline → `_`) before CLI injection; same pattern as Phase 5/6 |
| V2 Authentication | No | No auth logic in this phase |
| V3 Session Management | No | Session id handling is read-only file path lookup |
| V4 Access Control | No | No privilege escalation; markers dir already 0700 |
| V6 Cryptography | No | No crypto operations |

### Known Threat Patterns for Bash + Python Heredoc

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Shell injection via `root_sid` in heredoc | Tampering | `ROOT_SID="${root_sid}" python3 - <<'PY'` — single-quoted delimiter prevents expansion; value arrives as env var, never interpolated |
| CLI injection via unsanitized `root_aid` | Tampering | Sanitize `:`/`|`/newline → `_` in the Python reader before printing; bash array discipline `cmd+=(--agentic-job-id "${root_aid}")` |
| Path traversal via `root_sid` containing `..` | Tampering | Python `Path(markers_dir) / f"{root_sid}.jsonl"` — restrict to `markers_dir`; `root_sid` is a UUID from `get-root-session-id.py` which strips the `agent:main:subagent:` prefix to a UUID suffix |
| Overly long values causing log injection | Tampering | Apply the existing 64-char truncation pattern (`${root_aid:0:64}`) for log lines only; the actual arg passed to CLI is the full sanitized value |

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Static `--agent OpenClaw` | `--agent openclaw-{root_sid}` dynamic | Phase 4 v1.0 | Subagent spend already rolls up via `--agent`; Phase 7 adds explicit job attribution on top |
| No job tracking | Per-session `jobs create`/stamp/`outcome` | Phase 6 | Single-session baseline; Phase 7 extends to multi-session |
| No subagent job override | Root's `agentic_job_id` inherited by subagents | Phase 7 | One job spans whole agent tree |

**Deprecated/outdated:**
- Phase 7 makes `jobs_cache_file` unused for subagent sessions (the override replaces
  its result). The code still populates it (unchanged Phase 6 path), but for subagent
  sessions the values are discarded. This is intentional — it avoids adding an
  `if is_subagent` branch to the already-complex Python marker parser.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Hermes `root_aid` heredoc (lines 204-254) emits job_name and job_type on the same print statement as job_id | Code Examples / Pattern 1 | If Hermes only emits the id, the name/type threading must be added explicitly — low risk, already confirmed by reading hermes-report.sh |

**All other claims in this research were verified by directly reading the source files.**
The table is nearly empty because the CONTEXT.md decisions were already locked and the
code was fully readable.

---

## Open Questions

1. **`make_openclaw_home` helper in `test_report_jobs_argv.sh` does not create a `markers/`
   subdirectory under `sessions/`.**
   - What we know: the helper creates `${d}/agents/main/sessions` and
     `${d}/skills/revenium/markers`. The root markers file goes into
     `skills/revenium/markers/`, which IS created. The sessions_spawn JSONL goes into
     `agents/main/sessions/`, which IS also created.
   - What's unclear: whether GROUP F/G/H can reuse `make_openclaw_home` as-is or needs
     an additional `mkdir -p "${d}/skills/revenium/markers"` for the root markers file.
   - **Recommendation:** Confirm `make_openclaw_home` already creates the markers dir
     (it does — line 51: `"${d}/skills/revenium/markers"`). No change needed.

2. **Should the root markers read (`root_aid` resolve) be folded into the existing
   per-session markers-cache Python block, or remain a separate heredoc?**
   - What we know: Hermes uses a separate heredoc. The existing `_MARKER_FILE`/`_TASKS_CACHE`/
     `_JOBS_CACHE` heredoc already reads the SAME session's markers. The root read is
     inherently different (cross-session, different file path, once per session vs. once
     per session+already-done).
   - **Recommendation:** Keep separate (Hermes pattern). Folding would require passing
     a second marker path into the same heredoc, adding conditional logic, and risking
     regression of the existing task/job split. Claude's Discretion per CONTEXT.md.

---

## Sources

### Primary (HIGH confidence)

- `scripts/report.sh` — read directly; all line numbers verified [VERIFIED: read report.sh]
- `scripts/get-root-session-id.py` — read directly; resolver logic confirmed [VERIFIED: read get-root-session-id.py]
- `scripts/common.sh` — read directly; `MARKERS_DIR` path confirmed [VERIFIED: read common.sh]
- `tests/stub-revenium.sh` — read directly; env switches confirmed [VERIFIED: read stub-revenium.sh]
- `tests/test_report_jobs_argv.sh` — read directly; GROUP A-E structure confirmed [VERIFIED: read test_report_jobs_argv.sh]
- `tests/test_report_argv.sh` — read directly; no-agentic-job assertion at line 295 confirmed [VERIFIED: read test_report_argv.sh]
- `tests/test_get_root_session_id.py` — read directly; test coverage for resolver confirmed [VERIFIED: read test_get_root_session_id.py]
- `tests/fixtures/sessions/a1b2c3d4-*.jsonl` — read directly; sessions_spawn JSONL format confirmed [VERIFIED: read fixture]
- `.planning/phases/07-root-session-job-rollup/07-CONTEXT.md` — read directly; all decisions confirmed [VERIFIED]
- `.planning/phases/06-job-lifecycle-wiring/06-CONTEXT.md` — read directly; Phase 6 baseline confirmed [VERIFIED]
- `.planning/phases/05-job-declaration-foundation/05-CONTEXT.md` — read directly; marker schema confirmed [VERIFIED]
- `.planning/REQUIREMENTS.md` §JROLL — read directly; requirement text confirmed [VERIFIED]
- `../hermes-revenium/skills/revenium/scripts/hermes-report.sh` — read lines 195-254, 340-347, 853-863 directly; root_aid block and root-only gates confirmed [VERIFIED: read hermes-report.sh]

### Secondary (MEDIUM confidence)

None — all claims derive from direct file reads.

### Tertiary (LOW confidence)

None.

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — no new dependencies; existing code verified line-by-line
- Architecture: HIGH — Hermes port is direct and line-number-confirmed; discriminator already live in report.sh
- Pitfalls: HIGH — derived from code reading and Hermes port experience, not training knowledge
- Validation architecture: HIGH — existing test infrastructure (stub-revenium, test_report_jobs_argv.sh pattern) directly extended

**Research date:** 2026-06-03
**Valid until:** 2026-07-03 (stable codebase; no external dependencies)
