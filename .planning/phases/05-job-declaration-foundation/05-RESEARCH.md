# Phase 5: Job Declaration Foundation - Research

**Researched:** 2026-06-03
**Domain:** Shell/Python marker writer, JSONL taxonomy install, SKILL.md directive authoring
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Job declaration is arc-boundary triggered (Hermes model). A job = a goal-arc. The agent declares it when the arc concludes: completed-and-self-verified, definitively failed, or abandoned/cancelled. This is a *primary* agent action (no classifier plugin).
- **D-02:** Status bar ported verbatim from Hermes (`references/job-declaration.md`): `SUCCESS` requires positive, self-verified evidence. `FAILED` is a narrow definitive-negative terminal state. `CANCELLED` is the catch-all and the uncertainty-bias default.
- **D-03:** Pivot-cancel rule included: when the user pivots before the current arc was declared, the agent writes a `CANCELLED` job marker for the abandoned arc first.
- **D-04:** Granularity floor is a SOFT guideline only (no session-end hook; sessions with no clear arc completion may legitimately produce zero jobs).
- **D-05:** JOB DECLARATION directive sits within the guard-first SKILL.md ordering, modeled structurally on the existing `TASK CLASSIFICATION` section.
- **D-06:** New dedicated `scripts/write-job-marker.sh` — does NOT extend `write-marker.sh`. Reuses `common.sh` idioms.
- **D-07:** Named flags: `--job-id`, `--job-name`, `--job-type`, `--status`, `--failure-reason` (optional).
- **D-08:** `agentic_job_id` format = kebab-slug + 4-hex (e.g. `add-pagination-endpoint-3b1e`). The agent mints the full ID.
- **D-09:** Writer sanitizes every field: `:`, `|`, newline → `_`, plus a defensive length cap. Sanitization is the load-bearing defense for Phase 6 CLI arg injection.
- **D-10:** `ts` is ISO8601 string (`time.strftime('%Y-%m-%dT%H:%M:%SZ')`), matching the existing task-marker convention.
- **D-11:** Discriminator = `kind:"job"`; absence-of-`kind` means task. Existing task markers and `write-marker.sh` are left untouched.
- **D-12:** Mandatory fields (7): `kind`, `ts`, `sid`, `agentic_job_id`, `job_name`, `job_type`, `status`. `sid` is carried IN the record.
- **D-13:** `failure_reason` is the 8th, optional field — FAILED-only (omitted for SUCCESS/CANCELLED).
- **D-14:** Writer rejects: unknown `job_type`, missing mandatory field, invalid `status` value. Reject = no marker written, non-zero exit, logged.

### Claude's Discretion

- Exact `JOB_TAXONOMY_FILE` constant value in `common.sh` (parallel to `TAXONOMY_FILE`).
- The precise snake_case validation regex and where it lives (resolved below — no regex is enforced today).
- Length-cap value for sanitized fields and exact log/error wording.
- Exact placement/anchoring of the JOB DECLARATION section within SKILL.md.

### Deferred Ideas (OUT OF SCOPE)

- Per-job-type budget rules / guardrails (JGUARD-01)
- Classifier-plugin job inference (JCLASS-01)
- Business-outcome reporting beyond execution result (JOUT-01)
- Hard session-end enforcement of the one-job-per-session floor

</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| JOBDEC-01 | `job-taxonomy.json` with 11 labels, validated against snake_case regex, installed to skill runtime location alongside `task-taxonomy.json` | Install mechanism confirmed (post-install.sh seeding pattern); snake_case enforcement gap identified and resolved below |
| JOBDEC-02 | SKILL.md `JOB DECLARATION` directive instructing the agent to append a `kind:"job"` marker when a unit of work concludes | Structural model (TASK CLASSIFICATION section lines 63–115) fully documented; Hermes job-declaration.md content extracted for porting |
| JOBDEC-03 | Marker writer accepts/validates job markers via flock-protected atomic append; rejects unknown `job_type` and malformed records | write-marker.sh idiom fully extracted; exact Python heredoc pattern confirmed; no new infrastructure needed |
| JOBDEC-04 | Stable, unique `agentic_job_id` (business label + entropy suffix) sanitized before any value reaches a CLI argument | No existing sanitization helper confirmed; must be added inline in write-job-marker.sh Python block |

</phase_requirements>

---

## Summary

Phase 5 extends the proven v1.0 task-marker machinery by adding a parallel `write-job-marker.sh` writer, a `job-taxonomy.json` taxonomy file (11 labels ported from the sibling Hermes repo), a `JOB_TAXONOMY_FILE` constant in `common.sh`, and a `JOB DECLARATION` directive in `SKILL.md`. Every structural pattern needed already exists in the repo: the env-passing Python heredoc, flock-protected O_APPEND, allowlist-only taxonomy validation, sid resolution, markers dir mode 0700, and the fail-loud-but-don't-block exit contract. The new writer differs from `write-marker.sh` in four ways: named flags instead of a positional arg, 7 mandatory fields + optional `failure_reason`, `kind:"job"` + `sid` in the record, and field sanitization (`:`, `|`, newline → `_` + length cap). The taxonomy install mechanism is `post-install.sh` seeding (the file lives at `${STATE_DIR}/job-taxonomy.json` — SKILL_DIR == STATE_DIR in OpenClaw's collapsed model); adding a sibling `JOB_TAXONOMY_FILE` constant to `common.sh` and adding one seeding block to `post-install.sh` for `job-taxonomy.json` is the complete install mechanism. No existing sanitization helper exists; it must be added as an inline Python function inside the write-job-marker.sh heredoc. All five open questions raised in the brief are fully resolved against live code.

**Primary recommendation:** Copy `write-marker.sh` as a structural skeleton for `write-job-marker.sh`, adapt the arg-parsing block to named flags with `sys.argv` parsing, add the sanitizer function, add the 7-field mandatory check and status/job_type allowlist gates, write the record with `kind:"job"` + in-record `sid`, and add a single seeding block to `post-install.sh` for `job-taxonomy.json`. Do not touch `write-marker.sh`.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Job marker schema definition | Shell/Python script (write-job-marker.sh) | SKILL.md directive | The writer owns the record shape; the directive references the writer |
| Taxonomy storage and validation | Filesystem (job-taxonomy.json) | Python allowlist check in writer | Static JSON loaded at write time, same as task-taxonomy.json |
| Field sanitization / injection defense | Python inline in write-job-marker.sh | — | Load-bearing for Phase 6 CLI args; must live in the writer |
| SKILL.md directive (agent instructions) | SKILL.md file | references/job-declaration.md | Agent reads directive; examples live in the references doc |
| Taxonomy install | post-install.sh | common.sh constant | post-install.sh seeds the file; common.sh provides the path |
| Marker storage | markers/{sid}.jsonl | — | Same JSONL files as task markers; Phase 6 reads both, splits on `kind` |
| Sid resolution | Python in write-job-marker.sh (ported from write-marker.sh) | common.sh SESSIONS_DIR | Reuses the same logic verbatim |

---

## Standard Stack

### Core (all pre-existing, no new dependencies)

| Component | Version/Source | Purpose | Why Standard |
|-----------|---------------|---------|--------------|
| `python3` (stdlib: `json`, `os`, `time`, `fcntl`, `re`, `sys`) | System Python 3 | Marker write logic inside env-passing heredoc | Established pattern in write-marker.sh; fcntl.flock requires Python (no pure-bash flock on macOS) |
| `bash` (POSIX + arrays) | System bash | Script shell, arg parsing | Established in all skill scripts |
| `common.sh` | This repo | Path constants, log helpers, sid resolution (via SESSIONS_DIR) | Single source of truth for MARKERS_DIR, STATE_DIR, SESSIONS_DIR |

### No New External Packages

This phase installs zero new third-party packages. All dependencies are system Python stdlib or existing shell utilities already present in the skill.

---

## Package Legitimacy Audit

> Not applicable — this phase installs no external packages (stdlib only).

---

## Architecture Patterns

### System Architecture Diagram

```
Agent turn completes a goal arc
         |
         v
SKILL.md JOB DECLARATION directive
  → Step 1: pick job_type from 11-label taxonomy
  → Step 2: mint agentic_job_id (kebab-slug + 4-hex)
  → Step 3: call write-job-marker.sh --job-id ... --job-name ... --job-type ...
              --status SUCCESS|FAILED|CANCELLED [--failure-reason ...]
         |
         v
write-job-marker.sh
  ├── source common.sh  (MARKERS_DIR, JOB_TAXONOMY_FILE, SESSIONS_DIR)
  ├── parse named flags (--job-id, --job-name, --job-type, --status, --failure-reason)
  ├── pass all values to Python via env (never interpolate into heredoc)
  │
  └── Python heredoc block:
        ├── read env vars
        ├── sanitize(value): re.sub('[:|\\n]', '_', v)[:256]
        ├── validate job_type in taxonomy allowlist  → SystemExit(1) if unknown
        ├── validate status in {SUCCESS, FAILED, CANCELLED}  → SystemExit(1) if invalid
        ├── validate all 7 mandatory fields present  → SystemExit(1) if any absent
        ├── resolve sid (newest non-cron session, same logic as write-marker.sh)
        ├── path-traversal guard on sid
        ├── os.makedirs(markers_dir, mode=0o700, exist_ok=True)
        ├── build record: {kind, ts(ISO8601), sid, agentic_job_id, job_name,
        │                  job_type, status, [failure_reason if FAILED]}
        └── flock(LOCK_EX) + O_APPEND write to markers/{sid}.jsonl
              → print "job marker written: <path>" to stdout
              → exit 0

Phase 6 report.sh reads markers/{sid}.jsonl
  → lines with kind=="job" → job lifecycle processing
  → lines without kind        → task markers (existing behavior, untouched)
```

### Recommended Project Structure (additions only)

```
openclaw-revenium/
├── job-taxonomy.json            # NEW — 11-label job vocabulary (source of truth)
├── scripts/
│   ├── common.sh                # MODIFIED — add JOB_TAXONOMY_FILE constant
│   ├── write-job-marker.sh      # NEW — job marker writer
│   └── post-install.sh          # MODIFIED — add seeding block for job-taxonomy.json
├── tests/
│   └── test_write_job_marker.sh # NEW — integration tests (mirrors test_write_marker.sh)
└── SKILL.md                     # MODIFIED — add JOB DECLARATION directive section
```

### Pattern 1: Env-Passing Python Heredoc (existing, reuse verbatim)

**What:** All user-controlled values are passed to the Python block via environment variables. Values are never interpolated into the heredoc body. This prevents shell injection if a value contains backticks, `$`, or other shell metacharacters.

**When to use:** Every time a bash script runs Python with user-supplied inputs.

```bash
# Source: write-marker.sh lines 40-45 [VERIFIED: live file read]
TASK_TYPE="${TASK_TYPE_ARG}" \
TAXONOMY_FILE="${TAXONOMY_FILE}" \
MARKERS_DIR="${MARKERS_DIR}" \
SESSIONS_DIR="${SESSIONS_DIR}" \
OPENCLAW_HOME="${OPENCLAW_HOME}" \
python3 - <<'PY'
import json, os, time, fcntl, re, sys
tt = os.environ['TASK_TYPE']
# ... all values come from os.environ, never from string interpolation
PY
```

For write-job-marker.sh, pass each named-flag value as its own env var:
`JOB_ID`, `JOB_NAME`, `JOB_TYPE`, `STATUS`, `FAILURE_REASON` (empty string when absent).

### Pattern 2: fcntl.LOCK_EX + O_APPEND Atomic Append (existing, reuse verbatim)

**What:** Opens the marker JSONL in append-binary mode with `buffering=0`, acquires an exclusive flock before writing. O_APPEND is atomic at the OS level; flock prevents interleaving from concurrent invocations.

**When to use:** Every append to the markers JSONL.

```python
# Source: write-marker.sh lines 194-196 [VERIFIED: live file read]
with open(marker_path, 'ab', buffering=0) as fh:
    fcntl.flock(fh, fcntl.LOCK_EX)
    fh.write((json.dumps(rec, separators=(',', ':')) + '\n').encode('utf-8'))
```

### Pattern 3: Field Sanitization (NEW — must be added to write-job-marker.sh)

**What:** A compact inline sanitizer strips the three characters that could corrupt the JSONL record or inject shell arguments in Phase 6: `:` (used as CLI arg delimiter in some revenium flags), `|` (used as field separator in some Hermes scripts), and newlines (would break the JSONL line boundary). A length cap defends against memory-exhaustion and log-injection.

**Why write-job-marker.sh must own this:** Values flow directly into the marker record and, in Phase 6, will be passed as `--agentic-job-id`, `--name`, and `--type` CLI arguments. The writer is the only choke point that sees all values before they land in the file.

```python
# NEW — to be added inline in the write-job-marker.sh heredoc
import re

def sanitize(value, maxlen=256):
    """Replace :, |, newline with _ and cap length. [ASSUMED: maxlen=256 is reasonable]"""
    return re.sub(r'[:\|\n\r]', '_', str(value))[:maxlen]

# Apply to every field before building the record:
job_id   = sanitize(os.environ['JOB_ID'])
job_name = sanitize(os.environ['JOB_NAME'])
job_type = sanitize(os.environ['JOB_TYPE'])  # also validated against allowlist below
status   = sanitize(os.environ['STATUS'])    # also validated against allowlist below
failure_reason = sanitize(os.environ.get('FAILURE_REASON', ''))
```

### Pattern 4: Named-Flag Arg Parsing in Bash Wrapper

**What:** The bash wrapper parses `--job-id`, `--job-name`, `--job-type`, `--status`, `--failure-reason` from `$@` before handing to Python. Each value is assigned to a local bash variable and then exported to Python via the env-passing block.

```bash
# NEW — bash arg parsing skeleton for write-job-marker.sh
JOB_ID_ARG=""
JOB_NAME_ARG=""
JOB_TYPE_ARG=""
STATUS_ARG=""
FAILURE_REASON_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --job-id)       JOB_ID_ARG="$2";       shift 2 ;;
    --job-name)     JOB_NAME_ARG="$2";     shift 2 ;;
    --job-type)     JOB_TYPE_ARG="$2";     shift 2 ;;
    --status)       STATUS_ARG="$2";       shift 2 ;;
    --failure-reason) FAILURE_REASON_ARG="$2"; shift 2 ;;
    *) warn "write-job-marker.sh: unknown argument: $1"; exit 1 ;;
  esac
done

# Mandatory-flag presence check in bash (before Python):
if [[ -z "${JOB_ID_ARG}" || -z "${JOB_NAME_ARG}" || -z "${JOB_TYPE_ARG}" || -z "${STATUS_ARG}" ]]; then
  warn "write-job-marker.sh: missing required flag(s)"
  exit 1
fi
```

### Pattern 5: Taxonomy Seeding in post-install.sh (existing pattern, extend)

**What:** `post-install.sh` contains a seeding block for `task-taxonomy.json` that copies the repo-root file to `${SKILL_DIR}/task-taxonomy.json` if absent. In OpenClaw's collapsed model, `SKILL_DIR == STATE_DIR == ~/.openclaw/skills/revenium/`, so `TAXONOMY_FILE="${STATE_DIR}/task-taxonomy.json"` already points to the right place and no separate deployment step is needed.

`job-taxonomy.json` must follow the identical pattern — a seeding block directly after the existing task-taxonomy.json block.

```bash
# Source: post-install.sh lines 121-136 [VERIFIED: live file read] — EXISTING BLOCK:
TAXONOMY_SRC="${SKILL_DIR}/task-taxonomy.json"
TAXONOMY_DST="${SKILL_DIR}/task-taxonomy.json"  # same path (self-contained install)
if [[ ! -f "${TAXONOMY_DST}" ]]; then
  if [[ -f "${TAXONOMY_SRC}" ]]; then
    cp "${TAXONOMY_SRC}" "${TAXONOMY_DST}"
    info "Seeded task-taxonomy.json at ${TAXONOMY_DST}"
  else
    warn "task-taxonomy.json not found at ${TAXONOMY_SRC} — write-marker.sh will fail until it is present"
  fi
else
  info "task-taxonomy.json already present at ${TAXONOMY_DST}"
fi

# NEW BLOCK to add immediately after (same structure):
JOB_TAXONOMY_SRC="${SKILL_DIR}/job-taxonomy.json"
JOB_TAXONOMY_DST="${SKILL_DIR}/job-taxonomy.json"
if [[ ! -f "${JOB_TAXONOMY_DST}" ]]; then
  if [[ -f "${JOB_TAXONOMY_SRC}" ]]; then
    cp "${JOB_TAXONOMY_SRC}" "${JOB_TAXONOMY_DST}"
    info "Seeded job-taxonomy.json at ${JOB_TAXONOMY_DST}"
  else
    warn "job-taxonomy.json not found at ${JOB_TAXONOMY_SRC} — write-job-marker.sh will fail until it is present"
  fi
else
  info "job-taxonomy.json already present at ${JOB_TAXONOMY_DST}"
fi
```

### Anti-Patterns to Avoid

- **Interpolating user values into heredoc body:** Never write `python3 - <<PY\njob_id = "${JOB_ID_ARG}"\nPY`. Always pass via env + `os.environ[...]`. [VERIFIED: write-marker.sh pattern]
- **Extending write-marker.sh:** Locked as D-06. Extending it would add branching complexity to the proven v1.0 path and create regression risk.
- **Adding `kind:"task"` to existing task markers:** Locked as D-11. Absence of `kind` is the task discriminator; retrofitting existing writer breaks the zero-regression contract.
- **Hermes unix_float timestamp:** Hermes uses `time.time()` (unix float). OpenClaw uses `time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())` (ISO8601). Do not import the Hermes timestamp convention.
- **Putting sid resolution logic in common.sh:** The sid-resolution Python code lives inside the write-marker.sh heredoc (not in common.sh). The new writer must duplicate/inline the same Python logic — there is no shared Python library to import.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Flock-protected atomic append to JSONL | Custom lock file or rename dance | `fcntl.flock(LOCK_EX)` + `O_APPEND` (Pattern 2 above) | OS-level atomicity; pattern proven in write-marker.sh |
| Taxonomy loading and allowlist check | Custom parser or regex on the JSON | `json.load(tax_file)` + `if tt not in labels` | Already in write-marker.sh lines 56-64; copy verbatim |
| Sid resolution (newest non-cron session) | Reinvent the selection logic | Copy the ~60-line Python block from write-marker.sh lines 66-169 verbatim | Handles sessions.json cron exclusion, completion-ts selection, mtime fallback, pseudo-sid |
| markers/ directory creation | `mkdir` + `chmod` in bash | `os.makedirs(markers_dir, mode=0o700, exist_ok=True)` (Pattern 2) | Atomic on Linux/macOS; idempotent |

**Key insight:** Everything in write-job-marker.sh is an extension of an existing proven pattern. The planner should copy write-marker.sh as the skeleton and make targeted additions/modifications rather than writing from scratch.

---

## Open Questions Resolved

### OQ-1: Taxonomy Install Mechanism [VERIFIED: live file read]

**Answer:** `post-install.sh` is the sole install mechanism. It contains a seeding block (lines 121–136) that checks whether `task-taxonomy.json` exists at `${SKILL_DIR}/task-taxonomy.json` and copies it from the repo root if absent. In OpenClaw's collapsed model, `SKILL_DIR == STATE_DIR == ~/.openclaw/skills/revenium/`, so the file ends up at `~/.openclaw/skills/revenium/task-taxonomy.json` — identical to `TAXONOMY_FILE` from common.sh.

**What the planner must do:**
1. Add `job-taxonomy.json` to the repo root (same level as `task-taxonomy.json`).
2. Add `JOB_TAXONOMY_FILE="${STATE_DIR}/job-taxonomy.json"` to `common.sh` immediately after the `TAXONOMY_FILE` constant.
3. Add a sibling seeding block to `post-install.sh` immediately after the existing task-taxonomy.json block (Pattern 5 above).
4. Add `write-job-marker.sh` to the `for script in ...` chmod loop in `post-install.sh` (line 114).

There is no Makefile, no separate install script, and no ClawHub manifest step — post-install.sh is the complete deployment pipeline.

### OQ-2: Snake_case Regex Enforcement [VERIFIED: live file read]

**Answer:** No regex is enforced anywhere today. `write-marker.sh` performs only an allowlist-membership check (`if tt not in labels: raise SystemExit(...)`). There is no `re.fullmatch(r'^[a-z][a-z0-9_]*$', label)` call in write-marker.sh, setup-guardrails.sh, or any test. The phrase "same snake_case regex as task-taxonomy.json" in JOBDEC-01 describes an intent, not an existing enforcement.

**What the planner must add:**
- The `job-taxonomy.json` file content itself must use valid snake_case keys (it does — the Hermes source already uses snake_case for all 11 labels).
- JOBDEC-01 says to validate against "the same snake_case regex" — since no regex exists today, the planner must decide either (a) add a snake_case regex check to the job-taxonomy.json loader in write-job-marker.sh (validates keys on load), or (b) treat the allowlist-only check as sufficient. This is a discretion area left to the planner. The minimal-risk approach is an allowlist-only check consistent with write-marker.sh; adding a load-time regex is a defence-in-depth option.

### OQ-3: Markers Directory / JSONL Layout [VERIFIED: live file read]

**Answer:** Confirmed from `common.sh` and `write-marker.sh`:
- `MARKERS_DIR="${STATE_DIR}/markers"` — both kinds of markers share this directory.
- `marker_path = os.path.join(markers_dir, f"{sid}.jsonl")` — filename is `{sid}.jsonl`.
- Task markers currently have schema `{"ts":"…","task_type":"…","completion_id":"…"}` with no `kind` field.
- Job markers will have `{"kind":"job","ts":"…","sid":"…","agentic_job_id":"…","job_name":"…","job_type":"…","status":"…"}` plus optional `"failure_reason":"…"`.

**Phase 6 discrimination:** `kind == "job"` identifies job markers; absence of `kind` (or `kind` not present) identifies task markers. This is a clean discriminator. Phase 6 `report.sh` will branch on this field. The schema choice does not break Phase 6: the JSONL format is newline-delimited JSON, so existing task-marker readers that do `json.loads(line)` and check `rec.get('task_type')` will simply ignore the new `kind` field they don't know about.

### OQ-4: Sid Resolution + In-Record Sid [VERIFIED: live file read]

**Answer:** `write-marker.sh` resolves `sid` entirely within the Python heredoc (lines 66–169). The resolution logic:
1. Load `sessions.json` to get `cron_sids` (key prefix `agent:main:cron:`).
2. List all `*.jsonl` in `SESSIONS_DIR`, filter out cron sids.
3. Among non-cron files, prefer the one with the most recent `assistant` completion (by `timestamp` field in the JSONL). Fall back to mtime. Fall back to `pseudo-{int(time.time())}` if no non-cron files exist.
4. Extract `completion_id` (.id of the most recent assistant record) as a side-product of step 3.

The resolved `sid` becomes both the filename (`markers/{sid}.jsonl`) and, for job markers, an in-record field. The task marker does NOT write `sid` into the record — only into the filename. The new job writer needs to resolve `sid` using the exact same logic and also write it as a field in the record per D-12.

The Python block for sid resolution is self-contained and has no shared-library imports — it must be duplicated/inlined into write-job-marker.sh's heredoc verbatim (minus the `completion_id` extraction, which is optional for job markers and can be included or omitted at the planner's discretion).

### OQ-5: Sanitization Helper [VERIFIED: live file read]

**Answer:** There is no existing sanitization helper anywhere in the codebase. `write-marker.sh` does not sanitize the `task_type` value — it relies on the allowlist check to reject unknown values, and known taxonomy labels are already safe strings. `report.sh` and `setup-guardrails.sh` have `.strip()` calls for whitespace but no `:`, `|`, or newline replacement.

**What the planner must add:** An inline `sanitize()` function in the write-job-marker.sh Python heredoc (Pattern 3 above). It must be applied to all 5 variable fields: `job_id`, `job_name`, `job_type`, `failure_reason`, and — for belt-and-suspenders defense — `status` (before allowlist check). The `sid` field is derived internally (not user-supplied) and already has the path-traversal guard.

---

## Job Taxonomy: Complete 11-Label Specification

Source: `../hermes-revenium/skills/revenium/job-taxonomy.json` [VERIFIED: live file read]

The following is the exact content to ship as `job-taxonomy.json`:

```json
{
  "labels": {
    "feature_development": {
      "description": "Implementing a new capability, endpoint, component, or user-facing behavior from scratch",
      "examples": [
        "add a pagination feature to the search results",
        "implement the new user profile settings page"
      ]
    },
    "bug_fix": {
      "description": "Diagnosing and correcting a specific defect or regression in existing behavior",
      "examples": [
        "fix the null pointer exception in the payment flow",
        "resolve the race condition causing duplicate submissions"
      ]
    },
    "code_review": {
      "description": "Reviewing a diff, PR, or code block for correctness, style, security, or architectural fit",
      "examples": [
        "review this pull request for the authentication module",
        "check this diff for potential security issues"
      ]
    },
    "refactoring": {
      "description": "Restructuring existing code to improve clarity, reduce duplication, or improve maintainability without changing behavior",
      "examples": [
        "extract the validation logic into a shared helper module",
        "rename and reorganize the payment service classes"
      ]
    },
    "research": {
      "description": "Investigating a technology, approach, library, or unfamiliar codebase before making implementation decisions",
      "examples": [
        "evaluate which rate-limiting library fits our stack best",
        "understand how the upstream API handles pagination"
      ]
    },
    "debugging": {
      "description": "Reproducing, isolating, and diagnosing the root cause of an unexpected failure or error",
      "examples": [
        "trace why the integration test fails only in CI",
        "reproduce and identify the cause of the 500 error on login"
      ]
    },
    "testing": {
      "description": "Writing, expanding, or fixing a test suite — unit, integration, end-to-end, or performance tests",
      "examples": [
        "add unit tests for the billing calculation module",
        "write integration tests for the webhook delivery pipeline"
      ]
    },
    "documentation": {
      "description": "Writing or updating developer documentation, runbooks, API references, or inline code comments",
      "examples": [
        "document the deployment runbook for the new service",
        "update the API reference with the new endpoint signatures"
      ]
    },
    "devops": {
      "description": "Work on infrastructure, CI/CD, deployment configuration, monitoring, or operational tooling",
      "examples": [
        "add a GitHub Actions workflow for automated release tagging",
        "configure the Kubernetes liveness probe for the new service"
      ]
    },
    "planning": {
      "description": "Producing a plan, design document, task breakdown, or architectural decision record before implementation",
      "examples": [
        "design the database schema for the new reporting feature",
        "break the migration project into phased implementation tasks"
      ]
    },
    "interrupted": {
      "description": "Terminal job type for an arc that was cut short by a budget halt or an explicit user cancellation before completion",
      "examples": [
        "session halted by budget enforcement while implementing feature",
        "user pivoted before the refactoring arc was completed"
      ]
    }
  }
}
```

**Note:** `refactoring` (with -ing) is the Hermes label; `task-taxonomy.json` uses `refactor`. These are different objects for different purposes (job-level vs turn-level) and both are correct.

---

## Hermes Job-Declaration Content to Port

Source: `../hermes-revenium/skills/revenium/references/job-declaration.md` [VERIFIED: live file read]

The following content must be ported into `references/job-declaration.md` (new file) and/or inline into the SKILL.md `JOB DECLARATION` directive, adapted to OpenClaw's writer command syntax.

### Arc Definition (goal-continuity rule)
- **Same arc:** same goal including follow-up fixes and corrections. Do not declare a job for "implement X" if verification is still pending.
- **New arc:** genuine topic pivot, a new unrelated request.
- **Pivot-cancel rule:** on a genuine pivot before the current arc was declared, first write a `CANCELLED` job marker for the abandoned arc, then treat the new request as a fresh arc.

### Trigger (binary — no judgment calls)
Declare a job marker if ANY:
- Completed the goal and self-verified (see SUCCESS bar).
- The arc has definitively failed.
- The user has pivoted to a new goal before this arc was declared → write CANCELLED first.

Skip ONLY when ALL: response ≤ 2 sentences AND no arc was in progress.

### Status Bar
- **`SUCCESS`:** positive, checkable evidence established in the session (tests passed, build green, question fully answered). "Made the change but could not verify" = CANCELLED, not SUCCESS.
- **`FAILED`:** definitive negative terminal state (the fix didn't fix, build cannot pass, goal objectively unachievable). Include `failure_reason` (brief plain-text cause).
- **`CANCELLED`:** catch-all and uncertainty-bias default. When in doubt: CANCELLED.

### Worked Examples (adapted to OpenClaw CLI)

**Example 1 — SUCCESS (tests ran and passed):**
```
bash ~/.openclaw/skills/revenium/scripts/write-job-marker.sh \
  --job-id "add-pagination-endpoint-3b1e" \
  --job-name "Add pagination to /api/users endpoint" \
  --job-type "feature_development" \
  --status "SUCCESS"
```

**Example 2 — CANCELLED (change made, not verified):**
```
bash ~/.openclaw/skills/revenium/scripts/write-job-marker.sh \
  --job-id "fix-null-pointer-2c4d" \
  --job-name "Fix null pointer in payment flow" \
  --job-type "bug_fix" \
  --status "CANCELLED"
```
(Reason: you made the fix but did not run the tests.)

**Example 3 — FAILED (definitive negative terminal state):**
```
bash ~/.openclaw/skills/revenium/scripts/write-job-marker.sh \
  --job-id "fix-ci-upstream-blocker-9f2a" \
  --job-name "Fix CI pipeline upstream blocker" \
  --job-type "debugging" \
  --status "FAILED" \
  --failure-reason "upstream library bug blocks CI; no workaround after 3 attempts"
```

**Example 4 — Pivot-cancel (CANCELLED for abandoned arc, then new arc begins):**
```
# First: close the abandoned refactor arc
bash ~/.openclaw/skills/revenium/scripts/write-job-marker.sh \
  --job-id "refactor-auth-7a3b" \
  --job-name "Refactor auth module" \
  --job-type "refactoring" \
  --status "CANCELLED"
# Then: begin new arc (release announcement)
```

---

## Hermes Marker Shape: Divergences from OpenClaw

| Field | Hermes Shape | OpenClaw Phase 5 Shape | Reason |
|-------|-------------|----------------------|--------|
| `ts` | `time.time()` (unix float, e.g. `1748975231.234`) | `time.strftime('%Y-%m-%dT%H:%M:%SZ')` (ISO8601) | One timestamp convention across all marker kinds; Phase 6 ordering/correlation stays uniform |
| Declaration model | Backstop only (classifier plugin is primary) | Primary agent action (no plugin) | OpenClaw has no confirmed session-end hook |
| Writer | No dedicated writer; markers written inline in plugin/pre_tool_call.sh | `write-job-marker.sh` (dedicated, named flags) | Consistent with v1.0 write-marker.sh architecture |

---

## SKILL.md Directive: Structural Model

The new `JOB DECLARATION` section must be inserted after `TASK CLASSIFICATION` (line 115) and before `Path Resolution` (line 116). The SKILL.md guard-first ordering is:

```
## ABSOLUTE FIRST — HALT CHECK (lines 7-30)
## Guardrail Check Procedure (lines 34-61)
## TASK CLASSIFICATION (lines 63-115)    ← existing mandatory action
## JOB DECLARATION                       ← NEW mandatory action (insert here)
## Path Resolution (line 116)
## Setup (line 120)
## /revenium Command (line 185)
```

Structure (mirrors TASK CLASSIFICATION exactly):
- Section header with **MANDATORY** framing, arc-boundary trigger (not per-turn)
- Trigger subsection (binary, no judgment calls)
- Required action subsection (Step 1: pick job_type; Step 2: mint agentic_job_id; Step 3: call writer)
- Job type label table (11 labels from job-taxonomy.json)
- Status bar (SUCCESS/FAILED/CANCELLED criteria, from job-declaration.md)
- Failure reason guidance (FAILED-only)
- Confirmation/error handling (mirrors write-marker.sh pattern)
- "Why this matters" subsection
- Reference to `references/job-declaration.md` for full worked examples

---

## Common Pitfalls

### Pitfall 1: Sid Duplication Without Completion_id in Job Markers
**What goes wrong:** If the job writer reuses the sid resolution code but omits the `completion_id` extraction, Phase 6 will still work (job markers don't need completion_id for job lifecycle — they correlate by `agentic_job_id`). However, if the sid resolution logic is incorrectly modified (e.g., forgetting to exclude cron sessions), job markers may land in the wrong JSONL file and be silently lost.
**Why it happens:** The sid resolution is complex (~60 lines) and easy to accidentally truncate when copying.
**How to avoid:** Copy the full sid resolution block from write-marker.sh verbatim. The `completion_id` extraction is a side-product of the resolution loop and does not need to be used in job markers — but leaving the extraction code in does no harm.
**Warning signs:** Job marker files named `pseudo-{timestamp}.jsonl` appearing regularly (indicates the cron-session exclusion is failing).

### Pitfall 2: Sanitization Applied After Allowlist Check
**What goes wrong:** If sanitization runs after the allowlist/status validation, a sanitized value (e.g., `feature_development` with no special chars) passes both, but a value like `feature:development` would fail the allowlist before being sanitized into `feature_development`. This is actually desirable behavior — reject before sanitizing, since the sanitized form may match a valid label, which could be confusing.
**How to avoid:** Apply `sanitize()` to all fields at the top of the Python block (immediately after reading from `os.environ`), THEN run allowlist and status validation on the sanitized values. This means the allowlist check sees the sanitized form, which is also what gets written to the record. Consistent and predictable.

### Pitfall 3: failure_reason Written for Non-FAILED Status
**What goes wrong:** `failure_reason` present in a SUCCESS or CANCELLED marker is not a hard error, but it pollutes the record and may confuse Phase 6's `--metadata` forwarding logic.
**How to avoid:** In the Python block, only include `failure_reason` in the record when `status == "FAILED"` and `failure_reason` is non-empty:
```python
if status == "FAILED" and failure_reason:
    rec["failure_reason"] = failure_reason
```

### Pitfall 4: Missing Script in post-install.sh chmod Loop
**What goes wrong:** If `write-job-marker.sh` is not added to the `for script in ...` loop on line 114 of `post-install.sh`, the script will not be marked executable at install time, causing `bash: permission denied` when the agent calls it.
**How to avoid:** Plan task must explicitly add `write-job-marker.sh` to that loop.
**Warning signs:** `permission denied` error when the agent calls `write-job-marker.sh`.

### Pitfall 5: Argument Injection via --failure-reason
**What goes wrong:** `failure_reason` is a free-text field written by the agent. In Phase 6, its value is passed to `revenium jobs outcome --metadata`. If the Phase 6 implementation interpolates `failure_reason` unsafely into a shell command, a value containing shell metacharacters (`;`, `&&`, `$(...)`) could execute arbitrary commands.
**Why Phase 5 is the defense:** Phase 5's sanitizer strips `:`, `|`, and newlines, but does NOT strip `;`, `&&`, or `$(...)`. The planner should note that the sanitizer in Phase 5 is a partial defense for Phase 6. Phase 6 must either use the same env-passing-heredoc pattern for CLI invocation, or the Phase 5 sanitizer needs to be expanded. Flag this as a Phase 6 threat-model item.
**How to avoid in Phase 5:** Document the scope of the sanitizer clearly. The three chars (`:`, `|`, newline) are the explicit JOBDEC-04 requirement. Phase 6 must not shell-interpolate `failure_reason`.

### Pitfall 6: SKILL.md Section Ordering Breaks Guard-First Contract
**What goes wrong:** Placing JOB DECLARATION before TASK CLASSIFICATION, or before the Guardrail Check Procedure, would imply job markers are written before the guardrail is checked. This is wrong — the halt check is the absolute first action.
**How to avoid:** Insert JOB DECLARATION strictly after TASK CLASSIFICATION (after line 115), not before it.

---

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V4 Access Control (file permissions) | Yes | `os.makedirs(markers_dir, mode=0o700, exist_ok=True)` — inherited from write-marker.sh |
| V5 Input Validation / Output Encoding | Yes | Allowlist validation (job_type, status); sanitize() for free-text fields |
| V5 Path Traversal | Yes | `re.fullmatch(r'[0-9a-fA-F-]+|pseudo-[0-9]+', sid)` — same guard as write-marker.sh |
| V5 Log Injection | Yes | Truncate `job_type` and other fields to 64 chars in the bash `info` log call before heredoc |
| V6 Cryptography | No | No crypto operations |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Shell metachar injection via `--failure-reason` into Phase 6 CLI | Tampering | Sanitize in Phase 5 (partial); Phase 6 must use env-passing heredoc for CLI invocation |
| Log injection via long job_name/job_id values | Tampering | Truncate to 64 chars in bash `info` call (before heredoc, same as `TASK_TYPE_LOG` in write-marker.sh) |
| Path traversal via crafted sid | Elevation of privilege | `re.fullmatch` sid guard — copy from write-marker.sh verbatim |
| Race condition on markers JSONL | Tampering | `fcntl.flock(LOCK_EX)` + `O_APPEND` — copy from write-marker.sh verbatim |
| Slopsquatted/malicious job_type bypassing allowlist | Spoofing | Allowlist check against loaded JSON; json.load() not eval() |

---

## Validation Architecture

`nyquist_validation: true` in `.planning/config.json` — this section is required.

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Plain bash (`#!/usr/bin/env bash`) — no external test runner |
| Config file | None — each test file is self-contained |
| Quick run command | `bash tests/test_write_job_marker.sh` |
| Full suite command | `bash tests/test_write_marker.sh && bash tests/test_write_job_marker.sh && bash tests/test_report_argv.sh && bash tests/test_setup_guardrails_argv.sh && python3 -m pytest tests/test_get_root_session_id.py -v` |
| Test result format | `PASS: <description>` / `FAIL: <description>` per assertion, exit 0/1 |

**No test runner script exists** (`run_tests.sh` is absent from the `tests/` directory). Each test file is invoked individually with `bash`. The full suite is run by calling them sequentially.

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| JOBDEC-01 | `job-taxonomy.json` has 11 labels, all snake_case, correct shape | unit | `bash tests/test_write_job_marker.sh` (taxonomy-load test case) | ❌ Wave 0 |
| JOBDEC-03 | Writer exits 0 and prints "job marker written:" for a valid well-formed call | integration | `bash tests/test_write_job_marker.sh` | ❌ Wave 0 |
| JOBDEC-03 | Writer exits non-zero for unknown `job_type` | integration | `bash tests/test_write_job_marker.sh` | ❌ Wave 0 |
| JOBDEC-03 | Writer exits non-zero for invalid `status` value | integration | `bash tests/test_write_job_marker.sh` | ❌ Wave 0 |
| JOBDEC-03 | Writer exits non-zero when mandatory flag is missing | integration | `bash tests/test_write_job_marker.sh` | ❌ Wave 0 |
| JOBDEC-03 | Written record is valid JSONL with all 7 mandatory fields, correct `kind:"job"`, ISO8601 ts | integration | `bash tests/test_write_job_marker.sh` | ❌ Wave 0 |
| JOBDEC-03 | Two rapid invocations yield two non-corrupt lines (flock + O_APPEND) | integration | `bash tests/test_write_job_marker.sh` | ❌ Wave 0 |
| JOBDEC-03 | `failure_reason` is written for FAILED, absent for SUCCESS and CANCELLED | integration | `bash tests/test_write_job_marker.sh` | ❌ Wave 0 |
| JOBDEC-03 | markers/ directory is created with mode 0700 | integration | `bash tests/test_write_job_marker.sh` | ❌ Wave 0 |
| JOBDEC-04 | Field containing `:` / `|` / newline is sanitized to `_` in the written record | integration | `bash tests/test_write_job_marker.sh` | ❌ Wave 0 |
| JOBDEC-04 | Field longer than length cap is truncated in the written record | integration | `bash tests/test_write_job_marker.sh` | ❌ Wave 0 |
| JOBDEC-02 | SKILL.md contains `JOB DECLARATION` section | manual/grep | `grep -c "JOB DECLARATION" SKILL.md` ≥ 1 | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `bash tests/test_write_job_marker.sh`
- **Per wave merge:** `bash tests/test_write_marker.sh && bash tests/test_write_job_marker.sh`
- **Phase gate:** Both test files green before `/gsd-verify-work`

### Wave 0 Gaps
- [ ] `tests/test_write_job_marker.sh` — covers all JOBDEC-03 and JOBDEC-04 integration tests. Mirror `test_write_marker.sh` structure: tmp OPENCLAW_HOME tree, seed `job-taxonomy.json`, PASS/FAIL counters, cleanup trap.

**Note:** The existing `test_write_marker.sh` test suite covers `write-marker.sh` and does not need modification. The new test file is entirely additive.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `python3` | write-job-marker.sh heredoc | ✓ (confirmed — write-marker.sh runs today) | system | — |
| `bash` | write-job-marker.sh wrapper | ✓ | system | — |
| `fcntl` (Python stdlib) | flock in heredoc | ✓ (confirmed — write-marker.sh uses it) | stdlib | — |
| `json`, `os`, `time`, `re`, `sys` | heredoc logic | ✓ (confirmed in write-marker.sh) | stdlib | — |

No missing dependencies. This phase is code/file additions only.

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Length cap of 256 chars for sanitized fields is reasonable | Pattern 3 (Sanitization) | If Phase 6 CLI has a shorter max arg length, marker values may still cause truncation at CLI invocation time; Phase 6 must verify |
| A2 | The planner will treat "allowlist-only" as sufficient for JOBDEC-01 snake_case requirement (no load-time regex added) | OQ-2 (Snake_case) | If a test audit requires regex enforcement, a load-time `re.fullmatch` check must be added to the writer |
| A3 | `references/job-declaration.md` is a new file (not replacing an existing one) | Hermes content to port | Low risk — confirmed no such file exists in this repo yet |

---

## Sources

### Primary (HIGH confidence)

- `scripts/write-marker.sh` (live file read) — exact idioms for env-passing heredoc, allowlist validation, sid resolution, flock+O_APPEND, path-traversal guard, markers dir mode 0700
- `scripts/common.sh` (live file read) — TAXONOMY_FILE constant, STATE_DIR, MARKERS_DIR, SESSIONS_DIR definitions; SKILL_DIR == STATE_DIR collapsed model
- `scripts/post-install.sh` lines 114–142 (live file read) — taxonomy seeding mechanism, chmod loop
- `task-taxonomy.json` (live file read) — `{"labels": {"<label>": {"description", "examples"}}}` shape
- `SKILL.md` lines 63–115 (live file read) — TASK CLASSIFICATION section structure and ordering
- `tests/test_write_marker.sh` (live file read) — test harness conventions (PASS/FAIL counters, tmp home, cleanup trap, assertions)
- `../hermes-revenium/skills/revenium/job-taxonomy.json` (live file read) — 11 labels with descriptions and examples
- `../hermes-revenium/skills/revenium/references/job-declaration.md` (live file read) — arc definition, trigger, status bar, worked examples
- `../hermes-revenium/skills/revenium/SKILL.md` lines 228–249 (live file read) — Hermes JOB DECLARATION marker shape (unix_float ts, backstop model)
- `.planning/config.json` (live file read) — `nyquist_validation: true`

### Secondary (MEDIUM confidence)

- `../hermes-revenium/skills/revenium/scripts/pre_tool_call.sh` lines 166–181 (live file read) — Hermes CANCELLED job marker shape confirmation

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all components verified against live files
- Architecture: HIGH — all patterns extracted from existing code
- Pitfalls: HIGH — derived from direct code inspection (no speculation)
- Open questions: HIGH — all 5 resolved against live files with specific line references

**Research date:** 2026-06-03
**Valid until:** 2026-07-03 (stable domain; files won't change without a commit)
