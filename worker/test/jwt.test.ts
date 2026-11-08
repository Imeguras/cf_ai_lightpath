import { test } from "node:test";
import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { JWT_AUDIENCE, LEEWAY_S, MAX_LIFETIME_S, signJwt, verifyJwt, type Claims } from "../src/jwt.ts";

const SECRET = "test-secret-0123456789";
const NOW = 1_800_000_000_000;
const now = NOW / 1000;
const claims = (over: Partial<Claims> = {}): Claims => ({ aud: JWT_AUDIENCE, iat: now, exp: now + 60, ...over });

const b64url = (b: Buffer | string) => Buffer.from(b).toString("base64url");

// An independent HS256 signer (node:crypto), to check signJwt against.
function reference(header: object, payload: object, secret = SECRET): string {
  const data = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  return `${data}.${b64url(createHmac("sha256", secret).update(data).digest())}`;
}

test("signJwt produces a standard HS256 token", async () => {
  const c = claims({ sub: "web" });
  assert.equal(await signJwt(c, SECRET), reference({ alg: "HS256", typ: "JWT" }, c));
});

test("a fresh token verifies and returns its claims", async () => {
  const c = claims({ sub: "visitor-1" });
  assert.deepEqual(await verifyJwt(await signJwt(c, SECRET), SECRET, NOW), { ok: true, claims: c });
  assert.equal((await verifyJwt(reference({ alg: "HS256", typ: "JWT" }, c), SECRET, NOW)).ok, true);
});

test("time checks with leeway", async () => {
  const ok = async (c: Claims, at = NOW) => (await verifyJwt(await signJwt(c, SECRET), SECRET, at)).ok;
  assert.equal(await ok(claims({ iat: now + LEEWAY_S, exp: now + LEEWAY_S + 10 })), true);
  assert.equal(await ok(claims({ iat: now + LEEWAY_S + 1, exp: now + LEEWAY_S + 10 })), false);
  assert.equal(await ok(claims({ iat: now - 100, exp: now - LEEWAY_S })), true);
  assert.equal(await ok(claims({ iat: now - 100, exp: now - LEEWAY_S - 1 })), false);
  assert.equal(await ok(claims({ exp: now + MAX_LIFETIME_S })), true);
  assert.equal(await ok(claims({ exp: now + MAX_LIFETIME_S + 1 })), false);
  assert.equal(await ok(claims({ exp: now - 1 })), false, "exp before iat");
});

test("rejects wrong secret, audience, algorithm and shape", async () => {
  const good = await signJwt(claims(), SECRET);
  const [h, p, s] = good.split(".");
  const bad: [string, string][] = [
    [await signJwt(claims(), "other-secret"), "wrong secret"],
    [await signJwt(claims({ aud: "someone-else" }), SECRET), "audience"],
    [await signJwt({ ...claims(), iat: "now" as unknown as number }, SECRET), "iat string"],
    [await signJwt({ aud: JWT_AUDIENCE, iat: now } as Claims, SECRET), "no exp"],
    [reference({ alg: "none", typ: "JWT" }, claims()), "alg none (signed anyway)"],
    [`${b64url(JSON.stringify({ alg: "none" }))}.${p}.`, "alg none, empty signature"],
    [reference({ alg: "HS512", typ: "JWT" }, claims()), "other alg"],
    [reference({ alg: "HS256" }, [1, 2] as unknown as object), "claims not an object"],
    [`${h}.${b64url(JSON.stringify(claims({ exp: now + 100 })))}.${s}`, "payload swapped"],
    [`${h}.${p}`, "two parts"],
    [`${h}.${p}.${s}.x`, "four parts"],
    [`${h}.${p}.${s}=`, "padding"],
    [`${h}.${p}.!!!`, "not base64url"],
    ["", "empty"],
    [`${b64url("{not json")}.${p}.${s}`, "header not JSON"],
  ];
  for (const [token, why] of bad) {
    const r = await verifyJwt(token, SECRET, NOW);
    assert.equal(r.ok, false, why);
    if (!r.ok) {
      assert.equal(typeof r.error, "string");
      assert.ok(!r.error.includes(SECRET), why);
    }
  }
});

test("an empty secret never verifies", async () => {
  const t = reference({ alg: "HS256", typ: "JWT" }, claims(), "");
  assert.equal((await verifyJwt(t, "", NOW)).ok, false);
});
