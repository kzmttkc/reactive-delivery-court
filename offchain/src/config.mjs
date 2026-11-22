// Addresses and settings shared by the facilitator, sellers, buyer and judge.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const REPO = join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const dep = JSON.parse(readFileSync(join(REPO, "deployments", "v2.json"), "utf8"));
const roles = JSON.parse(readFileSync(join(REPO, "deployments", "roles.json"), "utf8")).roles;

export const NETWORK = "eip155:84532";
export const CHAIN_ID = 84532;
export const BASE_RPC = process.env.BASE_SEPOLIA_RPC_URL || "https://sepolia.base.org";
export const LASNA_RPC = process.env.LASNA_RPC_URL || "https://lasna-rpc.rnk.dev/";

export const CALLBACK = dep.callback.address;
export const REACTIVE = dep.reactive.address;
export const ESCROW = dep.escrow;
export const USDC = dep.usdc;
export const IDENTITY = dep.identityRegistry;
export const REPUTATION = dep.reputationRegistry;
export const VALIDATION = dep.validationRegistry;
export const AGENTS = dep.agents;
export const ROLES = roles;
export const THRESHOLD = dep.reactive.threshold;

export const PRICE_UNITS = "10000"; // 0.01 USDC

export const SELLERS = {
  deliver: { role: "seller-deliver", port: 4021, deadlineSeconds: 600 },
  empty: { role: "seller-empty", port: 4022, deadlineSeconds: 600 },
  silent: { role: "seller-silent", port: 4023, deadlineSeconds: 90 },
};
export const FACILITATOR_PORT = 4020;
