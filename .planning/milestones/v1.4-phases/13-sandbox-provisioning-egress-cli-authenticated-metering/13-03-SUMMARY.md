---
phase: 13-sandbox-provisioning-egress-cli-authenticated-metering
plan: 03
status: complete
requirements: [NCCLI-02]
---

# 13-03 SUMMARY — Live authenticated metering + spike 003 VALIDATED

## What was delivered

Closed **NCCLI-02 / SC4** for real: ran the full `scripts/post-install-nemoclaw.sh`
provisioning flow against the live NemoClaw sandbox (host **34.224.27.67**, sandbox
**revenium-spike**) with a real Revenium API key (D-LIVE). The authenticated
`revenium meter completion` returned **HTTP 2xx** — a created `metered-event` resource
(`id 36597852-c046-4ef2-b79e-4c52ac1c1627`, with `signature`), tagged
`--task-type install-smoke-test`. All five ledger keys present; a re-run emitted **no
second event** (exactly-once, D-06). Spike 003 flipped PARTIAL → **VALIDATED** in the
README (with a dated closure note) and the SKILL.md verdict table.

## Live-smoke findings (3 real defects the hermetic stub could not catch)

The hermetic suite (Plan 02) was green, but the real NemoClaw gRPC exec + real revenium
CLI surfaced three defects. Each is now fixed in `scripts/post-install-nemoclaw.sh` with a
hermetic regression guard:

1. **NemoClaw `exec` rejects newline/CR in any argv element** (`InvalidArgument`). The
   heredoc creds payload failed. Fix: single-line base64 payload + in-sandbox `base64 -d`.
   Guard: `tests/stub-nemoclaw.sh` now rejects newline-bearing argv. (commit `3b5ceda`)
2. **The CLI reads the API key from the `api-key:` config field, not `key:`.** A `key:`
   line is silently ignored (`config show` → "API Key: (not set)" while team-id read fine).
   Fix: write `api-key:`. Guard: GROUP-H decodes the base64 creds payload and asserts the
   field name. (commit `bc6ab5f`)
3. **A meter SUCCESS returns the created `metered-event` resource object, not a
   `{"status":200}` envelope.** The classifier false-negatived a genuine 2xx. Fix: match the
   resource shape. Guard: stub emits the real success shape so GROUP-G exercises it.
   (commit `305e74a`)

## Key files changed

- `.claude/skills/spike-findings-openclaw-revenium/sources/003-revenium-cli-in-sandbox/README.md` — verdict VALIDATED + dated live-2xx closure note + corrected `api-key:` field fact
- `.claude/skills/spike-findings-openclaw-revenium/SKILL.md` — spike-verdicts row 003 → VALIDATED
- `.claude/skills/spike-findings-openclaw-revenium/references/revenium-cli-and-metering.md` — documented the `api-key:` field + meter success-shape (alongside the existing newline-argv note)
- (Wave-2 script/test, fixed here): `scripts/post-install-nemoclaw.sh`, `tests/stub-nemoclaw.sh`, `tests/test_nemoclaw_provisioning.sh`

## Verification

- Live: authenticated 2xx (created metered-event), all five ledger keys, config.yaml mode 600,
  CLI v1.2.0 delivered, exactly-once re-run (no second event, probe skipped via ledger).
- Hermetic: `tests/test_nemoclaw_provisioning.sh` 17/17; `tests/test_install_dispatcher.sh` 10/10.
- Task 2 automated check: `grep VALIDATED` passes in both README and SKILL.md; no other spike rows changed.

## Notes / follow-ups

- **Security:** during a `config set` diagnostic the real API key printed in plaintext in
  diagnostic output (config set leaves a pre-existing `key:` line in the file). It was scrubbed
  from all local temp files + harness logs. Operator advised to consider rotating the D-LIVE key.
- The host config was corrected in place (`key:`→`api-key:`) and the `meter-probe-passed` ledger
  key set from the proven 2xx, so exactly-once held at a single real billable event.

## Self-Check: PASSED
