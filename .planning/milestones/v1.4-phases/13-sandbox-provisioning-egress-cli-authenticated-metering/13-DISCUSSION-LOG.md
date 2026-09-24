# Phase 13: Sandbox Provisioning — Egress, CLI & Authenticated Metering - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-08
**Phase:** 13-sandbox-provisioning-egress-cli-authenticated-metering
**Areas discussed:** CLI delivery path, Credentials & live close, Meter probe shape, Idempotency & ledger

---

## CLI delivery path

| Option | Description | Selected |
|--------|-------------|----------|
| In-sandbox CDN fetch | Sandbox curls the GitHub release CDN + tar/install; self-contained; ship+apply gh-release-policy.yaml to widen egress | ✓ |
| Host fetch + exec push | Host downloads tarball, pushes binary via base64-over-one-shot-exec; no egress widen, no mount | |
| Pull mount forward | Bring Phase-14 `share mount` into Phase 13, place binary host-side via mount | |

**User's choice:** In-sandbox CDN fetch
**Notes:** Keeps Phase 13 self-contained — no dependency on the Phase-14 mount; accepts shipping a second host-scoped egress preset (`gh-release-policy.yaml`).

### CLI version pinning (follow-up)

| Option | Description | Selected |
|--------|-------------|----------|
| Pin + checksum | Pin explicit version, verify sha256 before install | ✓ |
| Pin, no checksum | Pin version, rely on HTTPS only | |
| Track latest release | Resolve latest tag at install time | |

**User's choice:** Pin + checksum
**Notes:** Reproducible + tamper-evident for an unattended install; upgrading requires bumping pin + checksum.

---

## Credentials & live close

| Option | Description | Selected |
|--------|-------------|----------|
| Env-in, config-file-out | Operator passes REVENIUM_* env to install; install writes /sandbox/.config/revenium/config.yaml | ✓ |
| Env-in, env-on-exec | Pass secrets inline on every exec call; no persisted config | |
| Reuse host config | Copy existing host ~/.config/revenium/config.yaml into the sandbox | |

**User's choice:** Env-in, config-file-out
**Notes:** Mirrors standalone post-install.sh; persists for the agent's own later calls; SSL_CERT_FILE still set per call.

### Live close (NCCLI-02 verification plan)

| Option | Description | Selected |
|--------|-------------|----------|
| Real key available now | Run the authenticated 2xx meter call for real on 34.224.27.67 this phase; flip spike 003 to VALIDATED | ✓ |
| Build now, defer live call to UAT | Build everything; defer the authenticated 2xx to a human UAT item | |
| Test tenant / sandbox key | Use a throwaway test tenant for the live close | |

**User's choice:** Real key available now
**Notes:** NCCLI-02 / SC4 get a genuine live close this phase; no deferral.

---

## Meter probe shape

| Option | Description | Selected |
|--------|-------------|----------|
| Gated one-shot self-check | Single `revenium meter completion` with tagged synthetic event, ledger-gated to fire once, asserts 2xx | ✓ |
| Read-only reach check | Non-metering authenticated call (sources list / config show); zero billing footprint but doesn't exercise meter write | |
| Separate verify command | Keep install side-effect-free; meter call lives in a separate operator-run smoke script | |

**User's choice:** Gated one-shot self-check
**Notes:** Closes NCCLI-02 by exercising the real meter write path; ledger gating + synthetic tagging keep the data footprint minimal/traceable.

---

## Idempotency & ledger

| Option | Description | Selected |
|--------|-------------|----------|
| Step-keyed ledger | revenium-nemoclaw.ledger with a key per step (policy / gh-policy / cli+ver+sha / creds / meter-probe); resumable + exactly-once | ✓ |
| Ledger only for meter | Natural idempotency for safe steps; single sentinel only for the billable probe | |
| No ledger, re-apply | Re-run every step idempotently each install; meter probe fires every time | |

**User's choice:** Step-keyed ledger
**Notes:** Gives the one-shot meter exactly-once gating and makes the whole provisioning path resumable after partial failure. This is the ledger Phase 12 (D-11) deferred to "when real provisioning steps exist."

---

## Claude's Discretion

- Egress reach-verification depth after `policy-add` (in-sandbox curl/CLI check, SC1) — default: yes, follow spike-002 block-vs-reach signatures.
- Testing strategy — hermetic stub tests for script logic + a confirmatory live smoke on 34.224.27.67 (mirrors Phase 12's validation architecture).
- Ledger file format/location, copied-preset filenames, synthetic meter event payload/tag wording, exact CLI subcommands/flags — left to planner/researcher against the live CLI.

## Deferred Ideas

- Host-side metering loop (`share mount` + host cron) — Phase 14 (NCMETER-01).
- Per-turn enforcement plugin (`before_prompt_build`) + marker-gate adapter — Phase 15 (NCENF-01/02).
- Skill deploy via `nemoclaw skill install` + docs/README — Phase 16 (NCDEPLOY-01/02).
- Agent's own direct in-sandbox Revenium calls beyond the install meter-probe — enabled here, exercised later.
