---
spike: 002
name: openshell-egress
type: standard
validates: "Given an agent in an OpenShell sandbox, when it calls the Revenium API over HTTPS, then egress succeeds (default policy or documented allowance)"
verdict: VALIDATED
related: [001]
tags: [network, egress, openshell, metering]
host: "34.224.27.67 (sandbox revenium-spike)"
---

# Spike 002: OpenShell Egress to the Revenium API

## What This Validates

Given an OpenClaw agent running in an OpenShell sandbox, when it makes an outbound HTTPS call
to the Revenium API (`api.revenium.ai`), then egress succeeds. This is the kill-shot risk: if
sandbox network policy can't be opened for the Revenium API, metering is impossible and the whole
NemoClaw-support idea is dead.

## Research

- OpenShell forces all sandbox egress through a **managed proxy at `10.200.0.1:3128`** (env in
  `/etc/profile.d/nemoclaw-proxy.sh`; `HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY` all point there;
  `NODE_USE_ENV_PROXY=1`).
- Egress is allowlisted by **network policy presets**. Default `suggested` install enables:
  `brew, huggingface, npm, openclaw-pricing, pypi`. The Revenium API host is **not** among them.
- Custom presets are added with `nemoclaw <name> policy-add --from-file <yaml> [--yes|--dry-run]`.
- Preset schema (from `~/.nemoclaw/source/nemoclaw-blueprint/policies/presets/npm.yaml`):
  ```yaml
  preset: { name: <n>, description: "..." }
  network_policies:
    <key>:
      name: <key>
      endpoints:
        - host: <host>
          port: 443
          access: full
          tls: skip        # L4 CONNECT pass-through (Node 22 undici compat, #2767)
      binaries:
        - { path: /** }
  ```
- Revenium API host: `api.revenium.ai` (from the skill's `post-install.sh`:
  "Allow outbound network access so the revenium CLI can reach api.revenium.ai").

## How to Run

```bash
# 1. Default egress (expect BLOCKED):
nemoclaw revenium-spike exec -- sh -lc 'curl -sS -o /dev/null -w "HTTP=%{http_code}\n" https://api.revenium.ai/'

# 2. Apply the custom policy:
nemoclaw revenium-spike policy-add --from-file revenium-policy.yaml --yes

# 3. Re-test (expect ALLOWED):
nemoclaw revenium-spike exec -- sh -lc 'curl -v https://api.revenium.ai/ -o /dev/null'
```
`revenium-policy.yaml` is in this spike directory.

## What to Expect

- Before policy: `curl: (56) CONNECT tunnel failed, response 403`, `HTTP=000`.
- After policy: `HTTP/1.1 200 Connection Established` → TLS handshake → server reached.
- A non-allowlisted control host (`example.com`) stays blocked → policy is host-scoped.

## Investigation Trail

1. Inspected sandbox proxy env via `exec` → all traffic routed via `10.200.0.1:3128`.
2. Default egress to `api.revenium.ai`: proxy returned `CONNECT tunnel failed, response 403`. **Blocked, as feared.**
3. Read `policy-list` (presets + active set) and `policy-add --help`; located built-in preset YAMLs under `~/.nemoclaw/source/nemoclaw-blueprint/policies/presets/`.
4. Modeled `revenium-policy.yaml` on `npm.yaml` (used `tls: skip` L4 passthrough for robustness with curl + the compiled revenium CLI).
5. `policy-add --dry-run` → "Endpoints that would be opened: api.revenium.ai"; then `--yes` → "Policy version 4 loaded (active version: 4)".
6. Re-tested: `api.revenium.ai` → `HTTP=403` with curl-rc=0 (reached the server; 403 is Revenium's own unauth response). Control `example.com` → still `CONNECT tunnel failed`.
7. Verbose capture confirmed `CONNECT tunnel established, response 200` + TLS handshake.

## Results

**Verdict: VALIDATED.** Egress to the Revenium API from inside an OpenShell sandbox is blocked
by default and is opened with a single host-scoped custom network policy — no sandbox rebuild
required (policy hot-reloaded to version 4). The kill-shot risk is cleared.

**Decisive evidence:**
```
# default:  curl: (56) CONNECT tunnel failed, response 403   HTTP=000
# after:    < HTTP/1.1 200 Connection Established
#           * CONNECT tunnel established, response 200
#           * TLSv1.3 (OUT), TLS handshake ...   CAfile: /etc/openshell-tls/ca-bundle.pem
# control:  example.com -> CONNECT tunnel failed, response 403  (still blocked)
```

**Requirements that emerge for the build:**
- The NemoClaw parallel install path **must ship + apply a `revenium` network-policy preset**
  (this `revenium-policy.yaml`) via `nemoclaw <name> policy-add --from-file`, or metering silently fails.
- Without it, the failure mode is a proxy `403 CONNECT tunnel failed` — the install path should
  detect this and tell the user to add the policy (not a generic network error).

**Surprises / carry-forward:**
- The proxy hot-reloads policy (version bump, no rebuild) — cheap to apply, good for an installer.
- Sandbox TLS trust store is **`/etc/openshell-tls/ca-bundle.pem`** — spike 003 (revenium CLI in
  the sandbox) will likely need `SSL_CERT_FILE` pointed here, mirroring the CA-bundle handling the
  skill already does for the Docker sandbox.
- Open question for 003: whether `tls: skip` (L4 passthrough) vs L7 REST mode matters for the
  compiled `revenium` CLI specifically (tested here with curl). Verify with the real CLI in 003.
