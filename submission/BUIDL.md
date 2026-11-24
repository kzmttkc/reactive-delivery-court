# BUIDL draft (DoraHacks, Reactive Omni Buildathon)

Paste from `## Name` only. Do not paste lines 1–4.

Status: draft. Not submitted. The demo video is https://youtu.be/qbV-FGWv2bU (2:37).
Every number below is from a run in the repo. Contracts, scenes and latency are the v2 pair deployed on 2026-11-22 (JST). The v1 pair is in docs/HISTORY.md. Character counts are in CHECKLIST.md. Limit for all fields together: 4,000.

## Name

Delivery Court

## One-liner

x402 pays before anyone looks. On Base Sepolia testnet, Delivery Court holds USDC in escrow, a model judges the response, Reactive pays the seller or refunds the buyer.

## Track

Reactive Meets AI

## Repository

https://github.com/kzmttkc/reactive-delivery-court

## Demo video

https://youtu.be/qbV-FGWv2bU

## Deployed contracts

- DeliveryCourtReactive (Lasna): 0x7FeF8eAF662CFb82adaa1cA3E45821A866cC4D51
- DeliveryCourtCallback (Base Sepolia): 0xD80dfBa59a5930B943D0Eb5225E292B0ffB9D84a

## Transaction hashes (full loop, origin event to callback)

- Delivered, score 99, capture. Payment 0x3705f4307bfe8bf8477ff4dcce4cbe866ed3d44f76a64120e0187dd92f01cd5c, Deposited 0x9fa07f81…800afe, score 0xe85526853749719ce4d5190d41efc8db772842d13954f9b80aaad221f836f34a, react 0xb9ef16acdfa5f112c99e54039a2f80a47feeb52c992d6045e39b7a801dfeb7be, callback 0xb796e6e75349997d876a5c76353f4d003dde1b64637e88861b4314d283fbd465
- Empty 200 OK, score 0, refund. Payment 0xeedd718ccda44227ba32e920b8af5885220c744b49bf2b83549f260a666393c0, score 0xb4b5934e68f7f0e8ae39b1b5d5027739e6b9821fa7f0f3a8d09b93660a591acd, react 0xfd1476da24fdc01e675f276b6a95bedb1b3caf04febd383020f01f50d6e723e0, callback 0xfc6d9aad7a91fa2d62bd2780dc5b4118cb05c86a17bf44c4d93555cd7224ae42
- Silent seller, cron refund. Payment 0x8d56aefd4f4c5da8b80aaa7813d31468e8eec2f05dd7fb5736433dfce2600a51, cron react 0xf7f81584ceee2e3357050dd46ba0e4045ff583e26d6c151cb945ce707e26f3ad, callback 0xe4a424d02482f26c2f2c2dbe568a7bfb7cce76ace2e8217a4d645c321f830c76

## Description

<!-- DESCRIPTION START -->
vet402 has paid sellers 15,128 times (model/data/SOURCE.json 2026-11-21). 1,251 not delivered: 1,124 not_established (736 post-pay 4xx inconclusive per README) + 127 no_body_observed (~1 in 12). All settled anyway: x402 pays before anyone reads the response.

USDC sits in the official x402 escrow. Two networks score the response (ERC-8004). Reactive on Lasna callbacks Base: 70+ capture, below 70 void. No verdict by deadline: cron refunds. Silence and empty body leave ERC-8004 feedback.

### When 200 OK still fails delivery

Four bad 200 answers in metrics.json demo_inputs score metadata 100, content 0. Held-out: 822 bodies, 225 hosts, accuracy 0.9854 (metrics.json, 2026-11-21). 657 declared (README). JSON rule: 0.8662.

### What only Reactive does here

1. The judge never touches money. It only writes an ERC-8004 score, and its capture call reverts with NotAuthorized. Reactive turns the registry entry into a payment decision.
2. Nobody has to show up. A silent seller writes nothing. The cron refunded that buyer 116 s after payment. Cron resumes for judging (CHECKLIST). While paused, reclaim after the deadline refunds.
3. Reactive re-scores judge facts and keeps the lower score. Empty body scores 0 (sha256 of zero bytes, judge-99: judge 99, on chain 0). Wrong tag: `node src/rejudge.mjs` exits 1. Base Sepolia + Lasna testnet only.

### Judging criteria

1. Execution: three loops (README table, Deposited on deliver row). Live https://delivery-court.fly.dev deliver and empty buttons. Silent: hashes, /docket/, no third button. `cronPaused` until 2026-12-05 (CHECKLIST). Listed silent txs or resumed cron for Case 3.
2. Integration: above. Without Reactive the score moves no money.
3. Usefulness: empty and silent refund from escrow (116 s). Seller steps in docs/SELLER.md (owner registerSeller).
4. Craft: 123 Foundry + 26 off-chain tests. https://delivery-court.fly.dev/docket/ from public RPCs only.

MIT app code. reactive-lib-omni SPDX UNLICENSED upstream. Data: vet402 public record Aug 23 to Nov 21 in repo.
<!-- DESCRIPTION END -->
