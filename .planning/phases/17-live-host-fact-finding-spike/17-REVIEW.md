---
phase: 17-live-host-fact-finding-spike
reviewed: 2026-09-24T17:02:31Z
depth: standard
files_reviewed: 35
files_reviewed_list:
  - .claude/skills/spike-findings-openclaw-revenium/SKILL.md
  - .claude/skills/spike-findings-openclaw-revenium/references/live-host-2-0-facts.md
  - .claude/skills/spike-findings-openclaw-revenium/sources/007-live-2-0-host-provisioning/README.md
  - .claude/skills/spike-findings-openclaw-revenium/sources/007-live-2-0-host-provisioning/provision-2-0-host.sh
  - .claude/skills/spike-findings-openclaw-revenium/sources/007-live-2-0-host-provisioning/provision-run.log
  - .claude/skills/spike-findings-openclaw-revenium/sources/007-live-2-0-host-provisioning/revenium-egress-check.txt
  - .claude/skills/spike-findings-openclaw-revenium/sources/007-live-2-0-host-provisioning/tracer-turn-readback.txt
  - .claude/skills/spike-findings-openclaw-revenium/sources/007-live-2-0-host-provisioning/versions-resolved.txt
  - .claude/skills/spike-findings-openclaw-revenium/sources/008-sqlite-session-read-path/README.md
  - .claude/skills/spike-findings-openclaw-revenium/sources/008-sqlite-session-read-path/cli-surface-output.txt
  - .claude/skills/spike-findings-openclaw-revenium/sources/008-sqlite-session-read-path/fidelity-matrix.md
  - .claude/skills/spike-findings-openclaw-revenium/sources/008-sqlite-session-read-path/probe-cli-surfaces.sh
  - .claude/skills/spike-findings-openclaw-revenium/sources/008-sqlite-session-read-path/probe-session-id-resolution.sh
  - .claude/skills/spike-findings-openclaw-revenium/sources/008-sqlite-session-read-path/probe-sidecar-plugin/index.js
  - .claude/skills/spike-findings-openclaw-revenium/sources/008-sqlite-session-read-path/probe-sidecar-plugin/openclaw.plugin.json
  - .claude/skills/spike-findings-openclaw-revenium/sources/008-sqlite-session-read-path/probe-sidecar-plugin/package.json
  - .claude/skills/spike-findings-openclaw-revenium/sources/008-sqlite-session-read-path/probe-sqlite-direct.sh
  - .claude/skills/spike-findings-openclaw-revenium/sources/008-sqlite-session-read-path/sample-rows.txt
  - .claude/skills/spike-findings-openclaw-revenium/sources/008-sqlite-session-read-path/schema-capture.sql.txt
  - .claude/skills/spike-findings-openclaw-revenium/sources/008-sqlite-session-read-path/session-id-resolution.txt
  - .claude/skills/spike-findings-openclaw-revenium/sources/008-sqlite-session-read-path/sidecar-capture.jsonl
  - .claude/skills/spike-findings-openclaw-revenium/sources/009-hook-firing-matrix-2-0/README.md
  - .claude/skills/spike-findings-openclaw-revenium/sources/009-hook-firing-matrix-2-0/hook-fire-log.txt
  - .claude/skills/spike-findings-openclaw-revenium/sources/009-hook-firing-matrix-2-0/hook-matrix.md
  - .claude/skills/spike-findings-openclaw-revenium/sources/009-hook-firing-matrix-2-0/probe-hook-observer/index.js
  - .claude/skills/spike-findings-openclaw-revenium/sources/009-hook-firing-matrix-2-0/probe-hook-observer/openclaw.plugin.json
  - .claude/skills/spike-findings-openclaw-revenium/sources/009-hook-firing-matrix-2-0/probe-hook-observer/package.json
  - .claude/skills/spike-findings-openclaw-revenium/sources/010-command-dispatch-tool-verdict/README.md
  - .claude/skills/spike-findings-openclaw-revenium/sources/010-command-dispatch-tool-verdict/dispatch-run.log
  - .claude/skills/spike-findings-openclaw-revenium/sources/010-command-dispatch-tool-verdict/probe-skill/SKILL.md
  - .claude/skills/spike-findings-openclaw-revenium/sources/011-read-path-concurrency-soak/README.md
  - .claude/skills/spike-findings-openclaw-revenium/sources/011-read-path-concurrency-soak/soak-log.txt
  - .claude/skills/spike-findings-openclaw-revenium/sources/011-read-path-concurrency-soak/soak-summary.md
  - .claude/skills/spike-findings-openclaw-revenium/sources/011-read-path-concurrency-soak/soak-tick.sh
  - CLAUDE.md
findings:
  critical: 0
  warning: 5
  info: 1
  total: 6
status: issues_found
---

# Phase 17: Code Review Report

**Reviewed:** 2026-09-24T17:02:31Z
**Depth:** standard
**Files Reviewed:** 35
**Status:** issues_found

## Summary

Phase 17 is a live-host fact-finding spike, not production code — `plugin/`, `plugin-nemoclaw/`,
and `scripts/` are correctly untouched, and every determination in `SKILL.md` /
`references/live-host-2-0-facts.md` / the five spike `README.md`s is written with unusually
careful hedging: unrun sandbox cells are consistently labelled `UNRUN`/`NOT RUN` rather than
inferred, forced into a PARTIAL, or silently promoted to a pass, exactly per the phase's own
prohibition and `17-SANDBOX-BLOCKER.md`. Credential discipline (T-17-01) holds throughout: every
credential-touching command sources `~/.spike-17.env` host-side via `set -a; . ...; set +a`
immediately before use, no key is ever inlined into a logged command string, and the regex scan
for literal key material found nothing (confirmed, not re-reported here).

The issues below are all real, provable defects, but none rise to Critical: no credential leak
mechanism, no injection vulnerability, and no destructive/unsafe use of the live SQLite stores was
found (every read is `mode=ro` + `PRAGMA busy_timeout`, and the two probe plugins are fail-open
try/catch wrapped). What *was* found is (a) one case where a piece of committed evidence overclaims
a result beyond what was actually tested — exactly the class of defect this phase exists to guard
against, even though it doesn't touch the canonical determination — and (b) a small cluster of
correctness/consistency bugs in the throwaway probe scripts that are minor in isolation but would
mislead a future engineer who reuses this code as a starting point in Phase 19/22, which the skill's
own `## Requirements / build guidance` sections explicitly invite.

## Warnings

### WR-01: `cli-surface-output.txt`'s summary table overclaims session-parentage fidelity for `export-trajectory`

**File:** `.claude/skills/spike-findings-openclaw-revenium/sources/008-sqlite-session-read-path/cli-surface-output.txt:258`
**Issue:** The file's closing "Per-surface summary" table states:

```
export-trajectory:                ALL FOUR fields, full fidelity, confirmed live —
                                  succeeded unattended/non-TTY with no approval gate on a
                                  healthy store (HOST-LOCAL); inconclusive on the
                                  contended SANDBOX store this run.
```

The four D-02 fields are token usage, model id, toolCalls, and **session parentage** (established
in this same file's header and in `fidelity-matrix.md`). But this file's own detailed verdict for
the same surface, 120 lines earlier, lists only three fields as confirmed and says nothing about
parentage:

```
138: FIDELITY VERDICT vs D-02 fields: RECOVERABLE, full fidelity, matching candidate (a)
139:   exactly — per-completion token usage (both per-call and aggregate), model id
140:   (provider+model+responseModel), toolCalls (name, arguments, result, error via isError/
141:   exitCode, duration via durationMs) all present and joinable. ...
```

`README.md` and `fidelity-matrix.md` (the canonical determination documents this file is cited as
evidence for) both state plainly that candidate (b)'s parentage fidelity was **never graded**:
`session-branch.json`'s content was never inspected. So the "ALL FOUR fields... confirmed live"
line in the summary table is not supported by this spike's own evidence — it is exactly the
"unrun presented as run" failure mode `17-SANDBOX-BLOCKER.md` and the phase's own binding warn
against, just inside a raw evidence file rather than the canonical README. The canonical
determination (`README.md`/`fidelity-matrix.md`) is correct, so this does not currently mislead
Phase 19 if it reads the README — but a reader who cites `cli-surface-output.txt` directly (as
`fidelity-matrix.md`'s own "Evidence" column does) would land on the wrong claim.
**Fix:** Correct the summary line to scope it to the three fields actually graded, e.g.:
```
export-trajectory:                usage + model id + toolCalls: full fidelity, confirmed live
                                  (unattended/non-TTY, no approval gate, HOST-LOCAL). Session
                                  parentage: NOT GRADED — session-branch.json content was not
                                  inspected (see README.md ## Results §1).
```

### WR-02: `probe-sidecar-plugin/index.js` captures the raw tool-call error, not a flag, contradicting its own stated scope

**File:** `.claude/skills/spike-findings-openclaw-revenium/sources/008-sqlite-session-read-path/probe-sidecar-plugin/index.js:90`
**Issue:** The file's own header comment (lines 30–34) and every downstream evidence document
(`README.md`, `fidelity-matrix.md`, `cli-surface-output.txt`'s sibling file) describe this plugin's
`after_tool_call` capture as recording "only structural/metadata fields... (name, id, presence-of-
result, error flag, duration)". The code, however, captures the raw value:
```javascript
89:        hasResult: event?.result !== undefined,
90:        error: event?.error,
91:        durationMs: event?.durationMs,
```
`event.error` is not a boolean flag — it is whatever the OpenClaw runtime passes for a failed tool
call, which for an `exec`/`terminal` tool can plausibly include the failing command's stderr or
output text (i.e. exactly the tool "result content" this probe's own documented scope, and T-17-05,
say must never be captured). The near-identical sibling plugin written one spike later
(`009-hook-firing-matrix-2-0/probe-hook-observer/index.js:163`) gets this right:
`hasError: event?.error !== undefined`. In this run the field happened to be `undefined` on every
captured record (see `sidecar-capture.jsonl`), so nothing sensitive actually leaked into the
committed evidence — but the mechanism itself does not match its documented intent, and this file
is exactly the kind of "proven shape" future plugins (including in Phase 19) are told to mirror.
**Fix:**
```javascript
hasResult: event?.result !== undefined,
hasError: event?.error !== undefined,
durationMs: event?.durationMs,
```

### WR-03: `provision-2-0-host.sh` reintroduces the Node-shadowing PATH bug its own Finding 2 fixed

**File:** `.claude/skills/spike-findings-openclaw-revenium/sources/007-live-2-0-host-provisioning/provision-2-0-host.sh:289`
**Issue:** `README.md`'s Finding 2 and the "Reusable Facts" section explicitly document the fix for
a real live-host bug: `~/.local/bin/node` is a pre-existing, unrelated Hermes-bundled Node v22.23.2
symlink on this host, and the script must never let `~/.local/bin` resolve ahead of the real
system/npm-global Node. The documented, verified-safe ordering is "system paths first, `.local/bin`
last": `PATH="$HOME/.npm-global/bin:$PATH:$HOME/.local/bin"`. The script's own NemoClaw-install
branch does the opposite:
```bash
288:    )
289:    export PATH="$HOME/.local/bin:$PATH"
290:    hash -r 2>/dev/null || true
```
This prepends `~/.local/bin` ahead of everything, including `~/.npm-global/bin` set at line 136 —
exactly the ordering Finding 2 says causes `command -v node` to resolve the wrong binary. It has no
observed effect in this run only because no host-side `node`/`openclaw` call happens later in the
script; any future addition after this line, or reuse of this snippet elsewhere (which the skill's
own guidance invites for Phase 22), would silently reintroduce the bug this file claims to have
fixed.
**Fix:**
```bash
export PATH="$HOME/.npm-global/bin:$PATH:$HOME/.local/bin"
```

### WR-04: `record_version()` in `provision-2-0-host.sh` appends unconditionally, so re-runs accumulate stale/duplicate version records

**File:** `.claude/skills/spike-findings-openclaw-revenium/sources/007-live-2-0-host-provisioning/provision-2-0-host.sh:79-83`
**Issue:**
```bash
79: record_version() {
80:   # record_version PREFIX LABEL VALUE — appends "prefix: LABEL=VALUE"-shaped line
81:   local prefix="$1" label="$2" value="$3"
82:   printf '%s: %s=%s\n' "$prefix" "$label" "$value" >> "$VERSIONS_FILE"
83: }
```
`record_version` is called unconditionally every run (e.g. line 163's `record_version "standalone"
"openclaw" "$OPENCLAW_VERSION"` executes whether or not an install actually happened), always in
append mode, with no timestamp per line and no truncation of `$VERSIONS_FILE` at script start. The
script is explicitly framed as safe to re-run any number of times (D-14), and the two production
paths' versions genuinely can change between runs (e.g. after an upgrade) — but the resulting log
file has no way to distinguish "current" from "stale" once it contains more than one run's output
for the same key, since duplicate `prefix: label=value` lines are indistinguishable without an
external diff against git history. The single committed `versions-resolved.txt` happens to show
only one line per key because it was evidently captured/reset outside the script's own logic, not
because the script guarantees that.
**Fix:** Truncate at the top of the run and/or add a timestamp per line, e.g.:
```bash
: > "$VERSIONS_FILE"   # at script start, once, before any record_version call
# or:
printf '%s: %s=%s ts=%s\n' "$prefix" "$label" "$value" "$(date -u +%FT%TZ)" >> "$VERSIONS_FILE"
```

### WR-05: sqlite3's PRAGMA-echo quirk (discovered in spike 011) silently pollutes `probe-sqlite-direct.sh`'s table count and the "60 real table names" claim in spike 007

**File:** `.claude/skills/spike-findings-openclaw-revenium/sources/008-sqlite-session-read-path/probe-sqlite-direct.sh:60`; also `.claude/skills/spike-findings-openclaw-revenium/sources/007-live-2-0-host-provisioning/README.md:66`
**Issue:** Spike 011 discovered and documented (`soak-tick.sh` comment, lines 69–73) that this
host's `sqlite3 -cmd "PRAGMA busy_timeout=5000;" ...` batch mode echoes the PRAGMA setter's own
value ("5000") as its own output line ahead of the actual query/dot-command result — visible
directly in the committed evidence, e.g. `schema-capture.sql.txt:2` (a bare `5000` line
immediately before the first `CREATE TABLE`) and `tracer-turn-readback.txt:1`. `soak-tick.sh` was
fixed to take the *last* non-empty output line for exactly this reason. `probe-sqlite-direct.sh`'s
table-count step was never patched for the same quirk:
```bash
59:  echo "=== CELL ${label}: table count ==="
60:  run_ro "${db}" ".tables" | tr -s ' ' '\n' | grep -c .
```
Because `.tables` output is piped straight into `grep -c .` after whitespace-to-newline
normalization, the leading `5000` PRAGMA-echo line is counted as one extra "table," inflating the
reported count by at least one. `007/README.md`'s Investigation Trail item 8 ("`.tables` returned
60 real table names") was captured the same way, before this quirk was even discovered, and is
consequently unverified against it — the real count is plausibly 59, not 60. This is a minor,
non-load-bearing fact (no determination in this phase depends on the exact table count), but it is
exactly the kind of small, silently-wrong number a future reader could otherwise trust verbatim.
**Fix:** Apply the same "take the last non-empty line" (or filter out a bare-digits echo line)
discipline `soak-tick.sh` uses to every `-cmd`-prefixed invocation, including `.tables`/`.schema`:
```bash
run_ro "${db}" ".tables" | grep -v '^[0-9]\+$' | tr -s ' ' '\n' | grep -c .
```

## Info

### IN-01: `soak-tick.sh`'s `lock_errors` flag conflates any nonzero exit with a lock/busy error specifically

**File:** `.claude/skills/spike-findings-openclaw-revenium/sources/011-read-path-concurrency-soak/soak-tick.sh:80-83`
**Issue:**
```bash
80:  lock_errors=0
81:  if [[ ${rc} -ne 0 ]] || printf '%s' "${err_text}" | grep -qiE 'busy|locked'; then
82:    lock_errors=1
83:  fi
```
Any nonzero `sqlite3` exit code (e.g. the DB file missing, a permissions error, a corrupt/stale
SSHFS mount) is recorded as `lock_errors=1`, indistinguishable in `soak-log.txt` from an actual
`SQLITE_BUSY`/lock-contention event. This did not affect this soak's determination (all 62
HOST-LOCAL ticks had `rc=0`, so `lock_errors` and "any error" were equivalent in practice), but the
metric's name overstates its own specificity, and the intended SSHFS cell — which the skill's
`## Requirements / build guidance` says is a required pre-build step for Phase 19/22 — is exactly
the environment (network filesystem, more failure modes) where this conflation would matter.
**Fix:** Split into two counters, or narrow the error-text check to be the sole classifier:
```bash
lock_errors=0
other_errors=0
if printf '%s' "${err_text}" | grep -qiE 'busy|locked'; then
  lock_errors=1
elif [[ ${rc} -ne 0 ]]; then
  other_errors=1
fi
```

---
_Reviewed: 2026-09-24T17:02:31Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
