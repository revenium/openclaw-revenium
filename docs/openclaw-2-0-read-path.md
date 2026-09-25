# OpenClaw 2.0 Read Path — Operator Reference

This document explains how the Revenium skill reads OpenClaw 2.0's session data on a
`>=2026.8.1` host: where the session store lives, what the three store states mean, where
subagent-attribution data comes from, and what to check first when metering goes quiet.

**Coverage note (read this first):** everything below was verified live on the **standalone
OpenClaw + Docker + Claude pairing** (a live test host, OpenClaw 2026.9.6). The **NemoClaw /
OpenShell + Nemotron pairing was NOT exercised by this verification** — see `19-07-SUMMARY.md`
`## Scope: Which Pairing This Evidence Covers` for the full statement. Do not assume parity for
the sandbox pairing.

## Where the session store lives

Each install arm has its own SQLite session store, and the two arms run **independently
versioned OpenClaw builds that must never be normalized to one another**:

| Install arm | Session store path | OpenClaw build observed |
|---|---|---|
| Standalone (`~/.openclaw`) | `~/.openclaw/agents/<agentId>/agent/openclaw-agent.sqlite` | 2026.9.6 (eb377ac) |
| NemoClaw / OpenShell sandbox | `/sandbox/.openclaw/agents/<agentId>/agent/openclaw-agent.sqlite`, reached host-side only through the `nemoclaw share mount` SSHFS channel | 2026.9.1 (ad6fe23) as of the Phase 17 spike; not independently reconfirmed by this plan |

A host normally has multiple agents (e.g. `dev`, `main`), each with its own store file. The
skill's session-store layer (`scripts/session-store.sh`) globs
`${OPENCLAW_HOME}/agents/*/agent/openclaw-agent.sqlite` and treats **every matched store as one
combined session universe** for a tick — a session id is looked up across all of them.

**If one store among several is unreadable, the whole tick reports UNREADABLE**, not a partial
result from the readable stores. This is deliberate (see below) but worth knowing operationally:
a broken store for a rarely-used agent can silence metering for every other agent on the same
host until it is fixed.

## The read itself

The read is **read-only** and **bounded by a busy timeout**:

```
sqlite3 -cmd "PRAGMA busy_timeout=5000;" "file:<path>?mode=ro" "<SQL>"
```

No retry/backoff wrapper — `busy_timeout` is the only patience the read gets. A live 62-tick,
61-minute per-minute soak against a concurrently-written store produced zero lock errors and zero
stalls on the host-local cell (Phase 17 spike 011). The SSHFS-mounted cell (the NemoClaw pairing's
channel) was not soak-tested and should not be assumed to inherit that result.

A transient `SQLITE_BUSY`/lock condition during a live write can, in rare cases, be misreported
by the schema probe as `UNREADABLE` with a "missing columns" reason even though the columns are
present and a retry succeeds immediately — see `19-07-SUMMARY.md` for a live-observed instance.
If a tick reports UNREADABLE with a schema-missing reason, retry once before treating it as a
genuine schema change.

## The three store states

The tick classifies the store into exactly one of three states every run, and writes the
classification to a durable status file (see below) in **all three** cases:

| State | Meaning | Log | Exit code | Status file |
|---|---|---|---|---|
| `READABLE` | File exists, opens read-only, `session_nodes` queryable. Normal path. | `[INFO]` progress lines per session | `0` | `state: "READABLE"` |
| `EMPTY` | Opens and queries cleanly, zero non-cron sessions. A legitimate fresh host. | `[INFO] Session store is readable but holds zero non-cron sessions (fresh host) — nothing to meter this tick.` | `0` — **not a failure** | `state: "EMPTY"` |
| `UNREADABLE` | No store file under any candidate path, OR the file exists but open/query fails (corrupt, permission, schema mismatch, locked past the busy timeout). | `[ERROR] Session store unreadable — metering skipped this tick. Paths tried: <path1>, <path2>. <verbatim sqlite error>` | `1` (non-zero) | `state: "UNREADABLE"` |

**`UNREADABLE` is loud by design, on all three signals at once**, confirmed live: the log line
names every candidate path tried, the tick exits non-zero (so cron mail or a supervisor sees it),
and the status file below is written. It is **not a halt** — an unreadable store is an
observability defect, not a budget breach. A real agent turn driven while the store was
deliberately made unreadable completed normally; metering is a side channel to the agent, not a
gate on it.

One live gap found during verification: for a permission-denied unreadable store (`chmod 000` on
the file), `error_text` in both the log line and the status file was **empty** rather than
carrying the verbatim sqlite/OS error text — the paths-tried list, the non-zero exit, and the
status file itself were all still correct. If you are debugging an `UNREADABLE` state and
`error_text` is blank, check file permissions and ownership directly; do not assume the store is
merely absent.

## The subagent edge sidecar

The subagent attribution path has two sources, consulted in a fixed priority order:

1. **Primary — the plugin sidecar.** The `revenium-marker-gate` plugin registers
   `subagent_spawned`/`subagent_ended` hooks and appends one JSON line per event to:

   ```
   ${OPENCLAW_HOME}/skills/revenium/subagent-edges.jsonl
   ```

   Each line looks like:

   ```json
   {"event":"spawned","childSessionKey":"agent:dev:subagent:<uuid>","parentSessionKey":"agent:dev:main","runId":"<uuid>","capturedAt":"<iso8601>"}
   {"event":"ended","childSessionKey":"agent:dev:subagent:<uuid>","parentSessionKey":"agent:dev:main","runId":"<uuid>","outcome":"ok","capturedAt":"<iso8601>"}
   ```

   The file is bounded: it rotates to a `.1` sibling once it reaches 2 MiB
   (`SIDECAR_MAX_BYTES`), and a write failure fails open (never throws, never blocks the hook).
   `get-root-session-id.py --debug` prints which source answered (`sidecar`, `store`, or `none`)
   to stderr before the resolved id on stdout.

2. **Fallback — the store's own parentage columns**, consulted only when the sidecar has no edge
   for a given hop: `session_nodes.parent_session_key` / `spawned_by` / `fork_source_session_key`
   / `fork_source_session_id` (and the equivalent `session_windows` columns). **Confirmed live**
   (this plan) that these columns DO populate for a real subagent spawn on the standalone
   pairing — `parent_session_key` and `spawned_by` were both set to the parent's session key. This
   was previously unconfirmed; it does not change the priority order (the sidecar stays primary
   per D-08), but it means the fallback is a real safety net, not a theoretical one, at least on
   this pairing.

## What to check first when metering goes quiet

1. `cat ${OPENCLAW_HOME}/skills/revenium/read-path-status.json` — the durable status file, written
   every tick regardless of outcome. Key names: `state` (`READABLE`/`EMPTY`/`UNREADABLE`),
   `timestamp`, `paths_tried` (array), `error_text`, `schema_missing` (array, non-empty only for a
   genuine schema-drift `UNREADABLE`), `store_count`.
2. If `state` is `UNREADABLE`: check the paths in `paths_tried` exist and are readable by the
   user running the tick. Retry once before concluding schema drift — a transient lock can
   present as a false schema-missing reading (see above).
3. If `state` is `EMPTY`: this is a legitimate fresh host with no non-cron sessions yet, not a
   defect. Confirm an agent turn has actually happened since the store was created.
4. If `state` is `READABLE` but a specific session's completions/tool-events are not appearing:
   confirm the session id is a normal OpenClaw-generated identifier. The store's own ID/key
   validators only accept `[0-9a-fA-F-]` shapes for session ids; an operator-supplied
   `--session-id` value that is not hex-and-hyphen shaped (a human-readable label, for example)
   is silently rejected by the validator with a `WARN`-level log line and produces zero metering
   for that session, with no entry in `read-path-status.json` — this is a per-session validation
   reject, not a store-level failure, so it will not show up as `UNREADABLE`. Confirmed live
   during this plan's verification.
5. `revenium-reported.ledger` / `revenium-tool-events.ledger` under `${OPENCLAW_HOME}` are the
   append-only dedup ledgers, keyed `TX:<responseId>` and `TOOLEV:<toolCallId>` respectively.
   Grepping either for an id under investigation shows whether that specific completion or tool
   call was ever metered.

## What is verified, and on which pairing

This document (`docs/openclaw-2-0-read-path.md`) describes the read path as verified live by
Phase 19 Plan 07 on the **standalone OpenClaw + Docker + Claude pairing only**. All four
sections above — the session store paths, the three store states, the subagent edge sidecar, and
the ledger-based ledger lookup — were exercised with real live evidence on that pairing. The
NemoClaw / OpenShell + Nemotron pairing's read path, hook-firing behavior, and SSHFS-mounted store
concurrency profile remain unverified against this implementation; treat any assumption of parity
for that pairing as unconfirmed until it is independently checked (tracked for Phase 22).
