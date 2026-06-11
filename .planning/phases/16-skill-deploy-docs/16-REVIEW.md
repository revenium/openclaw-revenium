---
phase: 16-skill-deploy-docs
reviewed: 2026-06-10T00:00:00Z
depth: standard
files_reviewed: 5
files_reviewed_list:
  - README.md
  - docs/nemoclaw-setup.md
  - scripts/post-install-nemoclaw.sh
  - tests/stub-nemoclaw.sh
  - tests/test_nemoclaw_provisioning.sh
findings:
  critical: 1
  warning: 5
  info: 3
  total: 9
status: issues_found
---

# Phase 16: Code Review Report

**Reviewed:** 2026-06-10
**Depth:** standard
**Files Reviewed:** 5
**Status:** issues_found

## Summary

Reviewed the Phase 16 changes: the SKILL.md path guard, the `✓ ready` discovery
assertion, and the `--force` idempotency fix in `scripts/post-install-nemoclaw.sh`;
the new `docs/nemoclaw-setup.md` operator runbook; the one-line README pointer; and
the extended bash tests/stubs.

The shell scripting is generally careful — the `|| true` CR-01 guards are correctly
placed before content classification, `yaml_dquote` escapes backslash-then-quote in
the right order, the base64 credential transport avoids in-sandbox shell expansion,
and the egress exit-code capture deliberately avoids the `|| echo "000"` double-print
trap. The hermetic suite runs GREEN (27 passed, 0 failed).

However, the core new feature of this phase — the `✓ ready` discovery assertion —
has a substring-matching bug that produces a **false positive**: it accepts a skill
in a `not-ready`/`already`-flagged state as "ready," defeating the entire purpose of
the gate (T-16-02). This is a BLOCKER. There are also several doc-accuracy defects,
the most notable being a broken, self-referential cross-link inside the new runbook,
and a test-coverage gap that lets the assertion bug pass undetected.

## Critical Issues

### CR-01: `✓ ready` assertion false-positives on `not-ready` / `already` substrings

**File:** `scripts/post-install-nemoclaw.sh:153`
**Issue:** The discovery assertion is the headline deliverable of this phase (D-02,
T-16-02 — abort if the skill is not ready). It uses:

```bash
if ! echo "${_skill_list}" | grep "revenium" | grep -q "ready"; then
```

`grep -q "ready"` matches the bare substring `ready` anywhere on a revenium line —
including inside the words `not-ready`, `not ready`, `already`, `un-ready`, etc. If
`openclaw skills list` emits a non-ready status line that happens to contain any of
those tokens for the revenium skill, the gate passes and the installer reports
success while the skill is broken. Verified empirically:

```
$ printf '✗ not-ready  💰 revenium\n' | grep "revenium" | grep -q "ready"; echo $?
0   # FALSE POSITIVE — treated as ready
```

This is exactly the silent-broken-install failure mode the gate exists to prevent.
The matching is also unanchored against the status glyph, so it does not verify the
`✓ ready` marker the docs (README.md:154, docs/nemoclaw-setup.md:105) promise.

**Fix:** Match the actual ready marker (the `✓ ready` token the docs document), or at
minimum anchor `ready` as a whole word on the revenium line so `not-ready`/`already`
cannot satisfy it:

```bash
# Require the documented "✓ ready" marker on the revenium line:
if ! echo "${_skill_list}" | grep "revenium" | grep -qE '(^|[[:space:]])ready([[:space:]]|$)'; then
    fail "revenium skill NOT ready after install — ..."
fi
```

(If matching the literal `✓` is undesirable for the Unicode-safety reason cited in the
comment, the whole-word `ready` anchor above is the minimum acceptable fix. The current
unanchored substring match is not.)

## Warnings

### WR-01: Broken self-referential cross-link inside the new runbook

**File:** `docs/nemoclaw-setup.md:110`
**Issue:** The new runbook contains a pointer that tells the reader of the NemoClaw
runbook to go read the NemoClaw runbook:

```markdown
> **Running on NemoClaw/OpenShell?** See [NemoClaw Setup](docs/nemoclaw-setup.md) for the parallel install path.
```

This was copy-pasted verbatim from README.md:92 (confirmed in the diff — the whole file
is new in commit 891aed8). Two defects: (1) it is nonsensical self-reference inside the
very document it links to; (2) the relative path is wrong — from inside `docs/`, the
link `docs/nemoclaw-setup.md` resolves to `docs/docs/nemoclaw-setup.md`, a 404. Every
other cross-link in this file correctly uses `../` to escape `docs/` (lines 3, 122, 144,
309).
**Fix:** Delete line 110 entirely. The README→runbook pointer belongs only in README.md,
not in the runbook itself.

### WR-02: Documented manual uninstall leaves the ledger key set, breaking reinstall

**File:** `docs/nemoclaw-setup.md:207-221`
**Issue:** The "Uninstalling" section instructs operators to run a bare
`openclaw plugins uninstall revenium-enforcement` (step 2) and `skill remove` (step 3),
but never clears the ledger. `install_enforcement_plugin()` is gated on the
`enforcement-plugin-installed` ledger key (post-install-nemoclaw.sh:167). After the
documented manual uninstall, that key remains set, so a subsequent
`install.sh --nemoclaw` **skips the plugin reinstall entirely** ("already installed
(ledger) — skipping") and the operator is left with no enforcement and no error. The
repo already ships `scripts/uninstall-enforcement-nemoclaw.sh`, which correctly clears
the ledger key, disables via config patch, and removes the plugin dir from the mount —
but the runbook does not mention it.
**Fix:** Point the runbook at the dedicated uninstall script for the plugin (and
skill/cron) instead of the partial manual commands, or add an explicit step to clear
the relevant ledger keys (`enforcement-plugin-installed`, `skill-installed-nemoclaw`,
`metering-loop-installed`) after a manual uninstall.

### WR-03: Test suite never exercises the assertion bug from CR-01

**File:** `tests/test_nemoclaw_provisioning.sh:438-464` (GROUP I-b) and
`tests/stub-nemoclaw.sh:50,165`
**Issue:** The `STUB_NEMOCLAW_SKILLS_LIST_OUTPUT` env switch exists (stub line 50/165)
specifically to feed arbitrary skills-list output, but no test ever uses it. GROUP I-b
only tests the `STUB_NEMOCLAW_SKILL_NOT_READY` path, which emits `"No skills installed."`
— a string containing neither `revenium` nor `ready`, so the grep chain trivially fails
the right way. The dangerous case — a revenium line containing a `ready` substring like
`not-ready` — is never tested, which is why CR-01 ships GREEN. An adversarial test for
this assertion is the whole point of T-16-02.
**Fix:** Add a GROUP I case using
`STUB_NEMOCLAW_SKILLS_LIST_OUTPUT='✗ not-ready  💰 revenium'` and assert the install
exits non-zero. With the current code this test would (correctly) FAIL, surfacing CR-01.

### WR-04: GROUP I-c happy-path test captures exit code but never asserts it

**File:** `tests/test_nemoclaw_provisioning.sh:479-487`
**Issue:** I-c is the only happy-path coverage for the new `install_skill_nemoclaw()`
flow, but it asserts only that the `skill-installed-nemoclaw` ledger key was written.
`exit_code_ic` is captured (line 479-480) and then never checked, and the
"revenium skill confirmed ready in sandbox" success message is never asserted. Because
the ledger write (`ledger_set` at script line 158) happens *before* the
`install_enforcement_plugin` gates, the key could be present even if a later step
failed — so this assertion does not actually prove the ready-path succeeded cleanly.
**Fix:** Add `if [[ "${exit_code_ic}" -eq 0 ]]` and an assertion that `output_ic`
contains `revenium skill confirmed ready in sandbox`.

### WR-05: Success banner unconditionally prints `Skill: revenium (✓ ready)`

**File:** `scripts/post-install-nemoclaw.sh:568`
**Issue:** The line `Skill: revenium (✓ ready)` prints on every successful exit,
including the idempotent re-run branch (WORK_DONE=0) where the ready-assertion was
skipped via the ledger this invocation and was therefore never re-verified. It can thus
assert "✓ ready" for a skill whose state was never checked on this run. It also sits
outside the `if/else` block, so it appears even in the WORK_DONE=1 branch that otherwise
itemizes Delivered/Config/Probe/Plugin but deliberately omits the skill. This is a
correctness-of-reporting issue: the banner makes a freshness claim the run did not
validate.
**Fix:** Move the skill line inside the WORK_DONE=1 branch (where the assertion actually
ran), or reword it on the idempotent path to "Skill: revenium (deployed; ledger-gated,
not re-verified this run)".

## Info

### IN-01: Placeholder/likely-incorrect NemoClaw install URL in runbook

**File:** `docs/nemoclaw-setup.md:11`
**Issue:** The prerequisites block instructs `curl -fsSL https://www.nvidia.com/nemoclaw.sh | ... bash`.
`www.nvidia.com/nemoclaw.sh` is almost certainly not the real installer endpoint
(NVIDIA does not serve a top-level `.sh` from its marketing domain), and the
`[NemoClaw](https://www.nvidia.com/nemoclaw)` link (line 3) is similarly speculative.
Piping an unverified URL to `bash` as the documented first step is a footgun if the
host is wrong.
**Fix:** Confirm and use the canonical NemoClaw install URL, or mark the command as a
placeholder pending the real endpoint.

### IN-02: `_skill_list` comment claims "Unicode-safe two-pipe pattern (not literal ✓)" but the assertion does not check the readiness glyph at all

**File:** `scripts/post-install-nemoclaw.sh:149,153`
**Issue:** The comment frames the two-grep chain as a deliberate Unicode-safe way to
assert readiness, but as CR-01 shows it checks an unanchored `ready` substring rather
than the `✓ ready` marker the docs promise. The comment overstates the rigor of the
check and would mislead a future maintainer into trusting it.
**Fix:** Update the comment to match whatever anchored matching CR-01's fix adopts.

### IN-03: Runbook claims `~11 min` first-run partly attributable to NemoClaw bootstrap that the installer does not perform

**File:** `docs/nemoclaw-setup.md:79` (and README.md-style note)
**Issue:** The note "~11 min on first run — most of this is the NemoClaw bootstrap
(step 1)" attributes the install time to the NemoClaw image build, but the NemoClaw
bootstrap is a *prerequisite* the operator runs separately (line 9-17), not a step
inside `post-install-nemoclaw.sh`. `post-install-nemoclaw.sh` step 1 is the host
compatibility preflight (a fast probe), not the 80-step OpenShell build. The timing note
conflates the prerequisite with the installer's own runtime and may confuse operators
about where the time is spent.
**Fix:** Clarify that the ~11 min refers to the NemoClaw prerequisite build, and that
`post-install-nemoclaw.sh` itself is fast once the sandbox is Ready.

---

_Reviewed: 2026-06-10_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
