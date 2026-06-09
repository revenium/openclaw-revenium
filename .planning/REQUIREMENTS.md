# Requirements — v1.4 NemoClaw/OpenShell Support

**Milestone goal:** Let the Revenium skill optionally run under NemoClaw inside an OpenShell sandbox via a parallel install path that leaves the existing standalone OpenClaw + Docker path untouched.

**Basis:** 6 spikes in `.planning/spikes/` (MANIFEST.md, WRAP-UP-SUMMARY.md) + the `spike-findings-openclaw-revenium` skill. Feasibility proven end-to-end on live host 34.224.27.67.

## v1.4 Requirements

### Install & Detection (NCINST)
- [x] **NCINST-01**: Operator can install the Revenium skill onto a NemoClaw/OpenShell target via a parallel install path that leaves the standalone OpenClaw + Docker path untouched.
- [x] **NCINST-02**: The install path detects a NemoClaw/OpenShell target (Linux + Docker) and refuses explicitly on unsupported hosts (macOS) rather than silently no-opping.

### Sandbox Egress (NCEGRESS)
- [x] **NCEGRESS-01**: The install path ships and applies a host-scoped `revenium` network-policy preset so the sandbox can reach `api.revenium.ai`; a missing/blocking policy is surfaced as such (not a generic network error).

### CLI in Sandbox (NCCLI)
- [x] **NCCLI-01**: The `revenium` CLI is delivered into the sandbox (prebuilt binary, not a brew bottle) and authenticates via `REVENIUM_*` with `SSL_CERT_FILE` pointed at the OpenShell CA bundle (`/etc/openshell-tls/ca-bundle.pem`).
- [x] **NCCLI-02**: An authenticated meter call succeeds against Revenium from the NemoClaw deployment (closes spike 003's pending authenticated-meter step).

### Metering Loop (NCMETER)
- [x] **NCMETER-01**: A host-side metering loop (host cron + `nemoclaw share mount`) keeps `guardrail-status.json` current for the in-sandbox agent — without per-tick `nemoclaw exec` and without an in-sandbox daemon.

### Enforcement (NCENF)
- [x] **NCENF-01**: The mandatory per-turn guardrail directive reaches the agent on every turn via an OpenClaw `before_prompt_build` plugin (authored from the official scaffold / mirroring the nemoclaw plugin), so halt and warn-and-ask enforcement work under NemoClaw.
- [x] **NCENF-02**: Task/job marker writing works under NemoClaw — the existing `before_agent_finalize` marker-gate plugin is deployed/adapted into the sandbox — so attribution flows.

### Skill Deploy & Docs (NCDEPLOY)
- [ ] **NCDEPLOY-01**: The Revenium skill is deployed into the sandbox via `nemoclaw skill install` and discovered by the agent (`✓ ready`).
- [ ] **NCDEPLOY-02**: Setup docs cover the NemoClaw install path, prerequisites, and the macOS-unsupported constraint.

## Future Requirements (deferred)

- Hermes agent support (NemoClaw's second agent) — out of scope for v1.4 (OpenClaw-only).
- GPU-passthrough / local-inference NemoClaw deployments — v1.4 targets cloud-routed inference.
- Automated NemoClaw target provisioning — operators bring their own NemoClaw host.

## Out of Scope

- **Replacing the standalone OpenClaw + Docker path** — v1.4 is strictly additive (parallel path). Reason: the existing path is shipped and validated; NemoClaw support must not regress it.
- **Baking the skill into a custom OpenShell image** (`nemoclaw onboard --from`) — runtime deploy via `nemoclaw skill install` + plugin install is sufficient and lighter. Reason: avoids owning image builds; revisit only if runtime install proves insufficient.
- **macOS support** — NemoClaw is Linux-only (spike 001). Reason: upstream constraint, not ours to fix.

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| NCINST-01 | Phase 12 | Complete |
| NCINST-02 | Phase 12 | Complete |
| NCEGRESS-01 | Phase 13 | Complete |
| NCCLI-01 | Phase 13 | Complete |
| NCCLI-02 | Phase 13 | Complete |
| NCMETER-01 | Phase 14 | Complete |
| NCENF-01 | Phase 15 | Complete |
| NCENF-02 | Phase 15 | Complete |
| NCDEPLOY-01 | Phase 16 (deploy step pulled into Phase 15 per D-08) | Pending |
| NCDEPLOY-02 | Phase 16 | Pending |
