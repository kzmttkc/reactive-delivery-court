#!/usr/bin/env python3
"""Prints the README table of the model-judged scenes from offchain/runs/*.json."""
import json, os

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
B, L = "https://sepolia.basescan.org/tx/", "https://lasna.reactscan.net/tx/"
NAMES = {
    "deliver": "Delivering seller (200, JSON body), capture",
    "empty": "Empty body (200, 0 bytes), refund and feedback",
    "silent": "Silent seller (no answer), cron refund",
}


def link(base, h):
    return f"[{h[:10]}…{h[-6:]}]({base}{h})" if h else "n/a"


def usdc(units):
    return f"{int(units) / 1e6:.2f}"


print("| Scene | x402 payment: `authorize` (Base Sepolia) | Deposited react (Lasna) | Seller request, model score (Base Sepolia) | Decision react (Lasna) | Callback (Base Sepolia) | Buyer / seller USDC before, held, after |")
print("|---|---|---|---|---|---|---|")
for k in ("deliver", "empty", "silent"):
    p = os.path.join(REPO, "offchain", "runs", f"{k}.json")
    if not os.path.exists(p):
        continue
    r = json.load(open(p))
    if r.get("judgment"):
        j = r["judgment"]
        judged = f"request {link(B, r['validationRequestTx'])}, score {j['score']} {link(B, j['tx'])}"
    else:
        judged = "n/a (no answer, no request)"
    action = "capture" if r["resolved"]["captured"] else ("void + ERC-8004 feedback" if r.get("feedbackGiven") else "void")
    held = r.get("whileHeld")
    bal = (f"{usdc(r['before']['buyerUsdc'])} / {usdc(r['before']['sellerUsdc'])}, "
           + (f"{usdc(held['buyerUsdc'])} / {usdc(held['sellerUsdc'])}, " if held else "n/a, ")
           + f"{usdc(r['after']['buyerUsdc'])} / {usdc(r['after']['sellerUsdc'])}")
    print(f"| {NAMES[k]} | {link(B, r['authorizeTx'])} | {link(L, r['depositedReactTx'])} | {judged} | "
          f"{link(L, r['decisionReactTx'])} | {action} {link(B, r['callbackTx'])} | {bal} |")
