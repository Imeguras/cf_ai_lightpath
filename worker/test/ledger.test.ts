import { test } from "node:test";
import assert from "node:assert/strict";
import { Ledger, LEDGER_NAME } from "../src/ledger.ts";
import { memorySql } from "./sqlite.ts";

const DAY1 = Date.UTC(2026, 10, 6, 12);
const DAY2 = Date.UTC(2026, 10, 7, 0, 0, 1);

function setup(start = DAY1) {
  const clock = { t: start };
  const sql = memorySql();
  const ledger = new Ledger({ storage: { sql } }, {}, () => clock.t);
  return { ledger, sql, clock };
}

async function call(l: Ledger, method: string, path: string, body?: unknown) {
  const raw = body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body);
  const res = await l.fetch(new Request("https://ledger" + path, { method, body: raw }));
  assert.match(res.headers.get("content-type") ?? "", /application\/json/);
  return { status: res.status, json: (await res.json()) as any };
}

test("the instance name is fixed", () => {
  assert.equal(typeof LEDGER_NAME, "string");
  assert.ok(LEDGER_NAME.length > 0);
});

test("a new ledger reports zero for today", async () => {
  const { ledger } = setup();
  assert.deepEqual(await call(ledger, "GET", "/today"), {
    status: 200,
    json: { day: "2026-11-06", neurons: 0, calls: 0 },
  });
});

test("add sums neurons and counts calls", async () => {
  const { ledger } = setup();
  assert.deepEqual((await call(ledger, "POST", "/add", { neurons: 3.5 })).json, { day: "2026-11-06", neurons: 3.5, calls: 1 });
  assert.deepEqual((await call(ledger, "POST", "/add", { neurons: 0 })).json, { day: "2026-11-06", neurons: 3.5, calls: 2 });
  await call(ledger, "POST", "/add", { neurons: 10 });
  assert.deepEqual((await call(ledger, "GET", "/today")).json, { day: "2026-11-06", neurons: 13.5, calls: 3 });
});

test("a new UTC day starts from zero", async () => {
  const { ledger, clock } = setup();
  await call(ledger, "POST", "/add", { neurons: 500 });
  clock.t = DAY2;
  assert.deepEqual((await call(ledger, "GET", "/today")).json, { day: "2026-11-07", neurons: 0, calls: 0 });
  assert.deepEqual((await call(ledger, "POST", "/add", { neurons: 1 })).json, { day: "2026-11-07", neurons: 1, calls: 1 });
});

test("the total survives a new Ledger object on the same storage", async () => {
  const { ledger, sql } = setup();
  await call(ledger, "POST", "/add", { neurons: 42 });
  const again = new Ledger({ storage: { sql } }, {}, () => DAY1);
  assert.equal((await call(again, "GET", "/today")).json.neurons, 42);
});

test("bad adds are 400 and change nothing", async () => {
  const { ledger } = setup();
  for (const body of ["{nope", "[]", "null", {}, { neurons: -1 }, { neurons: "5" }, { neurons: null }]) {
    const r = await call(ledger, "POST", "/add", body);
    assert.equal(r.status, 400, JSON.stringify(body));
    assert.equal(typeof r.json.error, "string");
  }
  // JSON has no Infinity/NaN literals; 1e999 parses to Infinity.
  assert.equal((await call(ledger, "POST", "/add", '{"neurons": 1e999}')).status, 400);
  assert.deepEqual((await call(ledger, "GET", "/today")).json, { day: "2026-11-06", neurons: 0, calls: 0 });
});

test("unknown paths and methods are 404", async () => {
  const { ledger } = setup();
  assert.equal((await call(ledger, "GET", "/add")).status, 404);
  assert.equal((await call(ledger, "POST", "/today")).status, 404);
  assert.equal((await call(ledger, "GET", "/")).status, 404);
});
