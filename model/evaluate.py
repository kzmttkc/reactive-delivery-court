#!/usr/bin/env python3
"""Evaluates model/model.json on the held-out test period and prints the README numbers.

python3 model/evaluate.py          -> human readable
python3 model/evaluate.py --json   -> model/metrics.json content
"""
import hashlib, json, os, sys

import base64, glob

import numpy as np

from content_data import load_rows, matrix
from content_features import featurize_body
from features import HERE, featurize, forward, load, score, time_split

THRESHOLD = 70  # DeliveryCourtReactive threshold: capture when score >= 70
# Output schemas the demo sellers declare in their 402 answer (offchain/src/seller.mjs, OUTPUT_SCHEMAS).
SCHEMAS = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "seller_schemas.json")))
DELIVER_SCHEMA, EMPTY_SCHEMA = SCHEMAS["deliver"], SCHEMAS["empty"]


def confusion(y, pred):
    return {
        "delivered_scored_capture": int(((y == 1) & pred).sum()),
        "delivered_scored_void": int(((y == 1) & ~pred).sum()),
        "not_delivered_scored_capture": int(((y == 0) & pred).sum()),
        "not_delivered_scored_void": int(((y == 0) & ~pred).sum()),
    }


def metrics(y, s, thr):
    pred = s >= thr
    c = confusion(y, pred)
    pos, neg = int((y == 1).sum()), int((y == 0).sum())
    return {
        "threshold": thr,
        "accuracy": round(float((pred == (y == 1)).mean()), 4),
        "recall_delivered": round(c["delivered_scored_capture"] / pos, 4) if pos else None,
        "recall_not_delivered": round(c["not_delivered_scored_void"] / neg, 4) if neg else None,
        "confusion": c,
    }


def content_model_and_judge():
    cblob = open(os.path.join(HERE, "content_model.json"), "rb").read()
    jblob = open(os.path.join(HERE, "judge.json"), "rb").read()
    return json.loads(cblob), hashlib.sha256(cblob).hexdigest(), hashlib.sha256(jblob).hexdigest()


def own_seller_bodies():
    """Bodies the buyer received from the three demo sellers on testnet (offchain/runs).
    Labels follow the seller's design: deliver = 1, empty = 0."""
    out = []
    root = os.path.join(os.path.dirname(HERE), "offchain", "runs")
    for f in sorted(glob.glob(os.path.join(root, "**", "*.body"), recursive=True)):
        name = os.path.basename(f)
        kind = "deliver" if name.startswith("deliver") else "empty" if name.startswith("empty") else None
        if kind:
            out.append({"body": open(f, "rb").read(), "schema": DELIVER_SCHEMA if kind == "deliver" else EMPTY_SCHEMA,
                        "label": 1 if kind == "deliver" else 0, "source": "own_" + kind})
    return out


def binary_metrics(y, s, thr=THRESHOLD):
    if len(y) == 0:
        return None
    m = metrics(y, s, thr)
    m["rows"] = int(len(y))
    return m


def content_eval(meta_model):
    cm, csha, jsha = content_model_and_judge()
    rows = load_rows()
    test = [r for r in rows if r["test"]]
    real = [r for r in test if not r["synthetic"]]
    syn = [r for r in test if r["synthetic"]]
    out = {"content_sha256": csha, "judge_sha256": jsha}
    tr = [r for r in rows if not r["test"]]
    out["data"] = {"rows": len(rows), "train": len(tr), "test": len(test),
                   "synthetic_share": round(sum(1 for r in rows if r["synthetic"]) / len(rows), 4),
                   "train_real": sum(1 for r in tr if not r["synthetic"]), "train_synthetic": sum(1 for r in tr if r["synthetic"]),
                   "test_real": len(real), "test_synthetic": len(syn),
                   "test_hosts": len({r["host"] for r in test}), "train_hosts": len({r["host"] for r in tr})}
    def sc(rs):
        X, y = matrix(rs)
        return y, score(forward(cm, X))
    yr, sr = sc(real)
    ys, ss = sc(syn)
    yt, st = sc(test)
    out["real_test"] = binary_metrics(yr, sr)
    out["synthetic_test"] = binary_metrics(ys, ss)
    out["all_test"] = binary_metrics(yt, st)
    # Rule baseline: capture when the body parses as JSON and is a non-empty object or array.
    rule = lambda rs: np.array([100 if featurize_body(r["body"], None)[3] == 1.0 else 0 for r in rs])
    out["rule_baseline"] = {"real_test": binary_metrics(yr, rule(real)), "synthetic_test": binary_metrics(ys, rule(syn))}
    out["real_test_sweep"] = [metrics(yr, sr, t) for t in (50, 70, 90)]
    def by(rs, s, key):
        d = {}
        for r, v in zip(rs, s):
            k = key(r)
            a = d.setdefault(k, {"rows": 0, "scored_capture": 0})
            a["rows"] += 1
            a["scored_capture"] += int(v >= THRESHOLD)
        return dict(sorted(d.items()))
    out["real_test_by_source"] = by(real, sr, lambda r: r["source"] if not r["source"].startswith("error_page") else "error_page")
    out["synthetic_test_by_kind"] = by(syn, ss, lambda r: r["source"].removeprefix("synthetic_"))
    own = own_seller_bodies()
    if own:
        yo, so = sc(own)
        out["own_sellers"] = binary_metrics(yo, so)
        out["own_sellers_by_kind"] = by(own, so, lambda r: r["source"])
    else:
        out["own_sellers"] = None
    def judge_score(status, body, latency, schema):
        ms = int(score(forward(meta_model, np.array([featurize(status, None if body is None else len(body), None if body is None else len(body) > 0, latency)])))[0])
        if body is None:
            return {"metadata": ms, "content": None, "final": ms}
        cs = int(score(forward(cm, np.array([featurize_body(body, schema)])))[0])
        return {"metadata": ms, "content": cs, "final": min(ms, cs)}
    deliver = b'{"network":"eip155:84532","blockNumber":"61711514","blockTimestamp":1795264171,"baseFeePerGasWei":"5000000","servedBy":"delivery-court seller-deliver"}'
    out["combined_demo"] = {
        "200_deliver_json": judge_score(200, deliver, 2781, DELIVER_SCHEMA),
        "200_empty_body": judge_score(200, b"", 2781, EMPTY_SCHEMA),
        "200_error_json": judge_score(200, b'{"error":"upstream request timeout"}', 2781, DELIVER_SCHEMA),
        "200_html_502": judge_score(200, b"<html><head><title>502 Bad Gateway</title></head><body>502 Bad Gateway</body></html>", 2781, DELIVER_SCHEMA),
        "200_truncated_json": judge_score(200, deliver[:60], 2781, DELIVER_SCHEMA),
        "200_wrong_schema_json": judge_score(200, b'{"ok":true}', 2781, DELIVER_SCHEMA),
        "no_response": judge_score(None, None, None, None),
    }
    return out


def write_fixtures():
    """Fixed sample for the JS parity test (offchain/test): bodies, schemas, Python features, scores."""
    import random
    cm, _, _ = content_model_and_judge()
    rows = load_rows()
    rng = random.Random(11)
    pick = rng.sample(rows, 300) + own_seller_bodies()[:4]
    X, _ = matrix(pick)
    s = score(forward(cm, X))
    fx = [{"body_b64": base64.b64encode(r["body"]).decode(), "schema": r["schema"], "features": [round(v, 9) for v in x],
           "score": int(v)} for r, x, v in zip(pick, X.tolist(), s)]
    with open(os.path.join(HERE, "data", "content_fixtures.json"), "w") as f:
        json.dump(fx, f, separators=(",", ":"))
        f.write("\n")


def main():
    path = os.path.join(HERE, "model.json")
    blob = open(path, "rb").read()
    model = json.loads(blob)
    rows, X, y = load()
    cut, _, _ = time_split(rows)
    s = score(forward(model, X[cut:]))
    yt = y[cut:]
    test_rows = rows[cut:]
    empty_2xx = [i for i, r in enumerate(test_rows)
                 if r["http_status_paid"].startswith("2") and r["payload_non_empty"] == "false"]
    out = {
        "model_sha256": hashlib.sha256(blob).hexdigest(),
        "data_sha256": model["data_sha256"],
        "train_rows": cut,
        "test_rows": len(test_rows),
        "test_from": test_rows[0]["attempted_at"],
        "test_until": test_rows[-1]["attempted_at"],
        "test_delivered": int(yt.sum()),
        "test_not_delivered": int(len(yt) - yt.sum()),
        "majority_baseline_accuracy": round(float(max(yt.mean(), 1 - yt.mean())), 4),
        "at_contract_threshold": metrics(yt, s, THRESHOLD),
        "threshold_sweep": [metrics(yt, s, t) for t in (50, 70, 90)],
        "empty_2xx_rows": {"train": sum(1 for r in rows[:cut] if r["http_status_paid"].startswith("2")
                                        and r["payload_non_empty"] == "false"),
                           "test": len(empty_2xx)},
        "demo_inputs": {
            "200_json_212_bytes": int(score(forward(model, np.array([featurize(200, 212, True, 40)])))[0]),
            "200_empty_body": int(score(forward(model, np.array([featurize(200, 0, False, 40)])))[0]),
            "no_response": int(score(forward(model, np.array([featurize(None, None, None, None)])))[0]),
        },
    }
    out["content"] = content_eval(model)
    if "--fixtures" in sys.argv:
        write_fixtures()
    if "--json" in sys.argv:
        print(json.dumps(out, indent=2))
        return
    a = out["at_contract_threshold"]
    print(f"model sha256      {out['model_sha256']}")
    print(f"train/test rows   {out['train_rows']} / {out['test_rows']} (test {out['test_from']} .. {out['test_until']})")
    print(f"test labels       delivered {out['test_delivered']}, not delivered {out['test_not_delivered']}")
    print(f"majority baseline {out['majority_baseline_accuracy']}")
    print(f"accuracy @70      {a['accuracy']}  recall delivered {a['recall_delivered']}  recall not delivered {a['recall_not_delivered']}")
    print(f"confusion @70     {a['confusion']}")
    for m in out["threshold_sweep"]:
        print(f"  threshold {m['threshold']}: accuracy {m['accuracy']}, confusion {m['confusion']}")
    print(f"empty 2xx rows    {out['empty_2xx_rows']}")
    print(f"demo inputs       {out['demo_inputs']}")
    c = out["content"]
    print(f"content model     {c['content_sha256']}  judge (model version) {c['judge_sha256']}")
    print(f"content data      {c['data']}")
    for part in ("real_test", "synthetic_test", "own_sellers"):
        m = c[part]
        if m:
            print(f"content {part:15s} rows {m['rows']}  accuracy @70 {m['accuracy']}  confusion {m['confusion']}")
    rb = c["rule_baseline"]
    print(f"rule baseline (JSON non-empty) real accuracy {rb['real_test']['accuracy']} {rb['real_test']['confusion']}  synthetic accuracy {rb['synthetic_test']['accuracy']} {rb['synthetic_test']['confusion']}")
    print(f"content real test by source      {c['real_test_by_source']}")
    print(f"content synthetic test by kind   {c['synthetic_test_by_kind']}")
    for m in c["real_test_sweep"]:
        print(f"  real test threshold {m['threshold']}: accuracy {m['accuracy']}, confusion {m['confusion']}")
    print(f"combined demo     {c['combined_demo']}")


if __name__ == "__main__":
    main()
