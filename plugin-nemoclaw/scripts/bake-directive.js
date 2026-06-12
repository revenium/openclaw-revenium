#!/usr/bin/env node
/**
 * bake-directive.js — Build-time script that inlines BUDGET-GUARD.md into src/guard.js.
 *
 * GENERATED OUTPUT: plugin-nemoclaw/src/guard.js (GUARD_DIRECTIVE constant)
 * SOURCE OF TRUTH: BUDGET-GUARD.md (repo root)
 *
 * Run via: node scripts/bake-directive.js
 * (Called automatically by `npm run build` before tsc)
 *
 * Security (T-15-01): escapes backslashes, backticks, and ${ sequences so that
 * BUDGET-GUARD.md content cannot break out of the template literal or inject
 * executable expressions into guard.js.
 */

import { readFileSync, writeFileSync, copyFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// Escape so file content cannot break out of the template literal or inject
// executable expressions: backslashes first (must be first to avoid
// double-escaping), then backticks, then ${ sequences.
function escapeForTemplateLiteral(raw) {
  return raw
    .replace(/\\/g, "\\\\")
    .replace(/`/g, "\\`")
    .replace(/\$\{/g, "\\${");
}

// bakeConstant — read a markdown source, escape it, and write a generated
// src/<outFile> exporting `export const <constName> = `...``.
function bakeConstant({ srcPath, outFile, constName, label }) {
  let raw;
  try {
    raw = readFileSync(srcPath, "utf8");
  } catch (err) {
    console.error(`bake-directive.js: failed to read ${srcPath}: ${err.message}`);
    process.exit(1);
  }
  const escaped = escapeForTemplateLiteral(raw);
  const outPath = resolve(__dirname, "..", "src", outFile);
  const output = [
    `// GENERATED — do not edit. Source: ${label}`,
    "// Rebuild by running: node scripts/bake-directive.js (or npm run build)",
    "//",
    `// ${outFile} — Baked-in directive for the revenium-enforcement plugin.`,
    "// The build step reads the source markdown and escapes it into a template literal.",
    "// No fs I/O at hook time — the directive is a pure static constant (D-02).",
    "",
    `export const ${constName} = \`${escaped}\`;`,
    "",
  ].join("\n");
  try {
    writeFileSync(outPath, output, "utf8");
    console.log(`bake-directive.js: wrote ${outPath}`);
  } catch (err) {
    console.error(`bake-directive.js: failed to write ${outPath}: ${err.message}`);
    process.exit(1);
  }
}

// Resolve sources from repo root (two levels up: scripts/ -> plugin-nemoclaw/ -> repo root).
// GUARD_DIRECTIVE: guardrail enforcement (read at turn START).
bakeConstant({
  srcPath: resolve(__dirname, "..", "..", "BUDGET-GUARD.md"),
  outFile: "guard.js",
  constName: "GUARD_DIRECTIVE",
  label: "BUDGET-GUARD.md",
});
// METERING_DIRECTIVE: task classification + job declaration completion gates
// (run at turn END). Standalone installs inject this into AGENTS.md (post-install.sh
// step 7b); the NemoClaw sandbox has no AGENTS.md injection, so it rides the
// before_prompt_build hook here — otherwise the in-sandbox agent is never told to
// write task/job markers and Revenium sees no task-type attribution and no jobs.
bakeConstant({
  srcPath: resolve(__dirname, "..", "..", "references", "agents-metering-directives.md"),
  outFile: "metering.js",
  constName: "METERING_DIRECTIVE",
  label: "references/agents-metering-directives.md",
});

// Copy plugin/src/gate.js into src/gate.js so tsc can compile it within rootDir.
// D-06: imports the single shared source — not a fork. Any changes to plugin/src/gate.js
// are picked up on the next rebuild. Do NOT edit src/gate.js directly.
const gateSrc = resolve(__dirname, "..", "..", "plugin", "src", "gate.js");
const gateDst = resolve(__dirname, "..", "src", "gate.js");
try {
  copyFileSync(gateSrc, gateDst);
  console.log(`bake-directive.js: copied gate.js from ${gateSrc}`);
} catch (err) {
  console.error(`bake-directive.js: failed to copy gate.js: ${err.message}`);
  process.exit(1);
}
