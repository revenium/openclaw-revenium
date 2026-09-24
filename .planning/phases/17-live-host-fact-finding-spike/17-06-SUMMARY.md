---
phase: 17-live-host-fact-finding-spike
plan: "06"
subsystem: infra
tags: [spike, findings, manifest, skill, routing, requirements, roadmap, openclaw-2-0]

requires:
  - phase: 17-01
    provides: "SPIKE-00 VALIDATED determination"
  - phase: 17-02
    provides: "SPIKE-03 binary verdict NO — mechanism inapplicable to this call shape"
  - phase: 17-03
    provides: "SPIKE-01 candidates (a)/(b) evidence and D-03's session-id resolution answer"
  - phase: 17-04
    provides: "SPIKE-01 candidate (c) evidence and the fidelity-first ranking/determination"
  - phase: 17-05
    provides: "SPIKE-02 and SPIKE-04 PARTIAL determinations"
provides:
  - "MANIFEST.md rows 007-011 and 8 new accrued 2.0 constraints in its Requirements block"
  - "Re-scoped spike-findings-openclaw-revenium skill: new references/live-host-2-0-facts.md topic file, broadened description/context/findings-index/verdicts/processed-spikes, 5 new sources/ mirrors"
  - "Broadened CLAUDE.md routing-line parenthetical"
  - "COVERAGE.md reasoned no-external-API-integration declaration"
  - "SPIKE-03's NO verdict applied mechanically: ATTR-01 moved to REQUIREMENTS.md Future Requirements, Phase 21 deleted from ROADMAP.md (no renumbering), STATE.md's v2.0 Phase Map and Decisions updated"
affects: [18-version-gate-and-install-health, 19-session-read-path, 20-plugin-2-0-sdk-compliance, 22-nemoclaw-openshell-path-on-2-0, 23-hard-halt-version-canary, 24-clawhub-release]

actuals:
  tokens: 104267
  tasks: 3
  commits: 3

tech-stack:
  added: []
  patterns:
    - "Skill re-scope in place (D-10): broaden an existing skill's description/context/findings-index/verdicts/processed-spikes rather than create a second skill, keeping a downstream agent to one skill load"
    - "Mechanical verdict-to-document application: read a written binary verdict from a spike README and apply its stated consequence to REQUIREMENTS.md/ROADMAP.md/STATE.md without re-litigating the underlying spike"
    - "Phase deletion without renumbering: remove a phase's detail section and dependency references while preserving later phases' numbers, since those numbers are referenced elsewhere (STATE.md, phase directory names)"

key-files:
  created:
    - .claude/skills/spike-findings-openclaw-revenium/references/live-host-2-0-facts.md
    - .planning/phases/17-live-host-fact-finding-spike/COVERAGE.md
  modified:
    - .planning/spikes/MANIFEST.md
    - .claude/skills/spike-findings-openclaw-revenium/SKILL.md
    - CLAUDE.md
    - .planning/REQUIREMENTS.md
    - .planning/ROADMAP.md
    - .planning/STATE.md

key-decisions:
  - "Applied SPIKE-03's NO verdict mechanically per the task's binding instruction, without re-litigating the underlying spike: ATTR-01 moved from REQUIREMENTS.md's Contingent block to Future Requirements > Attribution (with verdict variant, date, and source cited); Phase 21 removed from ROADMAP.md; Phase 22 and 24's Depends-on lines updated to drop Phase 21; Phases 22, 23, 24 kept their original numbers (no renumbering, per the plan's explicit prohibition)."
  - "Kept the Phase 21 row in ROADMAP.md's Progress table (marked 'Removed 2026-09-24') and the corresponding STATE.md v2.0 Phase Map row (struck through, marked REMOVED) rather than deleting them outright — preserves a visible, explained gap in the numbering instead of a silent jump from 20 to 22."
  - "Computed REQUIREMENTS.md's Coverage counts as 26/26 (down from 27 total / 26 committed + 1 contingent), consistent with ATTR-01 no longer being mapped to a v1 roadmap phase; Phases count corrected from 8 to 7 (17-20, 22-24)."
  - "Mirrored spikes 007-011's full evidence directories into .claude/skills/spike-findings-openclaw-revenium/sources/ only after a dedicated credential-pattern grep (sk-ant-, nvapi-, REVENIUM_API_KEY=, api-key:) across both the source spike dirs and the mirrored copies returned zero matches — confirmed clean before and after the copy, not assumed clean from the source plans' own self-checks."
  - "Wrote references/live-host-2-0-facts.md as one cohesive topic file covering SPIKE-00 through SPIKE-04 (not five separate files) since they share the one live host and gate the same downstream phases, per D-10's explicit instruction and the existing reference files' topic-not-milestone split."

requirements-completed: [SPIKE-00, SPIKE-01, SPIKE-02, SPIKE-03, SPIKE-04]

coverage:
  - id: D1
    description: "MANIFEST.md extended with rows 007-011 in the established six-column shape, and 8 new non-negotiable 2.0 constraints accrued into its Requirements block, each supported by a claim in one of the five determinations"
    requirement: SPIKE-00
    verification:
      - kind: manual_procedural
        ref: "grep -cE '^\\| 00[789] \\||^\\| 01[01] \\|' MANIFEST.md → 5; grep -cE '^\\| 00[1-6] \\|' MANIFEST.md → 6; non-table bullet count 24 (was 17, gained 7 net after edit consolidation) — all re-run and pasted in this SUMMARY's Self-Check"
        status: pass
    human_judgment: false
  - id: D2
    description: "COVERAGE.md exists with a reasoned no-external-API-integration declaration for the seal-time api-coverage gate"
    requirement: SPIKE-00
    verification:
      - kind: manual_procedural
        ref: "grep -c 'No external API integration:' COVERAGE.md → 1"
        status: pass
    human_judgment: false
  - id: D3
    description: "The spike-findings-openclaw-revenium skill is re-scoped in place — broadened description, one new topic reference file, extended findings index/verdicts table/processed-spikes list, sources/ mirror — rather than a second skill being created"
    requirement: SPIKE-01
    verification:
      - kind: manual_procedural
        ref: "references/live-host-2-0-facts.md has all 5 skeleton headings + Origin line naming spikes 007-011; SKILL.md verdict rows 5 new + 6 pre-existing; sources/ has 5 new directories; no second skill directory created (verified by git status showing only the existing skill dir touched)"
        status: pass
    human_judgment: false
  - id: D4
    description: "A downstream agent loading the re-scoped skill reaches all five determinations through one skill load, without needing to read .planning/spikes/ directly"
    requirement: SPIKE-01
    verification: []
    human_judgment: true
    rationale: "This is the plan's own designated human-check (Task 2's <verify><human-check>): a fresh agent context invoking Skill(\"spike-findings-openclaw-revenium\") should confirm the broadened description, the new findings-index row, and that live-host-2-0-facts.md is sufficient to start Phase 19 without opening .planning/spikes/. Not automatable from this executor's context — flagged for the verifier/human."
  - id: D5
    description: "SPIKE-03's NO verdict applied mechanically: ATTR-01 moved to REQUIREMENTS.md Future Requirements with its traceability row updated, Phase 21 removed from ROADMAP.md with no renumbering, and STATE.md updated to match"
    requirement: SPIKE-03
    verification:
      - kind: manual_procedural
        ref: "grep -cE binary-verdict-sentence 010/README.md → 1; grep -c ATTR-01 REQUIREMENTS.md → 5; grep -cE Phase-header-pattern ROADMAP.md → 6; grep -c 010-command-dispatch-tool-verdict across REQUIREMENTS/ROADMAP/STATE → 3 files cite it"
        status: pass
    human_judgment: false

duration: 55min
completed: 2026-09-24
status: complete
---

# Phase 17 Plan 06: Findings Wrap-Up Summary

**MANIFEST.md indexes all eleven spikes with 007-011's verdicts and 8 newly-accrued 2.0 constraints; the spike-findings-openclaw-revenium skill is re-scoped in place with a new live-host-2-0-facts.md topic file reaching all five SPIKE-00..04 determinations in one load; SPIKE-03's NO verdict is applied mechanically — ATTR-01 moved to Future Requirements, Phase 21 deleted from the roadmap without renumbering 22-24.**

## Performance

- **Duration:** ~55 min
- **Started:** 2026-09-24 (following 17-05's completion)
- **Completed:** 2026-09-24
- **Tasks:** 3
- **Files created:** 2 (plus 5 mirrored source directories, ~28 files)
- **Files modified:** 6

## Accomplishments

- Extended `.planning/spikes/MANIFEST.md` with rows 007-011 in the established `| # | Name | Type | Validates | Verdict | Tags |` shape, continuing the numbering from 006, with the pre-existing rows 001-006 and Stack-relationship bullets left untouched
- Accrued 8 new non-negotiable 2.0 constraints into MANIFEST.md's `## Requirements` block (session-read mechanism + fields to preserve, connection form, session-id resolution mechanism, per-pairing hook reliability, CalVer/Node floors + two-different-builds fact, `session_end` fallback status for the confirmed pairing, `command-dispatch: tool` inapplicability, and the soak-proven per-minute polling bound) — one bullet per hard constraint, each traceable to a specific spike determination
- Wrote `.planning/phases/17-live-host-fact-finding-spike/COVERAGE.md`, a reasoned `No external API integration:` declaration for the seal-time api-coverage gate, naming the phase's real touch points (credential provisioning for already-integrated services, one read-only Revenium API probe, a read-only third-party SQLite read, documentation) as distinct from a new integration surface
- Wrote `references/live-host-2-0-facts.md`, one cohesive new topic reference file distilling SPIKE-00 through SPIKE-04 into build guidance (Requirements/How to Build It/What to Avoid/Constraints/Origin), following the existing four reference files' skeleton exactly
- Re-scoped `SKILL.md` in place: broadened the frontmatter description to name live-host OpenClaw 2.0 verification alongside NemoClaw/OpenShell support; added the 52.90.9.242/2026-09-24 provenance line to `<context>` alongside the existing 34.224.27.67/2026-06-07 line; added a new findings-index row; appended verdict rows 007-011; appended the five new spike names to the Processed Spikes list
- Mirrored all five new spike source directories (`007-live-2-0-host-provisioning` through `011-read-path-concurrency-soak`) into `.claude/skills/spike-findings-openclaw-revenium/sources/`, after a dedicated credential-pattern grep across both the originals and the mirrored copies returned zero matches
- Broadened CLAUDE.md's single routing-line parenthetical to name live-host OpenClaw 2.0 verification, keeping the label/arrow/`Skill(...)` call shape exactly as established
- Applied SPIKE-03's binary NO verdict mechanically, per the task's explicit binding: moved ATTR-01 from REQUIREMENTS.md's `### Contingent` block to `## Future Requirements` → `### Attribution` with the verdict variant, date, and source cited; updated its Traceability row and the Coverage counts (26/26, down from 27 total); removed ROADMAP.md's `### Phase 21` section, updated Phase 22's and Phase 24's `**Depends on**` lines to drop Phase 21, and added a milestone-heading note explaining the removal — without renumbering Phases 22, 23, or 24; updated STATE.md's v2.0 Phase Map and added a Decisions-list entry recording the verdict and its consequence

## Task Commits

Each task was committed atomically:

1. **Task 1: Extend MANIFEST.md with rows 007-011, accrue the 2.0 constraints, and write COVERAGE.md** - `bfe0f5a` (docs)
2. **Task 2: Re-scope the findings skill in place and broaden the CLAUDE.md routing line** - `3b3ef2e` (feat)
3. **Task 3: Apply SPIKE-03's verdict consequence to REQUIREMENTS.md and ROADMAP.md** - `8a75b59` (docs)

## Files Created/Modified

- `.claude/skills/spike-findings-openclaw-revenium/references/live-host-2-0-facts.md` - New topic reference file synthesizing spikes 007-011
- `.planning/phases/17-live-host-fact-finding-spike/COVERAGE.md` - No-external-API-integration declaration for the api-coverage gate
- `.planning/spikes/MANIFEST.md` - Rows 007-011 added; 8 new constraint bullets accrued
- `.claude/skills/spike-findings-openclaw-revenium/SKILL.md` - Broadened description/context; extended findings-index, verdicts table, processed-spikes list
- `.claude/skills/spike-findings-openclaw-revenium/sources/007-live-2-0-host-provisioning/` … `/011-read-path-concurrency-soak/` - Five new mirrored spike source directories
- `CLAUDE.md` - Routing-line parenthetical broadened
- `.planning/REQUIREMENTS.md` - ATTR-01 moved to Future Requirements; Traceability and Coverage updated
- `.planning/ROADMAP.md` - Phase 21 section removed; dependency chain repaired; milestone-heading note added
- `.planning/STATE.md` - v2.0 Phase Map and Decisions list updated to match

## Decisions Made

See `key-decisions` in frontmatter for the full list. Summary: SPIKE-03's NO verdict was applied mechanically without re-litigating the spike itself; the Phase 21 row was kept (marked "Removed") rather than deleted outright, in both ROADMAP.md's Progress table and STATE.md's Phase Map, to leave an explained gap rather than a silent jump in numbering; REQUIREMENTS.md's Coverage counts were recomputed to 26/26; the five new spike source directories were credential-scanned both before and after mirroring into the skill's `sources/` tree; and the new topic reference file covers all five SPIKE-00..04 determinations as one cohesive file rather than five, per D-10.

## Deviations from Plan

None - plan executed exactly as written. Task 3's branch (NO verdict) was determined mechanically by reading `010/README.md`'s written verdict, per the task's own binding instruction not to re-ask or re-litigate it.

## Issues Encountered

None. All three tasks' automated `<verify>` checks passed on first run; no fix-attempt cycles were needed.

## Known Stubs

None. Every artifact this plan produced or edited reflects real content: the MANIFEST rows and accrued constraints are traceable to the five spikes' actual determinations, the new skill reference file distills real build guidance (not placeholder text), and the REQUIREMENTS.md/ROADMAP.md/STATE.md edits are the literal, mechanical consequence of SPIKE-03's written verdict.

## User Setup Required

None. This plan performed no live-host work and required no new credentials — it only edited and created documentation/skill artifacts already present in the worktree.

## Next Phase Readiness

- Phase 17 is complete: all six plans (17-01 through 17-06) have produced SUMMARY.md files, and all five SPIKE-00..04 requirements are marked complete.
- **For Phase 18 (Version Gate & Install Health):** the numeric CalVer floor (`>=2026.8.1`) and Node floor (`>=24.16 <25 || >=26.1`) are recorded in both MANIFEST.md's Requirements block and `references/live-host-2-0-facts.md`.
- **For Phase 19 (Session Read Path):** the winning read mechanism (direct SQLite, read-only, WAL-aware), the session-id resolution mechanism, and the "define one completion precisely" caveat are all in `references/live-host-2-0-facts.md` and MANIFEST.md — reachable in one skill load without opening `.planning/spikes/` directly.
- **For Phase 20 (Plugin 2.0 SDK Compliance):** confirmed that the existing agent-written-marker architecture ports as-is (SPIKE-03's NO verdict means no attribution-mechanism redesign is in scope); the six-hook reliability findings (standalone/Claude only) are recorded.
- **For Phase 22 (NemoClaw/OpenShell Path on 2.0):** the B-05 question, the SSHFS soak cell, and the sandbox pairing's entire hook matrix remain open per `17-SANDBOX-BLOCKER.md` — carried forward explicitly in `references/live-host-2-0-facts.md`'s Constraints section, not silently dropped.
- **Outstanding human-check (Task 2's own `<verify><human-check>`):** a fresh agent context should invoke `Skill("spike-findings-openclaw-revenium")` and confirm the re-scoped skill surfaces all five determinations in one load, before Phase 19 planning begins in earnest. Flagged in this SUMMARY's coverage block (D4) as `human_judgment: true`.
- No blockers. This is the phase's final plan.

---
*Phase: 17-live-host-fact-finding-spike*
*Plan: 06*
*Completed: 2026-09-24*

## Self-Check: PASSED

**Files verified present on disk:**
- `.claude/skills/spike-findings-openclaw-revenium/references/live-host-2-0-facts.md` — FOUND
- `.planning/phases/17-live-host-fact-finding-spike/COVERAGE.md` — FOUND
- `.claude/skills/spike-findings-openclaw-revenium/sources/007-live-2-0-host-provisioning/` through `/011-read-path-concurrency-soak/` — FOUND (5 directories)

**Commits verified present in git log:** `bfe0f5a`, `3b3ef2e`, `8a75b59` — all found via `git log --oneline`.

**Plan-level `<verification>` re-run:**
- `MANIFEST.md` carries rows 001-006 unchanged (6 matches) plus new rows 007-011 (5 matches); `## Requirements` gained 7 net bullets (24 vs. 17 baseline)
- `COVERAGE.md` contains `No external API integration:` (1 match) with a one-line reason
- `references/live-host-2-0-facts.md` has all five skeleton headings (5 matches) and an Origin line naming spikes 007-011
- `SKILL.md` reaches the new topic file from its findings index (1 match), carries verdict rows 001-011 (6 + 5 matches), lists all eleven processed spikes
- `.claude/skills/spike-findings-openclaw-revenium/sources/` holds a directory for each of 007-011 (5 matches)
- `CLAUDE.md` holds exactly one `Skill("spike-findings-openclaw-revenium")` routing line (1 match)
- REQUIREMENTS.md/ROADMAP.md/STATE.md cite `010-command-dispatch-tool-verdict` (3 of 3 files); ROADMAP.md retains phase sections 18, 19, 20, 22, 23, 24 (6 matches) with no `### Phase 21:` section
- `git diff --name-only <base> HEAD -- plugin plugin-nemoclaw scripts` returns empty — scope guard held
- Credential-pattern grep (`sk-ant-`, `nvapi-`, `REVENIUM_API_KEY=`) across every file this plan touched returned zero matches
