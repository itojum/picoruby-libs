import { expect, test } from '@playwright/test';
import { CDN, PICORUBY_WASM, PICORUBY_WASM_VERSION, SITE, serve } from './server.mjs';

// Opens `path` and collects what PicoRuby prints. Ruby's `puts` goes to
// console.log; the fixtures prefix the lines the tests look at with "E2E ".
// `setup` runs after the fixtures are routed and before the page loads.
async function open(page, path, setup = async () => {}) {
  const logs = [];
  const errors = [];
  const requests = [];
  page.on('console', (msg) => {
    if (msg.type() === 'error') errors.push(msg.text());
    else if (msg.text().startsWith('E2E ')) logs.push(msg.text().slice(4));
  });
  page.on('pageerror', (err) => errors.push(err.message));
  page.on('request', (req) => requests.push(req.url()));
  await serve(page);
  await setup();
  await page.goto(SITE + path);
  return { logs, errors, requests };
}

// Waits until PicoRuby has printed every line of `expected`.
async function waitForLogs(run, expected) {
  try {
    await expect
      .poll(() => expected.filter((line) => !run.logs.includes(line)), { timeout: 30_000 })
      .toEqual([]);
  } catch (err) {
    // Built after the wait, so it shows what arrived while polling.
    err.message += `\nPicoRuby printed ${JSON.stringify(run.logs)}; errors: ${JSON.stringify(run.errors)}`;
    throw err;
  }
}

test.beforeAll(() => {
  console.log(`PicoRuby.wasm ${PICORUBY_WASM_VERSION} from ${PICORUBY_WASM}`);
});

test('requires npm libraries through the import map, with their dependencies and require_relative', async ({ page }) => {
  const run = await open(page, '/npm.html');
  await waitForLogs(run, [
    'greet: HELLO, PICORUBY! (greeter 1.0.0)',
    'await: after a Promise',
    'done',
  ]);
  await expect(page.locator('#out')).toHaveText('HELLO, PICORUBY! (greeter 1.0.0)');
  expect(run.errors).toEqual([]);

  // Each library resolved once from its package.json, then every file from
  // that exact version; nothing went to the real npm.
  const fromCdn = run.requests.filter((url) => url.startsWith(CDN)).map((url) => url.slice(CDN.length));
  expect(fromCdn.sort()).toEqual([
    'greeter@1.0.0/lib/greeter.rb',
    'greeter@1.0.0/lib/greeter/version.rb',
    'greeter@1.0.0/package.json',
    'shout@2.0.0/package.json',
    'shout@2.0.0/shout.rb',
  ]);
  const npm = run.requests.filter(
    (url) => url.startsWith('https://cdn.jsdelivr.net/npm/') && !url.startsWith(PICORUBY_WASM),
  );
  expect(npm).toEqual([]);
});

test('expands require_relative against the src of a script and maps a name to a URL', async ({ page }) => {
  const run = await open(page, '/relative.html');
  await waitForLogs(run, ['relative: 42', 'local: vendor/local.rb', 'done']);
  expect(run.errors).toEqual([]);
  // Resolved against the script's src (app/game.rb), not the page.
  expect(run.requests).toContain(`${SITE}/app/lib/helper.rb`);
  expect(run.requests).not.toContain(`${SITE}/lib/helper.rb`);
  expect(run.requests).toContain(`${SITE}/vendor/local.rb`);
});

test('leaves built-in libraries to PicoRuby and starts every script', async ({ page }) => {
  const run = await open(page, '/builtins.html');
  await waitForLogs(run, ['json: {"ok":true}', 'js: /builtins.html', 'second script']);
  expect(run.errors).toEqual([]);
  // js and json are in BUILTINS, so they are not looked up anywhere.
  expect(run.requests.filter((url) => /\/(js|json)(@|\/package\.json)/.test(url))).toEqual([]);
});

test('skips and reports scripts that cannot be fetched or compiled, and starts the others', async ({ page }) => {
  const run = await open(page, '/failures.html');
  await waitForLogs(run, ['healthy script']);
  await expect.poll(() => page.evaluate(() => window.e2eEvents.length), { timeout: 30_000 }).toBe(3);
  const events = await page.evaluate(() => window.e2eEvents);
  expect(events.map((e) => e[0])).toEqual(['error', 'error', 'ready']);
  expect(events[0][1]).toContain('script #1 (missing.rb) was not started: failed to load');
  expect(events[1][1]).toContain('script #2 (inline-2.rb) was not started: PicoRuby could not compile');
  // Each failure also goes to console.error.
  expect(run.errors.filter((text) => text.startsWith('picoruby-libs: '))).toEqual(events.slice(0, 2).map((e) => e[1]));
});

// Holds back the responses for `paths` until all of them have been requested,
// so the page only gets them if it fetches them at the same time, and then
// answers them in reverse order. Gives up after a few seconds so a sequential
// loader fails the test instead of hanging.
async function requireTogether(page, paths) {
  const requested = new Set();
  const answered = [];
  let together = false;
  let gaveUp = false;
  let release;
  const allRequested = new Promise((resolve) => {
    release = resolve;
  });
  await page.route(
    (url) => paths.includes(url.pathname),
    async (route) => {
      const path = new URL(route.request().url()).pathname;
      requested.add(path);
      if (requested.size === paths.length) {
        // Together only if no response had to be let go before this one.
        together = !gaveUp;
        release();
      }
      await Promise.race([allRequested, new Promise((resolve) => setTimeout(resolve, 3_000))]);
      if (requested.size < paths.length) gaveUp = true;
      // The last path is answered first, the first one last.
      await new Promise((resolve) => setTimeout(resolve, 300 * paths.indexOf(path)));
      answered.push(path);
      return route.fallback();
    },
  );
  return { together: () => together, answered };
}

test('fetches the src of every script, and the requires of a file, in parallel, keeping document order', async ({ page }) => {
  let srcs;
  let libs;
  const run = await open(page, '/parallel.html', async () => {
    // Reversed, so the second script and the second require arrive first.
    srcs = await requireTogether(page, ['/parallel/two.rb', '/parallel/one.rb']);
    libs = await requireTogether(page, ['/parallel/lib/b.rb', '/parallel/lib/a.rb']);
  });
  await waitForLogs(run, ['one: a,b', 'two']);
  expect(srcs.together()).toBe(true);
  expect(libs.together()).toBe(true);
  expect(srcs.answered).toEqual(['/parallel/two.rb', '/parallel/one.rb']);
  expect(libs.answered).toEqual(['/parallel/lib/b.rb', '/parallel/lib/a.rb']);
  // Inlined and started in document order all the same: a before b, and
  // the first script's task before the second's.
  expect(run.logs).toEqual(['one: a,b', 'two']);
  expect(run.errors).toEqual([]);
});
