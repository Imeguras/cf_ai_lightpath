// Lightpath Worker: the Cloudflare side of the app.
import { aiFor, history, record, sessionFor, today, type Env, type WorkflowBinding } from "./bindings.ts";
import { parseChatRequest, validSession } from "./chat.ts";
import { explain, parseFixture } from "./explain.ts";
import { verifyJwt } from "./jwt.ts";
import { Ledger } from "./ledger.ts";
import { MAX_BODY_BYTES } from "./limits.ts";
import { parsePackages } from "./news.ts";
import { NEWS_STORE_NAME, NewsStore } from "./news_store.ts";
import { DAILY_FREE_NEURONS, quotaHint } from "./neurons.ts";
import { Session } from "./session.ts";
import { parseTriageRequest } from "./triage.ts";
import { NewsWorkflow, TriageWorkflow } from "./workflows.ts";

// Durable Object and Workflow classes must be exported from the main module,
// and nothing else may be (constants live in other modules).
export { Ledger, NewsStore, NewsWorkflow, Session, TriageWorkflow };

/**
 * Routes. Every response is JSON (`content-type: application/json`).
 *
 * Auth: every route except GET /api/health needs `Authorization: Bearer
 * <JWT>`, verified with env.JWT_SECRET (see jwt.ts); otherwise 401 {"error"}
 * with `www-authenticate: Bearer`. Routes marked (AI) also pass the rate
 * limiter, keyed by the token's `sub` (or "anonymous"); over the limit they
 * answer 429 {"error"} without calling anything.
 *
 *   GET  /api/health          200 {"ok": true}
 *   GET  /api/usage           200 {"day", "neurons", "calls", "allowance", "rough": true}
 *                             502 {"error"} when the Ledger cannot be read
 *   POST /api/explain    (AI) body: a fixture (see parseFixture)
 *                             200 {"model", "text", "neurons"}
 *   POST /api/chat       (AI) body {"session", "message"} (see parseChatRequest),
 *                             answered by the Session Durable Object `session`
 *                             200 {"model", "text", "neurons"}
 *   GET  /api/chat/history?session=ID
 *                             200 {"messages": [...]}, oldest first
 *   POST /api/triage     (AI) body {"session", "message", "hard"?} (see
 *                             parseTriageRequest); starts a TriageWorkflow
 *                             202 {"id"}
 *   GET  /api/triage/status?id=ID
 *                             200 {"status", "output"?, "error"?}: the
 *                                 instance's status, output (a TriageResult)
 *                                 and error message
 *                             404 {"error"} for an unknown instance
 *   PUT  /api/news/packages   body {"packages": [...]} (see parsePackages)
 *                             200 {"count"}
 *   POST /api/news       (AI) starts a NewsWorkflow; 202 {"id"}
 *   GET  /api/news/status?id=ID   as /api/triage/status (output: a NewsDigest)
 *   GET  /api/news/latest     200 the latest NewsDigest; 404 {"error"} if none
 *
 *   Bodies: 400 {"error"} when not JSON or invalid, 413 {"error"} over
 *   MAX_BODY_BYTES (limits.ts). A missing or malformed ?session= or ?id= is
 *   400. Workers AI failing is 502 {"error"}, ending with quotaHint (see
 *   below). Another method on a known path is 405 {"error"}; any other path,
 *   404 {"error"} (after auth).
 *
 * Neurons: every successful explain or chat adds its estimate to the Ledger
 * (the Workflows record their own). A 502 from Workers AI ends its error with
 * quotaHint(today's estimate). The Ledger is display only: when it fails,
 * explain and chat answer as if it did not exist, and a 502 has no hint.
 *
 * Cron (scheduled): starts a NewsWorkflow.
 *
 * Workers AI calls go through the AI Gateway env.AI_GATEWAY when it is set.
 */
export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const route = ROUTES[url.pathname];
    if (url.pathname === "/api/health") {
      return request.method === "GET" ? json(200, { ok: true }) : methodNotAllowed();
    }

    const auth = request.headers.get("authorization") ?? "";
    const bearer = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    const verified = await verifyJwt(bearer, env.JWT_SECRET, Date.now());
    if (!verified.ok) {
      return json(401, { error: `unauthorized: ${verified.error}` }, { "www-authenticate": "Bearer" });
    }

    if (!route) return json(404, { error: "not found" });
    if (request.method !== route.method) return methodNotAllowed();
    if (route.ai) {
      const { success } = await env.RATE_LIMITER.limit({ key: verified.claims.sub ?? "anonymous" });
      if (!success) return json(429, { error: "too many AI requests; try again in a minute" });
    }
    return route.handle(request, env, url);
  },

  async scheduled(_controller: unknown, env: Env, ctx: { waitUntil(p: Promise<unknown>): void }): Promise<void> {
    ctx.waitUntil(env.NEWS.create());
  },
};

interface Route {
  method: string;
  /** Spends neurons: passes the rate limiter first. */
  ai: boolean;
  handle(request: Request, env: Env, url: URL): Promise<Response>;
}

const ROUTES: Record<string, Route> = {
  "/api/usage": { method: "GET", ai: false, handle: (_r, env) => handleUsage(env) },
  "/api/explain": { method: "POST", ai: true, handle: (r, env) => handleExplain(r, env) },
  "/api/chat": { method: "POST", ai: true, handle: (r, env) => handleChat(r, env) },
  "/api/chat/history": { method: "GET", ai: false, handle: (_r, env, url) => handleHistory(env, url) },
  "/api/triage": { method: "POST", ai: true, handle: (r, env) => handleTriage(r, env) },
  "/api/triage/status": { method: "GET", ai: false, handle: (_r, env, url) => instanceStatus(env.TRIAGE, url) },
  "/api/news/packages": { method: "PUT", ai: false, handle: (r, env) => handlePackages(r, env) },
  "/api/news": { method: "POST", ai: true, handle: async (_r, env) => json(202, { id: (await env.NEWS.create()).id }) },
  "/api/news/status": { method: "GET", ai: false, handle: (_r, env, url) => instanceStatus(env.NEWS, url) },
  "/api/news/latest": { method: "GET", ai: false, handle: (_r, env) => newsStore(env).fetch(new Request("https://news/latest")) },
};

async function handleExplain(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (body instanceof Response) return body;
  const parsed = parseFixture(body);
  if (!parsed.ok) return json(400, { error: parsed.error });

  let answer;
  try {
    answer = await explain(aiFor(env), parsed.fixture);
  } catch (e) {
    return aiFailed(env, `Workers AI failed: ${e instanceof Error ? e.message : String(e)}`);
  }
  await record(env, answer.neurons);
  return json(200, answer);
}

async function handleChat(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (body instanceof Response) return body;
  const parsed = parseChatRequest(body);
  if (!parsed.ok) return json(400, { error: parsed.error });
  const res = await sessionFor(env, parsed.session).fetch(
    new Request("https://session/chat", { method: "POST", body: JSON.stringify({ message: parsed.message }) }),
  );
  const out = (await res.json()) as { neurons?: number; error?: string };
  if (res.status === 502) return aiFailed(env, String(out.error));
  if (res.status === 200 && typeof out.neurons === "number") await record(env, out.neurons);
  return json(res.status, out);
}

async function handleHistory(env: Env, url: URL): Promise<Response> {
  const session = url.searchParams.get("session");
  if (!validSession(session)) {
    return json(400, { error: "session must be 1 to 64 letters, digits, '-' or '_'" });
  }
  return json(200, { messages: await history(env, session) });
}

async function handleTriage(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (body instanceof Response) return body;
  const parsed = parseTriageRequest(body);
  if (!parsed.ok) return json(400, { error: parsed.error });
  const { session, message, hard } = parsed;
  return json(202, { id: (await env.TRIAGE.create({ params: { session, message, hard } })).id });
}

async function handlePackages(request: Request, env: Env): Promise<Response> {
  const body = await readJson(request);
  if (body instanceof Response) return body;
  const parsed = parsePackages(body);
  if (!parsed.ok) return json(400, { error: parsed.error });
  return newsStore(env).fetch(
    new Request("https://news/packages", { method: "PUT", body: JSON.stringify({ packages: parsed.packages }) }),
  );
}

async function instanceStatus(workflow: WorkflowBinding, url: URL): Promise<Response> {
  const id = url.searchParams.get("id") ?? "";
  if (!/^[A-Za-z0-9_-]{1,100}$/.test(id)) return json(400, { error: "id must be 1 to 100 letters, digits, '-' or '_'" });
  let status;
  try {
    status = await (await workflow.get(id)).status();
  } catch {
    return json(404, { error: "no such instance" });
  }
  // The runtime reports a missing output or error as null (or leaves it out).
  return json(200, {
    status: status.status,
    ...(status.output == null ? {} : { output: status.output }),
    ...(status.error == null ? {} : { error: status.error.message ?? String(status.error) }),
  });
}

async function handleUsage(env: Env): Promise<Response> {
  try {
    return json(200, { ...(await today(env)), allowance: DAILY_FREE_NEURONS, rough: true });
  } catch (e) {
    return json(502, { error: `usage estimate unavailable: ${e instanceof Error ? e.message : String(e)}` });
  }
}

function newsStore(env: Env) {
  return env.NEWS_STORE.get(env.NEWS_STORE.idFromName(NEWS_STORE_NAME));
}

// A Workers AI failure, with the rough quota hint when the Ledger answers.
async function aiFailed(env: Env, error: string): Promise<Response> {
  try {
    return json(502, { error: `${error}. ${quotaHint((await today(env)).neurons)}` });
  } catch {
    return json(502, { error });
  }
}

/** The parsed JSON body, or the 413/400 response to send instead. */
async function readJson(request: Request): Promise<unknown> {
  const raw = await request.text();
  if (new TextEncoder().encode(raw).length > MAX_BODY_BYTES) {
    return json(413, { error: `body is larger than ${MAX_BODY_BYTES} bytes` });
  }
  try {
    return JSON.parse(raw);
  } catch {
    return json(400, { error: "body is not valid JSON" });
  }
}

function methodNotAllowed(): Response {
  return json(405, { error: "method not allowed" });
}

function json(status: number, body: unknown, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });
}
