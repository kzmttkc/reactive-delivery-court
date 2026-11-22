"""Builds the content data set: real response bytes from model/data/bodies.jsonl.gz plus made-up
negative bodies, split by seller host (no host is in both train and test).

Real (collected by fetch_bodies.py, no payment):
  label 1  bazaar_example  output example the seller declares in its x402 Bazaar listing
  label 0  unpaid_402      the seller's own answer to an unpaid GET (the 402 body)
  label 0  error_page_*    the seller host's answer to a path that does not exist
Made up (one per declared example, fixed seed, derived from that example and its schema):
  empty_json, blank, error_json, rate_limit, html_error, truncated, schema_violation, nulled
For 30% of examples the declared schema is hidden from the features, so the model also learns
the case where the seller declares none. That hiding is applied to real and made-up rows alike.
"""
import base64, copy, gzip, hashlib, json, os, random

from content_features import featurize_body

HERE = os.path.dirname(os.path.abspath(__file__))
SEED = 7
TEST_SHARE = 0.2
HIDE_SCHEMA = 0.3
SYNTH_KINDS = ["empty_json", "blank", "error_json", "rate_limit", "html_error", "truncated", "schema_violation", "nulled"]
MSGS = ["Internal Server Error", "upstream request timeout", "Service temporarily unavailable",
        "invalid API key for upstream provider", "model overloaded, try again later", "Not Found",
        "database connection failed", "request failed"]
HTML = [
    "<!DOCTYPE html><html><head><title>502 Bad Gateway</title></head><body><center><h1>502 Bad Gateway</h1></center><hr><center>nginx</center></body></html>",
    "<html><head><title>503 Service Unavailable</title></head><body><h1>Service Unavailable</h1><p>The server is temporarily unable to service your request.</p></body></html>",
    "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>Error</title></head><body><pre>Cannot GET /api</pre></body></html>",
    "<!DOCTYPE html><html><head><title>Just a moment...</title></head><body><noscript>Enable JavaScript and cookies to continue</noscript></body></html>",
    "<html><body><h1>500 Internal Server Error</h1></body></html>",
]


def host_in_test(host):
    return hashlib.sha256(host.encode()).digest()[0] < int(256 * TEST_SHARE)


def _nulled(v):
    if isinstance(v, dict):
        return {k: _nulled(x) for k, x in v.items()}
    if isinstance(v, list):
        return [_nulled(x) for x in v[:3]]
    return None


def synth(kind, body, schema, rng):
    """One made-up negative body from a declared example."""
    try:
        v = json.loads(body.decode("utf-8"))
    except Exception:
        v = None
    msg = rng.choice(MSGS)
    if kind == "empty_json":
        return rng.choice([b"{}", b"[]", b"null", b'""', b'{"data":[]}', b'{"result":null}', b'{"items":[],"total":0}'])
    if kind == "blank":
        return rng.choice([b"", b" ", b"\n", b"\r\n", b"   \n"])
    if kind == "error_json":
        shape = rng.randrange(5)
        o = [{"error": msg}, {"error": {"code": rng.choice([500, 502, 503]), "message": msg}},
             {"success": False, "message": msg}, {"status": "error", "message": msg}, {"message": msg, "code": 500}][shape]
        return json.dumps(o).encode()
    if kind == "rate_limit":
        return rng.choice([b"Too Many Requests", b"429 Too Many Requests\n",
                           json.dumps({"error": "rate limit exceeded", "retryAfter": rng.randrange(5, 120)}).encode(),
                           json.dumps({"message": "Quota exceeded for this API key"}).encode()])
    if kind == "html_error":
        return rng.choice(HTML).encode()
    if kind == "truncated":
        if len(body) >= 8:
            for _ in range(10):
                cut = body[: max(1, int(len(body) * rng.uniform(0.2, 0.9)))]
                try:
                    json.loads(cut.decode("utf-8"))
                except Exception:
                    return cut
        return json.dumps({"error": msg}).encode()
    if kind == "schema_violation":
        if isinstance(v, dict) and isinstance(schema, dict) and isinstance(schema.get("required"), list) and schema["required"]:
            o = {k: x for k, x in v.items() if k not in schema["required"]}
            o["ok"] = True
            return json.dumps(o).encode()
        if isinstance(v, dict) and v:
            return json.dumps({k: None for k in v}).encode()
        return b'{"ok":true}'
    if kind == "nulled":
        return json.dumps(_nulled(v) if isinstance(v, (dict, list)) and v else None).encode()
    raise ValueError(kind)


def load_rows():
    """Returns rows: dict(body, schema, label, source, host, synthetic, test)."""
    rng = random.Random(SEED)
    raw = [json.loads(l) for l in gzip.open(os.path.join(HERE, "data", "bodies.jsonl.gz"))]
    rows = []
    for r in raw:
        src = r["source"]
        if src != "bazaar_example" and src != "unpaid_402" and not src.startswith("error_page_"):
            continue  # unpaid 2xx/3xx/4xx other than 402 have no clear label
        body = base64.b64decode(r["body_b64"])
        schema = r["schema"] if isinstance(r["schema"], dict) and r["schema"] else None
        hide = schema is not None and rng.random() < HIDE_SCHEMA
        test = host_in_test(r["host"])
        rows.append({"body": body, "schema": None if hide else schema, "label": r["label"], "source": src,
                     "host": r["host"], "synthetic": False, "test": test})
        if src == "bazaar_example":
            kind = SYNTH_KINDS[rng.randrange(len(SYNTH_KINDS))]
            rows.append({"body": synth(kind, body, schema, rng), "schema": None if hide else schema, "label": 0,
                         "source": "synthetic_" + kind, "host": r["host"], "synthetic": True, "test": test})
    return rows


def matrix(rows):
    import numpy as np
    X = np.array([featurize_body(r["body"], r["schema"]) for r in rows], dtype=np.float64)
    y = np.array([float(r["label"]) for r in rows])
    return X, y
