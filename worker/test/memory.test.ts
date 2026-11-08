import { test } from "node:test";
import assert from "node:assert/strict";
import { append, HISTORY_LIMIT, migrate, recent, type StoredMessage } from "../src/memory.ts";
import { memorySql } from "./sqlite.ts";

const msg = (i: number, role: StoredMessage["role"] = i % 2 ? "assistant" : "user"): StoredMessage => ({
  role,
  content: `message ${i}`,
  model: role === "assistant" ? "@cf/test/model" : "",
  at: 1_700_000_000_000 + i,
});

test("HISTORY_LIMIT is a small positive integer", () => {
  assert.ok(Number.isInteger(HISTORY_LIMIT) && HISTORY_LIMIT > 0 && HISTORY_LIMIT <= 100);
});

test("a fresh database has no messages", () => {
  const sql = memorySql();
  migrate(sql);
  assert.deepEqual(recent(sql, 10), []);
});

test("messages come back as stored, oldest first", () => {
  const sql = memorySql();
  migrate(sql);
  const all = [0, 1, 2].map((i) => msg(i));
  for (const m of all) append(sql, m);
  assert.deepEqual(recent(sql, 10), all);
});

test("recent keeps the newest `limit`, still oldest first", () => {
  const sql = memorySql();
  migrate(sql);
  for (let i = 0; i < 7; i++) append(sql, msg(i));
  assert.deepEqual(recent(sql, 3), [4, 5, 6].map((i) => msg(i)));
  assert.deepEqual(recent(sql, 0), []);
  assert.deepEqual(recent(sql, -1), []);
});

test("order is storage order, not the `at` timestamp", () => {
  const sql = memorySql();
  migrate(sql);
  const late = { ...msg(0), at: 2_000_000_000_000 };
  const early = { ...msg(1), at: 1 };
  append(sql, late);
  append(sql, early);
  assert.deepEqual(recent(sql, 10), [late, early]);
});

test("migrate is safe to call again and keeps messages", () => {
  const sql = memorySql();
  migrate(sql);
  append(sql, msg(0));
  migrate(sql);
  assert.deepEqual(recent(sql, 10), [msg(0)]);
});

test("content is stored verbatim (quotes, SQL, unicode, newlines)", () => {
  const sql = memorySql();
  migrate(sql);
  const tricky = { ...msg(0), content: `'); DROP TABLE messages; --\n"ç ✓ 🍌"` };
  append(sql, tricky);
  assert.deepEqual(recent(sql, 1), [tricky]);
});
