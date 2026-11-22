#!/usr/bin/env python3
"""Trains the content model: an 18-8-1 tanh MLP in numpy over the bytes of the response body
(model/content_features.py), on the train hosts of model/content_data.py. Same optimizer, seed
and class balancing as train.py. Writes model/content_model.json and model/judge.json.

model/judge.json binds the two networks and the rule that combines them. Its sha256 is the
model version written in every judgment.
"""
import hashlib, json, os

import numpy as np

from content_data import SEED as DATA_SEED, HIDE_SCHEMA, SYNTH_KINDS, TEST_SHARE, load_rows, matrix
from content_features import CONTENT_FEATURES
from features import HERE, forward
from train import r8, train

THRESHOLD = 70


def write_json(path, obj):
    blob = (json.dumps(obj, sort_keys=True, separators=(",", ":")) + "\n").encode()
    with open(path, "wb") as f:
        f.write(blob)
    return hashlib.sha256(blob).hexdigest()


def main():
    rows = load_rows()
    tr = [r for r in rows if not r["test"]]
    X, y = matrix(tr)
    W1, b1, W2, b2 = train(X, y)
    src = json.load(open(os.path.join(HERE, "data", "BODIES_SOURCE.json")))
    model = {
        "name": "delivery-court-content-mlp",
        "architecture": f"{len(CONTENT_FEATURES)}-8-1, tanh hidden, sigmoid output, score = round(100 * p)",
        "features": CONTENT_FEATURES,
        "train": {"rows": len(tr), "real": sum(1 for r in tr if not r["synthetic"]),
                  "synthetic": sum(1 for r in tr if r["synthetic"]), "split": f"by seller host, {int(TEST_SHARE*100)}% of hosts held out",
                  "data_seed": DATA_SEED, "hide_schema_share": HIDE_SCHEMA, "synthetic_kinds": SYNTH_KINDS,
                  "class_weight": "balanced"},
        "bodies_sha256": src["sha256_of_jsonl"],
        "W1": r8(W1), "b1": r8(b1), "W2": r8(W2), "b2": r8(b2),
    }
    content_sha = write_json(os.path.join(HERE, "content_model.json"), model)
    meta_sha = hashlib.sha256(open(os.path.join(HERE, "model.json"), "rb").read()).hexdigest()
    judge = {
        "name": "delivery-court-judge",
        "metadata_model": {"file": "model/model.json", "sha256": meta_sha},
        "content_model": {"file": "model/content_model.json", "sha256": content_sha},
        "rule": "no response: score = metadata score. Otherwise score = min(metadata score, content score).",
        "threshold": THRESHOLD,
    }
    judge_sha = write_json(os.path.join(HERE, "judge.json"), judge)
    p = forward(model, X)
    print("content_model.json sha256", content_sha)
    print("judge.json sha256 (model version)", judge_sha)
    print("train rows", len(tr), "train accuracy at p>=0.70:", float(((p >= 0.70) == (y == 1)).mean()))


if __name__ == "__main__":
    main()
