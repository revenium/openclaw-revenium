# Stack Research: OpenClaw 2.0 Cut-Over

**Domain:** OpenClaw skill/plugin runtime target (CLI + plugin SDK + sandbox runtime)
**Researched:** 2026-09-23
**Confidence:** HIGH (primary sources: official `docs.openclaw.ai`, the `openclaw` npm registry entry itself, and NVIDIA's `docs.nvidia.com/nemoclaw` release notes — cross-checked against three independent third-party writeups)

---

## Does OpenClaw 2.0 exist? — Answered up front

**Yes, but not the way the milestone brief assumed.** "OpenClaw 2.0" is a **marketing nickname the OpenClaw team itself applied to a CalVer release**, not a semver major-version cut. There is no `2.0.0` version string anywhere in the registry or release notes.

- The official release notes page titles the release **"v2026.8.1 (AKA OpenClaw 2.0)"** — [docs.openclaw.ai/releases/2026.8.1](https://docs.openclaw.ai/releases/2026.8.1).
- The official OpenClaw blog post announcing it is explicit: *"Today we released by far the largest update in the history of OpenClaw... built by 933 contributors"* and over 16,000 merged PRs — and it names the actual version as **2026.8.1**, with "OpenClaw 2.0" as the nickname for that milestone — [openclaw.ai/blog/openclaw-2-accidentally](https://openclaw.ai/blog/openclaw-2-accidentally).
- **Independently verified on the npm registry** (`npm view openclaw versions/time --json`, run directly against `registry.npmjs.org` during this research): `openclaw@2026.8.1` was published **2026-08-31T02:45:39.923Z (Aug 31, 2026)**. The version sequence around it is pure CalVer — `2026.7.35` → `2026.8.1` → `2026.8.2` → `2026.9.1` → ... → `2026.9.6` (latest as of this research, published 2026-09-23). There is no `2.x.x` semver line.
- The official versioning-policy doc confirms the scheme did **not** change: *"Monthly Gateway extended-stable release version: `YYYY.M.PATCH`, with `PATCH >= 33`... Daily/regular final release version: `YYYY.M.PATCH`, with `PATCH < 33`... `PATCH` is a sequential monthly release-train number, not a calendar day"* — [docs.openclaw.ai/reference/RELEASING](https://docs.openclaw.ai/reference/RELEASING). The npm version list corroborates this exactly (`2026.6.33/34/35`, `2026.7.33/34/35` are the extended-stable builds each month).
- A third-party explainer (`openclawlaunch.com`) goes further and says flatly *"no, and there never will be"* a semver 2.0 — technically consistent with the primary sources' facts (no semver major exists) even though the "2.0" **label** is real and official.

**What this means for the milestone:** "cutting over to OpenClaw 2.0" = **cutting over to the CalVer line starting at `2026.8.1` and later** (currently `2026.9.6`, published 2026-09-23), not to a distinct SDK major version. **Recommend renaming the milestone's mental model** from "target semver 2.0" to **"target the `>=2026.8.1` generation"** — the breaking changes are real (see below) but they are dated to the 2026.8.1 cut, not gated by a major-version check the code can test for (there is no `major===2` to branch on).

**Sources:**
- [Release notes index](https://docs.openclaw.ai/releases) — HIGH (official)
- [v2026.8.1 (AKA OpenClaw 2.0) release notes](https://docs.openclaw.ai/releases/2026.8.1) — HIGH (official)
- [OpenClaw 2.0, Accidentally (official blog)](https://openclaw.ai/blog/openclaw-2-accidentally) — HIGH (official)
- [Release policy / RELEASING.md](https://docs.openclaw.ai/reference/RELEASING) — HIGH (official)
- npm registry, queried directly (`npm view openclaw versions/time/dist-tags --json`) — HIGH (primary, independently reproducible)
- [Is There an OpenClaw 2.0? — openclawlaunch.com](https://openclawlaunch.com/guides/openclaw-2-0) — MEDIUM (third-party, but directionally corroborates primary sources)
- [OpenClaw 2.0: What's New, What Breaks, What It Signals — CellCog](https://cellcog.ai/blog/openclaw-2-0/) — MEDIUM (third-party)
- [What Changed in OpenClaw 2.0 — DigitalApplied](https://www.digitalapplied.com/blog/what-changed-in-openclaw-2-0) — MEDIUM (third-party, used only for corroboration)

---

## Recommended Stack

### Core runtime target

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| `openclaw` (npm) | `>=2026.8.1`, tested current-latest `2026.9.6` (published 2026-09-23) | The gateway/CLI runtime the skill and plugins run against | This is the actual "2.0" cut per official release notes; `2026.9.6` is `latest` on npm as of this research (`npm view openclaw dist-tags` → `{"latest":"2026.9.6","beta":"2026.9.6","extended-stable":"2026.7.35"}`) |
| Node.js | `>=24.16.0 <25` or `>=26.1.0` (26 recommended) | Runtime for `openclaw` itself and for building the TypeScript plugins | Declared in `openclaw`'s own `package.json` `engines` field (verified via `npm view openclaw engines --json`); matches third-party install guides |
| `openclaw.plugin.json` manifest file | new, mandatory, per-plugin | Static plugin discovery/validation manifest OpenClaw reads **before** loading plugin code | *"Every native OpenClaw plugin must ship `openclaw.plugin.json` in the plugin root... A missing or invalid manifest blocks config validation and is treated as a plugin error."* — [docs.openclaw.ai/plugins/manifest](https://docs.openclaw.ai/plugins/manifest). **This is new and required — neither `plugin/` nor `plugin-nemoclaw/` currently ships one; today they only embed `{"openclaw":{"extensions":["./dist/index.js"]}}` in `package.json`, which the 2.0 docs say is not sufficient by itself.** This is the single concrete must-add artifact this milestone needs. |
| `openclaw/plugin-sdk/plugin-entry` (subpath import) | tracks host `openclaw` version | `definePluginEntry()` helper both existing plugins already use | **Good news:** both `plugin/src/index.ts` and `plugin-nemoclaw/src/index.ts` already `import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry"` — the exact *focused subpath* pattern 2.0 requires, confirmed live in [docs.openclaw.ai/plugins/sdk-entrypoints/define-plugin-entry](https://docs.openclaw.ai/plugins/sdk-entrypoints/define-plugin-entry) and [docs.openclaw.ai/plugins/sdk-overview/imports](https://docs.openclaw.ai/plugins/sdk-overview/imports). Neither plugin imports the now-removed broad surfaces (`openclaw/plugin-sdk` root, `openclaw/plugin-sdk/compat`, `openclaw/extension-api`) that the migration guide says "no longer load." |
| NemoClaw CLI | pin `>= v0.0.128` (2026-09-22 release) | Sandbox/OpenShell runtime host-side controller | This is the **first confirmed release** whose managed image pins an OpenClaw 2.0-generation build: *"Managed images now include OpenClaw 2026.9.1 and Hermes 0.21.3"* — [docs.nvidia.com .../release-notes/2026/9/22](https://docs.nvidia.com/nemoclaw/user-guide/openclaw/release-notes/2026/9/22). See the hard-gate note below — this was **not** true a few weeks earlier. |

### Supporting libraries (plugin build, unchanged)

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `typescript` | `^5.0.0` (existing devDependency) | Compile the plugin `dist/` | No forced bump — `openclaw` itself ships TS `6.0.3` internally but that's an implementation detail of the host, not a peer constraint on plugin authors |
| `@types/node` | `^25.9.1` (existing) | Types for the Node runtime | Fine as-is; no OpenClaw-driven change found |
| `@openclaw/plugin-inspector` (npm) | latest `0.3.26` (Node >=22) | **New recommendation** — offline, credential-free CI check of plugin compatibility | Exactly matches the milestone's "version canaries" goal: *"the offline compatibility checker for OpenClaw plugin packages... answers whether OpenClaw can discover package metadata and `openclaw.plugin.json` manifest, which hooks, registration calls, manifest contracts, and SDK imports the plugin uses"* — [github.com/openclaw/plugin-inspector](https://github.com/openclaw/plugin-inspector), confirmed on npm. Run via `pnpm dlx @openclaw/plugin-inspector inspect --no-openclaw` in CI to catch a future hook-contract break *before* it reaches a live host — directly answers this milestone's "Version canaries" target feature. |

### Development tools

| Tool | Purpose | Notes |
|------|---------|-------|
| `openclaw plugins inspect <id>` | Live, on-host verification that a plugin loaded and which hooks registered | Already used by `post-install.sh` / `post-install-nemoclaw.sh` Gate B; unchanged mechanism in 2.0, still the right live gate to keep |
| `openclaw doctor --fix` | Post-upgrade repair (session storage migration, stale plugin cleanup, model-route renames) | New in the 2.0 cycle per third-party writeup; worth running once after cutting a test host to `2026.8.1+` before debugging anything else — [digitalapplied.com](https://www.digitalapplied.com/blog/what-changed-in-openclaw-2-0) (MEDIUM confidence, unofficial) |
| `openclaw --version` | Runtime version string for gating | Confirmed to exist as the standard way to check CLI availability/version, but **the exact stdout format is UNVERIFIED** — no doc snippet surfaced the literal output string. Confirm on a live host before wiring a strict parser (see Gaps below). |

## Installation

```bash
# Standalone host — npm (what this project already documents)
npm install -g openclaw@latest --allow-scripts=openclaw
openclaw --version   # confirm >= 2026.8.1 before proceeding

# Pin explicitly instead of floating "latest" for reproducible CI/test hosts
npm install -g openclaw@2026.8.1

# Plugin devDependency change (both plugin/ and plugin-nemoclaw/):
#   peerDependencies.openclaw currently ">=2026.6.1" — tighten to reflect
#   the new support posture (2.0-only, drop CalVer 2026.x < 2026.8.1):
#     "peerDependencies": { "openclaw": ">=2026.8.1" }

# New required file, one per plugin root (plugin/openclaw.plugin.json,
# plugin-nemoclaw/openclaw.plugin.json) — minimal shape confirmed by docs:
cat > plugin/openclaw.plugin.json <<'EOF'
{
  "id": "revenium-marker-gate",
  "configSchema": { "type": "object", "additionalProperties": false, "properties": {} }
}
EOF

# CI compatibility canary (new — answers the milestone's "version canaries" goal)
pnpm dlx @openclaw/plugin-inspector inspect --no-openclaw

# NemoClaw CLI (host-side) — the only confirmed public installer
curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
# Pin explicitly to the first 2.0-generation-qualified build:
NEMOCLAW_INSTALL_TAG=v0.0.128 curl -fsSL https://www.nvidia.com/nemoclaw.sh | bash
```

**Do NOT `npm install -g nemoclaw`** — the `nemoclaw` name on the public npm registry (`0.1.0`, published 2026-03-15 by an unrelated maintainer) is **not** NVIDIA's NemoClaw CLI. Verified directly via `npm view nemoclaw`; it has no relationship to `docs.nvidia.com/nemoclaw`. This is exactly the kind of install-path landmine the v1.4.1 post-ship hardening session exists to prevent — flag it in the install docs.

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|--------------------------|
| Pin plugin `peerDependencies.openclaw` to `>=2026.8.1` | Pin to an exact patch (`2026.9.6`) | Only if the roadmap wants byte-for-byte reproducible CI; floating `>=2026.8.1` matches the project's existing style (current peer is `>=2026.6.1`) and the "2.0-only, not dual-support" posture without over-constraining future patch releases |
| Target the `latest`/regular release train | Target `extended-stable` (`npm dist-tag extended-stable` = `2026.7.35` as of 2026-09-23) | **Do not** target `extended-stable` for this milestone — it has **not yet cut over past CalVer 2026.7.x**, i.e. the "boring, long-lived" channel is still pre-2.0. If the deploy story needs an extended-stable pin later, that's a *separate*, currently-blocked dependency — track it, don't assume it. |
| Rebuild `dist/` against 2.0 and re-verify hooks live | Assume the existing committed `dist/` still loads untouched | The import surface is already 2.0-compliant (see above), but the **manifest requirement is new and current `dist/`-shipping plugins will fail without `openclaw.plugin.json`** — a rebuild + manifest-add + live `plugins inspect` re-verification is mandatory, not optional |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|--------------|
| `openclaw/plugin-sdk` (bare/root import) | Migration guide: *"Plugins importing the removed root, compat, or extension surfaces no longer load."* Not used by this project's plugins today — keep it that way. | `openclaw/plugin-sdk/plugin-entry` (already in use) and other focused subpaths (`openclaw/plugin-sdk/channel-core`, etc., as needed) |
| `openclaw/plugin-sdk/compat`, `openclaw/extension-api` | Same removal-gate language as above | Focused subpath imports per [docs.openclaw.ai/plugins/sdk-overview/imports](https://docs.openclaw.ai/plugins/sdk-overview/imports) |
| `api.registerEmbeddedExtensionFactory()` | Deprecated for plugins authored after **OpenClaw 2026.4.25**; replaced by middleware + manifest declaration | `contracts.agentToolResultMiddleware` + explicit middleware registration (not used by this project's plugins currently — confirm during rebuild it wasn't picked up) |
| `npm install -g nemoclaw` | Wrong package — unrelated 0.1.0 squat, not NVIDIA's tool (verified on registry) | `curl -fsSL https://www.nvidia.com/nemoclaw.sh \| bash` per [docs.nvidia.com quickstart](https://docs.nvidia.com/nemoclaw/user-guide/openclaw/get-started/quickstart) |
| Assuming "2.0" is a semver gate you can branch code on | There is no `major===2`; it is a CalVer date cut (`>=2026.8.1`) | Gate on the CalVer version string / `openclaw --version` output (exact format still needs live confirmation — see Gaps) or on a live capability probe (`openclaw plugins inspect` succeeding, `openclaw.plugin.json` being accepted) |

## Stack Patterns by Variant

**If standalone install path (Docker/macOS/Linux host, no NemoClaw):**
- Safe to cut straight to `openclaw>=2026.8.1` today — confirmed shipping and stable on npm/Homebrew since 2026-08-31.
- Add `openclaw.plugin.json`, rebuild `dist/`, re-verify via `openclaw plugins inspect revenium-marker-gate` before touching anything else.

**If NemoClaw/OpenShell sandbox install path:**
- **Hard gate:** as recently as 2026-08-31, NVIDIA's own migration epic (Issue #10694, "Qualify and migrate managed OpenClaw from 2026.7.1 to OpenClaw 2.0 (2026.8.1)") was **open**, with the managed image still pinned to `2026.7.1`, and listed real blockers: config-schema incompatibilities (`compaction.maxHistoryShare`, `gateway.controlUi.allowInsecureAuth` rejected by the 2.0 validator), a plugin-contract change requiring explicit capability declarations for `before_prompt_build`, the SQLite session-state migration, and a new `OPENCLAW_SUPERVISOR_MODE=external` requirement.
- **That gate cleared some time between 2026-08-31 and 2026-09-22**: NemoClaw's `v0.0.128` release (2026-09-22 — the day before this research) states the managed image "now include[s] OpenClaw 2026.9.1" — i.e. the 2.0-generation line. This is **extremely recent** and effectively concurrent with this research; treat it as freshly-qualified, not battle-tested.
- **Recommendation:** the NemoClaw path is unblocked as of today but pin to the exact qualified build (`NEMOCLAW_INSTALL_TAG=v0.0.128` or newer) and budget real live-validation time on a fresh sandbox — do not assume last month's spike findings (host 34.224.27.67) reflect the new managed image's config schema, plugin-contract permissions, or SQLite session layout.

## Version Compatibility

| Package A | Compatible With | Notes |
|-----------|------------------|-------|
| `revenium-marker-gate` plugin (`peerDependencies.openclaw`) | Currently `>=2026.6.1` | **Update to `>=2026.8.1`** to match the "2.0 only" support posture and stop silently claiming CalVer 2026.6.x/2026.7.x compatibility this milestone is dropping |
| `revenium-enforcement` (NemoClaw plugin, same peer today) | Currently `>=2026.6.1` | Same update; additionally must be re-verified against the NemoClaw `v0.0.128`-managed image's plugin-contract capability-declaration requirement flagged in Issue #10694 |
| NemoClaw CLI | `>= v0.0.128` (2026-09-22) for OpenClaw-2.0-generation managed images | Earlier NemoClaw builds (through at least late August) still provisioned OpenClaw `2026.7.1` sandboxes — those are **not** "2.0" despite running current NemoClaw |
| `openclaw` `extended-stable` dist-tag | `2026.7.35` as of 2026-09-23 | **Not** yet on the 2.0 line — do not route any part of this milestone's install docs through the extended-stable channel and expect 2.0 behavior |
| `revenium` CLI | No change identified | Nothing found in the 2.0 release notes, plugin-SDK migration guide, or NemoClaw migration issue that touches how external binaries are invoked, PATH-resolved, or sandboxed. Plugins are explicitly still documented as running **in-process with the Gateway, trusted code** — unchanged from pre-2.0. The new team-scoped Secret Store (write-only "protected secrets," Vault/1Password references) is a new *optional* credential-storage surface inside OpenClaw itself; it does not require any change to how the skill/plugin shells out to `revenium` or reads `~/.config/revenium/config.yaml`. Out of scope for this milestone unless a future one wants to migrate credential storage into it. |

## Answers to the milestone's specific questions

1. **Does 2.0 exist?** Yes — as a marketing name for CalVer `v2026.8.1` (2026-08-31) and its successors (currently `2026.9.6`, 2026-09-23). No semver major exists or is planned; see top section and sources.
2. **Install/distribution channels vs CalVer:** Unchanged surface — npm (`npm install -g openclaw@latest`), Homebrew cask, the `curl https://openclaw.ai/install.sh | bash` installer, Docker/Podman/K8s, and ClawHub for skills. What changed is *content*, not channel: `openclaw doctor --fix` now exists for post-upgrade repair, and `openclaw update --channel dev|stable` remains the update-channel toggle. No new distribution channel was introduced by the 2.0 cut. [docs.openclaw.ai/install](https://docs.openclaw.ai/install), [docs.openclaw.ai/clawhub](https://docs.openclaw.ai/clawhub).
3. **Plugin SDK / TypeScript types version, rebuild required?** There is no separately-versioned `@openclaw/plugin-sdk` npm package (confirmed 404 on the registry) — the SDK is subpath-exported from the `openclaw` package itself (`openclaw/plugin-sdk/*`), versioned in lockstep with the host. Both existing plugins already use the compliant focused-import style (`openclaw/plugin-sdk/plugin-entry`) and use `api: any` (no compile-time type dependency on OpenClaw internals), so the import surface itself is not a blocker. **However, a rebuild IS required** because the new mandatory `openclaw.plugin.json` manifest file doesn't exist in either plugin today, and its absence is a hard load failure per the current docs ("blocks config validation... treated as a plugin error"). Net: not a "new SDK major," but yes — must add the manifest file, rebuild `dist/`, bump the peer range, and re-verify live via `openclaw plugins inspect`.
4. **NemoClaw support?** Confirmed as of 2026-09-22 (`v0.0.128`, managed image → OpenClaw `2026.9.1`) — but this cleared only in the last ~3 weeks, was an open migration epic with real blockers as recently as 2026-08-31, and has not been through this project's own live-validation cycle. Treat as a real but *fresh* dependency, not a settled one — budget for surprises the way v1.4.1's post-ship hardening had to.
5. **Version-detection mechanism:** `openclaw --version` exists and is the standard CLI-presence/version check, and `openclaw plugins inspect <id>` remains the live capability probe this project already relies on (Gate A/B pattern). **UNVERIFIED:** the exact stdout format of `openclaw --version` (e.g. bare `2026.9.6` vs `openclaw 2026.9.6` vs JSON) — no source surfaced the literal string. Confirm on a live 2.0 host before writing a parser; do not guess the format.
6. **`revenium` CLI changes?** None found. See Version Compatibility table above.

## Sources

- [docs.openclaw.ai/releases](https://docs.openclaw.ai/releases) — release index, confirms `2026.8.1` is not the newest build (HIGH, official)
- [docs.openclaw.ai/releases/2026.8.1](https://docs.openclaw.ai/releases/2026.8.1) — the "AKA OpenClaw 2.0" release notes (HIGH, official)
- [openclaw.ai/blog/openclaw-2-accidentally](https://openclaw.ai/blog/openclaw-2-accidentally) — official framing of the 2.0 nickname (HIGH, official)
- [docs.openclaw.ai/reference/RELEASING](https://docs.openclaw.ai/reference/RELEASING) — CalVer policy, PATCH>=33 extended-stable scheme (HIGH, official; cross-checked against npm version list)
- npm registry, queried live: `npm view openclaw versions/time/dist-tags/engines/dependencies --json` — HIGH (primary, reproducible)
- npm registry: `npm view nemoclaw` and `npm view @openclaw/plugin-inspector` — HIGH (primary, reproducible)
- [docs.openclaw.ai/plugins/manifest](https://docs.openclaw.ai/plugins/manifest) — mandatory `openclaw.plugin.json` requirement (HIGH, official)
- [docs.openclaw.ai/plugins/sdk-migration](https://docs.openclaw.ai/plugins/sdk-migration) and [.../how-to-migrate](https://docs.openclaw.ai/plugins/sdk-migration/how-to-migrate) — import-surface deprecations (HIGH, official)
- [docs.openclaw.ai/plugins/sdk-overview/imports](https://docs.openclaw.ai/plugins/sdk-overview/imports) — valid vs deprecated subpath imports (HIGH, official)
- [docs.openclaw.ai/plugins/sdk-entrypoints/define-plugin-entry](https://docs.openclaw.ai/plugins/sdk-entrypoints/define-plugin-entry) — confirms `definePluginEntry` unchanged (HIGH, official)
- [docs.openclaw.ai/plugins/hooks](https://docs.openclaw.ai/plugins/hooks) — confirms `before_agent_finalize`, `before_tool_call`, `before_prompt_build`, `agent_end` all still exist, `allowConversationAccess` unchanged (HIGH, official)
- [docs.openclaw.ai/plugins/compatibility](https://docs.openclaw.ai/plugins/compatibility) — "all plugin APIs are experimental," 3-month deprecation windows (HIGH, official, but did not resolve the specific pre-2.0-dist backward-compat question)
- [docs.openclaw.ai/install](https://docs.openclaw.ai/install), [docs.openclaw.ai/clawhub](https://docs.openclaw.ai/clawhub), [docs.openclaw.ai/cli](https://docs.openclaw.ai/cli) — install channels, ClawHub, CLI reference (HIGH, official; `--version` exact output format NOT found — UNVERIFIED)
- [github.com/NVIDIA/NemoClaw Issue #10694](https://github.com/NVIDIA/NemoClaw/issues/10694) — migration epic, open 2026-08-31, blockers enumerated (HIGH, vendor-official tracker)
- [docs.nvidia.com/nemoclaw/.../release-notes](https://docs.nvidia.com/nemoclaw/user-guide/openclaw/release-notes) and [.../2026/9/22](https://docs.nvidia.com/nemoclaw/user-guide/openclaw/release-notes/2026/9/22) — confirms `v0.0.128` (2026-09-22) manages OpenClaw `2026.9.1` (HIGH, official NVIDIA docs)
- [docs.nvidia.com/nemoclaw/.../get-started/quickstart](https://docs.nvidia.com/nemoclaw/user-guide/openclaw/get-started/quickstart) — install command, version pinning via `NEMOCLAW_INSTALL_TAG` (HIGH, official)
- [github.com/openclaw/plugin-inspector](https://github.com/openclaw/plugin-inspector) — the recommended "version canary" tool (HIGH, official OpenClaw org repo)
- [openclawlaunch.com/guides/openclaw-2-0](https://openclawlaunch.com/guides/openclaw-2-0) — "no semver 2.0" corroboration (MEDIUM, third-party)
- [cellcog.ai/blog/openclaw-2-0](https://cellcog.ai/blog/openclaw-2-0/) — general "what's new/what breaks" framing (MEDIUM, third-party)
- [digitalapplied.com/blog/what-changed-in-openclaw-2-0](https://www.digitalapplied.com/blog/what-changed-in-openclaw-2-0) — plugin/session/Secret-Store detail, `doctor --fix` (MEDIUM, third-party, used for corroboration only)
- This project's own source: `plugin/package.json`, `plugin/src/index.ts`, `plugin-nemoclaw/package.json`, `plugin-nemoclaw/src/index.ts`, `scripts/post-install.sh`, `scripts/post-install-nemoclaw.sh` — read directly to establish current-state baseline (HIGH, primary/local)

---
*Stack research for: OpenClaw 2.0 Cut-Over milestone*
*Researched: 2026-09-23*
