#!/usr/bin/env node
/**
 * copy-gate.js — Build-time step that copies src/gate.js into dist/gate.js.
 *
 * SOURCE OF TRUTH: plugin/src/gate.js (the single shared marker-gate logic, D-06).
 * GENERATED OUTPUT: plugin/dist/gate.js
 *
 * Why this exists (CR-01 fix): gate.js is a plain `.js` ESM module, but
 * plugin/tsconfig.json's include glob is `src/**\/*.ts`, so `tsc` never emits
 * dist/gate.js. Historically dist/gate.js was a hand-maintained copy that went
 * stale (the B-05 transcript-scan update was missed on the standalone path).
 * This step makes the copy automatic so dist/gate.js CANNOT drift from src
 * again — it is refreshed on every `npm run build`, mirroring how
 * plugin-nemoclaw/scripts/bake-directive.js syncs the same shared source.
 *
 * gate.js is already valid ESM (no TypeScript syntax), so a faithful copy is
 * directly importable by node:test and by the openclaw host — no transform.
 *
 * Run via: node scripts/copy-gate.js  (called automatically by `npm run build`)
 */
import { copyFileSync, mkdirSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

const src = resolve(__dirname, "..", "src", "gate.js");
const distDir = resolve(__dirname, "..", "dist");
const dst = resolve(distDir, "gate.js");

try {
  mkdirSync(distDir, { recursive: true });
  copyFileSync(src, dst);
  console.log(`copy-gate.js: copied ${src} -> ${dst}`);
} catch (err) {
  console.error(`copy-gate.js: failed to copy gate.js: ${err.message}`);
  process.exit(1);
}
