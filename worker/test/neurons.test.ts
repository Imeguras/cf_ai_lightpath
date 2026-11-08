import { test } from "node:test";
import assert from "node:assert/strict";
import { DAILY_FREE_NEURONS, estimateNeurons, quotaHint, RATES, roughTokens, usageOf, utcDay } from "../src/neurons.ts";
import { MODELS } from "../src/explain.ts";

test("the allowance and the rates for the models we use", () => {
  assert.equal(DAILY_FREE_NEURONS, 10_000);
  for (const m of [MODELS.small, MODELS.large]) {
    assert.ok(RATES[m], m);
    assert.ok(RATES[m].input > 0 && RATES[m].output > 0, m);
  }
});

test("usageOf reads usage from a reply", () => {
  assert.deepEqual(usageOf({ response: "x", usage: { prompt_tokens: 10, completion_tokens: 3, total_tokens: 13 } }), {
    prompt_tokens: 10,
    completion_tokens: 3,
  });
  assert.deepEqual(usageOf({ usage: { prompt_tokens: 0, completion_tokens: 0 } }), { prompt_tokens: 0, completion_tokens: 0 });
});

test("usageOf: undefined for missing or bad usage", () => {
  for (const r of [
    null,
    "x",
    {},
    { usage: null },
    { usage: { prompt_tokens: 10 } },
    { usage: { prompt_tokens: "10", completion_tokens: 3 } },
    { usage: { prompt_tokens: -1, completion_tokens: 3 } },
    { usage: { prompt_tokens: 1, completion_tokens: Infinity } },
    { usage: { prompt_tokens: NaN, completion_tokens: 1 } },
  ]) {
    assert.equal(usageOf(r), undefined, JSON.stringify(r));
  }
});

test("roughTokens is length / 4 rounded up", () => {
  assert.equal(roughTokens(""), 0);
  assert.equal(roughTokens("a"), 1);
  assert.equal(roughTokens("abcd"), 1);
  assert.equal(roughTokens("abcde"), 2);
  assert.equal(roughTokens("x".repeat(4000)), 1000);
});

test("estimateNeurons uses the model's rates per million tokens", () => {
  const r = RATES[MODELS.small];
  assert.equal(estimateNeurons(MODELS.small, { prompt_tokens: 1_000_000, completion_tokens: 0 }), r.input);
  assert.equal(estimateNeurons(MODELS.small, { prompt_tokens: 0, completion_tokens: 1_000_000 }), r.output);
  const got = estimateNeurons(MODELS.large, { prompt_tokens: 2000, completion_tokens: 300 });
  const want = (2000 * RATES[MODELS.large].input + 300 * RATES[MODELS.large].output) / 1e6;
  assert.ok(Math.abs(got - want) < 1e-9, `${got} vs ${want}`);
  assert.equal(estimateNeurons(MODELS.small, { prompt_tokens: 0, completion_tokens: 0 }), 0);
});

test("estimateNeurons prices an unknown model at the most expensive rates", () => {
  const maxIn = Math.max(...Object.values(RATES).map((r) => r.input));
  const maxOut = Math.max(...Object.values(RATES).map((r) => r.output));
  assert.equal(estimateNeurons("@cf/unknown/model", { prompt_tokens: 1_000_000, completion_tokens: 0 }), maxIn);
  assert.equal(estimateNeurons("@cf/unknown/model", { prompt_tokens: 0, completion_tokens: 1_000_000 }), maxOut);
});

test("utcDay is the UTC date", () => {
  assert.equal(utcDay(Date.UTC(2026, 10, 6, 0, 0, 0)), "2026-11-06");
  assert.equal(utcDay(Date.UTC(2026, 10, 6, 23, 59, 59, 999)), "2026-11-06");
  assert.equal(utcDay(Date.UTC(2026, 0, 1, 0, 0, 0)), "2026-01-01");
  assert.equal(utcDay(Date.UTC(2026, 10, 7)), "2026-11-07");
});

test("quotaHint: probably not the allowance below 80%", () => {
  const h = quotaHint(37.4);
  assert.match(h, /not/i);
  assert.match(h, /\b37\b/);
  assert.doesNotMatch(h, /37\.4/); // rounded
  assert.match(h, /10[,.]?000/);
  assert.match(h, /rough/i);
  assert.doesNotMatch(quotaHint(7_999), /used up/i);
});

test("quotaHint: probably used up from 80%", () => {
  for (const n of [8_000, 9_999.6, 25_000]) {
    const h = quotaHint(n);
    assert.match(h, /used up/i, String(n));
    assert.match(h, /rough/i);
  }
  assert.match(quotaHint(9_999.6), /10[,.]?000/);
});
