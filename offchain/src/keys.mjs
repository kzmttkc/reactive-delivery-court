// Loads a role's testnet key from ~/.vet402-keys/reactive-roles.json into a viem account.
// The key value is never printed, logged or returned outside the account object.
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { privateKeyToAccount } from "viem/accounts";

// On the public server the same JSON (only the roles that server uses) comes from the
// ROLE_KEYS_JSON secret instead of the file.
export function roleAccount(role) {
  const j = JSON.parse(process.env.ROLE_KEYS_JSON || readFileSync(join(homedir(), ".vet402-keys", "reactive-roles.json"), "utf8"));
  if (!String(j.note ?? "").includes("testnet only")) throw new Error("reactive-roles.json is not marked testnet only");
  const entry = (j.keys ?? []).find((k) => k.role === role);
  if (!entry) throw new Error(`no key for role ${role}`);
  const account = privateKeyToAccount(entry.private_key);
  if (account.address !== entry.address) throw new Error(`address mismatch for role ${role}`);
  return account;
}
