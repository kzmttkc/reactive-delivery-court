import { CFG, enrichOnBase, lasnaCases, makeRpc, outcome, payerKind, pool, summarize } from "./core.mjs";

const B = "https://sepolia.basescan.org/", L = "https://lasna.reactscan.net/tx/";
const $ = (id) => document.getElementById(id);
const el = (tag, text, cls) => { const e = document.createElement(tag); if (text != null) e.textContent = text; if (cls) e.className = cls; return e; };
const short = (h) => `${h.slice(0, 8)}…${h.slice(-4)}`;
const fmt = (ts) => new Date(ts * 1000).toISOString().replace("T", " ").slice(0, 16) + " UTC";
const ext = (a) => { a.target = "_blank"; a.rel = "noopener noreferrer"; return a; };
const link = (base, h, label) => { if (!h || !/^0x[0-9a-fA-F]{64}$/.test(h)) return el("span", "–", "mut"); const a = el("a", label ?? short(h)); a.href = base + h; return ext(a); };
const addr = (a) => { const x = el("a", `${a.slice(0, 6)}…${a.slice(-4)}`); x.href = B + "address/" + a; return ext(x); };

const rpc = makeRpc((u, o) => fetch(u, { ...o, cache: "no-store", credentials: "omit", referrerPolicy: "no-referrer" }));
const hours = Math.min(168, Math.max(1, Number(new URLSearchParams(location.search).get("hours")) || 24));

function cell(label, ...kids) { const td = el("td"), box = el("div"); td.dataset.label = label; box.append(...kids); td.append(box); return td; }

function row(c, pending) {
  const tr = el("tr");
  const o = outcome(c);
  const kind = o.label === "PAID" ? "ok" : o.label === "REFUNDED" ? "ng" : "wait";
  tr.append(cell("Opened", c.opened ? fmt(c.opened.ts) : "–"));
  tr.append(cell("Case", el("code", short(c.paymentId))));
  tr.append(cell("Verdict", el("strong", o.label, `verdict ${kind}`), el("div", o.note, "mut")));
  const secs = cell("Seconds", c.seconds != null ? `${c.seconds} s` : pending ? "…" : "–");
  secs.className = "num"; tr.append(secs);
  const pk = payerKind(c);
  tr.append(pk === "server" ? cell("Payer", el("span", "court's buyer", "mut"))
    : pk === "operator" ? cell("Payer", el("span", "operator test wallet", "tag"), " ", addr(c.authorize.payer))
    : pk === "other" ? cell("Payer", el("span", "other wallet", "tag"), " ", addr(c.authorize.payer))
    : cell("Payer", el("span", pending ? "…" : "–", "mut")));
  const steps = cell("Transactions", link(B + "tx/", c.authorize?.tx, "pay"), " → ", link(L, c.opened?.tx, "open"), " → ", link(L, c.decision?.tx, "decide"), " → ", link(B + "tx/", c.callback?.tx, c.decision?.capture ? "capture" : "void"));
  steps.classList.add("steps");
  tr.append(steps);
  return tr;
}

function show(s) {
  $("count").textContent = String(s.count);
  $("paid").textContent = String(s.paid);
  $("refunded").textContent = String(s.refunded);
  $("cron").textContent = String(s.cron);
  $("median").textContent = s.median != null ? `${s.median} s` : "–";
  $("external").textContent = String(s.external);
  $("external-note").textContent = s.payersChecked < s.count
    ? `${s.payersChecked} of ${s.count} payers read so far`
    : `${s.externalWallets} distinct wallet${s.externalWallets === 1 ? "" : "s"}, ${s.count} payers read`;
}

async function main() {
  $("window").textContent = hours === 168 ? "last 7 days" : `last ${hours} h`;
  for (const a of document.querySelectorAll("[data-hours]")) if (Number(a.dataset.hours) === hours) a.setAttribute("aria-current", "page");
  $("buyer").textContent = `${CFG.serverBuyer.slice(0, 6)}…${CFG.serverBuyer.slice(-4)}`;
  $("status").textContent = "Reading Reactive Lasna…";
  const t0 = performance.now();
  try {
    const cache = new Map();
    const cases = await lasnaCases(rpc, { hours, cache });
    const tbody = $("rows"); tbody.textContent = "";
    const rows = cases.map((c) => { const tr = row(c, true); tbody.append(tr); return tr; });
    show(summarize(cases));
    if (!cases.length) { $("status").textContent = "No cases in this window. Try the 7 days view."; return; }
    // Rows are on screen; now match each case on Base Sepolia, newest first, a few at a time.
    let done = 0;
    const tick = () => { $("status").textContent = `Matching payments on Base Sepolia: ${done} of ${cases.length}`; $("progress").value = done / cases.length; };
    tick();
    await pool(cases, 6, async (c, i) => {
      try { await enrichOnBase(rpc, c, { cache }); } catch { /* keep the Lasna row */ }
      const tr = row(c, false); rows[i].replaceWith(tr); rows[i] = tr;
      done++; tick(); show(summarize(cases));
    });
    $("progress").hidden = true;
    const secs = ((performance.now() - t0) / 1000).toFixed(1);
    $("status").textContent = `Read ${new Date().toISOString().slice(11, 19)} UTC from ${new URL(CFG.lasna).host} and ${new URL(CFG.base).host} in ${secs} s. Seconds = Base Sepolia block timestamp of the callback minus that of the payment.`;
  } catch (e) {
    $("progress").hidden = true;
    $("status").textContent = "Could not read the chain: " + e.message + ". Reload to try again.";
  }
}
main();
