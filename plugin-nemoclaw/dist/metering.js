// GENERATED — do not edit. Source: references/agents-metering-directives.md
// Rebuild by running: node scripts/bake-directive.js (or npm run build)
//
// metering.js — Baked-in directive for the revenium-enforcement plugin.
// The build step reads the source markdown and escapes it into a template literal.
// No fs I/O at hook time — the directive is a pure static constant (D-02).
export const METERING_DIRECTIVE = `<!-- BEGIN revenium-metering-directives -->
## Revenium Metering — Task Classification (Mandatory Completion Gate)

Your turn is NOT complete until you classify it. This is a hard gate, not a suggestion — the same weight as the Guardrail Check above, just at the END of the turn instead of the start.

**If you called ANY tool other than read-only file inspection, OR produced > 200 words, OR the request needed multi-step reasoning, then the LAST tool call you make before yielding to the user MUST be:**

\`\`\`
bash ~/.openclaw/skills/revenium/scripts/write-marker.sh <task_type>
\`\`\`

A substantive response that ends without running \`write-marker.sh\` is a protocol violation. If you are about to yield and have not run it, run it NOW. Skip ONLY when your entire response is ≤ 2 sentences AND you called zero tools.

\`task_type\` — pick the closest: \`research\`, \`analysis\`, \`generation\`, \`review\`, \`code_review\`, \`refactor\`, \`planning\`, \`debugging\`. Confirmation is \`marker written: <path>\`. On error, log it but do not block your reply.

## Revenium Metering — Job Declaration (Mandatory Completion Gate)

When the user's goal is satisfied, definitively failed, or abandoned — i.e. the work arc concludes — you MUST declare it as an agentic job as your final action before your closing summary. Most requests are one arc = one job; declare at least one per session in which any real work occurred. This is a hard gate.

Mint a kebab-case goal slug + 4 random hex chars, then run (before yielding):

\`\`\`
bash ~/.openclaw/skills/revenium/scripts/write-job-marker.sh \\
  --job-id <goal-slug>-<4hex> \\
  --job-name "<short goal description>" \\
  --job-type <label> \\
  --status SUCCESS|FAILED|CANCELLED \\
  [--failure-reason "<brief cause — FAILED only>"]
\`\`\`

\`job_type\` — pick the closest: \`feature_development\`, \`bug_fix\`, \`code_review\`, \`refactoring\`, \`research\`, \`debugging\`, \`testing\`, \`documentation\`, \`devops\`, \`planning\`, \`interrupted\`. Status: \`SUCCESS\` = verified positive evidence; \`FAILED\` = definitive negative terminal state (add \`--failure-reason\`); \`CANCELLED\` = catch-all / when in doubt. Confirmation is \`job marker written: <path>\`. On error, log it but do not block your reply.

Running these two writes is part of FINISHING the task — exactly like the Guardrail Check is part of STARTING it. A completed substantive turn with neither marker leaves Revenium blind.
<!-- END revenium-metering-directives -->
`;
