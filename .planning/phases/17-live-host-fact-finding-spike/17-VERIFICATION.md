---
phase: 17-live-host-fact-finding-spike
verified: 2026-09-24T18:00:00Z
status: passed
score: 5/5 must-haves verified (documentary determinations); 0 failed; 9/9 human-judgment items resolved via UAT
behavior_unverified: 0
overrides_applied: 0
re_verification:
  previous_status: human_needed
  previous_score: "5/5 must-haves verified; 8 human-judgment items outstanding"
  gaps_closed:
    - "8 human_judgment items (9 after the coverage classifier split 010's methodology/verdict-application call into two) resolved in .planning/phases/17-live-host-fact-finding-spike/17-UAT.md, all result: pass, each with a reasoned note"
    - "REQUIREMENTS.md SPIKE-00..04 traceability filled in (commit 1af29ba): SPIKE-00/01/03 marked Complete, SPIKE-02/04 correctly marked Partial (not Complete) naming their unrun half"
    - "Cold-read checks 7 and 9 (009/011 legibility; skill sufficiency for Phase 19) were performed in genuinely fresh agent contexts, found two real defects, and fixed them in-session rather than deferring (commit ff060b8)"
  gaps_remaining: []
  regressions: []
gaps: []
---

# Phase 17: Live-Host Fact-Finding Spike Verification Report

**Phase Goal:** Before any 2.0 porting work begins, establish ground truth on a live, reproducibly-provisioned 2.0 host — the actual session read mechanism, per-model hook behavior, and whether deterministic marker dispatch is viable — since documentation research could not resolve these.
**Verified:** 2026-09-24 (re-verification)
**Status:** passed
**Re-verification:** Yes — after human-verification closure

## Verdict, plainly

**The phase achieved its goal, and the previously-outstanding human-judgment items are now genuinely resolved, not just marked resolved.** My prior pass found all 5 SPIKE-00..04 determinations correct and honest, but withheld `passed` status because 8 interpretive calls were deliberately flagged `human_judgment: true` by the phase's own plans and needed a human to confirm before downstream phases rely on them. `17-UAT.md` now records all 9 of those checkpoints (the coverage classifier split one item — spike 010's methodology-vs-verdict-application call — into two, so 8 became 9) as `result: pass`, each with a specific reasoning note rather than a bare checkbox. I independently re-derived two of the load-bearing calls from the raw evidence files myself (the SPIKE-03 architectural non-re-entry argument in `010/README.md`, and the `created_via` schema-enforced-enum argument in `session-id-resolution.txt`) rather than trusting the UAT note's characterization, and both hold up exactly as described.

Two of the nine checkpoints (#7 and #9) were the phase's own designated human-checks, explicitly requiring "a reader who has seen nothing else." The brief's claim that these were performed by an independent cold read is verifiable in its effect, not just its assertion: both found real defects and fixed them in the same commit (`ff060b8`) rather than rubber-stamping. I verified the fixes directly:

- `SKILL.md`'s opening `<context>` block previously (per my prior pass's own reading, and per the commit diff) could be skimmed as implying both production pairings were validated for the v2.0 spike session. It now reads: "Only spike 007 (provisioning) reached BOTH production pairings. Spikes 008, 009, 010 and 011 — four of the five determinations — were captured on the standalone OpenClaw 2026.9.6 + Docker + Claude pairing ONLY... Cross-pairing parity was NOT established." This is unambiguous — a planner skimming just this paragraph cannot come away believing parity was established.
- `references/live-host-2-0-facts.md`'s `## What to Avoid` section now includes spike 011's untraceable-`runId` caveat verbatim (join on a structurally-correct key, never a `LIKE` substring scan) — confirmed present at lines 46-50.
- `009/README.md` and `011/README.md`, in both `.planning/spikes/` and the skill's `sources/` mirror (4 files total, confirmed identical), now carry a `versions:` frontmatter line naming Node, the standalone OpenClaw build, and the unreached NemoClaw/sandbox build, explicitly stating "the only pairing these results were captured on."

REQUIREMENTS.md's SPIKE-00..04 rows (the other gap from my prior pass) are now filled in exactly as the brief describes: SPIKE-00/01/03 are `[x]`/Complete; SPIKE-02/04 are `[ ]`/Partial, and the Traceability table names each's unrun half (SPIKE-02: "NemoClaw/Nemotron half and the B-05 question UNRUN"; SPIKE-04: "SSHFS cell UNRUN, so NEMO-03 remains unanswered") rather than glossing over it. This is the honest characterization the brief asked me to confirm, not an inflated Complete.

SPIKE-02 and SPIKE-04 remaining Partial is correctly NOT held against the phase — `17-SANDBOX-BLOCKER.md` documents that the NemoClaw sandbox became unreachable mid-phase (`Phase: Error`, an identity mismatch caused by an orchestrator lifecycle mistake, not by any spike's own action) after waves 1-2 had already completed cleanly, and every plan from that point on correctly recorded the sandbox cell as `UNRUN`, never inferring a result or weakening a bar to force a pass. This is the phase's honesty mechanism working, not a defect.

## Goal Achievement

### Observable Truths

Unchanged from the prior pass (re-checked, no regressions found) — see full table and evidence in the previous revision of this file / commit `1af29ba`. Summary:

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Host provisioned, reproducible | ✓ VERIFIED | `007-live-2-0-host-provisioning/README.md` |
| 2 | Written, evidence-backed SQLite read-mechanism determination | ✓ VERIFIED | `008-sqlite-session-read-path/README.md` |
| 3 | Per-model hook-firing matrix captured live | ✓ VERIFIED | `009-hook-firing-matrix-2-0/hook-matrix.md` |
| 4 | Yes/no verdict on `command-dispatch: tool` determinism | ✓ VERIFIED | `010-command-dispatch-tool-verdict/README.md` |
| 5 | Confirmation of whether the read mechanism sustains cron polling | ✓ VERIFIED | `011-read-path-concurrency-soak/README.md` |

**Score:** 5/5 truths verified. 0 behavior-unverified.

### Human Verification — Now Resolved

All 9 items from the prior pass's `human_verification` list are recorded `result: pass` in `17-UAT.md`, each with a reasoning note (not a bare pass). I spot-verified two directly against source evidence rather than trusting the note:

| # | Item | UAT result | Independent spot-check |
|---|------|-----------|------------------------|
| 1 | HTTP 400 classification (007 Finding 7) | pass | Not independently re-derived; CLI exit-code semantics argument is documented and internally consistent in the note. |
| 2 | Telemetry-over-narrative methodology (010) | pass | Consistent with the project's own prior B-05 lesson (self-report is unreliable); methodology is sound on its face. |
| 3 | SPIKE-03 binary verdict → Phase 21 deletion | pass | **Independently re-derived from `010/README.md` lines 113-120**: the "NO" rests on a documented architectural fact — `command-dispatch: tool` is an inbound-Gateway-message router for messages starting with `/`, a code path an agent's own mid-turn tool-call flow structurally never re-enters — which generalizes across models. Confirmed this claim is stated in the README with its own control-test evidence (Investigation Trail step 6), not asserted from documentation alone. |
| 4 | Sandbox timeout attribution (008 SANDBOX cell) | pass | Consistent with `17-SANDBOX-BLOCKER.md`'s independently-documented timeline of the same gateway-lifecycle contention. |
| 5 | `created_via != 'cron'` safe to build on | pass | **Independently re-derived from `session-id-resolution.txt` lines 106-122**: `created_via` is confirmed as a schema-enforced `CHECK` enum including `'cron'` (verified against `schema-capture.sql.txt`); the file itself flags, in the open, that no real cron-created session existed to confirm the value is actually written by an OpenClaw-internal cron trigger, and explicitly defers that confirmation to Phase 19 as a first step. This matches the UAT note precisely — nothing is glossed over. |
| 6 | Candidate (a) ranking vs least-bad-promotion prohibition | pass | `fidelity-matrix.md`'s ranking is stated as unmet-by-all-candidates on the parentage field, not resolved by promotion — consistent with the note. |
| 7 | 009/011 cold-read legibility | pass | Fix verified directly: both READMEs (source + skill mirror, 4 files) now carry a `versions:` frontmatter stamp naming Node, standalone build, and unreached sandbox build. |
| 8 | SPIKE-04 delta "not cleanly measurable" vs softened FAIL | pass | Consistent with `011/README.md`'s framing: HOST-LOCAL cell is a definitive pass on the zero-lock-error half; the completions-count delta is attributed to a stated granularity mismatch (over-reporting direction, not a lock-contention loss), and SSHFS remains explicitly UNRUN rather than folded into a pass. |
| 9 | Skill alone suffices for Phase 19 | pass | Fix verified directly: `SKILL.md`'s opening context block now explicitly states cross-pairing parity was NOT established, and the topic file's `## Constraints` section states the both-pairings caveat three times (Requirements section, `## Constraints` bullet, and the hooks-reliable-per-pairing line) plus the fixed `## What to Avoid` entry for 011's runId caveat. |

No item was found unresolved, softened, or inconsistent with its own cited evidence.

### Requirements Traceability — Now Accurate

`.planning/REQUIREMENTS.md`:
- Line 20: `[x] SPIKE-00` — Complete
- Line 21: `[x] SPIKE-01` — Complete
- Line 22: `[ ] SPIKE-02` — correctly left unchecked
- Line 23: `[x] SPIKE-03` — Complete
- Line 24: `[ ] SPIKE-04` — correctly left unchecked
- Traceability table (lines 111-115): SPIKE-02 reads "Partial — standalone/Claude matrix complete; NemoClaw/Nemotron half and the B-05 question UNRUN (sandbox lost mid-phase, see `.../17-SANDBOX-BLOCKER.md`). The cross-model dimension this requirement exists for is not yet answered." SPIKE-04 reads "Partial — HOST-LOCAL cell confirmed... SSHFS cell UNRUN, so NEMO-03 remains unanswered."

Confirmed: neither Partial row is dressed up as Complete, and each names its own unrun half rather than a vague "mostly done."

### Anti-Patterns Found

Unchanged from the prior pass — no `TBD`/`FIXME`/`XXX`/`TODO`/placeholder patterns in any phase-17-authored file. No blockers.

**Secondary finding, non-blocking, not part of this re-verification's scope but noted for completeness:** `17-REVIEW.md` (produced by a parallel code-review pass in the same session, commit `1af29ba`) flags `WR-01` — a raw evidence file, `cli-surface-output.txt`, contains a closing summary-table line that overclaims `export-trajectory`'s session-parentage fidelity relative to its own detailed verdict 120 lines earlier in the same file. The canonical determination (`008/README.md` and `fidelity-matrix.md`, both of which I verified directly in this and the prior pass) is unaffected and correctly states parentage as unmet by all candidates. This is a raw-evidence-file inconsistency, not a determination-level defect, and does not change the phase's status.

### Gaps Summary

**None remaining.** Both items from the prior pass are closed:
1. The 8 (→9) human-judgment items are resolved in `17-UAT.md` with reasoned passes, two of which I independently re-derived from source evidence.
2. REQUIREMENTS.md's SPIKE-00..04 rows are filled in accurately, correctly distinguishing Complete from Partial.

The prior pass's minor arithmetic-slip note (MANIFEST.md's Requirements-block delta description in 17-06-SUMMARY.md's self-check) remains an unfixed but immaterial self-report inaccuracy — the underlying MANIFEST.md content itself was already confirmed correct in the prior pass and is not re-litigated here as it does not affect any determination or block Phase 18.

---

*Verified: 2026-09-24 (re-verification)*
*Verifier: Claude (gsd-verifier)*
