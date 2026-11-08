// The Ledger Durable Object: a single instance (named "global") holding the
// rough neuron estimate per UTC day in SQLite. Display only; see neurons.ts.
import type { Sql } from "./memory.ts";
import { utcDay } from "./neurons.ts";

/** The name of the one Ledger instance. */
export const LEDGER_NAME = "global";

export interface LedgerState {
  storage: { sql: Sql };
}

export interface Day {
  /** UTC day, "YYYY-MM-DD". */
  day: string;
  /** Estimated neurons used that day. */
  neurons: number;
  /** Workers AI calls counted that day. */
  calls: number;
}

/**
 * Requests come from the Worker only. Every response is JSON.
 *
 *   POST /add    body {"neurons": number}, a finite number >= 0
 *                200 Day: today (by `now`) after adding it and counting one call
 *                400 {"error"} for anything else; nothing is added
 *   GET  /today  200 Day: today so far ({neurons: 0, calls: 0} when nothing yet)
 *   anything else: 404 {"error"}
 *
 * Each UTC day starts from zero. `now` returns the current time in
 * milliseconds (tests pass their own clock).
 */
export class Ledger {
  readonly #sql: Sql;
  readonly #now: () => number;

  constructor(state: LedgerState, _env: unknown, now: () => number = Date.now) {
    this.#sql = state.storage.sql;
    this.#now = now;
    this.#sql.exec(
      `CREATE TABLE IF NOT EXISTS days (
        day     TEXT    PRIMARY KEY,
        neurons REAL    NOT NULL,
        calls   INTEGER NOT NULL
      )`,
    );
  }

  async fetch(request: Request): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (request.method === "GET" && pathname === "/today") return json(200, this.#today());
    if (request.method === "POST" && pathname === "/add") return this.#add(request);
    return json(404, { error: "not found" });
  }

  async #add(request: Request): Promise<Response> {
    let body: unknown;
    try {
      body = await request.json();
    } catch {
      return json(400, { error: "body is not valid JSON" });
    }
    const n = typeof body === "object" && body !== null ? (body as { neurons?: unknown }).neurons : undefined;
    if (typeof n !== "number" || !Number.isFinite(n) || n < 0) {
      return json(400, { error: "neurons must be a finite number >= 0" });
    }
    this.#sql.exec(
      `INSERT INTO days (day, neurons, calls) VALUES (?, ?, 1)
       ON CONFLICT (day) DO UPDATE SET neurons = neurons + excluded.neurons, calls = calls + 1`,
      utcDay(this.#now()),
      n,
    );
    return json(200, this.#today());
  }

  #today(): Day {
    const day = utcDay(this.#now());
    const [row] = this.#sql.exec("SELECT neurons, calls FROM days WHERE day = ?", day).toArray();
    return { day, neurons: row ? Number(row.neurons) : 0, calls: row ? Number(row.calls) : 0 };
  }
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}
