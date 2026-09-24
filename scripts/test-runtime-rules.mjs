import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';
import { build } from 'esbuild';

const injectedSource = await readFile('public/injected.js', 'utf8');
const bridgeSource = await readFile('public/content-bridge.js', 'utf8');
const backgroundSource = (await build({ entryPoints: ['src/background/index.ts'], bundle: true, write: false, platform: 'node', format: 'cjs' })).outputFiles[0].text;
const RULES = 'asap_redirect_rules_v1';
const GROUPS = 'asap_redirect_groups_v1';
const ENABLED = 'asap_redirect_enabled_v1';
const tick = () => new Promise((resolve) => setImmediate(resolve));
function event() {
  const listeners = [];
  return { addListener: (fn) => listeners.push(fn), emit: (...args) => listeners.map((fn) => fn(...args)) };
}
function config(type = 'modify_response_body') {
  return { [ENABLED]: true, [GROUPS]: [{ id: 'group', enabled: true }], [RULES]: [{
    id: 'rule', name: 'Test', enabled: true, groupId: 'group', type,
    conditions: [{ expression: '/api', matchMode: 'contains', redirectTarget: 'https://target.example/api', responseBodyMode: 'static', responseBodyValue: 'modified',
      filter: { requestHeaderFilters: [{ key: 'X-Env', operator: 'equals', value: 'stage' }] } }],
  }] };
}
function pageHarness() {
  const callbacks = [];
  const calls = [];
  class Xhr extends EventTarget {
    responseType = ''; withCredentials = false; timeout = 0; readyState = 0;
    open(method, url, ...rest) { this.method = method; this.url = url; this.openRest = rest; this.headers = {}; this.readyState = 1; }
    setRequestHeader(key, value) { this.headers[key.toLowerCase()] = value; }
    send(body) { calls.push({ url: this.url, method: this.method, headers: new Headers(this.headers), body, xhr: this }); }
    getAllResponseHeaders() { return 'x-server: original\r\n'; }
    getResponseHeader() { return 'original'; }
  }
  const changes = event();
  const pageListeners = [];
  const window = {
    location: new URL('https://app.example.com/'),
    fetch: async (input, init) => { calls.push({ url: typeof input === 'string' ? input : input.url, headers: new Headers(init?.headers ?? input?.headers), init, input }); return new Response('original', { headers: { 'x-server': 'original' } }); },
    XMLHttpRequest: Xhr,
    addEventListener: (name, fn) => { if (name === 'message') pageListeners.push(fn); },
    postMessage: (data) => { for (const fn of pageListeners) fn({ data, source: window }); },
  };
  const context = vm.createContext({ window, navigator: { language: 'en' }, URL, Headers, Request, Response, Event, ProgressEvent: Event,
    setTimeout: () => 1, clearTimeout: () => {},
    chrome: { runtime: { onMessage: event(), sendMessage: (_message, callback) => callback?.() },
      storage: { local: { get: (keys, cb) => { if (keys.includes(RULES)) callbacks.push(cb); else cb({}); } }, onChanged: changes } },
  });
  vm.runInContext(injectedSource, context);
  vm.runInContext(bridgeSource, context);
  return { window, callbacks, changes, calls, update(payload) { changes.emit({ [RULES]: {} }, 'local'); callbacks.pop()(payload); } };
}

test('injected fetch response honors headers and all three switches through the bridge', async () => {
  const page = pageHarness();
  const payload = config();
  page.callbacks.shift()(payload);
  const fetchBody = async (headers) => (await page.window.fetch('https://api.example.com/api', { headers })).text();
  assert.equal(await fetchBody(), 'original');
  assert.equal(await fetchBody({ 'x-env': 'prod' }), 'original');
  assert.equal(await fetchBody({ 'X-ENV': 'stage' }), 'modified');
  for (const disable of [
    (state) => { state[ENABLED] = false; },
    (state) => { state[GROUPS][0].enabled = false; },
    (state) => { state[RULES][0].enabled = false; },
  ]) {
    const off = structuredClone(payload); disable(off); page.update(off);
    assert.equal(await fetchBody({ 'X-Env': 'stage' }), 'original');
    page.update(payload);
    assert.equal(await fetchBody({ 'X-Env': 'stage' }), 'modified');
  }
});

test('late storage callback cannot re-enable injected rules', async () => {
  const page = pageHarness();
  const oldCallback = page.callbacks.shift();
  const disabled = config(); disabled[ENABLED] = false;
  page.update(disabled);
  oldCallback(config());
  assert.equal(await (await page.window.fetch('/api', { headers: { 'X-Env': 'stage' } })).text(), 'original');
});

function backgroundHarness(initial) {
  let stored = initial;
  let installed = [];
  let pending = 0;
  let maxPending = 0;
  let rejectNext = false;
  const changes = event();
  const messages = event();
  const module = { exports: {} };
  const chrome = {
    runtime: { getURL: (path) => `chrome-extension://test/${path}`, onStartup: event(), onInstalled: event(), onMessage: messages },
    tabs: { onUpdated: event(), onRemoved: event(), sendMessage: (_id, _message, cb) => cb() },
    storage: { local: { get: async () => structuredClone(stored) }, onChanged: changes },
    declarativeNetRequest: { updateDynamicRules: async ({ addRules = [] }) => {
      pending++; maxPending = Math.max(maxPending, pending); await tick(); pending--;
      if (rejectNext && addRules.length) { rejectNext = false; throw new Error('invalid rule'); }
      installed = addRules;
    } },
  };
  vm.runInNewContext(backgroundSource, { module, exports: module.exports, chrome, URL, console: { error() {} }, setTimeout, clearTimeout });
  return {
    get installed() { return installed; }, get maxPending() { return maxPending; },
    set rejectNext(value) { rejectNext = value; },
    update(payload) { stored = payload; changes.emit({ [RULES]: {} }, 'local'); },
    networkRules() { return new Promise((resolve) => messages.emit({ type: 'requestman:get-network-rules' }, {}, (result) => resolve(result.rules))); },
    apply(message = {}) { return new Promise((resolve) => messages.emit({ type: 'redirectRules/apply', ...message }, {}, resolve)); },
  };
}

test('background serializes storage-driven updates and ignores stale message payloads', async () => {
  const initial = config('redirect_request'); initial[RULES][0].conditions[0].filter = {};
  const background = backgroundHarness(initial);
  await background.apply();
  assert.equal(background.installed.length, 1);
  const off = structuredClone(initial); off[ENABLED] = false;
  background.update(off);
  await background.apply({ rules: initial[RULES], groups: initial[GROUPS], enabled: true });
  assert.equal(background.installed.length, 0);
  assert.equal(background.maxPending, 1);
});

test('failed atomic update removes previously installed broad rules and can recover', async () => {
  const initial = config('redirect_request'); initial[RULES][0].conditions[0].filter = {};
  const background = backgroundHarness(initial);
  await background.apply();
  assert.equal(background.installed.length, 1);
  background.rejectNext = true;
  const result = await background.apply();
  assert.equal(result.ok, false);
  assert.equal(background.installed.length, 0);
  assert.equal((await background.apply()).ok, true);
  assert.equal(background.installed.length, 1);
});

function deliverNetworkRules(page, rules) {
  page.window.postMessage({ source: 'requestman-extension', type: '__REQUESTMAN_RUNTIME_RULES__', networkRules: rules });
}

test('header-filtered redirects never become URL-only DNR rules; fetch and XHR enforce headers', async () => {
  const initial = config('redirect_request');
  const background = backgroundHarness(initial);
  const rules = await background.networkRules();
  assert.equal(background.installed.length, 0);
  assert.equal(rules.length, 1);
  const page = pageHarness();
  deliverNetworkRules(page, rules);
  await page.window.fetch('https://api.example.com/api', { headers: { 'x-env': 'prod' } });
  assert.equal(page.calls.at(-1).url, 'https://api.example.com/api');
  await page.window.fetch(new Request('https://api.example.com/api', { headers: { 'X-Env': 'stage' } }));
  assert.equal(page.calls.at(-1).url, 'https://target.example/api');
  for (const env of ['prod', 'stage']) {
    const xhr = new page.window.XMLHttpRequest();
    xhr.open('POST', 'https://api.example.com/api', true, 'user', 'password');
    xhr.setRequestHeader('X-Env', env);
    xhr.responseType = 'json'; xhr.withCredentials = true; xhr.timeout = 900;
    xhr.send('body');
    assert.equal(page.calls.at(-1).url, env === 'stage' ? 'https://target.example/api' : 'https://api.example.com/api');
    assert.equal(page.calls.at(-1).headers.get('x-env'), env);
    assert.equal(xhr.responseType, 'json');
    assert.equal(xhr.withCredentials, true);
    assert.equal(xhr.timeout, 900);
    assert.deepEqual(xhr.openRest, [true, 'user', 'password']);
  }
  for (const off of [
    { ...initial, [ENABLED]: false },
    { ...initial, [GROUPS]: [{ id: 'group', enabled: false }] },
    { ...initial, [RULES]: [{ ...initial[RULES][0], enabled: false }] },
  ]) {
    background.update(off);
    deliverNetworkRules(page, await background.networkRules());
    await page.window.fetch('https://api.example.com/api', { headers: { 'x-env': 'stage' } });
    assert.equal(page.calls.at(-1).url, 'https://api.example.com/api');
    const xhr = new page.window.XMLHttpRequest();
    xhr.open('GET', 'https://api.example.com/api'); xhr.setRequestHeader('x-env', 'stage'); xhr.send();
    assert.equal(page.calls.at(-1).url, 'https://api.example.com/api');
  }
});

test('header-filtered cancel, query, rewrite, and header actions affect only matching requests', async () => {
  for (const type of ['cancel_request', 'query_params', 'rewrite_string', 'modify_headers']) {
    const initial = config(type);
    Object.assign(initial[RULES][0].conditions[0], {
      queryParamModifications: [{ action: 'add', key: 'debug', value: '1' }],
      rewriteFrom: '/api', rewriteTo: '/mock',
      requestHeaderModifications: [{ action: 'update', key: 'X-Added', value: 'yes' }],
      responseHeaderModifications: [{ action: 'update', key: 'X-Server', value: 'modified' }],
    });
    const background = backgroundHarness(initial);
    const page = pageHarness();
    deliverNetworkRules(page, await background.networkRules());
    const original = await page.window.fetch('https://api.example.com/api', { headers: { 'x-env': 'prod' } });
    assert.equal(page.calls.at(-1).url, 'https://api.example.com/api');
    assert.equal(original.headers.get('x-server'), 'original');
    const result = page.window.fetch('https://api.example.com/api', { headers: { 'x-env': 'stage' } });
    if (type === 'cancel_request') {
      await assert.rejects(result, /Failed to fetch/);
      assert.equal(page.calls.length, 1);
    } else {
      const response = await result;
      if (type === 'query_params') assert.equal(page.calls.at(-1).url, 'https://api.example.com/api?debug=1');
      if (type === 'rewrite_string') assert.equal(page.calls.at(-1).url, 'https://api.example.com/mock');
      if (type === 'modify_headers') {
        assert.equal(page.calls.at(-1).headers.get('x-added'), 'yes');
        assert.equal(response.headers.get('x-server'), 'modified');
        assert.equal(response.clone().headers.get('x-server'), 'modified');
        assert.equal(await response.text(), 'original');
      }
    }
  }
});

test('all request headers must match, including legacy conditions', async () => {
  const initial = config('redirect_request');
  initial[RULES][0].conditions[0].filter.requestHeaderFilters.push(
    { key: 'Content-Type', operator: 'contains', value: 'json' },
    { key: 'X-Mode', operator: 'not_equals', value: 'live' },
  );
  const background = backgroundHarness(initial);
  const page = pageHarness();
  deliverNetworkRules(page, await background.networkRules());
  for (const [headers, expected] of [
    [{ 'x-env': 'stage' }, false],
    [{ 'x-env': 'stage', 'Content-Type': 'application/json', 'X-Mode': 'live' }, false],
    [{ 'x-env': 'stage', 'Content-Type': 'application/json', 'X-Mode': 'test' }, true],
  ]) {
    await page.window.fetch('https://api.example.com/api', { headers });
    assert.equal(page.calls.at(-1).url === 'https://target.example/api', expected);
  }
  initial[RULES][0].conditions[0].filter = { requestHeaderKey: 'X-Env', requestHeaderValue: 'stage' };
  background.update(initial);
  deliverNetworkRules(page, await background.networkRules());
  await page.window.fetch('https://api.example.com/api');
  assert.equal(page.calls.at(-1).url, 'https://api.example.com/api');
  await page.window.fetch('https://api.example.com/api', { headers: { 'x-env': 'stage' } });
  assert.equal(page.calls.at(-1).url, 'https://target.example/api');
});

test('redirect preserves Request body and options, and accepts URL objects', async () => {
  const background = backgroundHarness(config('redirect_request'));
  const page = pageHarness();
  deliverNetworkRules(page, await background.networkRules());
  await page.window.fetch(new Request('https://api.example.com/api', {
    method: 'POST', body: 'payload', credentials: 'include', headers: { 'X-Env': 'stage' },
  }));
  assert.equal(page.calls.at(-1).input.method, 'POST');
  assert.equal(page.calls.at(-1).input.credentials, 'include');
  assert.equal(await page.calls.at(-1).input.text(), 'payload');
  await page.window.fetch(new URL('https://api.example.com/api'), { headers: { 'X-Env': 'stage' } });
  assert.equal(page.calls.at(-1).url, 'https://target.example/api');
});

test('unsupported header-filtered User-Agent cannot install a broad native rule', async () => {
  const initial = config('user_agent');
  Object.assign(initial[RULES][0].conditions[0], { userAgentType: 'custom', userAgentCustomValue: 'test-agent' });
  const background = backgroundHarness(initial);
  const result = await background.apply();
  assert.equal(result.ok, false);
  assert.match(result.error, /User-Agent/);
  assert.equal(background.installed.length, 0);
  assert.equal((await background.networkRules()).length, 0);
});
