// Who may hand the court a body for a payment: only the wallet that paid it.
// The payer signs (EIP-191 personal_sign) the line below with the key that signed the x402 payment.
// The server recovers the signer and compares it with Deposited.payer before it judges anything.
import { createHash } from "node:crypto";
import { verifyMessage } from "viem";

export const judgeMessage = (paymentId, body, status) =>
  `delivery-court:judge:${String(paymentId).toLowerCase()}:0x${createHash("sha256").update(body).digest("hex")}:${status}`;

/** true only when `signature` is `signer`'s signature over judgeMessage(paymentId, body, status). */
export async function signedBy({ signer, paymentId, body, status, signature }) {
  return payerSigned({ payer: signer, paymentId, body, status, signature });
}

/** true only when `signature` is the payer's signature over judgeMessage(paymentId, body, status). */
export async function payerSigned({ payer, paymentId, body, status, signature }) {
  if (!/^0x[0-9a-fA-F]{130}$/.test(String(signature ?? ""))) return false;
  try {
    return await verifyMessage({ address: payer, message: judgeMessage(paymentId, body, status), signature });
  } catch {
    return false;
  }
}

/** Fixed-window limit per caller (requests per minute). */
export function perMinuteLimit(max) {
  const hits = new Map();
  return (key) => {
    const minute = Math.floor(Date.now() / 60_000);
    const k = `${minute}:${key}`;
    const n = (hits.get(k) ?? 0) + 1;
    hits.set(k, n);
    if (hits.size > 10_000) for (const old of hits.keys()) if (!old.startsWith(`${minute}:`)) hits.delete(old);
    return n <= max;
  };
}
