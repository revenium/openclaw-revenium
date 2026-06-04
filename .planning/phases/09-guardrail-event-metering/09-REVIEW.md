---
phase: 09-guardrail-event-metering
reviewed: 2026-06-03T00:00:00Z
depth: standard
files_reviewed: 6
files_reviewed_list:
  - scripts/common.sh
  - scripts/guardrail-check.sh
  - scripts/report.sh
  - tests/stub-revenium.sh
  - tests/test_guardrail_argv.sh
  - tests/test_report_argv.sh
findings:
  critical: 0
  warning: 5
  info: 3
  total: 8
status: issues_found
---

# Phase 9: Code Review Report

**Reviewed:** 2026-06-03T00:00:00Z
**Depth:** standard
**Files Reviewed:** 6
**Status:** issues_found

## Summary

Phase 9 adds fail-open guardrail-event metering (Section M) to `guardrail-check.sh`,
two ledger path constants to `common.sh`, and removes a dead `GUARDRAIL` operation-type
heuristic from `report.sh`. The adversarial focus areas — fail-open discipline,
shell-injection safety, ledger dedup, Bash 3.2 portability, and attribution — were
each traced against the implementation.

**Fail-open posture holds.** Every path in Section M was traced under `set -euo pipefail`:
all command substitutions are guarded with `|| true`, `_emit_guardrail_event` returns 0
on every branch, the `while read` loops exit 0 at EOF, and even the degenerate
`mktemp`-fails case (empty tmpfile path → failed redirect) was verified not to abort the
script. No path changes the exit code or blocks enforcement. The status file is written
in Section G before any metering, so durability precedes emission (D-11).

**Injection safety holds.** The meter argv is built with strict bash-array discipline
(`cmd+=(--flag "${value}")`), no `eval`, no string-join. All Python heredocs use the
env-passing `<<'PY'` pattern with no `${}` interpolation. The stub only string-compares
and `printf`-captures argv. No `<<<` herestrings were introduced in subshells (the three
in `report.sh` predate this phase and are out of scope).

The defects below are correctness/robustness concerns in the dedup and test layers, not
fail-open or security breaks — hence no BLOCKERs. The most consequential are WR-01 (warn/
shadow/halt events are silently *lost* if the meter call fails, because the cross-tick
dedup relies on the persisted status transition rather than the ledger) and WR-02 (the
ledger uses substring `grep -F` matching, weakening the exactly-once backstop).

## Warnings

### WR-01: Warn/shadow/halt event is permanently lost when the meter call fails

**File:** `scripts/guardrail-check.sh:543-603, 605-661`
**Issue:** Exactly-once for warn/shadow/halt depends on the *Python transition guard*
(prev `guardrail-status.json` state vs current), NOT on the ledger. The status file is
written in Section G **before** Section M runs, so it always records the new `warn`/`block`
state for the current tick. The ledger backstop cannot dedup across ticks for warn/shadow
because `onset_marker` is a fresh `now()` per tick (`_guardrail_warn_now` /
`_guardrail_shadow_now`), so its key differs every tick. Consequence: if the `revenium
meter completion` call fails on the onset tick, `_emit_guardrail_event` correctly returns 0
(fail-open) but does **not** write the ledger key — and on the next tick the rule is still
in `warn`/`block` state, so `warn_transitions`/`shadow_transitions` is empty and the event
is never retried. The metering event is silently dropped. Halt has the same gap: a meter
failure on the `HALT_TRANSITION=true` edge is never retried because the next tick sees
`prev_halted=true` → `halt_transition=false`. This is a metering-completeness defect (a
transient API/network blip on the exact onset tick loses the event forever), but it does
not double-bill, corrupt data, or break fail-open.
**Fix:** Decouple emission-retry from transition detection. Either (a) make the ledger the
authoritative dedup using a *stable* onset key for all three event types — e.g. for
warn/shadow derive `onset_marker` from a stable per-onset stamp persisted in the status
file (mirroring how `haltedAt` is stable for halt) rather than `now()` — and drive emission
off "rule is in warn/shadow state AND ledger key absent" instead of off the transition
edge; or (b) explicitly document that guardrail events are best-effort at-most-once and
acceptable to drop on transient failure. If (a), also persist a `warnOnsetAt`/`shadowOnsetAt`
timestamp per rule in Section G so the ledger key is stable across retries.

### WR-02: Ledger dedup uses substring (`grep -qF`) instead of whole-line match

**File:** `scripts/guardrail-check.sh:553`
**Issue:** `grep -qF "${ledger_key}" "${GUARDRAIL_LEDGER_FILE}"` matches the key as a
substring of any line, not as a whole line. With well-formed keys this is mostly benign
because the trailing timestamp differentiates rules, but two failure modes exist: (1) if
`onset_marker` is ever empty (e.g. a fallback edge where both `python3` and `date`
produced nothing under the `|| true`), the key degrades to
`GUARDRAIL:<type>:<rule>:` which substring-matches *any* prior dated line for that rule,
suppressing a legitimate emission; (2) any future change that lets a ruleId be a prefix of
another, or lets onset markers share a prefix, reintroduces false dedup. This is a
defense-in-depth weakness in the exactly-once backstop.
**Fix:** Use a whole-line anchored match:
```bash
if grep -qxF "${ledger_key}" "${GUARDRAIL_LEDGER_FILE}" 2>/dev/null; then
  return 0
fi
```
`-x` forces a full-line match, eliminating the substring/empty-onset hazard.

### WR-03: `count_grep`-style double-output bug in test_report_argv.sh anti-bleed assertion

**File:** `tests/test_report_argv.sh:250`
**Issue:** `unclassified_count=$(echo "${task_type_values}" | grep -c "^unclassified$" || echo 0)`
reintroduces the exact `grep -c` double-output bug that the sibling test documents and
guards against with its `count_grep` helper. When there are zero matches, `grep -c` prints
`0` AND exits 1, so `|| echo 0` also fires, yielding a two-line value `$'0\n0'`. The
subsequent `[[ "${unclassified_count}" -ge 2 ]]` then throws a "bad math expression" error
(verified). In the current happy path there are >=2 unclassified entries so `grep -c`
exits 0 and the bug is latent, but at the zero-match boundary (the precise case a bleed
regression would produce) the assertion crashes instead of reporting a clean failure,
masking the real defect it is meant to catch.
**Fix:** Use the same hardened idiom as the other test's `count_grep`:
```bash
unclassified_count=$(echo "${task_type_values}" | grep -c "^unclassified$" 2>/dev/null; exit 0)
unclassified_count="${unclassified_count:-0}"
```
or reuse a shared helper that suppresses the exit-1 path.

### WR-04: Newest-session-by-mtime may misattribute the guardrail event's `--agent`

**File:** `scripts/guardrail-check.sh:494-504`
**Issue:** Attribution resolves the root session by taking the most-recently-*modified*
session file (`ls -t .../*.jsonl | head -1`) and walking it to root. Under concurrent
activity, the newest-mtime session can belong to an unrelated agent run (or a subagent
whose root differs from the agent that actually triggered the budget breach). The
`get_root_session_id` walk corrects subagent→root, but it cannot correct "wrong session
entirely." The guardrail event is account/budget-scoped, not session-scoped, so the
`--agent openclaw-<root_sid>` value can be attributed to whichever session happened to be
written last, which may not be the breaching workload. This is an attribution-accuracy
WARNING, not a correctness break (the event is still emitted and deduped).
**Fix:** Document that guardrail-event `--agent` attribution is best-effort "most-recently-
active session" by design (budget breaches are account-level, not tied to one completion),
or, if precise attribution matters, derive the agent from the breaching rule's `groupBy`/
filter scope rather than from session mtime.

### WR-05: `xargs basename` can split or misbehave on unusual session paths

**File:** `scripts/guardrail-check.sh:495-498`
**Issue:** `ls -t "${SESSIONS_DIR}"/*.jsonl | head -1 | xargs basename | sed 's/\.jsonl$//'`
pipes a filename through `xargs`, which applies word-splitting and quote-processing to its
input. A session path containing whitespace or a quote (unusual but possible if
`SESSIONS_DIR` is relocated) would cause `xargs` to pass multiple args to `basename`
(which errors on >1 arg) or to mis-split. The whole pipeline is guarded by `|| true` so it
fails open to an empty sid (then `--agent` becomes just `openclaw-`), but that silently
degrades attribution.
**Fix:** Avoid `xargs`; resolve the basename in-shell:
```bash
_newest=$(ls -t "${SESSIONS_DIR}"/*.jsonl 2>/dev/null | head -1) || true
_guardrail_newest_session_id="$(basename "${_newest}" .jsonl 2>/dev/null)"
[[ "${_guardrail_newest_session_id}" == "*.jsonl" ]] && _guardrail_newest_session_id=""
```

## Info

### IN-01: Dead `report.sh` GUARDRAIL heuristic removed cleanly — verify no stale references

**File:** `scripts/report.sh:842-849`
**Issue:** The dead `budget-status.json`→`GUARDRAIL` operation-type branch and its
`BUDGET_STATUS_FILE` constant were removed as intended; `operation_type` now resolves only
to `CHAT`/`TOOL_CALL`. `test_report_argv.sh:307-311` (GRDEV-06) correctly asserts
`--operation-type GUARDRAIL` never appears in `report.sh` argv. No action required; noted
for completeness. Confirm no other script still reads `BUDGET_STATUS_FILE` (none found in
the reviewed set).
**Fix:** None — informational confirmation of clean removal.

### IN-02: `stdout` is polluted with KEY=value diagnostic lines

**File:** `scripts/guardrail-check.sh:364, 424-425`
**Issue:** Section runs `echo "${HALT_OUTPUT}"` and `echo "EVENT_TS=..."` /
`echo "EVENT_SUMMARY=..."` to stdout. Under cron these are harmless (captured to the log
via `2>&1` redirection), and the test harness relies on them, but emitting structured
KEY=value diagnostics on stdout from a cron stage is a mild smell that couples the
implementation to test observability.
**Fix:** Optional — route diagnostics through `info`/the log writer and keep stdout clean,
or document that stdout is an intentional test-observability channel.

### IN-03: Duplicated `JOBS_LEDGER_FILE` / open-job resolution logic across scripts

**File:** `scripts/common.sh:64`, `scripts/report.sh:34`, `scripts/guardrail-check.sh:510-531`
**Issue:** `JOBS_LEDGER_FILE` is defined identically in both `common.sh` and `report.sh`
(the comment at `common.sh:62` even flags "must stay in sync"), and the open-job resolution
Python in `guardrail-check.sh:513-530` re-implements the created/closed ledger scan that
`report.sh:1085-1100` (`handle_halt`) already implements. Drift between these copies would
silently change attribution behavior.
**Fix:** Optional refactor — source the single `JOBS_LEDGER_FILE` definition from
`common.sh` in `report.sh`, and factor the "newest open job from ledger" scan into one
shared sidecar/helper to prevent divergence.

---

_Reviewed: 2026-06-03T00:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
