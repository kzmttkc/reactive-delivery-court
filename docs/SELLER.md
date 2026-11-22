# Put your x402 endpoint under Delivery Court (Base Sepolia testnet)

Two values in your 402 payment requirements decide where the money goes:
`payTo` is you, and `extra.captureAuthorizer` is the court callback. With
`captureMode: "deferred"` the USDC waits in the x402 `AuthCaptureEscrow`, and
only the court can capture it for you or void it back to the payer.

The court's owner has to register you first (`registerSeller(seller, agentId)`,
with your ERC-8004 agent id). `authorize` refuses unregistered sellers, amounts
under 0.001 USDC and an expiry more than 1 hour ahead.

```js
// x402 resource server route (same shape as offchain/src/seller.mjs paymentRequirements)
const COURT = "0xD80dfBa59a5930B943D0Eb5225E292B0ffB9D84a"; // DeliveryCourtCallback v2, Base Sepolia
const USDC = "0x036CbD53842c5426634e7929541eC2318f3dCF7e";  // Base Sepolia USDC

export const accepts = {
  scheme: "auth-capture",
  network: "eip155:84532",
  payTo: "0xYourSellerAddress",
  price: { amount: "10000", asset: USDC },   // 0.01 USDC
  maxTimeoutSeconds: 60,
  extra: {
    operatorType: "custom",
    captureAuthorizer: COURT,                // the only line that hands settlement to the court
    captureMode: "deferred",
    paymentFlow: "escrow",
    receiverAuthorizer: "0x0000000000000000000000000000000000000000",
    feeRecipient: "0x0000000000000000000000000000000000000000",
    minFeeBps: 0, maxFeeBps: 0,
    name: "USDC", version: "2",
    captureDeadlineSeconds: 600,             // no verdict by then: the Reactive cron returns the money
    refundDeadlineSeconds: 600,
  },
};
```

What you get paid for: a final score of 70 or more, the lower of the judge's
score in the ERC-8004 ValidationRegistry and the score the reactive contract
computes on chain from the facts the judge commits (body hash and the tag
`dc1:<status>:<bodyBytes>:<latencyMs>`). An empty or silent answer is voided
to the payer, and the void is recorded as ERC-8004 feedback against your agent.
A low score is refunded without feedback.

What happens after the response:

1. Your server signs what it sent, with the key of `payTo`, and returns it in the response header `x-delivery-court-signature`. The signed line (EIP-191 personal_sign) is
   `delivery-court:judge:<paymentId lowercase>:0x<sha256 of the exact body bytes>:<HTTP status>`
   (`offchain/src/judge-auth.mjs`, `judgeMessage`).
2. Your server files `validationRequest(judge, yourAgentId, <any URI>, paymentId)` on the ERC-8004 ValidationRegistry, naming the court's judge `0x5eC4599A438fA0559aDe8b8551b369D5c5aDF0bC`. The judge scores only payments that have this request.
3. The payer posts the authorize tx, the status, the exact bytes, its own signature over the same line and your `sellerSignature` to `https://delivery-court.fly.dev/judge` (`offchain/src/pay.mjs` does all of it and forwards your header). The court refuses the post unless both signatures match the same bytes, so neither side can report alone.

Not confirmed yet: which public facilitators settle `auth-capture` with a
custom operator. The demo uses its own facilitator on 127.0.0.1.
