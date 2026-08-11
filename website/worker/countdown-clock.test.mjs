import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const LAUNCH_AT = '2026-08-11T07:00:00Z';
const LAUNCH_AT_MS = Date.parse(LAUNCH_AT);
const html = readFileSync(new URL('../public/index.html', import.meta.url), 'utf8');
const scriptStart = html.indexOf('/* Launch countdown:');
const scriptEnd = html.indexOf('/* Bell-to-email', scriptStart);
const countdownScript = html.slice(scriptStart, scriptEnd);

function createTextElement() {
  return {
    hidden: false,
    textContent: '',
    animate() {},
    getAnimations() { return []; },
  };
}

function createHarness({ clientNow, serverNow, state }) {
  let nextTimerId = 1;
  const timeouts = new Map();
  const intervals = new Map();
  const replacements = [];
  const units = new Map();
  const prefix = createTextElement();
  const time = createTextElement();
  const fallback = createTextElement();

  for (const name of ['days', 'hours', 'minutes', 'seconds']) {
    const current = createTextElement();
    const previous = createTextElement();
    units.set(name, {
      querySelector(selector) {
        return selector === '.countdown-current' ? current : previous;
      },
    });
  }

  const live = {
    hidden: true,
    querySelector(selector) {
      const match = selector.match(/^\[data-unit="([^"]+)"\]$/);
      if (match) return units.get(match[1]);
      if (selector === '.countdown-prefix') return prefix;
      if (selector === '.countdown-time') return time;
      throw new Error(`Unexpected live selector: ${selector}`);
    },
    querySelectorAll() { return []; },
  };

  const attributes = new Map();
  const classNames = new Set();
  const countdown = {
    querySelector(selector) {
      if (selector === '.countdown-fallback') return fallback;
      throw new Error(`Unexpected countdown selector: ${selector}`);
    },
    setAttribute(name, value) { attributes.set(name, value); },
    dispatchEvent() {},
    classList: {
      add(name) { classNames.add(name); },
      remove(name) { classNames.delete(name); },
    },
  };

  class FakeDate extends Date {
    static now() { return clientNow; }
  }

  const context = {
    Date: FakeDate,
    Event: class Event {
      constructor(type) { this.type = type; }
    },
    console,
    document: {
      hidden: false,
      getElementById(id) {
        if (id === 'launch-countdown') return countdown;
        if (id === 'countdown-live') return live;
        return null;
      },
      addEventListener() {},
    },
    window: {
      matchMedia() { return { matches: false, addEventListener() {} }; },
      addEventListener() {},
      location: { replace(path) { replacements.push(path); } },
    },
    fetch() {
      return Promise.resolve({
        headers: {
          get(name) {
            const values = {
              'date': new Date(serverNow).toUTCString(),
              'x-remarc-launch-at': LAUNCH_AT,
              'x-remarc-server-now': String(serverNow),
              'x-remarc-site-state': state,
            };
            return values[name] ?? null;
          },
        },
      });
    },
    setTimeout(callback, delay) {
      const id = nextTimerId++;
      timeouts.set(id, { callback, delay });
      return id;
    },
    clearTimeout(id) { timeouts.delete(id); },
    setInterval(callback, delay) {
      const id = nextTimerId++;
      intervals.set(id, { callback, delay });
      return id;
    },
    clearInterval(id) { intervals.delete(id); },
  };

  vm.runInNewContext(countdownScript, context);

  return {
    attributes,
    classNames,
    live,
    prefix,
    replacements,
    time,
    timeouts,
    async runImmediateProbe() {
      const entry = [...timeouts.entries()].find(([, timer]) => timer.delay === 0);
      assert.ok(entry, 'expected an immediate authoritative launch-state probe');
      timeouts.delete(entry[0]);
      entry[1].callback();
      await new Promise((resolve) => setImmediate(resolve));
    },
  };
}

test('a fast visitor clock is corrected by the Worker before launch', async () => {
  const serverNow = LAUNCH_AT_MS - 60_000;
  const harness = createHarness({
    clientNow: serverNow + 60 * 60 * 1000,
    serverNow,
    state: 'countdown',
  });

  await harness.runImmediateProbe();

  assert.deepEqual(harness.replacements, []);
  assert.equal(harness.prefix.textContent, 'Launching in');
  assert.equal(harness.time.hidden, false);
  assert.equal(harness.classNames.has('is-live'), false);
  assert.match(harness.attributes.get('aria-label'), /^Launching in /);
  assert.ok(
    [...harness.timeouts.values()].some(({ delay }) => delay === 60_000),
    'expected the exact server-derived cutover timeout',
  );
});

test('a slow visitor clock follows the Worker launch state immediately', async () => {
  const serverNow = LAUNCH_AT_MS + 1;
  const harness = createHarness({
    clientNow: serverNow - 60 * 60 * 1000,
    serverNow,
    state: 'launch',
  });

  await harness.runImmediateProbe();

  assert.deepEqual(harness.replacements, ['/']);
});

test('a non-launch response at zero retries with a bounded delay', async () => {
  const serverNow = LAUNCH_AT_MS + 1;
  const harness = createHarness({
    clientNow: serverNow,
    serverNow,
    state: 'countdown',
  });

  await harness.runImmediateProbe();

  assert.deepEqual(harness.replacements, []);
  assert.equal(
    [...harness.timeouts.values()].filter(({ delay }) => delay === 0).length,
    0,
  );
  assert.equal(
    [...harness.timeouts.values()].filter(({ delay }) => delay === 1000).length,
    1,
  );
});
