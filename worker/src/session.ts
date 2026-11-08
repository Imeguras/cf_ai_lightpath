// The Session Durable Object: one per conversation, holding its messages in
// SQLite. A plain class (no `cloudflare:workers` import) so it also loads in
// node tests; the runtime calls `fetch` for every request a stub sends it.
import { aiFor } from "./bindings.ts";
import { reply } from "./chat.ts";
import type { AI } from "./explain.ts";
import { append, HISTORY_LIMIT, migrate, recent, type Sql, type StoredMessage } from "./memory.ts";

/** What the runtime hands the Durable Object; only the parts we use. */
export interface SessionState {
  storage: { sql: Sql };
}

export interface SessionEnv {
  AI: AI;
  /** See bindings.ts; missing or "" calls Workers AI without a gateway. */
  AI_GATEWAY?: string;
}

/**
 * Requests come from the Worker only (they are not reachable from outside).
 * Every response is JSON.
 *
 *   POST /chat     body {"message": string}, already validated by the Worker
 *                  200 {"model", "text"}; the question and the answer are
 *                      stored, in that order, after the HISTORY_LIMIT newest
 *                      earlier messages were sent to the model with it
 *                  502 {"error"} when Workers AI fails; nothing is stored
 *   POST /append   body {"messages": [{"role", "content", "model"}, ...]}: stores
 *                  them in order, each with `at` = now (used by the triage
 *                  Workflow, which calls the model itself)
 *                  200 {"stored": n}
 *                  400 {"error"} unless every message has role "user" or
 *                      "assistant" and string content and model; then
 *                      nothing is stored
 *   GET  /history  200 {"messages": StoredMessage[]}, oldest first, all of them
 *   anything else: 404 {"error"}
 *
 * `now` returns the current time in milliseconds (tests pass a fixed clock).
 */
export class Session {
  readonly #sql: Sql;
  readonly #ai: AI;
  readonly #now: () => number;

  constructor(state: SessionState, env: SessionEnv, now: () => number = Date.now) {
    this.#sql = state.storage.sql;
    this.#ai = aiFor({ AI: env.AI, AI_GATEWAY: env.AI_GATEWAY ?? "" });
    this.#now = now;
    migrate(this.#sql);
  }

  async fetch(request: Request): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (request.method === "POST" && pathname === "/chat") return this.#chat(request);
    if (request.method === "POST" && pathname === "/append") return this.#append(request);
    if (request.method === "GET" && pathname === "/history") {
      return json(200, { messages: recent(this.#sql, Number.MAX_SAFE_INTEGER) });
    }
    return json(404, { error: "not found" });
  }

  async #append(request: Request): Promise<Response> {
    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return json(400, { error: "body is not valid JSON" });
    }
    const messages = (body as { messages?: unknown } | null)?.messages;
    const valid = (m: unknown): m is Pick<StoredMessage, "role" | "content" | "model"> => {
      const x = m as Record<string, unknown> | null;
      return (
        typeof x === "object" && x !== null &&
        (x.role === "user" || x.role === "assistant") &&
        typeof x.content === "string" && typeof x.model === "string"
      );
    };
    if (!Array.isArray(messages) || !messages.every(valid)) {
      return json(400, { error: "messages must be a list of {role: user|assistant, content, model}" });
    }
    for (const m of messages) append(this.#sql, { role: m.role, content: m.content, model: m.model, at: this.#now() });
    return json(200, { stored: messages.length });
  }

  async #chat(request: Request): Promise<Response> {
    const { message } = (await request.json()) as { message: string };
    const history = recent(this.#sql, HISTORY_LIMIT);
    let answer;
    try {
      answer = await reply(this.#ai, history, message);
    } catch (e) {
      return json(502, { error: `Workers AI failed: ${e instanceof Error ? e.message : String(e)}` });
    }
    // Stored only once both exist, so a failed call leaves no half turn.
    append(this.#sql, { role: "user", content: message, model: "", at: this.#now() });
    append(this.#sql, { role: "assistant", content: answer.text, model: answer.model, at: this.#now() });
    return json(200, answer);
  }
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}
