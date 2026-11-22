#!/usr/bin/env node
// Derives one key per Delivery Court role from the testnet deployer key:
//   role key = keccak256(parent key bytes || utf8("delivery-court:<role>"))
// Writes the keys to ~/.vet402-keys/reactive-roles.json (mode 600, outside the repo)
// and only the public addresses to deployments/roles.json in the repo.
// Never prints, logs or commits a key value.
import { readFileSync, writeFileSync, chmodSync, mkdirSync } from "node:fs";
import { homedir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { keccak256, concat, toBytes } from "viem";
import { privateKeyToAccount } from "viem/accounts";

export const ROLES = ["buyer", "seller-deliver", "seller-empty", "seller-silent", "judge", "relayer"];

export function deriveRoleKey(parentKey, role) {
  return keccak256(concat([toBytes(parentKey), toBytes(`delivery-court:${role}`)]));
}

function main() {
  const parentFile = join(homedir(), ".vet402-keys", "chiangmai-testnet.json");
  const j = JSON.parse(readFileSync(parentFile, "utf8"));
  if (!String(j.note ?? "").includes("testnet only")) throw new Error("parent key file is not marked testnet only");
  const parent = (j.keys ?? []).find((k) => k.role === "deployer");
  if (!parent) throw new Error("no deployer key");

  const keys = [];
  const addresses = {};
  for (const role of ROLES) {
    const pk = deriveRoleKey(parent.private_key, role);
    const address = privateKeyToAccount(pk).address;
    keys.push({ role, address, private_key: pk });
    addresses[role] = address;
  }
  addresses.deployer = parent.address;

  const out = join(homedir(), ".vet402-keys", "reactive-roles.json");
  writeFileSync(
    out,
    JSON.stringify(
      {
        note: "testnet only. Delivery Court roles derived from the chiangmai-testnet deployer key: keccak256(parent || 'delivery-court:<role>')",
        parent: parent.address,
        keys,
      },
      null,
      2,
    ),
    { mode: 0o600 },
  );
  chmodSync(out, 0o600);

  const repo = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
  mkdirSync(join(repo, "deployments"), { recursive: true });
  writeFileSync(
    join(repo, "deployments", "roles.json"),
    JSON.stringify(
      {
        derivation: "role key = keccak256(deployer key || utf8('delivery-court:<role>')). Keys live outside this repo.",
        chain: "Base Sepolia (84532), Lasna (5318007) for the deployer",
        roles: addresses,
      },
      null,
      2,
    ) + "\n",
  );
  for (const [r, a] of Object.entries(addresses)) console.log(`${r}\t${a}`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
