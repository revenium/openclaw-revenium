# Phase 15: Per-Turn Enforcement Plugin - Context

**Gathered:** 2026-06-08
**Status:** Ready for planning

<domain>
## Phase Boundary

Deliver **per-turn enforcement** into the NemoClaw/OpenShell sandbox by installing **one combined OpenClaw plugin** (`revenium-enforcement`) that registers:

- **`before_prompt_build`** (guard) — injects the mandatory guardrail directive into **every** agent turn, so halt and warn-and-ask enforcement work under NemoClaw (**NCENF-01**, the highest-risk requirement in v1.4).
- **`before_tool_call` + `before_agent_finalize` + `agent_end`** (marker gate) — reuses the Phase 11 marker logic so task/job markers are written under NemoClaw and attribution flows (**NCENF-02**).

Plus the install-path wiring that delivers, trusts, validates, and (per D-08) deploys the skill into the sandbox — replacing `stub_install_enforcement_plugin()` in `scripts/post-install-nemoclaw.sh`.

**Locked by spikes 005/006 + ROADMAP SC1–5 — NOT re-litigated here:**
- Mechanism is `before_prompt_build` → `prependContext` (production-proven by the nemoclaw plugin; reaches every turn).
- The plugin MUST be authored from the official scaffold (`openclaw plugins init`) or by mirroring the nemoclaw / Phase 11 plugin's compiled-ESM shape — **never a hand-rolled stub** (spike 006: a hand-stubbed plugin hung the turn).
- Install MUST be a clean `openclaw plugins install` so hooks are **trusted (provenance)** — untrusted/hand-placed plugins load but their hooks are inert.
- `package.json` needs `openclaw.extensions`; manifest needs `configSchema` (each omission is a hard failure; a bad manifest can break the whole openclaw CLI).
- Runtime contract is **fail-open** (SC4): a hook error/timeout never blocks the agent's reply — same contract as the Phase 11 plugin.
- Validate on the **live sandbox host 34.224.27.67** (sandbox `revenium-spike`), via the gateway turn path — not only an isolated unit test.

**Out of scope (other phases):** operator documentation, prerequisites guide, and the macOS-unsupported note (**Phase 16 / NCDEPLOY-02**). Any change to the standalone marker logic beyond the shared `gate.js`/`BUDGET-GUARD.md` edits below.

</domain>

<decisions>
## Implementation Decisions

### Guard directive content (NCENF-01)
- **D-01:** `revenium-enforcement`'s `before_prompt_build` hook injects the **contents of `BUDGET-GUARD.md` verbatim** as `prependContext`. Same enforcement semantics as the standalone path; one source of truth maintained for both paths. The agent then reads `~/.openclaw/skills/revenium/guardrail-status.json` and honors `halted`/`warned` exactly as it does standalone.
- **D-02:** The directive text is **inlined at build time** — a build step reads `BUDGET-GUARD.md` and bakes the string into the plugin's compiled `dist/index.js` (committed). The plugin stays **pure/static** (no fs I/O at hook time) — the safest posture against the spike-006 hang and the install-time safety scanner. Cost: a `BUDGET-GUARD.md` edit requires a plugin rebuild + redeploy (same discipline as the marker-gate's tsc→dist flow; see Pitfall 2 in Phase 11 research).
- **D-03:** Honor the Phase 14 stale-status hand-off (D-05/D-06) by adding a **freshness rule to `BUDGET-GUARD.md` itself** (so standalone + NemoClaw share one directive). The rule: if `guardrail-status.json` exists but is too old, treat it as **WARNED** (fail-safe), never as an all-clear. **NOTE for planner:** this edits the standalone enforcement contract — it is a regression-test surface; ensure standalone behavior is unchanged when the freshness field is absent (D-04).
- **D-04:** Staleness uses a **self-describing field already written by Phase 14: `_maxAgeSeconds`** (underscore prefix — confirmed stamped post-write by `scripts/nemoclaw-cron-tick.sh` Step 4 on the NemoClaw path). The directive rule: *if `_maxAgeSeconds` is present AND `now - updatedAt > _maxAgeSeconds` → treat as WARNED; if the field is absent, skip the freshness check.* The standalone `guardrail-check.sh` does **not** write `_maxAgeSeconds`, so standalone is unaffected unless it later opts in. The directive must read the exact field name `_maxAgeSeconds`.

### Plugin packaging (NCENF-01 + NCENF-02)
- **D-05:** Ship **one combined `revenium-enforcement` plugin** registering all four hooks (`before_prompt_build` guard + the three marker hooks), rather than two separate plugins. One install, one trust gate, one config entry, one gateway restart. (This diverges from the ROADMAP's "plugin + adapter" phrasing — packaging is one plugin; the two requirements are still both delivered.)
- **D-06:** The combined plugin **imports `plugin/src/gate.js` verbatim** (`safeBeforeToolCall` / `safeBeforeAgentFinalize` / `safeAgentEnd`) and only **adds** the new `before_prompt_build` guard hook in its thin wiring layer. `gate.js` stays the **single source of truth** for marker logic — Phase 11's tests still guard it. The standalone `plugin/` (revenium-marker-gate) keeps its own thin wrapper around the same `gate.js`. **Zero marker-logic divergence.**
- **Config required (locked-by-spike, for the planner):** the combined plugin's manifest needs `activation.onStartup: true` (the guard's `before_prompt_build` must register at startup — note Phase 11's marker-gate used `onStartup: false`), and the in-sandbox config patch must set `enabled: true` **and** `hooks.allowConversationAccess: true` (required for `before_agent_finalize` + `agent_end`, exactly as `scripts/post-install.sh` §7c does for standalone).

### Marker-gate sandbox adaptation (NCENF-02)
- **D-07:** Deploy the marker hooks **verbatim — no code adaptation.** `gate.js` is observe-only (it returns a *revise* directive telling the agent to run `~/.openclaw/skills/revenium/scripts/write-marker.sh`), and both `gate.js` and `write-marker.sh`/`common.sh` resolve paths from `~`/`OPENCLAW_HOME`, which is `/sandbox/.openclaw` in-sandbox. `write-marker.sh` writes a **local** `markers/<sid>.jsonl` (no revenium CLI, no egress, no SSL_CERT) that the Phase 14 host loop reads over the mount and meters. The real risk is **in-sandbox runtime deps** — so the install script **hard-gates on a preflight + live smoke**: assert `python3` present in-sandbox, `write-marker.sh` + taxonomy deployed, then write a test marker and confirm it appears in `<mount>/markers/` over the share. Catches the "silently no markers / attribution never flows" failure at install, not in production. Follows the Phase 13/14 hard-gate-preflight pattern.
- **D-08:** **Pull `nemoclaw skill install` (the bare deploy mechanic) into Phase 15**, run before the plugin step, so the marker chain is testable end-to-end here and SC3 is honestly verifiable. Phase 16 keeps only docs + polish (operator guide, prerequisites, macOS-unsupported note). **NOTE for planner / roadmap:** this shifts NCDEPLOY-01's *deploy step* earlier; the install-path order becomes `13 provisioning → 14 metering loop → 15a skill install → 15b plugin install → 15c preflight+smoke → 16 docs`. Flag a ROADMAP/REQUIREMENTS note so the mapping reflects it.

### Install & validation gate (NCENF-01, SC1)
- **D-09:** **Fail-hard install-time validation** (independent of the locked fail-OPEN *runtime* contract). After install → config patch → `nemoclaw <sbx> recover`, run a **real gateway turn** and assert the guard injected, AND `openclaw plugins inspect revenium-enforcement` shows the hooks trusted/active. If the assertion fails, **abort the install non-zero**. Closes the exact spike-006 failure modes (untrusted-but-inert / trusted-but-hung) at install time rather than in production. (This is stricter than the standalone `post-install.sh` warn-and-continue — justified because NCENF-01 is the highest-risk requirement.)
- **D-10:** Detect injection **prompt-side, deterministically**: wrap the inlined `BUDGET-GUARD.md` in a `<revenium-guard>…</revenium-guard>` tag and assert that tag/block appears in the turn's `finalPromptText` (exposed by `openclaw agent --json`, per spikes 005/006). This verifies the prompt was *built* with the directive independent of model behavior, and keeps real production turns clean (no forced sentinel echo). The tag also aids debugging. (Supersedes the spike's reply-side `REVENIUM_GUARD_ACTIVE` sentinel.)
- **D-11:** Deliver the built plugin **via the Phase 14 share mount**: the install script ensures the SSHFS mount (reuse Phase 14's mount-establish/self-heal helper), copies the committed plugin dir to `<mount>/extensions/revenium-enforcement/` (= `/sandbox/.openclaw/extensions/` in-sandbox — exactly the spike-006 layout), then `nemoclaw <sbx> exec -- openclaw plugins install /sandbox/.openclaw/extensions/revenium-enforcement`, applies the config patch, and `nemoclaw <sbx> recover`.

### Claude's Discretion (planner decides)
- **Combined plugin directory + build:** location/name of the new plugin source (e.g. `plugin-nemoclaw/`), and its tsc/build config that inlines `BUDGET-GUARD.md` (D-02) and bundles `gate.js` (D-06) into a committed `dist/index.js`. The host has no tsc — `dist/` must be committed (Phase 11 Pitfall 2).
- **Ledger idempotency:** key the real `install_enforcement_plugin()` (replacing `stub_install_enforcement_plugin`) on a ledger marker (e.g. `enforcement-plugin-installed`) following the Phase 13/14 ledger pattern; make config-patch + install idempotent on re-run.
- **Uninstall/teardown counterpart:** a NemoClaw plugin-uninstall path modeled on `scripts/uninstall-nemoclaw-cron.sh` (remove the plugin + config entry), if warranted.
- **Exact recover/restart invocation** and where the smoke-test mount handle comes from (reuse the metering mount vs a transient install-time mount).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Spike findings — the enforcement mechanism (LOCKED)
- `.claude/skills/spike-findings-openclaw-revenium/sources/006-plugin-directive-injection/README.md` — the `before_prompt_build` → `prependContext` proof, the trusted-vs-inert provenance finding, the hand-stub-hangs warning, and the exact install/recover/validate sequence.
- `.claude/skills/spike-findings-openclaw-revenium/sources/006-plugin-directive-injection/revenium-guard/` — the spike's `revenium-guard` skeleton (`index.js`, `package.json` with `openclaw.extensions`, `openclaw.plugin.json` with `configSchema`). Starting shape for the guard hook + manifest contract.
- `.claude/skills/spike-findings-openclaw-revenium/references/skill-deploy-and-enforcement.md` — why `skill install`/AGENTS.md cannot deliver the per-turn directive; the plugin route; what `skill install` skips (status seed, metering).

### Phase 11 marker-gate — the reuse target (LOCKED logic)
- `plugin/src/gate.js` — the pure marker logic to import **verbatim** (D-06): `safeBeforeToolCall`, `safeBeforeAgentFinalize`, `safeAgentEnd`, fail-open containment.
- `plugin/src/index.ts` — the wiring shape to mirror (`definePluginEntry`, `api.on(...)`, per-hook try/catch fail-open) and extend with `before_prompt_build`.
- `plugin/openclaw.plugin.json` + `plugin/package.json` — the manifest/package contract (`configSchema`, `openclaw.extensions`, peer `openclaw`, `tsc` build).
- `plugin/src/index.test.js` — the fail-open / hook-registration tests; extend to cover the guard hook.

### Enforcement directive (source of truth — gets the D-03 freshness edit)
- `BUDGET-GUARD.md` — the verbatim directive injected by the guard (D-01); add the `_maxAgeSeconds` freshness rule here (D-03/D-04).
- `SKILL.md` §"Guardrail Check Procedure" / "HALT CHECK" — the halt + warn-and-ask branches the directive points to.

### Marker write path (in-sandbox, local-only)
- `scripts/write-marker.sh` + `scripts/common.sh` — path resolution via `OPENCLAW_HOME` (= `/sandbox/.openclaw`), local `markers/<sid>.jsonl` write, python3 dependency (D-07 smoke).

### Install path + Phase 14 integration
- `scripts/post-install-nemoclaw.sh` — `stub_install_enforcement_plugin()` (line ~117) is what Phase 15 replaces; install order + ledger (`ledger_has`/`ledger_set`) + `install_metering_loop()` pattern to mirror.
- `scripts/post-install.sh` §7c (lines ~607–641) — the standalone plugin install + `allowConversationAccess` config-patch + `plugins inspect` verification pattern to adapt for the sandbox.
- `scripts/nemoclaw-cron-tick.sh` — Phase 14 tick; Step 4 stamps `_maxAgeSeconds` (D-04 source); the mount handle the smoke can reuse.
- `scripts/install-nemoclaw-cron.sh` — Phase 14 mount-establish/self-heal helper to reuse for D-11 delivery + D-07 smoke.

### Requirements & roadmap
- `.planning/REQUIREMENTS.md` — NCENF-01, NCENF-02 (and NCDEPLOY-01, whose deploy step D-08 pulls forward).
- `.planning/ROADMAP.md` §"Phase 15: Per-Turn Enforcement Plugin" — Goal, Success Criteria SC1–SC5, and the highest-risk note.
- `.planning/phases/14-host-side-metering-loop/14-CONTEXT.md` — D-05/D-06 the freshness/TTL hand-off that D-03/D-04 honor.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- `plugin/src/gate.js` — imported **verbatim** by the combined plugin (D-06); single source of truth for marker logic.
- `plugin/src/index.ts` — wiring template (`definePluginEntry`, fail-open per-hook try/catch) to mirror and extend with the guard hook.
- `BUDGET-GUARD.md` — directive payload, inlined at build (D-01/D-02); edited for freshness (D-03).
- `scripts/install-nemoclaw-cron.sh` / `scripts/nemoclaw-cron-tick.sh` — Phase 14 mount establish/self-heal helpers reused for plugin delivery (D-11) and the marker smoke (D-07).
- `scripts/post-install.sh` §7c — standalone plugin install + config-patch + inspect verification pattern.

### Established Patterns
- **Fail-open hook contract** — every handler wrapped so a throw resolves to pass-through; `before_agent_finalize` returns `undefined` on error (Phase 11). The guard hook follows the same contract.
- **Committed `dist/`** — host has no tsc; the build artifact (with inlined directive + bundled `gate.js`) must be committed (Phase 11 Pitfall 2).
- **Step-keyed ledger + hard-gate preflight** — Phase 13/14 install idempotency and "fail at install, not silently every run."
- **`allowConversationAccess` config patch** — required for `before_agent_finalize`/`agent_end` to register (verified vs openclaw 2026.6.1); applied in-sandbox via `openclaw config patch`.

### Integration Points
- In-sandbox plugin dir: `/sandbox/.openclaw/extensions/revenium-enforcement/` (reached via the Phase 14 mount at `<mount>/extensions/...`).
- In-sandbox marker output: `/sandbox/.openclaw/markers/<sid>.jsonl` ↔ `<mount>/markers/...` (host loop reads + meters — spike 004 / Phase 14).
- Directive ↔ status: guard injects `BUDGET-GUARD.md`; agent reads `/sandbox/.openclaw/skills/revenium/guardrail-status.json` (kept fresh by the Phase 14 loop; `_maxAgeSeconds` stamped there).
- Validation surface: `openclaw agent --json` `finalPromptText` (D-10) + `openclaw plugins inspect` (D-09), driven over `nemoclaw <sbx> exec`.

</code_context>

<specifics>
## Specific Ideas

- Combined-plugin hook set: `before_prompt_build` (guard, new) + `before_tool_call` + `before_agent_finalize` + `agent_end` (marker, reused from `gate.js`).
- `prependContext` shape (D-10): `"<revenium-guard>\n" + <BUDGET-GUARD.md contents> + "\n</revenium-guard>"`.
- Freshness rule (D-04): `if _maxAgeSeconds present AND now - updatedAt > _maxAgeSeconds → treat as WARNED; if absent → skip`.
- Install sequence (D-11/D-09): ensure mount → copy plugin to `<mount>/extensions/revenium-enforcement/` → `openclaw plugins install` → `config patch {enabled, hooks.allowConversationAccess}` → `nemoclaw <sbx> recover` → turn-test asserts `<revenium-guard>` in `finalPromptText` (else abort) → `plugins inspect` confirms hooks.
- Live validation host: `34.224.27.67`, sandbox `revenium-spike`.

</specifics>

<deferred>
## Deferred Ideas

- **Operator docs / prerequisites / macOS-unsupported note** — Phase 16 (NCDEPLOY-02). Only the bare `nemoclaw skill install` deploy mechanic is pulled into Phase 15 (D-08); the documentation stays in 16.
- **Adding `_maxAgeSeconds` to the standalone `guardrail-check.sh`** — directive supports it (D-04) but standalone opt-in is out of scope here; revisit only if standalone wants stale-protection.
- **Removing the python3 dependency from `write-marker.sh`** (pure bash/jq rewrite) — considered for fewer in-sandbox runtimes; rejected (touches a security-hardened shared script, reopens Phase 4). Phase 15 confirms python3 via preflight instead (D-07).
- **Active degraded signal via one-shot `exec`** — Phase 14 already deferred this in favor of the `_maxAgeSeconds` freshness contract now consumed here (D-04).

</deferred>

---

*Phase: 15-per-turn-enforcement-plugin*
*Context gathered: 2026-06-08*
