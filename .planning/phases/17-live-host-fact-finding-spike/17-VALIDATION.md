---
phase: "17"
slug: "live-host-fact-finding-spike"
# status lifecycle: draft (seeded by plan-phase) → validated (set by validate-phase §6)
# audit-milestone §5.5 distinguishes NOT-VALIDATED (draft) from PARTIAL (validated + nyquist_compliant: false) (#2117)
status: draft
nyquist_compliant: false
wave_0_complete: false
created: "2026-09-23"
---

# Phase 17 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
>
> **Phase shape note (from 17-RESEARCH.md `## Validation Architecture`):** this phase
> produces no application code and no automated test suite. Its verification unit is a
> live probe command plus its raw pasted output (CONTEXT.md D-12's evidence standard),
> not an automated assertion. Sampling is therefore **per-probe**, not per-commit.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | None — verification unit is a live command + verbatim raw output (D-12) |
| **Config file** | none — Wave 0 writes the probe scripts |
| **Quick run command** | Re-run any single probe script from its spike dir against the live host |
| **Full suite command** | `bash provision-2-0-host.sh` then each spike probe script in sequence |
| **Estimated runtime** | Provisioning ~10–20 min; soak windows are set by the planner (D-04) |

---

## Sampling Rate

- **After every task commit:** re-run that task's own probe command and confirm its raw output is captured in the spike dir
- **After every plan wave:** re-run the wave's probe scripts end-to-end against the live host
- **Before `/gsd-verify-work`:** all five determinations (SPIKE-00…SPIKE-04) written to `.planning/spikes/007–011/README.md` and consumable
- **Max feedback latency:** one probe run (no automated re-run cadence within the phase)

---

## Per-Task Verification Map

> Seeded at plan time; `validate-phase` fills task IDs once `*-PLAN.md` exists.

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| TBD | TBD | 0 | SPIKE-00 | — | Real keys are spike-scoped and never committed (D-16) | live probe | `bash provision-2-0-host.sh && openclaw --version && node --version && docker --version && nemoclaw --version` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | SPIKE-01 | — | Read path is read-only + WAL-aware against a live store (D-01) | live probe | probe scripts for candidates (a) direct sqlite3, (b) `openclaw sessions` subcommands, (c) plugin-hook sidecar — output diffed against a known ground-truth turn count | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | SPIKE-02 | — | N/A | live probe | trigger one qualifying turn per hook per pairing; assert via each hook's own log/counter across the 6 fixed hooks (D-08) | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | SPIKE-03 | — | N/A | live probe | scope probe on `command-dispatch: tool` first; then, only if scoped-in, a sustained two-model determinism run (D-05, D-07) | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | SPIKE-04 | — | Concurrent reads never corrupt or lock the agent's live store (D-04) | live probe | per-minute cron soak against a ground-truth completion count, under live agent traffic | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `provision-2-0-host.sh` — idempotent provisioning script under the spike dir (D-14); SPIKE-00's core deliverable. Must include a swapfile step — the host has 7.7 GiB RAM / 0 swap, below NemoClaw's documented ~8 GB floor.
- [ ] Probe scripts for SPIKE-01 candidates (a) / (b) / (c) — do not yet exist
- [ ] Shared long-running live-traffic harness for SPIKE-02 and SPIKE-04 — do not yet exist
- [ ] SPIKE-03 scope-probe fragment (`command-dispatch: tool`) — does not yet exist

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Determination documents are written and consumable | SPIKE-01…SPIKE-04 | "Operator can read an evidence-backed determination" is a readability/completeness judgement, not an assertion | Read each `.planning/spikes/007–011/README.md`; confirm it follows `.planning/spikes/CONVENTIONS.md` and that every claim carries its exact command, trimmed raw output, host, date, and OpenClaw/NemoClaw/Node versions (D-12) |
| Findings are discoverable downstream | D-10 | Discoverability depends on skill description + CLAUDE.md routing wording, not on a command's exit code | Confirm `spike-findings-openclaw-revenium` SKILL.md description is re-scoped to whole-project live-host findings and the new topic reference file exists alongside the existing four |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < one probe run
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
