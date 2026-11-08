// A ROUGH, display-only estimate of Workers AI neurons. It exists so the UI
// can say "you did not blow the daily allowance in one prompt" (or that you
// probably did). Never use it to allow or refuse a call: it can be off by a
// mile (unknown models, missing usage, other clients on the same account).

/** The free daily allowance (resets 00:00 UTC). */
export const DAILY_FREE_NEURONS = 10_000;

/**
 * Neurons per million tokens, from developers.cloudflare.com/workers-ai/
 * platform/pricing (2026-11-06).
 */
export const RATES: Record<string, { input: number; output: number }> = {
  "@cf/meta/llama-3.1-8b-instruct-fp8": { input: 13_778, output: 26_128 },
  "@cf/meta/llama-3.3-70b-instruct-fp8-fast": { input: 26_668, output: 204_805 },
  "@cf/meta/llama-3.2-1b-instruct": { input: 2_457, output: 18_252 },
};

export interface Usage {
  prompt_tokens: number;
  completion_tokens: number;
}

/**
 * The token counts of a Workers AI reply: its `usage` object when that has
 * `prompt_tokens` and `completion_tokens` as finite numbers >= 0; otherwise
 * undefined.
 */
export function usageOf(reply: unknown): Usage | undefined {
  if (typeof reply !== "object" || reply === null) return undefined;
  const u = (reply as { usage?: unknown }).usage;
  if (typeof u !== "object" || u === null) return undefined;
  const { prompt_tokens, completion_tokens } = u as Record<string, unknown>;
  const count = (n: unknown): n is number => typeof n === "number" && Number.isFinite(n) && n >= 0;
  return count(prompt_tokens) && count(completion_tokens) ? { prompt_tokens, completion_tokens } : undefined;
}

/** A rough token count for `text`: its length divided by 4, rounded up. */
export function roughTokens(text: string): number {
  return Math.ceil(text.length / 4);
}

/**
 * Neurons for `usage` on `model`: tokens times the model's RATES, per
 * million. An unknown model is priced at the most expensive rates in RATES,
 * so the estimate errs high.
 */
export function estimateNeurons(model: string, usage: Usage): number {
  const all = Object.values(RATES);
  const rate = RATES[model] ?? {
    input: Math.max(...all.map((r) => r.input)),
    output: Math.max(...all.map((r) => r.output)),
  };
  return (usage.prompt_tokens * rate.input + usage.completion_tokens * rate.output) / 1_000_000;
}

/** The UTC calendar day of `ms` (milliseconds since the epoch), "YYYY-MM-DD". */
export function utcDay(ms: number): string {
  return new Date(ms).toISOString().slice(0, 10);
}

/**
 * One sentence for the user after a failed Workers AI call, given today's
 * estimate. At 80% of DAILY_FREE_NEURONS or more it says the daily allowance
 * is probably used up; below that, that it probably is not the cause. Either
 * way it gives the rounded estimate and the allowance, and says it is a rough
 * estimate.
 */
export function quotaHint(neuronsToday: number): string {
  const used = `about ${Math.round(neuronsToday).toLocaleString("en-US")} of ${DAILY_FREE_NEURONS.toLocaleString("en-US")} free neurons today (a rough estimate)`;
  return neuronsToday >= 0.8 * DAILY_FREE_NEURONS
    ? `The daily allowance is probably used up: ${used}. It resets at 00:00 UTC.`
    : `This is probably not the daily allowance: ${used}.`;
}
