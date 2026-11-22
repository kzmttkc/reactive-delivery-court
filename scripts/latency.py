#!/usr/bin/env python3
"""Latency from payment confirmation to callback confirmation, from the runs in offchain/runs/latency/.

Both ends are Base Sepolia block timestamps (the chain's clock, not the local clock):
  start = timestamp of the block that holds the x402 `authorize` (USDC enters escrow)
  end   = timestamp of the block that holds the Reactive callback (`Resolved`, capture or void)
Block timestamps are whole seconds, so each value has a 1 s resolution.

Reproduce: cd offchain && node src/run-scenes.mjs deliver --repeat 30 --out latency
           python3 scripts/latency.py      # writes offchain/runs/latency/summary.json
"""
import glob, json, math, os, statistics, sys, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RPC = os.environ.get("BASE_SEPOLIA_RPC_URL", "https://sepolia.base.org")
LASNA = os.environ.get("LASNA_RPC_URL", "https://lasna-rpc.rnk.dev/")


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "delivery-court/1"})
    for _ in range(4):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                out = json.load(r)
            if "result" in out:
                return out["result"]
        except Exception:
            pass
    raise SystemExit(f"RPC {method} failed on {url}")


def tx_block_ts(url, tx):
    rc = rpc(url, "eth_getTransactionReceipt", [tx])
    blk = rpc(url, "eth_getBlockByNumber", [rc["blockNumber"], False])
    return int(rc["blockNumber"], 16), int(blk["timestamp"], 16), rc["status"]


def p95(xs):
    s = sorted(xs)
    return s[math.ceil(0.95 * len(s)) - 1]  # nearest rank


def main():
    d = os.path.join(REPO, "offchain", "runs", "latency")
    runs = []
    for f in sorted(glob.glob(os.path.join(d, "deliver-*.json"))):
        r = json.load(open(f))
        ab, at, ast = tx_block_ts(RPC, r["authorizeTx"])
        cb, ct, cst = tx_block_ts(RPC, r["callbackTx"])
        _, ot, _ = tx_block_ts(LASNA, r["depositedReactTx"])
        _, dt, _ = tx_block_ts(LASNA, r["decisionReactTx"])
        runs.append({"run": r["run"], "paymentId": r["paymentId"], "score": r["judgment"]["score"],
                     "captured": r["resolved"]["captured"], "authorizeTx": r["authorizeTx"], "authorizeBlock": ab,
                     "authorizeTs": at, "callbackTx": r["callbackTx"], "callbackBlock": cb, "callbackTs": ct,
                     "authorizeStatus": ast, "callbackStatus": cst,
                     "seconds": ct - at, "lasnaOpenedTs": ot, "lasnaDecisionTs": dt})
    if not runs:
        sys.exit("no runs in offchain/runs/latency")
    secs = [r["seconds"] for r in runs]
    summary = {
        "measure": "Base Sepolia block timestamp of the callback minus that of the x402 authorize",
        "runs": len(runs),
        "all_captured": all(r["captured"] for r in runs),
        "all_status_success": all(r["authorizeStatus"] == "0x1" and r["callbackStatus"] == "0x1" for r in runs),
        "median_seconds": statistics.median(secs),
        "p95_seconds": p95(secs),
        "min_seconds": min(secs),
        "max_seconds": max(secs),
        "per_run": runs,
    }
    with open(os.path.join(d, "summary.json"), "w") as f:
        json.dump(summary, f, indent=2)
        f.write("\n")
    print(f"runs {summary['runs']}  median {summary['median_seconds']} s  p95 {summary['p95_seconds']} s  "
          f"min {summary['min_seconds']} s  max {summary['max_seconds']} s  all captured {summary['all_captured']}  "
          f"all status success {summary['all_status_success']}")


if __name__ == "__main__":
    main()
