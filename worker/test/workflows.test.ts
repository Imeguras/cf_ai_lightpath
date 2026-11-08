import { test, afterEach } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { MAX_FEED_BYTES, NewsWorkflow, runner, STEP_CONFIG, TriageWorkflow, type WorkflowStepLike } from "../src/workflows.ts";
import { ARCH_NEWS_FEED } from "../src/news.ts";
import { MODELS } from "../src/explain.ts";
import { history } from "../src/bindings.ts";
import { fakeEnv } from "./fakes.ts";

function step() {
  const seen: { name: string; config: unknown }[] = [];
  const s: WorkflowStepLike = { do: async (name, config, fn) => (seen.push({ name, config }), fn()) };
  return { seen, s };
}

test("STEP_CONFIG: one retry, bounded time", () => {
  assert.equal(STEP_CONFIG.retries.limit, 1);
  assert.ok(STEP_CONFIG.timeout);
});

test("runner passes every step through step.do with STEP_CONFIG", async () => {
  const { seen, s } = step();
  assert.equal(await runner(s).do("a", async () => 42), 42);
  assert.deepEqual(seen, [{ name: "a", config: STEP_CONFIG }]);
});

test("TriageWorkflow answers, stores in the session and counts neurons", async () => {
  const env = fakeEnv(async () => ({ response: "The pools are not imported." }));
  const { seen, s } = step();
  const out = await new TriageWorkflow({}, env).run({ payload: { session: "w1", message: "ZFS?", hard: false } }, s);

  assert.equal(out.model, MODELS.small);
  assert.equal(out.text, "The pools are not imported.");
  assert.deepEqual(seen.map((x) => x.name), ["history", "small", "store", "record"]);
  assert.ok(seen.every((x) => x.config === STEP_CONFIG));
  assert.deepEqual((await history(env, "w1")).map((m) => [m.role, m.content]), [
    ["user", "ZFS?"],
    ["assistant", "The pools are not imported."],
  ]);
  const usage = await env.LEDGER.get(env.LEDGER.idFromName("global")).fetch(new Request("https://l/today"));
  assert.equal(((await usage.json()) as any).calls, 1);
});

test("TriageWorkflow uses the AI Gateway when configured", async () => {
  const options: unknown[] = [];
  const env = fakeEnv(async (_m, _i, o) => (options.push(o), { response: "ok" }), { AI_GATEWAY: "gw" });
  await new TriageWorkflow({}, env).run({ payload: { session: "g", message: "q", hard: false } }, step().s);
  assert.deepEqual(options, [{ gateway: { id: "gw" } }]);
});

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

function serveFeed(body: string, status = 200) {
  const urls: string[] = [];
  globalThis.fetch = (async (input: RequestInfo | URL) => {
    urls.push(String(input instanceof Request ? input.url : input));
    return new Response(body, { status });
  }) as typeof fetch;
  return urls;
}

test("NewsWorkflow digests the feed with the stored packages and saves it", async () => {
  const urls = serveFeed(readFileSync(new URL("./data/arch-news.xml", import.meta.url), "utf8"));
  const env = fakeEnv(async () => ({ response: "PHP needs an update." }));
  const store = env.NEWS_STORE.get(env.NEWS_STORE.idFromName("global"));
  await store.fetch(new Request("https://n/packages", { method: "PUT", body: JSON.stringify({ packages: ["php"] }) }));

  // The newest item in the saved feed is from 2026-10-21.
  const d = await new NewsWorkflow({}, env).run({ timestamp: new Date(Date.UTC(2026, 10, 7)) }, step().s);
  assert.deepEqual(urls, [ARCH_NEWS_FEED]);
  assert.equal(d.model, MODELS.large);
  assert.equal(d.text, "PHP needs an update.");
  assert.equal(d.created, Date.UTC(2026, 10, 7));
  assert.ok(d.items.length >= 1);
  assert.deepEqual(d.items[0].matches, ["php"]);

  const latest = await store.fetch(new Request("https://n/latest"));
  assert.deepEqual(await latest.json(), d);
});

test("NewsWorkflow fails the feed step on a bad status or a huge body", async () => {
  for (const [body, status] of [
    ["gone", 503],
    ["x".repeat(MAX_FEED_BYTES + 1), 200],
  ] as const) {
    serveFeed(body, status);
    const env = fakeEnv(async () => ({ response: "x" }));
    const { seen, s } = step();
    await assert.rejects(new NewsWorkflow({}, env).run({ timestamp: new Date() }, s));
    assert.equal(seen.at(-1)?.name, "feed");
  }
});
