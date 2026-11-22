#!/usr/bin/env node
// Runs a command with EVM_ADDRESS / EVM_PRIVATE_KEY set for one testnet role.
//   deployer                     -> ~/.vet402-keys/chiangmai-testnet.json
//   buyer, seller-deliver, seller-empty, seller-silent, judge, relayer
//                                -> ~/.vet402-keys/reactive-roles.json (derived, see offchain/src/derive-roles.mjs)
// Reads the files by JSON key names only. Never prints, logs or writes the key value.
// usage: with-evm-key.mjs <role> <command> [args...]
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";

const [role, cmd, ...args] = process.argv.slice(2);
if (!role || !cmd) {
  console.error("usage: with-evm-key.mjs <role> <command> [args...]");
  process.exit(2);
}

function load(file) {
  const j = JSON.parse(readFileSync(join(homedir(), ".vet402-keys", file), "utf8"));
  if (!String(j.note ?? "").includes("testnet only")) throw new Error(`${file} is not marked testnet only`);
  return j.keys ?? [];
}

const entry = (role === "deployer" ? load("chiangmai-testnet.json") : load("reactive-roles.json")).find((k) => k.role === role);
if (!entry) throw new Error(`no key with role ${role}`);
const env = { ...process.env, EVM_ADDRESS: entry.address, EVM_PRIVATE_KEY: entry.private_key };
console.error(`[with-evm-key] ${role}=${entry.address} (key not shown)`);
const r = spawnSync(cmd, args, { env, stdio: "inherit" });
process.exit(r.status ?? 1);
