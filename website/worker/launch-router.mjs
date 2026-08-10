// @ts-check

/**
 * @typedef {object} Env
 * @property {{ fetch(request: Request): Promise<Response> }} ASSETS
 * @property {string} LAUNCH_AT
 */

/**
 * @typedef {object} WorkerHandler
 * @property {(request: Request, env: Env) => Promise<Response>} fetch
 */

const ROOT_PATH = '/';
const LAUNCH_ASSET_PATH = '/_launch/';
const STATE_HEADER = 'X-Remarc-Site-State';
const LAUNCH_HEADER = 'X-Remarc-Launch-At';
const SERVER_NOW_HEADER = 'X-Remarc-Server-Now';

/**
 * @param {string} launchAt
 * @returns {number}
 */
export function parseLaunchAt(launchAt) {
  const launchAtMs = Date.parse(launchAt);
  if (!Number.isFinite(launchAtMs)) {
    throw new Error('LAUNCH_AT must be a valid ISO-8601 timestamp');
  }
  return launchAtMs;
}

/**
 * @param {number} nowMs
 * @param {number} launchAtMs
 * @returns {'countdown' | 'launch'}
 */
export function siteStateAt(nowMs, launchAtMs) {
  return nowMs >= launchAtMs ? 'launch' : 'countdown';
}

/**
 * Preserve the asset stream and security headers while preventing an outer
 * HTML response from surviving across the launch boundary in a browser cache.
 *
 * @param {Response} response
 * @param {'countdown' | 'launch'} state
 * @param {string} launchAt
 * @param {number} serverNowMs
 * @returns {Response}
 */
function withSiteState(response, state, launchAt, serverNowMs) {
  const headers = new Headers(response.headers);
  headers.set('Cache-Control', 'no-store');
  headers.set(STATE_HEADER, state);
  headers.set(LAUNCH_HEADER, launchAt);
  headers.set(SERVER_NOW_HEADER, String(serverNowMs));
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

/**
 * @param {Request} request
 * @param {Env} env
 * @param {number} nowMs
 * @returns {Promise<Response>}
 */
export async function routeRequest(request, env, nowMs) {
  const url = new URL(request.url);
  const launchAtMs = parseLaunchAt(env.LAUNCH_AT);
  const state = siteStateAt(nowMs, launchAtMs);

  // The staged launch document is an implementation detail, never a second
  // public URL. The assets binding call below bypasses this handler, so root
  // can still read it after the cutoff.
  if (url.pathname === '/_launch' || url.pathname.startsWith('/_launch/')) {
    if (state === 'countdown') {
      return new Response('Not Found', {
        status: 404,
        headers: { 'Cache-Control': 'no-store' },
      });
    }
    const rootUrl = new URL(ROOT_PATH, request.url);
    return Response.redirect(rootUrl.toString(), 302);
  }

  if (url.pathname !== ROOT_PATH) {
    return env.ASSETS.fetch(request);
  }

  const assetUrl = new URL(request.url);
  assetUrl.pathname = state === 'launch' ? LAUNCH_ASSET_PATH : ROOT_PATH;
  assetUrl.search = '';
  const assetResponse = await env.ASSETS.fetch(new Request(assetUrl, request));
  return withSiteState(assetResponse, state, env.LAUNCH_AT, nowMs);
}

/** @type {WorkerHandler} */
const worker = {
  async fetch(request, env) {
    try {
      return await routeRequest(request, env, Date.now());
    } catch (error) {
      console.error(JSON.stringify({
        event: 'launch_router_error',
        message: error instanceof Error ? error.message : 'Unknown error',
        path: new URL(request.url).pathname,
      }));
      return new Response('Service Unavailable', {
        status: 503,
        headers: {
          'Cache-Control': 'no-store',
          'Content-Type': 'text/plain; charset=utf-8',
          'X-Content-Type-Options': 'nosniff',
        },
      });
    }
  },
};

export default worker;
