# Requirements: Revenium OpenClaw Skill — v2.0 OpenClaw 2.0 Cut-Over

**Defined:** 2026-09-23
**Core Value:** Agents never silently blow through token budgets — every turn is guardrail-checked and the user keeps control past a threshold — and every cost-incurring activity is metered and attributed by root session, task type, and agentic job, so spend is fully observable in Revenium with no blind spots.

**Research basis:** `.planning/research/` (STACK, FEATURES, ARCHITECTURE, PITFALLS, SUMMARY — 2026-09-23).

**Milestone framing note.** "OpenClaw 2.0" is a marketing nickname for CalVer release `2026.8.1` (2026-08-30), **not** a semver major. CalVer continues past it (`2026.9.6` current). Requirements below target a numeric floor `>= 2026.8.1`; a version-string prefix check would be a defect, not an implementation detail.

## v1 Requirements

Requirements for this milestone. Each maps to exactly one roadmap phase.

### Fact-Finding (live host)

**Target host:** `52.90.9.242` — `ssh -i ~/.ssh/hermes-sandbox.pem ubuntu@52.90.9.242`. Verified reachable 2026-09-23: bare Ubuntu 26.04 LTS x86_64, passwordless sudo, node v22.23.2, **no** openclaw / nemoclaw / docker / revenium. Provisioning it (Node `>=24.16`, Docker, OpenClaw `>=2026.8.1`, NemoClaw `>=v0.0.128`, revenium CLI) is SPIKE-00 and gates every other requirement in this milestone. The four AWS hosts used through v1.4 (`34.224.27.67`, `98.82.34.123`, `3.91.58.114`, `18.212.94.67`) are all unreachable as of 2026-09-23 and must not be planned against.

Must complete before any porting work. Research could not resolve these from documentation; all four researchers independently recommended a live-host spike first.

- [x] **SPIKE-00**: Operator has a provisioned Linux host running OpenClaw `>= 2026.8.1`, Node `>= 24.16`, Docker, and NemoClaw `>= v0.0.128`, with the provisioning steps recorded so it is reproducible
- [x] **SPIKE-01**: Operator can read an evidence-backed written determination of how the skill reads completions and toolCalls from a 2.0 SQLite session store, produced against a live 2.0 host
- [ ] **SPIKE-02**: Operator can read a per-model hook-firing matrix recorded from a live 2.0 host, so model-dependent gaps (the B-05 class) are known before porting rather than discovered in production
- [x] **SPIKE-03**: Operator can read a yes/no verdict on whether the `command-dispatch: tool` SKILL.md frontmatter field makes marker-writing deterministic, with the evidence behind it
- [ ] **SPIKE-04**: Operator can read a confirmation that the chosen SQLite read mechanism sustains per-minute cron polling without degrading the host

### Session Read Path

The milestone centerpiece. 2.0 moved sessions from per-agent JSONL to per-agent SQLite; the existing read path fails **open**, metering nothing rather than erroring.

- [ ] **READ-01**: `report.sh` reads completions from the 2.0 session store and meters each one to Revenium
- [ ] **READ-02**: `report.sh` reads toolCalls from the 2.0 session store and emits one tool-event per call
- [ ] **READ-03**: Root-session resolution resolves the root session against the 2.0 session store, replacing the JSONL parse in `get-root-session-id.py`
- [ ] **READ-04**: A session store the skill cannot read produces a loud, visible failure rather than silent zero-metering

### Version Gate & Install Health

- [ ] **GATE-01**: Install refuses an OpenClaw below `2026.8.1` with an explicit message naming both the detected and the required version — never a silent no-op
- [ ] **GATE-02**: Version detection compares numeric CalVer components, not a version-string prefix
- [ ] **GATE-03**: Install runs `openclaw doctor --fix` and surfaces its result to the operator before provisioning
- [ ] **GATE-04**: Install verifies the Node runtime meets 2.0's floor (`>=24.16 <25` or `>=26.1`) and refuses explicitly below it

### Plugin 2.0 Compliance

- [ ] **PLUG-01**: Both plugins load on a 2.0 runtime without error, built against 2.0's SDK, with the committed `dist/` rebuilt and diffed rather than reused
- [ ] **PLUG-02**: `post-install.sh` and `post-install-nemoclaw.sh` set `allowPromptInjection` alongside `allowConversationAccess`
- [ ] **PLUG-03**: Operator can verify the per-turn guardrail directive is injected every turn on 2.0 via `before_prompt_build`
- [ ] **PLUG-04**: Root-session resolution uses `subagent_spawned`/`subagent_ended` hooks instead of cross-session marker-file resolution
- [ ] **PLUG-05**: Exec observation uses `after_tool_call`

### NemoClaw / OpenShell Path

- [ ] **NEMO-01**: NemoClaw install path installs against NemoClaw `>= v0.0.128` provisioning a 2.0-generation OpenClaw, and refuses older NemoClaw explicitly
- [ ] **NEMO-02**: The `nemoclaw exec -- openclaw ...` call sequence in `post-install-nemoclaw.sh` is re-verified against NemoClaw's `0.0.127`/`0.0.128` lifecycle-ownership changes
- [ ] **NEMO-03**: The host-side metering loop reads the 2.0 session store over the SSHFS `nemoclaw share mount`

### Version Canaries

- [ ] **CNRY-01**: A canary check fails loudly when a hook the skill depends on stops firing
- [ ] **CNRY-02**: The canary runs against a live runtime rather than mocks, and its failure reaches the operator rather than only a log

### Live Validation

- [ ] **HALT-01**: Operator can confirm a real budget breach produces a hard HALT end-to-end on a 2.0 host

### Release

- [ ] **REL-01**: A ClawHub release carries all v1.4 / v1.4.1 / post-ship fixes plus 2.0 support, with the NemoClaw plugin rebuilt
- [ ] **REL-02**: A clean install from the *published* ClawHub release is verified working after publish

### Contingent

*(None active.)* The sole contingent requirement, ATTR-01, resolved 2026-09-24: SPIKE-03 returned **NO — mechanism inapplicable to this call shape** (`.planning/spikes/010-command-dispatch-tool-verdict/README.md`). Per its own stated contingency, ATTR-01 has moved to `## Future Requirements` → `### Attribution`, and the existing marker architecture ports as-is under Phase 20.

## Future Requirements

Deferred. Tracked but not in this roadmap.

### Attribution

- **JCLASS-01**: LLM `on_session_end` classifier plugin for automatic job/task inference
- **ATTR-01**: Marker-writing dispatches deterministically via `command-dispatch: tool` rather than depending on model judgment. **Moved here 2026-09-24** — SPIKE-03 returned **NO — mechanism inapplicable to this call shape**: `command-dispatch: tool` does not achieve deterministic, model-free dispatch on OpenClaw 2026.9.6, for either a human-typed or an agent-initiated trigger, on the standalone/Claude pairing (the only pairing fully tested). Source: `.planning/spikes/010-command-dispatch-tool-verdict/README.md`. The existing agent-written-marker architecture ports as-is under Phase 20.

### Metering Depth

- **GRDEV-F1**: Meter per-tick guardrail API-poll overhead as aggregated enforcement cost
- **JOUT-01**: Business-outcome reporting (`--outcome-type CONVERTED`, ROI/conversion metrics)

### Enforcement

- **JGUARD-01**: Per-job-type budget rules in `setup-guardrails.sh --interactive`

### Ecosystem

- **UPSTREAM-01**: Report/confirm externals — OpenClaw finalize-revise veto, Revenium 429-on-breach metering blackout, NemoClaw gateway wedge on tool-using turns

## Out of Scope

| Feature | Reason |
|---------|--------|
| Dual-support for OpenClaw `< 2026.8.1` | Hard floor chosen deliberately; dual-maintaining two hook contracts is what made the CalVer line fragile |
| OpenClaw's native usage/cost telemetry as a Revenium replacement | Local and session-scoped; does not reach Revenium. Complementary, not substitutive |
| `diagnostics-otel` / `llm_output` corroboration of metering | Adds a second telemetry path to reconcile without closing a known gap |
| Repairing a user's broken OpenClaw install beyond `doctor --fix` | GATE-03 runs the sanctioned repair path; deeper repair is OpenClaw's responsibility |
| Retiring the `before_prompt_build` per-turn injection mitigation | The 2026.6.6 finalize-revise veto is **not** confirmed fixed (issue #128314 open, PR #147611 unmerged) |
| Migrating archived pre-2.0 JSONL sessions into Revenium | Backfill of historical spend is a separate concern from cutting the live path over |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| SPIKE-00 | Phase 17 | Complete — VALIDATED, `007-live-2-0-host-provisioning/README.md` |
| SPIKE-01 | Phase 17 | Complete — candidate (a) direct SQLite read selected, `008-sqlite-session-read-path/README.md` |
| SPIKE-02 | Phase 17 | Partial — standalone/Claude matrix complete; NemoClaw/Nemotron half and the B-05 question UNRUN (sandbox lost mid-phase, see `phases/17-live-host-fact-finding-spike/17-SANDBOX-BLOCKER.md`). The cross-model dimension this requirement exists for is not yet answered. |
| SPIKE-03 | Phase 17 | Complete — verdict NO, mechanism inapplicable, `010-command-dispatch-tool-verdict/README.md` |
| SPIKE-04 | Phase 17 | Partial — HOST-LOCAL cell confirmed (62/62 ticks, zero lock errors); SSHFS cell UNRUN, so NEMO-03 remains unanswered. Completions-vs-ground-truth granularity mismatch open for Phase 19. |
| GATE-01 | Phase 18 | Pending |
| GATE-02 | Phase 18 | Pending |
| GATE-03 | Phase 18 | Pending |
| GATE-04 | Phase 18 | Pending |
| READ-01 | Phase 19 | Pending |
| READ-02 | Phase 19 | Pending |
| READ-03 | Phase 19 | Pending |
| READ-04 | Phase 19 | Pending |
| PLUG-04 | Phase 19 | Pending |
| PLUG-01 | Phase 20 | Pending |
| PLUG-02 | Phase 20 | Pending |
| PLUG-03 | Phase 20 | Pending |
| PLUG-05 | Phase 20 | Pending |
| ATTR-01 | — (moved to Future Requirements) | Deferred — SPIKE-03 = NO, 2026-09-24, see `010-command-dispatch-tool-verdict/README.md` |
| NEMO-01 | Phase 22 | Pending |
| NEMO-02 | Phase 22 | Pending |
| NEMO-03 | Phase 22 | Pending |
| HALT-01 | Phase 23 | Pending |
| CNRY-01 | Phase 23 | Pending |
| CNRY-02 | Phase 23 | Pending |
| REL-01 | Phase 24 | Pending |
| REL-02 | Phase 24 | Pending |

**Coverage:**
- v1 requirements: 26 total, all committed — reduced from 27 (26 committed + 1 contingent) on 2026-09-24 when SPIKE-03 returned NO and ATTR-01 moved to Future Requirements (see `### Contingent` above)
- Mapped to phases: 26/26 ✓
- Unmapped: 0 ✓
- Phases: 7 (Phases 17–20, 22–24, continuing from v1.4's Phase 16; Phase 21 removed 2026-09-24 per SPIKE-03's NO verdict)

---
*Requirements defined: 2026-09-23*
*Last updated: 2026-09-24 — SPIKE-03 returned NO (see `.planning/spikes/010-command-dispatch-tool-verdict/README.md`): ATTR-01 moved from Contingent to Future Requirements, coverage reduced to 26/26*
