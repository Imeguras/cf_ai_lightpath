import { test } from "node:test";
import assert from "node:assert/strict";
import worker from "../src/index.ts";
import * as indexModule from "../src/index.ts";
import { Session } from "../src/session.ts";
import { Ledger } from "../src/ledger.ts";
import { NewsStore } from "../src/news_store.ts";
import { NewsWorkflow, TriageWorkflow } from "../src/workflows.ts";
import { MAX_BODY_BYTES } from "../src/limits.ts";
import { MODELS } from "../src/explain.ts";
import { DAILY_FREE_NEURONS, estimateNeurons } from "../src/neurons.ts";
import { JWT_AUDIENCE, signJwt } from "../src/jwt.ts";
import type { Env } from "../src/bindings.ts";
import { fakeEnv, type FakeEnv, type Run } from "./fakes.ts";

const fixture = { id: "uname", argv: ["uname", "-a"], exit_code: 0, stdout: "Linux labhost 7.2.14", stderr: "" };
const okRun: Run = async () => ({ response: "Kernel 7.2.14 is running." });

async function token(env: Env, over: Record<string, unknown> = {}) {
  const now = Math.floor(Date.now() / 1000);
  return signJwt({ aud: JWT_AUDIENCE, iat: now, exp: now + 60, sub: "visitor", ...over }, env.JWT_SECRET);
}

async function call(e: FakeEnv, method: string, path: string, body?: unknown, auth: string | null = "valid") {
  const headers: Record<string, string> = {};
  if (auth === "valid") headers.authorization = `Bearer ${await token(e)}`;
  else if (auth !== null) headers.authorization = auth;
  const raw = body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body);
  const res = await worker.fetch(new Request("http://localhost" + path, { method, body: raw, headers }), e);
  assert.match(res.headers.get("content-type") ?? "", /application\/json/, `${method} ${path} is not JSON`);
  return { status: res.status, json: (await res.json()) as any, headers: res.headers };
}

test("GET /api/health needs no token", async () => {
  const r = await call(fakeEnv(okRun), "GET", "/api/health", undefined, null);
  assert.equal(r.status, 200);
  assert.deepEqual(r.json, { ok: true });
});

test("every other route needs a valid token", async () => {
  const e = fakeEnv(okRun);
  const routes: [string, string][] = [
    ["GET", "/api/usage"],
    ["POST", "/api/explain"],
    ["POST", "/api/chat"],
    ["GET", "/api/chat/history?session=s"],
    ["POST", "/api/triage"],
    ["GET", "/api/triage/status?id=x"],
    ["PUT", "/api/news/packages"],
    ["POST", "/api/news"],
    ["GET", "/api/news/status?id=x"],
    ["GET", "/api/news/latest"],
    ["GET", "/nope"],
  ];
  const wrong = await signJwt({ aud: JWT_AUDIENCE, iat: 0, exp: 60 }, e.JWT_SECRET);
  for (const [method, path] of routes) {
    for (const auth of [null, "Bearer", "Bearer x.y.z", `Basic ${btoa("a:b")}`, `Bearer ${wrong}`]) {
      const r = await call(e, method, path, method === "GET" ? undefined : "{}", auth);
      assert.equal(r.status, 401, `${method} ${path} with ${auth}`);
      assert.equal(typeof r.json.error, "string");
      assert.equal(r.headers.get("www-authenticate"), "Bearer");
    }
  }
  const other = fakeEnv(okRun, { JWT_SECRET: "another-secret" });
  assert.equal((await call(other, "GET", "/api/usage", undefined, `Bearer ${await token(e)}`)).status, 401);
  assert.equal(e.limited.length, 0, "the rate limiter is not reached without a token");
});

test("POST /api/explain returns the model, text and neurons", async () => {
  const r = await call(fakeEnv(okRun), "POST", "/api/explain", fixture);
  assert.equal(r.status, 200);
  assert.equal(r.json.model, MODELS.small);
  assert.equal(r.json.text, "Kernel 7.2.14 is running.");
  assert.equal(typeof r.json.neurons, "number");
});

test("bodies: 400 for bad JSON or invalid, 413 when too big", async () => {
  const e = fakeEnv(okRun);
  const cases: [string, string, unknown][] = [
    ["POST", "/api/explain", "{not json"],
    ["POST", "/api/explain", { ...fixture, argv: [] }],
    ["POST", "/api/chat", { session: "a b", message: "x" }],
    ["POST", "/api/triage", { session: "s", message: "q", hard: "yes" }],
    ["PUT", "/api/news/packages", { packages: ["Bad Name"] }],
    ["PUT", "/api/news/packages", "[]"],
  ];
  for (const [m, p, b] of cases) {
    const r = await call(e, m, p, b);
    assert.equal(r.status, 400, `${m} ${p} ${JSON.stringify(b)}`);
    assert.equal(typeof r.json.error, "string");
  }
  const big = "x".repeat(MAX_BODY_BYTES);
  for (const [m, p, b] of [
    ["POST", "/api/explain", { ...fixture, stdout: big }],
    ["POST", "/api/chat", { session: "s", message: big }],
    ["POST", "/api/triage", { session: "s", message: big }],
    ["PUT", "/api/news/packages", { packages: [big] }],
  ] as const) {
    assert.equal((await call(e, m, p, b)).status, 413, p);
  }
});

test("chat answers and remembers per session", async () => {
  const e = fakeEnv(async () => ({ response: "Pools are not imported." }));
  const r = await call(e, "POST", "/api/chat", { session: "s1", message: "  Is ZFS up?  " });
  assert.equal(r.status, 200);
  assert.equal(r.json.text, "Pools are not imported.");
  const h = await call(e, "GET", "/api/chat/history?session=s1");
  assert.deepEqual(h.json.messages.map((m: any) => [m.role, m.content]), [
    ["user", "Is ZFS up?"],
    ["assistant", "Pools are not imported."],
  ]);
  assert.deepEqual((await call(e, "GET", "/api/chat/history?session=s2")).json, { messages: [] });
  for (const q of ["", "?session=", "?session=a%20b"]) {
    assert.equal((await call(e, "GET", "/api/chat/history" + q)).status, 400, q);
  }
});

test("usage adds every successful explain and chat", async () => {
  const usage = { prompt_tokens: 1000, completion_tokens: 100 };
  const e = fakeEnv(async () => ({ response: "ok", usage }));
  const zero = await call(e, "GET", "/api/usage");
  assert.equal(zero.status, 200);
  assert.deepEqual({ ...zero.json, day: "-" }, { day: "-", neurons: 0, calls: 0, allowance: DAILY_FREE_NEURONS, rough: true });
  await call(e, "POST", "/api/explain", fixture);
  await call(e, "POST", "/api/chat", { session: "u", message: "hi" });
  const after = await call(e, "GET", "/api/usage");
  assert.equal(after.json.calls, 2);
  assert.ok(Math.abs(after.json.neurons - 2 * estimateNeurons(MODELS.small, usage)) < 1e-9);
});

test("Workers AI failing: 502 with the quota hint, nothing counted or stored", async () => {
  const e = fakeEnv(async () => {
    throw new Error("4006: daily free allocation used up");
  });
  for (const [p, b] of [
    ["/api/explain", fixture],
    ["/api/chat", { session: "q", message: "hi" }],
  ] as const) {
    const r = await call(e, "POST", p, b);
    assert.equal(r.status, 502, p);
    assert.match(r.json.error, /4006/);
    assert.match(r.json.error, /rough/i);
  }
  assert.equal((await call(e, "GET", "/api/usage")).json.calls, 0);
  assert.deepEqual((await call(e, "GET", "/api/chat/history?session=q")).json.messages, []);
});

test("a broken Ledger never breaks explain or chat", async () => {
  const broken = { idFromName: (n: string) => n, get: () => ({ fetch: async () => Promise.reject(new Error("down")) }) };
  const ok = fakeEnv(okRun, { LEDGER: broken });
  assert.equal((await call(ok, "POST", "/api/explain", fixture)).status, 200);
  assert.equal((await call(ok, "POST", "/api/chat", { session: "b", message: "hi" })).status, 200);
  assert.equal((await call(ok, "GET", "/api/usage")).status, 502);
  const failing = fakeEnv(async () => Promise.reject(new Error("boom")), { LEDGER: broken });
  const r = await call(failing, "POST", "/api/explain", fixture);
  assert.equal(r.status, 502);
  assert.match(r.json.error, /boom/);
  assert.doesNotMatch(r.json.error, /rough/i);
});

test("AI routes are rate limited by the token's sub", async () => {
  const e = fakeEnv(okRun);
  await call(e, "POST", "/api/explain", fixture);
  await call(e, "POST", "/api/chat", { session: "r", message: "hi" });
  await call(e, "POST", "/api/triage", { session: "r", message: "hi" });
  await call(e, "POST", "/api/news");
  assert.deepEqual(e.limited, ["visitor", "visitor", "visitor", "visitor"]);

  await call(e, "GET", "/api/usage");
  await call(e, "GET", "/api/chat/history?session=r");
  await call(e, "PUT", "/api/news/packages", { packages: ["linux"] });
  assert.equal(e.limited.length, 4, "non-AI routes are not limited");

  const anon = fakeEnv(okRun);
  await call(anon, "POST", "/api/explain", fixture, `Bearer ${await token(anon, { sub: undefined })}`);
  assert.deepEqual(anon.limited, ["anonymous"]);

  e.allow = false;
  let calls = 0;
  const blocked = fakeEnv(async () => (calls++, { response: "x" }));
  blocked.allow = false;
  for (const [m, p, b] of [
    ["POST", "/api/explain", fixture],
    ["POST", "/api/chat", { session: "r", message: "hi" }],
    ["POST", "/api/triage", { session: "r", message: "hi" }],
    ["POST", "/api/news", undefined],
  ] as const) {
    const r = await call(blocked, m, p, b);
    assert.equal(r.status, 429, p);
    assert.equal(typeof r.json.error, "string");
  }
  assert.equal(calls, 0);
  assert.equal(blocked.TRIAGE.created.length + blocked.NEWS.created.length, 0);
});

test("triage: start an instance, then read its status", async () => {
  const e = fakeEnv(okRun);
  const r = await call(e, "POST", "/api/triage", { session: "t", message: " q ", hard: true });
  assert.equal(r.status, 202);
  assert.equal(r.json.id, "triage-1");
  assert.deepEqual(e.TRIAGE.created, [{ id: "triage-1", params: { session: "t", message: "q", hard: true } }]);
  assert.equal((await call(e, "POST", "/api/triage", { session: "t", message: "q" })).json.id, "triage-2");
  assert.deepEqual(e.TRIAGE.created[1].params, { session: "t", message: "q", hard: false });

  assert.deepEqual((await call(e, "GET", "/api/triage/status?id=triage-1")).json, { status: "queued" });
  e.TRIAGE.statuses.set("triage-1", { status: "complete", output: { text: "done" } });
  assert.deepEqual((await call(e, "GET", "/api/triage/status?id=triage-1")).json, { status: "complete", output: { text: "done" } });
  e.TRIAGE.statuses.set("triage-2", { status: "errored", error: { name: "Error", message: "4006" } });
  assert.deepEqual((await call(e, "GET", "/api/triage/status?id=triage-2")).json, { status: "errored", error: "4006" });

  // The real runtime reports "no output/error yet" as null, not undefined.
  e.TRIAGE.statuses.set("triage-1", { status: "running", output: null, error: null } as never);
  assert.deepEqual((await call(e, "GET", "/api/triage/status?id=triage-1")).json, { status: "running" });

  assert.equal((await call(e, "GET", "/api/triage/status?id=nope")).status, 404);
  for (const q of ["", "?id=", "?id=a%20b", "?id=" + "x".repeat(101)]) {
    assert.equal((await call(e, "GET", "/api/triage/status" + q)).status, 400, q);
  }
});

test("news: packages, start, status and latest", async () => {
  const e = fakeEnv(okRun);
  const up = await call(e, "PUT", "/api/news/packages", { packages: ["zfs-dkms", "linux", "linux"] });
  assert.deepEqual(up, { ...up, status: 200, json: { count: 2 } });
  const store = e.NEWS_STORE.get(e.NEWS_STORE.idFromName("global"));
  assert.deepEqual(await (await store.fetch(new Request("https://n/packages"))).json(), { packages: ["linux", "zfs-dkms"] });

  const r = await call(e, "POST", "/api/news");
  assert.equal(r.status, 202);
  assert.equal(r.json.id, "news-1");
  e.NEWS.statuses.set("news-1", { status: "running" });
  assert.deepEqual((await call(e, "GET", "/api/news/status?id=news-1")).json, { status: "running" });

  assert.equal((await call(e, "GET", "/api/news/latest")).status, 404);
  const digest = { key: "k", created: 1, model: "", text: "t", neurons: 0, cached: false, items: [] };
  await store.fetch(new Request("https://n/digest", { method: "PUT", body: JSON.stringify(digest) }));
  assert.deepEqual((await call(e, "GET", "/api/news/latest")).json, digest);
});

test("wrong methods and unknown paths", async () => {
  const e = fakeEnv(okRun);
  for (const [m, p, s] of [
    ["GET", "/api/explain", 405],
    ["POST", "/api/health", 405],
    ["GET", "/api/chat", 405],
    ["POST", "/api/chat/history?session=s", 405],
    ["GET", "/api/triage", 405],
    ["POST", "/api/triage/status?id=x", 405],
    ["GET", "/api/news/packages", 405],
    ["GET", "/api/news", 405],
    ["POST", "/api/news/latest", 405],
    ["POST", "/api/usage", 405],
    ["GET", "/nope", 404],
    ["GET", "/", 404],
  ] as const) {
    assert.equal((await call(e, m, p)).status, s, `${m} ${p}`);
  }
});

test("the cron handler starts a news digest", async () => {
  const e = fakeEnv(okRun);
  const waits: Promise<unknown>[] = [];
  await worker.scheduled({ cron: "0 6 * * *", scheduledTime: Date.now() }, e, { waitUntil: (p: Promise<unknown>) => waits.push(p) });
  await Promise.all(waits);
  assert.equal(e.NEWS.created.length, 1);
});

test("AI calls go through the gateway when one is set", async () => {
  const options: unknown[] = [];
  const e = fakeEnv(async (_m, _i, o) => (options.push(o), { response: "ok" }), { AI_GATEWAY: "lightpath" });
  await call(e, "POST", "/api/explain", fixture);
  await call(e, "POST", "/api/chat", { session: "g", message: "hi" });
  assert.deepEqual(options, [{ gateway: { id: "lightpath" } }, { gateway: { id: "lightpath" } }]);
});

test("index.ts exports the handler and the declared classes only", () => {
  // The runtime treats every named export of the main module as an entrypoint
  // and refuses to start on anything that is not a declared class.
  assert.deepEqual(Object.keys(indexModule).sort(), ["Ledger", "NewsStore", "NewsWorkflow", "Session", "TriageWorkflow", "default"]);
  assert.equal(indexModule.Session, Session);
  assert.equal(indexModule.Ledger, Ledger);
  assert.equal(indexModule.NewsStore, NewsStore);
  assert.equal(indexModule.TriageWorkflow, TriageWorkflow);
  assert.equal(indexModule.NewsWorkflow, NewsWorkflow);
});
