#!/usr/bin/env node
// Pay a Delivery Court seller with your own Base Sepolia wallet, then hand the court what you got.
//   BUYER_PRIVATE_KEY=0x... node src/pay.mjs https://<server>/deliver/resource
// The wallet needs 0.01 Base Sepolia USDC. It pays no gas (the facilitator relays the authorize).
// After the paid request it posts the authorize tx, the HTTP status and the exact body to
// <server>/judge and prints each court step as it confirms.
import { privateKeyToAccount } from "viem/accounts";
import { createBuyer } from "./buyer.mjs";
import { judgeMessage } from "./judge-auth.mjs";

const url = process.argv[2];
if (!url) { console.error("usage: BUYER_PRIVATE_KEY=0x... node src/pay.mjs <seller URL>"); process.exit(2); }
const account = process.env.BUYER_PRIVATE_KEY
  ? privateKeyToAccount(process.env.BUYER_PRIVATE_KEY)
  : (await import("./keys.mjs")).roleAccount("buyer"); // the project's own testnet buyer, for local checks
const origin = new URL(url).origin;
const log = (...m) => console.log(new Date().toISOString().slice(11, 19), ...m);

const bought = await createBuyer(account).buy(url, { timeoutMs: 20_000 });
if (!bought.paymentId) { console.error("no payment was made:", bought.error); process.exit(1); }
log(`paid, paymentId ${bought.paymentId}, got ${bought.response ? `${bought.response.status}, ${bought.response.body.length} bytes` : bought.error}`);
const pr = bought.response?.headers["payment-response"];
const authorizeTx = pr ? JSON.parse(Buffer.from(pr, "base64").toString("utf8")).transaction : null;
if (!authorizeTx) { console.error("no authorize tx in the PAYMENT-RESPONSE header. The payment returns to you after the deadline."); process.exit(1); }
const res = await fetch(`${origin}/judge`, {
  method: "POST", headers: { "content-type": "application/json" },
  body: JSON.stringify({
    authorizeTx, status: bought.response.status, bodyBase64: bought.response.body.toString("base64"), latencyMs: bought.response.latencyMs,
    // Only the payer may report what arrived: sign the exact bytes with the paying key.
    signature: await account.signMessage({ message: judgeMessage(bought.paymentId, bought.response.body, bought.response.status) }),
  }),
});
const j = await res.json();
if (res.status !== 202) { console.error("judge refused:", j.error); process.exit(1); }
const seen = new Set();
for (;;) {
  const r = await (await fetch(`${origin}/runs/${j.run}`)).json();
  for (const [k, v] of Object.entries(r.steps ?? {})) if (!seen.has(k)) { seen.add(k); log(k, v); }
  if (r.status === "done") { log(r.resolved.captured ? `seller paid, score ${r.score}` : `refunded to you, score ${r.score}`, r.responseURI); break; }
  if (r.status === "failed") { console.error("stopped:", r.error); process.exit(1); }
  await new Promise((s) => setTimeout(s, 3000));
}
