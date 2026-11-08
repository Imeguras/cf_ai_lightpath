// Triage: the cheap model answers first; the routing rules decide whether the
// large model answers instead. Pure orchestration over injected steps and
// dependencies, so it runs the same in tests and inside the Workflow
// (workflows.ts), where each step is checkpointed and retried by Cloudflare.
import { parseChatRequest, reply } from "./chat.ts";
import type { AI } from "./explain.ts";
import { HISTORY_LIMIT, type StoredMessage } from "./memory.ts";
import { ROUTING, shouldEscalate, type Routing } from "./routing.ts";

export interface TriageInput {
  session: string;
  message: string;
  /** Ask the large model directly. */
  hard: boolean;
}

/** Runs `fn` as a named, checkpointed step (Workflow step.do in production). */
export interface StepRunner {
  do<T>(name: string, fn: () => Promise<T>): Promise<T>;
}

export interface TriageDeps {
  ai: AI;
  /** All stored messages of the session, oldest first. */
  history(session: string): Promise<StoredMessage[]>;
  store(session: string, messages: Pick<StoredMessage, "role" | "content" | "model">[]): Promise<void>;
  /** Adds to the rough daily neuron estimate (display only). */
  record(neurons: number): Promise<void>;
}

export interface TriageResult {
  /** The model whose answer is final. */
  model: string;
  text: string;
  /** Rough neurons of every model call in this triage, summed. */
  neurons: number;
  escalated: boolean;
  /** Why the final model was chosen (see shouldEscalate). */
  reason: string;
  /** Each model call, in order. */
  calls: { model: string; neurons: number }[];
}

/**
 * Checks an untrusted triage request: parseChatRequest's rules, plus an
 * optional boolean `hard` (default false). A non-boolean `hard` is an error
 * naming "hard".
 */
export function parseTriageRequest(body: unknown): ({ ok: true } & TriageInput) | { ok: false; error: string } {
  const chat = parseChatRequest(body);
  if (!chat.ok) return chat;
  const hard = (body as { hard?: unknown }).hard ?? false;
  if (typeof hard !== "boolean") return { ok: false, error: "hard must be true or false" };
  return { ...chat, hard };
}

/**
 * Runs one triage, every external call inside a named step:
 *   "history"  the session's HISTORY_LIMIT newest messages
 *   "small"    reply() from routing.small with that history (skipped when
 *              `hard`: the large model is asked directly)
 *   "large"    reply() from routing.large with the same history, only when
 *              shouldEscalate says so (or `hard`)
 *   "store"    the question, then the final answer with its model
 *   "record"   the summed neurons (a failure here is ignored)
 * A failing model call propagates (the Workflow then errors) and nothing is
 * stored.
 */
export async function runTriage(
  step: StepRunner,
  deps: TriageDeps,
  input: TriageInput,
  routing: Routing = ROUTING,
): Promise<TriageResult> {
  const { session, message, hard } = input;
  const past = await step.do("history", async () => (await deps.history(session)).slice(-HISTORY_LIMIT));

  const calls: TriageResult["calls"] = [];
  let final;
  let decision;
  if (hard) {
    decision = shouldEscalate(message, "", true, routing);
  } else {
    final = await step.do("small", () => reply(deps.ai, past, message, routing.small));
    calls.push({ model: final.model, neurons: final.neurons });
    decision = shouldEscalate(message, final.text, false, routing);
  }
  if (decision.escalate) {
    final = await step.do("large", () => reply(deps.ai, past, message, routing.large));
    calls.push({ model: final.model, neurons: final.neurons });
  }
  const answer = final!;

  await step.do("store", () =>
    deps.store(session, [
      { role: "user", content: message, model: "" },
      { role: "assistant", content: answer.text, model: answer.model },
    ]),
  );
  const neurons = calls.reduce((n, c) => n + c.neurons, 0);
  await step.do("record", () => deps.record(neurons).catch(() => undefined));

  return { model: answer.model, text: answer.text, neurons, escalated: decision.escalate, reason: decision.reason, calls };
}
