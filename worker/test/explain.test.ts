import { estimateNeurons, roughTokens } from "../src/neurons.ts";
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  buildMessages,
  clip,
  complete,
  explain,
  MAX_ANSWER_TOKENS,
  MAX_OUTPUT_CHARS,
  MODELS,
  parseFixture,
  type AI,
  type Fixture,
} from "../src/explain.ts";

const zpool: Fixture = {
  id: "zpool-status",
  argv: ["zpool", "status"],
  exit_code: 1,
  stdout: "",
  stderr: "The ZFS modules cannot be auto-loaded.\n",
  error: "",
};

test("parseFixture accepts a full fixture", () => {
  const r = parseFixture({ ...zpool, extra: "ignored" });
  assert.ok(r.ok);
  if (r.ok) assert.deepEqual(r.fixture, zpool);
});

test("parseFixture defaults missing output fields to empty strings", () => {
  const r = parseFixture({ id: "uname", argv: ["uname"], exit_code: 0 });
  assert.ok(r.ok);
  if (r.ok) {
    assert.equal(r.fixture.stdout, "");
    assert.equal(r.fixture.stderr, "");
    assert.equal(r.fixture.error, "");
  }
});

test("parseFixture rejects bad input and names the field", () => {
  const cases: Array<[unknown, string]> = [
    [null, ""],
    ["text", ""],
    [{ ...zpool, id: "" }, "id"],
    [{ ...zpool, id: "x".repeat(65) }, "id"],
    [{ ...zpool, id: 7 }, "id"],
    [{ ...zpool, argv: [] }, "argv"],
    [{ ...zpool, argv: ["ok", 3] }, "argv"],
    [{ ...zpool, argv: "zpool status" }, "argv"],
    [{ ...zpool, exit_code: 1.5 }, "exit_code"],
    [{ ...zpool, exit_code: "1" }, "exit_code"],
    [{ ...zpool, stdout: 42 }, "stdout"],
    [{ ...zpool, stderr: [] }, "stderr"],
    [{ ...zpool, error: {} }, "error"],
  ];
  for (const [input, field] of cases) {
    const r = parseFixture(input);
    assert.equal(r.ok, false, `accepted ${JSON.stringify(input)}`);
    if (!r.ok && field) assert.match(r.error, new RegExp(field), `error for ${field} was: ${r.error}`);
  }
});

test("clip keeps short text and cuts long text in the middle", () => {
  assert.equal(clip("short", 10), "short");
  assert.equal(clip("x".repeat(10), 10), "x".repeat(10));

  const long = "HEAD" + "m".repeat(1000) + "TAIL";
  const out = clip(long, 100);
  assert.ok(out.startsWith("HEAD"), "head lost");
  assert.ok(out.endsWith("TAIL"), "tail lost");
  assert.ok(out.length < long.length);
  assert.match(out, /9\d\d characters/, "does not say how much was left out");
});

test("buildMessages: system rules and user content", () => {
  const [system, user] = buildMessages({ ...zpool, error: "partial" });
  assert.equal(system.role, "system");
  assert.equal(user.role, "user");
  assert.match(system.content, /120 words/);
  assert.match(system.content, /Nothing notable\./);
  assert.match(system.content, /invent/i);
  assert.match(system.content, /suggest/i);
  assert.doesNotMatch(system.content, /do not suggest/i);
  assert.match(user.content, /zpool status/);
  assert.match(user.content, /exit code:? ?1/i);
  assert.match(user.content, /cannot be auto-loaded/);
  assert.match(user.content, /partial/);
});

test("buildMessages clips stdout and stderr together to MAX_OUTPUT_CHARS", () => {
  const big = { ...zpool, stdout: "o".repeat(MAX_OUTPUT_CHARS), stderr: "e".repeat(MAX_OUTPUT_CHARS) };
  const [, user] = buildMessages(big);
  const os = (user.content.match(/o/g) ?? []).length;
  const es = (user.content.match(/e/g) ?? []).length;
  assert.ok(os + es <= MAX_OUTPUT_CHARS + 400, `sent ${os + es} output characters`);
  assert.ok(os > 0 && es > 0, "one stream was dropped entirely");
});

function fakeAI(reply: unknown, calls: Array<{ model: string; input: any }> = []): AI {
  return {
    async run(model, input) {
      calls.push({ model, input });
      return reply;
    },
  };
}

test("explain uses the small model by default and returns the trimmed answer", async () => {
  const calls: Array<{ model: string; input: any }> = [];
  const r = await explain(fakeAI({ response: "  ZFS is not loaded.  " }, calls), zpool);
  assert.equal(r.model, MODELS.small);
  assert.equal(r.text, "ZFS is not loaded.");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].model, MODELS.small);
  assert.equal(calls[0].input.max_tokens, MAX_ANSWER_TOKENS);
  assert.deepEqual(calls[0].input.messages, buildMessages(zpool));
});

test("complete estimates neurons from the reply's usage when present", async () => {
  const usage = { prompt_tokens: 1200, completion_tokens: 80 };
  const msgs = buildMessages(zpool);
  const r = await complete(fakeAI({ response: "ok", usage }), MODELS.large, msgs);
  assert.deepEqual(r, { model: MODELS.large, text: "ok", neurons: estimateNeurons(MODELS.large, usage) });
});

test("complete falls back to rough token counts without usage", async () => {
  const msgs = buildMessages(zpool);
  const r = await complete(fakeAI({ response: " answer text " }), MODELS.small, msgs);
  const prompt = msgs.reduce((n, m) => n + roughTokens(m.content), 0);
  const want = estimateNeurons(MODELS.small, { prompt_tokens: prompt, completion_tokens: roughTokens("answer text") });
  assert.ok(Math.abs(r.neurons - want) < 1e-9, `${r.neurons} vs ${want}`);
  assert.ok(r.neurons > 0);
});

test("explain can use another model", async () => {
  const r = await explain(fakeAI({ response: "ok" }), zpool, MODELS.large);
  assert.equal(r.model, MODELS.large);
});

test("explain throws on an empty or malformed reply", async () => {
  for (const reply of [{}, { response: "" }, { response: "   " }, null, "text", { response: 3 }]) {
    await assert.rejects(explain(fakeAI(reply), zpool), `accepted reply ${JSON.stringify(reply)}`);
  }
});
