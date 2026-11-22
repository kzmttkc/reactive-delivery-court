// Docket core and public pages, offline (no RPC). The live check is test/docket.live.mjs.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { CALLBACK, REACTIVE, REPO, ROLES } from "../src/config.mjs";
import { CFG, enrichOnBase, lasnaCases, limiter, makeRpc, payerKind, summarize } from "../public/docket/core.mjs";

const PUB = join(REPO, "offchain", "public");
const hex = (n) => "0x" + n.toString(16);
const pad = (h) => "0x" + h.replace(/^0x/, "").padStart(64, "0");

test("docket: contract addresses and the server buyer match the deployment", () => {
  assert.equal(CFG.callback, CALLBACK.toLowerCase());
  assert.equal(CFG.reactive, REACTIVE.toLowerCase());
  const roles = JSON.parse(readFileSync(join(REPO, "deployments", "roles.json"), "utf8")).roles;
  assert.equal(CFG.serverBuyer, roles.buyer.toLowerCase());
  assert.equal(CFG.serverBuyer, ROLES.buyer.toLowerCase());
});

// A tiny two-chain fake: Lasna at 1 block a second, Base Sepolia at 5 blocks a second.
function fakeChain() {
  const T = 1_800_000_000;
  const lasnaHead = 500_000, baseHead = 9_000_000;
  const lasnaTs = (n) => T - (lasnaHead - n);
  const baseTs = (n) => T - Math.ceil((baseHead - n) / 5);
  const baseAt = (ts) => baseHead - (T - ts) * 5;
  const other = "0x" + "c1".repeat(20), server = CFG.serverBuyer, seller = "0x" + "f9".repeat(20);
  const cases = [
    { id: pad("a1"), payer: server, capture: true, reason: 0, score: 99, opened: lasnaHead - 600 },
    { id: pad("b2"), payer: other, capture: false, reason: 1, score: 0, opened: lasnaHead - 400 },
    { id: pad("c3"), payer: other, capture: false, reason: 2, score: 0, opened: lasnaHead - 300 },
  ];
  const lasnaLogs = cases.flatMap((c) => [
    { topics: [CFG.topics.opened, c.id], data: pad(hex(lasnaTs(c.opened) + 600)), blockNumber: hex(c.opened), transactionHash: pad("10" + c.id.slice(-2)) },
    { topics: [CFG.topics.decision, c.id], data: pad(hex(c.capture ? 1 : 0)) + pad(hex(c.score)).slice(2) + pad(hex(c.reason)).slice(2), blockNumber: hex(c.opened + 5), transactionHash: pad("20" + c.id.slice(-2)) },
  ]);
  const baseLogs = cases.flatMap((c) => [
    { topics: [CFG.topics.deposited, c.id, pad(c.payer), pad(seller)], blockNumber: hex(baseAt(lasnaTs(c.opened)) - 3), transactionHash: pad("30" + c.id.slice(-2)) },
    { topics: [CFG.topics.resolved, c.id], blockNumber: hex(baseAt(lasnaTs(c.opened + 5)) + 10), transactionHash: pad("40" + c.id.slice(-2)) },
  ]);
  const calls = [], reqs = [];
  const answer = (url, method, params) => {
    calls.push(method);
    const lasna = url === CFG.lasna;
    if (method === "eth_blockNumber") return hex(lasna ? lasnaHead : baseHead);
    if (method === "eth_getBlockByNumber") return { timestamp: hex((lasna ? lasnaTs : baseTs)(Number(params[0]))) };
    if (method === "eth_getLogs") {
      const { fromBlock, toBlock, topics } = params[0];
      const [lo, hi] = [Number(fromBlock), Number(toBlock)];
      if (!lasna && hi - lo > CFG.baseRange) throw new Error("range too wide");
      const pool = lasna ? lasnaLogs : baseLogs;
      const t0 = [].concat(topics[0]);
      return pool.filter((l) => Number(l.blockNumber) >= lo && Number(l.blockNumber) <= hi && t0.includes(l.topics[0]) && (!topics[1] || topics[1] === l.topics[1]));
    }
    throw new Error("unexpected " + method);
  };
  const fetchImpl = async (url, o) => {
    const body = JSON.parse(o.body);
    reqs.push({ url, methods: [].concat(body).map((b) => b.method) });
    const one = (b) => ({ jsonrpc: "2.0", id: b.id, result: answer(url, b.method, b.params) });
    return { ok: true, status: 200, json: async () => (Array.isArray(body) ? body.map(one) : one(body)) };
  };
  return { fetchImpl, calls, reqs, other };
}

test("docket: rebuilds cases, finds each payer from Deposited and counts payers that are not the server's buyer", async () => {
  const { fetchImpl, calls, reqs, other } = fakeChain();
  const rpc = makeRpc(fetchImpl);
  const cache = new Map();
  const cases = await lasnaCases(rpc, { hours: 1, cache });
  assert.equal(cases.length, 3);
  // Lasna timestamps come in one batched request, not one request per block.
  assert.equal(calls.filter((m) => m === "eth_getBlockByNumber").length, 6);
  assert.equal(reqs.filter((r) => r.url === CFG.lasna && r.methods.includes("eth_getBlockByNumber")).length, 1);
  for (const c of cases) await enrichOnBase(rpc, c, { cache });
  assert.deepEqual(cases.map(payerKind), ["other", "other", "server"]); // also checks map(index) is not taken as a config
  assert.equal(cases[0].authorize.payer, other);
  for (const c of cases) assert.ok(c.seconds > 0 && c.seconds < 10, `seconds ${c.seconds}`);
  const s = summarize(cases);
  assert.deepEqual(s, { count: 3, paid: 1, refunded: 2, cron: 1, payersChecked: 3, external: 2, externalWallets: 1, median: s.median });
  assert.ok(s.median > 0);
});

test("docket: a batch item that errors is asked again on its own, and the per-host cap holds", async () => {
  let inFlight = 0, peak = 0, singles = 0;
  const fetchImpl = async (_u, o) => {
    inFlight++; peak = Math.max(peak, inFlight);
    await new Promise((r) => setTimeout(r, 5));
    inFlight--;
    const body = JSON.parse(o.body);
    if (!Array.isArray(body)) { singles++; return { ok: true, status: 200, json: async () => ({ jsonrpc: "2.0", id: body.id, result: "0x2" }) }; }
    return { ok: true, status: 200, json: async () => body.map((b, i) => (i === 1 ? { id: b.id, error: { message: "busy" } } : { id: b.id, result: "0x1" })) };
  };
  const rpc = makeRpc(fetchImpl, { concurrency: { "rpc.test": 2 } });
  assert.deepEqual(await rpc.batch("https://rpc.test/", [["a", []], ["b", []], ["c", []]]), ["0x1", "0x2", "0x1"]);
  assert.equal(singles, 1);
  await Promise.all(Array.from({ length: 8 }, () => rpc("https://rpc.test/", "x", [])));
  assert.ok(peak <= 2, `peak ${peak}`);
  let active = 0, top = 0;
  const lim = limiter(3);
  await Promise.all(Array.from({ length: 10 }, () => lim(async () => { active++; top = Math.max(top, active); await new Promise((r) => setTimeout(r, 2)); active--; })));
  assert.equal(top, 3);
});

test("public pages: docket keeps its CSP to the two public RPCs, and no page puts outside values into innerHTML", () => {
  const docket = readFileSync(join(PUB, "docket", "index.html"), "utf8");
  const csp = docket.match(/http-equiv="Content-Security-Policy" content="([^"]+)"/)[1];
  assert.match(csp, /connect-src https:\/\/sepolia\.base\.org https:\/\/lasna-rpc\.rnk\.dev;/);
  assert.match(csp, /default-src 'none'/);
  assert.match(csp, /script-src 'self';/);
  const server = readFileSync(join(REPO, "offchain", "src", "server.mjs"), "utf8");
  assert.ok(server.includes("connect-src https://sepolia.base.org https://lasna-rpc.rnk.dev;"), "server CSP unchanged");
  for (const f of [join(PUB, "index.html"), join(PUB, "docket", "docket.js"), join(PUB, "docket", "core.mjs")]) {
    assert.doesNotMatch(readFileSync(f, "utf8"), /innerHTML|outerHTML|insertAdjacentHTML|document\.write/, f);
  }
  // The docket reads nothing from the court's server.
  assert.doesNotMatch(readFileSync(join(PUB, "docket", "docket.js"), "utf8"), /fetch\(\s*["'`]\//);
});

test("the operator's own test wallet is not counted as outside use", async () => {
  const { payerKind, CFG } = await import("../public/docket/core.mjs");
  const c = (payer) => ({ authorize: { payer } });
  assert.equal(payerKind(c(CFG.serverBuyer)), "server");
  assert.equal(payerKind(c("0xc1661ccea7f9ce091e48807348e3dc0d8b9b9933")), "operator");
  assert.equal(payerKind(c("0x00000000000000000000000000000000000000aa")), "other");
});
