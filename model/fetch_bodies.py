#!/usr/bin/env python3
"""Collects real x402 response bytes that can be read without paying, for the content model.

1. Pages the public x402 Bazaar discovery list (Coinbase CDP, key-less):
   GET https://api.cdp.coinbase.com/platform/v2/x402/discovery/resources
   Keeps resources whose seller declares an output example (extensions.bazaar.info.output.example)
   and, when present, the JSON schema of that example. These examples are written by the sellers
   themselves. They are a claim of what a paid call returns, not an observed paid response.
2. For a sample of those resources (one per host, GET only), sends one unpaid GET and keeps the
   402 answer as received (status, content type, first 16,000 bytes). This is what the seller
   sends when it does not deliver the resource.
3. For the same hosts, one GET to a path that does not exist, to keep real 404 and error pages
   (often HTML).

No payment, no key, no login. Writes model/data/bodies.jsonl.gz and model/data/BODIES_SOURCE.json.
"""
import base64, concurrent.futures as cf, gzip, hashlib, json, os, random, sys, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
DISCOVERY = "https://api.cdp.coinbase.com/platform/v2/x402/discovery/resources"
UA = "delivery-court-dataset/1"
PAGES = int(os.environ.get("DC_PAGES", "40"))  # 100 resources per page
PROBE_HOSTS = int(os.environ.get("DC_PROBE_HOSTS", "400"))
CAP = 16000
SEED = 7


def get(url, timeout=10, cap=CAP):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json, */*"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, dict(r.headers), r.read(cap) if cap else r.read(), round((time.time() - t0) * 1000)
    except urllib.error.HTTPError as e:
        try:
            body = e.read(cap) if cap else e.read()
        except Exception:
            body = b""
        return e.code, dict(e.headers or {}), body, round((time.time() - t0) * 1000)
    except Exception as e:  # timeout, TLS, DNS
        return None, {}, None, str(type(e).__name__)


def output_schema(item):
    """JSON schema of the declared output, from the v2 bazaar extension or the v1 outputSchema."""
    bz = (item.get("extensions") or {}).get("bazaar") or {}
    s = (((bz.get("schema") or {}).get("properties") or {}).get("output") or {}).get("properties", {}).get("example")
    if isinstance(s, dict) and s:
        return s
    info_out = ((bz.get("info") or {}).get("output") or {})
    if isinstance(info_out.get("schema"), dict):
        return info_out["schema"]
    for a in item.get("accepts") or []:
        o = a.get("outputSchema")
        if isinstance(o, dict):
            out = (o.get("output") or o.get("properties", {}).get("output"))
            if isinstance(out, dict) and out:
                return out
    return None


def main():
    items = []
    for page in range(PAGES):
        st, _, body, _ = get(f"{DISCOVERY}?limit=100&offset={page * 100}", timeout=60, cap=None)
        if st != 200 or not body:
            print(f"page {page} status {st}, stop", file=sys.stderr)
            break
        got = json.loads(body).get("items") or []
        items += got
        if len(got) < 100:
            break
    print(f"discovery items {len(items)}", file=sys.stderr)

    records, seen = [], set()
    by_host = {}
    for it in items:
        res = it.get("resource") or ""
        host = urllib.parse.urlparse(res).netloc
        bz = (it.get("extensions") or {}).get("bazaar") or {}
        info = bz.get("info") or {}
        ex = (info.get("output") or {}).get("example")
        method = ((info.get("input") or {}).get("method") or "GET").upper()
        schema = output_schema(it)
        by_host.setdefault(host, []).append((res, method, schema))
        if ex is None or ex == "" or ex == {} or ex == []:
            continue
        blob = (json.dumps(ex, separators=(",", ":"), ensure_ascii=False) if not isinstance(ex, str) else ex).encode()
        key = (host, hashlib.sha256(blob).hexdigest())
        if key in seen:
            continue
        seen.add(key)
        records.append({"source": "bazaar_example", "label": 1, "host": host, "resource": res, "status": 200,
                        "content_type": "application/json", "schema": schema,
                        "body_b64": base64.b64encode(blob[:CAP]).decode()})
    print(f"declared examples kept {len(records)}", file=sys.stderr)

    rng = random.Random(SEED)
    hosts = sorted(h for h in by_host if h)
    rng.shuffle(hosts)
    probes = []
    for h in hosts:
        gets = [r for r in by_host[h] if r[1] == "GET"]
        if gets:
            probes.append((h, gets[0]))
        if len(probes) >= PROBE_HOSTS:
            break

    def probe(p):
        host, (res, _m, schema) = p
        out = []
        st, hd, body, lat = get(res)
        if body is not None:
            out.append({"source": "unpaid_402" if st == 402 else f"unpaid_{st}", "label": 0, "host": host, "resource": res,
                        "status": st, "content_type": hd.get("Content-Type") or hd.get("content-type"), "schema": schema,
                        "body_b64": base64.b64encode(body).decode()})
        u = urllib.parse.urlparse(res)
        miss = f"{u.scheme}://{u.netloc}/delivery-court-missing-{hashlib.sha256(host.encode()).hexdigest()[:8]}"
        st, hd, body, lat = get(miss)
        if body is not None and st and st >= 400:
            out.append({"source": f"error_page_{st}", "label": 0, "host": host, "resource": miss, "status": st,
                        "content_type": hd.get("Content-Type") or hd.get("content-type"), "schema": schema,
                        "body_b64": base64.b64encode(body).decode()})
        return out

    with cf.ThreadPoolExecutor(16) as ex:
        for out in ex.map(probe, probes):
            records += out
    os.makedirs(os.path.join(HERE, "data"), exist_ok=True)
    data = "".join(json.dumps(r, sort_keys=True) + "\n" for r in records).encode()
    with gzip.GzipFile(os.path.join(HERE, "data", "bodies.jsonl.gz"), "wb", mtime=0) as g:
        g.write(data)
    counts = {}
    for r in records:
        counts[r["source"]] = counts.get(r["source"], 0) + 1
    src = {
        "discovery_url": DISCOVERY,
        "fetched_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "discovery_items": len(items),
        "probe_hosts": len(probes),
        "records": len(records),
        "by_source": dict(sorted(counts.items(), key=lambda kv: -kv[1])),
        "sha256_of_jsonl": hashlib.sha256(data).hexdigest(),
    }
    with open(os.path.join(HERE, "data", "BODIES_SOURCE.json"), "w") as f:
        json.dump(src, f, indent=2)
        f.write("\n")
    print(json.dumps(src, indent=2))


if __name__ == "__main__":
    main()
