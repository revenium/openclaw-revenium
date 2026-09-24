# Phase 14: Host-Side Metering Loop - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-06-08
**Phase:** 14-host-side-metering-loop
**Areas discussed:** Loop body & host auth, Mount lifecycle, Failure / stale-status safety, Cron coexistence & identity

Architecture was pre-locked by spike 004 (VALIDATED) + ROADMAP SC1–4 (host cron + `nemoclaw share mount`; no per-tick `exec`; no in-sandbox daemon; do not modify the standalone scripts). Discussion covered only HOW to build on top of it.

---

## Loop body

| Option | Description | Selected |
|--------|-------------|----------|
| Reuse via OPENCLAW_HOME | Thin NemoClaw wrapper sets `OPENCLAW_HOME=<mount>` and calls existing `cron.sh` unchanged | ✓ |
| Dedicated NemoClaw tick | Separate script re-implementing read-logs → meter → write-status | |
| Hybrid: reuse + thin mount guard | Reuse cron.sh, but NemoClaw entrypoint owns mount health/stale/logging | |

**User's choice:** Reuse via OPENCLAW_HOME.
**Notes:** Existing `cron.sh` already supports an `OPENCLAW_HOME` override + `revenium.env` and runs `report.sh` + `guardrail-check.sh`. Zero logic duplication, honors SC4.

## Host auth

| Option | Description | Selected |
|--------|-------------|----------|
| Host revenium.env (set at install) | Write host-side env with same key/team; wrapper sources it, not the mount's | ✓ |
| Mount /sandbox/.config too | Second share mount of `/sandbox/.config/revenium` to read the sandbox key | |
| Decide in research | Defer the auth-wiring choice | |

**User's choice:** Host revenium.env written at install, sourced by the wrapper.
**Notes:** With `OPENCLAW_HOME=<mount>`, `cron.sh`'s default `${OPENCLAW_HOME}/revenium.env` would point at the sandbox env; the sandbox key lives at `/sandbox/.config/revenium` (outside the mount). Host must authenticate independently so metering bills the right account.

## Mount lifecycle

| Option | Description | Selected |
|--------|-------------|----------|
| Cron tick self-heals | Tick checks mount health and re-`share mount`s if gone; fail-and-log if remount fails | ✓ |
| Mount once, fail-and-log | Install establishes mount; tick only checks + exits on failure (no remount) | |
| systemd-style supervised mount | OS-supervised automount/fstab separate from cron | |

**User's choice:** Cron tick self-heals.
**Notes:** Sandbox restart / dropped SSHFS self-recovers on the next tick without operator action; hard remount failure → log + `exit 3`, never hang (SC3).

## sshfs prerequisite

| Option | Description | Selected |
|--------|-------------|----------|
| Preflight in cron-install, hard-gate | Check/install sshfs at install; abort with clear message if it fails | ✓ |
| Probe-host-compat preflight (Phase 13) | Fold sshfs check into the Phase 13 probe (warn) + re-check at install | |
| Decide in research | Defer where the check lives | |

**User's choice:** Hard-gate preflight in `install-nemoclaw-cron.sh` (apt/dnf, else abort).
**Notes:** Keep the failure at install time, not silently every tick.

## Stale safety

| Option | Description | Selected |
|--------|-------------|----------|
| Freshness contract, never write false | Healthy ticks advance updatedAt; on failure write nothing + log; TTL for consumer fail-safe | ✓ |
| Active degraded signal (one-shot exec) | On failed remount, stamp `degraded:true` directly in-sandbox via a single exec | |
| Both: TTL contract + degraded escalation | Default to TTL contract AND stamp degraded on hard failure | |

**User's choice:** Freshness/TTL contract; never a false all-clear.
**Notes:** Loop must never overwrite the status with stale "all clear" data. Constraint captured: TTL derived from existing `updatedAt` (or stamped post-write by the wrapper) so the shared `guardrail-check.sh` stays unmodified (SC4).

## Cron identity

| Option | Description | Selected |
|--------|-------------|----------|
| Per-sandbox tagged cron entry | Sandbox-scoped comment marker; idempotent per sandbox; multi-sandbox support; reuse interval precedence | ✓ |
| Single NemoClaw cron, one sandbox | One `# revenium-metering-nemoclaw` entry, single sandbox per host | |
| Decide in research | Defer marker scheme | |

**User's choice:** Per-sandbox tagged cron entry (`# revenium-metering-nemoclaw:<sandbox>`).
**Notes:** Never collides with the standalone `# revenium-metering` entry; interval reuses the `--interval` > `config.json cronIntervalMinutes` > default-1 precedence.

---

## Claude's Discretion

- Per-sandbox mount path convention (e.g. `~/sbx-openclaw-<sandbox>`).
- Tick logging/observability location.
- NemoClaw uninstall counterpart modeled on `uninstall-cron.sh`.
- Exact path/home of the host-side `revenium.env` and whether it's written by the cron-install step or folded into `post-install-nemoclaw.sh`.

## Deferred Ideas

- Phase 15 consumer fail-safe-on-stale (honoring the TTL contract) — Phase 15.
- Active degraded signal via one-shot `exec` — deferred in favor of the TTL contract.
- systemd/fstab supervised mount — deferred in favor of cron-tick self-heal.
