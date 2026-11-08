// When the cheap model's answer is kept and when the large model is asked
// instead. Plain data plus one pure function, so the rules are easy to read
// and to change (later: edited from the node editor, phase 10).
import { MODELS } from "./explain.ts";

export interface Routing {
  small: string;
  large: string;
  escalate: {
    /** Escalate when the small model's answer looks like it contains a command. */
    onCommand: boolean;
    /** Escalate questions at least this long (characters). */
    minQuestionChars: number;
  };
}

export const ROUTING: Routing = {
  small: MODELS.small,
  large: MODELS.large,
  escalate: { onCommand: true, minQuestionChars: 1500 },
};

export interface Decision {
  escalate: boolean;
  reason: string;
}

/**
 * True when `text` looks like it contains a shell command: it has a backtick,
 * a line that starts with "$ " (after optional spaces), or one of the words
 * doas, sudo or fudo.
 */
export function looksLikeCommand(text: string): boolean {
  return text.includes("`") || /^\s*\$ /m.test(text) || /\b(doas|sudo|fudo)\b/i.test(text);
}

/**
 * Decides whether to ask the large model, checking in this order and
 * returning the first that applies:
 *   1. `hard` is true                                → "asked for the large model"
 *   2. onCommand and looksLikeCommand(answer)        → "the small model suggested a command"
 *   3. question has at least minQuestionChars chars  → "long question"
 * Otherwise {escalate: false, reason: "small model answer kept"}.
 */
export function shouldEscalate(question: string, answer: string, hard: boolean, routing: Routing = ROUTING): Decision {
  if (hard) return { escalate: true, reason: "asked for the large model" };
  if (routing.escalate.onCommand && looksLikeCommand(answer)) {
    return { escalate: true, reason: "the small model suggested a command" };
  }
  if (question.length >= routing.escalate.minQuestionChars) return { escalate: true, reason: "long question" };
  return { escalate: false, reason: "small model answer kept" };
}
