import fs from "node:fs";

function requiredArg(name) {
  const index = process.argv.indexOf(`--${name}`);
  if (index < 0 || index + 1 >= process.argv.length) throw new Error(`Missing --${name}`);
  return process.argv[index + 1];
}

const sessionPath = requiredArg("session");
const contract = requiredArg("contract");
const sourcePath = requiredArg("source");
const waiverPath = requiredArg("waivers");
const events = fs
  .readFileSync(sessionPath, "utf8")
  .trim()
  .split("\n")
  .map((line) => JSON.parse(line));
if (!events.some((event) => event.event === "session_finished")) {
  throw new Error(`Mutation session did not finish: ${sessionPath}`);
}

const records = events
  .filter((event) => event.event === "mutation_completed")
  .map((event) => event.record)
  .filter((record) => record.source_path === sourcePath);
if (records.length === 0) {
  throw new Error(
    `Mutation session executed zero mutants for ${sourcePath}; ` +
      "the release gate must not use an empty diff",
  );
}
const survived = records.filter((record) => record.status === "survived");
const waiverDocument = JSON.parse(fs.readFileSync(waiverPath, "utf8"));
if (waiverDocument.version !== 1 || !Array.isArray(waiverDocument.waivers)) {
  throw new Error(`Unsupported mutation waiver format: ${waiverPath}`);
}
const waivers = waiverDocument.waivers.filter(
  (waiver) => waiver.contract === contract && waiver.source_path === sourcePath,
);
const matchCounts = new Array(waivers.length).fill(0);
const unexpected = [];

for (const mutant of survived) {
  const matches = waivers
    .map((waiver, index) => ({ waiver, index }))
    .filter(
      ({ waiver }) =>
        waiver.rule_name === mutant.rule_name &&
        mutant.code_context.includes(waiver.line_contains),
    );
  if (matches.length !== 1) {
    unexpected.push(mutant);
  } else {
    matchCounts[matches[0].index] += 1;
  }
}

const invalidWaivers = waivers.filter((_, index) => matchCounts[index] !== 1);
const count = (status) => records.filter((record) => record.status === status).length;
console.log(
  `${sourcePath}: killed=${count("killed")} survived=${survived.length} ` +
    `compile_errors=${count("compile_error")} waived=${survived.length - unexpected.length}`,
);
for (const mutant of unexpected) {
  console.error(`Unexpected survivor: ${mutant.source_path}:${mutant.line} ${mutant.rule_name}`);
}
for (const waiver of invalidWaivers) {
  console.error(
    `Stale or ambiguous waiver: ${waiver.source_path} ${waiver.rule_name} ` +
      JSON.stringify(waiver.line_contains),
  );
}
if (unexpected.length > 0 || invalidWaivers.length > 0) process.exitCode = 1;
