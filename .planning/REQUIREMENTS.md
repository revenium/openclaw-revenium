# Requirements: Revenium OpenClaw Skill — v2.0 OpenClaw 2.0 Cut-Over

**Defined:** 2026-09-23
**Core Value:** Agents never silently blow through token budgets — every turn is guardrail-checked and the user keeps control past a threshold — and every cost-incurring activity is metered and attributed by root session, task type, and agentic job, so spend is fully observable in Revenium with no blind spots.

**Research basis:** `.planning/research/` (STACK, FEATURES, ARCHITECTURE, PITFALLS, SUMMARY — 2026-09-23).

**Milestone framing note.** "OpenClaw 2.0" is a marketing nickname for CalVer release `2026.8.1` (2026-08-30), **not** a semver major. CalVer continues past it (`2026.9.6` current). Requirements below target a numeric floor `>= 2026.8.1`; a version-string prefix check would be a defect, not an implementation detail.

## v1 Requirements

Requirements for this milestone. Each maps to exactly one roadmap phase.

### Fact-Finding (live host)

Must complete before any porting work. Research could not resolve these from documentation; all four researchers independently recommended a live-host spike first.

- [ ] **SPIKE-01**: Operator can read an evidence-backed written determination of how the skill reads completions and toolCalls from a 2.0 SQLite session store, produced against a live 2.0 host
- [ ] **SPIKE-02**: Operator can read a per-model hook-firing matrix recorded from a live 2.0 host, so model-dependent gaps (the B-05 class) are known before porting rather than discovered in production
- [ ] **SPIKE-03**: Operator can read a yes/no verdict on whether the `command-dispatch: tool` SKILL.md frontmatter field makes marker-writing deterministic, with the evidence behind it
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

- [ ] **ATTR-01** *(contingent on SPIKE-03 returning yes)*: Marker-writing dispatches deterministically via `command-dispatch: tool` rather than depending on model judgment

If SPIKE-03 returns no, ATTR-01 moves to Future Requirements and the marker architecture ports as-is. This requirement is deliberately sequenced **after** the session-read-path checkpoint so a rewrite never lands on top of an unproven migration.

## Future Requirements

Deferred. Tracked but not in this roadmap.

### Attribution

- **JCLASS-01**: LLM `on_session_end` classifier plugin for automatic job/task inference
- **ATTR-01**: (moves here if SPIKE-03 returns no)

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

Populated during roadmap creation.

| Requirement | Phase | Status |
|-------------|-------|--------|
| SPIKE-01..04 | TBD | Pending |
| READ-01..04 | TBD | Pending |
| GATE-01..04 | TBD | Pending |
| PLUG-01..05 | TBD | Pending |
| NEMO-01..03 | TBD | Pending |
| CNRY-01..02 | TBD | Pending |
| HALT-01 | TBD | Pending |
| REL-01..02 | TBD | Pending |
| ATTR-01 | TBD | Pending (contingent) |

**Coverage:**
- v1 requirements: 25 total (24 committed + 1 contingent)
- Mapped to phases: 0
- Unmapped: 25 ⚠️

---
*Requirements defined: 2026-09-23*
*Last updated: 2026-09-23 after research-driven milestone revision*
