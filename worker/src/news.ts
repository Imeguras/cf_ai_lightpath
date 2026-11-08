// Arch Linux news digest. Pure functions plus runNews, which orchestrates the
// steps of the news Workflow (workflows.ts) over injected dependencies.
// Package matching is deterministic and happens before the model: only the
// items and the names that matched go into the prompt.
import { clip, complete, MODELS, type AI, type Message } from "./explain.ts";
import type { StepRunner } from "./triage.ts";

export const ARCH_NEWS_FEED = "https://archlinux.org/feeds/news/";

/** Items older than this many days are left out. */
export const NEWS_WINDOW_DAYS = 30;

/** Characters of each item's text sent to the model. */
export const MAX_ITEM_CHARS = 1500;

/** Most package names accepted in one list. */
export const MAX_PACKAGES = 5000;

export interface NewsItem {
  title: string;
  link: string;
  /** pubDate in milliseconds since the epoch. */
  published: number;
  /** The description as plain text. */
  text: string;
}

export interface DigestItem {
  title: string;
  link: string;
  published: number;
  /** Installed packages the item mentions (see matchPackages). */
  matches: string[];
}

export interface NewsDigest {
  /** digestKey of the items and packages it was made from. */
  key: string;
  /** When it was made (ms since the epoch). */
  created: number;
  /** "" when no model was needed (no items). */
  model: string;
  text: string;
  neurons: number;
  /** True when it came from the store instead of a new model call. */
  cached: boolean;
  items: DigestItem[];
}

/**
 * The items of an RSS 2.0 feed, in document order. Each needs a title and a
 * pubDate that Date.parse understands; other items are skipped. Text is
 * decoded twice, as Arch's feed escapes HTML inside XML: XML entities and
 * CDATA first, then HTML tags are removed, then HTML entities (named
 * amp/lt/gt/quot/apos/nbsp and numeric ones) are decoded; runs of whitespace
 * become one space and the ends are trimmed. Title and link get the same
 * entity decoding.
 */
export function parseFeed(xml: string): NewsItem[] {
  const items: NewsItem[] = [];
  for (const [, body] of xml.matchAll(/<item>([\s\S]*?)<\/item>/g)) {
    const field = (name: string) => body.match(new RegExp(`<${name}>([\\s\\S]*?)</${name}>`))?.[1] ?? "";
    const title = plain(xmlText(field("title")));
    const published = Date.parse(xmlText(field("pubDate")).trim());
    if (!title || Number.isNaN(published)) continue;
    items.push({
      title,
      link: plain(xmlText(field("link"))),
      published,
      text: plain(xmlText(field("description")).replace(/<[^>]*>/g, " ")),
    });
  }
  return items;
}

// XML character data: CDATA sections verbatim, entities decoded elsewhere.
function xmlText(raw: string): string {
  return raw.replace(/<!\[CDATA\[([\s\S]*?)\]\]>|([^<]+)/g, (_, cdata, text) => cdata ?? decodeEntities(text));
}

// HTML entities, then whitespace collapsed.
function plain(text: string): string {
  return decodeEntities(text).replace(/\s+/g, " ").trim();
}

const NAMED: Record<string, string> = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: "\u00a0" };

function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9a-f]+|#[0-9]+|[a-z]+);/gi, (whole, e: string) => {
    if (e[0] === "#") {
      const code = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return code > 0 && code <= 0x10ffff ? String.fromCodePoint(code) : whole;
    }
    return NAMED[e.toLowerCase()] ?? whole;
  });
}

/**
 * The items published in the last `days` days before `now` (an item exactly
 * `days` days old is kept; items dated after `now` are kept too), newest
 * first.
 */
export function recentItems(items: NewsItem[], now: number, days: number = NEWS_WINDOW_DAYS): NewsItem[] {
  const since = now - days * 86_400_000;
  return items.filter((i) => i.published >= since).sort((a, b) => b.published - a.published);
}

/**
 * Checks an untrusted package list: {"packages": string[]} with at most
 * MAX_PACKAGES names, each a valid pacman package name (lowercase letters,
 * digits and @ . _ + -, not starting with - or .). Returns the names
 * deduplicated and sorted. The error message names "packages".
 */
export function parsePackages(body: unknown): { ok: true; packages: string[] } | { ok: false; error: string } {
  const list = typeof body === "object" && body !== null ? (body as { packages?: unknown }).packages : undefined;
  if (
    !Array.isArray(list) ||
    list.length > MAX_PACKAGES ||
    !list.every((p) => typeof p === "string" && /^[a-z0-9@_+][a-z0-9@._+-]*$/.test(p))
  ) {
    return { ok: false, error: `packages must be a list of at most ${MAX_PACKAGES} pacman package names` };
  }
  return { ok: true, packages: [...new Set(list as string[])].sort() };
}

/**
 * The packages named in the item's title or text as whole words: the name
 * must not be preceded or followed by a character that can be part of a
 * package name (a-z, 0-9, @ . _ + -), ignoring case. A "." right after the
 * name counts as punctuation when no such character follows it ("... dkms.").
 * Sorted.
 */
export function matchPackages(item: Pick<NewsItem, "title" | "text">, packages: string[]): string[] {
  const haystack = `${item.title}\n${item.text}`.toLowerCase();
  const nameChar = /[a-z0-9@._+-]/;
  return packages
    .filter((p) => {
      const name = p.toLowerCase();
      for (let i = haystack.indexOf(name); i !== -1; i = haystack.indexOf(name, i + 1)) {
        const before = haystack[i - 1] ?? "";
        let after = haystack[i + name.length] ?? "";
        if (after === ".") after = haystack[i + name.length + 1] ?? "";
        if (!nameChar.test(before) && !nameChar.test(after)) return true;
      }
      return false;
    })
    .sort();
}

/**
 * The messages for the digest. The system message asks for a digest of Arch
 * Linux news for the server's operator: one or two sentences per item, items
 * that affect installed packages first, saying clearly when manual
 * intervention is needed, at most 250 words, without inventing facts. The
 * user message has one block per item: its date (YYYY-MM-DD), title, the
 * installed packages it mentions (or "none"), and its text clipped to
 * MAX_ITEM_CHARS.
 */
export function buildNewsMessages(items: (NewsItem & { matches: string[] })[]): Message[] {
  const blocks = items.map((i) =>
    [
      `Date: ${new Date(i.published).toISOString().slice(0, 10)}`,
      `Title: ${i.title}`,
      `Installed packages it mentions: ${i.matches.length ? i.matches.join(", ") : "none"}`,
      `Text: ${clip(i.text, MAX_ITEM_CHARS)}`,
    ].join("\n"),
  );
  return [
    { role: "system", content: NEWS_SYSTEM },
    { role: "user", content: blocks.join("\n\n") },
  ];
}

const NEWS_SYSTEM = [
  "You write a digest of Arch Linux news for the operator of one Arch Linux server.",
  "Give one or two sentences per item.",
  "Put items that mention installed packages first.",
  "Say clearly when an item needs manual intervention.",
  "Use at most 250 words. Do not invent facts that are not in the items.",
].join(" ");

/**
 * A stable key for a digest: hex SHA-256 of the items' links and dates and
 * the package list. Same inputs, same key; any change, a new key.
 */
export async function digestKey(items: Pick<NewsItem, "link" | "published">[], packages: string[]): Promise<string> {
  const data = JSON.stringify({ items: items.map((i) => [i.link, i.published]), packages });
  const hash = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(data));
  return [...new Uint8Array(hash)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

export interface NewsDeps {
  ai: AI;
  /** The feed's XML. */
  fetchFeed(): Promise<string>;
  /** The installed packages last uploaded ([] when none). */
  packages(): Promise<string[]>;
  /** A stored digest for `key`, if any. */
  cached(key: string): Promise<NewsDigest | undefined>;
  /** Stores `digest` and makes it the latest. */
  save(digest: NewsDigest): Promise<void>;
  record(neurons: number): Promise<void>;
}

/**
 * Makes (or reuses) the digest, every external call inside a named step:
 *   "packages"  deps.packages()
 *   "feed"      deps.fetchFeed(), parsed and cut to recentItems(now)
 *   "cached"    deps.cached(key); when found, it is saved again as the latest
 *               ("save") and returned with cached: true; no model call
 *   "digest"    complete() with MODELS.large and buildNewsMessages; with no
 *               recent items there is no model call and the text is
 *               "No Arch Linux news in the last 30 days." (model "", 0 neurons)
 *   "save"      deps.save(digest)
 *   "record"    the digest's neurons, only when a model was called (a
 *               failure here is ignored)
 */
export async function runNews(step: StepRunner, deps: NewsDeps, now: number): Promise<NewsDigest> {
  const packages = await step.do("packages", () => deps.packages());
  const items = await step.do("feed", async () => recentItems(parseFeed(await deps.fetchFeed()), now));
  const key = await digestKey(items, packages);

  const hit = await step.do("cached", async () => (await deps.cached(key)) ?? null);
  if (hit) {
    await step.do("save", () => deps.save(hit));
    return { ...hit, cached: true };
  }

  const matched = items.map((i) => ({ ...i, matches: matchPackages(i, packages) }));
  const answer = await step.do("digest", async () =>
    matched.length === 0
      ? { model: "", text: `No Arch Linux news in the last ${NEWS_WINDOW_DAYS} days.`, neurons: 0 }
      : complete(deps.ai, MODELS.large, buildNewsMessages(matched)),
  );
  const digest: NewsDigest = {
    key,
    created: now,
    ...answer,
    cached: false,
    items: matched.map(({ title, link, published, matches }) => ({ title, link, published, matches })),
  };
  await step.do("save", () => deps.save(digest));
  if (answer.model) await step.do("record", () => deps.record(answer.neurons).catch(() => undefined));
  return digest;
}
