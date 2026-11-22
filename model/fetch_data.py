#!/usr/bin/env python3
"""Downloads the public vet402 delivery record and stores the columns the model uses.

Source: GET https://vet402.com/api/v1/observatory/delivery.csv (key-less, public).
One row per paid x402 attempt that vet402 settled, with the HTTP status of the paid
request, the body size, whether the body was non-empty, latency and vet402's delivery label.

Writes model/data/delivery.csv.gz and model/data/SOURCE.json (fetch time, row count, sha256).
"""
import csv, gzip, hashlib, io, json, os, sys, urllib.request
from datetime import datetime, timezone

URL = "https://vet402.com/api/v1/observatory/delivery.csv"
KEEP = ["purchase_id", "attempted_at", "latency_ms", "delivery", "delivery_reason",
        "http_status_paid", "body_bytes", "payload_non_empty"]
HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    req = urllib.request.Request(URL, headers={"User-Agent": "delivery-court-model/1"})
    with urllib.request.urlopen(req, timeout=120) as r:
        raw = r.read()
    rows = list(csv.DictReader(io.StringIO(raw.decode("utf-8"))))
    missing = [k for k in KEEP if k not in rows[0]]
    if missing:
        sys.exit(f"columns missing in source: {missing}")
    out = io.StringIO()
    w = csv.DictWriter(out, fieldnames=KEEP, lineterminator="\n")
    w.writeheader()
    for row in sorted(rows, key=lambda x: (x["attempted_at"], x["purchase_id"])):
        w.writerow({k: row[k] for k in KEEP})
    data = out.getvalue().encode("utf-8")
    os.makedirs(os.path.join(HERE, "data"), exist_ok=True)
    with gzip.GzipFile(os.path.join(HERE, "data", "delivery.csv.gz"), "wb", mtime=0) as g:
        g.write(data)
    src = {
        "url": URL,
        "fetched_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "rows": len(rows),
        "sha256_of_kept_csv": hashlib.sha256(data).hexdigest(),
        "columns": KEEP,
    }
    with open(os.path.join(HERE, "data", "SOURCE.json"), "w") as f:
        json.dump(src, f, indent=2)
        f.write("\n")
    print(json.dumps(src, indent=2))


if __name__ == "__main__":
    main()
