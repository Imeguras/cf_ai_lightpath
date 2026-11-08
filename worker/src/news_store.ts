// The NewsStore Durable Object: a single instance (named NEWS_STORE_NAME)
// holding the uploaded package list and the digests, in SQLite.
import type { Sql } from "./memory.ts";
import type { NewsDigest } from "./news.ts";

export const NEWS_STORE_NAME = "global";

export interface NewsStoreState {
  storage: { sql: Sql };
}

/**
 * Requests come from the Worker and the news Workflow only. JSON in and out.
 * Bodies are validated by the caller (parsePackages); this stores them as is.
 *
 *   PUT /packages        body {"packages": string[]}; replaces the list
 *                        200 {"count": n}
 *   GET /packages        200 {"packages": string[]} ([] before any upload)
 *   PUT /digest          body: a NewsDigest; stores it under its key
 *                        (replacing one with the same key) and makes it the latest
 *                        200 {"key"}
 *   GET /digest?key=K    200 the digest stored under K; 404 {"error"} if none
 *   GET /latest          200 the digest saved last; 404 {"error"} if none
 *   anything else        404 {"error"}
 * A body that is not JSON is 400 {"error"}.
 */
export class NewsStore {
  readonly #sql: Sql;

  constructor(state: NewsStoreState, _env: unknown) {
    this.#sql = state.storage.sql;
    // `packages` has one row (id 1); `saved` orders digests for /latest.
    this.#sql.exec("CREATE TABLE IF NOT EXISTS packages (id INTEGER PRIMARY KEY CHECK (id = 1), list TEXT NOT NULL)");
    this.#sql.exec(
      "CREATE TABLE IF NOT EXISTS digests (key TEXT PRIMARY KEY, digest TEXT NOT NULL, saved INTEGER NOT NULL)",
    );
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    const route = `${request.method} ${url.pathname}`;
    let body: unknown;
    if (request.method === "PUT") {
      try {
        body = await request.json();
      } catch {
        return json(400, { error: "body is not valid JSON" });
      }
    }
    switch (route) {
      case "GET /packages": {
        const [row] = this.#sql.exec("SELECT list FROM packages WHERE id = 1").toArray();
        return json(200, { packages: row ? JSON.parse(String(row.list)) : [] });
      }
      case "PUT /packages": {
        const packages = (body as { packages: string[] }).packages;
        this.#sql.exec(
          "INSERT INTO packages (id, list) VALUES (1, ?) ON CONFLICT (id) DO UPDATE SET list = excluded.list",
          JSON.stringify(packages),
        );
        return json(200, { count: packages.length });
      }
      case "PUT /digest": {
        const d = body as NewsDigest;
        const [{ next }] = this.#sql.exec("SELECT COALESCE(MAX(saved), 0) + 1 AS next FROM digests").toArray();
        this.#sql.exec(
          "INSERT INTO digests (key, digest, saved) VALUES (?, ?, ?) ON CONFLICT (key) DO UPDATE SET digest = excluded.digest, saved = excluded.saved",
          d.key,
          JSON.stringify(d),
          Number(next),
        );
        return json(200, { key: d.key });
      }
      case "GET /digest":
        return this.#digest("SELECT digest FROM digests WHERE key = ?", url.searchParams.get("key") ?? "");
      case "GET /latest":
        return this.#digest("SELECT digest FROM digests ORDER BY saved DESC LIMIT 1");
      default:
        return json(404, { error: "not found" });
    }
  }

  #digest(query: string, ...bindings: unknown[]): Response {
    const [row] = this.#sql.exec(query, ...bindings).toArray();
    return row ? json(200, JSON.parse(String(row.digest))) : json(404, { error: "no digest" });
  }
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}
