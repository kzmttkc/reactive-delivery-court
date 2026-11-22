# Demo video script v2: "Delivery Court" (target 2:50, hard limit under 3:00)

Adopted from the external audit of 2026-11-22. Changes since: the live page now prints payment to settlement in block timestamps after each run (use that number for the stopwatch in Case 1), and `node src/rejudge.mjs <score tx>` exists, so an optional 5 s insert after Case 2 can show `on-chain 0 / recomputed 0 / match`. Since the v2 pair (deployed 2026-11-22): every tx below is from v2, Case 3 says "Under two minutes" (the recorded silent refund took 116 s), and the heist row adds the judge-99 scene (VOICE_SCRIPT R08).

Owner's own voice, no AI voice, subject "I" only. English narration. 1920x1080, 30 fps.
Arc (起承転結): 起 = the empty answer I paid for, 承 = the court and two ordinary verdicts, 転 = the seller goes silent and I walk away, then I try to cheat my own court, 結 = one line and the URL.
Every number on screen is from a repo file (sources at the bottom). Numbers measured on recording day (stopwatch block deltas) are read off the chain that day, not invented.

## Show moments (the three things a judge should remember)

1. **"I paid for this."** The cold open shows a real HTTP answer: `200 OK`, `content-length: 0`, with a register sound and `-0.01 USDC`.
2. **"I close my laptop."** The silent seller. A 90 s deadline counter runs, the laptop lid closes on camera (or the screen cuts to black with the sound of a lid), and the refund lands on Basescan with nobody online.
3. **"Even I can't steal it."** I call `courtCapture` from my own judge key on camera. It reverts: `NotAuthorized(0x5eC4…F0bC, 0x476F…8585)`. Checked on 2026-11-22 with `cast call` (an eth_call, no tx, no gas).

Extra motif: a courtroom. Each case gets a case card (`CASE 0xae71…` / `Buyer v. Seller`), a verdict card in large type (`PAID` green, `REFUNDED` red), and one short gavel knock under each verdict. Same three sounds all video: register (payment), tick (waiting), gavel (verdict). Nothing else.

## Storyboard

| Time | Screen | Narration (English, spoken) | On-screen text | Sound / pacing |
|---|---|---|---|---|
| 0:00-0:05 | Black. A terminal line types itself: `HTTP/1.1 200 OK` then `content-length: 0`. A small red counter `-0.01 USDC` appears top right. | "My agent just paid for this." (pause 0.5 s) "It's empty." | `HTTP/1.1 200 OK` / `content-length: 0` / `-0.01 USDC` | Silence, then the register sound on "paid". Dead stop after "empty". |
| 0:05-0:17 | Hard cut to one huge number on white: `1 in 12` (small `about` above it). Under it, small: `1,251 of 15,128 settled x402 payments in production never got a confirmed delivery. vet402 public record, Aug 23 to Nov 21, 2026, read 2026-11-21 12:22 UTC.` | "I run vet402. It has paid x402 sellers fifteen thousand times. About one payment in twelve never got a confirmed delivery. The money left anyway. x402 pays before anyone looks." | `1 in 12` | Each sentence on its own beat. No music yet. |
| 0:17-0:22 | Title card. Black, white type. | "So I built a court." | `DELIVERY COURT` / `The money waits for the verdict.` | Gavel knock on "court". |
| 0:22-0:47 | Four-box diagram builds left to right, one box per sentence: `Escrow (Base Sepolia)` → `Two neural networks` → `Reactive contract (Lasna)` → `Callback: pay or refund`. A red padlock sits on the escrow. | "The payment goes into the official x402 escrow, not to the seller. Two small neural networks read what came back. Their score goes on chain. A Reactive contract on Lasna reads the score and calls back. Seventy or more, the seller is paid. Below seventy, the buyer gets the money back. The model only proposes a score. Only the Reactive callback can move the money. Not the model. Not me." | Box labels only. Under the last box: `score ≥ 70 → seller` / `score < 70 → buyer` | Soft low tick starts (waiting motif). |
| 0:47-1:15 | **Case 1, live.** Split screen. Left: https://delivery-court.fly.dev, press "Pay a seller that delivers", steps tick in. Right: a big stopwatch driven by block timestamps (start at the authorize block, stop at the callback block, values filled in post from the run's `/runs/<id>`). Case card top left. | "Case one. A seller that delivers. I press the button. The payment is held. The model reads the answer. Ninety-nine." (beat) "Paid." "Block to block, about [N] seconds. Over thirty runs, the median is five." | `CASE 1  Buyer v. Seller` / `SCORE 99` / verdict card `PAID` / `[N] s (block timestamps)` / `median 5 s · p95 12 s · 30 runs` | Gavel on "Paid". Stopwatch freezes with a click. |
| 1:15-1:45 | **Case 2.** Press "Pay a seller that sends an empty answer (refund)". Then a fast 4-row "lie detector" table slides in, one row per 1.5 s: `error JSON`, `HTML 502 page`, `JSON cut at 60 bytes`, `{"ok":true} vs schema`. Two columns: `metadata 100` (grey) and `content 0` (red). Then the void callback on Basescan with the USDC transfer back to the buyer and the ERC-8004 feedback log. | "Case two. A seller that answers 200 OK, with nothing inside. A status code says delivered. The second network reads the body. Zero." "Refunded." "Here are four more ways to lie with a 200. The first network says one hundred. The second says zero. Every one gets refunded, and the seller gets a review on chain." | `CASE 2` / `SCORE 0` / `REFUNDED` / table headers `metadata` `content` | Gavel on "Refunded". Table rows tick in on beat. |
| 1:45-2:20 | **Case 3 (turn).** A buyer pays the silent seller (terminal, `node src/run-scenes.mjs silent`). A large counter starts at `90` and counts down, sped up 4x after the first 5 s. At ~1:55 the laptop lid closes on camera (phone camera shot of the laptop, 2 s), or the screen cuts to black with a lid sound. Black for 2 s with only the ticking. Then reopen on Reactscan: the cron react, then Basescan: the void callback, buyer balance back to before. | "Case three. The worst one. The seller takes the money and goes silent. No answer. No score." (beat) "And I close my laptop." (black) "Nobody is watching. Nobody has to." (reopen) "Reactive's cron wakes up after the deadline and refunds the buyer. Under two minutes after the payment. Nobody was online." | `CASE 3  The seller went silent` / countdown `90 → 0` / `REFUNDED` / `116 s after payment, nobody online` | Ticking only. Full silence during black. Gavel on "refunds". |
| 2:20-2:38 | **The heist.** Terminal, large font: `cast call <court> "courtCapture(...)" ... --from 0x5eC4…F0bC` (the judge key). Enter. Red: `execution reverted` → decoded `NotAuthorized(0x5eC4…F0bC, 0x476F…8585)`. Then 2 s on `src/CourtCallbackBase.sol` lines 96-118 with `onlyCallbackSender(reactiveSender)` highlighted. Then the judge-99 scene (recorded, `offchain/runs/judge99.json`): Basescan, the judge's `validationResponse` with score 99 for an empty body, then Reactscan, the decision react with `ScoreChecked(99, 0, 0, 1)`, then Basescan, the void callback. | "Could I cheat? I hold the judge key. Let me try to take the money myself." (enter) "Reverted. Only the Reactive callback can move it." (beat) "And if the judge calls an empty body ninety-nine, the Reactive contract scores it again on chain. Zero." "The model proposes. The contract commits." | `I hold the judge key.` / `NotAuthorized` / `only the Reactive callback can move the money` / `judge 99 → on chain 0` / `REFUNDED` / `recorded 2026-11-22` | Short buzzer on the revert (the only time it is used). |
| 2:38-2:50 | **Close.** Back to the four boxes, shrunk. Then end card: name, URL, repo, two addresses small. | "vet402 checks a seller before you pay. Delivery Court gets your money back after." | `DELIVERY COURT` / `delivery-court.fly.dev` / `github.com/<TBD>` / `Reactive Omni Buildathon · Reactive Meets AI` | One final gavel. Hold end card 3 s. |

Spoken words: about 308 (counted from the narration column, with the judge-99 sentence). That is about 109 words a minute over 2:50: slower than normal speech (130 to 150), so the pauses fit. The current script has 195 words in 2:45. If the first take runs long, cut from the diagram block (0:22-0:47) first. Hard check: `ffprobe -v error -show_entries format=duration -of csv=p=0 <file>` must be under 180.

## If live recording of a scene fails

- Case 1 and 2: use the README scene tx (deliver callback 0xb796e6e7…fbd465, empty callback 0xfc6d9aad…24ae42) in place of the live page and drop the stopwatch number `[N]`, keep "median 5 s".
- Case 3 needs the cron running. On recording day: `resumeCron`, run the silent scene, `pauseCron` (about 10 minutes of cron, about 0.07 lREACT at the measured 10.2 lREACT/day). If not possible, show the recorded silent scene (payment 0x8d56aefd…600a51, cron react 0xf7f81584…26f3ad, void 0xe4a424d0…830c76) and say "This is the recorded run" on screen.
- The judge-99 scene is always the recorded one (payment 0x7436f196…15b624, judge score 99 0x6eb358f6…63255e, decision react 0x1b343ecc…739b90, void 0xbc05ddb3…b7b417).
- Do not claim "live" on any shot that is a replay. Put `recorded 2026-11-21` on the replayed Case 1 to 3 shots (block times 2026-11-21 23:48 UTC) and `recorded 2026-11-22` on the judge-99 shots (2026-11-22 00:10 UTC).

## Recording tips

- Record each row as its own clip. Narration recorded separately in a quiet room, phone mic close, then laid over the clips. Cut on the words.
- Browser at 125% zoom, a clean profile, no extensions, no bookmarks bar. Dark terminal with 28 px font for the cold open and the heist.
- Hashes: never read aloud. Show the first 6 and last 4 characters large, the full hash small.
- The stopwatch: compute `[N]` from the run's authorize and callback block timestamps (the same method as `scripts/latency.py`). The 2026-11-22 production runs on the v2 pair gave 8 s for the delivering seller and 8 s for the empty seller. The page's wall clock can run longer than the block delta (14 s against 8 s in a v1 test run), so say "block to block", never "from click".
- Captions burned in (many judges watch muted). One line, max 42 characters.
- Thumbnail and the first frame: the same image (see below). YouTube "unlisted" is fine for judges, but check it plays logged out.
- Before upload: watch it once muted, once audio-only. If either fails to tell the story, fix that shot.

## Title card and thumbnail

- Title card (0:17): black, white type, `DELIVERY COURT`, under it `The money waits for the verdict.` A thin gavel line icon left of the name.
- Thumbnail (1280x720): left half `200 OK  content-length: 0` in terminal green on black, right half a red stamp `REFUNDED`. Top: `About 1 in 12 x402 payments never got a confirmed delivery`. Bottom right small: `Reactive × AI`.
- YouTube title: `Delivery Court: a neural network judges x402 payments, Reactive pays or refunds (Reactive Omni Buildathon)`.

## Sources of on-screen numbers

| On screen | Source |
|---|---|
| 1 in 12, 1,251 of 15,128, Aug 23 to Nov 21 | `model/data/delivery.csv.gz`, `model/data/SOURCE.json` (snapshot 2026-11-21 12:22 UTC). 1,251/15,128 = 8.27 % |
| score 99 / 0, threshold 70 | `offchain/runs/deliver.json`, `empty.json` |
| metadata 100 / content 0 on four 200 answers | `model/metrics.json` `demo_inputs` |
| median 5 s, p95 12 s, 30 runs | `offchain/runs/latency/summary.json` |
| 116 s silent refund ("Under two minutes") | `offchain/runs/silent.json` blocks 61915230 → 61915807, timestamps 1795304914 → 1795305030 |
| judge 99 → on chain 0, reason 3 | `offchain/runs/judge99.json` |
| deadline 90 s | `offchain/src/config.mjs` line 31 `deadlineSeconds: 90` |
| NotAuthorized | eth_call on 2026-11-22, revert data `0xc55ddc97…` |
