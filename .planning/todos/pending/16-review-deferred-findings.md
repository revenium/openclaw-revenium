---
id: 16-review-deferred-findings
title: "Phase 16 code-review: deferred minor findings (WR-04, IN-03 open; IN-01 resolved)"
created: 2026-06-10
updated: 2026-06-11
source: 16-REVIEW.md
relates_phase: 16
severity: low
tags: [code-review, docs, tests, nemoclaw]
---

## Deferred from 16-REVIEW.md

The Phase 16 code review (`.planning/phases/16-skill-deploy-docs/16-REVIEW.md`) raised
9 findings. The BLOCKER (CR-01) and the actionable warnings (WR-01, WR-02, WR-03, WR-05)
plus IN-02 were fixed during phase execution. Status of the three deferred minor items,
re-checked during the **v1.4.1 doc reconciliation (2026-06-11)**:

- **WR-04 — STILL OPEN (minor).** `tests/test_nemoclaw_provisioning.sh` GROUP I-c captures
  `exit_code_ic` (line 480) but still only asserts the `skill-installed-nemoclaw` ledger
  key — the captured exit code is never asserted, so the happy-path doesn't prove a clean
  end-to-end ready exit. Add an explicit `[[ "${exit_code_ic}" -eq 0 ]]` assertion.
- **IN-01 — RESOLVED.** The NemoClaw install URL in `docs/nemoclaw-setup.md:11`
  (`https://www.nvidia.com/nemoclaw.sh | bash`) is confirmed correct — NemoClaw is an
  NVIDIA product (the in-sandbox model is Nemotron), so the `nvidia.com` domain is the
  real install source, not a placeholder. No change needed.
- **IN-03 — STILL OPEN (minor).** The "first install takes ~11 minutes (80-step OpenShell
  image build)" note in `docs/nemoclaw-setup.md:13` sits in the NemoClaw **prerequisites**
  section and attributes the time to the OpenShell image build (the NemoClaw prereq), so
  it's clarified by context — but an explicit "this is NemoClaw's own first-run build, not
  the revenium installer's runtime" breakdown would remove all ambiguity.

## Why deferred

Non-blocking polish. The headline correctness defect (CR-01) and the broken doc link
(WR-01) were the priority and are fixed; IN-01 is resolved. WR-04 (test assertion) and
IN-03 (timing-note wording) remain as a small docs/test polish pass.
