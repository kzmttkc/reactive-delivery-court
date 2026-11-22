// Buyer agent: the official x402 client (@x402/fetch + @x402/evm auth-capture client scheme).
// It receives the 402, signs ERC-3009 ReceiveWithAuthorization for the escrow's token
// collector, retries with the payment header and records exactly what came back.
import { createPublicClient, http } from "viem";
import { baseSepolia } from "viem/chains";
import { wrapFetchWithPayment, x402Client } from "@x402/fetch";
import { toClientEvmSigner } from "@x402/evm";
import { AuthCaptureEvmScheme } from "@x402/evm/auth-capture/client";
import { BASE_RPC, CHAIN_ID, ESCROW, NETWORK } from "./config.mjs";
import { paymentIdFromPayload } from "./payment-id.mjs";
import { outputSchemaFrom } from "./content.mjs";

export function createBuyer(account) {
  const publicClient = createPublicClient({ chain: baseSepolia, transport: http(BASE_RPC) });
  const signer = toClientEvmSigner(account, publicClient);
  const client = new x402Client().register(NETWORK, new AuthCaptureEvmScheme(signer));
  let last = null;
  let required = null;
  client.onBeforePaymentCreation(async (ctx) => {
    required = ctx.paymentRequired;
  });
  client.onAfterPaymentCreation(async (ctx) => {
    last = ctx.paymentPayload;
  });
  const pay = wrapFetchWithPayment(fetch, client);

  /** Returns { paymentId, paymentPayload, outputSchema (declared in the 402, or null), response: {status, body, latencyMs, headers} | null, error } */
  async function buy(url, { timeoutMs = 20_000 } = {}) {
    last = null;
    required = null;
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), timeoutMs);
    const t0 = Date.now();
    try {
      const res = await pay(url, { signal: ac.signal });
      const body = Buffer.from(await res.arrayBuffer());
      clearTimeout(timer);
      return {
        paymentId: last ? paymentIdFromPayload(CHAIN_ID, ESCROW, last) : null,
        paymentPayload: last,
        outputSchema: outputSchemaFrom(required),
        response: { status: res.status, body, latencyMs: Date.now() - t0, headers: Object.fromEntries(res.headers) },
      };
    } catch (e) {
      clearTimeout(timer);
      return {
        paymentId: last ? paymentIdFromPayload(CHAIN_ID, ESCROW, last) : null,
        paymentPayload: last,
        outputSchema: outputSchemaFrom(required),
        response: null,
        error: ac.signal.aborted ? `no response within ${timeoutMs} ms` : String(e.message ?? e),
      };
    }
  }
  return { buy };
}
