#!/usr/bin/env node
// Verifies pinned toolchain versions. The circuits must be compiled with
// the exact circom + snarkjs versions recorded in package.json.

import { readFileSync } from "node:fs";
import { execSync } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, "..");
const pkg = JSON.parse(readFileSync(join(root, "package.json"), "utf8"));

const expectedCircom = pkg.config.circom_version;
const expectedSnarkjs = pkg.dependencies.snarkjs;

const circomOut = execSync("circom --version", { encoding: "utf8" });
const circomMatch = circomOut.match(/(\d+\.\d+\.\d+)/);
if (!circomMatch || circomMatch[1] !== expectedCircom) {
  console.error(`  ✗ circom: expected ${expectedCircom}, got ${circomMatch?.[1] ?? "unknown"}`);
  process.exit(1);
}
console.log(`  ✓ circom ${circomMatch[1]}`);

const snarkjsPkg = JSON.parse(
  readFileSync(join(root, "node_modules", "snarkjs", "package.json"), "utf8"),
);
if (snarkjsPkg.version !== expectedSnarkjs) {
  console.error(
    `  ✗ snarkjs: expected ${expectedSnarkjs}, got ${snarkjsPkg.version} (rerun \`npm ci\`)`,
  );
  process.exit(1);
}
console.log(`  ✓ snarkjs ${snarkjsPkg.version}`);

console.log("\nToolchain matches pinned versions.");
