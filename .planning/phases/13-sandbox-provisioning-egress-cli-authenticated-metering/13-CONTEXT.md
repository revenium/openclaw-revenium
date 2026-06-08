# Phase 13: Sandbox Provisioning — Egress, CLI & Authenticated Metering - Context

**Gathered:** 2026-06-08
**Status:** Ready for planning

<domain>
## Phase Boundary

Turn the Phase 12 NemoClaw stub functions into real provisioning of the OpenShell sandbox. Three things become true:

1. **Egress** — the install ships and applies a host-scoped `revenium` network-policy preset so the sandbox can reach `api.revenium.ai` over HTTPS; a missing/blocked policy is surfaced as a *policy gap*, not a generic network error.
2. **CLI delivery** — the prebuilt `revenium` binary is installed inside the sandbox at `/sandbox/.local/bin/revenium` (not brew), authenticated via `REVENIUM_*` with `SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem`.
3. **Authenticated metering** — an authenticated `revenium meter completion` call from inside the sandbox returns HTTP 2xx against the real Revenium API, closing spike 003's pending authenticated-meter step.

**Consumes:** NCEGRESS-01, NCCLI-01, NCCLI-02.

**Out of scope (later phases):** the host-side metering loop / `share mount` (Phase 14, NCMETER-01); the `before_prompt_build` enforcement plugin + marker-gate adapter (Phase 15); `nemoclaw skill install` + docs (Phase 16). This phase delivers provisioning + a one-shot authenticated meter *proof*, not the steady-state metering loop.

</domain>

<decisions>
## Implementation Decisions

### CLI delivery (NCCLI-01)
- **D-01:** Deliver via **in-sandbox CDN fetch** — the sandbox runs `curl` to the GitHub release CDN, then `tar` + `install -m755` to `/sandbox/.local/bin/revenium` (spike 003's proven path). Self-contained in Phase 13 — deliberately does **not** depend on the Phase-14 `share mount`. Rejected: host-fetch + base64-over-`exec` push (awkward), and pulling the mount forward (re-scopes the phase).
- **D-02:** **Pin an explicit CLI version + verify a sha256 checksum** before install. Pin lives in a variable (start from spike 003's `v1.2.0`, or a newer pinned release); the downloaded tarball/binary is checked against a known sha256 and the install aborts on mismatch. Reproducible + tamper-evident for an unattended install. Upgrading means bumping both the version pin and the checksum.

### Egress policy (NCEGRESS-01)
- **D-03:** Ship and `policy-add` **two** host-scoped presets: `revenium-policy.yaml` (`api.revenium.ai:443`, `tls: skip` = L4 CONNECT pass-through) **and** `gh-release-policy.yaml` (`release-assets.githubusercontent.com`) — the latter is required because D-01 fetches the tarball in-sandbox. Keep both presets narrow/host-scoped; do not widen egress broadly.
- **D-04:** **Detect the proxy-block signature** and surface it as a policy gap, not a network error. The block signature is `curl: (56) CONNECT tunnel failed, response 403` / `HTTP=000`; a *reached* server is `HTTP/1.1 200 Connection Established` followed by a real status (e.g. a `{"status":403}` auth rejection). On the block signature, tell the operator to add/apply the policy. (Default depth, riding spike-002 signatures — left to planner per Claude's Discretion below.)

### Credentials (NCCLI-01)
- **D-05:** **Env-in, config-file-out.** The operator supplies `REVENIUM_API_KEY` (+ team/tenant/owner) as env vars to the install (mirrors the standalone `post-install.sh` model). The install writes them into the sandbox as `/sandbox/.config/revenium/config.yaml` so they persist across sandbox sessions and the agent's own later calls — no secrets on every `exec` command line. `SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem` is still set per in-sandbox CLI call.

### Authenticated meter probe (NCCLI-02)
- **D-06:** **Gated one-shot self-check.** The install runs a single `revenium meter completion` with a clearly-tagged **synthetic** event (metadata marking it an install smoke-test) and asserts HTTP 2xx. It is gated by the ledger (D-07) so it fires **once per provisioning**, not on every idempotent re-run — avoiding repeated synthetic events polluting real metering data.
- **D-LIVE:** A **real Revenium API key (+ team/tenant/owner) is available now**, so NCCLI-02 / SC4 get a genuine authenticated-2xx close this phase on live host `34.224.27.67` — flipping spike 003 from PARTIAL to VALIDATED. (No deferral to UAT for the authenticated call.)

### Idempotency (provisioning resume)
- **D-07:** Introduce a **step-keyed `revenium-nemoclaw.ledger`** (host-side, e.g. under `~/.nemoclaw/` or alongside install state). Keys, one per completed step: `revenium-policy-applied`, `gh-release-policy-applied`, `cli-delivered` (records version + sha256), `creds-written`, `meter-probe-passed`. Each step checks its key and skips if present; the one-shot meter probe only fires when `meter-probe-passed` is absent. Makes the whole provisioning path resumable after a partial failure and gives the billable probe an exactly-once guarantee. This is the ledger Phase 12 (D-11) deferred to "when real provisioning steps exist."

### Claude's Discretion
- **Egress reach-verification depth (SC1):** whether/how to run an in-sandbox `curl`/CLI reach check to `api.revenium.ai` immediately after `policy-add` as part of install — default: yes, follow the spike-002 block-vs-reach signatures. Exact probe command and placement left to planner/researcher.
- **Testing strategy:** Phase 13 inherently touches a live sandbox + real API (unlike Phase 12's fully-hermetic harness). Default split — **hermetic stub tests** for script logic (arg/env parsing, ledger gating, version/sha verification, 403-vs-reach error-signature classification) **+ a confirmatory live smoke** on `34.224.27.67` — mirroring Phase 12's validation architecture. Exact stubbing approach (mock `nemoclaw`/`curl`, env overrides) left to planner per the existing `tests/` conventions.
- Exact ledger file format/location, preset filenames when copied into `scripts/`, the synthetic meter event's payload/tag wording, and the precise CLI subcommands/flags (`meter completion` arg surface) — left to planner/researcher against the live CLI.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Spike findings (primary build basis)
- `.claude/skills/spike-findings-openclaw-revenium/references/sandbox-egress-policies.md` — deny-by-default proxy at `10.200.0.1:3128`; ship + `policy-add` a host-scoped `revenium` preset; preset schema (`endpoints`/`binaries`, `tls: skip`); the `CONNECT tunnel failed, response 403` block signature vs a reached server; host-scoped presets don't widen other hosts. **Core NCEGRESS-01 reference.**
- `.claude/skills/spike-findings-openclaw-revenium/references/revenium-cli-and-metering.md` — no Linux brew bottle → prebuilt tarball install; `SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem`; `REVENIUM_API_KEY` (+ team/tenant/owner) via env or `~/.config/revenium/config.yaml`; in-sandbox HOME `/sandbox`, config/state `/sandbox/.openclaw`. **Core NCCLI-01/02 reference.**
- `.claude/skills/spike-findings-openclaw-revenium/sources/003-revenium-cli-in-sandbox/README.md` — the exact tarball-fetch + install + auth-reach commands; the dummy-key `{"status":403}` server-side reach proof; the explicit "authenticated meter call not yet run — provide a real key to flip to VALIDATED" reopen note.
- `.claude/skills/spike-findings-openclaw-revenium/sources/002-openshell-egress/revenium-policy.yaml` — the `revenium` network-policy preset to ship + apply.
- `.claude/skills/spike-findings-openclaw-revenium/sources/002-openshell-egress/README.md` — egress proxy facts, `policy-add` usage, `--dry-run` preview, hot-reload behavior.
- `.claude/skills/spike-findings-openclaw-revenium/sources/003-revenium-cli-in-sandbox/gh-release-policy.yaml` — the `release-assets.githubusercontent.com` egress preset required for the in-sandbox CDN fetch (D-01/D-03).
- `.claude/skills/spike-findings-openclaw-revenium/SKILL.md` — requirements + spike-verdict index; the non-negotiable constraints list.

### Phase scope
- `.planning/ROADMAP.md` § Phase 13 — goal + 4 success criteria + spike artifacts consumed.
- `.planning/REQUIREMENTS.md` — NCEGRESS-01 (ship+apply egress preset, surface policy gap), NCCLI-01 (prebuilt CLI in sandbox + `REVENIUM_*`/`SSL_CERT_FILE` auth), NCCLI-02 (authenticated meter call succeeds, closes spike 003).

### Existing code to extend / preserve
- `scripts/post-install-nemoclaw.sh` — the Phase 12 NemoClaw-path skeleton whose stub functions this phase fills in (preflight gate + CLI check already real; provisioning stubs become real). Follow its `info/warn/step/fail` + `command_exists` idioms and `set -euo pipefail` discipline.
- `scripts/install.sh` — the Phase 12 dispatcher (target detection + D-03 routing + macOS refusal); entry point, unchanged in contract.
- `scripts/probe-host-compat.sh` — the host preflight hard gate (exec'd, never sourced); precedes provisioning.
- `.planning/phases/12-parallel-install-scaffolding-detection/12-CONTEXT.md` — Phase 12 decisions, esp. D-11 (ledger deferred to here) and the identity-vs-capability routing split.
- `tests/` — hermetic bash/python harness conventions (see `tests/test_install_dispatcher.sh` from Phase 12) for the stub-testable script logic.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `post-install-nemoclaw.sh` stub functions (Phase 12): named Phase 13+ stubs that this phase replaces with real `policy-add`, CLI delivery, creds-write, and meter-probe steps.
- `post-install.sh` helper idioms (`info`/`warn`/`step`/`fail`, `command_exists`) and the standalone `REVENIUM_*` env model — mirror them for consistent UX and credential entry.
- Spike preset YAMLs (`revenium-policy.yaml`, `gh-release-policy.yaml`) — copy into `scripts/` as first-class shipped assets (the skill does not ship `spike-findings/sources/`, so the presets must be present on the target at install time — same rationale as Phase 12's D-09 for `probe-host-compat.sh`).

### Established Patterns
- `command_exists`-guarded, warn-and-continue idempotency — now augmented by the step-keyed ledger (D-07) for steps that must be exactly-once (the billable meter probe) or resumable (provisioning).
- `set -euo pipefail` across all scripts.
- Linux + prebuilt-tarball only for the NemoClaw path — no brew/macOS assumptions (those stay in `post-install.sh`).
- Phase 12's validation architecture: hermetic stub tests + a confirmatory live smoke on `34.224.27.67`.

### Integration Points
- Provisioning runs after the host preflight probe passes, inside `post-install-nemoclaw.sh`, against a live `nemoclaw` sandbox via `nemoclaw <name> exec` / `policy-add`.
- In-sandbox paths are fixed: HOME `/sandbox`, binary `/sandbox/.local/bin/revenium`, config `/sandbox/.config/revenium/config.yaml`, CA bundle `/etc/openshell-tls/ca-bundle.pem`.
- The authenticated meter probe is the first real Revenium API write from the NemoClaw deployment — its success is the phase's headline proof and closes spike 003.

</code_context>

<specifics>
## Specific Ideas

- The synthetic meter event must be **clearly tagged** as an install smoke-test (via event metadata) so it's distinguishable from real agent metering in Revenium.
- The egress error message must name the **policy gap** explicitly (e.g. "sandbox cannot reach api.revenium.ai — apply the revenium egress policy") and key off the proxy `403 CONNECT tunnel failed` signature — not print a generic "network error", which is the exact NCEGRESS-01 failure mode.
- The ledger records the delivered CLI **version + sha256** (not just a boolean) so a version bump invalidates `cli-delivered` and re-delivers.
- A real Revenium key is available this session → run the authenticated meter call for real on `34.224.27.67` and flip spike 003 to VALIDATED; do not stop at the dummy-key 403 reach proof.

</specifics>

<deferred>
## Deferred Ideas

- **Host-side metering loop** (`nemoclaw share mount` + host cron refreshing `guardrail-status.json`) — Phase 14 (NCMETER-01). Phase 13 deliberately avoids the mount (D-01) to stay self-contained.
- **Per-turn enforcement plugin** (`before_prompt_build`) + **marker-gate adapter** (`before_agent_finalize`) — Phase 15 (NCENF-01/02), flagged highest-risk.
- **Skill deploy via `nemoclaw skill install` + docs/README update** — Phase 16 (NCDEPLOY-01/02).
- **Agent's own direct in-sandbox Revenium calls** beyond the install meter-probe — only relevant once the agent meters directly; the in-sandbox CLI + egress policy provisioned here enable it, but the steady-state metering is host-side (Phase 14).

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 13-sandbox-provisioning-egress-cli-authenticated-metering*
*Context gathered: 2026-06-08*
