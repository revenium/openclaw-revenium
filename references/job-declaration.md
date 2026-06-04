# Job Declaration — Operational Detail

This file holds the full operational detail for the `## JOB DECLARATION` step in `SKILL.md`. Refer here for the arc definition, trigger rules, status bar, worked examples, and the pivot-cancel rule.

## Arc Definition

A **job** is a goal-arc — a unit of work with a single overarching intent. The arc boundary, not the turn boundary, determines when to declare.

**Same arc** — same overarching goal, including follow-up fixes and corrections within that goal. Do not declare a job after "implement X" if verification is still pending; the verification is still part of the same arc.

**New arc** — a genuine topic pivot to an unrelated or substantially different goal. A new user request that does not continue the previous goal starts a new arc.

**In ambiguous cases:** ask whether the new work is a consequence of or correction to the previous goal. If yes, same arc. If no, new arc.

## Trigger (binary — no judgment calls)

Declare a job marker if ANY of these are true:

1. You completed the goal and self-verified (see SUCCESS bar below).
2. The arc has definitively failed — the goal is objectively unachievable with the approaches available in this session.
3. The user pivoted to a new goal before this arc was declared → write CANCELLED first, then begin the new arc.

Skip ONLY when ALL of the following are true:
- Your response is ≤ 2 sentences.
- No arc was in progress.

There is no "borderline / when in doubt skip" path. When in doubt: write CANCELLED (see uncertainty-bias rule under Status Bar).

## Status Bar

### `SUCCESS`

Positive, checkable evidence established in the session:
- Tests ran and passed.
- Build completed green.
- The question was fully answered and the answer is correct.

"Made the change but could not verify" = **CANCELLED**, not SUCCESS. No user sign-off is required for SUCCESS — self-verification is sufficient.

### `FAILED`

Definitive negative terminal state:
- The fix did not fix the problem after exhausting available approaches.
- The build cannot pass given constraints in this session.
- The goal is objectively unachievable without information or access not available here.

FAILED is **narrow** — it requires a definitive conclusion, not just difficulty. If there is uncertainty about whether the goal is truly unreachable, use CANCELLED.

Include `--failure-reason` with a brief plain-text cause (one sentence). See Failure Reason section below.

### `CANCELLED`

Catch-all and **uncertainty-bias default**.

Use CANCELLED when:
- You made a change but could not verify it.
- The arc was interrupted before completion (user pivot, session end, budget halt).
- There is any ambiguity about whether the goal succeeded or definitively failed.
- You are unsure which status to use.

**When in doubt: CANCELLED.**

## Failure Reason

The `--failure-reason` flag is **FAILED-only** — do not pass it for SUCCESS or CANCELLED markers. It must not be present in those records at all.

Provide a brief plain-text cause: what specifically prevented success. One sentence is enough.

Correct:
```
--failure-reason "upstream library bug blocks CI; no workaround after 3 attempts"
```

Incorrect (too vague):
```
--failure-reason "it failed"
```

Incorrect (applied to CANCELLED):
```
--status "CANCELLED" --failure-reason "couldn't verify"   # WRONG: omit --failure-reason
```

## Pivot-Cancel Rule

When the user pivots to a new goal before the current arc was declared, the agent **must** write a CANCELLED job marker for the abandoned arc first, then treat the new request as a fresh arc.

This prevents attribution leakage: without the CANCELLED marker, the previous arc's work would be attributed to the next job. The pivot-cancel rule closes the arc cleanly before opening a new one.

**Order:**
1. Write `CANCELLED` marker for the abandoned arc.
2. Begin work on the new arc.
3. At the new arc's boundary, write its own marker with the appropriate status.

See Worked Example 4 for the exact command sequence.

## Granularity Floor

Aim for at least one job declaration per session. This is a **soft guideline only** — there is no hard enforcement (the architecture has no session-end hook to guarantee it).

A session with no clear arc completion (e.g., a pure research session that did not conclude) may legitimately produce zero job markers. Do not force a declaration if no arc actually concluded.

## Worked Examples

### Example 1 — SUCCESS (tests ran and passed)

The agent implemented a new pagination endpoint. All tests passed.

```bash
bash ~/.openclaw/skills/revenium/scripts/write-job-marker.sh \
  --job-id "add-pagination-endpoint-3b1e" \
  --job-name "Add pagination to /api/users endpoint" \
  --job-type "feature_development" \
  --status "SUCCESS"
```

Expected output: `job marker written: <path>`

### Example 2 — CANCELLED (change made, not verified)

The agent fixed a null pointer in the payment flow but did not run the tests. "Made the change but could not verify" = CANCELLED, not SUCCESS.

```bash
bash ~/.openclaw/skills/revenium/scripts/write-job-marker.sh \
  --job-id "fix-null-pointer-2c4d" \
  --job-name "Fix null pointer in payment flow" \
  --job-type "bug_fix" \
  --status "CANCELLED"
```

No `--failure-reason` — CANCELLED markers never carry a failure reason.

### Example 3 — FAILED (definitive negative terminal state)

The agent exhausted all available approaches to fix the CI pipeline blocker. The upstream library bug cannot be worked around in this session.

```bash
bash ~/.openclaw/skills/revenium/scripts/write-job-marker.sh \
  --job-id "fix-ci-upstream-blocker-9f2a" \
  --job-name "Fix CI pipeline upstream blocker" \
  --job-type "debugging" \
  --status "FAILED" \
  --failure-reason "upstream library bug blocks CI; no workaround after 3 attempts"
```

### Example 4 — Pivot-Cancel Sequence

The user was mid-way through a refactoring arc and pivoted to drafting a release announcement. The agent first closes the abandoned arc, then begins the new one.

```bash
# Step 1: close the abandoned refactoring arc
bash ~/.openclaw/skills/revenium/scripts/write-job-marker.sh \
  --job-id "refactor-auth-7a3b" \
  --job-name "Refactor auth module" \
  --job-type "refactoring" \
  --status "CANCELLED"

# Step 2: begin work on the release announcement (new arc, declared when that arc concludes)
```

The new arc (release announcement) gets its own job marker with its own `--job-id` when it concludes.

## Minting an `agentic_job_id`

The `agentic_job_id` must be minted by the agent at the time of declaration. Format: a short kebab-case goal slug plus a 4-character hex entropy suffix.

```
<kebab-case-goal-description>-<4hex>
```

Examples:
- `add-pagination-endpoint-3b1e`
- `fix-null-pointer-2c4d`
- `fix-ci-upstream-blocker-9f2a`
- `refactor-auth-7a3b`

The slug should be concise (3–6 words), lowercase, hyphen-separated, and describe the goal. The 4-hex suffix is entropy you generate to make the ID unique within a session (pick 4 random hex characters).

The agent mints and owns this ID — no external system generates it.

## Confirmation and Error Handling

- **`job marker written: <path>`** — the marker was appended successfully.
- **Non-zero exit or no `job marker written:` output** — protocol error. Log the error. **Do not block your response.** The fail-loud-but-don't-block contract applies: an unknown `job_type`, invalid `status`, or missing mandatory flag will cause a non-zero exit — log it, note it in your response, and continue.
