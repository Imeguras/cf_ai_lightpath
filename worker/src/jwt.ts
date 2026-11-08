// HS256 JSON Web Tokens, by hand on WebCrypto (no dependency). The web app
// signs a short-lived token per request; the Worker verifies it.

/** The `aud` claim every token must carry. */
export const JWT_AUDIENCE = "lightpath-worker";

/** Longest accepted lifetime (exp - iat), in seconds. */
export const MAX_LIFETIME_S = 300;

/** Clock difference tolerated between the web app and the Worker, in seconds. */
export const LEEWAY_S = 60;

export interface Claims {
  aud: string;
  /** Issued at, seconds since the epoch. */
  iat: number;
  /** Expires at, seconds since the epoch. */
  exp: number;
  /** Who the request is for (rate limit key); optional. */
  sub?: string;
  [claim: string]: unknown;
}

/**
 * The compact JWS for `claims`: base64url (no padding) of the header
 * {"alg":"HS256","typ":"JWT"}, of the claims as JSON, and of their HMAC-SHA256
 * signature with `secret` (UTF-8), joined by ".".
 */
export async function signJwt(claims: Claims, secret: string): Promise<string> {
  const data = `${encode(JSON.stringify({ alg: "HS256", typ: "JWT" }))}.${encode(JSON.stringify(claims))}`;
  const signature = await crypto.subtle.sign("HMAC", await key(secret), bytes(data));
  return `${data}.${encode(new Uint8Array(signature))}`;
}

/**
 * Checks `token` against `secret` at `nowMs`. Valid only when all hold:
 * `secret` is not empty; the token has three base64url parts; the header is
 * JSON with alg exactly "HS256"; the signature matches (compared in constant
 * time by WebCrypto); the claims are a JSON object with aud equal to
 * JWT_AUDIENCE and numeric iat and exp; iat is at most LEEWAY_S in the
 * future; exp is not more than LEEWAY_S in the past; exp - iat is between 0
 * and MAX_LIFETIME_S. The error says which check failed, never the secret.
 */
export async function verifyJwt(
  token: string,
  secret: string,
  nowMs: number,
): Promise<{ ok: true; claims: Claims } | { ok: false; error: string }> {
  const fail = (error: string) => ({ ok: false as const, error });
  if (secret === "") return fail("the Worker has no JWT secret configured");
  const parts = token.split(".");
  if (parts.length !== 3 || !parts.every((p) => /^[A-Za-z0-9_-]*$/.test(p))) return fail("malformed token");
  const [h, p, s] = parts;

  const header = parseJson(decode(h));
  if (typeof header !== "object" || header === null || (header as { alg?: unknown }).alg !== "HS256") {
    return fail("unsupported token algorithm");
  }
  const valid = await crypto.subtle.verify("HMAC", await key(secret), decode(s), bytes(`${h}.${p}`));
  if (!valid) return fail("bad token signature");

  const claims = parseJson(decode(p)) as Claims | undefined;
  if (typeof claims !== "object" || claims === null || Array.isArray(claims)) return fail("claims are not an object");
  if (claims.aud !== JWT_AUDIENCE) return fail("wrong token audience");
  if (typeof claims.iat !== "number" || typeof claims.exp !== "number") return fail("token needs numeric iat and exp");
  const now = nowMs / 1000;
  if (claims.iat > now + LEEWAY_S) return fail("token issued in the future");
  if (claims.exp < now - LEEWAY_S) return fail("token expired");
  const lifetime = claims.exp - claims.iat;
  if (lifetime < 0 || lifetime > MAX_LIFETIME_S) return fail("token lifetime out of range");
  return { ok: true, claims };
}

function bytes(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

function key(secret: string): Promise<CryptoKey> {
  return crypto.subtle.importKey("raw", bytes(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign", "verify"]);
}

function encode(data: string | Uint8Array): string {
  const raw = typeof data === "string" ? bytes(data) : data;
  return btoa(String.fromCharCode(...raw)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function decode(part: string): Uint8Array {
  try {
    const bin = atob(part.replace(/-/g, "+").replace(/_/g, "/"));
    return Uint8Array.from(bin, (c) => c.charCodeAt(0));
  } catch {
    return new Uint8Array();
  }
}

function parseJson(raw: Uint8Array): unknown {
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw));
  } catch {
    return undefined;
  }
}
