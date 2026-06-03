---
phase: 03-guardrail-engine
reviewed: 2026-05-31T00:00:00Z
depth: standard
files_reviewed: 8
files_reviewed_list:
  - BUDGET-GUARD.md
  - SKILL.md
  - scripts/common.sh
  - scripts/guardrail-check.sh
  - scripts/setup-guardrails.sh
  - scripts/cron.sh
  - scripts/post-install.sh
  - scripts/clear-halt.sh
findings:
  critical: 2
  warning: 6
  info: 3
  total: 11
status: issues_found
---

# Phase 03: Code Review Report

**Reviewed:** 2026-05-31T00:00:00Z
**Depth:** standard
**Files Reviewed:** 8
**Status:** issues_found

## Summary

Reviewed the Phase 3 guardrail engine implementation: the halt-state management skill files (`BUDGET-GUARD.md`, `SKILL.md`), the shared shell library (`common.sh`), the cron-driven enforcement check (`guardrail-check.sh`), the interactive rule-creation script (`setup-guardrails.sh`), the cron runner (`cron.sh`), the installer (`post-install.sh`), and the operator-facing halt-clear script (`clear-halt.sh`).

The overall architecture is sound — atomic writes via temp-then-rename, fail-open preflight guards, Python-based JSON manipulation via env-passing to stay Bash 3.2 compatible, and separation of the halt decision from shadow-mode rules. However, two correctness defects were found that violate the stated design invariants, plus several quality issues that reduce robustness.

---

## Critical Issues

### CR-01: Stale `ruleIds` in `config.json` after recreate-path failure leaves guardrails silently disabled

**File:** `scripts/setup-guardrails.sh:479-593`

**Issue:** In `run_interactive()`, when the operator chooses `[r]ecreate`, the script deletes all existing Revenium rules (lines 493-495) and then attempts to create a new one (line 589). If `create_rule` fails, the script `exit 1`s — but `config.json` still contains the now-deleted `ruleIds`. The SKILL.md setup gate (`config.json` has a non-empty `ruleIds` array?) considers setup complete. The next time the agent starts, it reads stale rule IDs that no longer exist in Revenium, `enforcement-rules get` returns no matching rules, `new_halted` stays `false`, and the halt mechanism is silently broken with no operator-visible error.

**Fix:** Clear `ruleIds` in `config.json` immediately before (or atomically with) rule deletion, so a subsequent run re-triggers the setup flow:

```python
# In the [r]ecreate branch, before the deletion loop:
write_rule_ids_to_config("[]")
```

Or inline in the Python cleanup block before `revenium guardrails budget-rules delete` is called. Placing it after deletion but before the prompt loop is also acceptable, since the flock prevents concurrent setup.

---

### CR-02: `HALT_OUTPUT` Python block has no `|| true` guard — violates stated fail-open posture and exits non-zero under `set -euo`

**File:** `scripts/guardrail-check.sh:123-308`

**Issue:** The script header explicitly documents a "fail-open posture: every preflight and failure path exits 0." The `HALT_OUTPUT=$(...)` command subshell invokes a Python heredoc that performs a `tempfile.mkstemp` + `os.replace` write. If this write fails (disk-full, permissions error, unexpected exception), Python exits with code 1. Under `set -euo pipefail`, the unguarded assignment causes the entire script to exit non-zero immediately — `guardrail-status.json` is not updated, no log line is written, and no notification is sent. While `cron.sh` wraps the call with `|| true`, the script's own documented contract is violated and direct invocations (e.g., during testing or manual runs) receive a non-zero exit instead of the promised exit-0 soft-fail.

**Fix:** Add a `|| true` guard and emit a `warn` log on failure:

```bash
HALT_OUTPUT=$(
  GUARDRAIL_STATUS_FILE="${GUARDRAIL_STATUS_FILE}" \
  ENFORCEMENT_JSON="${ENFORCEMENT_JSON}" \
  BUDGET_RULES_JSON="${BUDGET_RULES_JSON}" \
  RULE_IDS_JSON="${RULE_IDS_JSON}" \
  AUTONOMOUS="${AUTONOMOUS}" \
  python3 - <<'PY'
  ...
PY
) || { warn "guardrail status update failed — status file may be stale"; exit 0; }
```

---

## Warnings

### WR-01: `flock` command is an undocumented dependency — silently skips all cron work on macOS systems where it is absent

**File:** `scripts/cron.sh:69`

**Issue:** `cron.sh` uses `flock -n 9 || exit 0` to serialize concurrent cron invocations. `flock` is a Linux `util-linux` utility and is not present in macOS's standard toolchain (confirmed absent in the test environment). Because of the `|| exit 0` guard, a missing `flock` command causes the subshell to silently exit 0, skipping both `report.sh` and `guardrail-check.sh`. No warning is logged, no error is emitted, and the metering and halt check never run. `post-install.sh` checks for `revenium`, `jq`, and `python3`, but does not check for or install `flock`.

**Fix:** Add a `flock` preflight to `post-install.sh`, or replace the `flock` call with a Python `fcntl`-based lock (consistent with the approach already used in `setup-guardrails.sh`), which works on both platforms:

```bash
# Replace flock -n 9 || exit 0 with:
if ! python3 -c "import fcntl; fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)" 2>/dev/null; then
  exit 0
fi
```

---

### WR-02: Pipe character in API-returned rule names corrupts IFS-delimited shadow notification parsing

**File:** `scripts/guardrail-check.sh:400-406`

**Issue:** Shadow-mode transition data is serialized as pipe-delimited text (line 402: `print(f"{r['name']}|{r.get('metricType','')}|...")`) and then deserialized using `IFS='|' read -r SR_NAME SR_METRIC SR_WINDOW SR_CV SR_HL` (line 404). The comment states "pipes don't appear in numeric values or in the short metric/window enum strings" — this is true, but `r['name']` is an API-returned value that can contain arbitrary characters. `guardrail-check.sh` fetches all enforcement rules for the team (not just ones created by `setup-guardrails.sh`), so any rule created outside the skill with a pipe in its name causes field misalignment. A name like `"my|rule"` shifts `metricType` to `injected`, producing a misleading notification message sent to the operator.

**Fix:** Serialize via JSON array-of-objects instead of pipe-delimited text, passing the whole structure as a single environment variable (already used elsewhere), or encode the name field via base64 before passing through the pipe-delimited format.

---

### WR-03: `SHADOW_TMP` tempfile is never cleaned up if the Python formatter exits non-zero

**File:** `scripts/guardrail-check.sh:396-420`

**Issue:** `SHADOW_TMP=$(mktemp)` is created at line 396. The next line pipes `python3` output into it. Under `set -euo pipefail`, if the Python call exits non-zero (e.g., malformed JSON from `SHADOW_TRANSITIONS_JSON`), the script aborts before reaching `rm -f "${SHADOW_TMP}"` at line 420. A leaked tempfile per cron tick is a minor issue, but it accumulates in the default tmpdir over time. There is no `trap` handler to clean up on error.

**Fix:**
```bash
SHADOW_TMP=$(mktemp)
trap 'rm -f "${SHADOW_TMP}"' EXIT
SHADOW_TRANSITIONS_JSON="${SHADOW_TRANSITIONS_JSON}" python3 - <<'PY' > "${SHADOW_TMP}"
...
```

---

### WR-04: Cron frequency mismatch between `SKILL.md` and the actual cron schedule

**File:** `SKILL.md:38`, `scripts/cron.sh:4`, `scripts/install-cron.sh:11`

**Issue:** `SKILL.md` (line 38 and 113) tells the agent that "the background cron job checks Revenium every minute." The actual installed schedule is `*/15 * * * *` (every 15 minutes), documented in `cron.sh`'s header comment and hardcoded in `install-cron.sh`'s `CRON_SCHEDULE`. An agent reading `SKILL.md` will believe guardrail state is at most 60 seconds stale and may make enforcement decisions based on that assumption. The actual maximum staleness is 15 minutes.

**Fix:** Update `SKILL.md` lines 38 and 113 to say "every 15 minutes" (or sync the schedule to 1 minute if that was the intent):

```markdown
The guardrail status is maintained by a background cron job that checks Revenium
every 15 minutes and writes the result to `~/.openclaw/skills/revenium/guardrail-status.json`.
```

---

### WR-05: `guardrail-check.sh` atomic write lacks `fsync` — inconsistent with `setup-guardrails.sh` durability guarantee

**File:** `scripts/guardrail-check.sh:285-288`

**Issue:** The `guardrail-status.json` atomic write (lines 285-288) uses `os.fdopen` + `f.write` + `os.replace` but omits `f.flush()` and `os.fsync()` before the rename. By contrast, both `write_rule_ids_to_config` and `write_rule_ids_and_config` in `setup-guardrails.sh` (lines 331-332, 382-383) explicitly call `tmp.flush()` and `os.fsync(tmp.fileno())` before `os.rename`. On a crash or power failure after `os.replace` succeeds but before the kernel flushes dirty pages, the status file on disk may be empty or truncated. Since the agent reads this file before every response, a corrupt status file causes the halt check to fail silently (fail-open by design, but the corruption is unnecessary).

**Fix:**
```python
with os.fdopen(tmp_fd, 'w', encoding='utf-8') as f:
    f.write(json.dumps(data, indent=2) + '\n')
    f.flush()
    os.fsync(f.fileno())
os.replace(tmp_path, str(status_file))
```

---

### WR-06: `common.sh` defines `LOCK_FILE` pointing to a different path than `cron.sh`'s lock — dead constant causes confusion

**File:** `scripts/common.sh:45`, `scripts/cron.sh:67`

**Issue:** `common.sh` defines `LOCK_FILE="${STATE_DIR}/revenium-metering.lock"` which resolves to `~/.openclaw/skills/revenium/revenium-metering.lock`. `cron.sh` defines its own `LOCK_FILE="${OPENCLAW_HOME:-${HOME}/.openclaw}/revenium-metering.lock"` which resolves to `~/.openclaw/revenium-metering.lock` — a different path. `guardrail-check.sh` (which sources `common.sh`) never uses `LOCK_FILE`, making the `common.sh` constant dead. The divergence means a future maintainer who adds lock-checking code to `guardrail-check.sh` using `${LOCK_FILE}` would create a lock that does not coordinate with the cron-level lock, permitting concurrent execution.

**Fix:** Either remove `LOCK_FILE` from `common.sh` (it's unused) or align the path with `cron.sh`'s value. If `common.sh` is intended to export the lock path for shared use, update `cron.sh` to source `common.sh` and use `${LOCK_FILE}`:

```bash
# In common.sh, align to cron.sh's path:
LOCK_FILE="${OPENCLAW_HOME}/revenium-metering.lock"
```

---

## Info

### IN-01: `post-install.sh` seeds `guardrail-status.json` and `config.json` with non-atomic direct writes

**File:** `scripts/post-install.sh:391-396`, `scripts/post-install.sh:422-427`

**Issue:** Steps 5 and 6 write the seed files using `python3 -c "..." > "${GUARDRAIL_STATUS_FILE}"` and `cat > "${SKILL_CONFIG_FILE}"`. Unlike all other JSON writes in the codebase (which use temp-then-rename), these are direct overwrites. A SIGINT or kill during these writes leaves a partial/empty JSON file, which subsequent reads (`SKILL.md` halt check, `guardrail-check.sh` preflight) treat as corrupt and fail-open. This is only reached on first install (the `[[ ! -f ]]` guards skip on re-runs), so the impact window is narrow, but it's inconsistent with the rest of the codebase.

**Fix:** Use the same atomic-write pattern as the rest of the codebase (Python `tempfile.NamedTemporaryFile` + `os.rename`), or at minimum redirect into a tempfile and `mv` it into place.

---

### IN-02: Bash variable expansion into Python and JavaScript string literals in `post-install.sh` heredocs

**File:** `scripts/post-install.sh:268-339`, `scripts/post-install.sh:223-228`

**Issue:** Several `python3 <<PYEOF` and `node -e` blocks in `post-install.sh` use unquoted heredoc delimiters, allowing bash to expand `${EXTRA_PATH_DIRS}`, `${EXTRA_LIB_DIRS}`, `${SSL_CERT_FILE}`, `${AGENTS_MD}`, and `${HOME}` directly into Python/JS string literals. If any of these paths contain a double-quote (Python) or single-quote (JavaScript), the embedded string literal is syntactically broken and the interpreter will exit with a parse error. For the JS case, `node -e "... '${SSL_CERT_FILE}' ..."` (line 226) would break if `HOME` contains an apostrophe (e.g., `/Users/O'Brien/.openclaw/ssl/...`).

**Fix:** Pass path values via environment variables and use quoted heredoc delimiters where the Python code can be static (consistent with the `<<'PY'` pattern already used in `guardrail-check.sh` and `setup-guardrails.sh`):

```bash
SSL_CERT_FILE="${SSL_CERT_FILE}" node -e "
  const path = process.env.SSL_CERT_FILE;
  const tls = require('tls');
  const fs = require('fs');
  fs.writeFileSync(path, tls.rootCertificates.join('\n'));
"
```

---

### IN-03: `SKILL.md` setup flow mentions `install-cron.sh` but SKILL.md text references `install-cron.sh` — only `cron.sh` is reviewed

**File:** `SKILL.md:113`

**Issue:** SKILL.md step 4 instructs agents to run `bash ~/.openclaw/skills/revenium/scripts/install-cron.sh`. This file (`install-cron.sh`) is not in the reviewed file set for this phase (it exists and was read as context). The referenced script sets `CRON_SCHEDULE="*/15 * * * *"` — consistent with `cron.sh`'s header comment but inconsistent with `SKILL.md`'s "every minute" claim (already reported as WR-04). This is informational: the cross-reference is valid, but the discrepancy compounds WR-04.

**Fix:** No code change required beyond fixing WR-04. Noting here for completeness.

---

_Reviewed: 2026-05-31T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
