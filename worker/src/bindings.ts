// The Worker's bindings (what Terraform attaches, see deploy/terraform/worker)
// and small helpers to reach the Durable Objects. Shared by the HTTP handler
// and the Workflows.
import type { AI } from "./explain.ts";
import { LEDGER_NAME, type Day } from "./ledger.ts";
import type { StoredMessage } from "./memory.ts";

/** The subset of a Durable Object namespace binding we use. */
export interface Namespace {
  idFromName(name: string): unknown;
  get(id: unknown): { fetch(request: Request): Promise<Response> };
}

export interface InstanceStatus {
  status: string;
  output?: unknown;
  error?: { name: string; message: string };
}

/** The subset of a Workflow binding we use. */
export interface WorkflowBinding {
  create(options?: { id?: string; params?: unknown }): Promise<{ id: string }>;
  get(id: string): Promise<{ status(): Promise<InstanceStatus> }>;
}

/** The subset of a rate limiting binding we use. */
export interface RateLimiter {
  limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface Env {
  AI: AI;
  SESSION: Namespace;
  LEDGER: Namespace;
  NEWS_STORE: Namespace;
  TRIAGE: WorkflowBinding;
  NEWS: WorkflowBinding;
  RATE_LIMITER: RateLimiter;
  /** AI Gateway id; "" sends Workers AI calls without a gateway (local dev). */
  AI_GATEWAY: string;
  /** Shared HS256 secret for the web app's JWTs. */
  JWT_SECRET: string;
}

/**
 * env.AI, routed through the AI Gateway named by env.AI_GATEWAY (caching,
 * rate limits, logs) when that is not empty; env.AI itself when it is.
 */
export function aiFor(env: Pick<Env, "AI" | "AI_GATEWAY">): AI {
  if (!env.AI_GATEWAY) return env.AI;
  const gateway = { id: env.AI_GATEWAY };
  return { run: (model, input) => env.AI.run(model, input, { gateway }) };
}

/** The Session Durable Object for conversation `session`. */
export function sessionFor(env: Pick<Env, "SESSION">, session: string) {
  return env.SESSION.get(env.SESSION.idFromName(session));
}

/**
 * Today's rough neuron estimate from the Ledger. Throws when the Ledger
 * cannot be reached or does not answer 200.
 */
export async function today(env: Pick<Env, "LEDGER">): Promise<Day> {
  const res = await ledger(env).fetch(new Request("https://ledger/today"));
  if (!res.ok) throw new Error(`ledger answered ${res.status}`);
  return (await res.json()) as Day;
}

/** Adds `neurons` to today's estimate. Never throws: the Ledger is display only. */
export async function record(env: Pick<Env, "LEDGER">, neurons: number): Promise<void> {
  try {
    await ledger(env).fetch(new Request("https://ledger/add", { method: "POST", body: JSON.stringify({ neurons }) }));
  } catch {
    // Display only.
  }
}

/** All of `session`'s stored messages, oldest first. Throws on failure. */
export async function history(env: Pick<Env, "SESSION">, session: string): Promise<StoredMessage[]> {
  const res = await sessionFor(env, session).fetch(new Request("https://session/history"));
  if (!res.ok) throw new Error(`session answered ${res.status}`);
  return ((await res.json()) as { messages: StoredMessage[] }).messages;
}

/** Stores `messages` in `session`, in order. Throws on failure. */
export async function store(
  env: Pick<Env, "SESSION">,
  session: string,
  messages: Pick<StoredMessage, "role" | "content" | "model">[],
): Promise<void> {
  const res = await sessionFor(env, session).fetch(
    new Request("https://session/append", { method: "POST", body: JSON.stringify({ messages }) }),
  );
  if (!res.ok) throw new Error(`session answered ${res.status}`);
}

function ledger(env: Pick<Env, "LEDGER">) {
  return env.LEDGER.get(env.LEDGER.idFromName(LEDGER_NAME));
}
