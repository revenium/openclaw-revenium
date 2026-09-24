# Phase 17: Live-Host Fact-Finding Spike - Pattern Map

**Mapped:** 2026-09-23
**Files analyzed:** 12 (this phase produces spike artifacts and skill/doc edits, not application code)
**Analogs found:** 12 / 12

## Phase-Shape Note

This phase is a fact-finding spike, not a code port (per CONTEXT.md domain statement and D-11).
There is no controller/service/model/etc. to classify in the usual sense. The "files" below are:
provisioning script, throwaway probe scripts, spike README determinations, MANIFEST rows, and
skill/CLAUDE.md doc edits. Every analog is a v1.4-era spike artifact that already established the
exact shape these files must follow — this phase should copy structure, not invent new structure.

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---|---|---|---|---|
| `.planning/spikes/007-<name>/provision-2-0-host.sh` | utility (provisioning script) | batch / idempotent shell | `.planning/spikes/001-nemoclaw-bootstrap/probe-host-compat.sh` | exact (named as precedent in CONTEXT.md D-11/D-14) |
| `.planning/spikes/008-<name>/probe-sqlite-direct.sh` | utility (throwaway probe) | file-I/O (read-only SQLite) | `.planning/spikes/001-nemoclaw-bootstrap/probe-host-compat.sh` | role-match (probe shape, not host-compat content) |
| `.planning/spikes/008-<name>/probe-cli-export.sh` | utility (throwaway probe) | request-response (CLI subcommand) | `.planning/spikes/004-background-metering-loop/revenium-mount-tick.sh` | role-match (host-side CLI-invocation probe) |
| `.planning/spikes/008-<name>/probe-sidecar-plugin/` | plugin (hook sidecar) | event-driven | `.planning/spikes/006-plugin-directive-injection/revenium-guard/` | exact (only existing plugin-hook artifact in the repo) |
| `.planning/spikes/008-<name>/schema-capture.sql.txt` | config/evidence (verbatim capture) | file-I/O | none (new artifact type) — see "No Analog Found" | n/a |
| `.planning/spikes/007-011/README.md` (5 determination docs) | test/evidence doc | request-response (verdict write-up) | `.planning/spikes/001-nemoclaw-bootstrap/README.md` and `.planning/spikes/006-plugin-directive-injection/README.md` | exact |
| `.planning/spikes/MANIFEST.md` (rows added, Requirements accrual) | config/index | CRUD (append rows) | `.planning/spikes/MANIFEST.md` itself (existing rows 001-006) | exact (same file, additive edit) |
| `.claude/skills/spike-findings-openclaw-revenium/SKILL.md` (description/index edit) | config (skill frontmatter + index) | CRUD (edit) | itself, current version | exact |
| `.claude/skills/spike-findings-openclaw-revenium/references/<new-topic>.md` | component (skill reference doc) | transform (raw findings → consumable topic doc) | `.claude/skills/spike-findings-openclaw-revenium/references/install-and-bootstrap.md` | exact |
| `CLAUDE.md` (routing line edit) | config (routing) | CRUD (edit) | itself, current single routing line | exact |

## Pattern Assignments

### `.planning/spikes/007-<name>/provision-2-0-host.sh` (utility, idempotent-batch)

**Analog:** `.planning/spikes/001-nemoclaw-bootstrap/probe-host-compat.sh`

**Header/intent comment pattern** (lines 1-16):
```bash
#!/usr/bin/env bash
# Spike 001 — NemoClaw bootstrap feasibility probe (NON-DESTRUCTIVE).
#
# Does NOT install anything, does NOT sudo, does NOT modify the system.
# It checks THIS host against NemoClaw's documented requirements and the
# real OS gating found in NVIDIA/NemoClaw scripts/install.sh, then prints a
# compatibility verdict so we know whether this host can be the spike target.
#
# Documented NemoClaw requirements (sources in README.md):
#   - Linux only (no macOS; Windows via WSL2 only)
#   ...
set -u
```
**Deviation required:** `provision-2-0-host.sh` is NOT non-destructive (D-14 requires it to actually
install/upgrade), so the header must say so explicitly and each step must be idempotent/detection-gated,
not a pure read-only check like this analog. Keep the doc-header-with-sources convention; drop the
"NON-DESTRUCTIVE" framing.

**Pass/warn/fail scaffolding worth reusing directly** (lines 18-22):
```bash
pass=0; warn=0; fail=0
line() { printf '%-34s %s\n' "$1" "$2"; }
ok()   { line "$1" "✓ $2"; pass=$((pass+1)); }
wn()   { line "$1" "⚠ $2"; warn=$((warn+1)); }
no()   { line "$1" "✗ $2"; fail=$((fail+1)); }
```
Reuse this exact accounting helper for each provisioning step's detection-check output — gives a
consistent per-step verdict line and a final summary, and composes with the "explicit refusal, never
silent no-op" project convention (RESEARCH.md `## Common Pitfalls` + CONVENTIONS.md's own installer
critique of NemoClaw's Darwin graceful-skip).

**Detection-then-act gating pattern** (lines 58-68, Docker check):
```bash
if command -v docker >/dev/null 2>&1; then
  if docker info >/dev/null 2>&1; then
    ok "Docker" "installed and daemon reachable ($(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,))"
  else
    wn "Docker" "installed but daemon not reachable"
  fi
elif [ "$OS" = "Linux" ]; then
  wn "Docker" "not installed (installer-recoverable on Linux)"
else
  no "Docker" "not installed"
fi
```
Apply this "check first, install only if the check says missing" shape to every SPIKE-00 floor
(Node `>=24.16`, Docker, NemoClaw `>=v0.0.128`, OpenClaw `>=2026.8.1`) — each becomes: detect version →
if floor met, `ok`; if absent, run the documented install command from RESEARCH.md `## Host Provisioning`
items 5/9/11; if present but below floor, `no` (explicit refusal per D-14's "gated on a detection check").

**Version-floor recording pattern to add (not in the analog, but required by D-15):** after each
install step, capture and print the exact resolved version string (e.g. `openclaw --version`,
`node --version`, `nemoclaw --version`) rather than assuming the floor was met — D-15 requires
recording exactly what resolved, not normalizing standalone vs. NemoClaw-managed OpenClaw versions
to match.

**Verdict/exit-code pattern** (lines 118-131):
```bash
echo "Summary: ${pass} pass, ${warn} warn, ${fail} fail"
if [ "$fail" -gt 0 ]; then
  echo "VERDICT: INCOMPATIBLE — ..."
  exit 1
elif [ "$warn" -gt 0 ]; then
  echo "VERDICT: USABLE WITH CAVEATS — review warnings above."
  exit 0
else
  echo "VERDICT: COMPATIBLE — ..."
  exit 0
fi
```
Reuse this verbatim as the script's final summary — it is also the natural evidence blob to paste
into the `007-.../README.md`'s Results section per D-12.

---

### `.planning/spikes/008-<name>/probe-sqlite-direct.sh` (utility, throwaway probe — file-I/O)

**Analog:** `.planning/spikes/001-nemoclaw-bootstrap/probe-host-compat.sh` (structure) + RESEARCH.md
`## Pattern 1: Read-only WAL-aware SQLite probing` (the concrete command).

**Core pattern** (RESEARCH.md Pattern 1 / Code Examples, verbatim command to run and paste as evidence):
```bash
sqlite3 "file:${HOME}/.openclaw/agents/main/agent/openclaw-agent.sqlite?mode=ro" \
  "PRAGMA busy_timeout=5000; .schema" | tee schema-capture.sql.txt
```
Keep this single-purpose, non-destructive, no retry-loop wrapper (RESEARCH.md `## Don't Hand-Roll`
explicitly warns against hand-rolled retry/backoff — you want to *see* `SQLITE_BUSY` if it occurs,
not paper over it). Mirror `probe-host-compat.sh`'s pattern of a short shebang + doc-comment header
naming the exact source (`sqlite.org/forum`, `sqlite/sqlite doc/wal-lock.md`) and what it does NOT do
(does not write, does not lock).

**Error handling:** none needed beyond letting `sqlite3` exit non-zero on failure — this is evidence
capture, not production code (D-11); do not add try/catch-style guards that would mask a real
`SQLITE_BUSY` finding.

---

### `.planning/spikes/008-<name>/probe-sidecar-plugin/` (plugin, event-driven)

**Analog:** `.planning/spikes/006-plugin-directive-injection/revenium-guard/`

**Core pattern — hook registration shape** (README.md lines 26-32, quoting the plugin's own source):
```js
// index.js: export default (api) => api.on("before_prompt_build", () => ({
//   prependContext: "<revenium-guard>…REVENIUM_GUARD_ACTIVE…</revenium-guard>"
// }))
```
For SPIKE-01(c)'s sidecar candidate, register `llm_output` and `after_tool_call` instead of
`before_prompt_build`, following the same `api.on(hookName, handler)` shape confirmed live in spike
006 and RESEARCH.md's Hook Catalog. Capture per-completion `usage` (from `llm_output`) and
result/error/duration (from `after_tool_call`) into an append-only file, mirroring this project's
existing `markers/*.jsonl` append pattern (RESEARCH.md `## Session Read Path`, candidate (c) note).

**Packaging requirements (hard-won in spike 006, MUST carry forward — this is the single most
concrete transferable finding from that spike):**
```
package.json: needs "type": "module", "main", and "openclaw.extensions": ["./index.js"]
openclaw.plugin.json: needs id/name/version, activation.onStartup, and a (possibly empty) configSchema
```
Omitting `configSchema` broke the whole `openclaw` CLI in spike 006 ("Could not start the CLI") — treat
this as a mandatory field, not optional.

**Install/trust pattern** (README.md lines 39-41, 65-66):
```bash
nemoclaw revenium-spike exec -- openclaw plugins install /sandbox/.openclaw/extensions/revenium-guard
nemoclaw revenium-spike exec -- openclaw plugins enable revenium-guard
nemoclaw revenium-spike recover            # restart gateway so onStartup hooks load
```
Critical prior finding to reuse as a checklist item, not rediscover: a hand-placed (uninstalled)
plugin loads but its hooks are **inert** — `openclaw plugins inspect` warns "loaded without
install/load-path provenance." Always go through `openclaw plugins install` for a real trust/provenance
record before testing hook firing.

**Known failure mode to watch for:** spike 006's hand-rolled plugin hung the turn once trusted+enabled
(root cause not isolated). D-01(c)'s probe should therefore prefer scaffolding from `openclaw plugins init`
or mirror the real `nemoclaw` plugin's compiled-ESM-from-TS shape rather than a hand-written stub,
per spike 006's own "Requirements / build guidance" section.

---

### `.planning/spikes/007–011/README.md` (5 determination docs)

**Analog:** `.planning/spikes/001-nemoclaw-bootstrap/README.md` (VALIDATED example) and
`.planning/spikes/006-plugin-directive-injection/README.md` (PARTIAL example) — both established by
`.planning/spikes/CONVENTIONS.md`'s referenced format.

**Frontmatter pattern** (both analogs, lines 1-10):
```yaml
---
spike: 001
name: nemoclaw-bootstrap
type: standard
validates: "Given <precondition>, when <action>, then <outcome>"
verdict: VALIDATED
related: []
tags: [infra, install, nemoclaw, openshell]
host: "34.224.27.67 (Ubuntu 26.04 LTS, x86_64, no GPU)"
---
```
For 007-011, set `host: "52.90.9.242 (bare Ubuntu 26.04)"` and use a `verdict` value from
`VALIDATED / PARTIAL / INVALIDATED` (three-state, per the analogs) EXCEPT SPIKE-03, where D-06 requires
a strictly binary written verdict inside the body ("YES — deterministic" / "NO — mechanism inapplicable"
or "NO — model-gated") even though the frontmatter field itself may still read PARTIAL/VALIDATED at the
spike-tracking level; the binary framing belongs in the `## Results` prose, not the frontmatter enum.

**Section skeleton** (both analogs' consistent structure):
```
# Spike NNN: <Title>
## What This Validates
## Research
## How to Run
## What to Expect          (001 only — optional)
## Investigation Trail
## Results
## Requirements / build guidance   (006 only — include when the spike changes downstream build guidance)
## Open follow-up                  (006 only — include when unresolved)
```

**Evidence-pasting pattern (D-12's exact-command + raw-output standard), from 001 lines 86-116:**
```
### Linux host (VALIDATED — full stack up, agent turn completed)
Provisioned Ubuntu 26.04 host. Sequence that worked (all non-interactive):
1. Added 8 GB swap ...
...
Result: `finalAssistantVisibleText: "SPIKE001_OK"`, `winnerModel: nvidia/nemotron-3-super-120b-a12b`,
`result: success`, `fallbackUsed: false`. **A real end-to-end turn completed.**
```
Every claim in 007-011 must follow this same command → verbatim-output → interpretation triplet,
plus (new requirement this phase, per D-12) the OpenClaw/NemoClaw/Node version in effect at the time,
since D-15 established the two paths will not match versions.

**"Reusable facts captured" closing section** (001 lines 133-158) — keep this pattern for 008/009's
README to hand Phase 19+ the load-bearing facts (schema field names, hook firing per model, session-id
resolution answer) in one scannable block rather than burying them in the Investigation Trail.

---

### `.planning/spikes/MANIFEST.md` (rows added)

**Analog:** the existing table itself.

**Row pattern** (MANIFEST.md, spike table):
```
| 001 | nemoclaw-bootstrap | standard | Given a clean host, when NemoClaw `install.sh` runs, then NemoClaw + OpenShell come up and an OpenClaw agent completes one turn | **VALIDATED** (Linux host 34.224.27.67; agent turn completed via Nemotron). INVALIDATED on macOS. | infra, install, nemoclaw, openshell |
```
Append rows for 007-011 in the same `| # | Name | Type | Validates | Verdict | Tags |` shape, continuing
the numbering from 006. Per D-09/CONTEXT.md Claude's Discretion, also update the "## Requirements"
prose block above the table if a new non-negotiable constraint is discovered (matching how the existing
block accrues bullets like "The parallel install path MUST ship + apply a `revenium` network-policy
preset…" — one bullet per hard constraint, not per finding).

---

### `.claude/skills/spike-findings-openclaw-revenium/SKILL.md` (re-scope edit)

**Analog:** the file's own current version.

**Frontmatter description to broaden** (current, lines 1-4):
```yaml
---
name: spike-findings-openclaw-revenium
description: Implementation blueprint from spike experiments for adding optional NemoClaw/OpenShell support to the Revenium OpenClaw skill. Requirements, proven patterns, and verified knowledge. Auto-load during NemoClaw/OpenShell implementation work.
---
```
Per D-10, broaden to cover whole-project live-host findings (not just NemoClaw/OpenShell), e.g. widen
the scope clause to "...and for live-host verification of OpenClaw 2.0 session storage, plugin hooks,
and command-dispatch behavior..." — keep the same frontmatter shape (`name` + single `description`
string), just extend the sentence.

**`<findings_index>` table pattern to extend** (current lines 31-39):
```
| Area | Reference | Key Finding |
|------|-----------|-------------|
| Install & bootstrap | references/install-and-bootstrap.md | Linux-only; non-interactive env-var install; ... |
```
Add one new row for the new topic file (see next section) following the exact `| Area | Reference |
Key Finding |` shape — one row, one sentence of key finding, matching the terseness of the existing four.

**Spike verdicts table pattern to extend** (current lines 43-50) — append rows 007-011 mirroring the
`| # | Spike | Verdict |` shape already used for 001-006.

**`<metadata>` Processed Spikes list** (current lines 58-65) — append `007-...` through `011-...` entries.

---

### `.claude/skills/spike-findings-openclaw-revenium/references/<new-topic>.md` (new topic file, D-10)

**Analog:** `.claude/skills/spike-findings-openclaw-revenium/references/install-and-bootstrap.md`

**Section skeleton** (full file, 47 lines):
```
# <Topic Title>

## Requirements
- ...

## How to Build It
1. ...

## What to Avoid
- ...

## Constraints
- ...

## Origin

Synthesized from spike: <NNN>[, <NNN>...]. Sources: `sources/<NNN>-<name>/`.
```
This project's reference files are split by topic (install, egress, CLI/metering, skill deploy), each
distilling one or more numbered spikes into build guidance with a terminal "Origin" attribution line.
The new topic file (per D-10, one new file — e.g. `session-read-path.md` or `live-host-2-0-facts.md`
covering SPIKE-01..04's determinations as one cohesive topic, since they share the single live host and
gate the same downstream phases) should follow this exact skeleton: Requirements (the locked
constraints, e.g. D-01/D-02's ranking criteria and the chosen read mechanism), How to Build It (the
winning mechanism's concrete recipe), What to Avoid (the ruled-out candidates and why — `sessions tail`'s
redaction, `export-trajectory`'s approval-gate risk), Constraints (version floors, both-pairing caveat),
Origin (`Synthesized from spike: 007, 008, 009, 010, 011.`).

**Note on `sources/` mirror directory:** the existing skill keeps a `sources/` subdirectory of
preserved original spike artifacts (per SKILL.md's closing "Source Files" note: "Original spike source
files ... preserved in `sources/`"). Confirm whether 007-011's probe scripts/READMEs should be
mirrored into `.claude/skills/spike-findings-openclaw-revenium/sources/` the same way 001-006 were —
this mirrors the git-tracked skill's own `sources/`, not a build artifact, so it is safe to populate
directly (unlike the `.gsd/capabilities/*` mirror class the tracked-source gate warns about elsewhere).

---

### `CLAUDE.md` (routing line edit)

**Analog:** the file's own current single line.

**Current routing line:**
```markdown
- **Spike findings for openclaw-revenium** (NemoClaw/OpenShell support — implementation patterns, constraints, gotchas) → `Skill("spike-findings-openclaw-revenium")`
```
Per D-10, broaden the parenthetical to reflect the re-scoped skill, e.g.:
```markdown
- **Spike findings for openclaw-revenium** (NemoClaw/OpenShell support + live-host OpenClaw 2.0 verification — implementation patterns, constraints, gotchas) → `Skill("spike-findings-openclaw-revenium")`
```
Keep the exact `- **<label>** (<parenthetical>) → \`Skill("<name>")\`` shape — this is the only routing
line in the file and the only established pattern for it.

## Shared Patterns

### Explicit refusal, never silent no-op
**Source:** `.planning/spikes/001-nemoclaw-bootstrap/probe-host-compat.sh` lines 121-131 (VERDICT/exit-code
block) + RESEARCH.md `## Host Provisioning` item's framing of NemoClaw's own Darwin graceful-skip as a
documented anti-pattern.
**Apply to:** `provision-2-0-host.sh` — every version-floor check must hard-fail (non-zero exit, explicit
`no`/FAIL line) when unmet, never silently continue as if the floor were satisfied.

### Evidence standard (D-12)
**Source:** D-12 (CONTEXT.md) + `.planning/spikes/001-nemoclaw-bootstrap/README.md`'s "Non-interactive
install recipe (validated)" and "Linux host (VALIDATED...)" blocks.
**Apply to:** every one of the five 007-011 README.md files — exact command, raw trimmed-not-paraphrased
output, host, date, and OpenClaw/NemoClaw/Node versions in effect, for every claim.

### Host-side, never per-tick `nemoclaw exec`
**Source:** `.planning/spikes/004-background-metering-loop/revenium-mount-tick.sh` + CONVENTIONS.md
"Metering loop (spike 004)" section.
**Apply to:** SPIKE-04's soak harness and any NemoClaw-path probe in SPIKE-01/02 — read via `share mount`
+ host-side cron, not synchronous `nemoclaw exec` polling (hang-prone, accumulates hung host processes).

### `pkill` self-match hazard over SSH
**Source:** CONVENTIONS.md "## Operational hazards".
**Apply to:** any probe/soak script that needs to kill a stray process on the spike host — use
`ps | grep | awk | xargs kill` filtered on `node`, never `pkill -f "<pattern>"` (drops the SSH session,
exit 255, false-negative "cleanup failed" reading).

## No Analog Found

| File | Role | Data Flow | Reason |
|---|---|---|---|
| `.planning/spikes/008-<name>/schema-capture.sql.txt` | evidence/config | file-I/O | No prior spike captured a verbatim schema dump this way — v1.4 spikes captured CLI output and YAML policy files, not raw `.schema` text. Follow RESEARCH.md `## Pattern 1` and `## Code Examples` (`sqlite3 ... .schema | tee schema-capture.sql.txt`) directly; no codebase analog exists because this is the first SQL-schema-owning artifact in the project. |
| `.planning/spikes/010-<name>/` scope-check skill fragment (Pattern 2, `command-dispatch: tool` probe) | config (throwaway SKILL.md frontmatter fragment) | request-response | No existing skill in this repo uses `command-dispatch: tool` / `command-tool` / `command-arg-mode` — these are 2.0-era fields absent from the current production `SKILL.md` files. Build directly from RESEARCH.md `## Pattern 2` (the YAML frontmatter fragment shown there) as a throwaway test skill, not from an existing analog. |

## Metadata

**Analog search scope:** `.planning/spikes/` (all 6 existing spike dirs + CONVENTIONS.md + MANIFEST.md),
`.claude/skills/spike-findings-openclaw-revenium/` (SKILL.md + all 4 references/*.md), `CLAUDE.md`,
`scripts/report.sh`, `scripts/write-marker.sh`, `scripts/verify-markers.sh` (session-id resolution
excerpts, for SPIKE-01/D-03 context only — not files this phase modifies).
**Files scanned:** 6 spike READMEs/scripts (001-006), CONVENTIONS.md, MANIFEST.md, SKILL.md, 1 of 4
reference topic files (representative), CLAUDE.md, 3 scripts consumer-side.
**Pattern extraction date:** 2026-09-23
