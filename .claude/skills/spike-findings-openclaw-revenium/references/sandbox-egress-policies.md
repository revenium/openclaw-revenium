# Sandbox Egress Policies (OpenShell network)

## Requirements

- The parallel install path **MUST ship + apply a `revenium` network-policy preset** for
  `api.revenium.ai`, or metering silently fails (deny-by-default egress).

## How to Build It

1. OpenShell forces all sandbox egress through a proxy at `10.200.0.1:3128`. Egress is allowlisted by
   **policy presets**. Default `suggested` set: `brew, huggingface, npm, openclaw-pricing, pypi`
   (the `brew` preset also reaches github.com). **`api.revenium.ai` is NOT included.**
2. Ship `sources/002-openshell-egress/revenium-policy.yaml` and apply it:
   ```bash
   nemoclaw <name> policy-add --from-file revenium-policy.yaml --yes   # use --dry-run to preview
   ```
   Hot-reloads (version bump, no rebuild).
3. Preset schema (model new presets on built-ins at `~/.nemoclaw/source/nemoclaw-blueprint/policies/presets/`):
   ```yaml
   preset: { name: revenium, description: "..." }
   network_policies:
     revenium:
       name: revenium
       endpoints:
         - { host: api.revenium.ai, port: 443, access: full, tls: skip }
       binaries:
         - { path: /** }
   ```
   `tls: skip` = L4 CONNECT pass-through (robust for HTTPS clients / Node 22 undici, which the L7
   REST mode breaks — #2767).
4. If installing the CLI in-sandbox via the github release tarball, also apply
   `sources/003-revenium-cli-in-sandbox/gh-release-policy.yaml` (`release-assets.githubusercontent.com`).

## What to Avoid

- **Don't assume a generic network error means "down"** — a blocked host returns proxy
  `curl: (56) CONNECT tunnel failed, response 403`. Detect this signature and tell the user to add
  the policy, not "network error."
- **Don't widen egress broadly** — presets are host-scoped (verified: a control host stays blocked
  after adding `api.revenium.ai`). Keep the Revenium preset to just the API host(s).
- Prefer host-side metering (see `revenium-cli-and-metering.md`) so metering egress needs **no**
  sandbox policy at all — only the in-sandbox agent's own direct calls would.

## Constraints

- Distinguish proxy block (`CONNECT tunnel failed, response 403`, `HTTP=000`) from a reached server
  (`HTTP/1.1 200 Connection Established` then a real status). Sandbox TLS trust = `/etc/openshell-tls/ca-bundle.pem`.

## Origin

Synthesized from spikes: 002, 003. Sources: `sources/002-openshell-egress/`, `sources/003-revenium-cli-in-sandbox/`.
