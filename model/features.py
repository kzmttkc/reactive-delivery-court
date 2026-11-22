"""Feature extraction shared by train.py and evaluate.py. offchain/src/model.mjs mirrors it.

Only features that exist both in the public vet402 record and in a live x402 response:
HTTP status class of the paid request, body size, body non-empty, latency.
The public record has no body content, so JSON validity, content type and byte
distribution are not features (see README, "Model limits").
"""
import csv, gzip, math, os

import numpy as np

FEATURES = [
    "status_2xx_not_202", "status_202", "status_3xx", "status_4xx", "status_5xx", "status_none",
    "body_bytes_known", "log1p_body_bytes_div10", "body_non_empty", "log1p_latency_ms_div10",
]
HERE = os.path.dirname(os.path.abspath(__file__))


def featurize(status, body_bytes, non_empty, latency_ms):
    """status: int or None. body_bytes: int or None. non_empty: bool or None. latency_ms: number or None."""
    v = [0.0] * len(FEATURES)
    if status is None:
        v[5] = 1.0
    elif 200 <= status < 300:
        v[1 if status == 202 else 0] = 1.0
    elif 300 <= status < 400:
        v[2] = 1.0
    elif 400 <= status < 500:
        v[3] = 1.0
    else:
        v[4] = 1.0
    if body_bytes is not None:
        v[6] = 1.0
        v[7] = math.log1p(max(body_bytes, 0)) / 10.0
    if non_empty is None:
        non_empty = body_bytes is not None and body_bytes > 0
    v[8] = 1.0 if non_empty else 0.0
    if latency_ms is not None:
        v[9] = math.log1p(max(latency_ms, 0)) / 10.0
    return v


def _int(s):
    return int(s) if s not in ("", None) else None


def row_features(r):
    ne = r["payload_non_empty"]
    non_empty = True if ne == "true" else False if ne == "false" else None
    return featurize(_int(r["http_status_paid"]), _int(r["body_bytes"]), non_empty, _int(r["latency_ms"]))


def load(path=None):
    path = path or os.path.join(HERE, "data", "delivery.csv.gz")
    with gzip.open(path, "rt") as f:
        rows = list(csv.DictReader(f))
    rows.sort(key=lambda r: (r["attempted_at"], r["purchase_id"]))
    X = np.array([row_features(r) for r in rows], dtype=np.float64)
    y = np.array([1.0 if r["delivery"] == "delivered" else 0.0 for r in rows])
    return rows, X, y


def time_split(rows, frac=0.8):
    """Train on the earliest 80% by attempted_at, test on the latest 20%. No row of the test
    period is seen in training, so the score cannot use later information."""
    cut = int(len(rows) * frac)
    return cut, rows[cut - 1]["attempted_at"], rows[cut]["attempted_at"]


def forward(m, X):
    W1, b1, W2, b2 = (np.array(m[k], dtype=np.float64) for k in ("W1", "b1", "W2", "b2"))
    # numpy 2 with Apple Accelerate raises spurious FP warnings in matmul. Silence them
    # and check the result is finite instead.
    with np.errstate(all="ignore"):
        h = np.tanh(X @ W1 + b1)
        z = h @ W2 + b2
    assert np.isfinite(z).all(), "non-finite model output"
    return 1.0 / (1.0 + np.exp(-z[:, 0]))


def score(p):
    """0..100 score written on chain. The contract captures at score >= 70."""
    return np.clip(np.floor(p * 100.0 + 0.5), 0, 100).astype(int)
