import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import worker, { parseLaunchAt, routeRequest, siteStateAt } from './launch-router.mjs';

const LAUNCH_AT = '2026-08-11T07:00:00Z';
const LAUNCH_AT_MS = Date.parse(LAUNCH_AT);

function makeEnv() {
  const paths = [];
  return {
    paths,
    env: {
      LAUNCH_AT,
      ASSETS: {
        async fetch(request) {
          const url = new URL(request.url);
          paths.push({ method: request.method, pathname: url.pathname, search: url.search });
          return new Response(`asset:${url.pathname}`, {
            status: 200,
            headers: {
              'Content-Type': 'text/html; charset=utf-8',
              'X-Frame-Options': 'DENY',
            },
          });
        },
      },
    },
  };
}

test('parses the launch instant and rejects invalid configuration', () => {
  assert.equal(parseLaunchAt(LAUNCH_AT), LAUNCH_AT_MS);
  assert.throws(() => parseLaunchAt('Tuesday morning'), /valid ISO-8601/);
});

test('keeps the Worker deadline aligned with the visible countdown', () => {
  const config = JSON.parse(readFileSync(new URL('../wrangler.jsonc', import.meta.url), 'utf8'));
  const countdown = readFileSync(new URL('../public/index.html', import.meta.url), 'utf8');
  assert.equal(config.vars.LAUNCH_AT, LAUNCH_AT);
  assert.match(
    countdown,
    /<time datetime="2026-08-11T03:00:00-04:00">Tuesday at 3 AM ET<\/time>/,
  );
  assert.match(
    countdown,
    /datetime="2026-08-11T03:00:00-04:00">Launching Tuesday, August 11, 2026 at 3 AM Eastern Time<\/time>/,
  );
  assert.match(countdown, /new Date\('2026-08-11T03:00:00-04:00'\)/);
  assert.doesNotMatch(countdown, /2026-08-11T10:00:00-04:00|10 AM ET|10 AM Eastern Time/);
  assert.equal(Date.parse(config.vars.LAUNCH_AT), Date.parse('2026-08-11T03:00:00-04:00'));
});

test('selects launch at the exact deadline', () => {
  assert.equal(siteStateAt(LAUNCH_AT_MS - 1, LAUNCH_AT_MS), 'countdown');
  assert.equal(siteStateAt(LAUNCH_AT_MS, LAUNCH_AT_MS), 'launch');
  assert.equal(siteStateAt(LAUNCH_AT_MS + 1, LAUNCH_AT_MS), 'launch');
});

test('serves the countdown at root before launch with authoritative headers', async () => {
  const { env, paths } = makeEnv();
  const response = await routeRequest(
    new Request('https://remarc.app/?cache-bust=1'),
    env,
    LAUNCH_AT_MS - 1,
  );

  assert.deepEqual(paths, [{ method: 'GET', pathname: '/', search: '' }]);
  assert.equal(await response.text(), 'asset:/');
  assert.equal(response.headers.get('X-Remarc-Site-State'), 'countdown');
  assert.equal(response.headers.get('X-Remarc-Launch-At'), LAUNCH_AT);
  assert.equal(response.headers.get('X-Remarc-Server-Now'), String(LAUNCH_AT_MS - 1));
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.equal(response.headers.get('X-Frame-Options'), 'DENY');
});

test('serves the staged launch document at root at and after the deadline', async () => {
  for (const nowMs of [LAUNCH_AT_MS, LAUNCH_AT_MS + 1]) {
    const { env, paths } = makeEnv();
    const response = await routeRequest(new Request('https://remarc.app/'), env, nowMs);

    assert.deepEqual(paths, [{ method: 'GET', pathname: '/_launch/', search: '' }]);
    assert.equal(await response.text(), 'asset:/_launch/');
    assert.equal(response.headers.get('X-Remarc-Site-State'), 'launch');
    assert.equal(response.headers.get('Cache-Control'), 'no-store');
  }
});

test('preserves HEAD and hides the staged launch route before launch', async () => {
  const { env, paths } = makeEnv();
  const headResponse = await routeRequest(
    new Request('https://remarc.app/', { method: 'HEAD' }),
    env,
    LAUNCH_AT_MS - 1000,
  );
  assert.deepEqual(paths, [{ method: 'HEAD', pathname: '/', search: '' }]);
  assert.equal(headResponse.headers.get('X-Remarc-Site-State'), 'countdown');

  const hiddenResponse = await routeRequest(
    new Request('https://remarc.app/_launch/'),
    env,
    LAUNCH_AT_MS - 1,
  );
  assert.equal(hiddenResponse.status, 404);
  assert.equal(paths.length, 1);
});

test('redirects the staged route to canonical root after launch', async () => {
  const { env, paths } = makeEnv();
  const response = await routeRequest(
    new Request('https://remarc.app/_launch/index.html'),
    env,
    LAUNCH_AT_MS,
  );
  assert.equal(response.status, 302);
  assert.equal(response.headers.get('Location'), 'https://remarc.app/');
  assert.equal(paths.length, 0);
});

test('delegates non-root requests to static assets unchanged', async () => {
  const { env, paths } = makeEnv();
  const response = await routeRequest(
    new Request('https://remarc.app/favicon.png?version=1'),
    env,
    LAUNCH_AT_MS - 1,
  );
  assert.equal(await response.text(), 'asset:/favicon.png');
  assert.deepEqual(paths, [{ method: 'GET', pathname: '/favicon.png', search: '?version=1' }]);
});

test('returns an explicit non-cacheable error for invalid runtime configuration', async () => {
  const response = await worker.fetch(
    new Request('https://remarc.app/'),
    { LAUNCH_AT: 'invalid', ASSETS: { fetch: async () => new Response('unused') } },
  );
  assert.equal(response.status, 503);
  assert.equal(response.headers.get('Cache-Control'), 'no-store');
  assert.equal(await response.text(), 'Service Unavailable');
});
