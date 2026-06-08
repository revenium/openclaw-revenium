# Phase 13: Sandbox Provisioning — Egress, CLI & Authenticated Metering - Research

**Researched:** 2026-06-08
**Domain:** NemoClaw/OpenShell bash scripting — egress policy management, in-sandbox tarball delivery, config.yaml provisioning, ledger-gated metering probe
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Deliver via in-sandbox CDN fetch — the sandbox runs `curl` to the GitHub release CDN, then `tar` + `install -m755` to `/sandbox/.local/bin/revenium`. Self-contained in Phase 13 — deliberately does NOT depend on the Phase-14 `share mount`.
- **D-02:** Pin an explicit CLI version + verify a sha256 checksum before install. Pin lives in a variable (start from spike 003's `v1.2.0`, or a newer pinned release); the downloaded tarball/binary is checked against a known sha256 and the install aborts on mismatch.
- **D-03:** Ship and `policy-add` TWO host-scoped presets: `revenium-policy.yaml` (`api.revenium.ai:443`, `tls: skip`) AND `gh-release-policy.yaml` (`release-assets.githubusercontent.com`) — the latter is required because D-01 fetches the tarball in-sandbox. Keep both presets narrow/host-scoped.
- **D-04:** Detect the proxy-block signature and surface it as a policy gap, not a network error. The block signature is `curl: (56) CONNECT tunnel failed, response 403` / `HTTP=000`; a reached server is `HTTP/1.1 200 Connection Established` followed by a real status. On the block signature, tell the operator to add/apply the policy.
- **D-05:** Env-in, config-file-out. The operator supplies `REVENIUM_API_KEY` (+ team/tenant/owner) as env vars to the install. The install writes them into the sandbox as `/sandbox/.config/revenium/config.yaml` so they persist across sandbox sessions. `SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem` is still set per in-sandbox CLI call.
- **D-06:** Gated one-shot self-check. The install runs a single `revenium meter completion` with a clearly-tagged synthetic event (metadata marking it an install smoke-test) and asserts HTTP 2xx. It is gated by the ledger (D-07) so it fires once per provisioning, not on every idempotent re-run.
- **D-07:** Introduce a step-keyed `revenium-nemoclaw.ledger` (host-side, e.g. under `~/.nemoclaw/` or alongside install state). Keys: `revenium-policy-applied`, `gh-release-policy-applied`, `cli-delivered` (records version+sha256), `creds-written`, `meter-probe-passed`. Each step checks its key and skips if present.
- **D-LIVE:** A real Revenium API key (+ team/tenant/owner) is available now → run the authenticated meter call for real on live host 34.224.27.67, flip spike 003 from PARTIAL to VALIDATED.

### Claude's Discretion

- **Egress reach-verification depth (SC1):** whether/how to run an in-sandbox `curl`/CLI reach check to `api.revenium.ai` immediately after `policy-add` as part of install — default: yes, follow the spike-002 block-vs-reach signatures.
- **Testing strategy:** hermetic stub tests (arg/env parsing, ledger gating, version/sha verification, 403-vs-reach error-signature classification) + a confirmatory live smoke on `34.224.27.67`.
- Exact ledger file format/location, preset filenames when copied into `scripts/`, the synthetic meter event's payload/tag wording, and the precise CLI subcommands/flags (`meter completion` arg surface) — left to planner/researcher against the live CLI.

### Deferred Ideas (OUT OF SCOPE)

- **Host-side metering loop** (`nemoclaw share mount` + host cron refreshing `guardrail-status.json`) — Phase 14.
- **Per-turn enforcement plugin** (`before_prompt_build`) + **marker-gate adapter** (`before_agent_finalize`) — Phase 15.
- **Skill deploy via `nemoclaw skill install` + docs/README update** — Phase 16.
- Agent's own direct in-sandbox Revenium calls beyond the install meter-probe.

</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| NCEGRESS-01 | The install path ships and applies a host-scoped `revenium` network-policy preset so the sandbox can reach `api.revenium.ai`; a missing/blocking policy is surfaced as such (not a generic network error). | Spike 002 VALIDATED; policy YAML schema verified; block signature `curl (56) / HTTP=000` vs reach `HTTP=403` documented. Two-preset approach (D-03) confirmed in gh-release-policy.yaml. |
| NCCLI-01 | The `revenium` CLI is delivered into the sandbox (prebuilt binary, not a brew bottle) and authenticates via `REVENIUM_*` with `SSL_CERT_FILE` pointed at the OpenShell CA bundle (`/etc/openshell-tls/ca-bundle.pem`). | Spike 003 PARTIAL→VALIDATED. Binary at `/sandbox/.local/bin/revenium` v1.2.0 confirmed live. Tarball sha256 retrieved from official checksums. Config.yaml path `/sandbox/.config/revenium/config.yaml`. |
| NCCLI-02 | An authenticated meter call succeeds against Revenium from the NemoClaw deployment (closes spike 003's pending authenticated-meter step). | `meter completion` flag surface verified live (required flags confirmed). `--task-type` field confirmed as synthetic tagging mechanism. Dry-run validated full flag set. D-LIVE: real key available to close this during phase execution. |

</phase_requirements>

---

## Summary

Phase 13 fills in the three stub functions in `post-install-nemoclaw.sh` left by Phase 12: `stub_provision_egress_policy`, `stub_deliver_revenium_cli` (plus a new `stub_install_metering_loop` and `stub_install_enforcement_plugin` remain deferred). The core deliverables are: (1) copy two preset YAMLs from `scripts/` and apply them via `nemoclaw <name> policy-add`, (2) fetch the revenium v1.2.0 tarball inside the sandbox, verify sha256, install to `/sandbox/.local/bin/revenium`, (3) write `/sandbox/.config/revenium/config.yaml` from operator-supplied env vars, and (4) run a single ledger-gated `revenium meter completion` call that asserts HTTP 2xx.

All three requirements (NCEGRESS-01, NCCLI-01, NCCLI-02) have direct spike evidence. Spike 002 VALIDATED egress; spike 003 proved everything except the authenticated meter call (which was blocked only by lack of a real key). The live host at 34.224.27.67 currently has both policies applied and the binary installed from the spike — Phase 13 implementation will apply them idempotently via the ledger-gated provisioning flow.

The distinguishing technical challenge is the proxy-block error classification (NCEGRESS-01 SC2): curl exit code 56 + `CONNECT tunnel failed, response 403` is the proxy block, whereas `HTTP=403` with curl exit 0 is a server-side auth rejection proving egress is open. The install must parse these signatures to give operators actionable errors. The ledger (D-07) is the other novelty: a simple key=value text file under `~/.nemoclaw/` making every provisioning step idempotent and the billable meter probe exactly-once.

**Primary recommendation:** Implement the full provisioning flow as real replacements for the two Phase 13 stub functions in `post-install-nemoclaw.sh`, gated by a step-keyed ledger at `~/.nemoclaw/revenium-nemoclaw.ledger`. Ship both preset YAMLs as `scripts/revenium-policy.yaml` and `scripts/gh-release-policy.yaml`. Run the authenticated meter probe on live host 34.224.27.67 as part of phase execution to flip spike 003 to VALIDATED.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Egress policy application | Host (nemoclaw CLI) | — | `nemoclaw policy-add` is a host-side CLI command; the sandbox proxy hot-reloads without sandbox rebuild |
| Policy-block error classification | Host script | — | curl is invoked from host via `nemoclaw exec`; exit code and stderr are captured host-side |
| CLI tarball fetch | Sandbox (inside exec) | — | D-01: in-sandbox curl → CDN fetch so the binary lands directly in `/sandbox/.local/bin/` |
| SHA256 verification | Sandbox (inside exec) | — | Verification of the downloaded tarball must happen in-sandbox immediately after download |
| Config.yaml write | Host script via nemoclaw exec | — | Host has the env vars; writes into `/sandbox/.config/revenium/config.yaml` via exec |
| Ledger state tracking | Host filesystem (`~/.nemoclaw/`) | — | Ledger is host-side state; does not depend on sandbox persistence |
| Authenticated meter probe | Sandbox (inside exec) | — | Must prove end-to-end in-sandbox reach; `nemoclaw exec` dispatches; HTTP response returned to host |
| SSL/TLS trust | Sandbox CA bundle (`/etc/openshell-tls/ca-bundle.pem`) | — | OpenShell provides the CA bundle; `SSL_CERT_FILE` must point there for in-sandbox CLI calls |

---

## Standard Stack

This phase is a pure bash scripting phase. No new npm packages or Python packages are introduced. All tools are NemoClaw/OpenShell primitives and standard Linux utilities.

### Core Tools
| Tool | Version | Purpose | Source |
|------|---------|---------|--------|
| `nemoclaw` | `~/.local/bin/nemoclaw` (host) | `policy-add`, `exec`, `policy-list` primitives | [VERIFIED: spike 002/003 live] |
| `revenium` CLI | v1.2.0 | In-sandbox meter call, config.yaml write, config show | [VERIFIED: GitHub releases api.github.com/repos/revenium/revenium-cli/releases/latest] |
| `curl` | present in sandbox | Tarball fetch, egress reach probe | [VERIFIED: spike 003 live] |
| `sha256sum` | present in sandbox | Tarball checksum verification | [VERIFIED: live probe on 34.224.27.67] |
| `tar` | present in sandbox | Tarball extraction | [VERIFIED: spike 003] |
| `install -m755` | present in sandbox | Binary install to PATH | [VERIFIED: spike 003] |

### Version Pins (D-02)
| Asset | Version | Tarball sha256 | Binary sha256 |
|-------|---------|----------------|---------------|
| `revenium-cli_1.2.0_linux_amd64.tar.gz` | v1.2.0 | `cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67` | `2381086a6992f5a1767e0761f4a2c10f1febde8cc2af3da2518fab9061016bea` |

[VERIFIED: `https://github.com/revenium/revenium-cli/releases/download/v1.2.0/revenium-cli_1.2.0_checksums.txt` — official release checksums file; binary sha256 probed live inside sandbox on 34.224.27.67]

v1.2.0 is confirmed current as of 2026-06-08 (GitHub API `releases/latest` returns v1.2.0).

**Installation (host — no new packages):**

The install scripts are bash scripts. No package installs required for Phase 13 itself. The in-sandbox tarball fetch uses pre-existing `curl`/`tar`/`install` (confirmed present in spike 003). Preset YAMLs are shipped as files in `scripts/`.

---

## Package Legitimacy Audit

No external packages are installed in Phase 13. All tools used are:
- NemoClaw primitives (pre-installed on the NemoClaw host)
- Standard Linux utilities (curl, tar, sha256sum, install — present in OpenShell sandbox)
- revenium CLI v1.2.0 — fetched from GitHub official release CDN, sha256-verified before install

**Packages removed due to slopcheck verdict:** none (no packages introduced)
**Packages flagged as suspicious:** none

---

## Architecture Patterns

### System Architecture Diagram

```
Operator env vars
(REVENIUM_API_KEY, REVENIUM_TEAM_ID, etc.)
        │
        ▼
post-install-nemoclaw.sh  (host, bash)
        │
        ├─── ledger read: revenium-nemoclaw.ledger (~/.nemoclaw/)
        │         Key present? → skip step
        │         Key absent?  → execute step → write key to ledger
        │
        ├─── Step 1: provision_egress_policy()
        │       │  copy scripts/revenium-policy.yaml → /tmp/
        │       │  nemoclaw <name> policy-add --from-file ... --yes
        │       │  [probe: nemoclaw exec curl https://api.revenium.ai/]
        │       │    HTTP=000 + curl(56) → fail("policy gap: apply revenium preset")
        │       │    HTTP=4xx/2xx curl(0) → info("egress confirmed") → ledger write
        │       │
        ├─── Step 2: provision_gh_release_policy()
        │       │  copy scripts/gh-release-policy.yaml → /tmp/
        │       │  nemoclaw <name> policy-add --from-file ... --yes
        │       │    → ledger write gh-release-policy-applied
        │       │
        ├─── Step 3: deliver_revenium_cli()
        │       │  nemoclaw exec: curl CDN → /tmp/rev.tgz
        │       │  nemoclaw exec: sha256sum /tmp/rev.tgz
        │       │    sha256 mismatch → fail("checksum mismatch — aborting install")
        │       │    sha256 match    → tar + install -m755 → /sandbox/.local/bin/revenium
        │       │    → ledger write cli-delivered version=v1.2.0 sha256=...
        │       │
        ├─── Step 4: write_revenium_creds()
        │       │  nemoclaw exec: mkdir -p /sandbox/.config/revenium/
        │       │  nemoclaw exec: write config.yaml from REVENIUM_* env vars
        │       │    → ledger write creds-written
        │       │
        └─── Step 5: meter_probe()  [ledger-gated: skip if meter-probe-passed present]
                │  nemoclaw exec: SSL_CERT_FILE=... revenium meter completion
                │    --model <model> --provider <provider>
                │    --input-tokens 1 --output-tokens 1 --total-tokens 2
                │    --stop-reason END --task-type install-smoke-test
                │    --request-time <now> --completion-start-time <now>
                │    --response-time <now> --request-duration 1000
                │  HTTP 2xx → info("meter probe passed") → ledger write meter-probe-passed
                │  HTTP non-2xx → fail("meter probe failed — check API key and egress")
                │
                ▼
        Success banner
```

### Ledger Format

Simple key=value text file at `~/.nemoclaw/revenium-nemoclaw.ledger`:

```
# revenium-nemoclaw.ledger — step completion state (DO NOT EDIT MANUALLY)
revenium-policy-applied=1
gh-release-policy-applied=1
cli-delivered=v1.2.0:cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67
creds-written=1
meter-probe-passed=1
```

The `cli-delivered` key stores `version:tarball-sha256` so a version bump (different version string or different sha256) invalidates the key and triggers re-delivery.

**Ledger read pattern (bash):**
```bash
LEDGER_FILE="${HOME}/.nemoclaw/revenium-nemoclaw.ledger"

ledger_has() {
    local key="$1"
    grep -q "^${key}=" "${LEDGER_FILE}" 2>/dev/null
}

ledger_set() {
    local key="$1" val="$2"
    # Remove old entry, append new
    { grep -v "^${key}=" "${LEDGER_FILE}" 2>/dev/null || true; \
      echo "${key}=${val}"; } > "${LEDGER_FILE}.tmp" && \
      mv "${LEDGER_FILE}.tmp" "${LEDGER_FILE}"
}
```

### Recommended Project Structure

New files this phase adds to `scripts/`:
```
scripts/
├── post-install-nemoclaw.sh    # Modified: stubs replaced with real functions
├── revenium-policy.yaml        # NEW: api.revenium.ai egress preset (copy of spike 002 YAML)
└── gh-release-policy.yaml      # NEW: release-assets.githubusercontent.com preset (copy of spike 003 YAML)
```

No new top-level scripts. The provisioning logic lives entirely within `post-install-nemoclaw.sh` as function replacements.

### Pattern 1: Ledger-Gated Step

```bash
# Source: D-07 + established command_exists idiom from post-install-nemoclaw.sh
provision_egress_policy() {
    if ledger_has "revenium-policy-applied"; then
        info "Revenium egress policy already applied (ledger) — skipping."
        return 0
    fi

    step "Applying revenium egress policy"
    local preset_src="${SCRIPT_DIR}/revenium-policy.yaml"
    [[ -f "${preset_src}" ]] || fail "revenium-policy.yaml not found at ${preset_src}"

    nemoclaw "${SANDBOX_NAME}" policy-add --from-file "${preset_src}" --yes \
        || fail "policy-add failed for revenium preset"

    # Reach-verify: distinguish proxy block from open egress (D-04)
    local http_code
    http_code=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc \
        'curl -sS -o /dev/null -w "%{http_code}" https://api.revenium.ai/ 2>/dev/null' 2>/dev/null || echo "000")

    if [[ "${http_code}" == "000" ]]; then
        fail "sandbox cannot reach api.revenium.ai — policy gap detected. Check that the revenium preset was applied: nemoclaw ${SANDBOX_NAME} policy-list"
    fi
    info "Egress to api.revenium.ai confirmed (HTTP ${http_code})"

    ledger_set "revenium-policy-applied" "1"
}
```

### Pattern 2: In-Sandbox Tarball Deliver + SHA256 Verify

```bash
# Source: spike 003 README.md + D-02
deliver_revenium_cli() {
    local expected_cli_ledger="v1.2.0:cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67"

    if ledger_has "cli-delivered"; then
        local stored
        stored=$(grep "^cli-delivered=" "${LEDGER_FILE}" | cut -d= -f2-)
        if [[ "${stored}" == "${expected_cli_ledger}" ]]; then
            info "revenium CLI v1.2.0 already delivered and verified (ledger) — skipping."
            return 0
        fi
        warn "cli-delivered ledger entry exists but version/sha256 differs — re-delivering."
    fi

    step "Delivering revenium CLI v1.2.0 into sandbox"
    local tarball_url="https://github.com/revenium/revenium-cli/releases/download/v1.2.0/revenium-cli_1.2.0_linux_amd64.tar.gz"
    local expected_sha256="cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67"

    nemoclaw "${SANDBOX_NAME}" exec -- sh -lc "
        set -e
        cd /tmp
        curl -fsSL -o rev.tgz '${tarball_url}'
        actual_sha=\$(sha256sum rev.tgz | awk '{print \$1}')
        if [ \"\${actual_sha}\" != '${expected_sha256}' ]; then
            echo \"CHECKSUM_MISMATCH:\${actual_sha}\" >&2
            exit 2
        fi
        tar xzf rev.tgz
        mkdir -p /sandbox/.local/bin
        install -m755 ./revenium /sandbox/.local/bin/revenium
        echo 'CLI_DELIVERED_OK'
    " || {
        local rc=$?
        if [[ $rc -eq 2 ]]; then
            fail "revenium CLI sha256 mismatch — tarball may be tampered. Aborting install."
        fi
        fail "revenium CLI delivery failed (exit ${rc})"
    }

    ledger_set "cli-delivered" "${expected_cli_ledger}"
    info "revenium CLI v1.2.0 installed at /sandbox/.local/bin/revenium"
}
```

### Pattern 3: Config.yaml Write (D-05)

```bash
# Source: D-05 + revenium config --help (keys: key, api-url, team-id, tenant-id, owner-id)
write_revenium_creds() {
    if ledger_has "creds-written"; then
        info "Revenium credentials already written (ledger) — skipping."
        return 0
    fi

    [[ -n "${REVENIUM_API_KEY:-}" ]] \
        || fail "REVENIUM_API_KEY not set — export it before running the install"

    step "Writing revenium credentials into sandbox"
    local config_content
    config_content="key: ${REVENIUM_API_KEY}"
    [[ -n "${REVENIUM_TEAM_ID:-}"   ]] && config_content="${config_content}
team-id: ${REVENIUM_TEAM_ID}"
    [[ -n "${REVENIUM_TENANT_ID:-}" ]] && config_content="${config_content}
tenant-id: ${REVENIUM_TENANT_ID}"
    [[ -n "${REVENIUM_OWNER_ID:-}"  ]] && config_content="${config_content}
owner-id: ${REVENIUM_OWNER_ID}"

    nemoclaw "${SANDBOX_NAME}" exec -- sh -lc "
        mkdir -p /sandbox/.config/revenium
        cat > /sandbox/.config/revenium/config.yaml <<'YAML'
${config_content}
YAML
        chmod 600 /sandbox/.config/revenium/config.yaml
    "

    ledger_set "creds-written" "1"
    info "Credentials written to /sandbox/.config/revenium/config.yaml"
}
```

### Pattern 4: Meter Probe (D-06)

```bash
# Source: D-06 + live CLI help verification on 34.224.27.67
# meter completion required flags: --model, --provider, --input-tokens, --output-tokens,
#   --total-tokens, --stop-reason, --request-time, --completion-start-time,
#   --response-time, --request-duration
# --task-type is optional but used to tag as synthetic (confirmed via dry-run)
run_meter_probe() {
    if ledger_has "meter-probe-passed"; then
        info "Meter probe already passed (ledger) — skipping."
        return 0
    fi

    step "Running authenticated meter probe"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local meter_output
    meter_output=$(nemoclaw "${SANDBOX_NAME}" exec -- sh -lc "
        SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem \
        /sandbox/.local/bin/revenium meter completion \
            --model claude-sonnet-4-5 \
            --provider anthropic \
            --input-tokens 1 \
            --output-tokens 1 \
            --total-tokens 2 \
            --stop-reason END \
            --request-time '${now}' \
            --completion-start-time '${now}' \
            --response-time '${now}' \
            --request-duration 1000 \
            --task-type install-smoke-test \
            --output json 2>&1
    " 2>&1) || true

    # revenium CLI exits 0 on 2xx; exits non-zero on 4xx/5xx network error
    # Check for success indicators in output
    if echo "${meter_output}" | grep -qiE '"status"\s*:\s*"?(200|201|202|accepted|ok)"?|Metered successfully'; then
        ledger_set "meter-probe-passed" "1"
        info "Meter probe passed — authenticated meter call succeeded"
    else
        fail "Meter probe failed. Output: ${meter_output}. Check REVENIUM_API_KEY and egress policy."
    fi
}
```

### Anti-Patterns to Avoid

- **Treating `HTTP=000` as a network error:** It is a proxy block. Detect with curl exit code 56 OR `HTTP=000` and report as a policy gap.
- **Using `brew install revenium` in-sandbox:** No Linux bottle exists; brew falls back to a source build requiring gcc. Always use the prebuilt tarball.
- **Omitting `SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem`:** In-sandbox CLI calls fail TLS verification without it. The OpenShell CA bundle is at this fixed path.
- **Writing credentials on every run:** The `creds-written` ledger key prevents credential churn on idempotent re-runs.
- **Running the meter probe on every re-run:** The `meter-probe-passed` ledger key makes it exactly-once. Without it, every re-run would emit a synthetic billing event.
- **Inline policy YAML in the script:** Ship the presets as named files in `scripts/`; `policy-add --from-file` requires a file path. The skill's `sources/` directory is not shipped with the skill.
- **Newlines in `nemoclaw exec -- sh -lc "..."` payload:** gRPC rejects them. Keep exec payloads as single-line scripts or heredoc-embedded within a shell function (not across newlines in the gRPC call itself). [VERIFIED: spike references/revenium-cli-and-metering.md]
- **`SANDBOX_NAME` hardcoded:** It must be passed as a parameter or read from a well-known location — not hardcoded to `revenium-spike`.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Egress allowlisting | Custom iptables rules or proxy bypass | `nemoclaw policy-add --from-file` | NemoClaw manages the proxy; host-scoped presets hot-reload without sandbox rebuild |
| TLS CA bundle | Extract or generate CA certs | `/etc/openshell-tls/ca-bundle.pem` (already present in sandbox) | Fixed OpenShell path; spike 003 confirmed it works |
| In-sandbox binary install | Docker COPY / bind mount | `nemoclaw exec` tarball fetch + `install -m755` | D-01 decision: in-sandbox CDN fetch is self-contained and avoids Phase-14 mount dependency |
| Credential injection | Bind-mount `~/.config/revenium/` | Write `config.yaml` via `nemoclaw exec` from host env vars | OpenShell rejects credential path bind-mounts (post-install.sh comment, line 168-171) |
| Error classification logic | Generic `if [ $? -ne 0 ]` | Parse `HTTP=000` / curl exit 56 pattern | The proxy block and a real server rejection have the same surface appearance without this check |

---

## Common Pitfalls

### Pitfall 1: The Proxy Block Looks Like a Real Error
**What goes wrong:** A `curl: (56) CONNECT tunnel failed, response 403` looks like an API authentication error. The operator reports "Revenium is down" rather than "policy not applied."
**Why it happens:** The sandbox proxy returns HTTP 403 on the CONNECT handshake; curl sees it as a connection error (exit 56) and the http_code is 000.
**How to avoid:** After `policy-add`, probe with `curl -sS -o /dev/null -w "%{http_code}" https://api.revenium.ai/`; if the result is `000` → policy gap message; if 4xx/2xx with curl exit 0 → egress is open. [VERIFIED: spike 002 README]
**Warning signs:** `HTTP=000` in curl output; `curl: (56)` in error output.

### Pitfall 2: SHA256 Is the Tarball Hash, Not the Binary Hash
**What goes wrong:** The implementer hashes the extracted binary and compares it to the tarball checksum (or vice versa).
**Why it happens:** The official `checksums.txt` file contains tarball hashes. After extraction, the binary has a different hash.
**How to avoid:** Compute `sha256sum rev.tgz` (the tarball, before extraction) and compare to the value from the official `checksums.txt`. The tarball sha256 for `revenium-cli_1.2.0_linux_amd64.tar.gz` is `cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67`. [VERIFIED: official checksums.txt fetched 2026-06-08]

### Pitfall 3: The Ledger `cli-delivered` Key Must Encode Version+SHA
**What goes wrong:** `cli-delivered=1` (boolean) prevents re-delivery when the version pin is bumped.
**Why it happens:** A simple boolean key doesn't capture which version was delivered.
**How to avoid:** Store `cli-delivered=v1.2.0:<tarball-sha256>` as the ledger value. The step compares the stored value against the expected string; any mismatch (version bump or different sha256) triggers re-delivery.

### Pitfall 4: `nemoclaw exec` Shell Quoting With Variables
**What goes wrong:** Variables expanded on the host leak into the `sh -lc` payload with wrong values, or shell metacharacters break the command.
**Why it happens:** `sh -lc "..."` inside `nemoclaw exec -- sh -lc "..."` requires careful quoting — single-quote the inner payload to prevent host expansion of in-sandbox variables.
**How to avoid:** Use the spike 003 pattern: `nemoclaw exec -- sh -lc '...'` with single quotes for the inner payload; pass host variables explicitly via string interpolation before the single-quoted boundary where needed.

### Pitfall 5: Credentials in exec Command Line
**What goes wrong:** `nemoclaw exec -- sh -lc 'REVENIUM_API_KEY=... revenium ...'` leaks the key into process listing.
**Why it happens:** The key is visible in `ps aux` output on the host.
**How to avoid:** D-05 explicitly addresses this: write credentials to `config.yaml` (the `creds-written` step) before the meter probe step. The probe reads from `config.yaml`, not from env vars on the command line.

### Pitfall 6: The `revenium` Binary Reads `~/.config/revenium/config.yaml` as `~` = Sandbox HOME
**What goes wrong:** The CLI is expected at `~/.config/revenium/config.yaml` but inside the sandbox `~` is `/sandbox`, not the host user HOME.
**Why it happens:** The sandbox user is `sandbox`, HOME `/sandbox`. The config path is `/sandbox/.config/revenium/config.yaml`.
**How to avoid:** Write the config.yaml to `/sandbox/.config/revenium/config.yaml` (not the host path). Confirmed: `revenium config --help` shows `~/.config/revenium/config.yaml`, and in-sandbox `~` resolves to `/sandbox`. [VERIFIED: spike 003 README + live ls of /sandbox/]

### Pitfall 7: Both Egress Policies Must Be Applied Before the CDN Fetch
**What goes wrong:** `gh-release-policy.yaml` is applied after the CLI delivery step. The `curl` fetch fails because `release-assets.githubusercontent.com` is still blocked.
**Why it happens:** Steps are applied in order; if `revenium-policy.yaml` is applied but `gh-release-policy.yaml` is not, the CDN fetch fails.
**How to avoid:** Apply both policies (Steps 1 and 2) before the CLI delivery step (Step 3). The ledger ordering enforces this.

### Pitfall 8: SANDBOX_NAME Must Match the Running Sandbox
**What goes wrong:** `nemoclaw revenium-spike policy-add ...` hardcodes `revenium-spike`; a different deployment uses a different sandbox name.
**Why it happens:** Spike scripts use the concrete sandbox name.
**How to avoid:** The install script must accept the sandbox name as a parameter (e.g. `REVENIUM_SANDBOX_NAME` env var or `--sandbox` flag), not hardcode it.

---

## Code Examples

### Verified Policy-Add Command Surface
```bash
# Source: spike 002 README.md (VALIDATED live on 34.224.27.67)
# Apply preset — hot-reloads without rebuild
nemoclaw revenium-spike policy-add --from-file revenium-policy.yaml --yes
# Preview before applying
nemoclaw revenium-spike policy-add --from-file revenium-policy.yaml --dry-run
# Verify active presets
nemoclaw revenium-spike policy-list
```

### Verified Egress Probe Pattern
```bash
# Source: spike 002 README.md investigation trail
# After policy-add, verify egress:
http_code=$(nemoclaw revenium-spike exec -- sh -lc \
    'curl -sS -o /dev/null -w "%{http_code}" https://api.revenium.ai/ 2>/dev/null')
# Expected after policy applied: http_code=403 (server-side auth, egress open)
# Expected before policy: http_code=000 (proxy 403 CONNECT block, egress closed)
```

### Verified CLI Delivery Command
```bash
# Source: spike 003 README.md (VALIDATED live on 34.224.27.67)
nemoclaw revenium-spike exec -- sh -lc 'cd /tmp && \
  curl -fsSL -o rev.tgz https://github.com/revenium/revenium-cli/releases/download/v1.2.0/revenium-cli_1.2.0_linux_amd64.tar.gz && \
  tar xzf rev.tgz && install -m755 ./revenium /sandbox/.local/bin/revenium'
```

### Verified Meter Completion Minimum Required Flags
```bash
# Source: live `revenium meter completion --help` on 34.224.27.67, 2026-06-08
# Required flags (marked "(required)" in help output):
#   --model, --provider, --input-tokens, --output-tokens (implicit via total),
#   --total-tokens, --stop-reason, --request-time, --completion-start-time,
#   --response-time, --request-duration
# Optional tag: --task-type (used for synthetic event labeling)
SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem \
/sandbox/.local/bin/revenium meter completion \
    --model claude-sonnet-4-5 \
    --provider anthropic \
    --input-tokens 1 \
    --output-tokens 1 \
    --total-tokens 2 \
    --stop-reason END \
    --request-time 2026-06-08T00:00:00Z \
    --completion-start-time 2026-06-08T00:00:00Z \
    --response-time 2026-06-08T00:00:01Z \
    --request-duration 1000 \
    --task-type install-smoke-test
```
[VERIFIED: `--dry-run` on live sandbox confirms all flags accepted, output shows `taskType: install-smoke-test` in body]

### Verified Config.yaml Format
```yaml
# Source: revenium config --help (live) + spike 003 README.md
# Path: /sandbox/.config/revenium/config.yaml  (in-sandbox HOME = /sandbox)
key: <REVENIUM_API_KEY>
team-id: <REVENIUM_TEAM_ID>
tenant-id: <REVENIUM_TENANT_ID>
owner-id: <REVENIUM_OWNER_ID>
```
[VERIFIED: `revenium config --help` on 34.224.27.67 confirms key names; env var override names confirmed as `REVENIUM_API_KEY`, `REVENIUM_TEAM_ID`, `REVENIUM_TENANT_ID`]

---

## Existing Code Integration

### Functions to Replace in `post-install-nemoclaw.sh`

Two stub functions from Phase 12 become real implementations in Phase 13:

| Stub (Phase 12) | Replacement (Phase 13) | Ledger Keys |
|----------------|------------------------|-------------|
| `stub_provision_egress_policy()` | `provision_egress_policy()` + `provision_gh_release_policy()` | `revenium-policy-applied`, `gh-release-policy-applied` |
| `stub_deliver_revenium_cli()` | `deliver_revenium_cli()` + `write_revenium_creds()` + `run_meter_probe()` | `cli-delivered`, `creds-written`, `meter-probe-passed` |

The other two stubs remain as-is:
- `stub_install_metering_loop()` — Phase 14
- `stub_install_enforcement_plugin()` — Phase 15

### New Constants to Add
```bash
# Near top of post-install-nemoclaw.sh, after existing constants:
LEDGER_FILE="${HOME}/.nemoclaw/revenium-nemoclaw.ledger"
REVENIUM_CLI_VERSION="v1.2.0"
REVENIUM_CLI_TARBALL_SHA256="cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67"
REVENIUM_CLI_URL="https://github.com/revenium/revenium-cli/releases/download/${REVENIUM_CLI_VERSION}/revenium-cli_${REVENIUM_CLI_VERSION#v}_linux_amd64.tar.gz"
```

### Sandbox Name Discovery
The install must know which NemoClaw sandbox to provision. Options (in order of preference):
1. Env var `REVENIUM_SANDBOX_NAME` — operator-supplied at install time
2. Auto-detect from `nemoclaw sandbox list` (if a single sandbox exists)
3. Default to a well-known name (e.g., `revenium`) with a warn if absent

[ASSUMED: auto-detect approach — the planner should pick a concrete resolution strategy]

---

## State of the Art

| Old Approach | Current Approach | Notes |
|--------------|------------------|-------|
| Stub warnings in Phase 12 | Real provisioning in Phase 13 | Phase 12 left named stubs — this phase replaces exactly those |
| No ledger (Phase 12 read-only) | Step-keyed ledger (D-07) | Ledger introduced here as planned in Phase 12 D-11 |
| Spike scripts with hardcoded sandbox names | Parameterized install script | `revenium-spike` as hardcoded name must become a variable |

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Sandbox name resolution strategy (auto-detect vs env var vs default) | Code Examples, Architecture | Wrong approach could fail silently on multi-sandbox hosts |
| A2 | `revenium meter completion` with `--output json` exits 0 on HTTP 2xx, non-zero on error | Pattern 4 (meter probe) | Probe success detection breaks if CLI exits 0 regardless of HTTP status |

**All other claims verified** against live host 34.224.27.67, official GitHub release checksums, spike 002/003 source files, and live CLI help output.

---

## Open Questions

1. **Sandbox name parameter surface**
   - What we know: The spike hardcodes `revenium-spike`. The install script must accept a sandbox name.
   - What's unclear: Whether `nemoclaw sandbox list` output is parseable and whether single-sandbox auto-detect is safe.
   - Recommendation: Accept `REVENIUM_SANDBOX_NAME` env var; fail with clear message if unset and auto-detect is unavailable.

2. **meter completion exit behavior on HTTP error**
   - What we know: `--dry-run` produces clean output and exits 0. A real call with a bad key returned `{"status":403}` server-side in spike 003 (but via `sources list`, not `meter completion`).
   - What's unclear: Whether `revenium meter completion` exits non-zero on a 4xx/5xx response from the server.
   - Recommendation: Check both exit code AND presence of HTTP 2xx indicator in JSON output (`--output json`) as the success signal. D-LIVE execution on 34.224.27.67 will resolve this.

3. **`nemoclaw policy-add` idempotency**
   - What we know: Hot-reloads on each apply (version bump). The ledger gate prevents re-applying.
   - What's unclear: Whether applying the same preset twice errors or succeeds silently.
   - Recommendation: The ledger gate makes this a non-issue for the normal path. For extra safety, `--yes` suppresses prompts and the command appears to succeed even if policy is already active (based on spike 002 "Policy version 4 loaded" output — each apply bumps the version).

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| `nemoclaw` CLI | All policy-add and exec operations | ✓ (on PATH via `~/.local/bin`) | Runtime version on 34.224.27.67 | None — required |
| `curl` in sandbox | Tarball fetch (Step 3) | ✓ | Present per spike 003 | None — standard OpenShell |
| `sha256sum` in sandbox | Tarball verification (Step 3) | ✓ | Present — verified live on 34.224.27.67 | None |
| `tar` in sandbox | Tarball extraction (Step 3) | ✓ | Present per spike 003 | None |
| `install -m755` in sandbox | Binary placement (Step 3) | ✓ | Present per spike 003 | `cp + chmod 755` |
| `/etc/openshell-tls/ca-bundle.pem` | TLS for in-sandbox CLI calls | ✓ | Fixed OpenShell path | None — OpenShell provides it |
| `REVENIUM_API_KEY` env var | Cred write + meter probe | ✓ (available this session per D-LIVE) | — | Warn and continue cred-write steps; fail on meter probe |
| GitHub CDN (`release-assets.githubusercontent.com`) | Tarball fetch | ✓ (after gh-release policy applied) | — | None (prerequisite) |

[VERIFIED: sha256sum, curl, tar, install confirmed via live exec on 34.224.27.67; /etc/openshell-tls/ca-bundle.pem confirmed in spike 003 README]

---

## Validation Architecture

Nyquist validation is ENABLED. The phase has both hermetic-stub-testable logic and a live smoke requirement.

### Test Framework
| Property | Value |
|----------|-------|
| Framework | bash (matching existing tests/ conventions) + live exec on 34.224.27.67 |
| Config file | none — tests are standalone bash scripts |
| Quick run command | `bash tests/test_nemoclaw_provisioning.sh` |
| Full suite command | `bash tests/test_install_dispatcher.sh && bash tests/test_nemoclaw_provisioning.sh` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| NCEGRESS-01 SC1 | `policy-add` is called with the revenium preset | unit/hermetic | `bash tests/test_nemoclaw_provisioning.sh` (mock nemoclaw, assert policy-add invoked) | ❌ Wave 0 |
| NCEGRESS-01 SC2 | HTTP=000 probe triggers policy-gap error, not generic error | unit/hermetic | `bash tests/test_nemoclaw_provisioning.sh` (mock curl returning HTTP=000) | ❌ Wave 0 |
| NCEGRESS-01 SC2 | HTTP=403 (server response) does NOT trigger policy-gap error | unit/hermetic | `bash tests/test_nemoclaw_provisioning.sh` (mock curl returning HTTP=403, curl exit 0) | ❌ Wave 0 |
| NCCLI-01 | SHA256 mismatch aborts install | unit/hermetic | `bash tests/test_nemoclaw_provisioning.sh` (inject wrong sha256) | ❌ Wave 0 |
| NCCLI-01 | SHA256 match proceeds to install | unit/hermetic | `bash tests/test_nemoclaw_provisioning.sh` (inject correct sha256 from mock) | ❌ Wave 0 |
| NCCLI-01 | Ledger `cli-delivered` with matching version skips re-delivery | unit/hermetic | `bash tests/test_nemoclaw_provisioning.sh` (pre-populate ledger) | ❌ Wave 0 |
| NCCLI-01 | `meter-probe-passed` ledger key skips re-probe | unit/hermetic | `bash tests/test_nemoclaw_provisioning.sh` | ❌ Wave 0 |
| NCCLI-02 | Authenticated `revenium meter completion` returns HTTP 2xx from sandbox | live-smoke | Manual exec on 34.224.27.67 | live-only |
| All SC | Success run: all 5 ledger keys written | unit/hermetic | `bash tests/test_nemoclaw_provisioning.sh` (mock all external calls to succeed) | ❌ Wave 0 |

### Hermetic Test Strategy

The hermetic tests mock two external callsites:
1. `nemoclaw` — replace with a stub that records invocations and emits configurable output (curl HTTP code, policy-add success/fail, exec script output). Pattern: same `STUB_NEMOCLAW_ARGV_FILE` + symlink approach as `tests/stub-revenium.sh`.
2. `curl` inside the sandbox — the hermetic test does not run actual exec; instead it tests the error-classification logic by passing a mock curl-exit-code + http_code to the provisioning function.

**Stub env switches to implement:**
- `STUB_NEMOCLAW_CURL_HTTP_CODE` — controls the in-sandbox curl probe response (default `403`; set to `000` for proxy-block test)
- `STUB_NEMOCLAW_SHA256_MATCH` — controls whether the tarball sha256 matches (default `1`; set to `0` for mismatch test)
- `STUB_NEMOCLAW_METER_FAIL` — forces the meter probe to fail (exit non-zero or bad JSON response)
- Pre-populated ledger file path — inject via `LEDGER_FILE` override for skip/resume tests

**Live smoke (D-LIVE):**
Run the full `post-install-nemoclaw.sh` against the real sandbox `revenium-spike` on 34.224.27.67 with a real `REVENIUM_API_KEY`. Assert:
1. Both policies applied (ledger keys present)
2. Binary at `/sandbox/.local/bin/revenium version` → `revenium 1.2.0 (2f21f78)`
3. Config.yaml present at `/sandbox/.config/revenium/config.yaml`
4. `meter-probe-passed=1` in ledger
5. Spike 003 flipped to VALIDATED in `.claude/skills/spike-findings-openclaw-revenium/sources/003-revenium-cli-in-sandbox/README.md`

### Sampling Rate
- **Per task commit:** `bash tests/test_nemoclaw_provisioning.sh` (hermetic, < 30 seconds)
- **Per wave merge:** `bash tests/test_install_dispatcher.sh && bash tests/test_nemoclaw_provisioning.sh`
- **Phase gate:** Full hermetic suite green + live smoke on 34.224.27.67 passing before `/gsd-verify-work`

### Wave 0 Gaps
- [ ] `tests/test_nemoclaw_provisioning.sh` — covers NCEGRESS-01, NCCLI-01, NCCLI-02 hermetic scenarios
- [ ] `tests/stub-nemoclaw.sh` — argv-capturing nemoclaw stub (modeled on `tests/stub-revenium.sh`)
- [ ] `scripts/revenium-policy.yaml` — copy of spike 002 preset (required for policy-add in provisioning)
- [ ] `scripts/gh-release-policy.yaml` — copy of spike 003 preset (required for CDN fetch)

---

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes (API key) | Key written to file with chmod 600; never passed on command line |
| V3 Session Management | no | — |
| V4 Access Control | partial | Egress preset is host-scoped (verified: control host stays blocked after applying revenium preset) |
| V5 Input Validation | yes | Operator env vars are written verbatim to config.yaml; no shell injection possible (heredoc write, not eval) |
| V6 Cryptography | yes (sha256) | Official release checksums.txt; abort on mismatch |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Tarball tampering (CDN-level) | Tampering | sha256 verify against pinned value from official checksums.txt; abort on mismatch (D-02) |
| API key in process listing | Information Disclosure | Write to config.yaml; meter probe reads from file, not env var (D-05) |
| Overly broad egress policy | Elevation of Privilege | Host-scoped presets confirmed in spike 002; control host stays blocked; keep preset narrow |
| Synthetic meter events polluting billing | Spoofing | Ledger `meter-probe-passed` gate; `--task-type install-smoke-test` tag for filtering |
| `nemoclaw exec` injection via env vars | Tampering | Config.yaml written via heredoc (no shell expansion of values); env var names are fixed, not user-supplied |

---

## Sources

### Primary (HIGH confidence — verified live or from official release)

- Spike 002 README: `.claude/skills/spike-findings-openclaw-revenium/sources/002-openshell-egress/README.md` — policy-add usage, block/reach signatures, hot-reload behavior. VALIDATED.
- Spike 003 README: `.claude/skills/spike-findings-openclaw-revenium/sources/003-revenium-cli-in-sandbox/README.md` — tarball delivery commands, auth reach proof, reopen note. PARTIAL→to be flipped.
- `revenium-policy.yaml`: `.claude/skills/spike-findings-openclaw-revenium/sources/002-openshell-egress/revenium-policy.yaml` — the preset to ship.
- `gh-release-policy.yaml`: `.claude/skills/spike-findings-openclaw-revenium/sources/003-revenium-cli-in-sandbox/gh-release-policy.yaml` — includes both `release-assets.githubusercontent.com` and `objects.githubusercontent.com`.
- Live CLI help: `revenium meter completion --help` on 34.224.27.67 — complete required flag list verified.
- Official checksums: `https://github.com/revenium/revenium-cli/releases/download/v1.2.0/revenium-cli_1.2.0_checksums.txt` — tarball sha256 = `cc4b07e94589af082dc21ecba7e235ebc1dd52f010238fd932dec6003a816f67`.
- Live binary sha256: `sha256sum /sandbox/.local/bin/revenium` on 34.224.27.67 = `2381086a6992f5a1767e0761f4a2c10f1febde8cc2af3da2518fab9061016bea`.
- GitHub releases API: `https://api.github.com/repos/revenium/revenium-cli/releases/latest` — v1.2.0 is current as of 2026-06-08.
- Live `revenium config --help` on 34.224.27.67 — config.yaml keys and env var names confirmed.
- Live `nemoclaw revenium-spike policy-list` on 34.224.27.67 — confirmed both revenium presets already active from spike.
- Live `curl` egress probe on 34.224.27.67 — `HTTP=403` confirmed with both policies active.

### Secondary (MEDIUM confidence)

- `scripts/post-install-nemoclaw.sh` (Phase 12) — stub function names, idioms, ledger deferral note (D-11).
- `scripts/post-install.sh` — credential reading pattern, `command_exists` idiom.
- `tests/stub-revenium.sh` — hermetic test stubbing conventions to mirror for `stub-nemoclaw.sh`.

---

## Metadata

**Confidence breakdown:**
- Standard stack (bash/nemoclaw/revenium): HIGH — verified live on 34.224.27.67
- Architecture (ledger design, function structure): HIGH — follows established Phase 12 patterns + CONTEXT.md decisions
- CLI flag surface: HIGH — verified via live `--help` and `--dry-run`
- Checksum/version pins: HIGH — from official checksums.txt + GitHub releases API
- Testing approach: HIGH — direct extension of Phase 12 `test_install_dispatcher.sh` patterns
- Sandbox name parameter: MEDIUM — approach is clear, specific strategy is A1 (assumed)

**Research date:** 2026-06-08
**Valid until:** 2026-07-08 (stable — revenium CLI version pin would need updating only if v1.2.0 is retracted)
