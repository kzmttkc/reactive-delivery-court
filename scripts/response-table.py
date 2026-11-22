#!/usr/bin/env python3
"""Checks that the response body stored in the repo is the one the judge committed on chain.

For each scene in offchain/runs/<scene>.json with a judgment, reads the `validationResponse`
transaction from Base Sepolia, decodes responseURI and responseHash from its input, hashes the
stored body file and checks that the record file at responseURI exists. Prints the README table.
Exits 1 on any mismatch.
"""
import hashlib, json, os, sys, urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RPC = os.environ.get("BASE_SEPOLIA_RPC_URL", "https://sepolia.base.org")
SELECTOR = "validationResponse(bytes32,uint8,string,bytes32,string)"


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC, body, {"Content-Type": "application/json", "User-Agent": "delivery-court/1"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["result"]


def decode(inp):
    """ABI-decodes (bytes32, uint8, string, bytes32, string) from tx input."""
    data = bytes.fromhex(inp[2:])[4:]
    word = lambda i: data[32 * i: 32 * i + 32]
    def string_at(off):
        n = int.from_bytes(data[off: off + 32], "big")
        return data[off + 32: off + 32 + n].decode()
    return {"requestHash": "0x" + word(0).hex(), "score": int.from_bytes(word(1), "big"),
            "responseURI": string_at(int.from_bytes(word(2), "big")), "responseHash": "0x" + word(3).hex(),
            "tag": string_at(int.from_bytes(word(4), "big"))}


def main():
    ok = True
    print("| Scene | Body file in repo | sha256 of the file | `responseHash` in the judgment tx | `responseURI` in the judgment tx | Match |")
    print("|---|---|---|---|---|---|")
    for scene in ("deliver", "empty"):
        r = json.load(open(os.path.join(REPO, "offchain", "runs", f"{scene}.json")))
        j = r["judgment"]
        tx = rpc("eth_getTransactionByHash", [j["tx"]])
        d = decode(tx["input"])
        body_path = f"offchain/runs/{scene}.body"
        sha = "0x" + hashlib.sha256(open(os.path.join(REPO, body_path), "rb").read()).hexdigest()
        rec_path = os.path.join(REPO, d["responseURI"])
        rec = json.load(open(rec_path)) if os.path.exists(rec_path) else {}
        stored = os.path.join(REPO, rec.get("bodyFile", "missing"))
        sha2 = "0x" + hashlib.sha256(open(stored, "rb").read()).hexdigest() if os.path.exists(stored) else None
        match = (sha == d["responseHash"] == sha2 == rec.get("bodySha256") and d["requestHash"] == r["paymentId"]
                 and d["score"] == j["score"] == rec.get("score"))
        ok &= match
        short = lambda h: f"`{h[:10]}…{h[-6:]}`"
        print(f"| {scene} | [`{body_path}`]({body_path}) ({os.path.getsize(os.path.join(REPO, body_path))} bytes) | {short(sha)} | "
              f"{short(d['responseHash'])} ([tx](https://sepolia.basescan.org/tx/{j['tx']})) | [`{d['responseURI']}`]({d['responseURI']}) | "
              f"{'yes' if match else 'NO'} |")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
