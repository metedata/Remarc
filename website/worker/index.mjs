import launchRouter from "./launch-router.mjs";

const API_PATH = "/api/notify";
const CONSENT_VERSION = "2026-08-09-launch-only-v2";
const CONSENT_TEXT = "One email when Remarc launches. Nothing else.";
const MAX_BODY_BYTES = 4096;
const MAX_TURNSTILE_TOKEN_LENGTH = 2048;
const TURNSTILE_ACTION = "turnstile-spin-v1";
const TURNSTILE_HOSTNAMES = new Set([
  "remarc.app",
  "localhost",
  "127.0.0.1",
]);

const RESPONSE_HEADERS = {
  "Cache-Control": "no-store",
  "Content-Type": "application/json; charset=utf-8",
  "X-Content-Type-Options": "nosniff",
};

function json(body, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...RESPONSE_HEADERS, ...extraHeaders },
  });
}

export function normalizeEmail(value) {
  if (typeof value !== "string") return null;
  const email = value.trim().toLowerCase();
  if (email.length < 3 || email.length > 254) return null;
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email)) return null;
  return email;
}

function isSameOriginBrowserRequest(request, url) {
  const fetchSite = request.headers.get("Sec-Fetch-Site");
  if (fetchSite === "cross-site") return false;

  const origin = request.headers.get("Origin");
  if (!origin) return true;

  try {
    return new URL(origin).origin === url.origin;
  } catch {
    return false;
  }
}

async function readBody(request) {
  const declaredLength = Number(request.headers.get("Content-Length") || 0);
  if (declaredLength > MAX_BODY_BYTES) return { error: "too_large" };

  if (!request.body) return { error: "invalid_json" };
  const reader = request.body.getReader();
  const decoder = new TextDecoder();
  let received = 0;
  let raw = "";

  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      received += value.byteLength;
      if (received > MAX_BODY_BYTES) {
        await reader.cancel();
        return { error: "too_large" };
      }
      raw += decoder.decode(value, { stream: true });
    }
    raw += decoder.decode();
  } catch {
    return { error: "invalid_json" };
  }

  try {
    const value = JSON.parse(raw);
    if (!value || Array.isArray(value) || typeof value !== "object") {
      return { error: "invalid_json" };
    }
    return { value };
  } catch {
    return { error: "invalid_json" };
  }
}

async function checkRateLimit(binding, key) {
  if (!binding) return null;
  try {
    const result = await binding.limit({ key });
    return !result.success;
  } catch (error) {
    console.error(JSON.stringify({
      event: "launch_waitlist_rate_limit",
      outcome: "binding_error",
      message: error instanceof Error ? error.message : "unknown_error",
    }));
    return null;
  }
}

async function isRateLimited(request, env) {
  const actor = request.headers.get("CF-Connecting-IP") || "local-preview";
  const actorLimited = await checkRateLimit(env.NOTIFY_IP_RATE_LIMITER, actor);
  if (actorLimited) return true;

  const globalLimited = await checkRateLimit(
    env.NOTIFY_GLOBAL_RATE_LIMITER,
    "launch-notify",
  );
  return globalLimited === true;
}

async function verifyTurnstile(request, env, token) {
  if (
    typeof token !== "string" ||
    token.length < 1 ||
    token.length > MAX_TURNSTILE_TOKEN_LENGTH
  ) {
    return { ok: false, unavailable: false };
  }

  if (!env.TURNSTILE_VERIFY || typeof env.TURNSTILE_VERIFY.fetch !== "function") {
    console.error(JSON.stringify({
      event: "launch_waitlist_turnstile",
      outcome: "binding_missing",
    }));
    return { ok: false, unavailable: true };
  }

  try {
    const response = await env.TURNSTILE_VERIFY.fetch(
      "https://turnstile.internal/siteverify",
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Accept": "application/json",
        },
        body: JSON.stringify({
          token,
          remoteip: request.headers.get("CF-Connecting-IP") || undefined,
          idempotency_key: crypto.randomUUID(),
        }),
      },
    );

    if (!response.ok) {
      console.error(JSON.stringify({
        event: "launch_waitlist_turnstile",
        outcome: "verifier_http_error",
        status: response.status,
      }));
      return { ok: false, unavailable: true };
    }

    const result = await response.json();
    const hostname = typeof result.hostname === "string"
      ? result.hostname.toLowerCase()
      : "";
    const requestHostname = new URL(request.url).hostname.toLowerCase();
    const previewHostname = typeof env.PREVIEW_HOSTNAME === "string"
      ? env.PREVIEW_HOSTNAME.trim().toLowerCase()
      : "";
    const requestHostnameAllowed = TURNSTILE_HOSTNAMES.has(requestHostname) ||
      (previewHostname.length > 0 && requestHostname === previewHostname);
    const ok = result.success === true &&
      result.action === TURNSTILE_ACTION &&
      requestHostnameAllowed &&
      hostname === requestHostname;

    if (!ok) {
      console.warn(JSON.stringify({
        event: "launch_waitlist_turnstile",
        outcome: "rejected",
      }));
    }
    return { ok, unavailable: false };
  } catch (error) {
    console.error(JSON.stringify({
      event: "launch_waitlist_turnstile",
      outcome: "verifier_error",
      message: error instanceof Error ? error.message : "unknown_error",
    }));
    return { ok: false, unavailable: true };
  }
}

export async function handleNotify(request, env) {
  const url = new URL(request.url);

  if (request.method !== "POST") {
    return json(
      { ok: false, error: "method_not_allowed" },
      405,
      { Allow: "POST" },
    );
  }

  if (!isSameOriginBrowserRequest(request, url)) {
    return json({ ok: false, error: "forbidden" }, 403);
  }

  const contentType = request.headers.get("Content-Type") || "";
  if (!contentType.toLowerCase().includes("application/json")) {
    return json({ ok: false, error: "unsupported_media_type" }, 415);
  }

  const body = await readBody(request);
  if (body.error === "too_large") {
    return json({ ok: false, error: "request_too_large" }, 413);
  }
  if (body.error) {
    return json({ ok: false, error: "invalid_request" }, 400);
  }

  // A filled honeypot gets an indistinguishable success response so simple
  // form bots receive no useful feedback and no row is written.
  if (typeof body.value.company === "string" && body.value.company.trim()) {
    return json({ ok: true });
  }

  const email = normalizeEmail(body.value.email);
  if (!email) {
    return json({ ok: false, error: "invalid_email" }, 422);
  }

  if (await isRateLimited(request, env)) {
    return json({ ok: false, error: "rate_limited" }, 429, { "Retry-After": "60" });
  }

  const verification = await verifyTurnstile(
    request,
    env,
    body.value.turnstileToken,
  );
  if (!verification.ok) {
    if (verification.unavailable) {
      return json({ ok: false, error: "verification_unavailable" }, 503);
    }
    return json({ ok: false, error: "verification_required" }, 403);
  }

  try {
    const result = await env.WAITLIST_DB.prepare(
      `INSERT INTO launch_waitlist (
        id, email, source, consent_version, consent_text
      ) VALUES (?, ?, 'countdown-landing', ?, ?)
      ON CONFLICT(email) DO NOTHING`,
    )
      .bind(crypto.randomUUID(), email, CONSENT_VERSION, CONSENT_TEXT)
      .run();

    console.log(JSON.stringify({
      event: "launch_waitlist_signup",
      outcome: result.meta.changes > 0 ? "inserted" : "already_present",
    }));

    // Never reveal whether an address was already present.
    return json({ ok: true });
  } catch (error) {
    console.error(JSON.stringify({
      event: "launch_waitlist_signup",
      outcome: "database_error",
      message: error instanceof Error ? error.message : "unknown_error",
    }));
    return json({ ok: false, error: "temporary_error" }, 503);
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === API_PATH) return handleNotify(request, env);
    return launchRouter.fetch(request, env);
  },
};
