// An Env for tests: real Durable Object classes on in-memory SQLite, and
// small fakes for the Workflow and rate limiting bindings.
import type { Env, InstanceStatus, Namespace, WorkflowBinding } from "../src/bindings.ts";
import { Ledger } from "../src/ledger.ts";
import { NewsStore } from "../src/news_store.ts";
import { Session } from "../src/session.ts";
import { memorySql } from "./sqlite.ts";

export type Run = (model: string, input: any, options?: any) => Promise<unknown>;

// One object per name, created on first use.
function namespace(make: () => { fetch(r: Request): Promise<Response> }): Namespace {
  const live = new Map<string, { fetch(r: Request): Promise<Response> }>();
  return {
    idFromName: (name) => name,
    get: (id) => {
      const name = String(id);
      if (!live.has(name)) live.set(name, make());
      return live.get(name)!;
    },
  };
}

export interface FakeWorkflow extends WorkflowBinding {
  created: { id: string; params: unknown }[];
  statuses: Map<string, InstanceStatus>;
}

export function fakeWorkflow(prefix: string): FakeWorkflow {
  const created: { id: string; params: unknown }[] = [];
  const statuses = new Map<string, InstanceStatus>();
  return {
    created,
    statuses,
    async create(options) {
      const id = `${prefix}-${created.length + 1}`;
      created.push({ id, params: options?.params });
      statuses.set(id, { status: "queued" });
      return { id };
    },
    async get(id) {
      const s = statuses.get(id);
      if (!s) throw new Error(`instance.not_found: ${id}`);
      return { status: async () => s };
    },
  };
}

export type FakeEnv = Env & { TRIAGE: FakeWorkflow; NEWS: FakeWorkflow; limited: string[]; allow: boolean };

export function fakeEnv(run: Run, over: Partial<Env> = {}): FakeEnv {
  const ai = { run };
  const base = { AI: ai, AI_GATEWAY: "", JWT_SECRET: "test-secret" };
  const env = {
    ...base,
    // Like the runtime, Durable Objects get the whole env (read when created).
    SESSION: namespace(() => new Session({ storage: { sql: memorySql() } }, env)),
    LEDGER: namespace(() => new Ledger({ storage: { sql: memorySql() } }, {})),
    NEWS_STORE: namespace(() => new NewsStore({ storage: { sql: memorySql() } }, {})),
    TRIAGE: fakeWorkflow("triage"),
    NEWS: fakeWorkflow("news"),
    limited: [] as string[],
    allow: true,
    RATE_LIMITER: {
      limit: async ({ key }: { key: string }) => {
        env.limited.push(key);
        return { success: env.allow };
      },
    },
    ...over,
  } as FakeEnv;
  return env;
}
