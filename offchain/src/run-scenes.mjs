#!/usr/bin/env node
// Runs the demo scenes end to end over x402 HTTP on Base Sepolia and Lasna.
//   node src/run-scenes.mjs deliver empty silent     (any subset, in order)
//   node src/run-scenes.mjs --verify-only deliver    (signs and verifies, sends nothing)
// Starts the facilitator (relayer role) and the three sellers locally, buys with the buyer
// role, scores with the judge role, then waits for the court's decision on both chains.
// Writes runs/<scene>.json with every tx hash, the body sha256, the score and balances.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createPublicClient, http, parseAbiItem } from "viem";
import { baseSepolia } from "viem/chains";
import { decodePaymentResponseHeader } from "@x402/core/http";
import { x402Client, x402HTTPClient } from "@x402/fetch";
import { toClientEvmSigner } from "@x402/evm";
import { AuthCaptureEvmScheme } from "@x402/evm/auth-capture/client";
import { BASE_RPC, CALLBACK, ESCROW, FACILITATOR_PORT, LASNA_RPC, REACTIVE, REPO, ROLES, SELLERS, USDC } from "./config.mjs";
import { roleAccount } from "./keys.mjs";
import { createFacilitator } from "./facilitator.mjs";
import { createSeller } from "./seller.mjs";
import { createBuyer } from "./buyer.mjs";
import { createJudge } from "./judge.mjs";
import { loadJudge } from "./content.mjs";

const args = process.argv.slice(2);
const verifyOnly = args.includes("--verify-only");
// --repeat N runs each scene N times and writes runs/<out>/<scene>-<i>.json (latency runs).
const opt = (name, dflt) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : dflt; };
const repeat = Number(opt("--repeat", "0"));
const outDir = opt("--out", "");
const scenes = args.filter((a, i) => !a.startsWith("--") && !["--repeat", "--out"].includes(args[i - 1]));
const log = (...m) => console.log(new Date().toISOString().slice(11, 19), ...m);

const base = createPublicClient({ chain: baseSepolia, transport: http(BASE_RPC) });
const lasna = createPublicClient({ transport: http(LASNA_RPC) });
const ERC20 = [parseAbiItem("function balanceOf(address) view returns (uint256)")];
const ESCROW_ABI = [parseAbiItem("function getTokenStore(address) view returns (address)")];
const RESOLVED = parseAbiItem("event Resolved(bytes32 indexed paymentId, bool captured, uint256 amount, uint8 score, uint8 reason)");
const DEPOSITED = parseAbiItem("event Deposited(bytes32 indexed paymentId, address indexed payer, address indexed receiver, uint256 amount, uint48 deadline)");
const FEEDBACK = parseAbiItem("event FeedbackGiven(bytes32 indexed paymentId, uint256 indexed agentId, uint8 score)");
const PAYMENT_OPENED = parseAbiItem("event PaymentOpened(bytes32 indexed paymentId, uint48 deadline)");
const DECISION = parseAbiItem("event Decision(bytes32 indexed paymentId, bool capture, uint8 score, uint8 reason)");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const listen = (app, port) => new Promise((res) => { const s = app.listen(port, "127.0.0.1", () => res(s)); });

async function balances(seller, blockNumber) {
  const store = await base.readContract({ address: ESCROW, abi: ESCROW_ABI, functionName: "getTokenStore", args: [CALLBACK] });
  const bal = (a) => base.readContract({ address: USDC, abi: ERC20, functionName: "balanceOf", args: [a], blockNumber });
  const [buyer, sel, held] = await Promise.all([bal(ROLES.buyer), bal(seller), bal(store)]);
  return { buyerUsdc: buyer.toString(), sellerUsdc: sel.toString(), escrowStoreUsdc: held.toString(), tokenStore: store };
}

async function waitLog(client, address, event, paymentId, fromBlock, timeoutMs, label) {
  const t0 = Date.now();
  let from = fromBlock;
  while (Date.now() - t0 < timeoutMs) {
    try {
      const head = await client.getBlockNumber();
      const win = client === base ? 199n : 20000n; // public RPC getLogs caps: Base Sepolia 200 blocks, Lasna 30000
      const to = head - from > win ? from + win : head;
      const logs = await client.getLogs({ address, event, args: { paymentId }, fromBlock: from, toBlock: to });
      if (logs.length) return logs[0];
      from = to + 1n > head ? head : to + 1n;
    } catch (e) {
      log(`[${label}] RPC error, retrying: ${e.shortMessage ?? e.message}`); // read-only, safe to retry
    }
    await sleep(3000);
  }
  throw new Error(`timeout waiting for ${label}`);
}

// Read-only: rebuilds runs/<scene>.json from chain logs when a live run lost its connection
// after the payment. Balances are read at the blocks before the authorize, at the authorize
// and at the callback. Sends nothing.
async function collect(kind, paymentId, baseFrom, lasnaFrom) {
  const sellerAddr = ROLES[`seller-${kind}`];
  const dep = await waitLog(base, CALLBACK, DEPOSITED, paymentId, baseFrom, 60_000, "Deposited");
  const opened = await waitLog(lasna, REACTIVE, PAYMENT_OPENED, paymentId, lasnaFrom, 60_000, "PaymentOpened");
  const decision = await waitLog(lasna, REACTIVE, DECISION, paymentId, lasnaFrom, 60_000, "Decision");
  const resolved = await waitLog(base, CALLBACK, RESOLVED, paymentId, baseFrom, 60_000, "Resolved");
  const fb = await base.getLogs({ address: CALLBACK, event: FEEDBACK, args: { paymentId }, fromBlock: resolved.blockNumber, toBlock: resolved.blockNumber });
  const file = join(REPO, "offchain", "runs", `${kind}.json`);
  const live = existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : {};
  const chain = {
    scene: kind, collectedFromChainAt: new Date().toISOString(), modelSha256: loadJudge().sha256, paymentId,
    before: await balances(sellerAddr, dep.blockNumber - 1n),
    authorizeTx: dep.transactionHash,
    whileHeld: await balances(sellerAddr, dep.blockNumber),
    depositedReactTx: opened.transactionHash,
    decisionReactTx: decision.transactionHash,
    decision: { capture: decision.args.capture, score: decision.args.score, reason: decision.args.reason },
    callbackTx: resolved.transactionHash,
    resolved: { captured: resolved.args.captured, amount: resolved.args.amount.toString(), score: resolved.args.score, reason: resolved.args.reason },
    feedbackGiven: fb.length > 0,
    after: await balances(sellerAddr, resolved.blockNumber),
  };
  const out = { ...chain, ...live }; // a live record wins, the chain only fills what it lacks
  writeFileSync(file, JSON.stringify(out, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2) + "\n");
  log(JSON.stringify(out, (_k, v) => (typeof v === "bigint" ? v.toString() : v)));
}

async function main() {
  if (args[0] === "--collect") return collect(args[1], args[2], BigInt(args[3]), BigInt(args[4]));
  const model = loadJudge();
  log(`model version (judge.json) sha256 ${model.sha256}`);
  const settles = [];
  const fac = createFacilitator(roleAccount("relayer"), {
    log: (kind, detail) => { log(`[facilitator] ${kind} ${detail}`); if (kind === "settle") settles.push(detail); },
  });
  const servers = [await listen(fac.app, FACILITATOR_PORT)];
  const facilitatorUrl = `http://127.0.0.1:${FACILITATOR_PORT}`;
  const sellers = {};
  for (const [kind, cfg] of Object.entries(SELLERS)) {
    sellers[kind] = createSeller(kind, {
      account: roleAccount(cfg.role), facilitatorUrl, deadlineSeconds: cfg.deadlineSeconds,
      log: (m) => log(`[seller-${kind}] ${m}`),
    });
    servers.push(await listen(sellers[kind].app, cfg.port));
  }
  const buyer = createBuyer(roleAccount("buyer"));
  const judge = createJudge(roleAccount("judge"), model);
  const runDir = join(REPO, "offchain", "runs", outDir);
  mkdirSync(runDir, { recursive: true });
  const plan = repeat > 0 ? scenes.flatMap((k) => Array.from({ length: repeat }, (_, i) => [k, `${k}-${String(i + 1).padStart(2, "0")}`]))
    : scenes.map((k) => [k, k]);

  try {
    for (const [kind, name] of plan) {
      const cfg = SELLERS[kind];
      const url = `http://127.0.0.1:${cfg.port}/resource`;
      const sellerAddr = ROLES[`seller-${kind}`];
      log(`=== scene ${name} ${url}`);
      if (verifyOnly) {
        // Sign a real payment and run the facilitator's verify (signature checks and the
        // eth_simulateV1 dry run of the custom-operator authorize). Nothing is sent.
        const res = await fetch(url);
        const http402 = new x402HTTPClient(
          new x402Client().register("eip155:84532", new AuthCaptureEvmScheme(toClientEvmSigner(roleAccount("buyer"), base))),
        );
        const required = http402.getPaymentRequiredResponse((n) => res.headers.get(n), undefined);
        const payload = await http402.createPaymentPayload(required);
        const v = await fac.facilitator.verify(payload, payload.accepted);
        log(`unpaid status ${res.status}, verify ${JSON.stringify(v)}`);
        continue;
      }
      const before = await balances(sellerAddr);
      const baseFrom = await base.getBlockNumber();
      const lasnaFrom = await lasna.getBlockNumber();
      const requested = new Promise((resolve) => sellers[kind].events.once("requested", resolve));
      const nSettles = settles.length;
      const bought = await buyer.buy(url, { timeoutMs: 20_000 });
      const out = { scene: kind, run: name, startedAt: new Date().toISOString(), modelSha256: model.sha256, paymentId: bought.paymentId, before };
      if (bought.response) {
        const pr = bought.response.headers["payment-response"];
        out.paymentResponse = pr ? decodePaymentResponseHeader(pr) : null;
        out.response = {
          status: bought.response.status, bodyBytes: bought.response.body.length, latencyMs: bought.response.latencyMs,
          body: bought.response.body.toString("utf8").slice(0, 500),
        };
      } else {
        out.response = null;
        out.buyerError = bought.error;
      }
      log(`paymentId ${bought.paymentId} response ${bought.response ? bought.response.status + " " + bought.response.body.length + "B" : bought.error}`);
      if (!bought.paymentId) throw new Error("no payment was created");

      const dep = await waitLog(base, CALLBACK, DEPOSITED, bought.paymentId, baseFrom, 120_000, "Deposited");
      out.authorizeTx = dep.transactionHash;
      out.authorizeBlock = dep.blockNumber;
      out.facilitatorSettle = settles.slice(nSettles);
      log(`authorize ${dep.transactionHash}`);
      out.whileHeld = await balances(sellerAddr);
      const opened = await waitLog(lasna, REACTIVE, PAYMENT_OPENED, bought.paymentId, lasnaFrom, 300_000, "PaymentOpened on Lasna");
      out.depositedReactTx = opened.transactionHash;
      log(`Lasna PaymentOpened ${opened.transactionHash}`);

      if (kind !== "silent") {
        const req = await requested;
        if (req.error) throw new Error(`validationRequest failed: ${req.error}`);
        out.validationRequestTx = req.hash;
        out.outputSchema = bought.outputSchema;
        const j = await judge.judge(bought.paymentId, bought.response, bought.outputSchema);
        out.judgment = { tx: j.hash, status: j.status, score: j.score, bodySha256: j.bodySha256, responseURI: j.responseURI, record: j.record };
        writeFileSync(join(runDir, `${name}.body`), bought.response ? bought.response.body : Buffer.alloc(0));
        log(`validationResponse score ${j.score} ${j.hash} ${j.status}`);
      }

      const decision = await waitLog(lasna, REACTIVE, DECISION, bought.paymentId, lasnaFrom, kind === "silent" ? 900_000 : 300_000, "Decision on Lasna");
      out.decisionReactTx = decision.transactionHash;
      out.decision = { capture: decision.args.capture, score: decision.args.score, reason: decision.args.reason };
      log(`Lasna Decision capture=${decision.args.capture} score=${decision.args.score} reason=${decision.args.reason} ${decision.transactionHash}`);
      const resolved = await waitLog(base, CALLBACK, RESOLVED, bought.paymentId, baseFrom, 300_000, "Resolved callback");
      out.callbackTx = resolved.transactionHash;
      out.callbackBlock = resolved.blockNumber;
      out.resolved = { captured: resolved.args.captured, amount: resolved.args.amount.toString(), score: resolved.args.score, reason: resolved.args.reason };
      log(`callback ${resolved.args.captured ? "capture" : "void"} ${resolved.transactionHash}`);
      const fb = await base.getLogs({ address: CALLBACK, event: FEEDBACK, args: { paymentId: bought.paymentId }, fromBlock: resolved.blockNumber, toBlock: resolved.blockNumber });
      out.feedbackGiven = fb.length > 0;
      await sleep(2000);
      out.after = await balances(sellerAddr);
      out.finishedAt = new Date().toISOString();
      writeFileSync(join(runDir, `${name}.json`), JSON.stringify(out, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2) + "\n");
      log(`balances before ${JSON.stringify(before)} after ${JSON.stringify(out.after)}`);
    }
  } finally {
    for (const s of Object.values(sellers)) for (const r of s.ctx.held) r.socket?.destroy();
    for (const s of servers) { s.closeAllConnections(); s.close(); }
  }
}

main().catch((e) => { console.error("FAILED", e.shortMessage ?? e.message); process.exit(1); });
