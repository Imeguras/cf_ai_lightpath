import { test } from "node:test";
import assert from "node:assert/strict";
import { buildChatMessages, MAX_MESSAGE_CHARS, parseChatRequest, reply, validSession } from "../src/chat.ts";
import { MAX_ANSWER_TOKENS, MODELS } from "../src/explain.ts";
import type { StoredMessage } from "../src/memory.ts";

const history: StoredMessage[] = [
  { role: "user", content: "Is ZFS up?", model: "", at: 1 },
  { role: "assistant", content: "No, the pools are not imported.", model: MODELS.small, at: 2 },
];

test("parseChatRequest accepts a valid request and trims the message", () => {
  assert.deepEqual(parseChatRequest({ session: "abc-DEF_123", message: "  why?  " }), {
    ok: true,
    session: "abc-DEF_123",
    message: "why?",
  });
});

test("parseChatRequest rejects bad bodies, naming the field", () => {
  for (const body of [null, [], "x", 3]) {
    const r = parseChatRequest(body);
    assert.equal(r.ok, false, JSON.stringify(body));
  }
  const cases: [unknown, string][] = [
    [{ message: "hi" }, "session"],
    [{ session: "", message: "hi" }, "session"],
    [{ session: "a".repeat(65), message: "hi" }, "session"],
    [{ session: "a b", message: "hi" }, "session"],
    [{ session: "a/../b", message: "hi" }, "session"],
    [{ session: 7, message: "hi" }, "session"],
    [{ session: "s" }, "message"],
    [{ session: "s", message: 5 }, "message"],
    [{ session: "s", message: "   \n " }, "message"],
    [{ session: "s", message: "x".repeat(MAX_MESSAGE_CHARS + 1) }, "message"],
  ];
  for (const [body, field] of cases) {
    const r = parseChatRequest(body);
    assert.equal(r.ok, false, JSON.stringify(body));
    if (!r.ok) assert.match(r.error, new RegExp(field), JSON.stringify(body));
  }
});

test("parseChatRequest accepts the limits exactly", () => {
  const r = parseChatRequest({ session: "a".repeat(64), message: "x".repeat(MAX_MESSAGE_CHARS) });
  assert.equal(r.ok, true);
});

test("validSession follows the same rule", () => {
  for (const s of ["a", "A-z_09", "a".repeat(64)]) assert.equal(validSession(s), true, s);
  for (const s of ["", "a".repeat(65), "a b", "é", "a.b", null, 1]) assert.equal(validSession(s), false, String(s));
});

test("buildChatMessages: system, then history unchanged, then the question", () => {
  const msgs = buildChatMessages(history, "And the VMs?");
  assert.equal(msgs.length, 4);
  assert.equal(msgs[0].role, "system");
  assert.match(msgs[0].content, /read-only/i);
  assert.match(msgs[0].content, /homelab/i);
  assert.match(msgs[0].content, /150 words/);
  assert.match(msgs[0].content, /invent/i);
  assert.match(msgs[0].content, /suggest/i);
  assert.deepEqual(msgs.slice(1, 3), history.map(({ role, content }) => ({ role, content })));
  assert.deepEqual(msgs[3], { role: "user", content: "And the VMs?" });
});

test("buildChatMessages with no history", () => {
  const msgs = buildChatMessages([], "hi");
  assert.equal(msgs.length, 2);
  assert.deepEqual(msgs[1], { role: "user", content: "hi" });
});

test("reply sends the built messages and returns the trimmed answer", async () => {
  const calls: { model: string; input: any }[] = [];
  const ai = { run: async (model: string, input: any) => (calls.push({ model, input }), { response: "  ok  " }) };
  const r = await reply(ai, history, "q");
  assert.equal(r.model, MODELS.small);
  assert.equal(r.text, "ok");
  assert.equal(typeof r.neurons, "number");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].model, MODELS.small);
  assert.deepEqual(calls[0].input.messages, buildChatMessages(history, "q"));
  assert.equal(calls[0].input.max_tokens, MAX_ANSWER_TOKENS);

  assert.equal((await reply(ai, [], "q", MODELS.large)).model, MODELS.large);
});

test("reply throws on an empty or missing answer", async () => {
  for (const out of [{ response: "  " }, { response: 3 }, {}, null, "text"]) {
    await assert.rejects(reply({ run: async () => out }, [], "q"), undefined, JSON.stringify(out));
  }
});
