#!/usr/bin/env python3
"""Balance watch for the court while the cron runs. Read-only, sends nothing.

Checks, for the deployed pair in deployments/v2.json:
  Lasna         DeliveryCourtReactive balance (pays react and cron), its debt at the system
                contract 0x...fffFfF (any debt stops react and callbacks), cronPaused
  Base Sepolia  callback reserve at the callback proxy (pays callback gas) and its debt there
Exits 1 and prints LOW / DEBT lines when a value crosses its limit, so a scheduler can alert
before the court goes quiet. Limits are env vars:
  MIN_REACTIVE_LREACT (default 1.0)   MIN_CALLBACK_RESERVE_ETH (default 0.0002)   MAX_OPEN_WINDOW (default 24)
It also prints the reactive queue length and the cron cursor, and alerts when more than MAX_OPEN_WINDOW
payments sit past the cursor (the cron scans 32).

  python3 scripts/watch-balances.py           # human readable
  python3 scripts/watch-balances.py --json    # one JSON line, for a log
"""
import json, os, sys, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEP = json.load(open(os.path.join(REPO, "deployments", "v2.json")))
LASNA = os.environ.get("LASNA_RPC_URL", "https://lasna-rpc.rnk.dev/")
BASE = os.environ.get("BASE_SEPOLIA_RPC_URL", "https://sepolia.base.org")
SYSTEM = "0x0000000000000000000000000000000000fffFfF"
PROXY = "0x476F44b11F5C942c58f4c8E3d0300E5710743585"
MIN_RC = float(os.environ.get("MIN_REACTIVE_LREACT", "1.0"))
MIN_CB = float(os.environ.get("MIN_CALLBACK_RESERVE_ETH", "0.0002"))
# The cron scans at most 32 queued payments past the first undecided one (MAX_SCAN). If that many stay open,
# later payments are not refunded by the cron (anyone can open a payment, README "Known limits").
MAX_OPEN_WINDOW = int(os.environ.get("MAX_OPEN_WINDOW", "24"))


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "delivery-court/1"})
    with urllib.request.urlopen(req, timeout=30) as r:
        out = json.load(r)
    if "error" in out:
        raise RuntimeError(out["error"])
    return out["result"]


def selector(sig):
    # keccak256 is not in the Python standard library. Fixed selectors, from `cast sig "<signature>"`.
    return {"debt(address)": "0x9b6c56ec", "reserves(address)": "0xd66bd524", "cronPaused()": "0xa237b668",
            "queueLength()": "0xab91c7b0", "cursor()": "0x36a0b9ef"}[sig]


def call(url, to, sig, addr=None):
    data = selector(sig) + (addr[2:].lower().rjust(64, "0") if addr else "")
    return int(rpc(url, "eth_call", [{"to": to, "data": data}, "latest"]), 16)


def main():
    rc, cb = DEP["reactive"]["address"], DEP["callback"]["address"]
    v = {
        "reactive": rc, "callback": cb,
        "reactive_lreact": int(rpc(LASNA, "eth_getBalance", [rc, "latest"]), 16) / 1e18,
        "reactive_debt_wei": call(LASNA, SYSTEM, "debt(address)", rc),
        "cron_paused": bool(call(LASNA, rc, "cronPaused()")),
        "callback_reserve_eth": call(BASE, PROXY, "reserves(address)", cb) / 1e18,
        "callback_debt_wei": call(BASE, PROXY, "debt(address)", cb),
        "queue_length": call(LASNA, rc, "queueLength()"),
        "cursor": call(LASNA, rc, "cursor()"),
    }
    alerts = []
    if v["reactive_lreact"] < MIN_RC:
        alerts.append(f"LOW reactive balance {v['reactive_lreact']:.4f} lREACT < {MIN_RC} (top up: send lREACT to {rc} on Lasna, then coverDebt())")
    if v["reactive_debt_wei"]:
        alerts.append(f"DEBT reactive {v['reactive_debt_wei']} wei at the system contract (react and cron are stopped until coverDebt())")
    if v["callback_reserve_eth"] < MIN_CB:
        alerts.append(f"LOW callback reserve {v['callback_reserve_eth']:.6f} ETH < {MIN_CB} (top up: depositTo({cb}) on the callback proxy)")
    if v["callback_debt_wei"]:
        alerts.append(f"DEBT callback {v['callback_debt_wei']} wei at the callback proxy")
    if v["queue_length"] - v["cursor"] > MAX_OPEN_WINDOW:
        alerts.append(f"QUEUE {v['queue_length'] - v['cursor']} payments past the cron cursor (> {MAX_OPEN_WINDOW}): the 32-payment cron window may be filling with far-dated payments")
    v["alerts"] = alerts
    if "--json" in sys.argv:
        print(json.dumps(v))
    else:
        print(f"Lasna  reactive {rc}: {v['reactive_lreact']:.4f} lREACT, debt {v['reactive_debt_wei']} wei, cron paused {v['cron_paused']}")
        print(f"Lasna  queue {v['queue_length']}, cron cursor {v['cursor']}")
        print(f"Base   callback {cb}: reserve {v['callback_reserve_eth']:.6f} ETH at the proxy, debt {v['callback_debt_wei']} wei")
        print("\n".join(alerts) if alerts else "OK, no alert")
    sys.exit(1 if alerts else 0)


if __name__ == "__main__":
    main()
