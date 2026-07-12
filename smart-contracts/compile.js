const solc = require("solc");
const fs = require("fs");
const path = require("path");

const ROOT = __dirname;
const targets = process.argv.slice(2);
if (targets.length === 0) {
  console.error("usage: node compile.js <file.sol> [...]");
  process.exit(1);
}

function resolveImport(importPath) {
  const remaps = [
    ["@openzeppelin/contracts/", "lib/openzeppelin-contracts/contracts/"],
    ["forge-std/", "lib/forge-std/src/"],
    ["src/", "src/"],
    ["test/", "test/"],
  ];
  let p = importPath;
  for (const [from, to] of remaps) {
    if (p.startsWith(from)) { p = to + p.slice(from.length); break; }
  }
  const abs = path.isAbsolute(p) ? p : path.join(ROOT, p);
  try {
    return { contents: fs.readFileSync(abs, "utf8") };
  } catch (e) {
    return { error: "not found: " + importPath + " -> " + abs };
  }
}

const sources = {};
for (const t of targets) sources[t] = { content: fs.readFileSync(path.join(ROOT, t), "utf8") };

const input = {
  language: "Solidity",
  sources,
  settings: {
    optimizer: { enabled: true, runs: 200 },
    evmVersion: "paris",
    outputSelection: { "*": { "*": ["abi", "evm.bytecode.object"] } },
  },
};

const out = JSON.parse(solc.compile(JSON.stringify(input), { import: resolveImport }));
let failed = false;
for (const e of out.errors || []) {
  if (e.severity === "error") { failed = true; console.error(e.formattedMessage); }
  else if (process.env.WARN) console.warn(e.formattedMessage);
}
if (!failed) {
  const names = [];
  for (const f of Object.keys(out.contracts || {}))
    for (const c of Object.keys(out.contracts[f])) names.push(c);
  console.log("COMPILE OK:", names.join(", "));
  if (process.env.SAVE) {
    fs.mkdirSync(path.join(ROOT, "out-js"), { recursive: true });
    fs.writeFileSync(path.join(ROOT, "out-js", "build.json"), JSON.stringify(out.contracts));
  }
} else process.exit(1);
