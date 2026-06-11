---
id: 16-review-deferred-findings
title: "Phase 16 code-review: deferred minor findings (WR-04, IN-01, IN-03)"
created: 2026-06-10
source: 16-REVIEW.md
relates_phase: 16
severity: low
tags: [code-review, docs, tests, nemoclaw]
---

## Deferred from 16-REVIEW.md

The Phase 16 code review (`.planning/phases/16-skill-deploy-docs/16-REVIEW.md`) raised
9 findings. The BLOCKER (CR-01) and the actionable warnings (WR-01, WR-02, WR-03, WR-05)
plus IN-02 were fixed during phase execution. These three minor items were deferred:

- **WR-04** — `tests/test_nemoclaw_provisioning.sh` GROUP I-c captures `exit_code_ic` but
  never asserts it; the ledger-key check fires before later gates so it doesn't prove a
  clean ready-path end to end. Add an explicit exit-code assertion.
- **IN-01** — `docs/nemoclaw-setup.md:11` documents a likely-placeholder install URL
  (`https://www.nvidia.com/nemoclaw.sh | bash`). Confirm the real NemoClaw install URL
  and correct it before external publication.
- **IN-03** — the "~11 min first run" note in `docs/nemoclaw-setup.md` conflates the
  NemoClaw prerequisite build time with the installer's own runtime. Clarify the timing
  breakdown.

## Why deferred

Non-blocking polish; the headline correctness defect (CR-01) and the broken doc link
(WR-01) were the priority and are fixed. These can be picked up in a docs/test polish pass.
