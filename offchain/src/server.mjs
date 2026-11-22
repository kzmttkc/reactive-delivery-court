#!/usr/bin/env node
// Public demo server (Base Sepolia testnet only). One process holds:
//   GET  /deliver/resource, /empty/resource   two x402 sellers anyone can pay with their own wallet
//   POST /try/deliver, /try/empty              runs the whole loop with this server's buyer role
//   POST /judge                                a buyer that paid with its own wallet posts the bytes it got
//   GET  /runs/<id>, /responses/<file>         progress of a run, judgment records and bodies
//   GET  /health                               balances, limits and the model version
// The facilitator listens on 127.0.0.1 only. The court contracts decide where the money goes.
import express from "express";
import { createHash, randomBytes } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createPublicClient, decodeEventLog, http, parseAbiItem } from "viem";
import { baseSepolia } from "viem/chains";
import { BASE_RPC, CALLBACK, ESCROW, FACILITATOR_PORT, LASNA_RPC, REACTIVE, REPO, ROLES, SELLERS, USDC, VALIDATION } from "./config.mjs";
import { roleAccount } from "./keys.mjs";
import { createFacilitator } from "./facilitator.mjs";
import { createSeller, OUTPUT_SCHEMAS } from "./seller.mjs";
import { createBuyer } from "./buyer.mjs";
import { createJudge } from "./judge.mjs";
import { loadJudge } from "./content.mjs";
import { payerSigned, perMinuteLimit } from "./judge-auth.mjs";

const PORT = Number(process.env.PORT || 8080);
const DATA = process.env.DATA_DIR || join(REPO, "offchain", "runs", "public");
const PUBLIC_URL = (process.env.PUBLIC_URL || `http://127.0.0.1:${PORT}`).replace(/\/$/, "");
const DAILY_CAP = Number(process.env.DAILY_CAP || 40); // server-paid runs per UTC day
const GAP_MS = Number(process.env.MIN_GAP_SECONDS || 30) * 1000;
const KINDS = ["deliver", "empty"];
const log = (...m) => console.log(new Date().toISOString(), ...m);
for (const d of ["runs", "responses"]) mkdirSync(join(DATA, d), { recursive: true });

const base = createPublicClient({ chain: baseSepolia, transport: http(BASE_RPC) });
const lasna = createPublicClient({ transport: http(LASNA_RPC) });
const ERC20 = [parseAbiItem("function balanceOf(address) view returns (uint256)")];
const PROXY = "0x476F44b11F5C942c58f4c8E3d0300E5710743585";
const SYSTEM = "0x0000000000000000000000000000000000fffFfF";
const DEBT = [parseAbiItem("function debt(address) view returns (uint256)")];
const RESERVES = [parseAbiItem("function reserves(address) view returns (uint256)")];
const DEPOSITED = parseAbiItem("event Deposited(bytes32 indexed paymentId, address indexed payer, address indexed receiver, uint256 amount, uint48 deadline)");
const RESOLVED = parseAbiItem("event Resolved(bytes32 indexed paymentId, bool captured, uint256 amount, uint8 score, uint8 reason)");
const PAYMENT_OPENED = parseAbiItem("event PaymentOpened(bytes32 indexed paymentId, uint48 deadline)");
const VREQ = parseAbiItem("event ValidationRequest(address indexed validatorAddress, uint256 indexed agentId, string requestURI, bytes32 indexed requestHash)");
const DECISION = parseAbiItem("event Decision(bytes32 indexed paymentId, bool capture, uint8 score, uint8 reason)");
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const json = (v) => JSON.stringify(v, (_k, x) => (typeof x === "bigint" ? x.toString() : x), 2);

// Limits for a server-paid run. Below any of them the run is refused before anything is signed.
export const LIMITS = {
  buyerUsdc: 10000n, // one payment, 0.01 USDC
  relayerEth: 3n * 10n ** 14n, // authorize gas
  sellerEth: 1n * 10n ** 14n, // validationRequest gas
  judgeEth: 1n * 10n ** 14n, // validationResponse gas
  callbackReserveEth: 2n * 10n ** 14n, // callback gas at the Reactive callback proxy
  reactiveLreact: 3n * 10n ** 17n, // react gas on Lasna (about 0.03 per run, kept at 10 runs)
};

export function checkLimits(b) {
  const low = [];
  if (b.buyerUsdc < LIMITS.buyerUsdc) low.push("buyer USDC");
  if (b.relayerEth < LIMITS.relayerEth) low.push("relayer ETH");
  if (b.sellerEth < LIMITS.sellerEth) low.push("seller ETH");
  if (b.judgeEth < LIMITS.judgeEth) low.push("judge ETH");
  if (b.callbackReserveEth < LIMITS.callbackReserveEth) low.push("callback reserve");
  if (b.callbackDebt > 0n) low.push("callback debt");
  if (b.reactiveLreact < LIMITS.reactiveLreact) low.push("reactive lREACT");
  if (b.reactiveDebt > 0n) low.push("reactive debt");
  return low;
}

async function readBalances() {
  const usdc = (a) => base.readContract({ address: USDC, abi: ERC20, functionName: "balanceOf", args: [a] });
  const [buyerUsdc, relayerEth, sellerEth, judgeEth, callbackReserveEth, callbackDebt, reactiveLreact, reactiveDebt] = await Promise.all([
    usdc(ROLES.buyer),
    base.getBalance({ address: ROLES.relayer }),
    base.getBalance({ address: ROLES["seller-deliver"] }),
    base.getBalance({ address: ROLES.judge }),
    base.readContract({ address: PROXY, abi: RESERVES, functionName: "reserves", args: [CALLBACK] }),
    base.readContract({ address: PROXY, abi: DEBT, functionName: "debt", args: [CALLBACK] }),
    lasna.getBalance({ address: REACTIVE }),
    lasna.readContract({ address: SYSTEM, abi: DEBT, functionName: "debt", args: [REACTIVE] }),
  ]);
  return { buyerUsdc, relayerEth, sellerEth, judgeEth, callbackReserveEth, callbackDebt, reactiveLreact, reactiveDebt };
}

async function waitLog(client, address, event, paymentIdOrArgs, fromBlock, timeoutMs) {
  const args = typeof paymentIdOrArgs === "string" ? { paymentId: paymentIdOrArgs } : paymentIdOrArgs;
  const t0 = Date.now();
  let from = fromBlock;
  const win = client === base ? 199n : 20000n;
  while (Date.now() - t0 < timeoutMs) {
    try {
      const head = await client.getBlockNumber();
      const to = head - from > win ? from + win : head;
      const logs = await client.getLogs({ address, event, args, fromBlock: from, toBlock: to });
      if (logs.length) return logs[0];
      from = to + 1n > head ? head : to + 1n;
    } catch {
      /* read-only, retry */
    }
    await sleep(3000);
  }
  return null;
}

// --- persistent state (UTC day counter) and run records ---
const STATE = join(DATA, "state.json");
const state = existsSync(STATE) ? JSON.parse(readFileSync(STATE, "utf8")) : { day: "", count: 0, lastStart: 0 };
const saveState = () => writeFileSync(STATE, JSON.stringify(state));
const today = () => new Date().toISOString().slice(0, 10);
const runs = new Map();
const saveRun = (r) => { runs.set(r.id, r); writeFileSync(join(DATA, "runs", `${r.id}.json`), json(r)); };
const loadRun = (id) => runs.get(id) ?? (existsSync(join(DATA, "runs", `${id}.json`)) ? JSON.parse(readFileSync(join(DATA, "runs", `${id}.json`), "utf8")) : null);
let active = null;

// Shared tail of a court run once a payment is authorized: Lasna opens it, the seller files its
// validation request, the judge scores, Lasna decides, Base Sepolia captures or voids.
async function courtTail(run, kind, paymentId, response, outputSchema, baseFrom, lasnaFrom, judge, requested) {
  const step = (k, v) => { run.steps[k] = v; saveRun(run); };
  const opened = await waitLog(lasna, REACTIVE, PAYMENT_OPENED, paymentId, lasnaFrom, 300_000);
  if (!opened) throw new Error("Lasna did not open the payment within 5 minutes");
  step("lasnaOpened", opened.transactionHash);
  const req = await requested;
  if (req?.error) throw new Error(`validationRequest failed: ${req.error}`);
  if (req?.hash) step("validationRequest", req.hash);
  const j = await judge.judge(paymentId, response, outputSchema);
  run.score = j.score;
  run.responseURI = j.responseURI;
  step("validationResponse", j.hash);
  const decision = await waitLog(lasna, REACTIVE, DECISION, paymentId, lasnaFrom, 300_000);
  if (!decision) throw new Error("Lasna did not decide within 5 minutes");
  run.decision = { capture: decision.args.capture, score: decision.args.score, reason: decision.args.reason };
  step("lasnaDecision", decision.transactionHash);
  const resolved = await waitLog(base, CALLBACK, RESOLVED, paymentId, baseFrom, 300_000);
  if (!resolved) throw new Error("the callback did not arrive within 5 minutes");
  run.resolved = { captured: resolved.args.captured, amount: resolved.args.amount.toString() };
  step("callback", resolved.transactionHash);
}

async function main() {
  const model = loadJudge();
  const fac = createFacilitator(roleAccount("relayer"), { log: (k, d) => log("[facilitator]", k, d) });
  await new Promise((r) => fac.app.listen(FACILITATOR_PORT, "127.0.0.1", r));
  const facilitatorUrl = `http://127.0.0.1:${FACILITATOR_PORT}`;
  const sellers = {};
  for (const kind of KINDS) {
    sellers[kind] = createSeller(kind, {
      account: roleAccount(SELLERS[kind].role), facilitatorUrl, deadlineSeconds: SELLERS[kind].deadlineSeconds,
      log: (m) => log(`[seller-${kind}]`, m),
    });
  }
  // Every paid request files a validation request. Keep the result per paymentId for the judge.
  const requests = new Map();
  for (const kind of KINDS) {
    sellers[kind].events.on("requested", (e) => { if (e.paymentId) requests.get(e.paymentId)?.resolve(e); });
  }
  // What each of this server's sellers actually sent, per paymentId (status + sha256), kept on the volume.
  const SERVED = join(DATA, "served.json");
  const served = existsSync(SERVED) ? JSON.parse(readFileSync(SERVED, "utf8")) : {};
  for (const kind of KINDS) {
    sellers[kind].events.on("served", (e) => {
      served[e.paymentId] = { status: e.status, bodySha256: e.bodySha256, at: new Date().toISOString() };
      const keys = Object.keys(served);
      if (keys.length > 5000) for (const k of keys.slice(0, keys.length - 5000)) delete served[k];
      writeFileSync(SERVED, JSON.stringify(served));
    });
  }
  const awaitRequest = (paymentId) => {
    let resolve;
    const p = new Promise((r) => { resolve = r; });
    requests.set(paymentId, { resolve });
    return Promise.race([p, sleep(180_000).then(() => ({ error: "no validationRequest within 3 minutes" }))]).finally(() => requests.delete(paymentId));
  };
  const buyer = createBuyer(roleAccount("buyer"));
  const uriBase = `${PUBLIC_URL}/responses`;
  const dir = join(DATA, "responses");
  const serverJudge = createJudge(roleAccount("judge"), model, { uriBase, dir, reportedBy: "buyer role of this server" });
  const postedJudge = createJudge(roleAccount("judge"), model, { uriBase, dir, reportedBy: "buyer, posted to /judge" });

  const app = express();
  app.set("trust proxy", true);
  app.disable("x-powered-by");
  for (const kind of KINDS) app.use(`/${kind}`, sellers[kind].app);
  app.use(express.json({ limit: "64kb" }));

  app.get("/", (_req, res) => res.type("html").send(PAGE));
  // Read-only docket: the browser rebuilds every case from the public RPCs, nothing from this server.
  const DOCKET_CSP = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src https://sepolia.base.org https://lasna-rpc.rnk.dev; img-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
  app.use("/docket", express.static(join(REPO, "offchain", "public", "docket"), {
    index: "index.html",
    setHeaders: (res) => {
      res.setHeader("Content-Security-Policy", DOCKET_CSP);
      res.setHeader("X-Content-Type-Options", "nosniff");
      res.setHeader("Referrer-Policy", "no-referrer");
      res.setHeader("Cache-Control", "public, max-age=300");
    },
  }));
  app.get("/ping", (_req, res) => res.type("text").send("ok"));
  app.get("/health", async (_req, res) => {
    try {
      const b = await readBalances();
      res.json({
        ok: true, network: "Base Sepolia testnet (84532) and Reactive Lasna testnet", model: "sha256:" + model.sha256,
        callback: CALLBACK, reactive: REACTIVE, escrow: ESCROW, sellers: { deliver: ROLES["seller-deliver"], empty: ROLES["seller-empty"] },
        runsToday: state.day === today() ? state.count : 0, dailyCap: DAILY_CAP, busy: Boolean(active), low: checkLimits(b),
        // While the cron is paused, a payment nobody judges is refunded only by the buyer's own reclaim after the deadline.
        cronPaused: await lasna.readContract({ address: REACTIVE, abi: [{ type: "function", name: "cronPaused", stateMutability: "view", inputs: [], outputs: [{ type: "bool" }] }], functionName: "cronPaused" }).catch(() => null),
        balances: Object.fromEntries(Object.entries(b).map(([k, v]) => [k, v.toString()])),
      });
    } catch (e) {
      res.status(503).json({ ok: false, error: e.shortMessage ?? e.message });
    }
  });

  // Payment to settlement in Base Sepolia block timestamps (authorize block to callback block), the same measure as scripts/latency.py.
  const blockSeconds = async (run) => {
    try {
      const [a, c] = await Promise.all([run.steps.authorize, run.steps.callback].map((hash) => base.getTransactionReceipt({ hash })));
      const [ba, bc] = await Promise.all([a, c].map((r) => base.getBlock({ blockNumber: r.blockNumber })));
      run.blockSeconds = Number(bc.timestamp - ba.timestamp);
    } catch { /* shown only when both blocks are known */ }
  };

  // Payments already being judged (server-paid runs and /judge). One judgment per payment.
  const judged = new Set();
  const judgeLimit = perMinuteLimit(5);

  app.post("/try/:kind", async (req, res) => {
    const kind = req.params.kind;
    if (!KINDS.includes(kind)) return res.status(404).json({ error: "kind must be deliver or empty" });
    if (active) return res.status(409).json({ error: "A run is in progress. Open it below or try again in a few minutes.", run: active });
    if (state.day !== today()) { state.day = today(); state.count = 0; }
    if (state.count >= DAILY_CAP) return res.status(429).json({ error: `Daily limit of ${DAILY_CAP} server-paid runs reached. It resets at 00:00 UTC.` });
    const wait = state.lastStart + GAP_MS - Date.now();
    if (wait > 0) return res.status(429).json({ error: `Next run can start in ${Math.ceil(wait / 1000)} s.` });
    let low;
    try { low = checkLimits(await readBalances()); } catch (e) { return res.status(503).json({ error: `Could not read balances: ${e.shortMessage ?? e.message}` }); }
    if (low.length) return res.status(503).json({ error: `Paused, low testnet balance: ${low.join(", ")}.` });
    const id = randomBytes(6).toString("hex");
    const run = { id, kind, startedAt: new Date().toISOString(), status: "running", steps: {} };
    active = id;
    state.count += 1;
    state.lastStart = Date.now();
    saveState();
    saveRun(run);
    res.status(202).json({ run: id });
    try {
      const baseFrom = await base.getBlockNumber();
      const lasnaFrom = await lasna.getBlockNumber();
      let requested = null;
      const onPaid = (e) => { if (e.paymentId && !requested) requested = awaitRequest(e.paymentId); };
      sellers[kind].events.once("paid", onPaid);
      const bought = await buyer.buy(`http://127.0.0.1:${PORT}/${kind}/resource`, { timeoutMs: 20_000 });
      sellers[kind].events.off("paid", onPaid);
      if (!bought.paymentId) throw new Error(`no payment was created: ${bought.error ?? "unknown"}`);
      run.paymentId = bought.paymentId;
      // Claim the payment before the authorize is even on chain, so /judge can never answer for it first.
      judged.add(bought.paymentId);
      run.response = bought.response ? { status: bought.response.status, bytes: bought.response.body.length } : null;
      const dep = await waitLog(base, CALLBACK, DEPOSITED, bought.paymentId, baseFrom, 120_000);
      if (!dep) throw new Error("the authorize tx was not seen within 2 minutes");
      run.steps.authorize = dep.transactionHash;
      saveRun(run);
      await courtTail(run, kind, bought.paymentId, bought.response, bought.outputSchema, baseFrom, lasnaFrom, serverJudge, requested ?? awaitRequest(bought.paymentId));
      await blockSeconds(run);
      run.status = "done";
    } catch (e) {
      run.status = "failed";
      run.error = e.shortMessage ?? e.message;
      log("run failed", id, run.error);
    } finally {
      run.finishedAt = new Date().toISOString();
      saveRun(run);
      active = null;
    }
  });

  // A buyer that paid one of the sellers with its own wallet posts the authorize tx hash, the exact
  // bytes it received, and its signature over them (judge-auth.mjs). Only the payer can report a body.
  // One judgment per payment. The record says the buyer reported the body.
  app.post("/judge", async (req, res) => {
    if (!judgeLimit(req.get("fly-client-ip") ?? req.socket.remoteAddress ?? "unknown")) return res.status(429).json({ error: "at most 5 /judge calls a minute per caller" });
    const { authorizeTx, status, bodyBase64 = "", latencyMs = 1000, signature } = req.body ?? {};
    if (!/^0x[0-9a-fA-F]{64}$/.test(String(authorizeTx))) return res.status(400).json({ error: "authorizeTx must be a 32-byte tx hash" });
    if (!Number.isInteger(status) || status < 100 || status > 599) return res.status(400).json({ error: "status must be the HTTP status the buyer received" });
    let body;
    try { body = Buffer.from(String(bodyBase64), "base64"); } catch { return res.status(400).json({ error: "bodyBase64 is not base64" }); }
    let receipt;
    try { receipt = await base.getTransactionReceipt({ hash: authorizeTx }); } catch { return res.status(404).json({ error: "authorizeTx not found on Base Sepolia" }); }
    const dep = receipt.logs.filter((l) => l.address.toLowerCase() === CALLBACK.toLowerCase())
      .map((l) => { try { return decodeEventLog({ abi: [DEPOSITED], data: l.data, topics: l.topics }); } catch { return null; } })
      .find((d) => d?.eventName === "Deposited");
    if (!dep) return res.status(400).json({ error: "that tx has no Deposited event from the court" });
    const kind = KINDS.find((k) => ROLES[`seller-${k}`].toLowerCase() === dep.args.receiver.toLowerCase());
    if (!kind) return res.status(400).json({ error: "that payment is not to one of this server's sellers" });
    const paymentId = dep.args.paymentId;
    if (dep.args.payer.toLowerCase() === ROLES.buyer.toLowerCase()) return res.status(409).json({ error: "this payment was made by the server's own buyer and is judged by the server" });
    if (judged.has(paymentId) || existsSync(join(DATA, "responses", `${paymentId}.json`))) return res.status(409).json({ error: "already judged" });
    // The court has the seller's own copy for its sellers: a buyer cannot report a different body or status.
    const sent = served[paymentId];
    const postedSha = "0x" + createHash("sha256").update(body).digest("hex");
    if (sent && (sent.bodySha256 !== postedSha || sent.status !== status)) {
      return res.status(409).json({ error: "the posted body or status differs from what the seller sent for this payment", seller: { status: sent.status, bodySha256: sent.bodySha256 } });
    }
    if (!(await payerSigned({ payer: dep.args.payer, paymentId, body, status, signature }))) {
      return res.status(401).json({ error: "signature must be the payer's EIP-191 signature over delivery-court:judge:<paymentId>:0x<sha256(body)>:<status>" });
    }
    judged.add(paymentId);
    const id = randomBytes(6).toString("hex");
    const run = { id, kind, paymentId, startedAt: new Date().toISOString(), status: "running", steps: { authorize: authorizeTx }, response: { status, bytes: body.length }, posted: true };
    saveRun(run);
    res.status(202).json({ run: id, paymentId });
    try {
      const lasnaFrom = (await lasna.getBlockNumber()) - 3000n;
      // The seller filed its validation request when it answered. The score goes out only after
      // that request is on chain, so the registry pairs them.
      const requested = waitLog(base, VALIDATION, VREQ, { validatorAddress: ROLES.judge, requestHash: paymentId }, receipt.blockNumber, 180_000)
        .then((l) => (l ? { hash: l.transactionHash } : { error: "no validationRequest from the seller within 3 minutes" }));
      await courtTail(run, kind, paymentId, { status, body, latencyMs: Number(latencyMs) || 1000 }, OUTPUT_SCHEMAS[kind] ?? null,
        receipt.blockNumber, lasnaFrom > 0n ? lasnaFrom : 0n, postedJudge, requested);
      await blockSeconds(run);
      run.status = "done";
    } catch (e) {
      run.status = "failed";
      run.error = e.shortMessage ?? e.message;
    } finally {
      run.finishedAt = new Date().toISOString();
      saveRun(run);
    }
  });

  app.get("/runs/:id", (req, res) => {
    if (!/^[0-9a-f]{12}$/.test(req.params.id)) return res.status(400).json({ error: "bad id" });
    const r = loadRun(req.params.id);
    return r ? res.type("json").send(json(r)) : res.status(404).json({ error: "no such run" });
  });
  app.get("/responses/:file", (req, res) => {
    const f = req.params.file;
    if (!/^0x[0-9a-f]{64}\.(json|body)$/.test(f)) return res.status(400).json({ error: "bad file name" });
    const p = join(DATA, "responses", f);
    if (!existsSync(p)) return res.status(404).json({ error: "not found" });
    res.type(f.endsWith(".json") ? "json" : "application/octet-stream").send(readFileSync(p));
  });

  app.listen(PORT, "0.0.0.0", () => log(`listening on ${PORT}, public URL ${PUBLIC_URL}, model sha256:${model.sha256}`));
}

const PAGE = readFileSync(join(REPO, "offchain", "public", "index.html"), "utf8");
if (process.argv[1] && process.argv[1].endsWith("server.mjs")) main().catch((e) => { console.error("FAILED", e.message); process.exit(1); });
