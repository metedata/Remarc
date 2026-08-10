import assert from "node:assert/strict";
import test from "node:test";

import worker, { handleNotify, normalizeEmail } from "./index.mjs";

function request(body, headers = {}, url = "https://remarc.app/api/notify") {
  return new Request(url, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...headers },
    body: JSON.stringify(body),
  });
}

function database(changes = 1) {
  const calls = [];
  return {
    calls,
    prepare(sql) {
      return {
        bind(...values) {
          calls.push({ sql, values });
          return { run: async () => ({ meta: { changes } }) };
        },
      };
    },
  };
}

function verifier(result = {
  success: true,
  action: "turnstile-spin-v1",
  hostname: "remarc.app",
}, status = 200) {
  const calls = [];
  return {
    calls,
    async fetch(url, options) {
      calls.push({ url, options, body: JSON.parse(options.body) });
      return new Response(JSON.stringify(result), {
        status,
        headers: { "Content-Type": "application/json" },
      });
    },
  };
}

test("normalizes ordinary email addresses", () => {
  assert.equal(normalizeEmail("  Mete+Launch@Example.COM "), "mete+launch@example.com");
  assert.equal(normalizeEmail("missing-at.example.com"), null);
  assert.equal(normalizeEmail("a@b"), null);
});

test("composes the notify API with the scheduled launch router", async () => {
  const assetPaths = [];
  const env = {
    LAUNCH_AT: "2999-01-01T00:00:00Z",
    ASSETS: {
      async fetch(request) {
        assetPaths.push(new URL(request.url).pathname);
        return new Response("countdown");
      },
    },
  };
  const response = await worker.fetch(new Request("https://remarc.app/"), env);

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("X-Remarc-Site-State"), "countdown");
  assert.deepEqual(assetPaths, ["/"]);
});

test("stores a valid same-origin signup with fixed consent metadata", async () => {
  const db = database();
  const turnstile = verifier();
  const response = await handleNotify(
    request(
      { email: "Mete@Example.com", turnstileToken: "valid-token" },
      { Origin: "https://remarc.app", "CF-Connecting-IP": "203.0.113.4" },
    ),
    { WAITLIST_DB: db, TURNSTILE_VERIFY: turnstile },
  );

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
  assert.equal(db.calls.length, 1);
  assert.equal(db.calls[0].values[1], "mete@example.com");
  assert.equal(db.calls[0].values[2], "2026-08-09-launch-only-v2");
  assert.equal(db.calls[0].values[3], "One email when Remarc launches. Nothing else.");
  assert.equal(turnstile.calls.length, 1);
  assert.equal(turnstile.calls[0].body.token, "valid-token");
  assert.equal(turnstile.calls[0].body.remoteip, "203.0.113.4");
  assert.equal("email" in turnstile.calls[0].body, false);
});

test("returns the same success for an existing address", async () => {
  const response = await handleNotify(request({
    email: "mete@example.com",
    turnstileToken: "valid-token",
  }), {
    WAITLIST_DB: database(0),
    TURNSTILE_VERIFY: verifier(),
  });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
});

test("requires a server-verified Turnstile token before touching D1", async () => {
  const db = database();
  const response = await handleNotify(request({ email: "mete@example.com" }), {
    WAITLIST_DB: db,
    TURNSTILE_VERIFY: verifier(),
  });
  assert.equal(response.status, 403);
  assert.deepEqual(await response.json(), {
    ok: false,
    error: "verification_required",
  });
  assert.equal(db.calls.length, 0);
});

test("rejects failed, wrong-action, and wrong-hostname challenges", async () => {
  const cases = [
    { success: false, action: "turnstile-spin-v1", hostname: "remarc.app" },
    { success: true, action: "other-form", hostname: "remarc.app" },
    { success: true, action: "turnstile-spin-v1", hostname: "attacker.example" },
  ];

  for (const result of cases) {
    const db = database();
    const response = await handleNotify(request({
      email: "mete@example.com",
      turnstileToken: "invalid-token",
    }), {
      WAITLIST_DB: db,
      TURNSTILE_VERIFY: verifier(result),
    });
    assert.equal(response.status, 403);
    assert.equal(db.calls.length, 0);
  }
});

test("does not accept a localhost challenge on the production endpoint", async () => {
  const db = database();
  const response = await handleNotify(request({
    email: "mete@example.com",
    turnstileToken: "localhost-token",
  }), {
    WAITLIST_DB: db,
    TURNSTILE_VERIFY: verifier({
      success: true,
      action: "turnstile-spin-v1",
      hostname: "localhost",
    }),
  });
  assert.equal(response.status, 403);
  assert.equal(db.calls.length, 0);
});

test("accepts a localhost challenge only on the localhost endpoint", async () => {
  const db = database();
  const response = await handleNotify(request(
    { email: "mete@example.com", turnstileToken: "localhost-token" },
    { Origin: "http://localhost:4173" },
    "http://localhost:4173/api/notify",
  ), {
    WAITLIST_DB: db,
    TURNSTILE_VERIFY: verifier({
      success: true,
      action: "turnstile-spin-v1",
      hostname: "localhost",
    }),
  });
  assert.equal(response.status, 200);
  assert.equal(db.calls.length, 1);
});

test("accepts a configured preview challenge only on the matching endpoint", async () => {
  const hostname = "preview.example.com";
  const db = database();
  const response = await handleNotify(request(
    { email: "mete@example.com", turnstileToken: "preview-token" },
    { Origin: `https://${hostname}` },
    `https://${hostname}/api/notify`,
  ), {
    WAITLIST_DB: db,
    PREVIEW_HOSTNAME: hostname,
    TURNSTILE_VERIFY: verifier({
      success: true,
      action: "turnstile-spin-v1",
      hostname,
    }),
  });
  assert.equal(response.status, 200);
  assert.equal(db.calls.length, 1);
});

test("does not accept a preview challenge on the production endpoint", async () => {
  const db = database();
  const response = await handleNotify(request({
    email: "mete@example.com",
    turnstileToken: "preview-token",
  }), {
    WAITLIST_DB: db,
    TURNSTILE_VERIFY: verifier({
      success: true,
      action: "turnstile-spin-v1",
      hostname: "preview.example.com",
    }),
  });
  assert.equal(response.status, 403);
  assert.equal(db.calls.length, 0);
});

test("rejects production tokens and unconfigured preview hosts", async () => {
  const cases = [
    {
      requestHostname: "preview.example.com",
      verifiedHostname: "remarc.app",
    },
    {
      requestHostname: "other-preview.example.com",
      verifiedHostname: "other-preview.example.com",
    },
  ];

  for (const { requestHostname, verifiedHostname } of cases) {
    const db = database();
    const response = await handleNotify(request(
      { email: "mete@example.com", turnstileToken: "mismatched-token" },
      { Origin: `https://${requestHostname}` },
      `https://${requestHostname}/api/notify`,
    ), {
      WAITLIST_DB: db,
      PREVIEW_HOSTNAME: "preview.example.com",
      TURNSTILE_VERIFY: verifier({
        success: true,
        action: "turnstile-spin-v1",
        hostname: verifiedHostname,
      }),
    });
    assert.equal(response.status, 403);
    assert.equal(db.calls.length, 0);
  }
});

test("fails closed when the Turnstile verifier is unavailable", async () => {
  const db = database();
  const response = await handleNotify(request({
    email: "mete@example.com",
    turnstileToken: "valid-token",
  }), {
    WAITLIST_DB: db,
    TURNSTILE_VERIFY: {
      fetch: async () => { throw new Error("verifier unavailable"); },
    },
  });
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {
    ok: false,
    error: "verification_unavailable",
  });
  assert.equal(db.calls.length, 0);
});

test("fails closed for a missing binding, non-2xx response, or malformed JSON", async () => {
  const bindings = [
    undefined,
    verifier({ error: "unavailable" }, 503),
    {
      fetch: async () => new Response("not json", {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }),
    },
  ];

  for (const binding of bindings) {
    const db = database();
    const response = await handleNotify(request({
      email: "mete@example.com",
      turnstileToken: "valid-token",
    }), {
      WAITLIST_DB: db,
      TURNSTILE_VERIFY: binding,
    });
    assert.equal(response.status, 503);
    assert.equal(db.calls.length, 0);
  }
});

test("rejects an oversized Turnstile token without calling the verifier", async () => {
  const db = database();
  const turnstile = verifier();
  const response = await handleNotify(request({
    email: "mete@example.com",
    turnstileToken: "x".repeat(2049),
  }), {
    WAITLIST_DB: db,
    TURNSTILE_VERIFY: turnstile,
  });
  assert.equal(response.status, 403);
  assert.equal(turnstile.calls.length, 0);
  assert.equal(db.calls.length, 0);
});

test("rate limits before touching D1", async () => {
  const db = database();
  const turnstile = verifier();
  const response = await handleNotify(request({ email: "mete@example.com" }), {
    WAITLIST_DB: db,
    TURNSTILE_VERIFY: turnstile,
    NOTIFY_IP_RATE_LIMITER: { limit: async () => ({ success: false }) },
  });
  assert.equal(response.status, 429);
  assert.deepEqual(await response.json(), { ok: false, error: "rate_limited" });
  assert.equal(turnstile.calls.length, 0);
  assert.equal(db.calls.length, 0);
});

test("preserves a global denial when the actor limiter fails", async () => {
  const db = database();
  const response = await handleNotify(request({ email: "mete@example.com" }), {
    WAITLIST_DB: db,
    NOTIFY_IP_RATE_LIMITER: {
      limit: async () => { throw new Error("limiter unavailable"); },
    },
    NOTIFY_GLOBAL_RATE_LIMITER: { limit: async () => ({ success: false }) },
  });
  assert.equal(response.status, 429);
  assert.equal(db.calls.length, 0);
});

test("does not consume the global limiter after an actor denial", async () => {
  const db = database();
  let globalCalls = 0;
  const response = await handleNotify(request({ email: "mete@example.com" }), {
    WAITLIST_DB: db,
    NOTIFY_IP_RATE_LIMITER: { limit: async () => ({ success: false }) },
    NOTIFY_GLOBAL_RATE_LIMITER: {
      limit: async () => {
        globalCalls += 1;
        return { success: true };
      },
    },
  });
  assert.equal(response.status, 429);
  assert.equal(globalCalls, 0);
  assert.equal(db.calls.length, 0);
});

test("rejects an oversized streamed body", async () => {
  const db = database();
  const encoder = new TextEncoder();
  const body = new ReadableStream({
    start(controller) {
      controller.enqueue(encoder.encode(JSON.stringify({
        email: `${"a".repeat(5000)}@example.com`,
      })));
      controller.close();
    },
  });
  const response = await handleNotify(
    new Request("https://remarc.app/api/notify", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
      duplex: "half",
    }),
    { WAITLIST_DB: db },
  );
  assert.equal(response.status, 413);
  assert.equal(db.calls.length, 0);
});

test("rejects invalid addresses without touching D1", async () => {
  const db = database();
  const response = await handleNotify(request({ email: "nope" }), { WAITLIST_DB: db });
  assert.equal(response.status, 422);
  assert.equal(db.calls.length, 0);
});

test("silently drops honeypot submissions", async () => {
  const db = database();
  const response = await handleNotify(
    request({ email: "bot@example.com", company: "Spam Incorporated" }),
    { WAITLIST_DB: db },
  );
  assert.equal(response.status, 200);
  assert.equal(db.calls.length, 0);
});

test("rejects cross-site browser posts", async () => {
  const db = database();
  const response = await handleNotify(
    request(
      { email: "mete@example.com" },
      { Origin: "https://attacker.example", "Sec-Fetch-Site": "cross-site" },
    ),
    { WAITLIST_DB: db },
  );
  assert.equal(response.status, 403);
  assert.equal(db.calls.length, 0);
});
