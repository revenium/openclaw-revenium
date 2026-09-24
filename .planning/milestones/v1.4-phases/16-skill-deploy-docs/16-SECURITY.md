---
phase: 16
slug: skill-deploy-docs
status: secured
threats_total: 7
threats_closed: 7
threats_open: 0
register_authored_at_plan_time: true
asvs_level: 1
created: 2026-06-10
---

# SECURITY.md — Phase 16: skill-deploy-docs

**Audit Date:** 2026-06-10
**Auditor:** gsd-security-auditor
**ASVS Level:** unset (default)
**Register authored at plan time:** true

---

## Threat Verification Summary

**Threats Closed:** 7/7
**Threats Open:** 0/7
**Unregistered Flags:** none

---

## Threat Register

| Threat ID | Category | Plan | Disposition | Status | Evidence |
|-----------|----------|------|-------------|--------|----------|
| T-16-01 | Tampering / Input Validation | 16-01 | mitigate | CLOSED | `scripts/post-install-nemoclaw.sh:139–141` — `if [[ ! -f "${skill_dir}/SKILL.md" ]]; then fail "SKILL.md not found at ..."` inserted before the `nemoclaw skill install` call at line 143. Guard fires hard with actionable message. |
| T-16-02 | Spoofing / silent false success | 16-01 | mitigate | CLOSED | `scripts/post-install-nemoclaw.sh:153–157` — command substitution ends with `|| true` (CR-01 guard, line 154); grep uses anchored pattern `grep -Eq '(^|[[:space:]])ready([[:space:]]|\$)'` (not unanchored `grep -q "ready"`); `fail` fires before `ledger_set` on mismatch. The CR-01 fix (commit 54b3b2d referenced in threat register) is present in the deployed code. |
| T-16-SC | Tampering | 16-01 | accept | CLOSED | No npm/pip/cargo installs in `scripts/post-install-nemoclaw.sh` or test files. The plan modifies an existing bash script and bash test harness only. Accepted risk: no package installs, no new dependencies. |
| T-16-02-DOC | Information Disclosure | 16-02 | accept | CLOSED | `docs/nemoclaw-setup.md` reviewed — all credential references use env-var names/placeholders only (`<your-api-key>`, `<your-team-id>`, `nvapi-...`, etc.). No real API keys, host secrets, or long-form credential strings present. YAML config example at line 195 uses `"your-api-key"` placeholder. |
| T-16-03-01 | Repudiation | 16-03 | mitigate | CLOSED | `.planning/phases/16-skill-deploy-docs/16-VALIDATION.md` contains three re-run live evidence sections (`## LIVE VALIDATION`, Re-run 2, Re-run 3) each with `Command:` / `Exit:` / `Output:` blocks under the CRITICAL HONESTY RULE. Human checkpoint decision recorded at line 83: `Decision: approved: SC1+SC2 verified` (2026-06-11). SC1-a/SC1-b/SC1-c evidence verbatim; failures in early runs recorded as STILL FAILING (not papered over). Blocking human checkpoint independently reviewed and approved. |
| T-16-03-02 | Denial of Service | 16-03 | mitigate | CLOSED | `.planning/phases/16-skill-deploy-docs/16-VALIDATION.md` records host-restore commands and final ledger/skill state for all three re-runs (`## Host Restore` sections, lines ~262–291, ~462–491, ~655–678). Final ledger shows all 8 keys present; `openclaw skills list → ✓ ready  💰 revenium` confirmed after each restore. Sandbox left healthy. |
| T-16-03-SC | Tampering | 16-03 | accept | CLOSED | No npm/pip/cargo installs in the live-validation plan — it runs the already-built install path and records evidence. The `--force` idempotency fix committed in Re-run 3 (`faab3be`) is a bash flag addition, not a package install. Accepted risk: no new dependencies. |

---

## Accepted Risks Log

| Threat ID | Category | Accepted Risk | Rationale |
|-----------|----------|---------------|-----------|
| T-16-SC | Tampering | No package installs in phase | Plans 16-01 modifies bash scripts and test harness only; no npm/pip/cargo invocations introduced. |
| T-16-02-DOC | Information Disclosure | Docs embed no real secrets | `docs/nemoclaw-setup.md` uses env-var names and placeholders throughout; no real API keys or host secrets present at time of audit. |
| T-16-03-SC | Tampering | No package installs in live-validation plan | Plan 16-03 runs the already-built install path and records evidence; the `--force` flag addition is bash-only. |

---

## Unregistered Flags

None — no `## Threat Flags` section was present in any of the three SUMMARY.md files for this phase. The 16-01-SUMMARY.md contains a `## Threat Surface Scan` section which confirms no new network endpoints, auth paths, file access patterns, or schema changes were introduced.

---

## Verification Evidence Details

### T-16-01 (SKILL.md guard)

- Guard inserted at `install_skill_nemoclaw()` line 139, before `nemoclaw skill install` at line 143.
- `fail` message includes actionable instruction.
- `REVENIUM_SKILL_DIR` override hook (line 133) enables hermetic test coverage via GROUP I-a.

### T-16-02 (anchored grep + || true)

- `|| true` at end of command substitution (line 154) satisfies the CR-01 mandate.
- Grep pattern `grep -Eq '(^|[[:space:]])ready([[:space:]]|\$)'` (line 155) is the anchored version confirmed in commit 54b3b2d per the threat register. The original unanchored `grep -q "ready"` that false-positived on "not-ready"/"already" is NOT present.
- `fail` call at line 156 fires before `ledger_set` at line 160 — fail-closed ordering confirmed.

### T-16-02-DOC (no real secrets in docs)

- Long-string regex scan on `docs/nemoclaw-setup.md` returned only bash command paths (`~/.openclaw/skills/revenium/scripts/install.sh --nemoclaw` etc.), not credential-length secrets.
- All credential fields are `<placeholder>` or `"your-api-key"` style.

### T-16-03-01 (live evidence accuracy)

- Three distinct re-runs documented with honest failure recording (Re-run 1 SC2 "NOT PASS"; Re-run 2 "SC1-b STILL FAILING"; Re-run 3 final verdicts PASSED/PASS).
- Human reviewer explicitly approved "SC1+SC2 verified" on 2026-06-11.

### T-16-03-02 (sandbox restore)

- Each re-run includes a `Host Restore` section documenting the specific restore commands applied and the final ledger/skill state post-restore.
- Status recorded as `RESTORED HEALTHY` in Re-run 1 and ledger state confirmed across all three runs.

---

*Generated by gsd-security-auditor. Implementation files were not modified.*
