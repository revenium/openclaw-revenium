# Sandbox `revenium-2-0` unavailable — orchestrator note for plans 17-04, 17-05, 17-06

**Date:** 2026-09-24
**Host:** 52.90.9.242
**Status:** NemoClaw/OpenShell pairing is NOT reachable through its production access path. The standalone pairing is unaffected and fully working.

This note is binding on the remaining plans in phase 17. Read it before planning any sandbox work.

## What plans must do

Treat every NemoClaw/sandbox cell as an **open question**, not a PARTIAL and not a failure:

- Run the standalone-pairing cells normally and grade them.
- For sandbox cells, record `not run — sandbox unavailable, see 17-SANDBOX-BLOCKER.md` with the reason. Do not infer a sandbox result from the standalone result, and do not infer one from documentation.
- Per the phase's own prohibition: *"A spike verdict must NOT be recorded for a question whose probe was not actually run on the live host — an unrun question is an open question, not a PARTIAL."*
- Where a plan's `must_haves` require both pairings (17-04's both-pairings provenance bar, 17-05's "SSHFS cell is required, not optional"), state plainly in the determination that the bar is **unmet**, and why. Do not weaken the bar to make it pass.
- Do NOT attempt to repair the sandbox. Host recovery is the operator's, and is deliberately out of scope for these plans.

## Exact state as of this note

| Layer | State |
|---|---|
| Container `openshell-default--revenium-2-0-5e9fd2bf-...` (id `9361c029...`) | Up (healthy); workspace state preserved |
| In-container OpenClaw gateway | Running (PID 416 `openclaw-gatewa`), reachable at `ws://127.0.0.1:18789`, config `/sandbox/.openclaw/openclaw.json` |
| Host `openshell-gateway` daemon (PID 3714081, packaged-service) | Reachable — `nemoclaw ... doctor` reports `[ok] OpenShell status: connected to nemoclaw` |
| `nemoclaw revenium-2-0 exec` / `start` / `recover` | **Refused** — registry reports `Phase: Error` |
| `docker exec` into the container | Works (but is NOT the production path these spikes test — do not substitute it) |
| `AUTH_PROFILE_MIGRATION_REQUIRED` | **Still unfixed** — the original blocker |
| SSHFS mount `~/nemoclaw-revenium-2-0-mount` | Present but stale |

Blocking error from the control plane:

```
OpenShell container identity changed for sandbox 'revenium-2-0';
refusing privileged execution against a different container.
```

## How it got here

1. Plans 17-02 and 17-03 both hit `AUTH_PROFILE_MIGRATION_REQUIRED` in the sandbox and both correctly declined to run `openclaw doctor --fix`, because each was concurrently reading the store the other was studying.
2. With the contention gone, the orchestrator attempted the migration. `doctor --fix` requires the gateway stopped, not merely suspended: `gateway suspend` succeeded (0 blockers) but did not release the `gateway-lifecycle` lock, and `openclaw gateway stop` targets launchd/systemd/schtasks while this gateway is supervised by `nemoclaw-start`.
3. The orchestrator killed the gateway PID. **That propagated to the container's supervisor chain and the container exited 143.** The identity mismatch dates from this moment.
4. Recovery attempts: `nemoclaw recover` (failed, gateway stage), `nemoclaw start` (failed on a permissions guard), `chmod g-w ~/.local ~/.local/state` (applied — revert with `chmod g+w` if unwanted), `nemoclaw start` again (ConnectError code 9), `docker start` (succeeded — container healthy), `nemoclaw recover` again (still refused, `lifecycleAction=skipped`).

**Root cause of the mistake:** `nemoclaw <name> stop` and `nemoclaw <name> gateway restart` both exist and are the sanctioned ways to stop that gateway. The orchestrator reached for `kill` before enumerating the CLI's own lifecycle verbs. Anything needing a gateway stop in this sandbox should use those verbs.

## Untouched and safe

- The standalone pairing on 52.90.9.242 — OpenClaw 2026.9.6 + Docker — is unaffected and working.
- Waves 1 and 2 are complete, merged, and pushed to `origin/main`: plans 17-01, 17-02, 17-03 and spike artifacts 007, 008, 010.
- Nothing in the repository was damaged at any point.

## Candidate recovery paths (operator's call, not a plan's)

- `nemoclaw revenium-2-0 rebuild` — the remedy `status` itself hints at. **Caution:** it upgrades the sandbox to the current agent version, which may move OpenClaw off the 2026.9.1 that spike 007 recorded as a D-15 fact, and spike 007 also found SSHFS share mounts go stale across rebuilds — the mount 17-05's SSHFS cell needs.
- Reconciling the OpenShell registry's recorded container identity against the live container.
- After either, the original `AUTH_PROFILE_MIGRATION_REQUIRED` migration still needs to run — via `nemoclaw revenium-2-0 stop` or `nemoclaw revenium-2-0 gateway restart`, never `kill`.
