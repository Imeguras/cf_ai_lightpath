import { test } from "node:test";
import assert from "node:assert/strict";
import { NewsStore, NEWS_STORE_NAME } from "../src/news_store.ts";
import type { NewsDigest } from "../src/news.ts";
import { memorySql } from "./sqlite.ts";

const digest = (key: string, text = "t"): NewsDigest => ({
  key,
  created: 1,
  model: "m",
  text,
  neurons: 2.5,
  cached: false,
  items: [{ title: "x", link: "l", published: 3, matches: ["linux"] }],
});

async function call(s: NewsStore, method: string, path: string, body?: unknown) {
  const raw = body === undefined ? undefined : typeof body === "string" ? body : JSON.stringify(body);
  const res = await s.fetch(new Request("https://news" + path, { method, body: raw }));
  assert.match(res.headers.get("content-type") ?? "", /application\/json/);
  return { status: res.status, json: (await res.json()) as any };
}

test("the instance name is fixed", () => assert.ok(NEWS_STORE_NAME.length > 0));

test("packages: empty first, then replaced on each upload", async () => {
  const s = new NewsStore({ storage: { sql: memorySql() } }, {});
  assert.deepEqual(await call(s, "GET", "/packages"), { status: 200, json: { packages: [] } });
  assert.deepEqual(await call(s, "PUT", "/packages", { packages: ["linux", "zfs-dkms"] }), { status: 200, json: { count: 2 } });
  assert.deepEqual((await call(s, "PUT", "/packages", { packages: ["vim"] })).json, { count: 1 });
  assert.deepEqual((await call(s, "GET", "/packages")).json, { packages: ["vim"] });
});

test("digests: stored by key, latest is the last saved", async () => {
  const s = new NewsStore({ storage: { sql: memorySql() } }, {});
  assert.equal((await call(s, "GET", "/latest")).status, 404);
  assert.equal((await call(s, "GET", "/digest?key=a")).status, 404);

  assert.deepEqual(await call(s, "PUT", "/digest", digest("a")), { status: 200, json: { key: "a" } });
  await call(s, "PUT", "/digest", digest("b"));
  assert.deepEqual((await call(s, "GET", "/digest?key=a")).json, digest("a"));
  assert.deepEqual((await call(s, "GET", "/latest")).json, digest("b"));

  await call(s, "PUT", "/digest", digest("a", "new"));
  assert.deepEqual((await call(s, "GET", "/digest?key=a")).json, digest("a", "new"));
  assert.deepEqual((await call(s, "GET", "/latest")).json, digest("a", "new"));
});

test("state survives a new object on the same storage", async () => {
  const sql = memorySql();
  const s = new NewsStore({ storage: { sql } }, {});
  await call(s, "PUT", "/packages", { packages: ["linux"] });
  await call(s, "PUT", "/digest", digest("k"));
  const again = new NewsStore({ storage: { sql } }, {});
  assert.deepEqual((await call(again, "GET", "/packages")).json, { packages: ["linux"] });
  assert.deepEqual((await call(again, "GET", "/latest")).json, digest("k"));
});

test("bad JSON is 400; unknown routes are 404", async () => {
  const s = new NewsStore({ storage: { sql: memorySql() } }, {});
  assert.equal((await call(s, "PUT", "/packages", "{nope")).status, 400);
  assert.equal((await call(s, "PUT", "/digest", "{nope")).status, 400);
  assert.equal((await call(s, "POST", "/packages", { packages: [] })).status, 404);
  assert.equal((await call(s, "GET", "/")).status, 404);
});
