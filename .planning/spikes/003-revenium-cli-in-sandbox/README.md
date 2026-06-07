---
spike: 003
name: revenium-cli-in-sandbox
type: standard
validates: "Given the revenium binary + state dir + REVENIUM_* env in the OpenShell sandbox, when revenium config show + a meter call run inside, then the CLI is authenticated and meters"
verdict: PARTIAL
related: [001, 002, 004]
tags: [sandbox, cli, credentials, bind-mount, tls]
host: "34.224.27.67 (sandbox revenium-spike)"
---

# Spike 003: Revenium CLI in the Sandbox

## What This Validates

The OpenShell analog of the skill's current Docker model: get the `revenium` CLI running
*authenticated* inside the sandbox, reaching `api.revenium.ai` over TLS, and submitting a meter
event. Mirrors `post-install.sh` (brew-install CLI, inject `REVENIUM_*`, generate a CA bundle,
point `SSL_CERT_FILE` at it).

## Research / sandbox facts

- Sandbox user `sandbox`, HOME `/sandbox`. Writable: `/sandbox/.openclaw`, `/home/linuxbrew`,
  `/tmp`, `/sandbox`. Read-only: `/sandbox/.nemoclaw`.
- `brew` (preinstalled), `jq`, `curl` present; `revenium` absent.
- CA bundle at `/etc/openshell-tls/ca-bundle.pem`.
- CLI config: `~/.config/revenium/config.yaml`; keys `key, api-url, team-id, tenant-id, owner-id`;
  env `REVENIUM_API_KEY` etc.; default API `https://api.revenium.ai/profitstream`.

## How to Run

```bash
# Binary delivery — brew has NO linux bottle (falls back to source build + needs gcc).
# Fetch the prebuilt release tarball directly instead (egress for the github release
# CDN added via gh-release-policy.yaml in this dir):
nemoclaw revenium-spike exec -- sh -lc 'cd /tmp && \
  curl -fsSL -o rev.tgz https://github.com/revenium/revenium-cli/releases/download/v1.2.0/revenium-cli_1.2.0_linux_amd64.tar.gz && \
  tar xzf rev.tgz && install -m755 ./revenium /sandbox/.local/bin/revenium'

# Auth + reach (set SSL_CERT_FILE to the OpenShell CA bundle):
nemoclaw revenium-spike exec -- sh -lc \
  'SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem REVENIUM_API_KEY=<key> \
   /sandbox/.local/bin/revenium sources list --output json'
```

## What to Expect

- Binary runs (`revenium config show` prints config).
- With a key: a 200/data response. Without/dummy key: a server-side `{"status":403}` JSON
  (proves the request reached Revenium — not a proxy/TLS failure).

## Investigation Trail

1. Probed sandbox: writable dirs, `brew`/`jq`/`curl` present, `revenium` absent, CA bundle present.
2. `brew tap revenium/tap` worked (github.com reachable — brew preset covers it). `brew install revenium/tap/revenium` **failed twice**: (a) release-asset download blocked → needed egress to `release-assets.githubusercontent.com` (added via `gh-release-policy.yaml`); (b) after that, brew said "cannot install from bottle … Install Clang" — **no Linux bottle, source build required.**
3. **Bypassed brew:** fetched the prebuilt `revenium-cli_1.2.0_linux_amd64.tar.gz` directly and installed the binary to `/sandbox/.local/bin/revenium`. It executes.
4. `revenium config show` works in-sandbox (reads config; shows defaults).
5. **API reach with a dummy key + `SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem`:**
   `revenium sources list` returned `{"error":"Access denied...","status":403}` — a **server-side
   auth rejection**, proving binary + TLS (CA bundle trusted) + egress (`api.revenium.ai`, opened in
   spike 002) all integrate. The only missing piece is a valid Revenium API key.
6. Stopped: an authenticated meter call needs real Revenium credentials (not available this session).

## Results

**Verdict: PARTIAL.** Everything except the authenticated meter is proven inside the sandbox:
- ✅ Binary delivered + executes (`/sandbox/.local/bin/revenium`).
- ✅ TLS works with `SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem`.
- ✅ Egress reaches `api.revenium.ai` (spike-002 policy); the Revenium **server responds** (403 on dummy key).
- ⏸ **Authenticated meter call: not yet run** — blocked on a valid Revenium API key (+ team/tenant/owner).

**Requirements for the build:**
- **Do not rely on `brew install` for the CLI in-sandbox** — no Linux bottle. Either fetch the
  release tarball directly (needs `release-assets.githubusercontent.com` egress) or, better, deliver
  the binary host-side and place it via the share mount (mirrors the Docker bind-mount model, avoids
  widening sandbox egress for a github CDN).
- Set `SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem` for the in-sandbox CLI.
- Inject `REVENIUM_*` via env or write `~/.config/revenium/config.yaml` into the sandbox.
- Combined with spike 004: the cleaner design runs the CLI **host-side** (open egress, host CA store)
  and only writes results into the sandbox via the mount — in which case the in-sandbox CLI + the
  spike-002 egress policy are only needed if the agent itself calls Revenium directly.

## To finish (reopen)

Provide a Revenium API key (+ team/tenant/owner) and run a real `revenium meter ...` call in-sandbox;
expect a success/accepted response → flip to VALIDATED.
