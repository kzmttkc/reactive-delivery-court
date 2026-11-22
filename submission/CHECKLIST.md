# Pre-submission checklist

Source of the rules: dorahacks.io/hackathon/reactive-omni-buildathon/detail and /tracks, read on Nov 21, 2026 (JST).
Deadline: 2026-12-05 20:00 UTC (2026-12-06 05:00 JST).

Status on Nov 21, 2026 is in the right column. Re-check every line on the day of submission.

## Order on submission day

Do these in this order. Each step needs the one before it.

1. Public repo. Create it, push, open the URL logged out (row 1 below).
2. The two `<TBD>` in BUIDL.md: the repo URL, then the video URL after step 4. Recount the characters (section "Text").
3. `setAgentURI` for agents 10798, 10799 and 10801 (section "Seller agentURI after the repo is public"). Needs the public URL from step 1.
4. Video. Record from `VIDEO_SCRIPT.md`, check under 180 s with `ffprobe`, upload, put the URL in BUIDL.md.
5. `resumeCron` on the v2 reactive contract (section "Keep the court running on submission day"). Fuel plan, re-done on Nov 22: the v1 cron cost 10.2 lREACT a day (measured), and the v2 tick is assumed similar until measured. On Nov 22 the v2 reactive contract holds 157.76 lREACT (funded 150 from the deployer, tx 0x6d369fa1cafcac2b573218ac95ae5b78351dc4e445f6450ddbe3cdf0999e3411) and the deployer keeps 30.9. Judging starts after the Dec 5 deadline, so resume the cron on Dec 5: 188 lREACT cover about 18 days, to about Dec 23. The deployer's remaining 0.58 Sepolia ETH turns into about 58 lREACT at the faucet (1 ETH gives 100 lREACT, https://dev.reactive.network/debugging), which reaches about Dec 28. The live server and Fly run to Dec 31. Live runs cost about 0.03 lREACT each. While the cron is paused, a payment nobody judges is refunded by the buyer's own reclaim after the deadline (README).
6. Blockscout. Re-check `is_verified` for the v2 callback (section "Callback source on Blockscout"). It was true on Nov 22, and Sourcify is a match.
7. Submit the BUIDL on DoraHacks (owner).

## Live server

`https://delivery-court.fly.dev` (Fly app `delivery-court`, nrt, shared-cpu-1x 512MB, 1 GB volume `court_data`). On submission day: `curl -sL https://delivery-court.fly.dev/health` shows `"ok":true` and `"low":[]`, then press the button once on the page and see "Done. The seller was paid 0.01 USDC." Stop on 2027-01-01: `flyctl scale count 0 -a delivery-court --yes`.

## Required by the event

| # | Item | How to check | Status on Nov 21 |
|---|---|---|---|
| 1 | Repository is public | `gh repo view <owner>/reactive-delivery-court --json visibility` shows PUBLIC, and the URL opens while logged out | No remote configured yet |
| 2 | Repository is open source | A `LICENSE` file at the root. README "License" section | MIT `LICENSE` at the root (Nov 21) |
| 3 | Dependency licenses allow publishing | `grep -rl UNLICENSED lib/reactive-lib-omni/src` | 8 files in `lib/reactive-lib-omni/src` are UNLICENSED. It is a git submodule of the upstream repo (not vendored). Upstream has no LICENSE file, no license on GitHub, no license line in its README. Noted in README. Owner decision |
| 4 | Built during the event | Commit history starts on or after 2026-11-05 | First commits on Nov 21, 2026 |
| 5 | Deployed contract addresses listed | Every address in BUIDL.md matches README and the chain explorer | v2 pair (deployed Nov 22) listed in BUIDL.md and README. v1 pair only in docs/HISTORY.md |
| 6 | Full-loop tx hashes | Each scene has origin event, reactive tx and callback tx, all status success | Three scenes on the v2 pair (2026-11-21 23:48 UTC, Nov 22 JST): deliver capture reason 0, empty void reason 3, silent cron void reason 2. Records `offchain/runs/deliver.json`, `empty.json`, `silent.json`. Re-run `scripts/check-receipt.py` on the day |
| 7 | Demo video under 3:00 | `ffprobe -v error -show_entries format=duration -of csv=p=0 <file>` under 180 | Not recorded |
| 8 | AI is part of the running system | The scene tx show the score written by the model validator address, and the model version hash is recorded | Judge role 0x5eC4…F0bC writes the scores. Record at each `responseURI` carries model `sha256:71d5a109…4d90250` |
| 9 | Timers use timestamps on Base Sepolia | `grep -rn block.number src/` returns nothing used as a deadline | 0 hits (Nov 21). Latency is also measured in block timestamps |

## Addresses to confirm on the explorers

| Name | Chain | Address |
|---|---|---|
| DeliveryCourtReactive | Lasna | 0x7FeF8eAF662CFb82adaa1cA3E45821A866cC4D51 (deploy tx 0x9a95a0485d024b73e4cbe75de27897a40acc6fd1f013fb4b174ae8462c6b330c) |
| DeliveryCourtCallback | Base Sepolia | 0xD80dfBa59a5930B943D0Eb5225E292B0ffB9D84a (deploy tx 0xb6a8bfbc65fc07f99004ce5fac9a58bb95a9b72428dc73f86d2d2fda92ff2f47. Sourcify match, Blockscout `is_verified: true` on Nov 22) |
| Model validator (judge role) | Base Sepolia | 0x5eC4599A438fA0559aDe8b8551b369D5c5aDF0bC |
| Seller agents | Base Sepolia | seller-deliver 0xF98F6b4D8f1a5A03271bBf2bee23236737D9EC31 (ERC-8004 agent 10798), seller-empty 0x8Dba1A8aeD6Ab7F1e2037bfC295f3a0A00BE072F (agent 10799), seller-silent 0x4151f916c1bd18dF1324Fa0Edd9F8Fa5bA8AD0F2 (agent 10801, registered in 0x5c987c07fc194843120cb662687958a6808929356d9bf7fb17e1b26e2517781e). All three registered on the v2 callback |
| AuthCaptureEscrow v1.1 (external) | Base Sepolia | 0xf96815976523E00e65Be8f34cA5e64b4f41EB19c |
| ERC-8004 ValidationRegistry (external) | Base Sepolia | 0x8004Cb1BF31DAf7788923b405b754f57acEB4272 |

## tx status

For each hash in BUIDL.md, run `cast receipt <hash> status --rpc-url https://sepolia.base.org` (Base Sepolia) or open it on lasna.reactscan.net. All must be `1` or success. The repo has `scripts/check-receipt.py` for the Base Sepolia side.

## Text

| Item | How to check | Limit |
|---|---|---|
| Description length | Count from `## Name` to the end of BUIDL.md: drop the `## ` heading lines and HTML comments, keep blank lines (all fields), then add the length of the `## ` heading lines. The description alone is the text between `DESCRIPTION START` and `DESCRIPTION END` | 4,000 for all fields together. Nov 22 after the final re-score, repo URL filled: description 2,346, all fields 3,717, 3,864 counting the field headings. The video placeholder is 28 characters, the same as a `https://youtu.be/<id>` URL (a `watch?v=` URL adds 15), so about 3,864 to 3,879 with headings. |
| Banned in English | `grep -n -i -w -E 'w[e]|o[u]r|u[s]' submission/*.md`, and grep for the em dash and the semicolon characters | 0 hits |
| First line | Read only line 1 of the description. Does it make a judge read line 2 | Yes |
| No relative time | No "yesterday", "3 days ago" | 0 |
| Numbers | Every number in the description is from a run in the repo or re-measured on submission day | Only the repo and video URLs are `<TBD>` |
| Line numbers and links | Open each link from a logged-out browser on the default branch | All open |

## Keep the court running on submission day

1. `python3 scripts/watch-balances.py` shows no alert: reactive lREACT above 1.0, debt 0 at the Lasna system contract, callback reserve above 0.0002 ETH, debt 0 at the callback proxy. It reads the v2 pair from `deployments/v2.json`. On Nov 22 the v2 cron is paused (`cronPaused` true).
2. Top up if low (README, "Keeping the court running").
3. `resumeCron` from the deployer: `node scripts/with-evm-key.mjs deployer forge script script/Stage0.s.sol:Stage0 --sig "resumeCron(address)" 0x7FeF8eAF662CFb82adaa1cA3E45821A866cC4D51 --rpc-url https://lasna-rpc.rnk.dev/ --broadcast`
4. Run the watch every 30 minutes until judging ends and act on exit 1.

## Callback source on Blockscout

The v2 callback is verified: `https://base-sepolia.blockscout.com/api/v2/addresses/0xD80dfBa59a5930B943D0Eb5225E292B0ffB9D84a` showed `"is_verified": true` on Nov 22, and Sourcify gives `match` for creation and runtime (`https://sourcify.dev/server/v2/contract/84532/0xD80dfBa59a5930B943D0Eb5225E292B0ffB9D84a`). Re-check both on submission day. The v1 callback's verification history is in docs/HISTORY.md.

## Seller agentURI after the repo is public

Done 2026-11-22 (UTC 00:4x): the repo is public at https://github.com/kzmttkc/reactive-delivery-court and the three agents point at its registration files. setAgentURI: 10798 tx 0xfb66ce41690042b48ad1279d4a72ed2fbe84b0d35746d243ecbb1dd5fbbdb399, 10799 tx 0x09adac163c9df55e4534c0af7925d61faf2846b8d44d63c8f50e80efc160292e, 10801 tx 0xa952b6de7aec67b2c815f5c1e4284f3f44c5b93fc8aa2063bd165cce0271c497 (all status 1). tokenURI of each returns the raw URL of agents/<name>.json, which answers 200.


The registration files are in the repo: `agents/seller-deliver.json` (agent 10798), `agents/seller-empty.json` (agent 10799), `agents/seller-silent.json` (agent 10801, the silent seller, registered in 0x5c987c07fc194843120cb662687958a6808929356d9bf7fb17e1b26e2517781e). Agents 10798 and 10799 still point at URLs that do not exist (`https://github.com/delivery-court/agents/seller-deliver.json`, `https://github.com/delivery-court/agents/seller-empty.json`). Read the current value of each with `cast call 0x8004A818BFB912233c491871b3d84c89A494BD9e "tokenURI(uint256)(string)" <id> --rpc-url https://sepolia.base.org`.

Once `github.com/kzmttkc/reactive-delivery-court` is public with these files on `main`, send one tx per agent from its owner (the seller role):

| Agent | Owner role | URL |
|---|---|---|
| 10798 | seller-deliver | `https://raw.githubusercontent.com/kzmttkc/reactive-delivery-court/main/agents/seller-deliver.json` |
| 10799 | seller-empty | `https://raw.githubusercontent.com/kzmttkc/reactive-delivery-court/main/agents/seller-empty.json` |
| 10801 | seller-silent | `https://raw.githubusercontent.com/kzmttkc/reactive-delivery-court/main/agents/seller-silent.json` |

1. Open each URL logged out and check it serves the JSON.
2. For each row: `node scripts/with-evm-key.mjs <owner role> sh -c 'cast send 0x8004A818BFB912233c491871b3d84c89A494BD9e "setAgentURI(uint256,string)" <agent> "<URL>" --private-key $EVM_PRIVATE_KEY --rpc-url https://sepolia.base.org'`
3. Check each with `tokenURI` above and `cast receipt <hash> status`.

`setAgentURI(uint256,string)` (selector 0x0af28bd3) is present in the IdentityRegistry implementation 0x7274e874ca62410a93bd8bf61c69d8045e399c02 (checked Nov 21). Not sent yet.

## Owner steps (not done by the agent)

- Create the public repo and push
- Record the video and upload it
- Log in to DoraHacks and submit the BUIDL
