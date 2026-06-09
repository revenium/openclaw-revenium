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

// Resolve BUDGET-GUARD.md from repo root (two levels up: scripts/ -> plugin-nemoclaw/ -> repo root)
const srcPath = resolve(__dirname, "..", "..", "BUDGET-GUARD.md");
const outPath = resolve(__dirname, "..", "src", "guard.js");

let raw;
try {
  raw = readFileSync(srcPath, "utf8");
} catch (err) {
  console.error(`bake-directive.js: failed to read ${srcPath}: ${err.message}`);
  process.exit(1);
}

// Escape: backslashes first (must be first to avoid double-escaping),
// then backticks, then ${ sequences (template literal injection guard).
const escaped = raw
  .replace(/\\/g, "\\\\")
  .replace(/`/g, "\\`")
  .replace(/\$\{/g, "\\${");

const output = [
  "// GENERATED — do not edit. Source: BUDGET-GUARD.md",
  "// Rebuild by running: node scripts/bake-directive.js (or npm run build)",
  "//",
  "// guard.js — Baked-in guardrail directive for the revenium-enforcement plugin.",
  "// The build step reads BUDGET-GUARD.md and escapes it into a template literal.",
  "// No fs I/O at hook time — the directive is a pure static constant (D-02).",
  "",
  `export const GUARD_DIRECTIVE = \`${escaped}\`;`,
  "",
].join("\n");

try {
  writeFileSync(outPath, output, "utf8");
  console.log(`bake-directive.js: wrote ${outPath}`);
} catch (err) {
  console.error(`bake-directive.js: failed to write ${outPath}: ${err.message}`);
  process.exit(1);
}

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
