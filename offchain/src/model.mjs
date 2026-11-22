// Inference for model/model.json. Mirrors model/features.py (featurize, forward, score).
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { REPO } from "./config.mjs";
import { featurizeBody } from "./content.mjs";

export function loadModel(path = join(REPO, "model", "model.json")) {
  const blob = readFileSync(path);
  const m = JSON.parse(blob.toString("utf8"));
  return { ...m, sha256: createHash("sha256").update(blob).digest("hex") };
}

/** status: number|null, bodyBytes: number|null, nonEmpty: boolean|null, latencyMs: number|null */
export function featurize(status, bodyBytes, nonEmpty, latencyMs) {
  const v = new Array(10).fill(0);
  if (status === null || status === undefined) v[5] = 1;
  else if (status >= 200 && status < 300) v[status === 202 ? 1 : 0] = 1;
  else if (status >= 300 && status < 400) v[2] = 1;
  else if (status >= 400 && status < 500) v[3] = 1;
  else v[4] = 1;
  if (bodyBytes !== null && bodyBytes !== undefined) {
    v[6] = 1;
    v[7] = Math.log1p(Math.max(bodyBytes, 0)) / 10;
  }
  if (nonEmpty === null || nonEmpty === undefined) nonEmpty = bodyBytes != null && bodyBytes > 0;
  v[8] = nonEmpty ? 1 : 0;
  if (latencyMs !== null && latencyMs !== undefined) v[9] = Math.log1p(Math.max(latencyMs, 0)) / 10;
  return v;
}

export function probability(m, x) {
  const h = m.b1.map((b, j) => Math.tanh(x.reduce((s, xi, i) => s + xi * m.W1[i][j], b)));
  const z = h.reduce((s, hj, j) => s + hj * m.W2[j][0], m.b2[0]);
  return 1 / (1 + Math.exp(-z));
}

export function score(p) {
  return Math.min(100, Math.max(0, Math.floor(p * 100 + 0.5)));
}

/**
 * Final score with both networks (model/judge.json): no response -> metadata score,
 * otherwise min(metadata score, content score). schema = output schema the seller declared in its 402.
 */
export function judgeResponse(j, response, schema = null) {
  const meta = scoreResponse(j.meta, response);
  if (!response) return { score: meta.score, meta, content: null };
  const x = featurizeBody(response.body, schema);
  const p = probability(j.content, x);
  const content = { score: score(p), probability: p, features: x };
  return { score: Math.min(meta.score, content.score), meta, content };
}

/** Scores what the buyer received. response: { status, body (Buffer) , latencyMs } or null for no response. */
export function scoreResponse(m, response) {
  const x = response
    ? featurize(response.status, response.body.length, response.body.length > 0, response.latencyMs)
    : featurize(null, null, null, null);
  const p = probability(m, x);
  return { score: score(p), probability: p, features: x };
}
