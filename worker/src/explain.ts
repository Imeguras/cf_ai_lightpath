// Explaining one recorded command with Workers AI. Pure logic, no Cloudflare
// imports: the AI binding is passed in, so tests can use a fake.
import { estimateNeurons, roughTokens, usageOf } from "./neurons.ts";

/** One recorded command, as the web app sends it. */
export interface Fixture {
  id: string;
  argv: string[];
  exit_code: number;
  stdout: string;
  stderr: string;
  error: string;
}

/** The subset of the Workers AI binding we use. */
export interface AI {
  run(
    model: string,
    input: { messages: Message[]; max_tokens: number },
    options?: { gateway?: { id: string } },
  ): Promise<unknown>;
}

export interface Message {
  role: "system" | "user" | "assistant";
  content: string;
}

export interface Explanation {
  model: string;
  text: string;
  /** Rough neuron estimate for this call (display only, see neurons.ts). */
  neurons: number;
}

/** Cheap first, large only when asked (the triage Workflow decides later). */
export const MODELS = {
  small: "@cf/meta/llama-3.1-8b-instruct-fp8",
  large: "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
} as const;

/** Characters of stdout plus stderr sent to the model, to keep tokens down. */
export const MAX_OUTPUT_CHARS = 6000;

/** Longest answer we ask for. */
export const MAX_ANSWER_TOKENS = 400;

/**
 * Checks an untrusted request body. Requires `id` (a non-empty string of at
 * most 64 characters), `argv` (a non-empty array of strings) and `exit_code`
 * (an integer). `stdout`, `stderr` and `error` must be strings when present
 * and default to "". The error message names the offending field.
 */
export function parseFixture(body: unknown): { ok: true; fixture: Fixture } | { ok: false; error: string } {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "body must be a JSON object" };
  }
  const b = body as Record<string, unknown>;
  if (typeof b.id !== "string" || b.id === "" || b.id.length > 64) {
    return { ok: false, error: "id must be a non-empty string of at most 64 characters" };
  }
  if (!Array.isArray(b.argv) || b.argv.length === 0 || !b.argv.every((a) => typeof a === "string")) {
    return { ok: false, error: "argv must be a non-empty array of strings" };
  }
  if (typeof b.exit_code !== "number" || !Number.isInteger(b.exit_code)) {
    return { ok: false, error: "exit_code must be an integer" };
  }
  const text: Record<"stdout" | "stderr" | "error", string> = { stdout: "", stderr: "", error: "" };
  for (const field of ["stdout", "stderr", "error"] as const) {
    const v = b[field];
    if (v === undefined) continue;
    if (typeof v !== "string") return { ok: false, error: `${field} must be a string` };
    text[field] = v;
  }
  return { ok: true, fixture: { id: b.id, argv: b.argv as string[], exit_code: b.exit_code, ...text } };
}

/**
 * Returns `text` unchanged when it is at most `max` characters. Otherwise
 * keeps the first and last `max / 2` characters (errors tend to be at either
 * end) joined by a line saying how many characters were left out.
 */
export function clip(text: string, max: number): string {
  if (text.length <= max) return text;
  const half = Math.floor(max / 2);
  const omitted = text.length - 2 * half;
  return `${text.slice(0, half)}\n[... ${omitted} characters left out ...]\n${text.slice(text.length - half)}`;
}

// The rules every explanation follows.
const SYSTEM = [
  "You explain the output of one read-only diagnostic command run on a Linux homelab server.",
  "Say in plain words what the output tells about the server's state, in at most 120 words.",
  "If nothing in it needs attention, answer exactly: Nothing notable.",
  "Do not invent facts that are not in the output.",
  "You may suggest a likely fix or next check, labelled as a suggestion; the operator decides.",
].join(" ");

/**
 * Builds the chat messages. The system message asks for a plain-language
 * explanation of what the output says about the server, in at most 120
 * words; says to answer "Nothing notable." when that is the case; forbids
 * inventing facts that are not in the output; and allows suggesting a fix or
 * next check, labelled as a suggestion. The user message carries the command
 * line, the exit code, the error (if any), and stdout and stderr, which
 * together are clipped to MAX_OUTPUT_CHARS.
 */
export function buildMessages(f: Fixture): Message[] {
  // Each stream gets half the budget, plus whatever the other one leaves unused.
  const half = MAX_OUTPUT_CHARS / 2;
  const stderrMax = MAX_OUTPUT_CHARS - Math.min(f.stdout.length, half);
  const stderr = clip(f.stderr, stderrMax);
  const stdout = clip(f.stdout, MAX_OUTPUT_CHARS - Math.min(stderr.length, stderrMax));

  const parts = [`Command: ${f.argv.join(" ")}`, `Exit code: ${f.exit_code}`];
  if (f.error) parts.push(`Could not run: ${f.error}`);
  parts.push(`stdout:\n${stdout || "(empty)"}`, `stderr:\n${stderr || "(empty)"}`);
  return [
    { role: "system", content: SYSTEM },
    { role: "user", content: parts.join("\n\n") },
  ];
}

/**
 * Sends `messages` to `model` with at most MAX_ANSWER_TOKENS. Returns the
 * model, the trimmed answer and a rough neuron estimate: from the reply's
 * token counts when it has them (usageOf), otherwise from the sum of
 * roughTokens over the message contents, and roughTokens of the answer. Throws when the reply has no non-empty
 * `response` string.
 */
export async function complete(ai: AI, model: string, messages: Message[]): Promise<Explanation> {
  const reply = await ai.run(model, { messages, max_tokens: MAX_ANSWER_TOKENS });
  const text = typeof reply === "object" && reply !== null ? (reply as { response?: unknown }).response : undefined;
  if (typeof text !== "string" || text.trim() === "") {
    throw new Error("the model returned no answer");
  }
  const answer = text.trim();
  const usage = usageOf(reply) ?? {
    prompt_tokens: messages.reduce((n, m) => n + roughTokens(m.content), 0),
    completion_tokens: roughTokens(answer),
  };
  return { model, text: answer, neurons: estimateNeurons(model, usage) };
}

/**
 * Asks `model` (default MODELS.small) to explain `f`: complete() with
 * buildMessages(f).
 */
export async function explain(ai: AI, f: Fixture, model: string = MODELS.small): Promise<Explanation> {
  return complete(ai, model, buildMessages(f));
}
