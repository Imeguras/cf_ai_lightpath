import { test } from "node:test";
import assert from "node:assert/strict";
import { aiFor } from "../src/bindings.ts";

test("aiFor adds the gateway when one is configured", async () => {
  const seen: unknown[][] = [];
  const AI = { run: async (...args: unknown[]) => (seen.push(args), { response: "x" }) };
  const input = { messages: [], max_tokens: 1 };

  await aiFor({ AI, AI_GATEWAY: "lightpath" }).run("m", input);
  assert.deepEqual(seen[0], ["m", input, { gateway: { id: "lightpath" } }]);

  assert.equal(aiFor({ AI, AI_GATEWAY: "" }), AI);
  assert.equal(await aiFor({ AI, AI_GATEWAY: "g" }).run("m", input).then((r: any) => r.response), "x");
});
