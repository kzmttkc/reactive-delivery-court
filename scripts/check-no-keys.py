#!/usr/bin/env python3
"""Fails if any testnet private key (parent or derived role) appears in the working tree,
the git index or any commit in history. Prints only counts, never the key values."""
import json, os, subprocess, sys

HOME = os.path.expanduser("~")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
keys = []
for f in ("chiangmai-testnet.json", "reactive-roles.json"):
    p = os.path.join(HOME, ".vet402-keys", f)
    if os.path.exists(p):
        keys += [k["private_key"].lower().removeprefix("0x") for k in json.load(open(p))["keys"]]
if not keys:
    sys.exit("no keys loaded, nothing checked")

hits = 0
# working tree (tracked and untracked, excluding node_modules, build output and .git)
skip = {".git", "node_modules", "out", "cache", "lib"}
files = 0
for root, dirs, names in os.walk(REPO):
    dirs[:] = [d for d in dirs if d not in skip]
    for n in names:
        try:
            data = open(os.path.join(root, n), "rb").read().lower()
        except OSError:
            continue
        files += 1
        hits += sum(1 for k in keys if k.encode() in data)
history = subprocess.run(["git", "-C", REPO, "log", "--all", "-p", "--no-color"], capture_output=True).stdout.lower()
hist_hits = sum(1 for k in keys if k.encode() in history)
print(f"keys checked {len(keys)}, files scanned {files}, working tree hits {hits}, history bytes {len(history)}, history hits {hist_hits}")
sys.exit(1 if hits or hist_hits else 0)
