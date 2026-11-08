import { test } from "node:test";
import assert from "node:assert/strict";
import { looksLikeCommand, ROUTING, shouldEscalate, type Routing } from "../src/routing.ts";
import { MODELS } from "../src/explain.ts";

test("ROUTING uses the small and large models", () => {
  assert.equal(ROUTING.small, MODELS.small);
  assert.equal(ROUTING.large, MODELS.large);
  assert.equal(ROUTING.escalate.onCommand, true);
  assert.ok(ROUTING.escalate.minQuestionChars > 0);
});

test("looksLikeCommand: backticks, $-prompts, privilege words", () => {
  for (const t of [
    "Run `zpool import -f`.",
    "Try this:\n$ zpool status",
    "first line\n   $ ls",
    "You need doas for that.",
    "Use sudo modprobe zfs",
    "fudo pacman -Syu",
    "SUDO works too",
  ]) {
    assert.equal(looksLikeCommand(t), true, t);
  }
});

test("looksLikeCommand: plain prose is not a command", () => {
  for (const t of [
    "",
    "The pools are not imported because the module is missing.",
    "It costs $5 per month.",
    "a$ b",
    "pseudocode and sudoku are fine",
    "# A heading\nNothing to run.",
  ]) {
    assert.equal(looksLikeCommand(t), false, t);
  }
});

const long = "x".repeat(ROUTING.escalate.minQuestionChars);

test("shouldEscalate: reasons in order", () => {
  assert.deepEqual(shouldEscalate(long, "`cmd`", true), { escalate: true, reason: "asked for the large model" });
  assert.deepEqual(shouldEscalate(long, "`cmd`", false), { escalate: true, reason: "the small model suggested a command" });
  assert.deepEqual(shouldEscalate(long, "prose", false), { escalate: true, reason: "long question" });
  assert.deepEqual(shouldEscalate(long.slice(1), "prose", false), { escalate: false, reason: "small model answer kept" });
});

test("shouldEscalate follows the routing it is given", () => {
  const r: Routing = { ...ROUTING, escalate: { onCommand: false, minQuestionChars: 10 } };
  assert.equal(shouldEscalate("short", "`cmd`", false, r).escalate, false);
  assert.deepEqual(shouldEscalate("0123456789", "prose", false, r), { escalate: true, reason: "long question" });
});
