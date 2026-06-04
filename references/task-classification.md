# Task Classification — Operational Detail

This file holds the full operational detail for the `## TASK CLASSIFICATION` step in `SKILL.md`. Refer here for trigger rules, the `write-marker.sh` invocation, the blocklist, and worked examples.

## Trigger (binary — no judgment calls)

You **MUST** classify the turn if ANY of these are true:

- You called any tool other than read-only file inspection. Reading a file alone does not count. Bash commands, writes, edits, searches, and any other tool ALL count.
- You produced > 200 words of new content in your response.
- The user asked a question that required multi-step reasoning to answer.

You **MUST** skip the marker write ONLY when ALL of these are true:

- Your entire response is ≤ 2 sentences.
- You called zero tools.

There is no "borderline / when in doubt skip" path. If you can argue either side, you have already triggered rule (a), (b), or (c) — classify.

## Read-only tools (exempt from trigger rule a)

The following tools are **read-only** and do NOT trigger rule (a) by themselves:

- File read / view
- Directory listing / glob
- Grep / search (no write side-effect)

Any tool with a write, execute, or side-effecting action is non-read-only and DOES trigger rule (a).

## Required action sequence

Before your final response yields back to the user, you **MUST** call `write-marker.sh` with the chosen label. **DO NOT skip it. DO NOT defer it to "next turn". DO NOT respond to the user without performing it.** The success print line (`marker written: <path>`) is your confirmation that the action completed.

**Step 1 — pick a `task_type` label.** Choose the closest-fitting label from the fixed 8-label taxonomy below. Do NOT invent new labels.

| Label | When to use |
|-------|-------------|
| `research` | Reading docs, exploring code, searching to learn before acting |
| `analysis` | Diagnosing a problem, profiling, or characterizing a system |
| `generation` | Writing new code, tests, configuration, or documentation from scratch |
| `review` | Reviewing docs, designs, or diffs for correctness or fit |
| `code_review` | Reviewing code for correctness, style, or architectural fit |
| `refactor` | Restructuring existing code without changing observable behavior |
| `planning` | Producing a plan, roadmap, design doc, or task breakdown |
| `debugging` | Reproducing and fixing a defect or unexpected behavior |

The taxonomy is fixed. Do not use any label outside this set — `write-marker.sh` will reject it with a non-zero exit code and print an error; when that happens, default attribution is `unclassified`.

The following values are **rejected** by `write-marker.sh` and must NEVER be used:

- `ack`
- `acknowledgment`
- `greeting`
- `confirmation`
- `hello`
- `thanks`
- Any label not in the 8-label set above

**Step 2 — call `write-marker.sh`.** Replace `<task_type>` with the label from Step 1:

```
bash ~/.openclaw/skills/revenium/scripts/write-marker.sh <task_type>
```

- **Exit 0 + prints `marker written: <path>`:** success — the marker is appended.
- **Non-zero exit or no `marker written:` line:** protocol error — log the error, do not block your response; the cron will default to `unclassified` for attributions without a marker.

## Self-check before yielding

Immediately before yielding your final response, answer these questions. If markers were required and you have not written them, fix it NOW — call `write-marker.sh` before sending your response. Do not promise to do it next turn.

1. Did I call any non-read-only tool in this turn? → if yes, marker REQUIRED.
2. Did I produce > 200 words of new content? → if yes, marker REQUIRED.
3. Did I call `write-marker.sh`? → if a marker was REQUIRED, YES is the only acceptable answer.

## Examples

**Example 1 — Clear substantive (CLASSIFY):**
User asked for a code review. You called `read_file` twice and ran a bash command. You wrote 12 sentences with suggested changes.
- Rule (a) triggered: bash command is a non-read-only tool.
- Required action: `bash ~/.openclaw/skills/revenium/scripts/write-marker.sh code_review`

**Example 2 — Clear trivial (SKIP):**
User typed "what is 2+2?" You replied "4." in one sentence. No tools called.
- All skip conditions met: ≤ 2 sentences AND zero tools.
- Required action: NONE. No marker written.

**Example 3 — Borderline classify (CLASSIFY):**
User asked you to explain POSIX O_APPEND atomicity. You wrote a five-paragraph response covering the kernel guarantee, macOS vs Linux behavior, and the belt-and-suspenders flock recommendation. No tools were called.
- Rule (b) triggered: > 200 words of new content.
- Required action: `bash ~/.openclaw/skills/revenium/scripts/write-marker.sh analysis`

**Example 4 — Borderline skip (SKIP):**
User said "good morning, can you confirm you're ready?" You replied "Good morning — ready when you are." over two short lines. No tools called.
- All skip conditions met: ≤ 2 sentences AND zero tools.
- Required action: NONE.

Writing a marker on a clear-skip turn pollutes the taxonomy. Skipping a marker on a clear-classify turn breaks attribution. The rule is binary by design — there is no middle ground.
