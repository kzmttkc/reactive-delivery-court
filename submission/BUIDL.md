# BUIDL draft (DoraHacks, Reactive Omni Buildathon)

Status: draft. Not submitted. Only the repository URL and the video URL are still `<TBD>`.
Every number below is from a run in the repo. Contracts, scenes and latency are the v2 pair deployed on 2026-11-22 (JST). The v1 pair is in docs/HISTORY.md. Character counts are in CHECKLIST.md. Limit for all fields together: 4,000.

## Name

Delivery Court

## One-liner

x402 pays before anyone looks. Delivery Court makes the money wait: a neural network judges the response, then Reactive pays the seller or refunds the buyer.

## Track

Reactive Meets AI

## Repository

<TBD: public GitHub URL>

## Demo video

<TBD: video URL, under 3:00>

## Deployed contracts

- DeliveryCourtReactive (Lasna): 0x7FeF8eAF662CFb82adaa1cA3E45821A866cC4D51
- DeliveryCourtCallback (Base Sepolia): 0xD80dfBa59a5930B943D0Eb5225E292B0ffB9D84a

## Transaction hashes (full loop, origin event to callback)

- Delivered, score 99, capture. Payment 0x3705f4307bfe8bf8477ff4dcce4cbe866ed3d44f76a64120e0187dd92f01cd5c, score 0xe85526853749719ce4d5190d41efc8db772842d13954f9b80aaad221f836f34a, react 0xb9ef16acdfa5f112c99e54039a2f80a47feeb52c992d6045e39b7a801dfeb7be, callback 0xb796e6e75349997d876a5c76353f4d003dde1b64637e88861b4314d283fbd465
- Empty 200 OK, score 0, refund. Payment 0xeedd718ccda44227ba32e920b8af5885220c744b49bf2b83549f260a666393c0, score 0xb4b5934e68f7f0e8ae39b1b5d5027739e6b9821fa7f0f3a8d09b93660a591acd, react 0xfd1476da24fdc01e675f276b6a95bedb1b3caf04febd383020f01f50d6e723e0, callback 0xfc6d9aad7a91fa2d62bd2780dc5b4118cb05c86a17bf44c4d93555cd7224ae42
- Silent seller, cron refund. Payment 0x8d56aefd4f4c5da8b80aaa7813d31468e8eec2f05dd7fb5736433dfce2600a51, cron react 0xf7f81584ceee2e3357050dd46ba0e4045ff583e26d6c151cb945ce707e26f3ad, callback 0xe4a424d02482f26c2f2c2dbe568a7bfb7cce76ace2e8217a4d645c321f830c76

## Description

<!-- DESCRIPTION START -->
vet402, my x402 buyer service, has paid sellers 15,128 times. 1,251 of those payments, about 1 in 12, never got a confirmed delivery. Every one settled anyway, because x402 pays before anyone reads the response.

Delivery Court makes the money wait for a verdict. The USDC goes into the official x402 auth-capture escrow. Two small neural networks read what came back. The lower score goes on chain (ERC-8004 validationResponse). A Reactive contract on Lasna reads it and calls back to Base Sepolia: 70 or more captures to the seller, below 70 voids to the buyer. No verdict by the deadline: a Reactive cron refunds the buyer. Silence and an empty body leave ERC-8004 feedback.

### A 200 is not a delivery

The metadata network gives 100 to an error JSON, an HTML 502 page, JSON cut after 60 bytes and `{"ok":true}` against the declared schema. The content network gives each 0. Held-out test, 822 real bodies from 225 hosts not seen in training: accuracy 0.985. A "non-empty JSON" rule: 0.866.

### What only Reactive does here

1. The judge never touches money. It writes a standard ERC-8004 validationResponse, holds no operator role, and its capture call reverts with NotAuthorized. Reactive turns the registry entry into a payment decision.
2. Nobody has to show up. Reactive joins the unmodified x402 escrow, the ERC-8004 registry and a timer. A permissionless settle() still needs someone awake with gas, and a silent seller writes nothing. The cron refunded that buyer 116 s after payment.
3. The judge can lower a score, never raise it. Reactive re-scores the committed facts and keeps the lower one. An empty body is 0 by its hash: the judge key wrote 99 for one, Reactive made it 0 and refunded.
Don't trust the judge: `node src/rejudge.mjs <score tx>` re-runs both networks on the public body and prints match.

### Judging criteria

1. Execution: three cases with origin, react and callback tx. Live: https://delivery-court.fly.dev, one click, every tx linked.
2. Integration: above. Without Reactive the score moves no money.
3. Usefulness: refunds for non-delivery with no bot or person holding the money. The body a buyer reports must match the seller's copy. Next, vet402 adds it to its x402 facilitator: checks a seller before you pay, refunds you after.
4. Craft: 123 Foundry tests (fuzzing, reentrancy, fork run), 25 off-chain tests with Python/JS model parity.

Data: vet402 public record, in production, Aug 23 to Nov 21, snapshot in the repo.
<!-- DESCRIPTION END -->
