import { test } from "node:test";
import assert from "node:assert/strict";
import { Session } from "../src/session.ts";
import { buildChatMessages } from "../src/chat.ts";
import { HISTORY_LIMIT, type StoredMessage } from "../src/memory.ts";
import { MODELS } from "../src/explain.ts";
import { memorySql } from "./sqlite.ts";

function setup(run: (model: string, input: any) => Promise<unknown> = async () => ({ response: "answer" })) {
  let t = 1000;
  const sql = memorySql();
  const session = new Session({ storage: { sql } }, { AI: { run } }, () => t++);
  return { session, sql };
}

async function call(s: Session, method: string, path: string, body?: unknown) {
  const res = await s.fetch(
    new Request("https://session" + path, { method, body: body === undefined ? undefined : JSON.stringify(body) }),
  );
  assert.match(res.headers.get("content-type") ?? "", /application\/json/);
  return { status: res.status, json: (await res.json()) as any };
}

test("a new session has an empty history", async () => {
  const { session } = setup();
  assert.deepEqual(await call(session, "GET", "/history"), { status: 200, json: { messages: [] } });
});

test("POST /chat answers and stores the question then the answer", async () => {
  const { session } = setup();
  const r = await call(session, "POST", "/chat", { message: "Is ZFS up?" });
  assert.equal(r.status, 200);
  assert.equal(r.json.model, MODELS.small);
  assert.equal(r.json.text, "answer");
  assert.equal(typeof r.json.neurons, "number");

  const h = await call(session, "GET", "/history");
  const msgs: StoredMessage[] = h.json.messages;
  assert.equal(msgs.length, 2);
  assert.deepEqual(
    msgs.map(({ role, content, model }) => ({ role, content, model })),
    [
      { role: "user", content: "Is ZFS up?", model: "" },
      { role: "assistant", content: "answer", model: MODELS.small },
    ],
  );
  assert.ok(msgs[0].at <= msgs[1].at);
});

test("earlier messages are sent to the model, capped at HISTORY_LIMIT", async () => {
  const seen: any[] = [];
  let n = 0;
  const { session } = setup(async (_m, input) => (seen.push(input.messages), { response: `a${n++}` }));
  const turns = HISTORY_LIMIT; // 2 messages per turn, so history overflows the limit
  for (let i = 0; i < turns; i++) await call(session, "POST", "/chat", { message: `q${i}` });

  const all: StoredMessage[] = (await call(session, "GET", "/history")).json.messages;
  assert.equal(all.length, 2 * turns);

  const last = seen[seen.length - 1];
  const expected = buildChatMessages(all.slice(-2 - HISTORY_LIMIT, -2), `q${turns - 1}`);
  assert.deepEqual(last, expected);
});

test("history survives a new Session object on the same storage", async () => {
  const { session, sql } = setup();
  await call(session, "POST", "/chat", { message: "remember me" });
  const again = new Session({ storage: { sql } }, { AI: { run: async () => ({ response: "x" }) } });
  const msgs = (await call(again, "GET", "/history")).json.messages;
  assert.equal(msgs[0].content, "remember me");
});

test("when Workers AI fails: 502 and nothing stored", async () => {
  for (const run of [
    async () => {
      throw new Error("4006: daily free allocation used up");
    },
    async () => ({ response: "" }),
  ]) {
    const { session } = setup(run);
    const r = await call(session, "POST", "/chat", { message: "hello" });
    assert.equal(r.status, 502);
    assert.equal(typeof r.json.error, "string");
    assert.deepEqual((await call(session, "GET", "/history")).json.messages, []);
  }
});

test("unknown paths and methods are 404", async () => {
  const { session } = setup();
  assert.equal((await call(session, "GET", "/chat")).status, 404);
  assert.equal((await call(session, "POST", "/history")).status, 404);
  assert.equal((await call(session, "GET", "/")).status, 404);
});

test("POST /append stores messages in order with the current time", async () => {
  const { session } = setup();
  const r = await call(session, "POST", "/append", {
    messages: [
      { role: "user", content: "q", model: "" },
      { role: "assistant", content: "a", model: MODELS.large },
    ],
  });
  assert.deepEqual(r, { status: 200, json: { stored: 2 } });
  const msgs: StoredMessage[] = (await call(session, "GET", "/history")).json.messages;
  assert.deepEqual(
    msgs.map(({ role, content, model }) => ({ role, content, model })),
    [
      { role: "user", content: "q", model: "" },
      { role: "assistant", content: "a", model: MODELS.large },
    ],
  );
  assert.ok(msgs[0].at >= 1000 && msgs[0].at <= msgs[1].at);
});

test("POST /append rejects any bad message and stores nothing", async () => {
  const { session } = setup();
  const good = { role: "user", content: "q", model: "" };
  for (const body of [
    "{nope",
    {},
    { messages: "x" },
    { messages: [good, { role: "system", content: "x", model: "" }] },
    { messages: [good, { role: "user", content: 3, model: "" }] },
    { messages: [good, { role: "user", content: "x" }] },
    { messages: [good, null] },
  ]) {
    const raw = typeof body === "string" ? body : JSON.stringify(body);
    const res = await session.fetch(new Request("https://session/append", { method: "POST", body: raw }));
    assert.equal(res.status, 400, raw);
    assert.equal(typeof ((await res.json()) as any).error, "string");
  }
  assert.deepEqual((await call(session, "GET", "/history")).json.messages, []);
});
