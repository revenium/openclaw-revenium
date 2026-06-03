# Phase 4: Task Metering & Attribution - Research

**Researched:** 2026-06-03
**Domain:** Bash metering pipeline + LLM-instruction (SKILL.md) + Revenium CLI integration; porting from sibling Hermes skill into OpenClaw
**Confidence:** HIGH

## Summary

Phase 4 grafts task-type metering and subagent attribution onto the existing OpenClaw metering pipeline (`report.sh`), guided by a controlled 8-label taxonomy and a mandatory SKILL.md classification directive. The two open research questions are now both **fully resolved with HIGH confidence against the live machine** (revenium 1.1.2, OpenClaw session JSONL at `~/.openclaw/agents/main/sessions/`):

1. **Revenium CLI flag surface (D-10, D-03):** `revenium meter completion` accepts BOTH `--task-type string` and `--agent string` [VERIFIED: `revenium meter completion --help` on 1.1.2]. `revenium guardrails budget-rules create` accepts `TASK_TYPE` as BOTH a `--filter` dimension AND a `--group-by` dimension, and `STARTS_WITH` is a documented operator [VERIFIED: `revenium guardrails budget-rules create --help` on 1.1.2]. **The per-task-type picker (criterion 5) is fully supported — no graceful-skip path is needed in practice**, though D-10's capability gate should still ship as defense-in-depth.

2. **Root-session resolution over OpenClaw JSONL (D-05/D-06):** OpenClaw has no SQLite `state.db`. The session JSONL header carries only `type, version, id, timestamp, cwd` — no parent linkage [VERIFIED: inspected header of `0c81700c-…jsonl`]. The ONLY parent→child linkage is a **`sessions_spawn` toolResult line written in the PARENT file**, carrying `details.childSessionKey = "agent:main:subagent:<child-sid>"` [VERIFIED: line in `1950694d-…jsonl`]. Critically, **the spawned child session has no separate `<sid>.jsonl` file and no `sessions.json` index entry** — its transcript is inlined in the parent. Therefore `report.sh`, which iterates `<sid>.jsonl` files, already only ever processes root/top-level sessions in the observed model. The recommended resolver builds a reverse `child→parent` map by scanning all session files for `childSessionKey` and walks it (fail-open to self).

**Primary recommendation:** Port the Hermes task-type + agent logic into OpenClaw's simpler per-line `report.sh` loop using **true timestamp-precedence** (D-01) rather than Hermes' window-equal-split. Build the JSONL-based root resolver as a small Python sidecar that scans for `childSessionKey` lines; ship `--agent "openclaw-{root}"` with fail-open to `openclaw-{sid}`. Wire `--task-type` from a timestamp-correlated marker read. Add the per-task-type picker with an explicit extra `--filter TASK_TYPE:IS:<label>` per rule (the Hermes picker has a latent bug here — see Pitfall 4).

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Task classification decision | LLM / SKILL.md | — | Only the agent knows the turn's intent; a deterministic script cannot infer task type |
| Marker write (validate + append) | `write-marker.sh` (script) | — | D-03: script owns timestamp stamping, taxonomy validation, sid resolution — avoids malformed LLM-authored markers |
| Task-type ↔ completion correlation | `report.sh` (cron) | — | report.sh already parses per-line timestamps; correlation is a deterministic delta-loop concern |
| Root-session resolution | resolver sidecar (Python) + `common.sh` wrapper | `report.sh` (caller) | Pure data-derivation over JSONL; isolated for testability + fail-open |
| Agent-name attribution (`--agent`) | `report.sh` (cron) | `common.sh` (constant) | Wire-level concern; prefix constant centralized in common.sh |
| Per-task-type budget rules | `setup-guardrails.sh` (interactive) | revenium CLI (server) | Rule creation is a setup-time interactive concern; server enforces TASK_TYPE grouping |
| Marker pruning | `cron.sh` stage (D-04) | — | Housekeeping belongs in the cron path, fail-open |
| Legacy-install detection | SKILL.md `/revenium` + optional cron check (D-08) | `config.json` marker | One-time notice; user retains control (no auto-rewrite) |

## Phase Requirements

| ID | Description (from ROADMAP success criteria) | Research Support |
|----|---------------------------------------------|------------------|
| METER-01 | `task-taxonomy.json` exists with the standard 8-label vocabulary | Copy `../hermes-revenium/skills/revenium/task-taxonomy.json` verbatim — [VERIFIED] identical 8 labels (research, analysis, generation, review, code_review, refactor, planning, debugging) |
| METER-02 | SKILL.md mandatory TASK CLASSIFICATION section fires before substantive turns, writes per-session marker | Port Hermes SKILL.md §218-226 + `references/task-classification.md` trigger rules; replace `execute_code` write_marker snippet with a single `write-marker.sh <task_type>` call (D-03) |
| METER-03 | `report.sh` passes `--task-type <label>` (default `unclassified`) on every completion | `--task-type` flag [VERIFIED] on 1.1.2; timestamp-correlation logic (D-01) grafts onto existing per-line loop |
| TRACE-01 | `report.sh` resolves root session id, ships `--agent "openclaw-{root}"` | `--agent` flag [VERIFIED]; JSONL `childSessionKey` resolver algorithm below (D-05) |
| TRACE-02 | Subagent spend aggregates under root in Revenium | `AGENT:STARTS_WITH:openclaw-` base filter [VERIFIED: STARTS_WITH operator exists]; rollup is server-side by agent value |

## Standard Stack

This phase introduces **no new external packages**. It uses tools already on the enforcement path.

### Core
| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| `revenium` CLI | 1.1.2 (546e137) | `meter completion --task-type/--agent`, `guardrails budget-rules create --filter TASK_TYPE` | [VERIFIED: `revenium 1.1.2` on this machine]; same binary Phase 3 uses |
| `python3` | system | JSON manipulation, resolver sidecar, marker read/split, atomic writes | Established Phase 3 pattern (no jq on enforcement path) |
| `jq` | system | JSONL parsing in `report.sh` (existing usage) | report.sh already depends on it (guard at line 78) |
| bash 3.2 | system | scripts (env-passing heredoc discipline) | macOS default; Phase 3 PATTERNS mandates 3.2-safe heredocs |

### Supporting
| Asset | Source | Purpose |
|-------|--------|---------|
| `task-taxonomy.json` | copy verbatim from `../hermes-revenium/skills/revenium/task-taxonomy.json` | METER-01 vocabulary; read by `write-marker.sh` (validation) + `setup-guardrails.sh` (picker) |
| `references/task-classification.md` | port from Hermes (drop classifier-plugin/job refs) | METER-02 trigger rules + worked examples |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Timestamp-precedence correlation (D-01) | Hermes window-equal-split (`split_strategies.equal_split`) | Hermes splits a window's delta equally across all markers because its report.sh works in coarse windows. OpenClaw's report.sh processes **per assistant-message line with real timestamps**, so true precedence is both simpler and more accurate. Do NOT port `equal_split`. |
| `childSessionKey` scan resolver | `sessions.json` index lookup | `sessions.json` indexes only ~9 of 97 session files (it's rotated/pruned) and contained ZERO subagent keys at research time — unreliable as a resolver source. [VERIFIED] |
| `write-marker.sh` helper (D-03) | LLM direct file-append | Direct append risks malformed JSON + missing timestamp/validation. Helper script owns correctness. |

**Installation:** None. (No `npm install` / `pip install` step in this phase.)

## Package Legitimacy Audit

> Not applicable — this phase installs **no external packages**. All tooling (`revenium`, `python3`, `jq`, bash) is pre-existing on the enforcement path and was established in Phases 1-3. No registry packages are introduced, so the slopcheck gate has nothing to evaluate.

## Revenium CLI Flag Surface (Open Question 1 — RESOLVED)

### `revenium meter completion` — relevant flags [VERIFIED: `--help` on 1.1.2]

| Flag | Type | Status | Notes |
|------|------|--------|-------|
| `--task-type` | string | **PRESENT** | "Task type classification" — free-form string; server normalizes |
| `--agent` | string | **PRESENT** | "Agent identifier" — currently hardcoded `"OpenClaw"` at report.sh:221 |
| `--trace-id` | string | PRESENT | already used by report.sh for turn correlation |
| `--operation-type` | string | PRESENT | CHAT/GENERATE/EMBED/... (report.sh already maps GUARDRAIL/TOOL_CALL/CHAT) |
| `--agentic-job-id` / `--agentic-job-name` / `--agentic-job-type` | string | PRESENT but **OUT OF SCOPE** (deferred — drop all jobs machinery per CONTEXT) |

### `revenium guardrails budget-rules create` — filter/group-by surface [VERIFIED: `--help` on 1.1.2]

- `--filter stringArray` — `dim:op:val` form. **Known dimensions: `AGENT, MODEL, PROVIDER, ORGANIZATION, CREDENTIAL, PRODUCT, SUBSCRIBER, TASK_TYPE`.** Known operators: `IS, IS_NOT, CONTAINS, STARTS_WITH, ENDS_WITH`. Repeatable.
- `--group-by` — one of `ORGANIZATION, CREDENTIAL, PRODUCT, MODEL, PROVIDER, AGENT, SUBSCRIBER, TASK_TYPE` (required).
- `--filters-json` — alternative JSON form (mutually exclusive with `--filter`).

**Conclusions:**
- `AGENT:STARTS_WITH:openclaw-` (D-07 base filter) is fully valid — `STARTS_WITH` operator confirmed.
- `TASK_TYPE:IS:<label>` (D-10 per-task filter) is fully valid — `TASK_TYPE` dimension confirmed.
- The D-10 graceful-skip path (picker offered only if CLI supports TASK_TYPE) **will never trigger on 1.1.2** — but ship the capability gate anyway as defense-in-depth against older installs. A reasonable gate: probe `revenium guardrails budget-rules create --help 2>/dev/null | grep -q 'TASK_TYPE'`.

## Root-Session Resolution Algorithm (Open Question 2 — RESOLVED)

### What the live filesystem actually contains [VERIFIED]

1. **Session JSONL header** (line 1 of each file):
   ```json
   {"type":"session","version":3,"id":"0c81700c-ff52-4bcf-b10e-843f9bd498ac","timestamp":"2026-06-02T12:00:23.099Z","cwd":"/Users/johndemic/clawd"}
   ```
   No `parentSessionId`, no `parentSessionKey`, no root field. [VERIFIED across files]

2. **Every message/custom line carries `parentId`** — but this is an **intra-session message-DAG pointer** (an 8-char hash linking to the previous message's `id`), NOT a cross-session parent. report.sh already walks this for trace-id (lines 418-437). Do NOT confuse it with session parentage.

3. **The ONLY cross-session linkage** is a `sessions_spawn` toolResult, written in the **PARENT** session file:
   ```json
   {"type":"message","id":"7599c6de","parentId":"86f81ea7","timestamp":"2026-01-28T16:38:42.940Z",
    "message":{"role":"toolResult","toolName":"sessions_spawn",
      "content":[{"type":"text","text":"{...\"childSessionKey\": \"agent:main:subagent:b1554e45-1083-4186-96e5-6131a0090151\", \"runId\": ...}"}],
      "details":{"status":"accepted","childSessionKey":"agent:main:subagent:b1554e45-1083-4186-96e5-6131a0090151","runId":"95e25ed3-..."}}}
   ```
   The child sid is the UUID suffix of `childSessionKey` (strip the `agent:<agent>:subagent:` prefix). The `details.childSessionKey` field is the clean machine-readable copy (prefer it over re-parsing the text body). [VERIFIED]

4. **The spawned child session has NO separate `.jsonl` file and NO `sessions.json` entry** — its transcript is inlined in the parent. [VERIFIED: `b1554e45` matches no file, not in `sessions.json`]. There was exactly ONE `sessions_spawn` in the entire history (in a since-deleted file), so subagents are rare on this install.

5. **`sessions.json`** is keyed by session-key namespace (`agent:main:main`, `agent:main:cron:<id>`, `agent:main:telegram:direct:<id>`, and would carry `agent:main:subagent:<id>` for live subagents). But it indexed only 9 of 97 files at research time and held zero subagent keys — **not a reliable resolver source.** [VERIFIED]

### Recommended resolver algorithm

Because the linkage is **forward (parent declares child)** and the resolver needs **reverse (child → root)**, build a reverse map:

```
get_root_session_id(sid, sessions_dir, max_depth=10):
    1. If sid empty → return sid (fail-open).
    2. Build child→parent map ONCE:
       For every *.jsonl file F in sessions_dir (basename = parent_sid):
         For every line with toolName == "sessions_spawn" AND details.childSessionKey present:
           child_sid = childSessionKey.rsplit(":", 1)[-1]
           child_to_parent[child_sid] = parent_sid
    3. Walk: current = sid; for _ in range(max_depth):
         parent = child_to_parent.get(current)
         if parent is None: return current   # current is the root
         current = parent
       return current   # depth cap hit → fail-open to deepest resolved
    4. On ANY exception (unreadable dir, malformed JSON) → return sid.
```

**Design notes:**
- This mirrors the Hermes `get-root-session-id.py` contract (max_depth=10 circular guard, fail-open to input sid, never raises) — adapt that file's structure, swap the SQLite query for the JSONL scan.
- **Performance:** building the child→parent map scans all session files. To respect the per-minute cron budget (D-01 / Hermes' "resolve once per session" note), the sidecar should accept the sid and build the map once per invocation; in report.sh, resolve `root_sid` **once per session file** (not per completion line), exactly as Hermes does at hermes-report.sh:196-202. Given subagents are rare and the spawn-line scan can short-circuit (`grep -l sessions_spawn` first), cost is negligible in the common case.
- **Optimization (recommended):** pre-filter with `grep -l '"sessions_spawn"'` to find the (usually zero) parent files before parsing — most ticks build an empty map instantly.
- **Practical reality:** since subagent transcripts are inlined and never appear as separate files report.sh iterates, in the observed model `root_sid == sid` for every file report.sh processes. The resolver is correct defense for the case where OpenClaw *does* persist a subagent session file (model may vary by version/config). Fail-open guarantees correctness either way (D-05/D-06).

**Confidence:** HIGH for the JSONL shapes and the absence of a SQLite/header linkage (directly verified). MEDIUM for whether future OpenClaw versions persist subagent sessions as separate files — the fail-open design makes this immaterial to correctness.

## Architecture Patterns

### System Data Flow

```
[Agent turn]
   │  (substantive? per D-09 trigger)
   ▼
SKILL.md TASK CLASSIFICATION  ──calls──▶  write-marker.sh <task_type>
                                              │ validates against task-taxonomy.json
                                              │ stamps ISO ts, resolves current sid
                                              ▼
                                  markers/<sid>.jsonl  (append: {"ts","task_type"})
   ...time passes; tokens accrue in session JSONL...
[cron tick] ──▶ cron.sh
                 ├─▶ report.sh
                 │      For each <sid>.jsonl (root sessions):
                 │        root_sid = get_root_session_id(sid)         ── childSessionKey scan
                 │        For each new assistant completion line (by offset):
                 │          ts_c = completion.timestamp
                 │          task_type = latest marker in markers/<sid>.jsonl where marker.ts <= ts_c
                 │                       else "unclassified"
                 │          revenium meter completion --task-type <task_type> \
                 │                                     --agent "openclaw-<root_sid>" ...
                 ├─▶ guardrail-check.sh   (Phase 3, unchanged)
                 └─▶ marker prune stage   (D-04: delete markers/* older than ~7d)

[setup] setup-guardrails.sh --interactive
          create base rule  --filter AGENT:STARTS_WITH:openclaw- --group-by AGENT
          (optional picker)  per-label rule --filter AGENT:STARTS_WITH:openclaw-
                                             --filter TASK_TYPE:IS:<label> --group-by TASK_TYPE
```

### Project Structure (additions)
```
scripts/
├── write-marker.sh          # NEW (D-03) — validate + append marker
├── get-root-session-id.py   # NEW (D-05) — JSONL childSessionKey resolver sidecar
├── report.sh                # MODIFIED — task-type correlation + --agent openclaw-{root}
├── setup-guardrails.sh      # MODIFIED — base filter → STARTS_WITH; + picker
├── common.sh                # MODIFIED — REVENIUM_AGENT_PREFIX + resolver wrapper
└── cron.sh                  # MODIFIED — marker-prune stage (D-04)
SKILL.md                     # MODIFIED — TASK CLASSIFICATION section + legacy notice
task-taxonomy.json           # NEW (copy verbatim from Hermes)
markers/<sid>.jsonl          # runtime, under ~/.openclaw/skills/revenium/markers/
```

### Pattern 1: Timestamp-precedence correlation (D-01)
**What:** Tag each completion with the most recent marker whose `ts` precedes the completion's timestamp.
**When to use:** In report.sh's per-line loop, after extracting the completion timestamp (already parsed at report.sh:372).
**Example:**
```bash
# Source: derived for OpenClaw (Hermes uses equal_split — intentionally NOT ported)
# Read markers once per session into a sorted (ts, task_type) list; for each
# completion timestamp, pick the latest marker with marker_ts <= completion_ts.
MARKER_FILE="${MARKERS_DIR}/${session_id}.jsonl" COMPLETION_TS="${timestamp}" python3 - <<'PY'
import json, os
mf = os.environ.get('MARKER_FILE', '')
cts = os.environ.get('COMPLETION_TS', '')
chosen = 'unclassified'
try:
    rows = []
    if os.path.exists(mf):
        with open(mf, encoding='utf-8') as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    r = json.loads(line)
                except Exception:
                    continue
                if isinstance(r, dict) and r.get('ts') and r.get('task_type'):
                    rows.append((r['ts'], r['task_type']))
    rows.sort(key=lambda x: x[0])          # ISO8601 sorts lexicographically
    for ts, tt in rows:
        if ts <= cts:
            chosen = tt
        else:
            break
except Exception:
    chosen = 'unclassified'
print(chosen)
PY
```
(For performance, read+sort markers ONCE per session, not per completion — pass the completion ts in and bisect, or cache the sorted list in a temp file like report.sh already does for msg metadata at lines 305-319.)

### Pattern 2: write-marker.sh (D-03)
**What:** Validate `<task_type>` against `task-taxonomy.json`, resolve current sid, append `{"ts","task_type"}` with flock.
**Example shape (port from Hermes write_marker snippet, simplify to bash + python heredoc):**
```bash
# Source: adapted from ../hermes-revenium/.../references/task-classification.md write_marker
# write-marker.sh <task_type>
TASK_TYPE="$1" TAXONOMY_FILE="${STATE_DIR}/task-taxonomy.json" \
MARKERS_DIR="${STATE_DIR}/markers" SESSIONS_DIR="${OPENCLAW_HOME}/agents/main/sessions" \
python3 - <<'PY'
import json, os, time, fcntl
tt = os.environ['TASK_TYPE']
tax = os.environ['TAXONOMY_FILE']
labels = set(json.load(open(tax)).get('labels', {}))     # validate
if tt not in labels:
    raise SystemExit(f"unknown task_type: {tt}")
# resolve current sid: newest non-cron *.jsonl in SESSIONS_DIR (mirror Hermes "newest session" heuristic)
sd = os.environ['SESSIONS_DIR']
cands = [f for f in os.listdir(sd) if f.endswith('.jsonl')]
sid = max(cands, key=lambda f: os.path.getmtime(os.path.join(sd, f)))[:-len('.jsonl')] if cands else f"pseudo-{int(time.time())}"
md = os.environ['MARKERS_DIR']; os.makedirs(md, mode=0o700, exist_ok=True)
mp = os.path.join(md, f"{sid}.jsonl")
rec = {"ts": time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), "task_type": tt}
with open(mp, "ab", buffering=0) as f:
    fcntl.flock(f, fcntl.LOCK_EX)
    f.write((json.dumps(rec, separators=(",",":")) + "\n").encode())
print(f"marker written: {mp}")
PY
```
**NOTE on sid resolution:** the "newest session file" heuristic is what Hermes uses (write_marker snippet, references/task-classification.md:44-61). OpenClaw's marker `ts` should be ISO8601 to sort identically to completion timestamps for Pattern 1 (Hermes uses unix float; D-01/specifics say ISO8601 marker — use ISO8601 for OpenClaw so the precedence comparison is a direct string compare against report.sh's `timestamp`).

### Pattern 3: `--agent` wiring (D-07)
```bash
# report.sh post_to_revenium: replace line 221
#   --agent "OpenClaw"
# with (root_sid resolved once per session before the line loop):
  --agent "${REVENIUM_AGENT_PREFIX}${root_sid}"   # REVENIUM_AGENT_PREFIX="openclaw-"
```
Add to common.sh alongside existing `REVENIUM_AGENT_NAME` (keep both; prefix is the metering/filter scheme, name is retained for backward reference):
```bash
REVENIUM_AGENT_PREFIX="${REVENIUM_AGENT_PREFIX:-openclaw-}"
```

### Pattern 4: per-task-type picker (D-10) — base + TASK_TYPE filter
Port Hermes picker (setup-guardrails.sh:700-797) BUT each per-task `create_rule` must add `--filter TASK_TYPE:IS:<label>` on top of the base `AGENT:STARTS_WITH:openclaw-` filter, and `--group-by TASK_TYPE`. The Hermes picker does NOT do this (Pitfall 4) — it calls `create_rule` which only emits the base AGENT filter, so every per-task rule is identical. The OpenClaw port must parameterize the extra filter.

### Anti-Patterns to Avoid
- **Porting `equal_split` / `split_strategies.py`:** Hermes' window-equal-split is an artifact of its coarse windowing. OpenClaw's per-line loop has real timestamps — use precedence (Pattern 1).
- **Porting jobs / `--agentic-job-id`:** explicitly out of scope (CONTEXT deferred). Drop all `m_owning_job_*`, `JOBS_CLI_CAPABLE`, `root_aid` logic from hermes-report.sh.
- **Using `parentId` for session parentage:** it is an intra-session message pointer, not session lineage.
- **Trusting `sessions.json` for resolution:** it is rotated/pruned and omits most sessions.
- **Auto-rewriting legacy rules (D-08):** detect + notify only; never silently mutate user rules (honors Phase 3 D-02).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Root-session walk | A new traversal model | Adapt Hermes `get-root-session-id.py` contract (max_depth, fail-open, never-raise) | The invariants are subtle (cycle guard, error paths); reuse the proven shape |
| Marker append concurrency | Naive `>>` echo | `fcntl.flock` + `O_APPEND` (Hermes write_marker) | Concurrent turns/cron can interleave; POSIX append + flock is the belt-and-suspenders pattern |
| Atomic config/status writes | In-place rewrite | temp-then-`os.replace` (Phase 3 PATTERNS "Atomic JSON Write") | Crash-safety; established project pattern |
| Taxonomy validation | Inline string list in write-marker | Read `task-taxonomy.json` labels | Single source of truth; picker reads same file |
| Provider/model/stop-reason mapping | Re-derive | report.sh already has `get_provider`, `clean_model_name`, `map_stop_reason` | Reuse existing helpers verbatim |

**Key insight:** Almost everything except the JSONL resolver and the timestamp-precedence correlation is a verbatim or near-verbatim port from Hermes — the value here is identifying the *two* places OpenClaw must diverge (resolver source, correlation strategy) and the *one* Hermes bug to fix (picker filter).

## Runtime State Inventory

> Phase 4 adds new runtime state and changes the `--agent` wire value, which interacts with existing Revenium-side rule state. Inventory below.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | NEW: `~/.openclaw/skills/revenium/markers/<sid>.jsonl` (per-session marker logs). NEW: `~/.openclaw/skills/revenium/task-taxonomy.json`. Existing `revenium-offsets.json`, `revenium-reported.ledger` unaffected (no schema change needed for task-type — it's read from markers, not stored in the ledger). | Create markers dir (mode 0700); seed taxonomy in post-install.sh; prune markers in cron (D-04) |
| Live service config (Revenium-side, NOT in git) | **Phase 3 budget rules created with `--filter AGENT:IS:OpenClaw` live on the Revenium server.** Changing report.sh to ship `--agent "openclaw-<root>"` means those rules **stop matching any completion** (D-08). The rules exist server-side; git/config.json only stores their `ruleIds`. | D-08: detect legacy `AGENT:IS:OpenClaw` rules (live `budget-rules list`/`enforcement-rules get` filter inspection OR a `config.json` schema-version marker) and surface a one-time reconfigure notice. NO auto-rewrite. |
| OS-registered state | cron entry unchanged (same `cron.sh` invocation). No new cron entries (D-04 prune is a stage inside cron.sh). | None |
| Secrets / env vars | None new. `REVENIUM_AGENT_PREFIX` is a code constant, not a secret. | None |
| Build artifacts | None — no packaging/egg-info; scripts are copied by post-install.sh. New scripts (`write-marker.sh`, `get-root-session-id.py`) must be added to post-install.sh chmod loop (mirror Phase 3 PATTERNS Change 1). | Add new script names to post-install.sh chmod list |

**The canonical question — after every file is updated, what runtime systems still carry the old `--agent "OpenClaw"` value?** Answer: the **Revenium-side budget rules created in Phase 3** filter on `AGENT:IS:OpenClaw`. They are the single piece of stale runtime state and are exactly what D-08's legacy-detection-and-notify addresses. There is no way to fix them by editing repo files — the user must reconfigure (or the rule must be recreated with the new filter).

## Common Pitfalls

### Pitfall 1: Shipping `--agent "openclaw-{root}"` silently orphans Phase 3 rules
**What goes wrong:** Existing rules filter `AGENT:IS:OpenClaw`; new completions carry `openclaw-<sid>`. The rules match nothing → currentValue stuck at 0 → enforcement silently dead.
**Why it happens:** The agent-name scheme change (D-07) is a wire-incompatible break with Phase 3 D-23.
**How to avoid:** D-08 legacy detection + one-time notice. Base filter must be `AGENT:STARTS_WITH:openclaw-` so BOTH `openclaw-<root>` and the `openclaw-<sid>` fallback match.
**Warning signs:** Revenium dashboard shows $0 spend on existing rules after upgrade despite active sessions.

### Pitfall 2: Marker `ts` format mismatch breaks timestamp precedence
**What goes wrong:** If markers store unix-float `ts` (Hermes style) but report.sh compares against ISO8601 completion `timestamp`, the comparison is meaningless.
**How to avoid:** Store marker `ts` as ISO8601 UTC (`%Y-%m-%dT%H:%M:%SZ`) so `marker.ts <= completion.timestamp` is a correct lexicographic string compare (specifics confirm ISO8601 marker shape).
**Warning signs:** All completions tagged `unclassified` despite markers existing, or wrong labels.

### Pitfall 3: Resolving root per-completion-line blows the cron budget
**What goes wrong:** Calling the Python resolver sidecar for every assistant message = N python3 cold-starts per session per tick.
**How to avoid:** Resolve `root_sid` ONCE per session file before the line loop (mirror hermes-report.sh:196-202). Pre-filter with `grep -l '"sessions_spawn"'` so the common (no-subagent) case builds an empty map instantly.

### Pitfall 4: Hermes picker creates identical per-task rules (latent bug)
**What goes wrong:** Hermes' picker (setup-guardrails.sh:700-797) calls `create_rule "$name" ...` which emits only the module-level base filter — every "per-task" rule ends up with the SAME filter and no TASK_TYPE scoping.
**How to avoid:** The OpenClaw port must add `--filter TASK_TYPE:IS:<label>` (plus `--group-by TASK_TYPE`) for each per-task rule. Parameterize `create_rule` to accept an extra filter, or build the per-task cmd inline.
**Warning signs:** All per-task rules report aggregate spend identical to the base rule.

### Pitfall 5: write-marker.sh sid resolution picks the cron session
**What goes wrong:** The "newest *.jsonl" heuristic could select a cron-generated session file instead of the interactive one.
**How to avoid:** Mirror Hermes' exclusion of cron sessions. In OpenClaw, cron sessions are keyed `agent:main:cron:*` in `sessions.json`; the marker writer runs in the agent's interactive context — the agent's own session is the most-recently-written interactive file. Consider excluding files whose `sessions.json` key is `agent:main:cron:*`, or accept the newest-file heuristic and rely on the fact that `write-marker.sh` runs synchronously inside the active turn (its own session is the freshest). Validate during planning with a worked example.
**Warning signs:** Markers landing in a cron session's marker file.

### Pitfall 6: Forgetting `task-taxonomy.json` lives in TWO places conceptually
**What goes wrong:** Hermes has a seed (`skills/.../task-taxonomy.json`) and a live mutable copy (`~/.hermes/state/revenium/...`). OpenClaw collapses skill dir and state dir into one (`~/.openclaw/skills/revenium/`), so there is ONE path. Don't port Hermes' seed-vs-live two-path logic.
**How to avoid:** Single path `${STATE_DIR}/task-taxonomy.json`; post-install.sh seeds it; write-marker.sh + picker read it.

## Code Examples

### Resolver sidecar skeleton (adapt from Hermes get-root-session-id.py)
```python
# Source: adapted from ../hermes-revenium/skills/revenium/scripts/get-root-session-id.py
# get-root-session-id.py <sid>  — JSONL childSessionKey reverse walk, fail-open
import json, os, sys
from pathlib import Path

def get_root_session_id(sid, sessions_dir=None, max_depth=10):
    if not sid:
        return sid
    sessions_dir = sessions_dir or os.path.join(
        os.environ.get("OPENCLAW_HOME", os.path.expanduser("~/.openclaw")),
        "agents", "main", "sessions")
    try:
        child_to_parent = {}
        for f in os.listdir(sessions_dir):
            if not f.endswith(".jsonl"):
                continue
            parent_sid = f[:-len(".jsonl")]
            fp = os.path.join(sessions_dir, f)
            try:
                with open(fp, encoding="utf-8") as fh:
                    for line in fh:
                        if '"sessions_spawn"' not in line:   # cheap pre-filter
                            continue
                        try:
                            o = json.loads(line)
                        except Exception:
                            continue
                        det = (o.get("message") or {}).get("details") or {}
                        ck = det.get("childSessionKey")
                        if ck:
                            child_to_parent[ck.rsplit(":", 1)[-1]] = parent_sid
            except OSError:
                continue
        current = sid
        for _ in range(max_depth):
            parent = child_to_parent.get(current)
            if parent is None:
                return current
            current = parent
        return current
    except Exception:
        return sid

if __name__ == "__main__":
    if len(sys.argv) < 2 or not sys.argv[1]:
        sys.exit(0)
    print(get_root_session_id(sys.argv[1]))
```

### common.sh resolver wrapper (adapt from Hermes common.sh:96-106)
```bash
# Source: adapted from ../hermes-revenium/skills/revenium/scripts/common.sh:96-106
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

### setup-guardrails.sh base-filter substitution (D-07)
```bash
# CURRENT (scripts/setup-guardrails.sh lines 270 and 289):
#   --filter "AGENT:IS:${REVENIUM_AGENT_NAME}"
# AFTER (D-07):
  --filter "AGENT:STARTS_WITH:${REVENIUM_AGENT_PREFIX}"   # openclaw-
```

## State of the Art

| Old Approach (Phase 3) | New Approach (Phase 4) | When Changed | Impact |
|------------------------|------------------------|--------------|--------|
| `--agent "OpenClaw"` (static) | `--agent "openclaw-<root_sid>"` | D-07 | Subagent rollup; breaks legacy rules (D-08) |
| `AGENT:IS:OpenClaw` filter | `AGENT:STARTS_WITH:openclaw-` | D-07 | Catches all session-scoped agents |
| No task attribution | `--task-type <label>` per completion | D-01/METER-03 | Per-task analytics + optional per-task budgets |
| (Hermes) SQLite `state.db` root walk | JSONL `childSessionKey` reverse scan | D-05 | OpenClaw has no state.db |
| (Hermes) window equal-split correlation | true timestamp-precedence | D-01 | report.sh has real per-line timestamps |

**Deprecated/outdated (do NOT port):**
- Hermes `split_strategies.equal_split` — replaced by timestamp precedence.
- Hermes jobs / `--agentic-job-id` / `job-taxonomy.json` / `kind:"job"` markers — out of scope.
- Hermes classifier plugin + `pre_llm_call`/`post_tool_call` hooks — deferred (agent-driven markers instead).
- Hermes two-path taxonomy (seed vs live) — OpenClaw has one collapsed path.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | OpenClaw persists subagent transcripts INLINE in the parent and does NOT write a separate `<child-sid>.jsonl` file | Root resolution | LOW — fail-open resolver is correct either way; only affects whether the resolver ever does real work. Based on 1 observed historical spawn + absence of child file/index. |
| A2 | `write-marker.sh` "newest session file" heuristic reliably picks the active interactive session | Pattern 2 / Pitfall 5 | MEDIUM — could mis-attribute to a cron session. Needs a worked example + possible `agent:main:cron:*` exclusion during planning. |
| A3 | Marker `ts` as ISO8601 sorts correctly against report.sh completion `timestamp` (both UTC `...Z`) | Pattern 1 / Pitfall 2 | LOW — both are ISO8601 UTC; verify report.sh timestamps are always `Z`-suffixed during planning. |
| A4 | Server-side, `--task-type` with no value defaults benignly (report.sh always sends `unclassified` so this is moot) | METER-03 | LOW — report.sh never omits the flag. |

## Open Questions

1. **Marker sid resolution robustness (A2).**
   - What we know: Hermes uses newest-non-cron session file; OpenClaw cron sessions are keyed `agent:main:cron:*` in `sessions.json`.
   - What's unclear: whether the active interactive session is always the freshest-mtime `.jsonl` at the instant `write-marker.sh` runs.
   - Recommendation: planner should add a worked-example test and consider reading `sessions.json` to exclude `agent:main:cron:*`-keyed files, OR pass the sid explicitly if SKILL.md/OpenClaw exposes it to the shell call.

2. **Whether OpenClaw exposes the current session id to shell tool calls.**
   - What we know: Hermes' `execute_code` gets no `HERMES_SESSION_ID`; it uses the file heuristic.
   - What's unclear: whether OpenClaw provides an env var (e.g. `OPENCLAW_SESSION_ID`) when running a `bash` tool call from within a turn — that would make `write-marker.sh` sid resolution deterministic.
   - Recommendation: probe during planning (`env | grep -i session` from inside an OpenClaw bash tool call). If present, prefer it over the heuristic.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `revenium` CLI | meter completion + budget-rules | ✓ | 1.1.2 (546e137) | none (skill gated on it) |
| `--task-type` flag | METER-03 | ✓ | present on 1.1.2 | always send `unclassified` (still requires flag) |
| `--agent` flag | TRACE-01 | ✓ | present on 1.1.2 | n/a |
| `TASK_TYPE` filter/group-by | D-10 picker | ✓ | present on 1.1.2 | skip picker gracefully (gate ships anyway) |
| `STARTS_WITH` operator | D-07 base filter | ✓ | present on 1.1.2 | n/a |
| `python3` | resolver, marker read/write | ✓ | system | n/a (fail-open echoes sid) |
| `jq` | report.sh JSONL parse | ✓ | system | report.sh already guards/exits |
| OpenClaw session JSONL | resolver + report.sh | ✓ | `~/.openclaw/agents/main/sessions/*.jsonl` | resolver fails open to sid |

**Missing dependencies with no fallback:** None.
**Missing dependencies with fallback:** None blocking — every path is fail-open by design (D-05/D-06).

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | bats-core preferred for bash scripts; pure-python `unittest` for the resolver sidecar (importable, mirrors Hermes' `get-root-session-id.py` test approach) |
| Config file | none currently — see Wave 0 |
| Quick run command | `bash scripts/<script>.sh` against a tmp fixture dir; `python3 -m pytest tests/ -x` if pytest adopted |
| Full suite command | run all script-level fixtures + resolver unit tests |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| METER-01 | taxonomy file present + 8 labels | unit | `python3 -c "import json,sys; d=json.load(open('task-taxonomy.json')); sys.exit(0 if set(d['labels'])>={'research','analysis','generation','review','code_review','refactor','planning','debugging'} else 1)"` | ❌ Wave 0 |
| METER-02 | write-marker.sh validates + appends; rejects unknown label | unit | `bash scripts/write-marker.sh research` against tmp STATE_DIR → assert marker line; `bash scripts/write-marker.sh bogus` → non-zero exit | ❌ Wave 0 |
| METER-03 | report.sh tags completion with preceding marker; defaults unclassified | integration | seed a session JSONL + marker fixture; run report.sh with a stubbed `revenium` capturing argv; assert `--task-type` value | ❌ Wave 0 |
| TRACE-01 | resolver returns root via childSessionKey; fails open to sid | unit | `python3 -m unittest` importing `get_root_session_id`; cases: no-parent→self, one-hop, cycle→depth-cap, missing-dir→sid | ❌ Wave 0 |
| TRACE-02 | report.sh ships `--agent openclaw-<root>` | integration | stubbed-revenium argv capture; assert `--agent` prefix `openclaw-` | ❌ Wave 0 |
| D-07/D-10 | base rule filter STARTS_WITH; per-task rule adds TASK_TYPE:IS | integration | stubbed `revenium guardrails budget-rules create` argv capture in `setup-guardrails.sh --interactive` with scripted stdin | ❌ Wave 0 |
| D-08 | legacy AGENT:IS:OpenClaw detection surfaces notice once | integration | seed config/rule fixture with legacy filter; assert one-time notice | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** run the unit test for the script touched (`write-marker.sh` test or resolver `unittest`) — < 5s.
- **Per wave merge:** full fixture suite (report.sh integration + setup-guardrails argv capture) with a stubbed `revenium` on PATH.
- **Phase gate:** full suite green; manual smoke: one real `revenium meter completion --dry-run --task-type research --agent openclaw-test ...` to confirm flag acceptance on 1.1.2.

### Wave 0 Gaps
- [ ] `tests/` harness directory + a stubbed `revenium` script (captures argv to a temp file) — reused by report.sh and setup-guardrails.sh integration tests.
- [ ] `tests/fixtures/sessions/` — sample parent JSONL with a `sessions_spawn` line + a plain session, for resolver + report.sh tests.
- [ ] `tests/test_get_root_session_id.py` — resolver unit tests (TRACE-01).
- [ ] bats or shell harness for `write-marker.sh` (METER-02) and report.sh argv capture (METER-03/TRACE-02).
- [ ] Framework install: adopt bats-core (`brew install bats-core`) OR keep pure-shell asserts — planner's discretion; resolver tests use stdlib `unittest` (no install).

## Security Domain

> `security_enforcement` not set in config.json — treat as enabled. Phase is local bash/Python over local files + an authenticated CLI; no network service authored here.

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | revenium API key handled by CLI config (Phase 2); not touched here |
| V3 Session Management | no | n/a |
| V4 Access Control | partial | markers dir created mode `0700` (Hermes pattern) — restrict to user |
| V5 Input Validation | yes | `write-marker.sh` validates `<task_type>` against taxonomy allowlist; reject otherwise. Per-task picker validates indices + hard-limit numeric (reuse `validate_hard_limit`). |
| V6 Cryptography | no | no crypto authored |

### Known Threat Patterns for bash/JSONL pipeline
| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Marker injection via crafted `task_type` (newlines/pipes corrupting downstream parse) | Tampering | Allowlist validation against taxonomy; `json.dumps` for marker write; sanitize control chars (Hermes WR-01 pattern, PATTERNS "Log Injection Mitigation") |
| Malformed JSONL crashing resolver/report (DoS of cron tick) | Denial of Service | try/except around every `json.loads`; fail-open (skip line / echo sid); never raise |
| Path traversal via sid in marker filename | Tampering | sid derives from session filenames (UUIDs) or `childSessionKey` UUID suffix — constrain to `[0-9a-f-]`; never accept arbitrary user sid into a path |
| Log injection via rule/marker names in log lines | Tampering | 64-char truncation (PATTERNS "Log Injection Mitigation") |
| Shell interpolation of `${VAR}` inside heredoc | Tampering / RCE | Env-passing heredoc discipline (PATTERNS) — never interpolate into `<<'PY'` |

## Sources

### Primary (HIGH confidence)
- `revenium meter completion --help` (revenium 1.1.2, 546e137) — `--task-type`, `--agent` confirmed [VERIFIED]
- `revenium guardrails budget-rules create --help` (1.1.2) — `TASK_TYPE` filter+group-by, `STARTS_WITH` operator confirmed [VERIFIED]
- `~/.openclaw/agents/main/sessions/*.jsonl` (live) — header shape, `sessions_spawn`/`childSessionKey` linkage, `parentId` semantics, absence of child file/index [VERIFIED]
- `~/.openclaw/agents/main/sessions/sessions.json` — key namespace, rotation/pruning, no subagent keys [VERIFIED]
- `../hermes-revenium/skills/revenium/task-taxonomy.json` — 8-label vocabulary [VERIFIED identical]
- `../hermes-revenium/skills/revenium/scripts/{get-root-session-id.py,common.sh,hermes-report.sh,setup-guardrails.sh}` — port sources [read directly]
- `../hermes-revenium/skills/revenium/{SKILL.md,references/task-classification.md}` — classification directive [read directly]
- `scripts/{report.sh,common.sh,setup-guardrails.sh,cron.sh}` (OpenClaw current) — modification targets [read directly]
- `.planning/phases/03-guardrail-engine/03-PATTERNS.md` — substitution map + shared patterns

### Secondary (MEDIUM confidence)
- Inference that subagent sessions are always inlined (A1) — based on single historical spawn + filesystem absence; fail-open design makes it immaterial.

### Tertiary (LOW confidence)
- None.

## Metadata

**Confidence breakdown:**
- Revenium CLI flag surface: HIGH — directly verified against installed 1.1.2.
- Root-session resolution mechanism: HIGH for JSONL shapes / no-SQLite / linkage location; MEDIUM for future-version subagent file persistence (mitigated by fail-open).
- Port surface (taxonomy, marker, picker, agent wiring): HIGH — all source + target files read directly.
- Correlation strategy divergence (precedence vs equal-split): HIGH — grounded in actual report.sh structure.
- Marker sid resolution robustness: MEDIUM — heuristic carries a mis-attribution risk (A2, Open Q1/2).

**Research date:** 2026-06-03
**Valid until:** 2026-07-03 (stable — revenium 1.1.2 pinned; OpenClaw session model is the main version-sensitive item)
