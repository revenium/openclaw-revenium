---
phase: 17-live-host-fact-finding-spike
verified: 2026-09-24T00:00:00Z
status: human_needed
score: 5/5 must-haves verified (documentary determinations); 0 failed; 8 human-judgment items outstanding
behavior_unverified: 0
overrides_applied: 0
gaps: []
human_verification:
  - test: "Confirm the HTTP 400 'Missing request parameter: teamId' classification in 007/README.md Finding 7 (egress+auth proven, account-scoping incomplete) is sound, based on the CLI exit-code semantics argument (exit 4 validation vs exit 2 auth) rather than re-running with a different key."
    expected: "A human agrees the reasoning correctly distinguishes 'egress/auth failed' from 'egress/auth succeeded, a required parameter is simply missing from this credential set.'"
    why_human: "Flagged human_judgment:true by 17-01-SUMMARY.md D4 — an interpretive call about a 4th, unanticipated CLI outcome."
  - test: "Confirm 010/README.md's NO verdict — reached from objective telemetry (promptChars, tool-call diversity, duration) contradicting the model's own narrated claims — is a sound basis for a binary SPIKE-03 verdict that deletes Phase 21 and moves ATTR-01 to Future Requirements."
    expected: "A human agrees the telemetry-over-narrative methodology is valid and the single-pairing NO result correctly resolves to NO under D-06's binary framing (rather than requiring the sandbox pairing to also fail before concluding NO)."
    why_human: "Flagged human_judgment:true by 17-02-SUMMARY.md D1/D3 — this call drives a costly, hard-to-reverse roadmap edit (Phase 21 deletion)."
  - test: "Confirm the SANDBOX cell's export-trajectory/doctor-inspect timeouts in 008/README.md are correctly attributed to the same systemic gateway-lifecycle contention Task 1 (17-03) found, rather than being a genuine export-trajectory approval-gate finding, before Phase 19 relies on the HOST-LOCAL 'no gate' conclusion for the sandbox path too."
    expected: "A human agrees the attribution is sound and that no approval-gate finding is being silently discarded."
    why_human: "Flagged human_judgment:true by 17-03-SUMMARY.md D3."
  - test: "Confirm that treating `session_nodes.created_via != 'cron'` as the session-id resolution mechanism is safe to build on, given no real OpenClaw-internal cron-scheduled session existed on the spike host to verify that `created_via` is actually set to `'cron'` for such a session."
    expected: "A human either accepts the structural (schema-enforced enum) argument as sufficient, or requires Phase 19 to run this confirmation as a first step before relying on the exclusion filter."
    why_human: "Flagged human_judgment:true by 17-03-SUMMARY.md D4."
  - test: "Confirm the ranking call in 008/README.md (Task 17-04) — treating candidate (a)'s schema-present-but-unexercised parentage columns as a stronger evidentiary position than candidate (c)'s confirmed structural absence, and NOT re-opening the ranking or escalating the parentage field further — is sound before Phase 19 treats candidate (a) as the settled winner."
    expected: "A human agrees this is a legitimate application of the phase's own escalation discretion (CONTEXT.md), not a least-bad promotion in violation of the phase's D-02 prohibition."
    why_human: "Flagged human_judgment:true by 17-04-SUMMARY.md D3 — directly touches the phase's central prohibition #3 about promoting a least-bad candidate."
  - test: "Read 009/README.md and 011/README.md as a Phase 19/20/23 planner who has read nothing else. Confirm the hook matrix tells you which hooks you may build on per pairing, the soak result is stated per cell rather than averaged, and every claim is one you could re-run from the text alone."
    expected: "Both documents are legible and self-contained for a cold-start downstream planner."
    why_human: "Flagged human_judgment:true by 17-05-SUMMARY.md D3 — this is the plan's own designated human-check."
  - test: "Confirm the granularity-mismatch explanation for SPIKE-04's 56-vs-18 completions/ground-truth delta (soak-summary.md) is sufficient to avoid recording D-04's 'zero missed completions' half as a straightforward FAIL, given the mismatch direction is over-reporting (real data the ground truth undercounts) not under-reporting (a lock-contention-caused loss)."
    expected: "A human agrees 'not cleanly measurable as designed' is the honest characterization, not a softened FAIL."
    why_human: "Flagged human_judgment:true by 17-05-SUMMARY.md D4."
  - test: "Invoke Skill(\"spike-findings-openclaw-revenium\") in a fresh agent context and confirm the broadened description, the new findings-index row, and references/live-host-2-0-facts.md are sufficient to start Phase 19 planning without opening .planning/spikes/ directly."
    expected: "All five SPIKE-00..04 determinations are reachable and correctly represented (including per-pairing UNRUN status) from one skill load."
    why_human: "Flagged human_judgment:true by 17-06-SUMMARY.md D4 — the plan's own designated human-check, explicitly called out in the verification brief as a known outstanding item."
---

# Phase 17: Live-Host Fact-Finding Spike Verification Report

**Phase Goal:** Before any 2.0 porting work begins, establish ground truth on a live, reproducibly-provisioned 2.0 host — the actual session read mechanism, per-model hook behavior, and whether deterministic marker dispatch is viable — since documentation research could not resolve these.
**Verified:** 2026-09-24
**Status:** human_needed
**Re-verification:** No — initial verification

## Verdict, plainly

**The phase achieved its goal.** All five SPIKE-00..04 determinations are real, evidence-backed, and — critically — honest about their own limits. Every place a downstream agent would look (spike READMEs, MANIFEST.md, the re-scoped `spike-findings-openclaw-revenium` skill, ROADMAP.md, STATE.md) represents the sandbox-blocker-caused unknowns as **open questions**, never as passes, never generalized from the standalone result. I could not find a single place where a live-host behavior was asserted from documentation instead of observation, where an unrun probe was recorded as a verdict, or where a least-bad candidate was quietly promoted to "the chosen mechanism" beyond what its evidence actually supports. This is an honest PARTIAL/NO-laden phase that is *succeeding* at its actual goal, per the brief's own framing.

The status is `human_needed`, not `passed`, because the phase's own plans deliberately flagged eight interpretive judgment calls (`human_judgment: true` in the SUMMARY coverage blocks) that a human should confirm before downstream phases lean on them — this is the phase working as designed, not a defect. Separately, I found one concrete, non-blocking documentation-consistency gap: REQUIREMENTS.md's own SPIKE-00..04 checkboxes/traceability rows were never flipped to reflect completion, despite every SUMMARY claiming `requirements-completed` for them. See `## Gaps Summary` below.

## Goal Achievement

### Observable Truths

Derived from ROADMAP.md's five stated Success Criteria for Phase 17 (Option A — roadmap contract).

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | A Linux host is provisioned and reproducible (OpenClaw `>=2026.8.1`, Node `>=24.16`, Docker, NemoClaw `>=v0.0.128`), with steps recorded so the same state can be reached again | ✓ VERIFIED | `.planning/spikes/007-live-2-0-host-provisioning/README.md` + `provision-2-0-host.sh` + `provision-run.log`. Standalone: OpenClaw `2026.9.6 (eb377ac)`, Node `v24.21.0`, Docker `29.8.1`. NemoClaw `v0.0.128`, in-sandbox OpenClaw `2026.9.1 (ad6fe23)`. Re-run proof: second run exits 0, zero install actions, 14/14 pass lines (`provision-run.log` "Task 4" section). Explicit-refusal proven against a naive-comparison-defeating case (`2026.8.9` vs floor `2026.8.10`). |
| 2 | Operator can read a written, evidence-backed determination of how the skill should read completions/toolCalls from the 2.0 SQLite session store | ✓ VERIFIED | `.planning/spikes/008-sqlite-session-read-path/README.md` — direct SQLite read (candidate a) wins tie-break over `export-trajectory` (candidate b) on 3/4 D-02 fields (usage, model id, toolCalls all zero-loss on both); the 4th field (session parentage) is explicitly recorded as **unmet by any candidate**, with an escalation path stated rather than a least-bad promotion (satisfies prohibition #3 — see `## Prohibition Compliance` below). |
| 3 | Operator can read a per-model hook-firing matrix captured live, showing model-dependent gaps (B-05 class) before porting | ✓ VERIFIED | `.planning/spikes/009-hook-firing-matrix-2-0/hook-matrix.md` + `hook-fire-log.txt`. All six hooks fired on standalone/Claude with byte-verified counts (16/35/7/2/2/2, confirmed by direct `jq`-equivalent grep against the raw log, matching the README exactly). Every NemoClaw/Nemotron cell is explicitly `UNRUN`, and the B-05 question is stated as "UNRUN, not answered either way" — not inferred from the Claude column. |
| 4 | Operator can read a yes/no verdict, with evidence, on whether `command-dispatch: tool` makes marker-writing dispatch deterministic | ✓ VERIFIED | `.planning/spikes/010-command-dispatch-tool-verdict/README.md` — **NO**, with a telemetry-based (not model-self-report-based) evidence trail, a control test proving the harness reaches the real command layer, and a logically sound (not doc-inferred) generalization: since D-05/D-06 require *both* models to succeed for a YES, and the tested pairing failed, YES is impossible regardless of the untested pairing's result — the sandbox pairing's actual behavior is separately, explicitly marked "not an observed fact." |
| 5 | Operator can read a confirmation of whether the chosen SQLite read mechanism sustains per-minute cron polling without degrading the host | ✓ VERIFIED | `.planning/spikes/011-read-path-concurrency-soak/README.md` + `soak-log.txt` — HOST-LOCAL: 62/62 ticks, `lock_errors=0` on every tick (independently re-counted from the raw log, matches exactly). SSHFS cell explicitly `UNRUN`, NEMO-03 explicitly unanswered — not inferred from HOST-LOCAL. |

**Score:** 5/5 truths verified. 0 behavior-unverified. 8 flagged human-judgment items (see Human Verification Required).

### Prohibition Compliance (the phase's own standing bar)

| # | Prohibition | Result | Evidence |
|---|-------------|--------|----------|
| 1 | Must NOT assert a live-host behavior inferred from documentation rather than observed | **Honored** | Every determination cites a live command + raw output + host + date + versions (D-12 evidence standard). Spike 010's cross-pairing generalization is logical (D-06's binary framing), not doc-inferred, and is explicitly labeled "not an observed fact" for the untested pairing. |
| 2 | Must NOT record a spike verdict for a question whose probe was not actually run — an unrun question is an open question, not a PARTIAL | **Honored** | Every sandbox/NemoClaw cell across 008, 009, 010, 011 is labeled `UNRUN` (not PARTIAL, not FAIL) at the cell level. The overall spike-level verdicts (PARTIAL for 008/009/011) are for the *combination* of a real, graded HOST-LOCAL result plus an explicitly-unmet both-pairings bar — never for the unrun cell itself. |
| 3 | If no read candidate clears D-02's fidelity bar, must NOT promote the least-bad candidate to "the chosen mechanism" | **Honored** | 008/README.md explicitly separates the 3 fully-tested fields (candidate (a) wins cleanly, zero-loss, matching (b)) from the 4th field (parentage), which is stated as unmet by all three candidates, with an explicit pre-build confirmation step required before Phase 19 relies on it — not folded silently into "(a) wins." |

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `.planning/spikes/007-live-2-0-host-provisioning/README.md` + evidence files | SPIKE-00 VALIDATED determination | ✓ VERIFIED | README + `provision-2-0-host.sh`, `provision-run.log`, `tracer-turn-readback.txt`, `revenium-egress-check.txt`, `versions-resolved.txt` all present, content spot-checked |
| `.planning/spikes/008-sqlite-session-read-path/README.md` + evidence files | SPIKE-01 PARTIAL determination | ✓ VERIFIED | README + `schema-capture.sql.txt`, `sample-rows.txt`, `fidelity-matrix.md`, `session-id-resolution.txt`, `cli-surface-output.txt`, `sidecar-capture.jsonl`, `probe-*.sh`, `probe-sidecar-plugin/` all present |
| `.planning/spikes/009-hook-firing-matrix-2-0/README.md` + evidence files | SPIKE-02 PARTIAL determination | ✓ VERIFIED | README + `hook-matrix.md`, `hook-fire-log.txt` (counts independently re-verified byte-for-byte), `probe-hook-observer/` present |
| `.planning/spikes/010-command-dispatch-tool-verdict/README.md` + evidence files | SPIKE-03 NO determination | ✓ VERIFIED | README + `dispatch-run.log`, `probe-skill/` present |
| `.planning/spikes/011-read-path-concurrency-soak/README.md` + evidence files | SPIKE-04 PARTIAL determination | ✓ VERIFIED | README + `soak-summary.md`, `soak-log.txt` (62/62 ticks, zero lock errors, independently re-verified), `soak-tick.sh` present |
| `.planning/spikes/MANIFEST.md` | Extended with rows 007-011 + accrued constraints | ✓ VERIFIED | Rows 001-006 preserved (6 matches), rows 007-011 added (5 matches); Requirements block grew from 14 to 21 bullets (+7, all traceable to spikes 007-011) |
| `.claude/skills/spike-findings-openclaw-revenium/SKILL.md` + `references/live-host-2-0-facts.md` | Re-scoped skill reaching all 5 determinations in one load | ✓ VERIFIED | Findings index, verdicts table (per-pairing UNRUN status stated plainly), processed-spikes list all extended; new topic file present with Requirements/How to Build It/What to Avoid/Constraints/Origin sections, both-pairings caveat stated in three separate places within the file |
| `.claude/skills/spike-findings-openclaw-revenium/sources/007..011/` | Mirrored evidence | ✓ VERIFIED | 5 directories present; credential-pattern grep (sk-ant-, nvapi-, REVENIUM_API_KEY=, api-key:) across all mirrored + source files returned only shell-variable references (`\$REVENIUM_API_KEY`), never a literal key |
| `.planning/phases/17-live-host-fact-finding-spike/COVERAGE.md` | No-external-API-integration declaration | ✓ VERIFIED | Present, reasoned, one line |
| `CLAUDE.md` routing line | Broadened to cover live-host 2.0 verification | ✓ VERIFIED | Line 5 confirmed broadened |
| `.planning/REQUIREMENTS.md` (ATTR-01 disposition) | ATTR-01 moved to Future Requirements, Traceability/Coverage updated | ✓ VERIFIED | Lines 72, 81, 129, 140, 143, 147 all correctly reflect SPIKE-03's NO and ATTR-01's move |
| `.planning/ROADMAP.md` (Phase 21 removal) | Phase 21 deleted, no dangling references, gap documented | ✓ VERIFIED | No `### Phase 21:` section; milestone-heading note explains the gap; Progress table keeps a struck-through row; Phase 22/24 dependency lines no longer cite Phase 21; checklist (lines 24-30) omits Phase 21 |
| `.planning/STATE.md` | v2.0 Phase Map + Decisions updated to match | ✓ VERIFIED | Phase Map row for 21 struck through and marked REMOVED; Decisions list carries the SPIKE-03 verdict and consequence verbatim |

### Key Link Verification

| From | To | Via | Status | Details |
|------|-----|-----|--------|---------|
| Spike READMEs 007-011 | `spike-findings-openclaw-revenium` skill | `references/live-host-2-0-facts.md` + `sources/` mirror + verdicts table | ✓ WIRED | Topic file's Origin line names all 5 spikes; SKILL.md findings index row points to the topic file; sources/ mirror holds all 5 directories |
| 010's NO verdict | REQUIREMENTS.md / ROADMAP.md / STATE.md | Mechanical application per D-06 | ✓ WIRED | All three files cite `010-command-dispatch-tool-verdict` and agree on the consequence (verified via `grep -c` matching the SUMMARY's own self-check claim) |
| 008's read-mechanism selection | `live-host-2-0-facts.md` "How to Build It" | Direct restatement of the connection form, session-id query, and open pre-build confirmations | ✓ WIRED | Matches 008/README.md's `## Requirements / build guidance` almost verbatim, including the parentage pre-build-confirmation caveat |

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | No `TBD`/`FIXME`/`XXX`/`TODO`/placeholder patterns found in any phase-17-authored file (spike READMEs, MANIFEST.md, skill files, evidence files). The `TBD` hits in `17-VALIDATION.md` and `ROADMAP.md`'s not-yet-planned Phase 18-24 sections are pre-existing planning scaffolding for *future* phases, not phase-17 deliverables, and are the expected convention for unplanned phases. | — | — |

No blockers found.

### Human Verification Required

See frontmatter `human_verification` — 8 items, all pre-flagged by the phase's own plans (`human_judgment: true` in each SUMMARY's coverage block) as interpretive calls a human should confirm before downstream phases fully rely on them. Reproduced in full above; not repeated here for brevity.

### Gaps Summary

**No blocking gaps.** One non-blocking documentation-consistency finding:

- **REQUIREMENTS.md's SPIKE-00..04 status was never flipped to reflect completion.** Lines 20-24 (`- [ ] **SPIKE-00**...` through `SPIKE-04`) remain unchecked, and the Traceability table (lines 111-115) still reads `Pending` for all five, even though all six 17-0N-SUMMARY.md files declare `requirements-completed` for these IDs, and 007-011's determinations genuinely exist and are readable per the requirement text. This project has an established convention for this exact update — e.g. commit `6367eeb` "docs(09): mark GRDEV-01..06 complete in traceability" — that Phase 17 did not follow for SPIKE-00..04 (it *did* correctly update ATTR-01's own Traceability row as part of the SPIKE-03 consequence, so the mechanism for editing this table was in scope and used, just not extended to the other four rows). This does not affect the trustworthiness of any determination and does not block Phase 18 planning (ROADMAP.md's own phase details and success criteria, which Phase 18 actually depends on, are correct and internally consistent) — it is a bookkeeping gap in REQUIREMENTS.md itself, worth a one-commit fix before or alongside Phase 18's own kickoff.

- **Minor, non-substantive:** 17-06-SUMMARY.md's Self-Check claims MANIFEST.md's Requirements block was "24 (was 17, gained 7 net after edit consolidation)". The actual verified numbers are baseline 14 → current 21 (+7, all 7 additions, no removals/consolidation involved) — the net delta of +7 is coincidentally correct, but the baseline (17, not 14) and the "8 added, 1 consolidated" narrative in the commit message and coverage description don't match the actual diff (which added exactly 7 bullets, one per spike). All 7 bullets themselves are accurate and traceable to spikes 007-011. This is an arithmetic slip in the self-report, not a content defect.

---

*Verified: 2026-09-24*
*Verifier: Claude (gsd-verifier)*
