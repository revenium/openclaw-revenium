// Spike 006: minimal OpenClaw plugin proving per-turn directive injection.
// Replicates the nemoclaw plugin's mechanism (before_prompt_build -> prependContext).
// Pure + static: no child_process, no fs, no network — passes the install-time safety scanner.
export default function register(api) {
  api.on("before_prompt_build", () => ({
    prependContext: [
      "<revenium-guard>",
      "MANDATORY (Revenium budget enforcement): before doing anything else this turn,",
      "read ~/.openclaw/skills/revenium/guardrail-status.json and honor halted/warned.",
      "Proof-of-injection: begin your reply with the token REVENIUM_GUARD_ACTIVE.",
      "</revenium-guard>",
    ].join("\n"),
  }));
}
