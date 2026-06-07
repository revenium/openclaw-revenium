---
spike: 006
name: plugin-directive-injection
type: standard
validates: "Given a custom OpenClaw plugin in the sandbox, when any agent turn runs, then a mandatory per-turn directive (guardrail check) reaches the agent context every turn"
verdict: PARTIAL
related: [005, 001]
tags: [plugin, directives, enforcement, hook, before_prompt_build]
host: "34.224.27.67 (sandbox revenium-spike)"
---

# Spike 006: Plugin Directive Injection

## What This Validates

The mechanism left open by spike 005: can an **OpenClaw plugin** inject the skill's MANDATORY
per-turn guardrail directive so it reaches the agent on **every** turn (the thing SKILL.md /
AGENTS.md / the `<nemoclaw-runtime>` preamble could not do)? This is the gate on the skill's core
enforcement value under NemoClaw.

## Research (the mechanism — confirmed to exist)

Read the live `nemoclaw` plugin source on the host (`~/.nemoclaw/source/nemoclaw/src/`):
- Plugin API (`index.ts`): `register(api)` receives an `OpenClawPluginApi` with `registerCommand`,
  `registerProvider`, `registerService`, and `api.on(hookName, handler)`.
- **`before_prompt_build` hook** returns `{ systemPrompt?, appendContext? }` (type def) — and
  `runtime-context.ts` uses `api.on("before_prompt_build", () => ({ prependContext: <text> }))` to
  prepend the `<nemoclaw-runtime>` block **to every agent turn**.
- This is exactly the seam needed, and it is **production-proven**: spike 005 saw `<nemoclaw-runtime>`
  in the turn's `finalPromptText`. So per-turn directive injection via a plugin IS achievable.
- Plugin packaging: `package.json` needs `type: module`, `main`, and **`openclaw.extensions: ["./index.js"]`**;
  manifest `openclaw.plugin.json` needs `id/name/version`, `activation.onStartup`, and a **`configSchema`**.

## How to Run

```bash
# plugin source preserved in this dir: revenium-guard/ (package.json, openclaw.plugin.json, index.js)
# index.js: export default (api) => api.on("before_prompt_build", () => ({ prependContext: "<revenium-guard>…REVENIUM_GUARD_ACTIVE…</revenium-guard>" }))
nemoclaw revenium-spike exec -- openclaw plugins install /sandbox/.openclaw/extensions/revenium-guard
nemoclaw revenium-spike exec -- openclaw plugins enable revenium-guard
nemoclaw revenium-spike recover            # restart gateway so onStartup hooks load
nemoclaw revenium-spike exec -- openclaw agent --message "What is 2+2?" --session-id t --json
# check: <revenium-guard> in finalPromptText AND reply begins with REVENIUM_GUARD_ACTIVE
```

## Investigation Trail

1. Found the seam: `before_prompt_build` → `prependContext`, used by the nemoclaw plugin (the working reference).
2. Authored a minimal `revenium-guard` plugin (pure, static — no shelling out, to pass the install-time safety scanner).
3. First install failed: `package.json missing openclaw.extensions`. Added `openclaw.extensions: ["./index.js"]`.
4. Second install failed: `plugin manifest requires configSchema` — and the bad manifest **broke the whole openclaw CLI** ("Could not start the CLI"). Added an empty `configSchema`; fixed both copies via the share mount.
5. Plugin then showed `enabled`, but a neutral turn produced no sentinel and `finalPromptText` had `<nemoclaw-runtime>` but **not** `<revenium-guard>`. `plugins inspect` warned: *"loaded without install/load-path provenance; treat as untracked local code."* → **untrusted plugins load but their hooks are inert.**
6. Did a **clean** `openclaw plugins install` (valid manifest) → provenance recorded, warning gone, `Status: loaded`, gateway restarted.
7. Now the agent turn **hung** (0-byte output, exec timed out). Disabling the plugin restored turns (`"4"`) → the hook fires when trusted but **breaks/hangs prompt-build**.
8. Suspected duplicate plugin id (source copy at `/sandbox/.openclaw/revenium-guard` + installed at `…/extensions/revenium-guard`); removed the source copy — **still hung**. So not a duplicate.
9. Could not isolate the hang cause via remote exec (the return key matches nemoclaw's `prependContext`; not a dup). Uninstalled the plugin and confirmed the sandbox is healthy again.

## Results

**Verdict: PARTIAL — the mechanism is proven to exist and be viable; a hand-authored replica did not work cleanly.**

- ✅ **Per-turn injection via a plugin is achievable** — the nemoclaw plugin's `before_prompt_build`
  → `prependContext` hook demonstrably reaches every agent turn. The skill's core enforcement CAN be
  delivered this way under NemoClaw. **This answers spike 005's open question: YES, a plugin is the path.**
- ✅ **Runtime plugin lifecycle works:** install → enable → recover; and a key security finding —
  **untrusted/hand-placed plugins load but run no hooks** (provenance gate); a clean `openclaw plugins install` is required to record trust.
- ✅ **Plugin contract captured:** `openclaw.extensions` in package.json + `configSchema` in the
  manifest are both mandatory (each omission is a hard failure, and a bad manifest can break the whole CLI).
- ❌ **The minimal hand-rolled hook did not inject cleanly:** untrusted → inert; trusted → hung the
  turn. Root cause not isolated remotely (not the return key, not a duplicate id).

## Requirements / build guidance

- **Deliver the guardrail directive via an OpenClaw plugin's `before_prompt_build` hook** — not SKILL.md/AGENTS.md.
- **Do not hand-stub the plugin.** Build it from the official scaffold (`openclaw plugins init`) and/or
  mirror the working `nemoclaw` plugin exactly (compiled ESM from TS, its `register`/`api.on` shape).
  The hand-written stub hung the turn — match the real authoring contract.
- **Install cleanly** (`openclaw plugins install <dir>`) so the hook is trusted (provenance) — a
  hand-placed plugin's hooks are inert.
- Manifest MUST include `configSchema`; package.json MUST include `openclaw.extensions`.
- Validate via the gateway/dashboard turn path, not only `openclaw agent --json` over `exec`.

## Open follow-up

Author the plugin from `openclaw plugins init` (or a TS build mirroring nemoclaw), and re-run this
test — expect `<revenium-guard>` in `finalPromptText` and the agent honoring the directive. This is
the one remaining build-time task before the enforcement path is fully proven.
