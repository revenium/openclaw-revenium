# Phase 4: Task Metering & Attribution - Pattern Map

**Mapped:** 2026-06-03
**Files analyzed:** 9 (3 new + 5 modified scripts/SKILL.md + 1 new asset)
**Analogs found:** 9 / 9

> Builds on `03-PATTERNS.md`. Do NOT re-derive the Hermes→OpenClaw substitution map,
> the atomic-write pattern, the fail-open cron posture, the bash-3.2 env-passing heredoc
> pattern, or the OPENCLAW_HOME probe — they are inherited verbatim from Phase 3 and
> referenced here by name. Phase 4 adds only the deltas in the "Phase 4 New Patterns"
> section below.

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `~/.openclaw/skills/revenium/task-taxonomy.json` | config/data asset | N/A (read) | `../hermes-revenium/skills/revenium/task-taxonomy.json` | exact (copy verbatim) |
| `scripts/write-marker.sh` | utility/helper | file-I/O (append) | Hermes `references/task-classification.md` `write_marker` snippet (py) + OpenClaw `common.sh` header | role-match (port from py snippet → bash+heredoc) |
| `scripts/get-root-session-id.py` | utility/resolver sidecar | transform (JSONL scan) | `../hermes-revenium/skills/revenium/scripts/get-root-session-id.py` | role-match (swap SQLite query → JSONL scan) |
| `scripts/common.sh` | utility/library | N/A (sourced) | `scripts/common.sh` (self) + Hermes `common.sh:96-106` | exact (self-update) |
| `scripts/report.sh` | service/cron reporter | request-response (per-line) | `scripts/report.sh` (self) + Hermes `hermes-report.sh:196-202` | exact (self-update) |
| `scripts/setup-guardrails.sh` | utility/interactive | request-response | `scripts/setup-guardrails.sh` (self) + Hermes `setup-guardrails.sh:699-797` | exact (self-update; port picker) |
| `scripts/cron.sh` | orchestrator/cron | batch | `scripts/cron.sh` (self) | exact (self-update; add prune stage) |
| `SKILL.md` | LLM-instruction | request-response | `SKILL.md` (self) + Hermes `SKILL.md:218-226` + `references/task-classification.md` | exact (self-update; port classification) |
| `scripts/post-install.sh` | config/installer | batch | `scripts/post-install.sh` (self) | exact (self-update; seed + chmod) |

> `scripts/post-install.sh` is listed because two new scripts (`write-marker.sh`,
> `get-root-session-id.py`) must be added to its chmod loop and `task-taxonomy.json`
> must be seeded + the `markers/` dir created. It is NOT in the CONTEXT file list but
> RESEARCH "Runtime State Inventory" / "Build artifacts" require the change. Planner:
> include it.

---

## Phase 4 New Patterns (the only real divergences)

RESEARCH key insight: "Almost everything except the JSONL resolver and the
timestamp-precedence correlation is a verbatim or near-verbatim port from Hermes."
These four patterns are the load-bearing novelty.

### NP-1: Timestamp-precedence correlation (D-01) — REPLACES Hermes equal_split
**What:** Tag each completion with the most recent marker whose `ts` precedes the
completion's `timestamp`. Do NOT port `split_strategies.equal_split`.
**Where it lands:** `report.sh process_session`, after the completion `timestamp` is
extracted (current `report.sh:372`), inside the per-line `while` loop (`report.sh:335-496`).
**Source excerpt** (RESEARCH §"Pattern 1", derived for OpenClaw — bash-3.2 env-passing heredoc):
```bash
MARKER_FILE="${MARKERS_DIR}/${session_id}.jsonl" COMPLETION_TS="${timestamp}" python3 - <<'PY'
import json, os
mf = os.environ.get('MARKER_FILE', ''); cts = os.environ.get('COMPLETION_TS', '')
chosen = 'unclassified'
try:
    rows = []
    if os.path.exists(mf):
        with open(mf, encoding='utf-8') as fh:
            for line in fh:
                line = line.strip()
                if not line: continue
                try: r = json.loads(line)
                except Exception: continue
                if isinstance(r, dict) and r.get('ts') and r.get('task_type'):
                    rows.append((r['ts'], r['task_type']))
    rows.sort(key=lambda x: x[0])      # ISO8601 sorts lexicographically
    for ts, tt in rows:
        if ts <= cts: chosen = tt
        else: break
except Exception:
    chosen = 'unclassified'
print(chosen)
PY
```
**Performance (Pitfall 3):** read + sort markers ONCE per session before the line loop
(cache like `report.sh` already caches msg metadata in temp files at `report.sh:305-319`),
then for each completion line bisect against the cached sorted list. Do NOT spawn python3
per completion line.

### NP-2: JSONL childSessionKey reverse-walk resolver (D-05) — REPLACES Hermes SQLite walk
**What:** Build a reverse `child→parent` map by scanning all `*.jsonl` for
`sessions_spawn` toolResult lines carrying `details.childSessionKey`; walk to root;
fail-open to input sid. Mirrors the Hermes resolver *contract* (max_depth=10 cycle guard,
fail-open, never raises) but swaps the data source.
**Analog contract** (`../hermes-revenium/skills/revenium/scripts/get-root-session-id.py:35-68`):
keep the signature `get_root_session_id(sid, ..., max_depth=10)`, the `if not sid: return sid`
guard, the `for _ in range(max_depth)` walk, and the blanket `except Exception: return sid`.
**Swap** the SQLite block (Hermes lines 52-64):
```python
# Hermes (DROP):
uri = f"file:{state_db}?mode=ro"
with sqlite3.connect(uri, uri=True) as conn:
    current = sid
    for _ in range(max_depth):
        row = conn.execute("SELECT parent_session_id FROM sessions WHERE id = ?", (current,)).fetchone()
        if row is None or row[0] is None: return current
        current = row[0]
    return current
```
**For** the JSONL scan (RESEARCH §"Code Examples" / §"Recommended resolver algorithm"):
```python
# build reverse map once; cheap pre-filter on the raw line before json.loads
child_to_parent = {}
for f in os.listdir(sessions_dir):
    if not f.endswith(".jsonl"): continue
    parent_sid = f[:-len(".jsonl")]
    try:
        with open(os.path.join(sessions_dir, f), encoding="utf-8") as fh:
            for line in fh:
                if '"sessions_spawn"' not in line:   # cheap pre-filter
                    continue
                try: o = json.loads(line)
                except Exception: continue
                det = (o.get("message") or {}).get("details") or {}
                ck = det.get("childSessionKey")
                if ck:
                    child_to_parent[ck.rsplit(":", 1)[-1]] = parent_sid
    except OSError:
        continue
current = sid
for _ in range(max_depth):
    parent = child_to_parent.get(current)
    if parent is None: return current
    current = parent
return current
```
`sessions_dir` default: `os.path.join(os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw")), "agents", "main", "sessions")` (matches `report.sh:28` `SESSIONS_DIR`).
**`__main__` block:** keep Hermes' exactly — `if len(sys.argv) < 2 or not sys.argv[1]: sys.exit(0)` then `print(get_root_session_id(sys.argv[1]))`.

### NP-3: write-marker.sh helper (D-03) — port from Hermes `write_marker` py snippet
**What:** Validate `<task_type>` against taxonomy allowlist, resolve current sid, append
`{"ts","task_type"}` (ISO8601 ts) under `flock`. Bash wrapper around a python heredoc.
**Source:** `references/task-classification.md:37-83` `write_marker` snippet — but SIMPLIFY:
drop `muid`, drop the dual GUARDRAIL/CHAT two-record pattern, drop the unix-float `ts`
(use ISO8601 per Pitfall 2 / NP-1), drop `sid`/`operation_type` fields. OpenClaw marker
shape is exactly `{"ts":"<ISO8601Z>","task_type":"<label>"}` (D-02 / specifics).
**Header pattern:** copy `scripts/common.sh:1-15` header style + source common.sh for
`STATE_DIR`, `MARKERS_DIR`, `TAXONOMY_FILE`, `SESSIONS_DIR`, `info`/`warn`, `ensure_path`.
**Core (RESEARCH §"Pattern 2", bash-3.2 env-passing heredoc):**
```bash
TASK_TYPE="$1" TAXONOMY_FILE="${TAXONOMY_FILE}" \
MARKERS_DIR="${MARKERS_DIR}" SESSIONS_DIR="${SESSIONS_DIR}" \
python3 - <<'PY'
import json, os, time, fcntl, re
tt = os.environ['TASK_TYPE']
labels = set(json.load(open(os.environ['TAXONOMY_FILE'])).get('labels', {}))  # allowlist (V5)
if tt not in labels:
    raise SystemExit(f"unknown task_type: {tt}")
sd = os.environ['SESSIONS_DIR']
cands = [f for f in os.listdir(sd) if f.endswith('.jsonl')]
sid = max(cands, key=lambda f: os.path.getmtime(os.path.join(sd, f)))[:-len('.jsonl')] if cands else f"pseudo-{int(time.time())}"
if not re.fullmatch(r'[0-9a-fA-F-]+|pseudo-[0-9]+', sid):  # path-traversal guard (V5)
    raise SystemExit("unsafe sid")
md = os.environ['MARKERS_DIR']; os.makedirs(md, mode=0o700, exist_ok=True)
mp = os.path.join(md, f"{sid}.jsonl")
rec = {"ts": time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), "task_type": tt}
with open(mp, "ab", buffering=0) as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    f.write((json.dumps(rec, separators=(",",":")) + "\n").encode())
print(f"marker written: {mp}")
PY
```
**Exit-code contract for SKILL.md:** non-zero on unknown/unsafe `<task_type>` (so SKILL.md
can surface a protocol error); 0 + `marker written: <path>` on success.
**OPEN (A2 / Pitfall 5 / RESEARCH Open Q1-2):** the "newest *.jsonl" sid heuristic may pick
a cron session. Planner MUST add a worked example; consider reading `sessions.json` to
exclude `agent:main:cron:*`-keyed files, OR prefer an `OPENCLAW_SESSION_ID` env var if a
plan-time probe (`env | grep -i session` inside an OpenClaw bash tool call) finds one.

### NP-4: per-task-type picker with TASK_TYPE filter (D-10) — port + FIX Hermes bug
**What:** After the base rule, offer per-label budget rules from `task-taxonomy.json`. Each
per-task `create_rule` MUST add `--filter "TASK_TYPE:IS:<label>"` AND `--group-by TASK_TYPE`
on top of the base `AGENT:STARTS_WITH:openclaw-` filter.
**Source:** `../hermes-revenium/skills/revenium/scripts/setup-guardrails.sh:699-797` —
port the taxonomy-read, the numbered-menu print, the comma-index parse, and the
per-label create loop verbatim (all four are clean bash-3.2 env-passing heredocs).
**Hermes bug to FIX (Pitfall 4):** Hermes' loop calls `create_rule "${task_rule_name}" ...`
which emits ONLY the module base `AGENT` filter — every per-task rule ends up identical with
no TASK_TYPE scoping. The OpenClaw `create_rule` (current `setup-guardrails.sh:248-352`) must
be parameterized to accept an extra `--filter` (and `--group-by TASK_TYPE`), e.g. add a 5th
positional `extra_filter` arg appended to the `cmd`/heredoc when non-empty. Rule name uses
`"OpenClaw ${label_title} Budget"` (substitute "Hermes"→"OpenClaw", matching current
`setup-guardrails.sh:459,640`).
**Capability gate (defense-in-depth, never triggers on 1.1.2):**
```bash
if revenium guardrails budget-rules create --help 2>/dev/null | grep -q 'TASK_TYPE'; then
  # offer picker
else
  info "revenium CLI lacks TASK_TYPE filter dimension — skipping per-task-type picker"
fi
```

---

## Pattern Assignments

### `~/.openclaw/skills/revenium/task-taxonomy.json` (config asset) — NEW
**Analog:** `../hermes-revenium/skills/revenium/task-taxonomy.json` (read in full).
Copy **verbatim** — the 8 labels (`research, analysis, generation, review, code_review,
refactor, planning, debugging`) match ROADMAP success criterion 1 exactly [VERIFIED].
**Single path** (Pitfall 6): lives at `${STATE_DIR}/task-taxonomy.json`. Do NOT port
Hermes' seed-vs-live two-path model — OpenClaw collapses skill dir and state dir.
**Source of truth lives in repo** (so post-install can seed it): place the file at the repo
root (alongside `SKILL.md`/`BUDGET-GUARD.md`) mirroring Hermes' `skills/revenium/`.

### `scripts/get-root-session-id.py` (resolver sidecar) — NEW
See **NP-2**. Header/docstring adapted from Hermes file (drop the SQLite/`state.db` /
`classifier._walk_to_root_session` references; document the `childSessionKey` source).
**Wired by:** the `common.sh` resolver wrapper (below), called once per session in `report.sh`.

### `scripts/write-marker.sh` (helper) — NEW
See **NP-3**. Called by SKILL.md TASK CLASSIFICATION section as:
`bash ~/.openclaw/skills/revenium/scripts/write-marker.sh <task_type>`.

### `scripts/common.sh` (library) — MODIFY (self-update)
**Analog:** `scripts/common.sh` (self, read in full) + Hermes `common.sh:96-106`.
Three additive changes; everything else (lines 1-124) UNCHANGED.

**Add 1 — path constants** (after current line 47 `RULES_LOCK_FILE`):
```bash
TAXONOMY_FILE="${STATE_DIR}/task-taxonomy.json"
MARKERS_DIR="${STATE_DIR}/markers"
SESSIONS_DIR="${OPENCLAW_HOME}/agents/main/sessions"
```
(03-PATTERNS.md "Omit from OpenClaw common.sh" listed `TAXONOMY_FILE`/`MARKERS_DIR` as
Phase-4 concerns — this is the phase that adds them.)

**Add 2 — `REVENIUM_AGENT_PREFIX` constant** (D-07; beside current line 53
`REVENIUM_AGENT_NAME`, keep both):
```bash
# D-07: metering/filter scheme. report.sh ships --agent "${REVENIUM_AGENT_PREFIX}${root_sid}";
# base budget rule filters AGENT:STARTS_WITH:${REVENIUM_AGENT_PREFIX}. Supersedes the static
# AGENT:IS:${REVENIUM_AGENT_NAME} model (Phase 3 D-23) for filtering/rollup.
REVENIUM_AGENT_PREFIX="${REVENIUM_AGENT_PREFIX:-openclaw-}"
```

**Add 3 — `get_root_session_id()` wrapper** (adapt Hermes `common.sh:96-106` — add the
`OPENCLAW_HOME` env pass-through that RESEARCH §"common.sh resolver wrapper" shows):
```bash
get_root_session_id() {
  local sid="${1:-}"
  [[ -z "${sid}" ]] && return 0
  if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "${sid}"; return 0
  fi
  OPENCLAW_HOME="${OPENCLAW_HOME}" python3 "${SKILL_DIR}/scripts/get-root-session-id.py" "${sid}" 2>/dev/null \
    || printf '%s\n' "${sid}"
}
```

### `scripts/report.sh` (cron reporter) — MODIFY (self-update)
**Analog:** `scripts/report.sh` (self, read in full) + Hermes `hermes-report.sh:196-202`
(resolve-root-once-per-session placement).

**Change 1 — source common.sh constants.** `report.sh` currently defines its own paths
(`report.sh:28-34`) and does NOT source `common.sh`. It needs `MARKERS_DIR`,
`REVENIUM_AGENT_PREFIX`, and `get_root_session_id`. Either source `common.sh` after the
OPENCLAW_HOME probe, or add the three constants + the resolver wrapper inline. (Planner's
discretion; sourcing is cleaner but report.sh's self-contained PATH/log block at
`report.sh:36-68` overlaps common.sh — verify no double-definition.) `SESSIONS_DIR` already
exists at `report.sh:28`.

**Change 2 — resolve root once per session** (Pitfall 3). In `process_session`
(`report.sh:279`), after `session_id=$(basename ...)` (line 282) and before the line loop:
```bash
local root_sid
root_sid=$(get_root_session_id "${session_id}")
root_sid="${root_sid:-${session_id}}"   # fail-open belt-and-suspenders (D-05)
```
Also read+sort the marker list ONCE here (NP-1 performance note) into a temp/cache.

**Change 3 — task-type correlation** (NP-1). In the per-line loop, after `timestamp` is set
(`report.sh:372`), compute `task_type` via the precedence lookup against the cached markers;
default `unclassified`. Pass it into `post_to_revenium` as a new positional arg.

**Change 4 — `--agent` and `--task-type` flags** (D-07/D-05/METER-03). In `post_to_revenium`
(`report.sh:186-274`):
- Replace `report.sh:221` `--agent "OpenClaw"` with `--agent "${REVENIUM_AGENT_PREFIX}${root_sid}"`
  (add `root_sid` and `task_type` as new params to the function signature
  `report.sh:186-205` + the call site `report.sh:478-489`).
- Add to the `cmd` array (always present, default `unclassified` per A4):
  ```bash
  --task-type "${task_type:-unclassified}"
  ```
**Reuse verbatim:** `get_provider` (103), `clean_model_name` (119), `map_stop_reason` (133),
`get_offset`/`set_offset` (149-181), the trace-id walk (418-437) — RESEARCH "Don't Hand-Roll".
**Do NOT** introduce any jobs / `--agentic-job-id` machinery (out of scope, RESEARCH Anti-Patterns).

### `scripts/setup-guardrails.sh` (interactive) — MODIFY (self-update)
**Analog:** `scripts/setup-guardrails.sh` (self) + Hermes `setup-guardrails.sh:699-797`.

**Change 1 — base filter** (D-07). Replace BOTH occurrences (current `setup-guardrails.sh:270`
and `:289`):
```bash
# CURRENT:
--filter "AGENT:IS:${REVENIUM_AGENT_NAME}" \
# AFTER (D-07):
--filter "AGENT:STARTS_WITH:${REVENIUM_AGENT_PREFIX}" \
```
Update the comment at `:242` and the help text at `:42` accordingly (STARTS_WITH, prefix).

**Change 2 — parameterize `create_rule`** for the picker (NP-4 / Pitfall 4 fix). Add an
optional extra-filter + group-by override so per-task rules can append
`--filter "TASK_TYPE:IS:<label>"` and `--group-by TASK_TYPE`. The base rule keeps
`--group-by AGENT` (current `:267`,`:286`).

**Change 3 — add the picker** after the base-rule creation in `run_interactive`
(current base rule name at `setup-guardrails.sh:640`). Port Hermes `:699-797` with the NP-4
fix + the capability gate. Reuse existing `validate_hard_limit` / `compute_warn_threshold`
(present in current file — 03-PATTERNS confirms ports). Append each new ruleId to the
config write (current `write_rule_ids_*` helpers, `setup-guardrails.sh:354+`).

> 03-PATTERNS.md deliberately OMITTED this picker ("Task-type picker section ... Omit
> entirely"). Phase 4 ports it back — this is the explicit Phase 3→4 reversal (CONTEXT D-10).

### `scripts/cron.sh` (orchestrator) — MODIFY (self-update)
**Analog:** `scripts/cron.sh` (self, read in full). Add a marker-prune stage (D-04) inside
BOTH lock branches, after the existing `report.sh` + `guardrail-check.sh` calls
(`cron.sh:79-80` flock branch and `:93-94` mkdir branch). Fail-open posture (03-PATTERNS
"Fail-Open Cron Posture"):
```bash
# D-04: prune marker files older than ~7d (threshold = Claude's discretion).
# Fail-open: prune failure never blocks the tick.
prune_markers || true
```
where `prune_markers` is a small inline function (or a stage in report.sh per D-04 discretion)
using `find "${MARKERS_DIR}" -name '*.jsonl' -mtime +7 -delete 2>/dev/null` (BSD/GNU-portable,
matches the existing portable `find -mmin` usage at `cron.sh:88`). MARKERS_DIR comes from
common.sh; cron.sh currently does NOT source common.sh, so either source it or inline the path
(`${OPENCLAW_HOME}/skills/revenium/markers`). **Decision (D-04 discretion):** owning stage is
`cron.sh` vs `report.sh` — planner picks; if `report.sh`, gate behind the per-tick run, not
per session.
**Reference for the staleness model** (optional): Hermes `prune-markers.sh` is ledger-aware;
OpenClaw's simpler mtime-based prune is sufficient (markers carry no ledger linkage).

### `SKILL.md` (LLM-instruction) — MODIFY (self-update)
**Analog:** `SKILL.md` (self, headings inventoried) + Hermes `SKILL.md:218-226` +
`references/task-classification.md` (read in full).

**Change 1 — TASK CLASSIFICATION section** (D-09/METER-02). Add a new section (e.g. after
the `## Guardrail Check Procedure`, before `## /revenium Command`). Port the Hermes
trigger wording verbatim-in-spirit from `references/task-classification.md:5-16`:
classify if (called a non-read-only tool) OR (>200 words) OR (multi-step reasoning);
skip ONLY when ≤2 sentences AND zero tools. Port worked examples (`task-classification.md:94-116`).
**Replace** the Hermes `execute_code` `write_marker` python snippet with a SINGLE directive:
> Call `bash ~/.openclaw/skills/revenium/scripts/write-marker.sh <task_type>` where
> `<task_type>` is one of the 8 taxonomy labels. Confirmation = `marker written: <path>`.
**DROP** (RESEARCH Anti-Patterns / CONTEXT out-of-scope): the JOB DECLARATION section
(`Hermes SKILL.md:228-249`), the classifier-plugin references, the subagent `trace_id`/
`agentic_job_id` paragraph (`Hermes SKILL.md:224`), the GUARDRAIL/CHAT two-record invariant,
and any `references/job-declaration.md` link. Also port `references/task-classification.md`
itself (stripped of plugin/job refs) so SKILL.md can link to it.

**Change 2 — legacy-install reconfigure notice** (D-08). In the `/revenium` command flow
(current `SKILL.md:132-156`) and/or a cron-path check, detect rules still filtering the
legacy `AGENT:IS:OpenClaw` (live `revenium guardrails budget-rules list --output json`
filter inspection — reuse the `--output json` + python-parse idiom from
`guardrail-check.sh` API-fetch pattern in 03-PATTERNS — OR a `config.json` schema/version
marker; mechanism = Claude's discretion). Surface ONE-TIME:
> "Your budget rules use the old filter and won't track spend — run reconfigure."
**NO auto-rewrite** (honors Phase 3 D-02; RESEARCH Anti-Patterns). "One-time" = persist a
flag in `config.json` (atomic write, 03-PATTERNS "Atomic JSON Write") so the notice doesn't
repeat every turn.

### `scripts/post-install.sh` (installer) — MODIFY (self-update)
**Analog:** `scripts/post-install.sh` (self).
- **chmod loop** (current `post-install.sh:114`): add `write-marker.sh` and
  `get-root-session-id.py` to the script list (mirrors 03-PATTERNS "Change 1").
- **Seed `task-taxonomy.json`**: copy the repo-root taxonomy into `${SKILL_DIR}/task-taxonomy.json`
  if absent (Pitfall 6 single path; reuse the existing copy-from-SKILL_DIR idiom used for
  BUDGET-GUARD.md per 03-PATTERNS "Change 3").
- **Create `markers/` dir** mode 0700 (ASVS V4): `mkdir -p "${SKILL_DIR}/markers" && chmod 700 ...`.

---

## Shared Patterns (inherited from 03-PATTERNS.md — apply, do not re-derive)

| Pattern | 03-PATTERNS source | Phase 4 application |
|---------|--------------------|---------------------|
| **OPENCLAW_HOME Multi-Candidate Probe** | 03-PATTERNS §"Shared Patterns"; `common.sh:23-33`, `cron.sh:14-22`, `report.sh:18-26` | resolver sidecar `sessions_dir` default; any new script that runs standalone |
| **Atomic JSON Write (temp-then-rename)** | 03-PATTERNS §"Atomic JSON Write" | `config.json` legacy-notice flag (D-08); offsets already use it (`report.sh:165-181`) |
| **Fail-Open Cron Posture** (`\|\| true`, `exit 0`) | 03-PATTERNS §"Fail-Open Cron Posture"; `cron.sh:79-94` | resolver (fail-open to sid, D-05/D-06), prune stage (D-04), correlation (default `unclassified`) |
| **Python3 Env-Passing Heredoc (bash 3.2)** | 03-PATTERNS §"Python3 Env-Passing Heredoc" | write-marker.sh, NP-1 correlation, NP-4 picker — NEVER interpolate `${VAR}` inside `<<'PY'` |
| **Log Injection Mitigation (64-char trunc)** | 03-PATTERNS §"Log Injection Mitigation" | per-task rule names + marker task_type in log lines |
| **flock append (fcntl.LOCK_EX + O_APPEND)** | RESEARCH "Don't Hand-Roll" (Hermes `write_marker`) | write-marker.sh concurrent-turn safety |

---

## Key Substitution Map (Phase 4 additions to 03-PATTERNS map)

| Hermes / Phase 3 | OpenClaw Phase 4 |
|------------------|------------------|
| `state.db.sessions.parent_session_id` SQLite walk | JSONL `details.childSessionKey` reverse scan (NP-2) |
| `split_strategies.equal_split` window correlation | timestamp-precedence (NP-1) |
| `--agent "OpenClaw"` (static, Phase 3 D-23) | `--agent "openclaw-{root_sid}"` (D-07) |
| `AGENT:IS:${REVENIUM_AGENT_NAME}` filter | `AGENT:STARTS_WITH:${REVENIUM_AGENT_PREFIX}` (D-07) |
| Hermes `write_marker` py snippet (muid + dual GUARDRAIL/CHAT + unix-float ts) | `write-marker.sh <task_type>` (single record, ISO8601 ts, no muid) (NP-3) |
| Hermes two-path taxonomy (seed + live) | single `${STATE_DIR}/task-taxonomy.json` (Pitfall 6) |
| Hermes picker `create_rule` (identical-filter bug) | parameterized `create_rule` + `TASK_TYPE:IS:<label>` per rule (NP-4 / Pitfall 4) |
| Hermes JOB DECLARATION / `--agentic-job-id` / classifier plugin | DROP ENTIRELY (out of scope) |
| Hermes ledger-aware `prune-markers.sh` (separate, not cron-wired) | mtime-based prune stage INSIDE `cron.sh` (D-04) |

---

## No Analog Found

All files have close analogs (Hermes sibling skill or self-update). No entries.

> Note: the JSONL resolver and timestamp-precedence correlation have *contract* analogs
> (Hermes resolver shape; report.sh per-line loop) but novel *implementations* — captured
> as NP-1/NP-2 rather than verbatim ports.

## Metadata

**Analog search scope:** `scripts/` (openclaw-revenium), repo root (SKILL.md, BUDGET-GUARD.md),
`../hermes-revenium/skills/revenium/{scripts,references,SKILL.md,task-taxonomy.json}`
**Files read:** task-taxonomy.json, get-root-session-id.py (Hermes), common.sh (OpenClaw + Hermes:90-106),
cron.sh, report.sh, setup-guardrails.sh:240-352 (OpenClaw) + :699-797 (Hermes),
task-classification.md, SKILL.md:210-260 (Hermes), SKILL.md headings + post-install.sh:114 (OpenClaw)
**Pattern extraction date:** 2026-06-03
