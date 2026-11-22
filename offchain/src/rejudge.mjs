#!/usr/bin/env node
// Don't trust the judge: re-run it. Read only (sends nothing, reads no key).
//   node src/rejudge.mjs <validationResponse tx hash> [more tx hashes...]
// For each score the judge wrote on chain:
//   1. reads the validationResponse call from Base Sepolia (requestHash, score, responseURI, responseHash) and checks it went to the
//      ERC-8004 ValidationRegistry from the judge address,
//   2. downloads the judgment record (responseURI) and the exact body it names, checks sha256(body) == responseHash,
//   3. checks the record names the same model files as model/judge.json here,
//   4. re-runs both networks on that body with this repository's code and compares the score with the one on chain,
//   5. checks the facts tag on chain ("dc1:<status>:<bodyBytes>:<latencyMs>", what the v2 reactive contract re-scores):
//      status and bytes must match the body and the record, latency must match the record. Judgments from before
//      the tag existed ("delivery") are reported as "legacy" and not failed.
// Prints "on-chain <n> / recomputed <m> / match" per tx and exits 1 if any tx does not match.
// The metadata network also takes the response latency. The record keeps it as a feature (log1p(ms)/10, 6 decimals),
// so the latency is read back from that feature (records from v3 on also keep latencyMs). The content network reads only the body.
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { createPublicClient, decodeFunctionData, http } from "viem";
import { baseSepolia } from "viem/chains";
import { BASE_RPC, REPO, ROLES, VALIDATION } from "./config.mjs";
import { loadJudge } from "./content.mjs";
import { judgeResponse } from "./model.mjs";

const ABI = [{
  type: "function", name: "validationResponse", stateMutability: "nonpayable", outputs: [],
  inputs: [
    { name: "requestHash", type: "bytes32" }, { name: "response", type: "uint8" },
    { name: "responseURI", type: "string" }, { name: "responseHash", type: "bytes32" }, { name: "tag", type: "string" },
  ],
}];
const sha256 = (b) => "0x" + createHash("sha256").update(b).digest("hex");

async function fetchBytes(ref) {
  if (/^https:\/\//.test(ref)) {
    const r = await fetch(ref, { redirect: "follow" });
    if (!r.ok) throw new Error(`${ref} answered HTTP ${r.status}`);
    return Buffer.from(await r.arrayBuffer());
  }
  // Records written before the public server use a path relative to the repository root.
  if (/^offchain\/runs\/responses\/0x[0-9a-f]{64}\.(json|body)$/.test(ref) && existsSync(join(REPO, ref))) return readFileSync(join(REPO, ref));
  throw new Error(`cannot read ${ref} (only https URLs and offchain/runs/responses/ paths)`);
}

export async function rejudge(txHash, { client = createPublicClient({ chain: baseSepolia, transport: http(BASE_RPC) }), judge = loadJudge() } = {}) {
  const tx = await client.getTransaction({ hash: txHash });
  if (tx.to?.toLowerCase() !== VALIDATION.toLowerCase()) throw new Error("not a call to the ERC-8004 ValidationRegistry");
  if (tx.from.toLowerCase() !== ROLES.judge.toLowerCase()) throw new Error(`sent by ${tx.from}, not by the judge ${ROLES.judge}`);
  const receipt = await client.getTransactionReceipt({ hash: txHash });
  if (receipt.status !== "success") throw new Error("the score tx reverted");
  const { functionName, args } = decodeFunctionData({ abi: ABI, data: tx.input });
  if (functionName !== "validationResponse") throw new Error("not validationResponse");
  const [requestHash, onChain, responseURI, responseHash, tag] = args;

  const record = JSON.parse((await fetchBytes(responseURI)).toString("utf8"));
  if (String(record.paymentId).toLowerCase() !== requestHash.toLowerCase()) throw new Error("record is for another payment");
  if (record.model !== "sha256:" + judge.sha256) throw new Error(`record names model ${record.model}, this repository has sha256:${judge.sha256}`);
  const body = await fetchBytes(record.bodyFile);
  const bodySha = sha256(body);
  if (bodySha !== responseHash.toLowerCase() || bodySha !== String(record.bodySha256).toLowerCase()) {
    throw new Error(`body sha256 ${bodySha} differs from responseHash ${responseHash}`);
  }
  const f9 = record.metadata?.features?.[9];
  const latencyMs = typeof record.latencyMs === "number" ? record.latencyMs : typeof f9 === "number" ? Math.expm1(f9 * 10) : null;
  const again = judgeResponse(judge, { status: record.status, body, latencyMs }, record.outputSchemaDeclared ?? null);
  const facts = checkTag(tag, record, body.length, latencyMs);
  const scoreMatch = again.score === Number(onChain);
  return {
    tx: txHash, paymentId: requestHash, onChain: Number(onChain), recomputed: again.score,
    scoreMatch, tag: facts, match: scoreMatch && facts.ok, bodyBytes: body.length, responseURI,
  };
}

/** The facts tag against the body and the record. Returns { ok, kind: "match" | "legacy" | "mismatch", why? }. */
export function checkTag(tag, record, bodyBytes, latencyMs) {
  if (typeof tag !== "string" || !tag.startsWith("dc1:")) return { ok: true, kind: "legacy" };
  const m = /^dc1:(\d{1,12}):(\d{1,12}):(\d{1,12})$/.exec(tag);
  if (!m) return { ok: false, kind: "mismatch", why: `malformed tag ${tag}` };
  const [st, nb, lat] = m.slice(1).map(Number);
  const wantStatus = record.status ?? 0;
  if (st !== wantStatus) return { ok: false, kind: "mismatch", why: `tag status ${st}, record status ${wantStatus}` };
  if (nb !== bodyBytes) return { ok: false, kind: "mismatch", why: `tag says ${nb} bytes, the body has ${bodyBytes}` };
  if (record.bodyBytes != null && nb !== record.bodyBytes) return { ok: false, kind: "mismatch", why: `tag says ${nb} bytes, the record ${record.bodyBytes}` };
  const wantLat = latencyMs == null ? 0 : Math.round(latencyMs);
  if (lat !== wantLat) return { ok: false, kind: "mismatch", why: `tag latency ${lat} ms, record ${wantLat} ms` };
  return { ok: true, kind: "match" };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const txs = process.argv.slice(2);
  if (!txs.length) { console.error("usage: node src/rejudge.mjs <validationResponse tx hash> [...]"); process.exit(2); }
  let ok = true;
  for (const t of txs) {
    try {
      const r = await rejudge(t);
      ok &&= r.match;
      const facts = r.tag.kind === "mismatch" ? `tag MISMATCH: ${r.tag.why}` : `tag ${r.tag.kind}`;
      console.log(`${t.slice(0, 10)}… on-chain ${r.onChain} / recomputed ${r.recomputed} / ${r.scoreMatch ? "match" : "MISMATCH"}, ${facts} (body ${r.bodyBytes} bytes, sha256 checked)`);
    } catch (e) {
      ok = false;
      console.log(`${t.slice(0, 10)}… cannot re-run: ${e.shortMessage ?? e.message}`);
    }
  }
  process.exit(ok ? 0 : 1);
}
