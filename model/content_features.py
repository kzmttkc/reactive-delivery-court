"""Content features of an HTTP response body. offchain/src/content.mjs mirrors this file
byte for byte, and npm test compares the two on model/data/content_fixtures.json.

Every feature is computed from the raw bytes the buyer received and, when the seller declared
one in its 402 answer, the JSON schema of the output. Text checks are ASCII-only and
case-insensitive on bytes, so Python and JavaScript agree on any input.
"""
import json, math

CONTENT_FEATURES = [
    "log1p_bytes_div10", "blank", "json_ok", "json_container_nonempty", "json_scalar",
    "log1p_leaves_div5", "empty_leaf_ratio", "schema_declared", "schema_score", "error_shape",
    "rate_limit_text", "html", "truncated_json", "x402_challenge", "printable_ratio",
    "entropy_div8", "top_byte_ratio", "error_word_text",
]
WS = b" \t\n\r"
RATE = (b"rate limit", b"rate-limit", b"ratelimit", b"too many requests", b"quota exceeded")
ERRW = (b"error", b"not found", b"internal server", b"unauthorized", b"forbidden", b"bad gateway",
        b"service unavailable", b"timed out", b"timeout")
ERROR_ONLY_KEYS = {"message", "code", "detail", "details", "status", "statuscode", "reason", "title", "type"}
MAX_NODES = 5000


def parse_json(body):
    try:
        text = body.decode("utf-8")  # strict, like TextDecoder fatal
    except UnicodeDecodeError:
        return False, None
    try:
        return True, json.loads(text, parse_constant=_reject)
    except Exception:
        return False, None


def _reject(_c):
    raise ValueError("non-standard JSON constant")


def _is_num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def type_ok(v, t):
    if isinstance(t, list):
        return any(type_ok(v, x) for x in t)
    return {
        "string": isinstance(v, str),
        "number": _is_num(v),
        "integer": _is_num(v) and math.isfinite(v) and float(v) == math.floor(v),
        "boolean": isinstance(v, bool),
        "object": isinstance(v, dict),
        "array": isinstance(v, list),
        "null": v is None,
    }.get(t, True)


def schema_score(schema, ok, v):
    """Share of the schema's checkable claims that the body meets: top-level type, required keys,
    types of listed properties, types of the first 5 array items. 0 when the body is not JSON."""
    if not ok:
        return 0.0
    checks = []
    if isinstance(schema.get("type"), (str, list)):
        checks.append(type_ok(v, schema["type"]))
    props = schema.get("properties") if isinstance(schema.get("properties"), dict) else {}
    req = schema.get("required") if isinstance(schema.get("required"), list) else []
    if isinstance(v, dict):
        for k in req:
            if isinstance(k, str):
                checks.append(k in v)
        for k in sorted(props):
            sub = props[k]
            if k in v and isinstance(sub, dict) and isinstance(sub.get("type"), (str, list)):
                checks.append(type_ok(v[k], sub["type"]))
    elif props and req:
        checks.append(False)
    items = schema.get("items")
    if isinstance(v, list) and isinstance(items, dict) and isinstance(items.get("type"), (str, list)):
        for x in v[:5]:
            checks.append(type_ok(x, items["type"]))
    if not checks:
        return 1.0
    return sum(1.0 for c in checks if c) / len(checks)


def leaves(v):
    """(leaf count, empty leaf count). A leaf is a scalar or an empty container. Empty means
    null, "" or an empty container. Scans at most MAX_NODES nodes."""
    n = empty = seen = 0
    stack = [v]
    while stack and seen < MAX_NODES:
        x = stack.pop()
        seen += 1
        if isinstance(x, dict) and x:
            stack.extend(x.values())
        elif isinstance(x, list) and x:
            stack.extend(x)
        else:
            n += 1
            if x is None or x == "" or (isinstance(x, (dict, list)) and not x):
                empty += 1
    return n, empty


def featurize_body(body, schema=None):
    """body: bytes. schema: dict or None (declared output schema)."""
    b = bytes(body)
    n = len(b)
    low = b.lower()  # ASCII-only lowercasing
    stripped = b.strip(WS)
    ok, v = parse_json(b) if stripped else (False, None)
    head = low.strip(WS)[:512]
    html = head.startswith(b"<!doctype html") or head.startswith(b"<html") or b"<html" in head
    f = [0.0] * len(CONTENT_FEATURES)
    f[0] = math.log1p(n) / 10.0
    f[1] = 1.0 if not stripped else 0.0
    f[2] = 1.0 if ok else 0.0
    f[3] = 1.0 if ok and isinstance(v, (dict, list)) and len(v) > 0 else 0.0
    f[4] = 1.0 if ok and not isinstance(v, (dict, list)) else 0.0
    if ok:
        nl, ne = leaves(v)
        f[5] = math.log1p(nl) / 5.0
        f[6] = ne / nl if nl else 0.0
    if isinstance(schema, dict) and schema:
        f[7] = 1.0
        f[8] = schema_score(schema, ok, v)
    if ok and isinstance(v, dict):
        keys = {k.lower() for k in v}
        err = v.get("error", None) if "error" in v else v.get("errors", None)
        st = v.get("status")
        f[9] = 1.0 if ((("error" in v or "errors" in v) and err not in (None, False, "", [], {}))
                       or v.get("success") is False
                       or (isinstance(st, str) and st.lower() in ("error", "fail", "failed"))
                       or (keys and keys <= ERROR_ONLY_KEYS and "message" in keys)) else 0.0
        f[13] = 1.0 if ("x402Version" in v or isinstance(v.get("accepts"), list)) else 0.0
    f[10] = 1.0 if any(p in low for p in RATE) else 0.0
    f[11] = 1.0 if html else 0.0
    f[12] = 1.0 if (stripped[:1] in (b"{", b"[") and not ok and not html) else 0.0
    if n:
        printable = sum(1 for c in b if 32 <= c <= 126 or c in (9, 10, 13) or c >= 128)
        f[14] = printable / n
        counts = [0] * 256
        for c in b:
            counts[c] += 1
        f[15] = -sum((c / n) * math.log2(c / n) for c in counts if c) / 8.0
        f[16] = max(counts) / n
    f[17] = 1.0 if (not ok and any(p in low for p in ERRW)) else 0.0
    return f
