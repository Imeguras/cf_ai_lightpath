import { test } from "node:test";
import assert from "node:assert/strict";
import { parseTriageRequest, runTriage, type StepRunner, type TriageDeps } from "../src/triage.ts";
import { buildChatMessages } from "../src/chat.ts";
import { MODELS } from "../src/explain.ts";
import { HISTORY_LIMIT, type StoredMessage } from "../src/memory.ts";
import { estimateNeurons } from "../src/neurons.ts";

test("parseTriageRequest: chat rules plus optional boolean hard", () => {
  assert.deepEqual(parseTriageRequest({ session: "s", message: " q " }), { ok: true, session: "s", message: "q", hard: false });
  assert.deepEqual(parseTriageRequest({ session: "s", message: "q", hard: true }), {
    ok: true,
    session: "s",
    message: "q",
    hard: true,
  });
  for (const [body, field] of [
    [{ session: "a b", message: "q" }, "session"],
    [{ session: "s", message: "" }, "message"],
    [{ session: "s", message: "q", hard: "yes" }, "hard"],
    [{ session: "s", message: "q", hard: 1 }, "hard"],
  ] as const) {
    const r = parseTriageRequest(body);
    assert.equal(r.ok, false, JSON.stringify(body));
    if (!r.ok) assert.match(r.error, new RegExp(field));
  }
  assert.equal(parseTriageRequest(null).ok, false);
});

const usage = { prompt_tokens: 100, completion_tokens: 10 };

// Steps run inline; their names are recorded in order.
function steps() {
  const names: string[] = [];
  const runner: StepRunner = {
    do: async (name, fn) => {
      names.push(name);
      return fn();
    },
  };
  return { names, runner };
}

function deps(answers: Record<string, unknown>, stored: StoredMessage[] = []) {
  const calls: { model: string; messages: unknown }[] = [];
  const saved: unknown[] = [];
  const recorded: number[] = [];
  const d: TriageDeps = {
    ai: {
      run: async (model, input: any) => {
        calls.push({ model, messages: input.messages });
        const a = answers[model];
        if (a instanceof Error) throw a;
        return { response: a, usage };
      },
    },
    history: async () => stored,
    store: async (_s, m) => void saved.push(...m),
    record: async (n) => void recorded.push(n),
  };
  return { d, calls, saved, recorded };
}

const small = estimateNeurons(MODELS.small, usage);
const large = estimateNeurons(MODELS.large, usage);

test("a plain answer from the small model is kept", async () => {
  const { names, runner } = steps();
  const { d, calls, saved, recorded } = deps({ [MODELS.small]: "The pools are not imported." });
  const r = await runTriage(runner, d, { session: "s", message: "Is ZFS up?", hard: false });

  assert.deepEqual(names, ["history", "small", "store", "record"]);
  assert.deepEqual(r, {
    model: MODELS.small,
    text: "The pools are not imported.",
    neurons: small,
    escalated: false,
    reason: "small model answer kept",
    calls: [{ model: MODELS.small, neurons: small }],
  });
  assert.equal(calls.length, 1);
  assert.deepEqual(saved, [
    { role: "user", content: "Is ZFS up?", model: "" },
    { role: "assistant", content: "The pools are not imported.", model: MODELS.small },
  ]);
  assert.deepEqual(recorded, [small]);
});

test("a command in the small answer escalates to the large model", async () => {
  const { names, runner } = steps();
  const { d, calls, saved, recorded } = deps({
    [MODELS.small]: "Run `zpool import -f`.",
    [MODELS.large]: "Suggestion: boot a kernel zfs-dkms supports.",
  });
  const r = await runTriage(runner, d, { session: "s", message: "Fix ZFS?", hard: false });

  assert.deepEqual(names, ["history", "small", "large", "store", "record"]);
  assert.equal(r.model, MODELS.large);
  assert.equal(r.text, "Suggestion: boot a kernel zfs-dkms supports.");
  assert.equal(r.escalated, true);
  assert.equal(r.reason, "the small model suggested a command");
  assert.deepEqual(r.calls, [
    { model: MODELS.small, neurons: small },
    { model: MODELS.large, neurons: large },
  ]);
  assert.ok(Math.abs(r.neurons - (small + large)) < 1e-9);
  assert.deepEqual(calls.map((c) => c.model), [MODELS.small, MODELS.large]);
  assert.deepEqual(saved, [
    { role: "user", content: "Fix ZFS?", model: "" },
    { role: "assistant", content: "Suggestion: boot a kernel zfs-dkms supports.", model: MODELS.large },
  ]);
  assert.equal(recorded.length, 1);
  assert.ok(Math.abs(recorded[0] - (small + large)) < 1e-9);
});

test("hard asks the large model directly", async () => {
  const { names, runner } = steps();
  const { d, calls } = deps({ [MODELS.large]: "Deep answer." });
  const r = await runTriage(runner, d, { session: "s", message: "q", hard: true });
  assert.deepEqual(names, ["history", "large", "store", "record"]);
  assert.deepEqual(calls.map((c) => c.model), [MODELS.large]);
  assert.equal(r.escalated, true);
  assert.equal(r.reason, "asked for the large model");
  assert.deepEqual(r.calls, [{ model: MODELS.large, neurons: large }]);
});

test("only the HISTORY_LIMIT newest messages go to the models", async () => {
  const stored: StoredMessage[] = Array.from({ length: HISTORY_LIMIT + 5 }, (_, i) => ({
    role: i % 2 ? "assistant" : "user",
    content: `m${i}`,
    model: "",
    at: i,
  }));
  const { runner } = steps();
  const { d, calls } = deps({ [MODELS.small]: "ok" }, stored);
  await runTriage(runner, d, { session: "s", message: "q", hard: false });
  assert.deepEqual(calls[0].messages, buildChatMessages(stored.slice(-HISTORY_LIMIT), "q"));
});

test("a failing model call propagates and stores nothing", async () => {
  for (const answers of [
    { [MODELS.small]: new Error("4006") },
    { [MODELS.small]: "`cmd`", [MODELS.large]: new Error("4006") },
  ]) {
    const { runner } = steps();
    const { d, saved, recorded } = deps(answers);
    await assert.rejects(runTriage(runner, d, { session: "s", message: "q", hard: false }), /4006/);
    assert.deepEqual(saved, []);
    assert.deepEqual(recorded, []);
  }
});

test("a failing record is ignored", async () => {
  const { runner } = steps();
  const { d } = deps({ [MODELS.small]: "ok" });
  d.record = async () => {
    throw new Error("ledger down");
  };
  const r = await runTriage(runner, d, { session: "s", message: "q", hard: false });
  assert.equal(r.text, "ok");
});
