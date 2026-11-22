import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import express from "express";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { zeroAddress } from "viem";
import { x402Client, x402HTTPClient } from "@x402/fetch";
import { toClientEvmSigner } from "@x402/evm";
import { AuthCaptureEvmScheme } from "@x402/evm/auth-capture/client";
import { CALLBACK, CHAIN_ID, ESCROW, REPO, ROLES, USDC } from "../src/config.mjs";
import { loadModel, featurize, probability, score, judgeResponse } from "../src/model.mjs";
import { featurizeBody, loadJudge, outputSchemaFrom } from "../src/content.mjs";
import { escrowHash, paymentIdFromPayload, paymentInfoFromPayload } from "../src/payment-id.mjs";
import { buildJudgment } from "../src/judge.mjs";
import { createFacilitator } from "../src/facilitator.mjs";
import { createSeller, handlers, paymentRequirements, maxTimeoutFor, DEADLINE_BUCKET_SECONDS } from "../src/seller.mjs";

const metrics = JSON.parse(readFileSync(join(REPO, "model", "metrics.json"), "utf8"));
const model = loadModel();
const judgeBundle = loadJudge();
const fixtures = JSON.parse(readFileSync(join(REPO, "model", "data", "content_fixtures.json"), "utf8"));
const DELIVER_SCHEMA = JSON.parse(readFileSync(join(REPO, "model", "seller_schemas.json"), "utf8")).deliver;

function listen(app) {
  return new Promise((resolve) => {
    const s = app.listen(0, () => resolve({ server: s, url: `http://127.0.0.1:${s.address().port}` }));
  });
}

test("JS inference matches the Python evaluation (hash and demo inputs)", () => {
  assert.equal(model.sha256, metrics.model_sha256);
  const s = (st, b, ne, l) => score(probability(model, featurize(st, b, ne, l)));
  assert.equal(s(200, 212, true, 40), metrics.demo_inputs["200_json_212_bytes"]);
  assert.equal(s(200, 0, false, 40), metrics.demo_inputs["200_empty_body"]);
  assert.equal(s(null, null, null, null), metrics.demo_inputs.no_response);
});

test("model separates a JSON body from an empty 200 at the contract threshold", () => {
  const s = (st, b, ne, l) => score(probability(model, featurize(st, b, ne, l)));
  assert.ok(s(200, 212, true, 3000) >= 70);
  assert.ok(s(200, 0, false, 3000) < 70);
  assert.ok(s(500, 30, true, 3000) < 70);
  assert.ok(s(null, null, null, null) < 70);
});

test("paymentId matches the escrow hash of the stage 0 capture payment", () => {
  const t = 1795263375n;
  const id = escrowHash(CHAIN_ID, ESCROW, {
    operator: "0xED4123D5D7b2102106042b04af0f3268A537eB79",
    payer: "0x6db137549302E9b98abcB2a275b642f485895E2d",
    receiver: "0x6db137549302E9b98abcB2a275b642f485895E2d",
    token: USDC, maxAmount: 10000n, preApprovalExpiry: t, authorizationExpiry: t, refundExpiry: t,
    minFeeBps: 0, maxFeeBps: 0, feeReceiver: zeroAddress, salt: 1n,
  });
  assert.equal(id, "0x65c83b91cda8699ee54767e35e7465509f27173b8123c25f901b4998c131d75d");
});

test("payment requirements: custom operator, deferred capture, zero fees, payTo is the seller", () => {
  const r = paymentRequirements("deliver", ROLES["seller-deliver"], 600);
  assert.equal(r.scheme, "auth-capture");
  assert.equal(r.payTo, ROLES["seller-deliver"]);
  assert.equal(r.extra.operatorType, "custom");
  assert.equal(r.extra.captureAuthorizer, CALLBACK);
  assert.equal(r.extra.captureMode, "deferred");
  assert.equal(r.extra.minFeeBps, 0);
  assert.equal(r.extra.maxFeeBps, 0);
  assert.equal(r.extra.feeRecipient, zeroAddress);
});

test("payment window fits the capture deadline even at the end of the SDK's 60 s bucket", () => {
  for (const d of [90, 600]) {
    const worstCaptureDeadline = d - (DEADLINE_BUCKET_SECONDS - 1);
    assert.ok(maxTimeoutFor(d) + 6 < worstCaptureDeadline, `deadline ${d}`);
    assert.equal(paymentRequirements("deliver", ROLES["seller-deliver"], d).maxTimeoutSeconds, maxTimeoutFor(d));
  }
});

test("seller handlers: deliver JSON, empty 0 bytes with 200, silent never answers", async () => {
  const held = new Set();
  const ctx = { held, publicClient: { getBlock: async () => ({ number: 123n, timestamp: 456n, baseFeePerGas: 7n }) } };
  const app = express();
  for (const k of ["deliver", "empty", "silent"]) app.get(`/${k}`, (req, res) => handlers[k](req, res, ctx));
  const { server, url } = await listen(app);
  try {
    const d = await fetch(`${url}/deliver`);
    assert.equal(d.status, 200);
    const body = await d.json();
    assert.equal(body.blockNumber, "123");
    const e = await fetch(`${url}/empty`);
    assert.equal(e.status, 200);
    assert.equal((await e.arrayBuffer()).byteLength, 0);
    const ac = new AbortController();
    const timer = setTimeout(() => ac.abort(), 400);
    await assert.rejects(fetch(`${url}/silent`, { signal: ac.signal }));
    clearTimeout(timer);
    assert.equal(held.size, 1);
  } finally {
    server.closeAllConnections();
    server.close();
  }
});

test("content features and scores match Python on every fixture", () => {
  assert.ok(fixtures.length >= 300);
  for (const fx of fixtures) {
    const f = featurizeBody(Buffer.from(fx.body_b64, "base64"), fx.schema);
    fx.features.forEach((v, i) => assert.ok(Math.abs(f[i] - v) < 1e-6, `feature ${i}: js ${f[i]} py ${v}`));
    assert.equal(score(probability(judgeBundle.content, f)), fx.score);
  }
});

test("model version: judge.json binds both networks and matches the Python evaluation", () => {
  assert.equal(judgeBundle.sha256, metrics.content.judge_sha256);
  assert.equal(judgeBundle.content.sha256, metrics.content.content_sha256);
  assert.equal(judgeBundle.meta.sha256, metrics.model_sha256);
  const demo = metrics.content.combined_demo;
  const deliver = Buffer.from('{"network":"eip155:84532","blockNumber":"61711514","blockTimestamp":1795264171,"baseFeePerGasWei":"5000000","servedBy":"delivery-court seller-deliver"}');
  const r = (body, schema) => judgeResponse(judgeBundle, { status: 200, body, latencyMs: 2781 }, schema);
  assert.equal(r(deliver, DELIVER_SCHEMA).score, demo["200_deliver_json"].final);
  assert.equal(r(Buffer.from('{"error":"upstream request timeout"}'), DELIVER_SCHEMA).score, demo["200_error_json"].final);
  assert.equal(r(deliver.subarray(0, 60), DELIVER_SCHEMA).score, demo["200_truncated_json"].final);
  assert.equal(r(Buffer.from('{"ok":true}'), DELIVER_SCHEMA).score, demo["200_wrong_schema_json"].final);
  assert.equal(judgeResponse(judgeBundle, null).score, demo.no_response.final);
});

test("content model voids 200 answers that carry no delivery", () => {
  const r = (body) => judgeResponse(judgeBundle, { status: 200, body: Buffer.from(body), latencyMs: 3000 }, DELIVER_SCHEMA).score;
  assert.ok(r('{"network":"eip155:84532","blockNumber":"1","blockTimestamp":2}') >= 70);
  for (const bad of ["", "{}", '{"error":"rate limit exceeded"}', "<html><body>502 Bad Gateway</body></html>", '{"network":"eip155:84532","blockN', "Too Many Requests"]) {
    assert.ok(r(bad) < 70, `scored ${r(bad)} for ${JSON.stringify(bad)}`);
  }
});

test("judgment: body sha256 is responseHash, responseURI is the record path in the repo", () => {
  const id = "0x" + "11".repeat(32);
  const empty = buildJudgment(judgeBundle, id, { status: 200, body: Buffer.alloc(0), latencyMs: 3000 }, DELIVER_SCHEMA);
  assert.ok(empty.score < 70);
  assert.equal(empty.bodySha256, "0x" + createHash("sha256").update(Buffer.alloc(0)).digest("hex"));
  assert.equal(empty.args[0], id);
  assert.equal(empty.args[2], `offchain/runs/responses/${id}.json`);
  assert.equal(empty.args[3], empty.bodySha256);
  assert.equal(empty.record.model, "sha256:" + judgeBundle.sha256);
  assert.equal(empty.record.bodyFile, `offchain/runs/responses/${empty.bodySha256}.body`);
  const body = Buffer.from(JSON.stringify({ network: "eip155:84532", blockNumber: "1", blockTimestamp: 2 }));
  const ok = buildJudgment(judgeBundle, id, { status: 200, body, latencyMs: 3000 }, DELIVER_SCHEMA);
  assert.ok(ok.score >= 70);
  assert.equal(ok.args[3], "0x" + createHash("sha256").update(body).digest("hex"));
});

test("v2 facts tag: dc1:<status>:<bodyBytes>:<latencyMs>, integer latency, empty body has 0 bytes", () => {
  const id = "0x" + "22".repeat(32);
  const body = Buffer.from(JSON.stringify({ network: "eip155:84532", blockNumber: "1", blockTimestamp: 2 }));
  const ok = buildJudgment(judgeBundle, id, { status: 200, body, latencyMs: 2780.6 }, DELIVER_SCHEMA);
  assert.equal(ok.args[4], `dc1:200:${body.length}:2781`);
  assert.match(ok.args[4], /^dc1:\d{1,12}:\d{1,12}:\d{1,12}$/);
  assert.equal(ok.record.latencyMs, 2781);
  assert.equal(ok.record.tag, ok.args[4]);
  // The metadata score is taken on the rounded latency, the same input the reactive contract has.
  assert.equal(ok.record.metadata.features[9], Number((Math.log1p(2781) / 10).toFixed(6)));
  const empty = buildJudgment(judgeBundle, id, { status: 200, body: Buffer.alloc(0), latencyMs: 3000 }, DELIVER_SCHEMA);
  assert.equal(empty.args[4], "dc1:200:0:3000");
  const none = buildJudgment(judgeBundle, id, null, DELIVER_SCHEMA);
  assert.equal(none.args[4], "dc1:0:0:0");
  const noLatency = buildJudgment(judgeBundle, id, { status: 404, body: Buffer.from("nope") }, null);
  assert.equal(noLatency.args[4], "dc1:404:4:0");
});

test("x402 end to end without chain: seller answers 402, official client signs, paymentId rebuilds", async () => {
  const relayer = privateKeyToAccount(generatePrivateKey());
  const fac = createFacilitator(relayer);
  const f = await listen(fac.app);
  const seller = createSeller("deliver", { facilitatorUrl: f.url, deadlineSeconds: 600, fileRequest: false });
  const s = await listen(seller.app);
  try {
    const sup = await (await fetch(`${f.url}/supported`)).json();
    const kind = sup.kinds.find((k) => k.scheme === "auth-capture");
    assert.ok(kind);
    assert.deepEqual(kind.extra.operators, [{ address: CALLBACK, operatorType: "custom" }]);

    const res = await fetch(`${s.url}/resource`);
    assert.equal(res.status, 402);
    const buyer = privateKeyToAccount(generatePrivateKey());
    const client = new x402Client().register("eip155:84532", new AuthCaptureEvmScheme(toClientEvmSigner(buyer, { readContract: async () => { throw new Error("no chain in this test"); } })));
    const http = new x402HTTPClient(client);
    const required = http.getPaymentRequiredResponse((n) => res.headers.get(n), await res.json().catch(() => undefined));
    const accepted = required.accepts[0];
    assert.deepEqual(outputSchemaFrom(required), DELIVER_SCHEMA);
    assert.equal(accepted.payTo, ROLES["seller-deliver"]);
    assert.equal(accepted.extra.captureAuthorizer, CALLBACK);
    assert.equal(accepted.extra.operatorType, "custom");
    assert.equal(accepted.extra.captureMode, "deferred");
    const payload = await client.createPaymentPayload(required);
    const info = paymentInfoFromPayload(payload);
    assert.equal(info.operator, CALLBACK);
    assert.equal(info.payer, buyer.address);
    assert.equal(info.receiver, ROLES["seller-deliver"]);
    assert.equal(BigInt(info.authorizationExpiry) - BigInt(info.preApprovalExpiry) >= 0n, true);
    assert.match(paymentIdFromPayload(CHAIN_ID, ESCROW, payload), /^0x[0-9a-f]{64}$/);
  } finally {
    s.server.closeAllConnections(); s.server.close();
    f.server.closeAllConnections(); f.server.close();
  }
});

test("public server: every low testnet balance or debt pauses server-paid runs", async () => {
  const { checkLimits, LIMITS } = await import("../src/server.mjs");
  const ok = { ...LIMITS, callbackDebt: 0n, reactiveDebt: 0n };
  assert.deepEqual(checkLimits(ok), []);
  for (const k of Object.keys(LIMITS)) assert.equal(checkLimits({ ...ok, [k]: LIMITS[k] - 1n }).length, 1, k);
  assert.deepEqual(checkLimits({ ...ok, callbackDebt: 1n }), ["callback debt"]);
  assert.deepEqual(checkLimits({ ...ok, reactiveDebt: 1n }), ["reactive debt"]);
});

test("public judgment: record and body are named by the server URL and say who reported the body", async () => {
  const { buildJudgment } = await import("../src/judge.mjs");
  const { loadJudge } = await import("../src/content.mjs");
  const pid = "0x" + "ab".repeat(32);
  const j = buildJudgment(loadJudge(), pid, { status: 200, body: Buffer.from("{}"), latencyMs: 100 }, null, { uriBase: "https://x.example/responses", reportedBy: "buyer, posted to /judge" });
  assert.equal(j.responseURI, `https://x.example/responses/${pid}.json`);
  assert.equal(j.record.bodyFile, `https://x.example/responses/${j.bodySha256}.body`);
  assert.equal(j.record.bodyReportedBy, "buyer, posted to /judge");
  assert.equal(j.recordFile, `${pid}.json`);
});

// External audit 2026-11-22 H1: only the payer may report a body for its payment.
import { judgeMessage, payerSigned, perMinuteLimit } from "../src/judge-auth.mjs";
import { privateKeyToAccount as pkToAccount } from "viem/accounts";
test("/judge accepts a body only with the payer's signature over the exact bytes and status", async () => {
  const payer = pkToAccount("0x" + "11".repeat(32));
  const other = pkToAccount("0x" + "22".repeat(32));
  const paymentId = "0x" + "ab".repeat(32);
  const body = Buffer.from('{"ok":true}');
  const signature = await payer.signMessage({ message: judgeMessage(paymentId, body, 200) });
  assert.equal(await payerSigned({ payer: payer.address, paymentId, body, status: 200, signature }), true);
  // someone else's key, an empty body swapped in, another status, another payment, garbage
  assert.equal(await payerSigned({ payer: payer.address, paymentId, body, status: 200, signature: await other.signMessage({ message: judgeMessage(paymentId, body, 200) }) }), false);
  assert.equal(await payerSigned({ payer: payer.address, paymentId, body: Buffer.alloc(0), status: 200, signature }), false);
  assert.equal(await payerSigned({ payer: payer.address, paymentId, body, status: 404, signature }), false);
  assert.equal(await payerSigned({ payer: payer.address, paymentId: "0x" + "cd".repeat(32), body, status: 200, signature }), false);
  assert.equal(await payerSigned({ payer: payer.address, paymentId, body, status: 200, signature: "0x1234" }), false);
  assert.equal(await payerSigned({ payer: payer.address, paymentId, body, status: 200 }), false);
});

test("per-minute limit lets 5 through and refuses the 6th for the same caller only", () => {
  const ok = perMinuteLimit(5);
  for (let i = 0; i < 5; i++) assert.equal(ok("a"), true);
  assert.equal(ok("a"), false);
  assert.equal(ok("b"), true);
});

test("the server claims a server-paid payment before /judge can answer and refuses its own buyer's payments", () => {
  const src = readFileSync(new URL("../src/server.mjs", import.meta.url), "utf8");
  const claim = src.indexOf("judged.add(bought.paymentId)");
  const tail = src.indexOf("await courtTail(run, kind, bought.paymentId");
  assert.ok(claim > 0 && claim < tail, "claim happens before the court tail");
  assert.ok(src.includes("dep.args.payer.toLowerCase() === ROLES.buyer.toLowerCase()"));
  assert.ok(src.includes("payerSigned({ payer: dep.args.payer"));
  const judgeSrc = readFileSync(new URL("../src/judge.mjs", import.meta.url), "utf8");
  assert.ok(judgeSrc.includes('{ flag: "wx" }'), "a second record for the same payment cannot overwrite the first");
});

// External audit 2026-11-22: "Don't trust the judge: re-run it" (src/rejudge.mjs), offline with a fake chain client.
import { rejudge } from "../src/rejudge.mjs";
import { encodeFunctionData } from "viem";
import { VALIDATION } from "../src/config.mjs";
test("rejudge recomputes the on-chain score from the stored record and body, and flags a wrong score", async () => {
  const deliver = JSON.parse(readFileSync(join(REPO, "offchain/runs/deliver.json"), "utf8"));
  const recordPath = `offchain/runs/responses/${deliver.paymentId}.json`;
  const record = JSON.parse(readFileSync(join(REPO, recordPath), "utf8"));
  const abi = [{ type: "function", name: "validationResponse", stateMutability: "nonpayable", outputs: [], inputs: [
    { name: "requestHash", type: "bytes32" }, { name: "response", type: "uint8" }, { name: "responseURI", type: "string" },
    { name: "responseHash", type: "bytes32" }, { name: "tag", type: "string" }] }];
  const fake = (score) => ({
    getTransaction: async () => ({ to: VALIDATION, from: ROLES.judge, input: encodeFunctionData({ abi, functionName: "validationResponse", args: [deliver.paymentId, score, recordPath, record.bodySha256, "delivery"] }) }),
    getTransactionReceipt: async () => ({ status: "success" }),
  });
  const ok = await rejudge("0x" + "01".repeat(32), { client: fake(record.score) });
  assert.equal(ok.match, true);
  assert.equal(ok.recomputed, record.score);
  const wrong = await rejudge("0x" + "01".repeat(32), { client: fake(record.score === 0 ? 99 : 0) });
  assert.equal(wrong.match, false);
  const other = { ...fake(record.score), getTransaction: async () => ({ ...(await fake(record.score).getTransaction()), from: ROLES.buyer }) };
  await assert.rejects(rejudge("0x" + "01".repeat(32), { client: other }), /not by the judge/);
  assert.equal(ok.tag.kind, "legacy", "v1 judgments wrote 'delivery' and are not failed for it");
});

test("rejudge checks the v2 facts tag against the body and the record, and flags a rewritten tag", async () => {
  const deliver = JSON.parse(readFileSync(join(REPO, "offchain/runs/deliver.json"), "utf8"));
  const recordPath = `offchain/runs/responses/${deliver.paymentId}.json`;
  const record = JSON.parse(readFileSync(join(REPO, recordPath), "utf8"));
  const body = readFileSync(join(REPO, record.bodyFile));
  const latency = Math.round(Math.expm1(record.metadata.features[9] * 10));
  const abi = [{ type: "function", name: "validationResponse", stateMutability: "nonpayable", outputs: [], inputs: [
    { name: "requestHash", type: "bytes32" }, { name: "response", type: "uint8" }, { name: "responseURI", type: "string" },
    { name: "responseHash", type: "bytes32" }, { name: "tag", type: "string" }] }];
  const fake = (tag) => ({
    getTransaction: async () => ({ to: VALIDATION, from: ROLES.judge, input: encodeFunctionData({ abi, functionName: "validationResponse", args: [deliver.paymentId, record.score, recordPath, record.bodySha256, tag] }) }),
    getTransactionReceipt: async () => ({ status: "success" }),
  });
  const good = `dc1:${record.status}:${body.length}:${latency}`;
  const ok = await rejudge("0x" + "01".repeat(32), { client: fake(good) });
  assert.equal(ok.tag.kind, "match");
  assert.equal(ok.match, true);
  for (const bad of [`dc1:404:${body.length}:${latency}`, `dc1:${record.status}:${body.length + 1}:${latency}`, `dc1:${record.status}:${body.length}:${latency + 500}`, "dc1:200:x:1"]) {
    const r = await rejudge("0x" + "01".repeat(32), { client: fake(bad) });
    assert.equal(r.tag.kind, "mismatch", bad);
    assert.equal(r.match, false, bad);
    assert.equal(r.scoreMatch, true, "the score itself still matches; only the facts were rewritten");
  }
});

test("/judge refuses a body or status that differs from what the seller sent (rescore 2026-11-22, mid 1)", () => {
  const src = readFileSync(new URL("../src/server.mjs", import.meta.url), "utf8");
  const seller = readFileSync(new URL("../src/seller.mjs", import.meta.url), "utf8");
  assert.ok(seller.includes('events.emit("served"'), "the seller reports the hash of what it sent");
  const cmp = src.indexOf("sent.bodySha256 !== postedSha || sent.status !== status");
  const sig = src.indexOf("payerSigned({ payer: dep.args.payer");
  assert.ok(cmp > 0 && cmp < sig, "compared before anything is judged");
  assert.ok(src.includes('req.get("fly-client-ip")'), "the per-caller limit keys on Fly-Client-IP, not X-Forwarded-For");
});

test("an outside seller registered on the court can be judged, only with its own signature over the bytes (rescore 2026-11-22)", async () => {
  const src = readFileSync(new URL("../src/server.mjs", import.meta.url), "utf8");
  assert.ok(src.includes('functionName: "sellers", args: [dep.args.receiver]'), "registration is read from the callback");
  assert.ok(src.includes("signedBy({ signer: dep.args.receiver"), "the seller's signature is required");
  const seller = pkToAccount("0x" + "33".repeat(32));
  const paymentId = "0x" + "ef".repeat(32);
  const body = Buffer.from('{"answer":42}');
  const sellerSignature = await seller.signMessage({ message: judgeMessage(paymentId, body, 200) });
  const { signedBy } = await import("../src/judge-auth.mjs");
  assert.equal(await signedBy({ signer: seller.address, paymentId, body, status: 200, signature: sellerSignature }), true);
  assert.equal(await signedBy({ signer: seller.address, paymentId, body: Buffer.alloc(0), status: 200, signature: sellerSignature }), false);
});
