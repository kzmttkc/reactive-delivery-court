// Three x402 sellers on the official @x402/express middleware and the auth-capture scheme.
// Payment requirements: payTo = the seller, funds held by the x402 AuthCaptureEscrow with
// DeliveryCourtCallback as the "custom" operator, captureMode "deferred", zero fees.
// The seller never captures. Release or refund is decided by the court.
//   deliver: 200 with a real JSON body (live Base Sepolia chain data)
//   empty:   200 with a 0-byte body
//   silent:  never answers
// After a paid request, the deliver and empty sellers file an ERC-8004 validationRequest
// (requestHash = paymentId) that names the judge, as an honest seller that believes it delivered.
import express from "express";
import { createHash } from "node:crypto";
import { EventEmitter } from "node:events";
import { createPublicClient, createWalletClient, http, zeroAddress } from "viem";
import { baseSepolia } from "viem/chains";
import { paymentMiddleware, x402ResourceServer } from "@x402/express";
import { HTTPFacilitatorClient } from "@x402/core/server";
import { decodePaymentSignatureHeader } from "@x402/core/http";
import { AuthCaptureEvmScheme } from "@x402/evm/auth-capture/server";
import { AGENTS, BASE_RPC, CALLBACK, CHAIN_ID, ESCROW, NETWORK, PRICE_UNITS, ROLES, USDC, VALIDATION } from "./config.mjs";
import { paymentIdFromPayload } from "./payment-id.mjs";
import { declareDiscoveryExtension } from "@x402/extensions/bazaar";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { REPO } from "./config.mjs";

// Output schema each seller declares in its 402 answer (x402 Bazaar discovery extension).
// The judge checks the body against it. model/seller_schemas.json is shared with model/evaluate.py.
export const OUTPUT_SCHEMAS = JSON.parse(readFileSync(join(REPO, "model", "seller_schemas.json"), "utf8"));
const OUTPUT_EXAMPLE = { network: "eip155:84532", blockNumber: "61711514", blockTimestamp: 1795264171 };

const VALIDATION_ABI = [
  {
    type: "function", name: "validationRequest", stateMutability: "nonpayable", outputs: [],
    inputs: [
      { name: "validatorAddress", type: "address" }, { name: "agentId", type: "uint256" },
      { name: "requestURI", type: "string" }, { name: "requestHash", type: "bytes32" },
    ],
  },
];

// The SDK server rounds "now" down to a 60 s bucket before it adds captureDeadlineSeconds, so the
// capture deadline can be as early as now + deadlineSeconds - 59. The facilitator refuses a payment
// whose now + maxTimeoutSeconds passes that deadline (invalid_auth_capture_evm_deadline_ordering).
// Keep 10 s of slack for signing and the facilitator's own clock.
export const DEADLINE_BUCKET_SECONDS = 60;
export function maxTimeoutFor(deadlineSeconds) {
  return Math.max(15, Math.min(60, deadlineSeconds - DEADLINE_BUCKET_SECONDS - 10));
}

export function paymentRequirements(kind, payTo, deadlineSeconds) {
  return {
    scheme: "auth-capture",
    network: NETWORK,
    payTo,
    price: { amount: PRICE_UNITS, asset: USDC },
    maxTimeoutSeconds: maxTimeoutFor(deadlineSeconds),
    extra: {
      operatorType: "custom",
      captureAuthorizer: CALLBACK,
      captureMode: "deferred",
      paymentFlow: "escrow",
      receiverAuthorizer: zeroAddress,
      feeRecipient: zeroAddress,
      minFeeBps: 0,
      maxFeeBps: 0,
      name: "USDC",
      version: "2",
      captureDeadlineSeconds: deadlineSeconds,
      refundDeadlineSeconds: deadlineSeconds,
    },
  };
}

export const handlers = {
  async deliver(_req, res, ctx) {
    const block = await ctx.publicClient.getBlock();
    res.json({
      network: NETWORK,
      blockNumber: block.number.toString(),
      blockTimestamp: Number(block.timestamp),
      baseFeePerGasWei: block.baseFeePerGas?.toString() ?? null,
      servedBy: "delivery-court seller-deliver",
    });
  },
  async empty(_req, res) {
    res.status(200).end();
  },
  async silent(req, _res, ctx) {
    ctx.held.add(req); // never answers
  },
};

export function createSeller(kind, { account, facilitatorUrl, deadlineSeconds, judge = ROLES.judge, fileRequest = true, log = () => {} }) {
  const payTo = ROLES[`seller-${kind}`];
  const publicClient = createPublicClient({ chain: baseSepolia, transport: http(BASE_RPC) });
  const wallet = account ? createWalletClient({ account, chain: baseSepolia, transport: http(BASE_RPC) }) : null;
  const events = new EventEmitter();
  const ctx = { publicClient, held: new Set() };

  const server = new x402ResourceServer(new HTTPFacilitatorClient({ url: facilitatorUrl, timeoutMs: 90_000 })).register(
    NETWORK,
    new AuthCaptureEvmScheme({ collectOnlyRoutes: true }),
  );
  const routes = {
    "GET /resource": {
      accepts: paymentRequirements(kind, payTo, deadlineSeconds),
      description: `Delivery Court demo seller (${kind})`,
      mimeType: "application/json",
      extensions: OUTPUT_SCHEMAS[kind]
        ? declareDiscoveryExtension({ method: "GET", output: { example: OUTPUT_EXAMPLE, schema: OUTPUT_SCHEMAS[kind] } })
        : undefined,
    },
  };

  const app = express();
  app.use(paymentMiddleware(routes, server));
  app.get("/resource", async (req, res) => {
    const header = req.header("payment-signature");
    const paymentPayload = header ? decodePaymentSignatureHeader(header) : null;
    const paymentId = paymentPayload ? paymentIdFromPayload(CHAIN_ID, ESCROW, paymentPayload) : null;
    log(`paid request, paymentId ${paymentId}`);
    events.emit("paid", { paymentId });
    // The seller's own copy of what it sent: status and sha256 of the exact bytes, so the court can
    // compare it with what a buyer later reports to /judge.
    if (paymentId) {
      const chunks = [];
      const write = res.write.bind(res), end = res.end.bind(res);
      res.write = (c, ...r) => { if (c) chunks.push(Buffer.from(c)); return write(c, ...r); };
      res.end = (c, ...r) => { if (c && typeof c !== "function") chunks.push(Buffer.from(c)); return end(c, ...r); };
      res.on("finish", () => events.emit("served", { paymentId, status: res.statusCode, bodySha256: "0x" + createHash("sha256").update(Buffer.concat(chunks)).digest("hex") }));
    }
    if (fileRequest && wallet && paymentId && kind !== "silent") {
      res.on("finish", async () => {
        try {
          const hash = await wallet.writeContract({
            address: VALIDATION, abi: VALIDATION_ABI, functionName: "validationRequest",
            args: [judge, BigInt(AGENTS[`seller-${kind}`]), `urn:delivery-court:${kind}:${paymentId}`, paymentId],
          });
          const r = await publicClient.waitForTransactionReceipt({ hash });
          log(`validationRequest ${hash} ${r.status}`);
          events.emit("requested", { paymentId, hash, status: r.status });
        } catch (e) {
          log(`validationRequest failed ${e.shortMessage ?? e.message}`);
          events.emit("requested", { paymentId, error: e.shortMessage ?? e.message });
        }
      });
    }
    await handlers[kind](req, res, ctx);
  });
  return { app, events, ctx };
}
