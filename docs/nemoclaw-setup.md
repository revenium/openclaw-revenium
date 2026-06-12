# Revenium OpenClaw Skill — NemoClaw/OpenShell Setup

Budget enforcement and token metering for [OpenClaw](https://docs.openclaw.ai) agents running inside an [NemoClaw](https://www.nvidia.com/nemoclaw)/OpenShell sandbox. This runbook covers the **NemoClaw install path only** — for the standalone OpenClaw + Docker path (macOS or Linux), see [README.md](../README.md).

## Prerequisites

- **Linux host** — bare-metal, VM, or cloud. macOS is explicitly unsupported (see [macOS](#macos-unsupported)).
- **Docker** — required by NemoClaw; the installer verifies this.
- **NemoClaw** installed and a sandbox provisioned. To install NemoClaw:
  ```bash
  curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
  ```
  Follow the prompts to accept the terms and provision a sandbox. The first install takes ~11 minutes (80-step OpenShell image build). After installation, the `nemoclaw` CLI is available at `~/.local/bin/nemoclaw` — add it to your PATH:
  ```bash
  export PATH="$HOME/.local/bin:$PATH"
  ```
  Verify the sandbox is ready:
  ```bash
  nemoclaw <your-sandbox-name> status
  ```
  You should see `Phase: Ready, Inference: healthy`.

- **`sshfs`** — the host-side metering loop mounts the sandbox filesystem over SSHFS. Install it on your Linux host (e.g., `apt install sshfs` on Debian/Ubuntu).

- **`revenium` CLI** — delivered as a prebuilt binary tarball into the sandbox by the installer. **Do not install via Homebrew for the NemoClaw path** — Homebrew is not available inside an OpenShell sandbox, and the CLI must be accessible in-sandbox. The installer fetches, sha256-verifies, and installs the binary to `/sandbox/.local/bin/revenium` automatically.

- **Revenium credentials** — you'll set these as environment variables when you run the installer (the exact `export` commands are in [Installation Step 2](#2-export-credentials-and-sandbox-name-then-run-the-nemoclaw-install-script)). You will need:
  - `REVENIUM_SANDBOX_NAME` — the NemoClaw sandbox to provision **(required)**
  - `REVENIUM_API_KEY` — the installer writes this in-sandbox **(required)**
  - `REVENIUM_TEAM_ID`, `REVENIUM_TENANT_ID`, `REVENIUM_OWNER_ID` — optional but recommended

  Your Revenium credentials can be found at [app.revenium.ai/connections](https://app.revenium.ai/connections).

## Installation

### 1. Clone the skill into the host skill directory

```bash
git clone https://github.com/revenium/openclaw-revenium.git ~/.openclaw/skills/revenium
cd ~/.openclaw/skills/revenium
git config core.fileMode false
```

> **Private repo?** Authenticate first: `gh auth login`, or use a PAT in the URL.

### 2. Export credentials and sandbox name, then run the NemoClaw install script

```bash
export REVENIUM_SANDBOX_NAME=<your-sandbox-name>
export REVENIUM_API_KEY=<your-api-key>
export REVENIUM_TEAM_ID=<your-team-id>
export REVENIUM_TENANT_ID=<your-tenant-id>
export REVENIUM_OWNER_ID=<your-owner-id>

# Optional — create a budget guardrail rule at install time. If you omit these,
# no budget is created and metering still works; set them to auto-create the rule
# (it appears in Revenium under your Team and writes ruleIds into the sandbox config).
export REVENIUM_BUDGET_LIMIT=100              # numeric hard limit, e.g. 100.00
export REVENIUM_BUDGET_PERIOD=MONTHLY        # DAILY | WEEKLY | MONTHLY | QUARTERLY
# export REVENIUM_BUDGET_SHADOW=1            # optional: warn-only (no blocking)
# export REVENIUM_BUDGET_AUTONOMOUS=true     # optional: HARD-HALT the agent when the
                                             # hard limit is breached. Default (unset):
                                             # warn-and-ask — over the limit, the agent
                                             # asks permission each turn instead of
                                             # halting (relies on per-turn LLM compliance)

bash ~/.openclaw/skills/revenium/scripts/install.sh --nemoclaw
```

This runs `scripts/post-install-nemoclaw.sh` which, in order:

1. Runs a host compatibility preflight (Linux + Docker check)
2. Applies the Revenium egress policy preset to allow `api.revenium.ai` from the sandbox
3. Applies the GitHub release CDN egress policy (required for CLI delivery)
4. Fetches the prebuilt `revenium` CLI tarball in-sandbox, sha256-verifies it, and installs it to `/sandbox/.local/bin/revenium`
5. Writes your credentials to `/sandbox/.config/revenium/config.yaml` (chmod 600; key written as the `api-key:` field — never on a command line)
6. Runs a ledger-gated authenticated meter probe (`--task-type install-smoke-test`) to confirm egress + credentials are working
7. Installs the `revenium` CLI **on the host** (`~/.local/bin/revenium`) — the metering cron runs `report.sh` on the host and needs it (skipped if you already have `revenium` on your PATH)
8. Installs the host-side metering loop (host cron reads OpenClaw session JSONL logs over a `nemoclaw share mount` SSHFS mount — no per-tick `nemoclaw exec`, no in-sandbox cron daemon)
9. Deploys the revenium skill into the sandbox via `nemoclaw <name> skill install`
10. Installs and validates the `revenium-enforcement` plugin (the per-turn guardrail directive enforcer)
11. **Creates a Revenium budget guardrail rule** and writes its `ruleIds` into the sandbox `config.json` — **only if `REVENIUM_BUDGET_LIMIT` + `REVENIUM_BUDGET_PERIOD` are set** (see the export block in Step 2). Without them this step is skipped and no budget is created (metering still works); the rule appears in Revenium under your **Team**.

All steps are **ledger-gated, per sandbox** — re-running the script is safe and skips already-completed steps. The ledger lives at `~/.nemoclaw/revenium-nemoclaw-<sandbox-uuid>.ledger` (a destroyed+recreated sandbox gets a fresh ledger and re-provisions).

> **~11 min on first run** — most of this is the NemoClaw bootstrap (step 1). Subsequent re-runs are near-instant (every step is skipped via the ledger).

> **API key transport:** The API key is base64-encoded on the host and decoded in-sandbox, so it never appears as a plain-text argument in a `nemoclaw exec` call. It is written only to the chmod-600 file `/sandbox/.config/revenium/config.yaml`.

### 3. Confirm credentials in-sandbox

The credentials are stored at `/sandbox/.config/revenium/config.yaml` inside the sandbox (in-sandbox `HOME` is `/sandbox`, not `~` on the host). To verify:

```bash
nemoclaw <your-sandbox-name> exec -- sh -lc \
  "SSL_CERT_FILE=/etc/openshell-tls/ca-bundle.pem /sandbox/.local/bin/revenium config show"
```

You should see your API key, Team ID, and other fields populated.

> **Note on the `api-key:` field:** The `revenium` CLI config file uses `api-key:` (not `key:`) for the API key. A `key:` line is silently ignored — `config show` would report "API Key: (not set)". The installer writes `api-key:` correctly; if you edit the file manually, use `api-key:`.

### 4. Verify

```bash
nemoclaw <your-sandbox-name> exec -- sh -lc "openclaw skills list"
```

You should see the revenium skill listed as `✓ ready`:

```
✓ ready  💰 revenium
```

The installer also asserts this automatically (step 8 above) and aborts if the skill is not ready — so if the install completed successfully, this step is a confirmation.

---

## Parallel-Path Guarantee

The NemoClaw install path and the standalone OpenClaw + Docker path are **fully independent**:

- The standalone path uses `scripts/post-install.sh`; the NemoClaw path uses `scripts/post-install-nemoclaw.sh`. The two scripts do not share install steps.
- `scripts/install.sh` routes to the correct script based on detection (NemoClaw vs standalone vs macOS) and the `--nemoclaw` flag. The standalone `post-install.sh` is byte-stable — running the NemoClaw install path does not modify or re-run it.
- The shared operational scripts (`cron.sh`, `report.sh`, `guardrail-check.sh`) are never modified by either install path — they are sha256-pinned.

For the standalone OpenClaw + Docker path, see [README.md](../README.md).

---

## macOS Unsupported

NemoClaw/OpenShell is a Linux-only stack. If you attempt to run the NemoClaw install path on macOS, the installer exits immediately with:

```
  ✗ NemoClaw is unsupported on macOS.

  NemoClaw/OpenShell is a Linux-only stack. IMPORTANT: NemoClaw's own
  installer graceful-skips on Darwin (exits 0 without provisioning the
  sandbox) — this looks like success but never installs anything.

  To use the NemoClaw path, provision a Linux host (bare-metal, VM, or
  cloud) with Docker. The standalone OpenClaw path (default, no --nemoclaw
  flag) continues to work on macOS.
```

Exit code: `1`. This is intentional — NemoClaw's own installer graceful-skips on Darwin (exits 0 without provisioning anything), which looks like success but never installs anything. The explicit refusal prevents silent no-ops.

To use the NemoClaw path, provision a Linux host (bare-metal, VM, or cloud) with Docker. The standalone OpenClaw + Docker path continues to work on macOS — see [README.md](../README.md).

---

## First-Time Agent Setup (Automatic)

After the install, the metering cron and guardrail rules are configured the first time you interact with the agent. The agent walks you through:

1. Confirming your Revenium credentials are visible in the sandbox
2. Setting a budget threshold and period
3. Optionally enabling shadow mode and autonomous mode
4. Creating the Revenium guardrail rules and saving their `ruleIds`

This setup happens via [SKILL.md](../SKILL.md) — the skill manifest. The per-turn enforcement is delivered by the `revenium-enforcement` plugin (installed in step 9 above), which injects the mandatory guardrail directive into every agent turn via the `before_prompt_build` hook. See [BUDGET-GUARD.md](../BUDGET-GUARD.md) for the directive content and why the plugin is mandatory beyond `skill install`.

To verify the host-side metering cron is running:

```bash
tail -f ~/.openclaw/skills/revenium/revenium-metering.log
```

---

## How It Works

The metering and enforcement architecture for the NemoClaw path differs from the standalone path:

**Host-side metering loop (not Docker bind-mount):** A host cron job reads OpenClaw session JSONL logs over a `nemoclaw share mount` SSHFS mount — no per-tick `nemoclaw exec` and no in-sandbox cron daemon. The SSHFS mount makes the in-sandbox `~/.openclaw` directory visible on the host at `~/sbx-openclaw-<sandbox-name>/`. The host cron runs `cron.sh` with `OPENCLAW_HOME=<mount>` delegating to the standard unmodified `report.sh` and `guardrail-check.sh`.

**Per-turn guardrail directive (plugin, not AGENTS.md):** `skill install` deploys the skill but does not wire per-turn enforcement — SKILL.md is loaded on-demand (progressive disclosure), and there is no in-sandbox AGENTS.md. The `revenium-enforcement` plugin uses the `before_prompt_build` hook to inject the mandatory guardrail check directive into every turn, regardless of skill loading.

**Credential location:** Inside the sandbox, `HOME` is `/sandbox`, so credentials live at `/sandbox/.config/revenium/config.yaml` (not `~/.config/revenium/config.yaml` on the host). The `api-key:` field is what the CLI reads.

---

## Configuration

The skill stores its runtime config at `~/.openclaw/skills/revenium/config.json` (on the host, visible to the host cron):

```json
{
  "ruleIds": ["d5jng5"],
  "organizationName": "my-org",
  "autonomousMode": false,
  "notifyChannel": "slack",
  "notifyTarget": "#ops",
  "cronIntervalMinutes": 1
}
```

In-sandbox credential config is at `/sandbox/.config/revenium/config.yaml` (written by the installer):

```yaml
api-key: "your-api-key"
team-id: "your-team-id"
tenant-id: "your-tenant-id"
owner-id: "your-owner-id"
```

> **Rotate credentials?** Clear the `creds-written` entry from `~/.nemoclaw/revenium-nemoclaw.ledger` and re-run `scripts/install.sh --nemoclaw` to re-write the credential file.

---

## Uninstalling

```bash
# 1. Clear the host-side metering cron
bash ~/.openclaw/skills/revenium/scripts/uninstall-nemoclaw-cron.sh

# 2. Uninstall the enforcement plugin and clear its ledger key
#    (use the dedicated script — running openclaw plugins uninstall directly
#    does NOT clear the enforcement-plugin-installed ledger key, which would
#    cause a subsequent reinstall to silently skip the plugin).
bash ~/.openclaw/skills/revenium/scripts/uninstall-enforcement-nemoclaw.sh \
    --sandbox <your-sandbox-name>

# 3. Remove the skill from the sandbox
nemoclaw <your-sandbox-name> skill remove revenium

# 4. Remove the skill directory from the host
rm -rf ~/.openclaw/skills/revenium
```

Optionally clean up your Revenium guardrail rules:

```bash
revenium guardrails budget-rules list
revenium guardrails budget-rules delete <rule-id> --yes
```

---

## Troubleshooting

### macOS: installer exits immediately with "NemoClaw is unsupported on macOS."

This is expected — see [macOS Unsupported](#macos-unsupported) above. Provision a Linux host to use the NemoClaw path.

### SSHFS unsafe-filename error

If you see an error like `File names must match [A-Za-z0-9._-/]` during the SSHFS share mount, the sandbox name contains a character outside the allowed set. Sandbox names must match `[A-Za-z0-9._-/]`. If the error appears during skill install (step 8), the installer checks for `SKILL.md` at the resolved skill path before calling `nemoclaw skill install` — if the path resolved to `~/` or another wrong location (e.g., due to SSHFS path issues), the installer aborts with:

```
  ✗ SKILL.md not found at <path> — cannot determine skill root.
    Run the install from the skill directory: bash ~/.openclaw/skills/revenium/scripts/post-install-nemoclaw.sh
```

Run the install as instructed — from the skill directory on the host, not from inside the sandbox.

### Skill not ready after install (`openclaw skills list` does not show `✓ ready`)

The installer asserts `✓ ready` after `nemoclaw skill install` and aborts if it is not present. If you see this failure:

1. Check the sandbox is running: `nemoclaw <name> status`
2. Inspect the sandbox: `nemoclaw <name> status` and look for errors
3. Retry the install (all steps are ledger-gated; a failed step's ledger key is not written so it will retry)

### Enforcement plugin not injecting the guardrail directive

The `revenium-enforcement` plugin uses the `before_prompt_build` hook to inject the directive. The installer validates this via the `promptChars` gate (Gate A) and `openclaw plugins inspect` (Gate B) — if either fails, the install aborts.

If you suspect the plugin has become inactive after a sandbox restart:

```bash
nemoclaw <your-sandbox-name> exec -- sh -lc "openclaw plugins inspect revenium-enforcement"
```

Look for `before_prompt_build` and `before_agent_finalize` in the output. If the plugin is listed but hooks are absent, recover the sandbox to reload plugins:

```bash
nemoclaw <your-sandbox-name> recover
```

### Sandbox restart / recovery

To restart or recover the sandbox:

```bash
nemoclaw <your-sandbox-name> recover
```

After a recovery, the SSHFS mount may need to be re-established. The host-side metering cron includes mount-health gating — if the mount is stale, the next cron tick will detect and re-mount.

### Re-provisioning after an API key rotation

Clear the relevant ledger key and re-run the install:

```bash
# Remove just the credential write entry
grep -v "^creds-written=" ~/.nemoclaw/revenium-nemoclaw.ledger \
  > ~/.nemoclaw/revenium-nemoclaw.ledger.tmp \
  && mv ~/.nemoclaw/revenium-nemoclaw.ledger.tmp ~/.nemoclaw/revenium-nemoclaw.ledger

# Also clear meter-probe-passed if you want to re-run the smoke test
# (note: clearing this emits a new metered-event)
grep -v "^meter-probe-passed=" ~/.nemoclaw/revenium-nemoclaw.ledger \
  > ~/.nemoclaw/revenium-nemoclaw.ledger.tmp \
  && mv ~/.nemoclaw/revenium-nemoclaw.ledger.tmp ~/.nemoclaw/revenium-nemoclaw.ledger

export REVENIUM_API_KEY=<new-key>
bash ~/.openclaw/skills/revenium/scripts/install.sh --nemoclaw
```

---

## Cross-References

- [SKILL.md](../SKILL.md) — the skill manifest; the guardrail halt/warn enforcement directives the agent reads
- [BUDGET-GUARD.md](../BUDGET-GUARD.md) — the guardrail directive content injected into every isolated/cron session; explains why the plugin is mandatory beyond `skill install`
- [README.md](../README.md) — standalone OpenClaw + Docker install path (macOS or Linux without NemoClaw)

---

## Support

Questions, bugs, or feature requests? Join us on [Discord](http://discord.gg/J2DbmjZ2nA).
