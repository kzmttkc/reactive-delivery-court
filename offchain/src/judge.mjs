// Judge role: scores what the buyer received with the two delivery networks (model/judge.json)
// and writes the score to ERC-8004 ValidationRegistry.validationResponse. The Reactive contract
// on Lasna reads that log and asks DeliveryCourtCallback to capture (score >= 70) or void.
//   requestHash  = paymentId (AuthCaptureEscrow.getHash(paymentInfo))
//   responseHash = sha256 of the response body the buyer received
//   tag          = "dc1:<status>:<bodyBytes>:<latencyMs>", the facts the score rests on. The v2 reactive
//                  contract re-scores them with the same metadata network and takes the lower score;
//                  status 0 = no response, latencyMs is rounded to an integer before scoring.
//   responseURI  = offchain/runs/responses/<paymentId>.json, a path relative to the repository
//                  root. That file holds the judgment record. The body itself is stored next to it
//                  as <responseHash>.body, so anyone can recompute the hash.
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createPublicClient, createWalletClient, http } from "viem";
import { baseSepolia } from "viem/chains";
import { BASE_RPC, REPO, VALIDATION } from "./config.mjs";
import { judgeResponse } from "./model.mjs";

const ABI = [
  {
    type: "function", name: "validationResponse", stateMutability: "nonpayable", outputs: [],
    inputs: [
      { name: "requestHash", type: "bytes32" }, { name: "response", type: "uint8" },
      { name: "responseURI", type: "string" }, { name: "responseHash", type: "bytes32" }, { name: "tag", type: "string" },
    ],
  },
];
export const RESPONSES_DIR = "offchain/runs/responses";
const r6 = (x) => Number(x.toFixed(6));

// opts.uriBase: the public server names the record by a full URL (its own /responses/ path)
// instead of the repository path. opts.reportedBy says whose copy of the body was scored.
/** The facts tag written next to the score. The v2 reactive contract parses exactly this shape. */
export function factsTag(status, bodyBytes, latencyMs) {
  return `dc1:${status ?? 0}:${bodyBytes}:${latencyMs}`;
}

export function buildJudgment(judge, paymentId, response, outputSchema = null, opts = {}) {
  // The chain only sees integer milliseconds, so the judge scores those too: the metadata score here
  // and the one the reactive contract computes from the tag are the same number.
  const latencyMs = response ? Math.max(0, Math.round(Number(response.latencyMs ?? 0)) || 0) : 0;
  if (response) response = { ...response, latencyMs };
  const body = response ? response.body : Buffer.alloc(0);
  const bodySha256 = "0x" + createHash("sha256").update(body).digest("hex");
  const j = judgeResponse(judge, response, outputSchema);
  const tag = factsTag(response ? response.status : null, body.length, latencyMs);
  const base = opts.uriBase ?? RESPONSES_DIR;
  const responseURI = `${base}/${paymentId}.json`;
  const record = {
    v: 3,
    model: "sha256:" + judge.sha256,
    metadataModel: "sha256:" + judge.meta.sha256,
    contentModel: "sha256:" + judge.content.sha256,
    rule: "score = min(metadata score, content score), metadata score alone when there is no response",
    paymentId,
    status: response ? response.status : null,
    bodyBytes: response ? body.length : null,
    latencyMs: response ? latencyMs : null,
    tag,
    bodySha256,
    bodyFile: `${base}/${bodySha256}.body`,
    ...(opts.reportedBy ? { bodyReportedBy: opts.reportedBy } : {}),
    outputSchemaDeclared: outputSchema,
    score: j.score,
    metadata: { score: j.meta.score, p: r6(j.meta.probability), features: j.meta.features.map(r6) },
    content: j.content ? { score: j.content.score, p: r6(j.content.probability), features: j.content.features.map(r6) } : null,
  };
  return { score: j.score, bodySha256, record, body, responseURI, recordFile: `${paymentId}.json`, tag, args: [paymentId, j.score, responseURI, bodySha256, tag] };
}

/** Writes the record and the body under offchain/runs/responses/ before the judgment is sent. */
export function storeJudgment(j, dir = join(REPO, RESPONSES_DIR)) {
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, `${j.bodySha256}.body`), j.body);
  const file = join(dir, j.recordFile);
  // First writer wins: a second judgment for the same payment fails here instead of overwriting the public record.
  writeFileSync(file, JSON.stringify(j.record, null, 2) + "\n", { flag: "wx" });
}

export function createJudge(account, judgeBundle, { uriBase, dir, reportedBy } = {}) {
  const wallet = createWalletClient({ account, chain: baseSepolia, transport: http(BASE_RPC) });
  const publicClient = createPublicClient({ chain: baseSepolia, transport: http(BASE_RPC) });
  async function judge(paymentId, response, outputSchema) {
    const j = buildJudgment(judgeBundle, paymentId, response, outputSchema, { uriBase, reportedBy });
    storeJudgment(j, dir);
    // Twice the estimate, at least 300k: an estimate taken before the seller's validationRequest is mined
    // can come out low and the score tx then runs out of gas (seen once in the v2 latency runs, 2026-11-22).
    const est = await publicClient.estimateContractGas({ account, address: VALIDATION, abi: ABI, functionName: "validationResponse", args: j.args }).catch(() => 0n);
    const gas = est * 2n > 300_000n ? est * 2n : 300_000n;
    const hash = await wallet.writeContract({ address: VALIDATION, abi: ABI, functionName: "validationResponse", args: j.args, gas });
    const r = await publicClient.waitForTransactionReceipt({ hash });
    return { ...j, hash, status: r.status };
  }
  return { judge };
}
