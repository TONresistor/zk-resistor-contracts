#!/usr/bin/env node

import { readFile } from "node:fs/promises";

const [lcovPath, minimumRaw = "95"] = process.argv.slice(2);
if (!lcovPath) {
  throw new Error("usage: check-lcov-lines.mjs <lcov.info> [minimum-percent]");
}
const minimum = Number(minimumRaw);
if (!Number.isFinite(minimum) || minimum < 0 || minimum > 100) {
  throw new Error(`invalid minimum percentage: ${minimumRaw}`);
}

const report = await readFile(lcovPath, "utf8");
let found = 0;
let hit = 0;
for (const line of report.split(/\r?\n/)) {
  if (line.startsWith("LF:")) found += Number(line.slice(3));
  if (line.startsWith("LH:")) hit += Number(line.slice(3));
}
if (found === 0) throw new Error(`no line coverage records in ${lcovPath}`);

const percent = (hit * 100) / found;
console.log(
  `Line coverage: ${hit}/${found} (${percent.toFixed(2)}%), minimum ${minimum.toFixed(2)}%`,
);
if (percent + Number.EPSILON < minimum) process.exit(1);
