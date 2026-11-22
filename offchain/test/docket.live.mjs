// Live, read-only check of the docket core against the public RPCs (not part of npm test).
// node test/docket.live.mjs [hours=24] [rows=5] [all]
//   rows: cases matched on Base Sepolia one after another (as before, to compare timings)
//   all:  then match every case in the window the way the browser does, and print the summary
import { enrichOnBase, lasnaCases, makeRpc, outcome, payerKind, pool, summarize } from "../public/docket/core.mjs";
const rpc = makeRpc((u, o) => fetch(u, { ...o, headers: { ...o.headers, "user-agent": "docket-test/1" } }));
const t0 = Date.now();
const cache = new Map();
const cases = await lasnaCases(rpc, { hours: Number(process.argv[2] || 24), cache });
console.log("cases", cases.length, "lasna ms", Date.now() - t0);
for (const c of cases.slice(0, Number(process.argv[3] || 5))) {
  await enrichOnBase(rpc, c, { cache });
  const o = outcome(c);
  console.log(c.paymentId.slice(0, 10), o.label, o.note, "seconds", c.seconds, "authorize", c.authorize?.tx?.slice(0, 10), "callback", c.callback?.tx?.slice(0, 10), "payer", payerKind(c));
}
console.log("rows ms", Date.now() - t0);
if (process.argv[4] === "all") {
  await pool(cases, 6, (c) => (c.authorize || c.callback ? c : enrichOnBase(rpc, c, { cache }).catch(() => c)));
  console.log("summary", JSON.stringify(summarize(cases)), "all ms", Date.now() - t0);
  const others = cases.filter((c) => payerKind(c) === "other").map((c) => `${c.paymentId.slice(0, 10)} ${c.authorize.payer} ${outcome(c).label}`);
  if (others.length) console.log("other payers\n" + others.join("\n"));
}
