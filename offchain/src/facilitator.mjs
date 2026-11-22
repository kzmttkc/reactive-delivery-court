// Self-hosted x402 facilitator for the auth-capture scheme on Base Sepolia.
// The official SDK facilitator (@x402/evm auth-capture) verifies the buyer's ERC-3009
// signature, simulates the custom-operator authorize with eth_simulateV1 (nested logs and
// balances before and after, as the auth-capture EVM spec asks of a facilitator that relays
// to a custom operator), then the relayer role sends DeliveryCourtCallback.authorize.
// The only operator it relays to is DeliveryCourtCallback.
import express from "express";
import { createWalletClient, http, publicActions } from "viem";
import { baseSepolia } from "viem/chains";
import { x402Facilitator } from "@x402/core/facilitator";
import { toFacilitatorEvmSigner } from "@x402/evm";
import { AuthCaptureEvmScheme } from "@x402/evm/auth-capture/facilitator";
import { BASE_RPC, CALLBACK, NETWORK } from "./config.mjs";

export function createFacilitator(relayerAccount, { log = () => {} } = {}) {
  const client = createWalletClient({ account: relayerAccount, chain: baseSepolia, transport: http(BASE_RPC) }).extend(publicActions);
  const signer = toFacilitatorEvmSigner(Object.assign(client, { address: relayerAccount.address }), { confirmationTimeoutMs: 60_000 });
  const scheme = new AuthCaptureEvmScheme(signer, {
    operators: [{ address: CALLBACK, operatorType: "custom" }],
    feeTerms: { feeRecipient: "0x0000000000000000000000000000000000000000", minFeeBps: 0, maxFeeBps: 0 },
  });
  const facilitator = new x402Facilitator().register(NETWORK, scheme);

  const app = express();
  app.use(express.json({ limit: "256kb" }));
  app.get("/supported", (_req, res) => res.json(facilitator.getSupported()));
  app.post("/verify", async (req, res) => {
    try {
      const r = await facilitator.verify(req.body.paymentPayload, req.body.paymentRequirements);
      log("verify", r.isValid ? "valid" : r.invalidReason);
      res.json(r);
    } catch (e) {
      log("verify error", e.message);
      res.status(500).json({ error: String(e.message) });
    }
  });
  app.post("/settle", async (req, res) => {
    try {
      const r = await facilitator.settle(req.body.paymentPayload, req.body.paymentRequirements);
      log("settle", r.success ? r.transaction : `${r.errorReason} ${r.errorMessage ?? ""}`);
      res.json(r);
    } catch (e) {
      log("settle error", e.message);
      res.status(500).json({ error: String(e.message) });
    }
  });
  return { app, facilitator };
}
