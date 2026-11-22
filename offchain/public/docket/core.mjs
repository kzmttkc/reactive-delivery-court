// Court docket core: rebuilds every case from the chain, read-only. Runs in the browser and in Node.
// Sources: Reactive Lasna logs of DeliveryCourtReactive (PaymentOpened, Decision), then Base Sepolia
// logs of DeliveryCourtCallback (Deposited, Resolved) and their block timestamps.
// No keys, no writes. Every value shown comes from an RPC response.
export const CFG = {
  base: "https://sepolia.base.org",
  lasna: "https://lasna-rpc.rnk.dev/",
  reactive: "0x7fef8eaf662cfb82adaa1ca3e45821a866cc4d51",
  callback: "0xd80dfba59a5930b943d0eb5225e292b0ffb9d84a",
  // The buyer role of the court's own server (deployments/roles.json). Payments from any other
  // payer came from someone else's wallet.
  serverBuyer: "0xbd857a30e35ba99f8edab20b41baa3a4272c154d",
  // Wallets the operator made for its own tests (funded from the server's buyer). They are not outside use.
  operatorWallets: ["0xc1661ccea7f9ce091e48807348e3dc0d8b9b9933"],
  topics: {
    opened: "0x50d9b4195ccd839269b479e5d874d2471442279002b9312647e99c324001e385", // PaymentOpened(bytes32,uint48)
    decision: "0xebe45331b461145197da5ebfa6dcec2f0a30b30b7accf8676c218436fa2afa84", // Decision(bytes32,bool,uint8,uint8)
    deposited: "0x8148d07b886b81d23cb0f6b4f7e3f176079816415273e329f68e973414dbcd23", // Deposited(bytes32 indexed,address indexed payer,address indexed receiver,uint256,uint48)
    resolved: "0x851dfe7d538d719735b69b7eae51ddbb2c1d373486e896e82db8a148103b7566", // Resolved(bytes32,bool,uint256,uint8,uint8)
  },
  lasnaRange: 29_999, // RPC limit 30,000 blocks (checked 2026-11-22)
  baseRange: 199, // RPC limit 200 blocks
  baseBlockSeconds: 0.2, // exact on Base Sepolia (checked 2026-11-22 over 400,000 blocks)
  // Requests in flight per RPC host. The RPCs are public: a few at a time, with batching, is enough.
  concurrency: { "sepolia.base.org": 4, "lasna-rpc.rnk.dev": 2 },
  batchSize: 25,
};

const HEX32 = /^0x[0-9a-f]{64}$/;
const hexToInt = (h) => {
  if (typeof h !== "string" || !/^0x[0-9a-fA-F]+$/.test(h)) throw new Error("bad hex from RPC");
  return Number(BigInt(h));
};
const toHex = (n) => "0x" + Math.max(0, Math.floor(n)).toString(16);
const word = (data, i) => "0x" + data.slice(2 + 64 * i, 2 + 64 * (i + 1));
const topicAddress = (t) => (typeof t === "string" && /^0x0{24}[0-9a-fA-F]{40}$/.test(t) ? ("0x" + t.slice(26)).toLowerCase() : null);
const sleep = (ms) => new Promise((ok) => setTimeout(ok, ms));

/** At most `n` calls of `fn` at once. */
export function limiter(n) {
  let active = 0;
  const queue = [];
  const next = () => {
    if (active >= n || !queue.length) return;
    active++;
    const { fn, ok, fail } = queue.shift();
    Promise.resolve().then(fn).then(ok, fail).finally(() => { active--; next(); });
  };
  return (fn) => new Promise((ok, fail) => { queue.push({ fn, ok, fail }); next(); });
}

/** Runs `fn` over `items` with at most `n` in flight, in order of the list. */
export async function pool(items, n, fn) {
  const lim = limiter(n);
  return Promise.all(items.map((it, i) => lim(() => fn(it, i))));
}

/**
 * JSON-RPC client. rpc(url, method, params) for one call, rpc.batch(url, [[method, params], ...]) for
 * several in one request. Requests are capped per host (cfg.concurrency) and retried with backoff.
 */
export function makeRpc(fetchImpl = fetch, { concurrency = CFG.concurrency, fallback = 4 } = {}) {
  let id = 0;
  const lims = new Map();
  const lim = (url) => {
    const host = new URL(url).host;
    if (!lims.has(host)) lims.set(host, limiter(concurrency[host] ?? fallback));
    return lims.get(host);
  };
  const post = async (url, body) => {
    const r = await lim(url)(() => fetchImpl(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) }));
    return { status: r.status, j: r.ok ? await r.json().catch(() => null) : null };
  };
  const rpc = async (url, method, params) => {
    // Public RPCs rate-limit; back off and retry a few times before giving up.
    for (let attempt = 0; ; attempt++) {
      const { status, j } = await post(url, { jsonrpc: "2.0", id: ++id, method, params });
      if (j && !j.error && j.result !== undefined) return j.result;
      if (attempt >= 4) throw new Error(`${method}: ${j?.error?.message ?? "HTTP " + status}`);
      await sleep(500 * 2 ** attempt);
    }
  };
  rpc.batch = async (url, calls) => {
    if (!calls.length) return [];
    const ids = calls.map(() => ++id);
    let res = null;
    try {
      const { j } = await post(url, calls.map(([method, params], i) => ({ jsonrpc: "2.0", id: ids[i], method, params })));
      if (Array.isArray(j)) res = new Map(j.map((x) => [x?.id, x]));
    } catch { /* fall back to single calls below */ }
    // Any item the batch did not answer is asked again on its own (with retries).
    return Promise.all(calls.map(([method, params], i) => {
      const x = res?.get(ids[i]);
      return x && !x.error && x.result !== undefined ? x.result : rpc(url, method, params);
    }));
  };
  return rpc;
}

// Block timestamps, cached per chain. Every resolved (block, ts) is also kept as a known point.
const pointsOf = (cache, url) => {
  const k = "points:" + url;
  if (!cache.has(k)) cache.set(k, []);
  return cache.get(k);
};
export async function blockTs(rpc, url, n, cache) {
  const k = url + n;
  if (!cache.has(k)) {
    cache.set(k, rpc(url, "eth_getBlockByNumber", [toHex(n), false]).then((b) => {
      const ts = hexToInt(b.timestamp);
      pointsOf(cache, url).push({ block: n, ts });
      return ts;
    }));
  }
  return cache.get(k);
}
/** Timestamps of many blocks in batched requests. */
export async function blockTimes(rpc, url, blocks, cache, size = CFG.batchSize) {
  const missing = [...new Set(blocks)].filter((n) => !cache.has(url + n));
  const chunks = [];
  for (let i = 0; i < missing.length; i += size) chunks.push(missing.slice(i, i + size));
  for (const chunk of chunks) {
    const p = (rpc.batch ? rpc.batch(url, chunk.map((n) => ["eth_getBlockByNumber", [toHex(n), false]]))
      : Promise.all(chunk.map((n) => rpc(url, "eth_getBlockByNumber", [toHex(n), false]))));
    chunk.forEach((n, i) => cache.set(url + n, p.then((bs) => {
      const ts = hexToInt(bs[i].timestamp);
      pointsOf(cache, url).push({ block: n, ts });
      return ts;
    })));
  }
  return Promise.all(blocks.map((n) => cache.get(url + n)));
}

/** Every case the court opened or decided on Lasna in the last `hours`. Newest first. */
export async function lasnaCases(rpc, { hours = 24, cfg = CFG, cache = new Map() } = {}) {
  const head = hexToInt(await rpc(cfg.lasna, "eth_blockNumber", []));
  const span = Math.ceil(hours * 3600); // ~1 s blocks
  const ranges = [];
  for (let to = head; to > head - span; to -= cfg.lasnaRange + 1) ranges.push([Math.max(0, to - cfg.lasnaRange, head - span), to]);
  // The windows are independent: ask for them together (the per-host cap keeps it polite).
  const chunks = await Promise.all(ranges.map(([from, to]) => rpc(cfg.lasna, "eth_getLogs", [{ address: cfg.reactive, fromBlock: toHex(from), toBlock: toHex(to), topics: [[cfg.topics.opened, cfg.topics.decision]] }])));
  const cases = new Map();
  for (const l of chunks.flat()) {
    const id = String(l.topics[1]).toLowerCase();
    if (!HEX32.test(id)) continue;
    const c = cases.get(id) ?? { paymentId: id };
    const blk = hexToInt(l.blockNumber);
    if (l.topics[0] === cfg.topics.opened) {
      c.opened = { tx: l.transactionHash, block: blk, deadline: hexToInt(word(l.data, 0)) };
    } else {
      c.decision = { tx: l.transactionHash, block: blk, capture: hexToInt(word(l.data, 0)) === 1, score: hexToInt(word(l.data, 1)), reason: hexToInt(word(l.data, 2)) };
    }
    cases.set(id, c);
  }
  // Lasna logs carry blockTimestamp 0x0, so the blocks are read, many per request.
  const all = [...cases.values()];
  const blocks = all.flatMap((c) => [c.opened?.block, c.decision?.block]).filter((n) => n != null);
  await blockTimes(rpc, cfg.lasna, blocks, cache);
  for (const c of all) {
    if (c.opened) c.opened.ts = await blockTs(rpc, cfg.lasna, c.opened.block, cache);
    if (c.decision) c.decision.ts = await blockTs(rpc, cfg.lasna, c.decision.block, cache);
  }
  return all.sort((a, b) => (b.opened?.ts ?? b.decision?.ts ?? 0) - (a.opened?.ts ?? a.decision?.ts ?? 0));
}

/** Base Sepolia block at unix time `ts`, from the nearest block whose timestamp is known. */
function baseEstimate(cfg, anchor, ts, cache) {
  let best = anchor;
  for (const p of pointsOf(cache, cfg.base)) if (Math.abs(p.ts - ts) < Math.abs(best.ts - ts)) best = p;
  return Math.min(anchor.block, best.block + Math.round((ts - best.ts) / cfg.baseBlockSeconds));
}
// Checks the estimate against real block timestamps (used only when the quick guess missed).
async function baseBlockAt(rpc, cfg, anchor, ts, cache) {
  let est = baseEstimate(cfg, anchor, ts, cache);
  for (let i = 0; i < 3; i++) {
    const got = await blockTs(rpc, cfg.base, Math.min(est, anchor.block), cache);
    const step = Math.round((ts - got) / cfg.baseBlockSeconds);
    if (Math.abs(step) <= 5) break;
    est = Math.min(est + step, anchor.block);
  }
  return est;
}
/** Finds the Base Sepolia log of `topic` for paymentId near unix time `ts` (200-block windows). */
async function baseLogNear(rpc, cfg, anchor, topic, paymentId, ts, windows, cache) {
  const search = async (est) => {
    for (const [lo, hi] of windows) {
      const from = est + lo, to = Math.min(est + hi, anchor.block);
      if (to < from) continue;
      const logs = await rpc(cfg.base, "eth_getLogs", [{ address: cfg.callback, fromBlock: toHex(from), toBlock: toHex(to), topics: [topic, paymentId] }]);
      if (logs.length) return { tx: logs[0].transactionHash, block: hexToInt(logs[0].blockNumber), topics: logs[0].topics };
    }
    return null;
  };
  const quick = baseEstimate(cfg, anchor, ts, cache);
  const hit = await search(quick);
  if (hit) return hit;
  const checked = await baseBlockAt(rpc, cfg, anchor, ts, cache);
  return checked === quick ? null : search(checked);
}

/** Adds the Base Sepolia authorize (with its payer) and callback tx and the block-timestamp seconds between them. */
export async function enrichOnBase(rpc, c, { cfg = CFG, cache = new Map() } = {}) {
  if (!cache.has("anchor")) {
    cache.set("anchor", (async () => {
      const block = hexToInt(await rpc(cfg.base, "eth_blockNumber", []));
      return { block, ts: await blockTs(rpc, cfg.base, block, cache) };
    })());
  }
  const anchor = await cache.get("anchor");
  const [authorize, callback] = await Promise.all([
    // Deposited lands in the same second or one second before Lasna opens the case.
    c.opened ? baseLogNear(rpc, cfg, anchor, cfg.topics.deposited, c.paymentId, c.opened.ts, [[-120, 79], [-320, -121], [80, 279]], cache) : null,
    // The callback lands 1 to 3 s after the Lasna decision.
    c.decision ? baseLogNear(rpc, cfg, anchor, cfg.topics.resolved, c.paymentId, c.decision.ts, [[-20, 179], [180, 379], [380, 579]], cache) : null,
  ]);
  if (authorize) {
    c.authorize = { tx: authorize.tx, block: authorize.block, payer: topicAddress(authorize.topics?.[2]), receiver: topicAddress(authorize.topics?.[3]) };
  }
  if (callback) c.callback = { tx: callback.tx, block: callback.block };
  const [ta, tc] = await Promise.all([c.authorize && blockTs(rpc, cfg.base, c.authorize.block, cache), c.callback && blockTs(rpc, cfg.base, c.callback.block, cache)]);
  if (c.authorize) c.authorize.ts = ta;
  if (c.callback) c.callback.ts = tc;
  if (c.authorize && c.callback) c.seconds = c.callback.ts - c.authorize.ts;
  return c;
}

/** "server" for the court's own buyer, "operator" for the operator's own test wallets, "other" for any other payer, null while unknown. */
export function payerKind(c, cfg = CFG) {
  const p = c.authorize?.payer;
  if (!p) return null;
  if (p === (cfg?.serverBuyer ?? CFG.serverBuyer)) return "server";
  if ((cfg?.operatorWallets ?? CFG.operatorWallets ?? []).includes(p)) return "operator";
  return "other";
}

/** Counts for the docket summary. */
export function summarize(cases, cfg = CFG) {
  const decided = cases.filter((c) => c.decision);
  const paid = decided.filter((c) => c.decision.capture).length;
  const refunded = decided.length - paid;
  const cron = decided.filter((c) => !c.decision.capture && c.decision.reason === 2).length;
  const known = cases.filter((c) => payerKind(c, cfg));
  const others = known.filter((c) => payerKind(c, cfg) === "other");
  const secs = cases.filter((c) => c.seconds != null && c.decision?.capture).map((c) => c.seconds).sort((a, b) => a - b);
  return {
    count: cases.length, paid, refunded, cron,
    payersChecked: known.length, external: others.length, externalWallets: new Set(others.map((c) => c.authorize.payer)).size,
    median: secs.length ? secs[Math.floor((secs.length - 1) / 2)] : null,
  };
}

export function outcome(c) {
  if (!c.decision) return { label: "OPEN", note: "waiting for a score or the deadline" };
  if (c.decision.capture) return { label: "PAID", note: `score ${c.decision.score} (pays at 70 or more)` };
  // Reasons: 1 below 70, 2 no score by the deadline (v1 also used 2 for a late score), 3 empty body hash,
  // 4 no facts tag, 5 facts contradict the hash, 6 score after the deadline (v2).
  const r = c.decision.reason;
  if (r === 2) return { label: "REFUNDED", note: c.decision.score ? `score ${c.decision.score} came after the deadline` : "no score by the deadline, Reactive cron" };
  if (r === 3) return { label: "REFUNDED", note: "empty body (its hash), whatever the judge said" };
  if (r === 4) return { label: "REFUNDED", note: "the judge wrote no facts tag" };
  if (r === 5) return { label: "REFUNDED", note: "facts tag contradicts the body hash" };
  if (r === 6) return { label: "REFUNDED", note: `score ${c.decision.score} came after the deadline` };
  return { label: "REFUNDED", note: `score ${c.decision.score} (below 70)` };
}
