// Chat memory: one Session Durable Object per conversation, each with its own
// SQLite database. Pure functions over the SQL handle, so tests can pass a
// real SQLite (node:sqlite) instead of the Durable Object's.

/** The subset of a Durable Object's `ctx.storage.sql` we use. */
export interface Sql {
  exec(query: string, ...bindings: unknown[]): { toArray(): Record<string, unknown>[] };
}

/** One stored chat message. */
export interface StoredMessage {
  role: "user" | "assistant";
  content: string;
  /** The model that wrote an assistant message; "" for user messages. */
  model: string;
  /** When it was stored, in milliseconds since the Unix epoch. */
  at: number;
}

/** How many past messages go back to the model with each new question. */
export const HISTORY_LIMIT = 20;

/**
 * Creates the messages table when it does not exist yet. Safe to call before
 * every use; existing messages are kept.
 */
export function migrate(sql: Sql): void {
  // id gives the storage order; `at` is informational only.
  sql.exec(
    `CREATE TABLE IF NOT EXISTS messages (
      id      INTEGER PRIMARY KEY AUTOINCREMENT,
      role    TEXT    NOT NULL CHECK (role IN ('user', 'assistant')),
      content TEXT    NOT NULL,
      model   TEXT    NOT NULL,
      at      INTEGER NOT NULL
    )`,
  );
}

/** Stores `m` after every message stored before it. */
export function append(sql: Sql, m: StoredMessage): void {
  sql.exec("INSERT INTO messages (role, content, model, at) VALUES (?, ?, ?, ?)", m.role, m.content, m.model, m.at);
}

/**
 * Returns the newest `limit` messages in the order they were stored (oldest
 * first). Returns all of them when there are fewer; none for `limit` <= 0.
 */
export function recent(sql: Sql, limit: number): StoredMessage[] {
  if (limit <= 0) return [];
  const rows = sql
    .exec("SELECT role, content, model, at FROM messages ORDER BY id DESC LIMIT ?", Math.floor(limit))
    .toArray();
  return rows.reverse().map((r) => ({
    role: r.role as StoredMessage["role"],
    content: String(r.content),
    model: String(r.model),
    at: Number(r.at),
  }));
}
