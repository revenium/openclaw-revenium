---
phase: 12-parallel-install-scaffolding-detection
reviewed: 2026-06-07T00:00:00Z
depth: standard
files_reviewed: 4
files_reviewed_list:
  - scripts/install.sh
  - scripts/post-install-nemoclaw.sh
  - scripts/probe-host-compat.sh
  - tests/test_install_dispatcher.sh
findings:
  critical: 0
  warning: 5
  info: 4
  total: 9
status: issues_found
---

# Phase 12: Code Review Report

**Reviewed:** 2026-06-07
**Depth:** standard
**Files Reviewed:** 4
**Status:** issues_found

## Summary

Reviewed four bash install-scaffolding scripts for the parallel NemoClaw/OpenShell
install path: the dispatcher (`install.sh`), the NemoClaw skeleton
(`post-install-nemoclaw.sh`), the non-destructive host probe
(`probe-host-compat.sh`), and a hermetic dispatcher test harness
(`test_install_dispatcher.sh`).

Shell-safety hygiene is generally good: `set -euo pipefail` in the executable
scripts, quoted expansions, the `${arr[@]+"${arr[@]}"}` empty-array guard, and
the probe is correctly **exec'd via `bash`, never sourced** — the core preflight
contract holds. No command-injection or secret-leak vectors were found; no `eval`,
no unquoted user-controlled expansion into a command.

No BLOCKERs. The findings are robustness and contract-fidelity defects. The most
material is **WR-01**: the probe reads the *real* `uname -s` and does not honor
the `STUB_UNAME_S` override that the dispatcher advertises as its testability
seam, so the dispatcher's "testable OS detection" contract is not honored
end-to-end once routing reaches the probe. **WR-02** (the probe's `set -u`
without `pipefail`/`-e`) and **WR-03** (silent integer floor on sub-threshold
RAM/disk) are the next most important.

## Warnings

### WR-01: Probe ignores the `STUB_UNAME_S` testability seam — dispatcher OS contract breaks end-to-end

**File:** `scripts/probe-host-compat.sh:28` (and `scripts/install.sh:56`)
**Issue:** `install.sh` deliberately reads OS via `_os="${STUB_UNAME_S:-$(uname -s)}"`
(line 56) so tests can override OS detection. But once the dispatcher routes to
`post-install-nemoclaw.sh`, that script execs `probe-host-compat.sh`, which reads
OS via the raw `OS="$(uname -s)"` (line 28) with no `STUB_UNAME_S` fallback. The
override therefore stops at the dispatcher boundary. On a real macOS dev box,
`test_install_dispatcher.sh` GROUP A/F run with `STUB_UNAME_S="Linux"`, but the
probe still sees `Darwin`, emits an OS hard-FAIL, exits 1, and
`post-install-nemoclaw.sh` `fail()`s the install. The tests happen to survive
this (they assert only on the routing *marker*, which is printed before the
probe runs, and GROUP F asserts only that the two exit codes *match*), so the
defect is masked — but the behavior under test diverges from the behavior the
test names claim to exercise, and any future assertion on probe success will
silently break on non-Linux CI runners.
**Fix:** Honor the same seam in the probe so the OS override is consistent across
the call chain:
```bash
OS="${STUB_UNAME_S:-$(uname -s)}"
```
(If the probe is intentionally meant to always reflect the true host, document
that explicitly and have `post-install-nemoclaw.sh` forward `STUB_UNAME_S` or
skip the probe under test — otherwise the seam is a half-measure.)

### WR-02: Probe runs under `set -u` only — no `pipefail`/`-e`, so failed pipeline stages are swallowed

**File:** `scripts/probe-host-compat.sh:16`
**Issue:** The probe uses `set -u` but not `set -o pipefail` (and not `-e`),
while the rest of the suite uses `set -euo pipefail`. Several checks build values
through multi-stage pipelines whose non-final stage can fail silently, e.g.
`kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)` (line 73),
`avail_gb=$(df -Pg "$HOME" 2>/dev/null | awk 'NR==2{print $4}')` (line 86), and
the `docker --version | awk | tr` chain (line 60). Without `pipefail`, a failing
`df`/`awk`/`grep` upstream is hidden by a succeeding downstream stage, so a
genuine probe error can be misreported as a benign WARN rather than surfacing.
This weakens the reliability of the very gate that decides whether provisioning
proceeds.
**Fix:** Add pipefail to the probe (keep `-e` off if intentional, since the probe
deliberately tallies failures rather than aborting):
```bash
set -uo pipefail
```

### WR-03: Sub-threshold RAM/disk silently floors to a smaller integer (off-by-one against the gate)

**File:** `scripts/probe-host-compat.sh:74-77, 86-89`
**Issue:** RAM and disk are computed with truncating integer division:
`ram_gb=$(( kb / 1024 / 1024 ))` (line 74) and the `-Pk` fallback
`avail_gb=$(df -Pk "$HOME" | awk 'NR==2{print int($4/1024/1024)}')` (line 89).
A host with 8.9 GB RAM floors to `8` (passes the `>= 8` gate — acceptable), but a
host with 7.9 GB floors to `7` and a host with 20.9 GB disk that is actually
*above* 20 GB still floors to `20` (boundary OK). The real defect is asymmetric
reporting: the threshold compares a floored value, so a machine at exactly the
boundary in MB but just under in the floored GB will be classified incorrectly,
and the printed verdict ("`${ram_gb} GB`") understates the true figure, which is
misleading in a host-selection report. Because this is the gate humans use to
pick a spike host, the rounding direction matters.
**Fix:** Compare in the smaller unit before flooring for display, e.g. gate on
KB/MB and only floor for the human-readable string:
```bash
# RAM gate in MB to avoid floor-at-the-boundary
ram_mb=$(( kb / 1024 ))
if [ "$ram_mb" -ge 8192 ]; then ok "RAM" "$(( ram_mb / 1024 )) GB (>= 8 GB)"; ...
```

### WR-04: `df -Pg` is non-portable; the `NR==2` parse breaks on long-device-name line wrapping

**File:** `scripts/probe-host-compat.sh:86`
**Issue:** `df -Pg` relies on a `-g` (GB blocks) flag that exists on BSD/macOS df
but **not** on GNU coreutils df (Linux), where `-g` is not a valid option. On
Linux the `df -Pg` invocation fails, `avail_gb` comes back empty, and the code
falls through to the `-Pk` fallback (line 89) — so it recovers, but the primary
path is effectively dead on the only supported OS (Linux). Separately, both
`df` parses assume the data row is `NR==2`; POSIX `-P` mostly prevents the
classic long-device-name wrap, but combining `-P` with the non-portable `-g`
undermines that guarantee on the platform where `-g` is honored.
**Fix:** Drop the `-g` path entirely and parse a single portable POSIX `df -Pk`,
which is supported on both Linux and macOS:
```bash
avail_gb=$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2{print int($4/1024/1024)}')
```

### WR-05: PATH is mutated before the preflight gate, and the CLI-check guidance is then misleading

**File:** `scripts/post-install-nemoclaw.sh:43, 89-94`
**Issue:** Line 43 unconditionally prepends `~/.local/bin` to `PATH` at script
top, *before* the preflight gate and CLI check run. Then lines 92-93 warn the
user that `nemoclaw` was "not found on PATH — ensure ~/.local/bin is in PATH"
and instruct them to add `export PATH="$HOME/.local/bin:$PATH"`. But the script
already did exactly that, so if the CLI is genuinely absent the printed remedy is
a no-op that will mislead the operator into thinking PATH is the problem when the
binary simply is not installed. The advice contradicts the script's own state.
**Fix:** Make the warning reflect reality — the CLI binary is absent, not the
PATH entry:
```bash
warn "nemoclaw CLI not found (searched PATH incl. ~/.local/bin) — NemoClaw may not be installed yet."
```

## Info

### IN-01: Probe header still carries spike-era branding inconsistent with its production role

**File:** `scripts/probe-host-compat.sh:25`
**Issue:** The banner prints "Spike 001 — NemoClaw host compatibility probe"
(line 25) and line 2 calls itself a spike artifact, yet the script is now an
install-time preflight gate invoked by `post-install-nemoclaw.sh`. Calling a
production gate "Spike 001" in operator-facing output is confusing.
**Fix:** Rename the banner to reflect the install-preflight role (e.g.
"NemoClaw host compatibility preflight").

### IN-02: Dispatcher requires `post-install.sh` to exist even on the NemoClaw route

**File:** `scripts/install.sh:90-93`
**Issue:** Both script-existence guards run unconditionally before dispatch, so a
NemoClaw-only install still hard-fails if `post-install.sh` is missing, even
though that route never invokes it. Harmless today (both files exist) but couples
the NemoClaw path to an unrelated file's presence.
**Fix:** Move each guard inside its corresponding branch of the routing `if`, so
each path only asserts the script it actually runs.

### IN-03: Probe evaluates RAM/disk/GPU/Node on Darwin despite Darwin being a hard OS FAIL

**File:** `scripts/probe-host-compat.sh:75-77, 84-116`
**Issue:** When `OS=Darwin` the OS check already records a hard `fail` (line 44),
guaranteeing an INCOMPATIBLE verdict, yet the script proceeds to compute macOS
RAM via `sysctl` and run the remaining checks. This is dead-weight work whose
output ("RAM 16 GB ✓") falsely implies partial compatibility on a host that is
categorically rejected.
**Fix:** Optional — short-circuit the remaining checks once the OS gate fails, or
add a note that subsequent rows are informational only on unsupported OSes.

### IN-04: Test idempotency assertions are weak — only marker presence and matching exit codes, not output stability

**File:** `tests/test_install_dispatcher.sh:218-233`
**Issue:** GROUP F claims to verify "stable output" (header comment line 206) and
"byte-stability", but actually asserts only that (a) the two exit codes are equal
and (b) both runs contain the routing marker. Two runs could differ materially
(e.g. one warns about a missing CLI, one does not) and still pass. The assertion
does not match the stated intent.
**Fix:** Diff the two captured outputs after masking known-volatile lines (paths,
versions), e.g. `[[ "$(norm "$output_f1")" == "$(norm "$output_f2")" ]]`, to
actually enforce stability.

---

_Reviewed: 2026-06-07_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
