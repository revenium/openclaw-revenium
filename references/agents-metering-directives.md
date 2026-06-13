<!-- BEGIN revenium-metering-directives -->
## Revenium Metering — Task Classification (Mandatory Completion Gate)

Your turn is NOT complete until you classify it. This is a hard gate, not a suggestion — the same weight as the Guardrail Check above, just at the END of the turn instead of the start.

**If you called ANY tool other than read-only file inspection, OR produced > 200 words, OR the request needed multi-step reasoning, then the LAST tool call you make before yielding to the user MUST be:**

```
bash ~/.openclaw/skills/revenium/scripts/write-marker.sh <task_type>
```

A substantive response that ends without running `write-marker.sh` is a protocol violation. If you are about to yield and have not run it, run it NOW. Skip ONLY when your entire response is ≤ 2 sentences AND you called zero tools.

`task_type` — pick the closest: `research`, `analysis`, `generation`, `review`, `code_review`, `refactor`, `planning`, `debugging`. Confirmation is `marker written: <path>`. On error, log it but do not block your reply.

## Revenium Metering — Job Declaration (Mandatory Lifecycle Gates)

Work arcs are tracked as agentic jobs with an OPEN at the start and a CLOSE at the end. Most requests are one arc = one job. These are hard gates.

**OPEN — when the user gives you a goal needing real work** (multi-step, tool-using, or substantive creative/analytical — skip only for ≤2-sentence zero-tool exchanges), BEFORE diving in. Mint a kebab-case goal slug + 4 random hex chars:

```
bash ~/.openclaw/skills/revenium/scripts/write-job-marker.sh \
  --job-id <goal-slug>-<4hex> \
  --job-name "<short goal description>" \
  --job-type <label> \
  --status RUNNING
```

**CLOSE — when the arc concludes** (goal satisfied, definitively failed, or abandoned/pivoted), as your final action before your closing summary:

```
bash ~/.openclaw/skills/revenium/scripts/write-job-marker.sh \
  --close --status SUCCESS|FAILED|CANCELLED \
  [--failure-reason "<brief cause — FAILED only>"]
```

If `--close` errors (no open job recorded) or you never opened the arc, declare once at the end with the full OPEN flags plus a terminal status instead of RUNNING.

`job_type` — pick the closest: `feature_development`, `bug_fix`, `code_review`, `refactoring`, `research`, `debugging`, `testing`, `documentation`, `devops`, `planning`, `interrupted`. Status: `RUNNING` = arc underway (open only); `SUCCESS` = verified positive evidence; `FAILED` = definitive negative terminal state (add `--failure-reason`); `CANCELLED` = catch-all / when in doubt. Confirmation is `job marker written: <path>`. On error, log it but do not block your reply.

Opening the job is part of STARTING the task and closing it is part of FINISHING — exactly like the Guardrail Check. A substantive arc with no job record leaves Revenium blind.
<!-- END revenium-metering-directives -->
