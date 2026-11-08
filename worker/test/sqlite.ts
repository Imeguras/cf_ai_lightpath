// A real SQLite database shaped like a Durable Object's ctx.storage.sql.
import { DatabaseSync } from "node:sqlite";
import type { Sql } from "../src/memory.ts";

export function memorySql(): Sql {
  const db = new DatabaseSync(":memory:");
  return {
    exec(query: string, ...bindings: unknown[]) {
      const rows = db.prepare(query).all(...(bindings as never[])) as Record<string, unknown>[];
      return { toArray: () => rows };
    },
  };
}
