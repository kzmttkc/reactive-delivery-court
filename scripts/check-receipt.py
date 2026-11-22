#!/usr/bin/env python3
"""Relayer post-check: reads a Base Sepolia receipt and lists the events Delivery Court cares about."""
import json, subprocess, sys
tx, rpc = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "https://sepolia.base.org"
def keccak(sig): return subprocess.check_output(["cast", "keccak", sig], text=True).strip()
names = {
    keccak("PaymentAuthorized(bytes32,(address,address,address,address,uint120,uint48,uint48,uint48,uint16,uint16,address,uint256),uint256,address)"): "PaymentAuthorized",
    keccak("PaymentCaptured(bytes32,uint256,uint256,address)"): "PaymentCaptured",
    keccak("PaymentVoided(bytes32,uint256)"): "PaymentVoided",
    keccak("Deposited(bytes32,address,address,uint256,uint48)"): "Deposited",
    keccak("Resolved(bytes32,bool,uint256,uint8,uint8)"): "Resolved",
    keccak("FeedbackGiven(bytes32,uint256,uint8)"): "FeedbackGiven",
    keccak("FeedbackSkipped(bytes32,uint256)"): "FeedbackSkipped",
    keccak("Transfer(address,address,uint256)"): "Transfer",
    keccak("ValidationRequest(address,uint256,string,bytes32)"): "ValidationRequest",
    keccak("ValidationResponse(address,uint256,bytes32,uint8,string,bytes32,string)"): "ValidationResponse",
}
r = json.loads(subprocess.check_output(["cast", "receipt", tx, "--json", "-r", rpc], text=True))
print("status", int(r["status"], 16), "block", int(r["blockNumber"], 16), "gasUsed", int(r["gasUsed"], 16))
for lg in r["logs"]:
    n = names.get(lg["topics"][0], lg["topics"][0][:10])
    extra = ""
    if n == "Transfer" and len(lg["topics"]) == 3:
        extra = f'from=0x{lg["topics"][1][-40:]} to=0x{lg["topics"][2][-40:]} value={int(lg["data"],16)}'
    elif len(lg["topics"]) > 1:
        extra = "topic1=" + lg["topics"][1]
    print(f'  {lg["address"]} {n} {extra}')
