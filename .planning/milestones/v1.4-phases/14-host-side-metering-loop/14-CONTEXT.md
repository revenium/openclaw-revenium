# Phase 14: Host-Side Metering Loop - Context

**Gathered:** 2026-06-08
**Status:** Ready for planning

<domain>
## Phase Boundary

Deliver a **host-side** metering loop for the NemoClaw install path: a host cron job that reads the in-sandbox OpenClaw session logs over an SSHFS `nemoclaw share mount` of `/sandbox/.openclaw`, meters via the **host** revenium CLI, and writes a refreshed `guardrail-status.json` back through the mount — keeping the in-sandbox agent's enforcement state current.

**Architecture is LOCKED by spike 004 (VALIDATED) + ROADMAP SC1–4** — discussion covered only HOW to build on top of it:
- Host cron + `nemoclaw share mount` (SSHFS). **NOT** per-tick `nemoclaw exec`, **NOT** an in-sandbox daemon.
- Host reads logs from the mount and meters via the host revenium CLI (host has open egress — the loop needs no sandbox egress policy).
- The existing standalone cron / `report.sh` / `guardrail-check.sh` must **not** be modified (SC4).
- `sshfs` is a host prerequisite.

**Out of scope (other phases):** the in-sandbox agent's *consumption* of `guardrail-status.json` and any per-turn enforcement/fail-safe-on-stale behavior (Phase 15); skill deploy + operator docs (Phase 16).
</domain>

<decisions>
## Implementation Decisions

### Loop body & host auth
- **D-01:** Reuse the existing `scripts/cron.sh` (which already runs `report.sh` + `guardrail-check.sh`) via a thin NemoClaw cron wrapper that sets `OPENCLAW_HOME=<mount>` so the shared scripts read session logs from the mount and write `guardrail-status.json` back through it. No metering/status logic is duplicated; the shared scripts are not modified (SC4). Any future metering improvement flows to both install paths automatically.
- **D-02:** The host-side loop authenticates to Revenium from a **host-side env** (e.g. `~/.nemoclaw/revenium-host.env` with the same `REVENIUM_API_KEY` + `REVENIUM_TEAM_ID` used to provision the sandbox), written at install time and sourced by the NemoClaw wrapper — **not** the mount's `revenium.env`. Rationale: with `OPENCLAW_HOME` pointed at the mount, `cron.sh`'s default `${OPENCLAW_HOME}/revenium.env` would resolve to the sandbox's env, and the sandbox's api key lives at `/sandbox/.config/revenium` (outside the mounted `/sandbox/.openclaw`). The host CLI must authenticate independently so metering bills the right account.

### Mount lifecycle
- **D-03:** **Cron tick self-heals.** A dedicated `install-nemoclaw-cron.sh` establishes the mount once and installs the cron. Each tick first checks mount health (`mountpoint -q` / `[ -d "$MNT/skills" ]`) and re-establishes it via `nemoclaw <sandbox> share mount /sandbox/.openclaw <mount>` if it's gone, so a sandbox restart or dropped SSHFS self-recovers on the next tick. If the remount itself fails, the tick logs a clear error and exits non-zero (rc 3) without metering — never hangs (SC3).
- **D-04:** `sshfs` is ensured by a **hard-gate preflight in `install-nemoclaw-cron.sh`**: if missing, attempt `apt-get`/`dnf` install; if that fails, abort install with an explicit "install sshfs then re-run" message rather than installing a cron that can never mount. Keep the failure at install time, not silently every tick.

### Failure / stale-status safety
- **D-05:** **Freshness/TTL contract — never write a false all-clear.** Healthy ticks always advance `updatedAt`/`_tick`. On any failure (mount down, remount failed) the loop writes **nothing** to `guardrail-status.json` (so `updatedAt` simply freezes) and logs the failure. The status carries a max-age/TTL signal so the Phase 15 consumer can fail-safe (treat status older than the TTL as halt/warn). The loop must never overwrite the status with stale "all clear" data that could let an over-budget agent run free.
- **D-06 (planner constraint):** Because the shared `guardrail-check.sh` writes the status and cannot be modified (SC4), the TTL/staleness is derived from the existing `updatedAt` field — either consumed directly by Phase 15 against a configured interval, or stamped as an explicit `_maxAgeSeconds` field **post-write** by the NemoClaw wrapper. Do **not** edit the shared status writer to add the field.

### Cron coexistence & identity
- **D-07:** **Per-sandbox tagged cron entry.** The NemoClaw cron uses a distinct, sandbox-scoped crontab comment marker (e.g. `# revenium-metering-nemoclaw:<sandbox>`) so it never collides with the standalone `# revenium-metering` entry or other sandboxes' entries. `install-nemoclaw-cron.sh` is idempotent per sandbox (re-run updates that sandbox's entry only). Multiple sandboxes on one host are supported via distinct markers.
- **D-08:** Interval reuses the existing precedence from `install-cron.sh` (`--interval N` > `config.json cronIntervalMinutes` > default 1 minute, range 1–59).

### Claude's Discretion (planner decides)
- Per-sandbox mount path convention (e.g. `~/sbx-openclaw-<sandbox>` to support concurrent sandboxes).
- Tick logging/observability location (history + error log path).
- A NemoClaw uninstall counterpart modeled on `scripts/uninstall-cron.sh` (remove the per-sandbox cron entry + optionally unmount).
- Exactly where the host-side `revenium.env` is written (install-nemoclaw-cron.sh vs folding into post-install-nemoclaw.sh) and its precise path.
</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Spike findings — host-side metering architecture (LOCKED)
- `.claude/skills/spike-findings-openclaw-revenium/sources/004-background-metering-loop/README.md` — the recommended architecture (host cron + `share mount`), why per-tick `exec` and in-sandbox cron are rejected, and the validated tick evidence.
- `.claude/skills/spike-findings-openclaw-revenium/sources/004-background-metering-loop/revenium-mount-tick.sh` — proven mount-aware tick pattern (mount-gone → `exit 3`; write status through the mount, no `exec`).
- `.claude/skills/spike-findings-openclaw-revenium/references/revenium-cli-and-metering.md` — host-side loop guidance, `sshfs` prerequisite, "avoid per-tick exec", `SSL_CERT_FILE`/`api-key:` notes.

### Requirements & roadmap
- `.planning/REQUIREMENTS.md` — NCMETER-01.
- `.planning/ROADMAP.md` §"Phase 14: Host-Side Metering Loop" — goal + Success Criteria SC1–SC4 (the must-be-true list).

### Phase 13 provisioning (the install path this extends)
- `.planning/phases/13-sandbox-provisioning-egress-cli-authenticated-metering/13-03-SUMMARY.md` — provisioning end state + live-smoke gotchas (NemoClaw exec rejects newline argv; `api-key:` config field; meter success shape). Relevant if the host env write reuses provisioning machinery.
</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `scripts/cron.sh` — existing cron runner: resolves `OPENCLAW_HOME` (env override supported), sources `${OPENCLAW_HOME}/revenium.env`, ensures the revenium CLI is on PATH, then runs the metering/status scripts. **Reuse via `OPENCLAW_HOME=<mount>` (D-01)** — but override env-sourcing so host auth is used (D-02).
- `scripts/install-cron.sh` — existing installer: `cronIntervalMinutes` precedence, idempotent crontab entry keyed on a `# revenium-metering` comment, `OPENCLAW_HOME` probe. **Model for `install-nemoclaw-cron.sh`** (per-sandbox marker, sshfs preflight, mount establishment).
- `scripts/uninstall-cron.sh` — model for the NemoClaw uninstall counterpart.
- `scripts/post-install-nemoclaw.sh` — Phase 13 provisioning (ledger, `probe-host-compat.sh` preflight pattern, sandbox-name resolution). Candidate home for the host-side `revenium.env` write.

### Established Patterns
- `report.sh` (metering: completions/jobs/tools) + `guardrail-check.sh` (writes `guardrail-status.json` atomically each tick) are the shared workhorses cron.sh invokes — **MUST NOT be modified (SC4)**. The NemoClaw loop drives them unchanged via `OPENCLAW_HOME`.
- Idempotent crontab management keyed on a comment marker; `cronIntervalMinutes` config precedence.
- Step-keyed ledger + preflight-hard-gate patterns from `post-install-nemoclaw.sh` (Phase 13) for the install script.

### Integration Points
- Mount: SSHFS `nemoclaw <sandbox> share mount /sandbox/.openclaw <mount>` (in-sandbox HOME=`/sandbox`; openclaw state at `/sandbox/.openclaw`).
- Status file: `<mount>/skills/revenium/guardrail-status.json` ↔ in-sandbox `/sandbox/.openclaw/skills/revenium/guardrail-status.json` (host writes are instantly visible to the agent — spike 004).
- Host revenium auth: host-side env file (D-02), independent of the sandbox's `/sandbox/.config/revenium/config.yaml`.
</code_context>

<specifics>
## Specific Ideas

- Tick shape (from spike + D-01/D-03): `MNT="$HOME/sbx-openclaw-<sandbox>"`; ensure/remount-or-`exit 3`; `source <host revenium.env>`; `OPENCLAW_HOME="$MNT" cron.sh`; record tick health.
- Crontab coexistence example: `# revenium-metering` (standalone, untouched) alongside `# revenium-metering-nemoclaw:revenium-spike`.
</specifics>

<deferred>
## Deferred Ideas

- **Phase 15 consumer fail-safe-on-stale** — honoring the D-05 TTL/`updatedAt` freshness contract (treating stale status as halt/warn) is the in-sandbox enforcement plugin's job, not this phase.
- **Active degraded signal via one-shot `exec`** — considered for mount-down (stamp `degraded:true` directly in-sandbox); deferred in favor of the freshness/TTL contract (D-05). Revisit only if Phase 15 cannot honor TTL.
- **systemd/fstab supervised mount** — considered for mount durability; deferred in favor of the cron-tick self-heal model (D-03) to avoid OS-specific/root setup.
</deferred>

---

*Phase: 14-host-side-metering-loop*
*Context gathered: 2026-06-08*
