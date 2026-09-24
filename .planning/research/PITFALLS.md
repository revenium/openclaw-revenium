# Pitfalls Research

**Domain:** Major-runtime-version cut-over for a production, deeply-integrated OpenClaw agent skill (guardrail enforcement + usage metering), across two install paths (standalone OpenClaw+Docker, NemoClaw/OpenShell sandbox)
**Researched:** 2026-09-23
**Confidence:** MEDIUM-HIGH (OpenClaw 2.0's existence and headline changes are well-sourced from official docs and release notes; some finer hook-firing semantics and NemoClaw-specific 2.0 compatibility statements are thin or unverified — flagged inline)

## Does OpenClaw 2.0 exist? — CONFIRMED, with a caveat on naming

**Yes.** OpenClaw 2.0 is real. It shipped as version **v2026.8.1** on **2026-08-30/31**, and the project's own release notes and third-party coverage both refer to it interchangeably as "OpenClaw 2.0" and "v2026.8.1" — so **the CalVer scheme was not actually replaced; "2.0" is a marketing/milestone label layered onto the same `20YY.M.P` version string.** This matters directly for this milestone: there is no discrete `2.x` version track to branch logic on. Version-gating code must key off the CalVer value (`>= 2026.8.1`), not a semver-style major.

- Official release index: [Release notes · OpenClaw](https://docs.openclaw.ai/releases)
- The 2.0 release itself: [v2026.8.1 (AKA OpenClaw 2.0) · OpenClaw](https://docs.openclaw.ai/releases/2026.8.1)
- Third-party confirmation with scale ("16,977 PRs, 698 direct commits, 987 contributors"): [OpenClaw releases version 2.0 system overhaul — Agentic Ready](https://www.getreadyforagents.com/news/openclaw-2-0-system-update-release/)
- Independent analysis: [OpenClaw 2.0: What's New, What Breaks, What It Signals | CellCog](https://cellcog.ai/blog/openclaw-2-0/)
- As of this research date the current line has advanced further, to **2026.9.x** (e.g. 2026.9.1, 2026.9.4) — described as the "extended-stable line" carrying targeted fixes on top of 2.0. Do not plan against 2026.8.1 as if it were still current; verify against the latest 2026.9.x release notes at implementation time. Source: search-result synthesis citing [Release openclaw 2026.9.1 · GitHub](https://github.com/openclaw/openclaw/releases/tag/v2026.9.1) (UNVERIFIED beyond search snippet — re-fetch at Phase 1 to confirm exact current patch).

This confirmation resolves the milestone's stated "open risk" (`PROJECT.md`: "If 2.0 does not exist yet... the milestone shrinks"). It does not shrink — proceed with the milestone as scoped, but read the specific findings below before writing requirements, because they change what "port as-is" actually costs.

---

## Critical Pitfalls

### Pitfall 1: Silent hook-contract breakage with no throw, no log, no signal

**What goes wrong:**
A runtime upgrade changes what a hook receives, when it fires, or whether a plugin's `revise` return is honored — and nothing errors. The plugin installs cleanly, `openclaw plugins inspect` shows it registered, and the agent keeps responding. The only symptom is that the *behavior the hook was supposed to enforce* silently stops happening — exactly what happened on 2026.6.6 when `before_agent_finalize` revise actions began being vetoed on tool-using turns, discovered only by reading gateway logs at `/tmp/openclaw/`.

**Why it happens:** Hook contracts in a system like this are a triangle of (a) what the SDK types declare, (b) what the runtime actually dispatches, and (c) what conditions cause the runtime to silently drop or override a plugin's return value. (a) and (b)/(c) drift independently across releases, and a fail-open plugin (this project's `revenium-marker-gate` is deliberately fail-open by design, per `CR-01`) makes the drift *invisible by construction* — the whole point of fail-open is "never block the reply," which also means "never surface that enforcement quietly stopped."

**How to avoid:** Build a **version canary** — see the dedicated spec below. Do not rely on manual log-reading (how 2026.6.6 was actually caught) as the detection mechanism for 2.0; that only worked because someone happened to be debugging low attribution coverage. A canary must run unattended and fail loudly.

**Warning signs:** Metering/attribution coverage percentage drops without a corresponding code change; `verify-markers.sh` coverage stats silently regress; gateway logs show `revise` requests followed immediately by a finalized reply with no evidence the revise instruction was honored.

**Phase to address:** A dedicated early phase ("Establish 2.0 facts" per `PROJECT.md`) that builds and runs the canary *before* porting either install path, so the canary itself is validated against both the old and new runtime as a differential check.

---

#### Version canary — concrete spec (feeds the milestone's "Version canaries" requirement)

A canary is not a hermetic unit test (those pass today and passed the whole time v1.4 was silently broken). It must run **against a live OpenClaw process** on real hosts, on a cadence, and fail loudly on drift. Concretely:

**What it should assert** (per hook this project depends on):
| Hook | Assertion | How to check without reading conversation content |
|------|-----------|-----------------------------------------------------|
| `before_agent_finalize` | A `revise` return on a tool-using turn is actually honored (the finalize pass re-runs) | Register a canary plugin that returns `revise` unconditionally on a synthetic marker-tagged turn, then check that the resulting completion in the session store shows evidence of a second pass (retry count, or a sentinel string injected by the revise instruction) |
| `before_tool_call` | Fires for a synthetic tool call, including for exec routed through `tool_search_code` (the B-05 case) | Trigger one exec call per supported model in the deploy matrix; assert the hook's own counter/log incremented once per call |
| `before_prompt_build` | Injected directive text lands in the actual submitted prompt every turn (not just first turn) | Compare `promptChars` (or an equivalent measurable prompt-size delta) against a known baseline — this project already validated this exact technique live (~4599 vs ~649 baseline chars) |
| Session read path | The session/transcript source this project reads from (JSONL glob or SQLite) still exists in the shape parsers expect | Write one synthetic completion, then confirm the exact file/row the report/guardrail scripts are coded to read is present and parseable |
| `plugins inspect` / hook registration | The plugin is actually loaded and its hooks are actually registered, not just installed | Parse `openclaw plugins inspect <id>` output for the hook names, don't just check install exit code |

**How it should fail:** Non-zero exit + a machine-readable JSON report (`canary-report.json`) with one row per assertion, `pass`/`fail`/`skip`, and the raw evidence (byte counts, counts, file paths checked). It must be safe to fail-loud here — unlike the enforcement plugin, the canary's entire job is to be noisy, so it should NOT inherit the fail-open posture of `revenium-marker-gate`.

**Where it should run:** (1) as a manual/CI check runnable against a fresh install before any release is cut ("does this OpenClaw version still support what we need"), and (2) as an optional low-frequency cron-adjacent check on production hosts (e.g., once per day, not per-tick) that writes its result where `verify-markers.sh`-style tooling can be diffed over time — so a runtime auto-update in the field is caught within a day, not discovered by a customer.

**Confidence:** MEDIUM — the specific assertions are derived from this project's own documented hook usage and prior incidents (HIGH confidence those incidents happened); the general "differential canary against live process, not hermetic mocks" pattern is a well-established SRE practice, not OpenClaw-specific (labeled general).

---

### Pitfall 2: Sessions/transcripts moved to SQLite — this project's core read path may already be broken on 2.0

**What goes wrong:** OpenClaw 2.0 (v2026.8.1) "changes how sessions and transcripts are stored by moving them into SQLite," with the runtime session store now living at `~/.openclaw/agents/<agentId>/agent/openclaw-agent.sqlite` by default. This project's `report.sh` reads OpenClaw session logs directly (`PROJECT.md`: "sessions at `~/.openclaw/agents/main/sessions/*.jsonl`") to drive completion metering, task-type/job-marker correlation, and root-session resolution. If that JSONL glob is no longer where live session data lands on 2.0, the entire metering pipeline reads nothing and fails silently (or errors loudly, which would at least be better — this needs to be tested, not assumed).

Worse: this is not hypothetical. A currently **open** upstream bug (`Issue #155696`, filed against **OpenClaw 2026.9.4**) reports that for SQLite-backed sessions, the `session_end` hook payload carries no messages and its `sessionFile` field points to a JSONL that no longer exists on disk — and that at least one third-party plugin's session-end flush silently became a no-op because of exactly this assumption. This is the precise failure mode this project is at risk of if the attribution-core rewrite leans on `session_end`/JSONL access.

**Why it happens:** A major version bumped storage backend without (as of the latest observed patch) fully replacing all the read paths plugin authors relied on — the fix is tracked but still open. Teams treat "the CLI still shows my sessions" as proof the storage change doesn't affect them, without checking whether *their own code* reads the underlying files directly versus going through a supported CLI/API surface.

**How to avoid:**
- Phase 1 ("Establish the 2.0 facts"): on a real 2.0+ host, run `report.sh`'s current session-discovery logic unmodified and observe directly whether `~/.openclaw/agents/main/sessions/*.jsonl` exists, is populated, and is current. Do not infer this from docs — docs describe the intended architecture, not necessarily every compatibility shim.
- If JSONL is gone or stale, do not read the SQLite file directly (private storage engine detail, could change again) — check for and use `openclaw sessions export-trajectory` and `openclaw sessions tail` (both confirmed CLI surfaces on 2.0), or `openclaw cli/transcripts`, as the supported access layer.
- If building the code-side attribution-core rewrite against `session_end`/hook-delivered payloads, treat `Issue #155696` as a live blocker to validate against directly, not a documentation gap — reproduce it on your own target host before designing around it.
- Because this is an *open* issue as of the most recent patch, build in a runtime capability probe (does the hook payload contain messages? does `sessionFile` exist?) with a documented fallback, not a hard dependency.

**Warning signs:** `report.sh`/`guardrail-check.sh` cron ticks produce zero new completions on a 2.0 host despite the agent visibly running turns; `guardrail-status.json` goes stale; any `session_end`-hook-based code reads an empty payload or a `sessionFile` path that `stat` fails on.

**Phase to address:** Must be resolved in Phase 1 (fact-finding) before Phase 2/3 (standalone/NemoClaw porting) even start, because it determines whether the entire metering read-path needs to be rewritten, not just re-pointed.

Sources: [v2026.8.1 (AKA OpenClaw 2.0) release notes](https://docs.openclaw.ai/releases/2026.8.1), [Installation and Onboarding changes](https://docs.openclaw.ai/releases/2026.8.1/installation-and-onboarding), [SQLite maintenance and session migration · OpenClaw](https://docs.openclaw.ai/cli/doctor/sqlite-maintenance), [Sessions · OpenClaw](https://docs.openclaw.ai/cli/sessions), [Issue #155696 — session_end hook payload carries no messages and sessionFile points to a non-existent JSONL for SQLite-backed sessions](https://github.com/openclaw/openclaw/issues/155696) (open, filed against 2026.9.4). Confidence: HIGH for the storage-migration fact (official release notes, explicit quote); HIGH for the open bug (direct issue read); MEDIUM for exactly how this project's specific glob path is affected (must be verified live, not just inferred).

---

### Pitfall 3: "Works hermetically, broken on a clean host" — recurs unless the proof bar changes, not just the tests

**What goes wrong:** v1.4 was marked shipped after its hermetic Nyquist suites and even a spike-host validation passed, then a live UAT pass on a genuinely clean host found ~14 real bugs (Gate A/B probes broken against the then-current OpenClaw version, SSHFS cache-lag causing spurious marker failures, host-side CLI missing, ledger scoping wrong, etc.). Every one of those bugs existed in code that had "passed" hermetic tests. A 2.0 cut-over recreates every precondition that caused that gap: new install-time probes, new gate assertions, a host that has genuinely never run this install before.

**Why it happens:** Hermetic tests mock the environment; they encode the author's *assumptions* about the environment, and those assumptions are exactly what a runtime upgrade invalidates (new CLI flag requirements, new output strings to grep, new file locations). A test suite can be 100% green while testing the wrong assumptions with 100% internal consistency.

**How to avoid (concrete, not aspirational):**
- Adopt the same proof bar `PROJECT.md` already states for this milestone: "Live on a clean host — fresh clone → install → enforcement gates → metering → `guardrail-status.json` flowing, on a host actually running 2.0." Make this a literal exit gate for *both* install-path phases, not just a milestone-level aspiration — i.e., each phase's plan should name the specific clean-host command sequence and require its actual output pasted/logged as verification evidence, the same way v1.4.1's fixes were each tied to a live-validated command.
- Provision the 2.0-running host(s) *before* writing phase plans, not during execution — order matters. If a 2.0 host isn't stood up until deep into implementation, hermetic-only development for weeks recreates the exact gap that broke v1.4.
- Every install-time string-matching gate (Gate A/B/D patterns like `grep -Eq '(^|[[:space:]])ready([[:space:]]|$)'` or `Status: loaded`) is a version-fragile probe by construction — treat each one as a named risk item to re-verify against 2.0's actual CLI output, not assume it still matches. This project has already been burned twice by exactly this (Gate A `--agent` flag requirement change; BUILTIN tool-type enum rejection that dry-run didn't catch).
- Prefer probing the *real* CLI/API response over trusting a cached understanding of its shape — dry-run and hermetic stubs cannot catch server-side/CLI-side enum or flag changes; only a live call can.

**Warning signs:** All hermetic suites green but no phase has logged a fresh-clone, fresh-host command transcript; any gate whose pass condition is a fixed string grepped from CLI output that hasn't been re-captured against the current 2.0 patch.

**Phase to address:** Every phase that touches an install/gate script needs its own live-clean-host verification step, not a single end-of-milestone UAT phase — v1.4's mistake was treating live UAT as a final gate rather than a per-phase discipline. This milestone's "Proof bar" section already says this; the roadmap should turn it into a per-phase checklist item, not a one-time final phase.

Confidence: HIGH — this is this project's own documented history (`PROJECT.md` v1.4.1 section), corroborated by the general software-engineering pattern (labeled general) that integration/smoke tests against real dependencies catch classes of bugs unit/hermetic tests structurally cannot.

---

### Pitfall 4: Big-bang 2.0-only cut-over — failure modes of dropping CalVer support outright

**What goes wrong:** The user has explicitly chosen **2.0 only**, dropping `2026.x` (pre-2.0) support rather than dual-maintaining. The generic risks of a hard cut-over (well documented outside the OpenClaw ecosystem, labeled general) are:
- **No rollback path for users on hosts that can't upgrade** — if a production host is pinned to an older OpenClaw for reasons outside this skill's control (e.g., a managed platform hasn't rolled 2.0 out yet), the skill simply stops working there with no graceful degradation, only an install-time refusal at best or a silent runtime failure at worst.
- **Version-string drift makes "2.0 only" ambiguous to enforce** — since 2.0 is a CalVer label (`>= 2026.8.1`) not a discrete major, a naive check like `startswith("2026.")` matches both the supported and dropped versions. Any gate must check against the actual minimum CalVer, and must be re-verified against the specific patch the user runs, because "extended-stable 2026.9.x" patches are still shipping fixes that could matter (SQLite checkpoint handling, capped response sizes — per the 2026.9.1 release notes referenced in search results).
- **Silent partial failure instead of explicit refusal** — a version-gated skill that doesn't actively check the version will half-install or half-run on an unsupported host, producing confusing partial state (some gates pass, metering doesn't work) rather than a clean, actionable refusal message. This project has direct precedent for doing this right: v1.4's macOS-unsupported path returns "an explicit refusal, not a silent no-op" (NCINST-02) — the same discipline is needed for pre-2.0 hosts.

**How to avoid:**
- **Feature-detect, don't version-detect, wherever the underlying capability can be probed directly** (general best practice — e.g., web feature-detection over browser-sniffing) — for example, probe for the actual `openclaw plugins inspect` hook-registration output or the actual session-store shape rather than gating purely on the CalVer string. Version-detection is still needed as a fast first-pass refusal (cheap, avoids a slow partial install), but should not be the *only* gate; a feature probe catches the case where the version string looks new enough but the specific capability is missing (e.g., a hotfix branch, a vendor-patched host).
- Write the minimum-supported-version check once, in one shared place (this project already centralizes shared probe logic in `common.sh`/`post-install.sh`), and make the refusal message state the exact required version and a link/pointer to upgrade instructions — mirroring the macOS-refusal precedent.
- Since there is no dual-support path, the "rollback path" for this milestone is necessarily operational, not code-level: keep the last pre-2.0-compatible tagged release (`v1.4`/`v1.4.1`) installable via an explicit pinned-version ClawHub/git ref for any host that cannot upgrade OpenClaw yet, and say so in the docs, rather than pretending no rollback is needed.
- Stage the cutover: validate on one real 2.0 host end-to-end before touching the ClawHub-published artifact that other users pull — this project has already been burned by exactly this class of staleness (see Pitfall 9).

**Warning signs:** Install exits 0 on a pre-2.0 host but enforcement/metering silently doesn't work; version-gate logic string-matches on `2026.` without a numeric minimum-version comparison.

**Phase to address:** The version-gate/refusal logic belongs in the same "Establish 2.0 facts" / install-dispatcher phase that already owns platform detection (it extended `install.sh`'s NemoClaw-vs-standalone-vs-macOS dispatch in v1.4 — this is the same pattern, one more axis).

Confidence: MEDIUM-HIGH — the OpenClaw-specific facts (CalVer-as-2.0-label, current patch line) are sourced; the general cut-over risk analysis is standard practice, labeled general.

---

### Pitfall 5: Rewrite-under-migration — bundling the attribution-core rewrite with the runtime port

**What goes wrong:** The milestone's scope explicitly includes "replace agent-written markers + AGENTS.md injection with code-side classification **if and only if** 2.0's hooks support it." Doing a architecture rewrite (agent-written markers → code-side hook classification) at the same time as a runtime migration means that **when something breaks, there are two independent variables and no way to tell which one caused it** — a canonical migration anti-pattern (general software engineering knowledge, not OpenClaw-specific): if metering coverage drops after the 2.0 port, is it because 2.0 changed hook semantics, or because the new code-side classifier has a bug the old agent-written-marker approach didn't have? Every regression becomes a two-hypothesis debugging problem instead of one.

This project's own history shows exactly how expensive that ambiguity is: the "1-in-64 marked-completion baseline" bug in production took real debugging effort to trace to on-demand SKILL.md loading — and that was with only *one* moving part (marker-writing was already a known, stable mechanism; only its trigger location was in question). Two simultaneous unknowns compound.

**How to avoid — sequence to keep them separable:**
1. **Port first, rewrite second, as strictly separate phases with a green checkpoint between them.** Land the runtime-version port (both install paths green on 2.0, using the *existing* agent-written-marker architecture unchanged) as its own phase(s), fully live-validated, before starting any code-side hook rewrite.
2. **Gate the rewrite on a fact, not a hope.** The milestone already states the rewrite is conditional ("if and only if 2.0's hooks support it") — make that condition a literal artifact of the fact-finding phase: a written yes/no determination, with the specific hook(s) and their confirmed live-tested behavior cited, before any rewrite phase is planned into the roadmap. If the fact-finding phase can't confirm hook support live (not just from docs), the rewrite does not get scheduled this milestone — "port as-is and say so plainly" is the documented fallback and should be treated as a first-class, non-embarrassing outcome.
3. **If the rewrite does proceed, keep the old and new attribution paths running in parallel for a validation window** (dual-write, compare, don't switch) rather than a hard swap — this is exactly the "shadow mode" pattern this project already used for guardrail-event onset detection (mirroring the shadow loop, gated `state=='warn'`) and is directly reusable here: run the code-side classifier alongside the agent-written-marker path, diff their outputs, and only retire the old path once the diff is clean over a real usage window.
4. **Never let one phase's plan touch both the runtime-facing probe code and the attribution-logic code.** If a single PR/plan changes both "how we detect 2.0 is present" and "how markers get classified," a regression is unattributable by diff alone.

**Warning signs:** A single phase plan whose diff touches both install-gate/probe scripts and marker/classification logic; a regression discovered post-port with no way to bisect which change caused it because both landed together.

**Phase to address:** This is a roadmap-structuring concern, not a single phase — the roadmapper should split "2.0 runtime port" and "attribution-core rewrite" into non-overlapping phase groups with the port's live-validation checkpoint as an explicit dependency gate before the rewrite phase(s) are even planned in detail.

Confidence: HIGH for the general principle (widely documented refactor-vs-migration separation discipline, labeled general); HIGH for the project-specific parallel to the shadow-mode precedent (direct project history).

---

### Pitfall 6: Model-dependent hook behavior — the next B-05

**What goes wrong:** On Nemotron models, `exec` routes through `tool_search_code`, so `before_tool_call` never fires — the same plugin code behaves differently depending on which model is driving the agent, discovered only through live probing (tracked as B-05, still unresolved as of the last project update). A 2.0 migration is validated against whatever model/host combination happens to be convenient (Claude on a standalone host, say), and the NemoClaw/Nemotron path — or any other model added later — silently doesn't get the same guarantees, exactly as happened before.

OpenClaw's own hook reference is explicit that its hook catalog is "the registration API, not a promise that every runtime emits every hook" — i.e., the framework itself documents that hook-firing is not a universal guarantee across all execution paths, which directly validates that B-05-style gaps are a structural risk of the platform, not a one-off Nemotron bug.

**Why it happens:** Different model providers/execution modes route tool calls through different code paths inside the runtime (native tool-call vs. code-execution-mediated tool routing), and hook instrumentation is typically added per-path, not centrally. Testing against a single model gives 100% false confidence.

**How to avoid:**
- Maintain an explicit **model/host validation matrix** as a milestone artifact (not just prose) — at minimum: {standalone OpenClaw + a primary hosted model} × {NemoClaw/OpenShell + Nemotron}, since those are this project's two shipped paths. Every hook this project depends on (`before_agent_finalize`, `before_tool_call`, `before_prompt_build`) must be live-probed against *each* cell of that matrix as part of the version canary (Pitfall 1's spec already includes "Trigger one exec call per supported model in the deploy matrix").
- Do not treat "the docs say this hook fires" as sufficient — the hook reference itself disclaims that promise; only a live per-model probe counts as verification, matching this project's own established practice of probing live hosts rather than trusting dry-run/docs.
- Where a hook is confirmed not to fire for a given model (the B-05 case persists), document the specific compensating mechanism per model explicitly, rather than silently degrading — B-05 is documented as affecting task-type attribution but not the per-turn guardrail directive; that kind of partial-degradation note needs to be current for 2.0, not carried forward unverified from the CalVer-era finding.

**Warning signs:** A hook-dependent feature works in every test the team ran, but all those tests used one model; attribution/metering coverage differs meaningfully between the standalone-path and NemoClaw-path hosts with no known cause.

**Phase to address:** Belongs in the same fact-finding/canary phase as Pitfall 1 (the matrix check is the canary run per-model), and must be re-run as an explicit gate before each install path's phase is marked complete — not deferred to a single end-of-milestone UAT.

Sources: [Plugin hooks · OpenClaw](https://docs.openclaw.ai/plugins/hooks) ("The catalog is the registration API, not a promise that every runtime emits every hook" — direct quote); project history for B-05 (`PROJECT.md`). Confidence: HIGH.

---

### Pitfall 7: Sandbox/container-specific traps for the NemoClaw/OpenShell path

**What goes wrong — several distinct traps, each with project-specific precedent:**

1. **Mount cache lag causing spurious failures.** SSHFS-mounted `guardrail-status.json`/marker reads can appear stale or missing due to client-side cache lag, not an actual failure — this project already hit this (Gate D marker check had to be changed from abort to warn-not-abort specifically for SSHFS cache lag). A 2.0 port that touches any of the mount-dependent gates risks reintroducing a hard-abort where a warn-and-continue is correct, if the fix isn't explicitly re-carried into new/changed code.
2. **Egress policy drift.** NemoClaw/OpenShell sandboxes are governed by declarative network policy (egress presets like `revenium-policy.yaml`); if 2.0 changes what hosts/endpoints the OpenClaw runtime itself needs to reach (telemetry, model routing, plugin registry checks), an unchanged egress policy will silently block those calls with a proxy-block signature (HTTP 000) this project already has classification logic for — but that logic must be re-validated against whatever *new* endpoints 2.0 introduces, not assumed unchanged.
3. **CA bundle / TLS drift.** Sandboxed environments with custom egress proxies are a common place for new SDK/CLI HTTPS calls to fail on certificate trust if the sandbox's CA bundle isn't updated for new intermediate certs a 2.0-era CLI might use (general container-networking pitfall, labeled general — no OpenClaw-2.0-specific evidence found for this; treat as a smoke-test item, not a known issue).
4. **Binary/version skew between host and sandbox.** The 2026.9.1-era NemoClaw release notes state that "OpenClaw and Hermes now own their native gateway processes, plugins, packages, child processes, hooks, and background work after onboarding" — a real ownership-boundary shift versus earlier NemoClaw versions where NemoClaw itself may have mediated more of this. This changes where version-mismatch bugs can originate: if the host-side `revenium` CLI or install scripts assume NemoClaw controls plugin lifecycle and 2.0-era NemoClaw has handed that back to OpenClaw natively, install/gate logic written against the old ownership model may check the wrong process or the wrong config surface. Verify this ownership boundary live before porting `post-install-nemoclaw.sh`'s gates.
5. **Device-authentication bypass retirement.** OpenClaw 2026.9.1 "retired device authentication bypass," and NemoClaw correspondingly "does not emit a device-auth bypass key" — any install/pairing logic that relied on that bypass path (even indirectly, e.g., assuming a headless pairing shortcut) needs re-verification on 2.0-era hosts.
6. **Node runtime floor bump.** 2.0 requires Node 24.16+/26.x (26.1+), explicitly warning to upgrade Node *before* OpenClaw "to prevent SQLite text truncation." A NemoClaw sandbox image pinned to an older Node (common in locked-down sandbox base images) will fail in a way that looks like an OpenClaw bug but is actually a Node-floor violation — check the sandbox's Node version as an explicit preflight, separate from the OpenClaw version check.

**How to avoid:** Re-run every NemoClaw-path preflight/gate against a genuinely 2.0-provisioned sandbox from a fresh `nemoclaw` provision (not a patched existing sandbox — see Pitfall 9), and treat each of the six traps above as a named preflight check with its own pass/fail line in the canary report, not folded into a single generic "sandbox healthy" check.

**Warning signs:** Gate D-style marker checks abort intermittently; egress-policy-classified HTTP 000 errors on calls that used to succeed; install scripts reference `nemoclaw exec`/lifecycle assumptions that no longer match the 2026.9.x ownership model; SQLite-adjacent truncation errors traceable to sandbox Node version.

**Phase to address:** The NemoClaw/OpenShell-path phase, gated on a fresh (not reused) 2.0-provisioned sandbox — do not validate against the already-running `revenium-spike` sandbox left over from v1.4 spikes, since that sandbox's OpenClaw/Node/NemoClaw versions are exactly the kind of state that needs to be re-provisioned clean.

Sources: [NemoClaw v0.0.127 release notes / gateway-plugin-package ownership](https://docs.nvidia.com/nemoclaw/user-guide/openclaw/release-notes) region (search-derived; UNVERIFIED exact page — re-fetch specific dated release note at implementation time), device-auth-bypass retirement (search-result synthesis, UNVERIFIED primary source — re-confirm against NemoClaw 2026.9.x release notes directly), Node floor (WebSearch synthesis of [v2026.8.1 release notes](https://docs.openclaw.ai/releases/2026.8.1) — re-verify exact Node version numbers directly against the page at implementation time, as they were reported via search snippet, not a direct fetch quote). SSHFS-cache-lag and egress-preset facts are HIGH confidence (this project's own documented history).

---

### Pitfall 8: Plugin SDK deprecated import subpaths break the `dist/` build silently until compile time

**What goes wrong:** 2.0 removes/deprecates several plugin-sdk subpaths entirely: `openclaw/plugin-sdk`, `openclaw/plugin-sdk/compat`, `openclaw/plugin-sdk/infra-runtime`, and `openclaw/extension-api` are called out as removed or slated for removal, with a hard deadline of **September 1, 2026** for external plugin authors to move off five legacy subpath imports. This project's `revenium-marker-gate` is "TypeScript + committed pre-built `dist/`" — a committed build artifact. If the source imports any of the deprecated subpaths, the *committed* `dist/` may still run fine against 2.0 for a while (compatibility adapter + deprecation window are documented), then stop working once the compatibility shim is actually removed, with no local build step to catch it because nobody rebuilds a committed `dist/` on every OpenClaw release.

**How to avoid:**
- Audit `revenium-marker-gate`'s source imports against the subpath list in the [Plugin SDK migration guide](https://docs.openclaw.ai/plugins/sdk-migration) as a first-pass, cheap check in the fact-finding phase.
- Do not treat "the committed `dist/` still works today" as proof of 2.0-readiness — rebuild from source against the 2.0-era SDK and diff, since the compatibility adapter window is explicitly time-bounded (already past the Sept 1 deadline as of this research date — verify whether the deprecated subpaths are now hard-removed or still shimmed on the current 2026.9.x line).
- Treat this as a forcing function to also rebuild-and-recommit `dist/` as a standard step of this milestone (ties directly into Pitfall 9's stale-artifact problem) rather than assuming the existing committed build is a safe base to extend.

**Warning signs:** `openclaw plugins install` succeeds but the plugin throws at load/hook-dispatch time referencing a missing module from `openclaw/plugin-sdk/*`; `plugins inspect` shows the plugin registered with zero hooks actually bound.

**Phase to address:** Standalone-path porting phase, as a precondition before any TypeScript source changes — rebuild `dist/` from source against 2.0's SDK early, even before deciding on the attribution-core rewrite, purely to confirm the *existing* plugin still compiles clean.

Source: [Plugin SDK migration · OpenClaw](https://docs.openclaw.ai/plugins/sdk-migration) (deprecated subpaths, removal of `openclaw/plugin-sdk` and `openclaw/extension-api`, "compatibility adapter, diagnostics, docs, and a deprecation window" language via [breaking-changes search synthesis](https://docs.openclaw.ai/plugins/hooks) sources); September 1, 2026 deadline per WebSearch synthesis (MEDIUM confidence — re-verify exact date directly against the migration guide's removal-timeline subpage at implementation time, as it was not directly fetched).

---

### Pitfall 9: Stale ClawHub-published artifact vs. repo drift — this has already happened once

**What goes wrong:** Both prior test hosts for this project were patched via scp/git directly rather than through the published install path, and the ClawHub-published install was confirmed stale/diverged from the repo (even with `AGENTS.md` present, the end-of-turn marker gate was found dropped on the ClawHub-published v0.5.8 install on a second test host). A 2.0 cut-over is exactly the kind of change that must reach real users through the published artifact — if the ClawHub package isn't rebuilt and republished as part of this milestone's release phase, every fix validated on a hand-patched spike host is invisible to anyone who actually installs from ClawHub.

**How to avoid:**
- Treat "rebuild the NemoClaw plugin" and "cut a ClawHub release" (both already named in this milestone's target features) as the *last* phase, gated on all prior phases' live validation — and explicitly verify post-publish by installing fresh from ClawHub on a clean host, the same way NCDEPLOY validation worked in v1.4 (`openclaw skills list` independently confirming `✓ ready` after a real install, not a patched one).
- Add a lightweight drift check as a recurring practice (not just at ship time): diff the currently-published ClawHub package version/hash against the repo's tagged release before calling any milestone phase done, so drift is caught immediately rather than discovered on a second test host weeks later.
- Do not consider any test-host validation during this milestone sufficient proof that the *distribution channel* works — spike/scp-patched hosts validate the code; only a ClawHub install validates the release pipeline, and those are different failure surfaces.

**Warning signs:** A feature works on the hand-maintained spike host (34.224.27.67 / revenium-spike) but a fresh ClawHub install on a different host doesn't have it; `ClawHub`-installed version number doesn't match `git describe` on the tag that was supposed to ship.

**Phase to address:** The final "ClawHub release" phase this milestone already names, with an explicit post-publish clean-install verification step as its own exit criterion — not assumed to follow automatically from the code being merged.

Confidence: HIGH — direct project history (`MEMORY.md`: "ClawHub-published install v0.5.8... even with AGENTS.md present the end-of-turn marker gate is dropped").

---

## Technical Debt Patterns

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|-----------------|------------------|
| Keep fail-open enforcement plugin posture unexamined during the port | No behavior-change risk to the enforcement guarantee itself | Fail-open silently masks exactly the kind of contract breakage this migration is trying to get ahead of (Pitfall 1) | Acceptable short-term only if the version canary (which is explicitly NOT fail-open) is shipped alongside it in the same phase |
| Grep-matching CLI output strings for gate pass/fail (`Status: loaded`, `✓ ready`) | Fast, simple, matches this project's existing style | Every OpenClaw release is a chance to silently change the exact string, as already happened with Gate A's `--agent` flag | Never acceptable without a companion structured (`--json`) check where the CLI supports one — check whether 2.0's CLI surfaces gained `--json` flags for these gates and prefer them |
| Porting attribution-core "as-is" without confirming 2.0 hook support, just to hit a deadline | Ships something this milestone | Locks in another multi-milestone migration debt if 2.0 genuinely does support better hooks and nobody circles back | Acceptable if — and only if — the fact-finding phase's yes/no determination (Pitfall 5) is documented and the decision to defer is explicit, not silent |
| Reusing the existing `revenium-spike` sandbox for 2.0 validation instead of fresh-provisioning | Saves setup time | Carries forward unknown pre-2.0 sandbox state, undermining the entire "clean host" proof bar | Never acceptable for the final proof-bar validation; fine only for early exploratory probing |

## Integration Gotchas

| Integration | Common Mistake | Correct Approach |
|-------------|------------------|-------------------|
| OpenClaw session/transcript store | Reading the SQLite file directly, or assuming the old JSONL glob still populates | Use the supported CLI surfaces (`openclaw sessions export-trajectory`, `openclaw sessions tail`) or confirmed hook payload fields; verify live before coding against either |
| `before_agent_finalize` revise | Assuming a `revise` return is always honored on tool-using turns | Treat revise-honoring as a canary-verified fact per model/host, not an SDK-type guarantee — upstream issues (#128314, #140743-area fixes) show this is still an active area of runtime bugs even within 2.0 |
| Plugin SDK imports | Extending the committed `dist/` without rebuilding from source against the current SDK | Rebuild from source against 2.0's SDK as a first step, audit for deprecated subpaths before any logic changes |
| ClawHub distribution | Validating only on hand-patched hosts, assuming publish "just works" | Explicit post-publish clean-install verification as its own gate |
| NemoClaw/OpenShell egress policy | Assuming existing egress presets cover whatever new endpoints a 2.0-era OpenClaw/NemoClaw calls | Re-derive/re-validate egress presets against a fresh 2.0 sandbox provision, watching for new HTTP 000 proxy-block signatures |

## Performance Traps

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|-----------------|
| Per-tick version canary checks | Canary itself adds network/CLI-call overhead to every cron tick | Run the canary on its own lower-frequency schedule (e.g., daily), separate from the per-minute enforcement/metering cron | Any cadence tighter than the enforcement loop's own tick — canary cost should be negligible relative to enforcement-loop cost |
| SQLite-backed session reads at high session volume | Direct file/API reads scale differently than the old JSONL append-and-tail pattern | Prefer the CLI's own trajectory/export commands (which presumably handle indexing) over ad hoc queries against the database file, especially if session volume is meaningfully higher post-2.0's multiplayer/shared-session features | Not yet measured for this project's scale; flag as an open question for the fact-finding phase rather than assumed fine |

## Security Mistakes

| Mistake | Risk | Prevention |
|---------|------|------------|
| Relying on any remnant of the retired device-authentication-bypass path for headless NemoClaw pairing | Install scripts silently fail, or worse, someone "fixes" it by re-introducing an insecure bypass workaround | Explicitly re-verify the pairing/install flow against 2.0's supported (non-bypass) device-auth path; do not carry forward any workaround that depended on the retired bypass |
| Treating the fail-open enforcement plugin's silence as "no security impact" | A silently-voided enforcement gate is a guardrail-bypass in practice, even though it's an availability design choice, not a security bug per se | Pair every fail-open enforcement mechanism with a *fail-loud* canary (Pitfall 1) so silent-bypass has a detection path even if it doesn't have a blocking path |
| Assuming CA bundles/TLS trust in the NemoClaw sandbox are unaffected by a 2.0-era CLI/SDK bump | New TLS chain requirements could cause outbound calls to fail in a way that gets "fixed" by disabling cert verification under time pressure | Treat CA-bundle currency as an explicit sandbox preflight item, never patch around a TLS failure by weakening verification |

## UX Pitfalls

| Pitfall | User Impact | Better Approach |
|---------|--------------|-------------------|
| Ambiguous version-gate refusal ("OpenClaw version not supported") without the exact required version and remediation | User can't tell whether to upgrade OpenClaw, downgrade the skill, or file a bug | Mirror the macOS-refusal precedent (NCINST-02): a specific, verbatim, testable refusal string naming the exact minimum version and where to get it |
| Silent metering gap post-cutover (no error, just missing data in Revenium) | User doesn't discover budget guardrails have quietly stopped enforcing until a budget is blown | Version canary output surfaced somewhere the operator actually looks (docs already reference `verify-markers.sh` coverage diagnostics as the pattern to extend) |

## "Looks Done But Isn't" Checklist

- [ ] **"2.0 support" claim:** Often means "installs without error on 2.0" — verify metering data actually lands in Revenium from a truly fresh, unpatched 2.0 host, not a patched spike host
- [ ] **Version canary:** Often built as a hermetic unit test that mocks hook dispatch — verify it runs against a live OpenClaw process and would have caught the 2026.6.6 revise-veto incident if it had existed then (write it as a regression test for that exact incident)
- [ ] **Attribution-core rewrite decision:** Often left implicit ("we'll see if the hooks work") — verify there's a written yes/no determination with the specific hook(s) and live evidence cited, before any rewrite code is planned
- [ ] **ClawHub release:** Often considered done once `clawhub package publish` exits 0 — verify by installing fresh from ClawHub on a clean host and confirming behavior, not just publish success
- [ ] **NemoClaw path parity:** Often validated only on the reused spike sandbox — verify against a freshly provisioned 2.0-era sandbox
- [ ] **Hard HALT validation:** Explicitly named in this milestone as never proven end-to-end even on v1.4 — verify it is proven on 2.0, not carried forward as "presumably still works"

## Recovery Strategies

| Pitfall | Recovery Cost | Recovery Steps |
|---------|-----------------|------------------|
| Silent hook-contract breakage discovered post-ship | MEDIUM | Same playbook that worked for 2026.6.6: read gateway logs (`/tmp/openclaw/` or 2.0's equivalent), identify the specific hook/condition, add a per-turn injection compensating mechanism if the structural hook can't be fixed upstream, and retroactively add a canary assertion so it can't regress silently again |
| SQLite session-read path broken (Pitfall 2) | HIGH | Requires rewriting the read layer to use supported CLI export commands instead of direct file globbing — not a config change, a real code change across `report.sh`/`guardrail-check.sh` |
| ClawHub artifact found stale post-ship (recurrence of Pitfall 9) | LOW | Rebuild and republish; this project already has the muscle memory for this exact recovery from prior incidents |
| Attribution-core rewrite shipped bundled with the runtime port and a regression appears | HIGH | Because the two changes are entangled, recovery means bisecting via a rollback of the rewrite only (if phases were kept separable per Pitfall 5) — if they weren't kept separable, recovery cost is much higher (may require reverting the whole milestone's changes) |

## Pitfall-to-Phase Mapping

| Pitfall | Prevention Phase | Verification |
|---------|-------------------|----------------|
| 1. Silent hook-contract breakage | "Establish 2.0 facts" fact-finding phase (canary built here) | Canary report shows pass on all named hooks against a live 2.0 host, and a regression test proves it would have caught the 2026.6.6 incident |
| 2. SQLite session-store break | Same fact-finding phase, before any install-path porting | Live confirmation of session read-path shape on a real 2.0 host, documented as a fact, not inferred from docs |
| 3. "Works hermetically" trap | Every phase touching install/gate scripts (not one final phase) | Each phase's plan cites a fresh-clone, fresh-host command transcript as evidence, per the milestone's stated proof bar |
| 4. Big-bang 2.0-only cutover | Install-dispatcher/version-gate phase (extends existing `install.sh` platform dispatch) | Explicit refusal message tested on a pre-2.0 host; feature-probe fallback verified, not just a version-string check |
| 5. Rewrite-under-migration entanglement | Roadmap structuring — port phases strictly before rewrite phases, with a written go/no-go gate between them | No single phase's diff touches both probe/gate code and attribution-logic code |
| 6. Model-dependent hook behavior (next B-05) | Fact-finding/canary phase, re-run per install path | Canary matrix covers every model this project ships against, including Nemotron |
| 7. NemoClaw/OpenShell sandbox traps | NemoClaw-path porting phase, on a freshly provisioned 2.0 sandbox | Each of the six named sub-traps has its own pass/fail line, not one generic "sandbox healthy" check |
| 8. Plugin SDK deprecated imports | Standalone-path porting phase, before any TypeScript logic changes | `dist/` rebuilt from source against 2.0's SDK and diffed against the committed artifact |
| 9. Stale ClawHub artifact drift | Final "ClawHub release" phase | Post-publish clean-install verification on a host that has never touched the repo directly |

## Sources

**OpenClaw 2.0 official / primary:**
- [Release notes index · OpenClaw](https://docs.openclaw.ai/releases)
- [v2026.8.1 (AKA OpenClaw 2.0) · OpenClaw](https://docs.openclaw.ai/releases/2026.8.1)
- [Installation and Onboarding · OpenClaw 2026.8.1](https://docs.openclaw.ai/releases/2026.8.1/installation-and-onboarding)
- [Skills · OpenClaw 2026.8.1](https://docs.openclaw.ai/releases/2026.8.1/skills)
- [Plugin hooks · OpenClaw](https://docs.openclaw.ai/plugins/hooks)
- [Hook reference · OpenClaw](https://docs.openclaw.ai/plugins/hooks/reference)
- [Plugin SDK migration · OpenClaw](https://docs.openclaw.ai/plugins/sdk-migration)
- [Migrate · OpenClaw CLI](https://docs.openclaw.ai/cli/migrate)
- [Sessions · OpenClaw CLI](https://docs.openclaw.ai/cli/sessions)
- [SQLite maintenance and session migration · OpenClaw](https://docs.openclaw.ai/cli/doctor/sqlite-maintenance)
- [Agent loop · OpenClaw](https://docs.openclaw.ai/concepts/agent-loop)
- [Issue #155696 — session_end hook payload carries no messages and sessionFile points to a non-existent JSONL for SQLite-backed sessions](https://github.com/openclaw/openclaw/issues/155696) (open, filed against 2026.9.4)
- [Release openclaw 2026.9.1 · GitHub](https://github.com/openclaw/openclaw/releases/tag/v2026.9.1)

**OpenClaw 2.0 third-party analysis (secondary, cross-checked against official notes above):**
- [OpenClaw 2.0: What's New, What Breaks, What It Signals | CellCog](https://cellcog.ai/blog/openclaw-2-0/)
- [OpenClaw releases version 2.0 system overhaul with runtime and security updates — Agentic Ready](https://www.getreadyforagents.com/news/openclaw-2-0-system-update-release/)

**NemoClaw/OpenShell:**
- [Release Notes | NVIDIA NemoClaw](https://docs.nvidia.com/nemoclaw/user-guide/openclaw/release-notes) (UNVERIFIED specific dated sub-pages — synthesized via search snippet; re-fetch directly at implementation time)
- [GitHub - NVIDIA/NemoClaw](https://github.com/NVIDIA/NemoClaw)

**General migration/SRE practice (explicitly labeled general, not OpenClaw-specific):**
- Canary-vs-smoke-test distinction and "many canary failures are dependency-specific" guidance: search synthesis of [Canary release vs smoke testing | Unleash](https://www.getunleash.io/blog/canary-release-vs-smoke-test) and related QASkills.sh posts
- Feature detection over version/UA detection as an industry-standard compatibility pattern: [Feature detection (web development) — Wikipedia](https://en.wikipedia.org/wiki/Feature_detection_(web_development))

**This project's own documented history (primary source, HIGH confidence — cited throughout):**
- `/Users/johndemic/Development/projects/revenium/openclaw-revenium/.planning/PROJECT.md`
- User's persistent `MEMORY.md` entries referenced in the milestone context (2026.6.6 revise veto, B-05, ClawHub staleness, Revenium tool-type enum strictness)

---
*Pitfalls research for: OpenClaw 2.0 cut-over of the Revenium guardrail/metering skill*
*Researched: 2026-09-23*
