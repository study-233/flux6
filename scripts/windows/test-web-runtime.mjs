import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';

const source = readFileSync(new URL('../../apps/windows/web/app.js', import.meta.url), 'utf8');

// Load the production script without firing DOMContentLoaded. All transport
// and rendering are fixtures; these checks never contact a running helper.
function frontend(invoke, fetch) {
  const context = vm.createContext({
    window: invoke ? { __TAURI_INTERNALS__: { invoke } } : {},
    document: { addEventListener() {} },
    localStorage: { getItem() { return null; } },
    fetch,
  });
  vm.runInContext(source, context);
  return context;
}

test('requests use the shell port and bearer token', async () => {
  const calls = [];
  const context = frontend(
    async name => name === 'get_helper_port' ? 23456 : 'launch-token',
    async (url, options) => {
      calls.push({ url, options });
      return { ok: true, status: 200, json: async () => ({ ready: true }) };
    },
  );
  assert.equal((await context.api('/status')).ready, true);
  assert.equal(calls[0].url, 'http://127.0.0.1:23456/api/v1/status');
  assert.equal(calls[0].options.headers.Authorization, 'Bearer launch-token');
});

test('browser previews and older shells retain the default port', async () => {
  for (const invoke of [undefined, async () => { throw new Error('unknown command'); }, async () => 0]) {
    const context = frontend(invoke, async url => {
      assert.equal(url, 'http://127.0.0.1:13335/api/v1/status');
      return { ok: true, status: 200, json: async () => ({}) };
    });
    await context.api('/status');
  }
});

test('a refreshed bearer retries once on the same dynamic port', async () => {
  let tokens = 0;
  const auth = [];
  const context = frontend(
    async name => name === 'get_helper_port' ? 23456 : `token-${++tokens}`,
    async (url, options) => {
      assert.equal(url, 'http://127.0.0.1:23456/api/v1/status');
      auth.push(options.headers.Authorization);
      return { ok: auth.length === 2, status: auth.length === 2 ? 200 : 401, json: async () => ({}) };
    },
  );
  await context.api('/status');
  assert.deepEqual(auth, ['Bearer token-1', 'Bearer token-2']);
});

test('a status response started before stop cannot restore running state', async () => {
  const context = frontend();
  const state = vm.runInContext('state', context);
  Object.assign(state, { helperOnline: true, proxyRunning: true, runtimePresent: true, runtimeChecked: true });
  let reply;
  context.api = async path => {
    if (path === '/status') return new Promise(resolve => { reply = resolve; });
    if (path === '/runtime') return { present: true };
    assert.equal(path, '/proxy/stop');
    return {};
  };
  const transitions = [];
  context.setRunning = running => { transitions.push(running); state.proxyRunning = running; };
  for (const name of ['addLog', 'setMode', 'maybeArmAutoRun', 'updateSettingsUI', 'autoDelayTestAfterStart']) context[name] = () => {};
  const pending = context.pollStatus();
  await context.stopProxyApi();
  state.proxyRunning = false;
  reply({ proxy: { running: true }, settings: {} });
  await pending;
  assert.equal(state.proxyRunning, false);
  assert.deepEqual(transitions, []);

  // A later status response still synchronizes genuine backend changes.
  context.api = async path => path === '/runtime' ? { present: true } : { proxy: { running: true }, settings: {} };
  await context.pollStatus();
  assert.equal(state.proxyRunning, true);
  assert.deepEqual(transitions, [true]);
});
