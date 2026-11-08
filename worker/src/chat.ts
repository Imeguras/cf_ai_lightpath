// Chatting with the homelab copilot. Pure logic, like explain.ts: the AI
// binding and the history are passed in.
import { complete, MODELS, type AI, type Explanation, type Message } from "./explain.ts";
import type { StoredMessage } from "./memory.ts";

/** Longest question accepted, in characters. */
export const MAX_MESSAGE_CHARS = 4000;

/**
 * Checks an untrusted chat request. Requires `session` (1 to 64 characters,
 * only letters, digits, "-" and "_") and `message` (a string that is not
 * blank and has at most MAX_MESSAGE_CHARS characters). The returned message
 * is trimmed. The error message names the offending field.
 */
export function parseChatRequest(
  body: unknown,
): { ok: true; session: string; message: string } | { ok: false; error: string } {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "body must be a JSON object" };
  }
  const b = body as Record<string, unknown>;
  if (!validSession(b.session)) {
    return { ok: false, error: "session must be 1 to 64 letters, digits, '-' or '_'" };
  }
  if (typeof b.message !== "string" || b.message.trim() === "" || b.message.length > MAX_MESSAGE_CHARS) {
    return { ok: false, error: `message must be a non-blank string of at most ${MAX_MESSAGE_CHARS} characters` };
  }
  return { ok: true, session: b.session, message: b.message.trim() };
}

/**
 * Checks a session id on its own, with the same rule as parseChatRequest.
 */
export function validSession(session: unknown): session is string {
  return typeof session === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(session);
}

// The rules every chat answer follows.
const SYSTEM = [
  "You are Lightpath, a read-only assistant for one Linux homelab server (Arch Linux).",
  "Answer in plain words, in at most 150 words.",
  "Do not invent facts about the server; when you would need a command's output to answer, say which command.",
  "You may suggest a fix or next check, labelled as a suggestion; the operator decides.",
].join(" ");

/**
 * Builds the messages for the model: first a system message (a read-only
 * assistant for a Linux homelab server; answers in at most 150 words; does
 * not invent facts about the server and says when it would need a command's
 * output; may suggest a fix or next check, labelled as a suggestion), then
 * `history` with its roles and contents unchanged and in order, then
 * `message` as the user's turn.
 */
export function buildChatMessages(history: StoredMessage[], message: string): Message[] {
  return [
    { role: "system", content: SYSTEM },
    ...history.map(({ role, content }) => ({ role, content })),
    { role: "user", content: message },
  ];
}

/**
 * Asks `model` (default MODELS.small) to answer `message` given `history`:
 * complete() with buildChatMessages(history, message).
 */
export async function reply(
  ai: AI,
  history: StoredMessage[],
  message: string,
  model: string = MODELS.small,
): Promise<Explanation> {
  return complete(ai, model, buildChatMessages(history, message));
}
