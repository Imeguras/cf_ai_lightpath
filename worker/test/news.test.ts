import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  buildNewsMessages,
  digestKey,
  MAX_ITEM_CHARS,
  MAX_PACKAGES,
  matchPackages,
  NEWS_WINDOW_DAYS,
  parseFeed,
  parsePackages,
  recentItems,
  runNews,
  type NewsDeps,
  type NewsDigest,
  type NewsItem,
} from "../src/news.ts";
import { MODELS } from "../src/explain.ts";
import { estimateNeurons } from "../src/neurons.ts";
import type { StepRunner } from "../src/triage.ts";

const DAY = 86_400_000;

const feed = (items: string) =>
  `<?xml version="1.0" encoding="utf-8"?><rss version="2.0"><channel><title>t</title>${items}</channel></rss>`;

const item = (title: string, date: string, description = "", link = "https://archlinux.org/news/x/") =>
  `<item><title>${title}</title><link>${link}</link><description>${description}</description><pubDate>${date}</pubDate></item>`;

test("parseFeed: items in order with dates, links and decoded text", () => {
  const xml = feed(
    item(
      "zfs-dkms &amp; linux &gt;= 7.2",
      "Wed, 21 Oct 2026 13:58:42 +0000",
      "&lt;p&gt;Manual  intervention &amp;amp; &lt;a href=&quot;x&quot;&gt;read&lt;/a&gt;&lt;/p&gt;\n&lt;p&gt;caf&amp;#233; &amp;lt;3&amp;nbsp;ok&lt;/p&gt;",
      "https://archlinux.org/news/a/",
    ) +
      item("Second", "Tue, 22 Sep 2026 09:09:27 +0000", "<![CDATA[<b>bold</b> &amp; plain]]>", "https://archlinux.org/news/b/"),
  );
  assert.deepEqual(parseFeed(xml), [
    {
      title: "zfs-dkms & linux >= 7.2",
      link: "https://archlinux.org/news/a/",
      published: Date.parse("Wed, 21 Oct 2026 13:58:42 +0000"),
      text: "Manual intervention & read café <3 ok",
    },
    {
      title: "Second",
      link: "https://archlinux.org/news/b/",
      published: Date.parse("Tue, 22 Sep 2026 09:09:27 +0000"),
      text: "bold & plain",
    },
  ]);
});

test("parseFeed skips items without a title or a valid date", () => {
  const xml = feed(
    item("", "Wed, 21 Oct 2026 13:58:42 +0000") + item("No date", "not a date") + item("Good", "Tue, 22 Sep 2026 09:09:27 +0000"),
  );
  assert.deepEqual(parseFeed(xml).map((i) => i.title), ["Good"]);
  assert.deepEqual(parseFeed(""), []);
  assert.deepEqual(parseFeed("<html>not a feed</html>"), []);
});

test("parseFeed reads the real Arch feed", () => {
  const items = parseFeed(readFileSync(new URL("./data/arch-news.xml", import.meta.url), "utf8"));
  assert.equal(items.length, 10);
  for (const i of items) {
    assert.ok(i.title && i.link.startsWith("https://archlinux.org/news/"), i.title);
    assert.ok(Number.isFinite(i.published));
    assert.doesNotMatch(i.text, /<[a-z]|&lt;|&amp;/i, i.title);
  }
  assert.match(items[0].title, /php/);
});

const at = (title: string, published: number): NewsItem => ({ title, link: "l", published, text: "" });

test("recentItems keeps the window, newest first", () => {
  const now = Date.UTC(2026, 10, 7);
  const items = [
    at("old", now - (NEWS_WINDOW_DAYS + 1) * DAY),
    at("edge", now - NEWS_WINDOW_DAYS * DAY),
    at("week", now - 7 * DAY),
    at("future", now + DAY),
    at("today", now),
  ];
  assert.deepEqual(recentItems(items, now).map((i) => i.title), ["future", "today", "week", "edge"]);
  assert.deepEqual(recentItems(items, now, 7).map((i) => i.title), ["future", "today", "week"]);
});

test("parsePackages: valid names, deduplicated and sorted", () => {
  assert.deepEqual(parsePackages({ packages: ["zfs-dkms", "linux", "linux", "lib32-gcc-libs", "gtk+", "r8168@x", "a.b_c"] }), {
    ok: true,
    packages: ["a.b_c", "gtk+", "lib32-gcc-libs", "linux", "r8168@x", "zfs-dkms"],
  });
  assert.deepEqual(parsePackages({ packages: [] }), { ok: true, packages: [] });
});

test("parsePackages rejects bad input, naming packages", () => {
  for (const body of [
    null,
    {},
    { packages: "linux" },
    { packages: ["Linux"] },
    { packages: ["-linux"] },
    { packages: [".linux"] },
    { packages: ["li nux"] },
    { packages: [""] },
    { packages: [3] },
    { packages: ["a;rm"] },
    { packages: Array.from({ length: MAX_PACKAGES + 1 }, (_, i) => `p${i}`) },
  ]) {
    const r = parsePackages(body);
    assert.equal(r.ok, false, JSON.stringify(body)?.slice(0, 60));
    if (!r.ok) assert.match(r.error, /packages/);
  }
  assert.equal(parsePackages({ packages: Array.from({ length: MAX_PACKAGES }, (_, i) => `p${i}`) }).ok, true);
});

test("matchPackages finds whole package names, ignoring case", () => {
  const pk = ["linux", "linux-lts", "zfs-dkms", "zfs", "php", "php-legacy", "gtk+", "dkms"];
  assert.deepEqual(matchPackages({ title: "Update to PHP ≥ 8.5", text: "and php-legacy too" }, pk), ["php", "php-legacy"]);
  assert.deepEqual(matchPackages({ title: "zfs-dkms needs linux-lts", text: "" }, pk), ["linux-lts", "zfs-dkms"]);
  assert.deepEqual(matchPackages({ title: "gtk+ 4 (and gtk+3)", text: "dkms." }, pk), ["dkms", "gtk+"]);
  assert.deepEqual(matchPackages({ title: "nothing here", text: "linuxfoo phpx" }, pk), []);
});

test("buildNewsMessages: system rules, one block per item", () => {
  const long = "y".repeat(MAX_ITEM_CHARS + 500);
  const msgs = buildNewsMessages([
    { title: "zfs news", link: "l1", published: Date.UTC(2026, 9, 21, 13), text: "body one", matches: ["zfs-dkms"] },
    { title: "other", link: "l2", published: Date.UTC(2026, 9, 2), text: long, matches: [] },
  ]);
  assert.equal(msgs.length, 2);
  assert.equal(msgs[0].role, "system");
  for (const re of [/Arch Linux/, /250 words/, /manual intervention/i, /invent/i, /installed/i]) assert.match(msgs[0].content, re);
  assert.equal(msgs[1].role, "user");
  const u = msgs[1].content;
  for (const s of ["2026-10-21", "zfs news", "zfs-dkms", "body one", "2026-10-02", "other", "none"]) assert.ok(u.includes(s), s);
  assert.ok(!u.includes(long), "item text is clipped");
  assert.ok(u.length < 2 * MAX_ITEM_CHARS + 1000);
});

test("digestKey is stable and changes with any input", async () => {
  const items = [{ link: "a", published: 1 }];
  const k = await digestKey(items, ["linux"]);
  assert.match(k, /^[0-9a-f]{64}$/);
  assert.equal(await digestKey([{ link: "a", published: 1 }], ["linux"]), k);
  assert.notEqual(await digestKey([{ link: "b", published: 1 }], ["linux"]), k);
  assert.notEqual(await digestKey([{ link: "a", published: 2 }], ["linux"]), k);
  assert.notEqual(await digestKey(items, ["linux", "zfs"]), k);
  assert.notEqual(await digestKey(items, []), k);
});

// --- runNews -------------------------------------------------------------

const NOW = Date.UTC(2026, 10, 7, 6);
const usage = { prompt_tokens: 900, completion_tokens: 200 };

function setup(xml: string, opts: { packages?: string[]; cached?: NewsDigest; aiError?: Error } = {}) {
  const names: string[] = [];
  const runner: StepRunner = { do: async (n, fn) => (names.push(n), fn()) };
  const ai: { model?: string; messages?: unknown; calls: number } = { calls: 0 };
  const saved: NewsDigest[] = [];
  const recorded: number[] = [];
  const deps: NewsDeps = {
    ai: {
      run: async (model, input: any) => {
        ai.calls++;
        ai.model = model;
        ai.messages = input.messages;
        if (opts.aiError) throw opts.aiError;
        return { response: " Digest text. ", usage };
      },
    },
    fetchFeed: async () => xml,
    packages: async () => opts.packages ?? [],
    cached: async (key) => (opts.cached && opts.cached.key === key ? opts.cached : undefined),
    save: async (d) => void saved.push(d),
    record: async (n) => void recorded.push(n),
  };
  return { names, runner, deps, ai, saved, recorded };
}

const recentXml = feed(
  item("zfs-dkms 2.4.4 supports linux 7.2", "Thu, 05 Nov 2026 10:00:00 +0000", "&lt;p&gt;Update zfs-dkms.&lt;/p&gt;", "https://archlinux.org/news/z/") +
    item("Old news", "Mon, 01 Jun 2026 10:00:00 +0000", "old", "https://archlinux.org/news/o/"),
);

test("runNews makes a digest of recent items with the large model", async () => {
  const s = setup(recentXml, { packages: ["linux", "zfs-dkms", "vim"] });
  const d = await runNews(s.runner, s.deps, NOW);

  assert.deepEqual(s.names, ["packages", "feed", "cached", "digest", "save", "record"]);
  assert.equal(s.ai.calls, 1);
  assert.equal(s.ai.model, MODELS.large);
  const z = parseFeed(recentXml)[0];
  assert.deepEqual(s.ai.messages, buildNewsMessages([{ ...z, matches: ["linux", "zfs-dkms"] }]));
  assert.deepEqual(d, {
    key: await digestKey([z], ["linux", "zfs-dkms", "vim"]),
    created: NOW,
    model: MODELS.large,
    text: "Digest text.",
    neurons: estimateNeurons(MODELS.large, usage),
    cached: false,
    items: [{ title: z.title, link: z.link, published: z.published, matches: ["linux", "zfs-dkms"] }],
  });
  assert.deepEqual(s.saved, [d]);
  assert.deepEqual(s.recorded, [d.neurons]);
});

test("runNews reuses a stored digest without calling the model", async () => {
  const first = setup(recentXml, { packages: ["zfs-dkms"] });
  const made = await runNews(first.runner, first.deps, NOW);

  const s = setup(recentXml, { packages: ["zfs-dkms"], cached: made });
  const d = await runNews(s.runner, s.deps, NOW + 3_600_000);
  assert.equal(s.ai.calls, 0);
  assert.deepEqual(d, { ...made, cached: true });
  assert.deepEqual(s.names, ["packages", "feed", "cached", "save"]);
  assert.deepEqual(s.saved, [made]);
  assert.deepEqual(s.recorded, []);
});

test("runNews with no recent items needs no model", async () => {
  const s = setup(feed(item("Old news", "Mon, 01 Jun 2026 10:00:00 +0000")));
  const d = await runNews(s.runner, s.deps, NOW);
  assert.equal(s.ai.calls, 0);
  assert.equal(d.model, "");
  assert.equal(d.neurons, 0);
  assert.equal(d.text, "No Arch Linux news in the last 30 days.");
  assert.deepEqual(d.items, []);
  assert.deepEqual(s.saved, [d]);
  assert.deepEqual(s.recorded, []);
});

test("runNews: a failing model call propagates and nothing is saved", async () => {
  const s = setup(recentXml, { aiError: new Error("4006") });
  await assert.rejects(runNews(s.runner, s.deps, NOW), /4006/);
  assert.deepEqual(s.saved, []);
});

test("runNews: a failing record is ignored", async () => {
  const s = setup(recentXml);
  s.deps.record = async () => {
    throw new Error("down");
  };
  assert.equal((await runNews(s.runner, s.deps, NOW)).text, "Digest text.");
});
