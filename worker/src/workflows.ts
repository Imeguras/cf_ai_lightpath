// The Workflow classes. Thin: they connect runTriage and runNews to the
// Workflow runtime (checkpointed, retried steps) and to the bindings.
import { WorkflowEntrypoint } from "cloudflare:workers";
import { aiFor, history, record, store, type Env } from "./bindings.ts";
import { ARCH_NEWS_FEED, runNews, type NewsDeps, type NewsDigest } from "./news.ts";
import { NEWS_STORE_NAME } from "./news_store.ts";
import { runTriage, type StepRunner, type TriageInput, type TriageResult } from "./triage.ts";

/**
 * Every step: one retry after 10 seconds, then the instance errors (a retry
 * spends neurons again, so not more), and at most 2 minutes per attempt.
 */
export const STEP_CONFIG = {
  retries: { limit: 1, delay: "10 seconds", backoff: "constant" },
  timeout: "2 minutes",
} as const;

/** Largest feed accepted, in bytes. */
export const MAX_FEED_BYTES = 1024 * 1024;

/** The subset of the runtime's WorkflowStep we use. */
export interface WorkflowStepLike {
  do<T>(name: string, config: typeof STEP_CONFIG, fn: () => Promise<T>): Promise<T>;
}

/** A StepRunner that runs each step through `step.do` with STEP_CONFIG. */
export function runner(step: WorkflowStepLike): StepRunner {
  return { do: (name, fn) => step.do(name, STEP_CONFIG, fn) };
}

/** Triage of one chat question; the instance's output is the TriageResult. */
export class TriageWorkflow extends WorkflowEntrypoint<Env, TriageInput> {
  async run(event: { payload: TriageInput }, step: WorkflowStepLike): Promise<TriageResult> {
    const env = this.env;
    const deps = {
      ai: aiFor(env),
      history: (session: string) => history(env, session),
      store: (session: string, messages: Parameters<typeof store>[2]) => store(env, session, messages),
      record: (neurons: number) => record(env, neurons),
    };
    return runTriage(runner(step), deps, event.payload);
  }
}

/**
 * The Arch news digest, as of the instance's creation time (event.timestamp,
 * so a replayed run sees the same "now"). Fetches ARCH_NEWS_FEED; a non-2xx
 * status or a body over MAX_FEED_BYTES fails the "feed" step. Packages and
 * digests live in the NewsStore Durable Object.
 */
export class NewsWorkflow extends WorkflowEntrypoint<Env, Record<string, never>> {
  async run(event: { timestamp: Date }, step: WorkflowStepLike): Promise<NewsDigest> {
    const env = this.env;
    const news = env.NEWS_STORE.get(env.NEWS_STORE.idFromName(NEWS_STORE_NAME));
    const ask = async (path: string, init?: RequestInit) => {
      const res = await news.fetch(new Request(`https://news${path}`, init));
      if (!res.ok && res.status !== 404) throw new Error(`news store answered ${res.status}`);
      return res;
    };
    const deps: NewsDeps = {
      ai: aiFor(env),
      fetchFeed: async () => {
        const res = await fetch(ARCH_NEWS_FEED, { headers: { "user-agent": "Lightpath (homelab copilot)" } });
        if (!res.ok) throw new Error(`the Arch news feed answered ${res.status}`);
        const body = await res.text();
        if (new TextEncoder().encode(body).length > MAX_FEED_BYTES) throw new Error("the Arch news feed is too large");
        return body;
      },
      packages: async () => ((await (await ask("/packages")).json()) as { packages: string[] }).packages,
      cached: async (key) => {
        const res = await ask(`/digest?key=${encodeURIComponent(key)}`);
        return res.status === 404 ? undefined : ((await res.json()) as NewsDigest);
      },
      save: async (digest) => void (await ask("/digest", { method: "PUT", body: JSON.stringify(digest) })),
      record: (neurons) => record(env, neurons),
    };
    return runNews(runner(step), deps, event.timestamp.getTime());
  }
}
