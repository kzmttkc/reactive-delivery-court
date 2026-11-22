// Content features of a response body and the content model. Mirrors model/content_features.py.
// npm test compares the two on model/data/content_fixtures.json.
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { REPO } from "./config.mjs";

const WS = new Set([0x20, 0x09, 0x0a, 0x0d]);
const enc = (s) => Buffer.from(s, "latin1");
const RATE = ["rate limit", "rate-limit", "ratelimit", "too many requests", "quota exceeded"].map(enc);
const ERRW = ["error", "not found", "internal server", "unauthorized", "forbidden", "bad gateway",
  "service unavailable", "timed out", "timeout"].map(enc);
const ERROR_ONLY_KEYS = new Set(["message", "code", "detail", "details", "status", "statuscode", "reason", "title", "type"]);
const MAX_NODES = 5000;
const FEATURE_COUNT = 18;

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const isNum = (v) => typeof v === "number";
const has = (o, k) => Object.prototype.hasOwnProperty.call(o, k);

function asciiLower(b) {
  const out = Buffer.from(b);
  for (let i = 0; i < out.length; i++) if (out[i] >= 0x41 && out[i] <= 0x5a) out[i] += 0x20;
  return out;
}

function strip(b) {
  let s = 0, e = b.length;
  while (s < e && WS.has(b[s])) s++;
  while (e > s && WS.has(b[e - 1])) e--;
  return b.subarray(s, e);
}

function parseJson(b) {
  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(b);
  } catch {
    return [false, null];
  }
  try {
    return [true, JSON.parse(text)];
  } catch {
    return [false, null];
  }
}

function typeOk(v, t) {
  if (Array.isArray(t)) return t.some((x) => typeOk(v, x));
  switch (t) {
    case "string": return typeof v === "string";
    case "number": return isNum(v);
    case "integer": return isNum(v) && Number.isFinite(v) && Math.floor(v) === v;
    case "boolean": return typeof v === "boolean";
    case "object": return isObj(v);
    case "array": return Array.isArray(v);
    case "null": return v === null;
    default: return true;
  }
}

const isTypeDecl = (t) => typeof t === "string" || Array.isArray(t);

export function schemaScore(schema, ok, v) {
  if (!ok) return 0;
  const checks = [];
  if (isTypeDecl(schema.type)) checks.push(typeOk(v, schema.type));
  const props = isObj(schema.properties) ? schema.properties : {};
  const req = Array.isArray(schema.required) ? schema.required : [];
  if (isObj(v)) {
    for (const k of req) if (typeof k === "string") checks.push(has(v, k));
    for (const k of Object.keys(props).sort()) {
      const sub = props[k];
      if (has(v, k) && isObj(sub) && isTypeDecl(sub.type)) checks.push(typeOk(v[k], sub.type));
    }
  } else if (Object.keys(props).length && req.length) {
    checks.push(false);
  }
  const items = schema.items;
  if (Array.isArray(v) && isObj(items) && isTypeDecl(items.type)) for (const x of v.slice(0, 5)) checks.push(typeOk(x, items.type));
  if (!checks.length) return 1;
  return checks.filter(Boolean).length / checks.length;
}

function leaves(v) {
  let n = 0, empty = 0, seen = 0;
  const stack = [v];
  while (stack.length && seen < MAX_NODES) {
    const x = stack.pop();
    seen++;
    if (isObj(x) && Object.keys(x).length) stack.push(...Object.values(x));
    else if (Array.isArray(x) && x.length) stack.push(...x);
    else {
      n++;
      if (x === null || x === "" || (isObj(x) && !Object.keys(x).length) || (Array.isArray(x) && !x.length)) empty++;
    }
  }
  return [n, empty];
}

const falsy = (e) => e === null || e === undefined || e === false || e === 0 || e === "" ||
  (Array.isArray(e) && e.length === 0) || (isObj(e) && Object.keys(e).length === 0);

/** body: Buffer. schema: object or null (the output schema the seller declared). */
export function featurizeBody(body, schema = null) {
  const b = Buffer.from(body);
  const n = b.length;
  const low = asciiLower(b);
  const stripped = strip(b);
  const [ok, v] = stripped.length ? parseJson(b) : [false, null];
  const head = strip(low).subarray(0, 512);
  const html = head.subarray(0, 14).equals(enc("<!doctype html")) || head.subarray(0, 5).equals(enc("<html")) || head.includes(enc("<html"));
  const f = new Array(FEATURE_COUNT).fill(0);
  f[0] = Math.log1p(n) / 10;
  f[1] = stripped.length ? 0 : 1;
  f[2] = ok ? 1 : 0;
  const container = ok && (isObj(v) || Array.isArray(v));
  f[3] = container && (Array.isArray(v) ? v.length : Object.keys(v).length) > 0 ? 1 : 0;
  f[4] = ok && !container ? 1 : 0;
  if (ok) {
    const [nl, ne] = leaves(v);
    f[5] = Math.log1p(nl) / 5;
    f[6] = nl ? ne / nl : 0;
  }
  if (isObj(schema) && Object.keys(schema).length) {
    f[7] = 1;
    f[8] = schemaScore(schema, ok, v);
  }
  if (ok && isObj(v)) {
    const keys = new Set(Object.keys(v).map((k) => k.toLowerCase()));
    const err = has(v, "error") ? v.error : v.errors;
    const st = v.status;
    const errorOnly = keys.size > 0 && [...keys].every((k) => ERROR_ONLY_KEYS.has(k)) && keys.has("message");
    f[9] = ((has(v, "error") || has(v, "errors")) && !falsy(err)) || v.success === false ||
      (typeof st === "string" && ["error", "fail", "failed"].includes(st.toLowerCase())) || errorOnly ? 1 : 0;
    f[13] = has(v, "x402Version") || Array.isArray(v.accepts) ? 1 : 0;
  }
  f[10] = RATE.some((p) => low.includes(p)) ? 1 : 0;
  f[11] = html ? 1 : 0;
  f[12] = stripped.length && (stripped[0] === 0x7b || stripped[0] === 0x5b) && !ok && !html ? 1 : 0;
  if (n) {
    let printable = 0;
    const counts = new Array(256).fill(0);
    for (const c of b) {
      if ((c >= 32 && c <= 126) || c === 9 || c === 10 || c === 13 || c >= 128) printable++;
      counts[c]++;
    }
    f[14] = printable / n;
    let h = 0;
    for (const c of counts) if (c) h += (c / n) * Math.log2(c / n);
    f[15] = -h / 8;
    f[16] = Math.max(...counts) / n;
  }
  f[17] = !ok && ERRW.some((p) => low.includes(p)) ? 1 : 0;
  return f;
}

export function loadJudge() {
  const read = (p) => readFileSync(join(REPO, p));
  const sha = (b) => createHash("sha256").update(b).digest("hex");
  const jblob = read("model/judge.json");
  const judge = JSON.parse(jblob.toString("utf8"));
  const mblob = read(judge.metadata_model.file);
  const cblob = read(judge.content_model.file);
  if (sha(mblob) !== judge.metadata_model.sha256) throw new Error("metadata model hash does not match judge.json");
  if (sha(cblob) !== judge.content_model.sha256) throw new Error("content model hash does not match judge.json");
  return {
    sha256: sha(jblob),
    threshold: judge.threshold,
    meta: { ...JSON.parse(mblob.toString("utf8")), sha256: sha(mblob) },
    content: { ...JSON.parse(cblob.toString("utf8")), sha256: sha(cblob) },
  };
}

/** Output schema the seller declared in its 402 answer: x402 v2 Bazaar extension, or v1 outputSchema.
 * Mirrors output_schema() in model/fetch_bodies.py. */
export function outputSchemaFrom(paymentRequired) {
  if (!paymentRequired) return null;
  const bz = paymentRequired.extensions?.bazaar ?? {};
  const s = bz.schema?.properties?.output?.properties?.example;
  if (isObj(s) && Object.keys(s).length) return s;
  if (isObj(bz.info?.output?.schema)) return bz.info.output.schema;
  for (const a of paymentRequired.accepts ?? []) {
    const o = a.outputSchema;
    const out = isObj(o) ? (o.output ?? o.properties?.output) : null;
    if (isObj(out) && Object.keys(out).length) return out;
  }
  return null;
}
