#!/usr/bin/env python3
"""Trains the delivery model: a 10-8-1 tanh MLP in numpy, class-balanced, fixed seed.

Writes model/model.json (weights, feature list, split) and prints its sha256, which is the
model version hash the judge writes on chain. Run evaluate.py for the numbers.
"""
import hashlib, json, os

import numpy as np

from features import FEATURES, HERE, forward, load, time_split

SEED = 7
HIDDEN = 8
EPOCHS = 3000
LR = 0.05
L2 = 1e-4


def train(X, y):
    rng = np.random.default_rng(SEED)
    d = X.shape[1]
    W1 = rng.normal(0, 1 / np.sqrt(d), (d, HIDDEN))
    b1 = np.zeros(HIDDEN)
    W2 = rng.normal(0, 1 / np.sqrt(HIDDEN), (HIDDEN, 1))
    b2 = np.zeros(1)
    params = [W1, b1, W2, b2]
    m = [np.zeros_like(p) for p in params]
    v = [np.zeros_like(p) for p in params]
    pos = y.sum()
    w = np.where(y == 1, len(y) / (2 * pos), len(y) / (2 * (len(y) - pos)))
    w = w / w.sum()
    for t in range(1, EPOCHS + 1):
        _step(t, X, y, w, params, m, v)
    assert all(np.isfinite(p).all() for p in params), "non-finite weights"
    return params


def _step(t, X, y, w, params, m, v):
    W1, b1, W2, b2 = params
    with np.errstate(all="ignore"):  # spurious Accelerate matmul warnings, finiteness checked above
        h = np.tanh(X @ W1 + b1)
        p = 1 / (1 + np.exp(-(h @ W2 + b2)[:, 0]))
        g = (w * (p - y))[:, None]
        gW2 = h.T @ g + L2 * W2
        gb2 = g.sum(0)
        gh = (g @ W2.T) * (1 - h * h)
        gW1 = X.T @ gh + L2 * W1
        gb1 = gh.sum(0)
        for i, gr in enumerate([gW1, gb1, gW2, gb2]):
            m[i] = 0.9 * m[i] + 0.1 * gr
            v[i] = 0.999 * v[i] + 0.001 * gr * gr
            params[i] -= LR * (m[i] / (1 - 0.9**t)) / (np.sqrt(v[i] / (1 - 0.999**t)) + 1e-8)
    return params


def r8(a):
    return [float(f"{x:.8g}") for x in np.ravel(a)] if np.ndim(a) == 1 else [r8(row) for row in a]


def main():
    rows, X, y = load()
    cut, last_train, first_test = time_split(rows)
    W1, b1, W2, b2 = train(X[:cut], y[:cut])
    with open(os.path.join(HERE, "data", "SOURCE.json")) as f:
        src = json.load(f)
    model = {
        "name": "delivery-court-mlp",
        "architecture": "10-8-1, tanh hidden, sigmoid output, score = round(100 * p)",
        "features": FEATURES,
        "train": {"rows": cut, "until": last_train, "seed": SEED, "epochs": EPOCHS, "lr": LR, "l2": L2,
                  "class_weight": "balanced"},
        "test": {"rows": len(rows) - cut, "from": first_test},
        "data_sha256": src["sha256_of_kept_csv"],
        "W1": r8(W1), "b1": r8(b1), "W2": r8(W2), "b2": r8(b2),
    }
    blob = (json.dumps(model, sort_keys=True, separators=(",", ":")) + "\n").encode()
    with open(os.path.join(HERE, "model.json"), "wb") as f:
        f.write(blob)
    print("model.json sha256", hashlib.sha256(blob).hexdigest())
    p = forward(model, X[:cut])
    print("train accuracy at p>=0.70:", float(((p >= 0.70) == (y[:cut] == 1)).mean()))


if __name__ == "__main__":
    main()
