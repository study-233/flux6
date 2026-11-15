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
    AbortController,
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

test('controller requests follow the current session and reject unverified ports', async () => {
  const calls = [];
  const context = frontend(undefined, (url, options) => { calls.push([url, options.headers.Authorization]); });
  context.syncController({controllerPort: 49190, controllerSecret: 'fixture'}, true);
  await context.controllerGet('/connections');
  context.syncController({controllerPort: 0, controllerSecret: 'must-not-send'}, true);
  assert.throws(() => context.controllerGet('/proxies'));
  context.syncController({controllerSecret:'legacy'}, true);
  await context.controllerGet('/proxies');
  context.syncController({controllerPort: 49190}, false);
  assert.throws(() => context.controllerGet('/connections'));
  assert.deepEqual(calls, [
    ['http://127.0.0.1:49190/connections', 'Bearer fixture'],
    ['http://127.0.0.1:9090/proxies', 'Bearer legacy'],
  ]);
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

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

test('each node ranking keeps unmeasured nodes last and preserves the chosen node', () => {
  const context = frontend();
  const grid = { contains: () => false, querySelectorAll: () => [] };
  const sort = { value: 'download' };
  context.document.querySelector = selector => ({ '#nodeGrid': grid, '#nodeSort': sort })[selector];
  vm.runInContext(`
    state.proxyGroup = { now: 'Node 10', all: ['Node 10', 'Node 2', 'Node 1', 'Node 20'] };
    state.delaysReady = true;
    state.proxyDelays = { 'Node 2': 90, 'Node 10': 20, 'Node 20': 5000 };
    downloadResults.set(activeProxyGroupKey(), new Map([
      ['Node 10', { bytesPerSecond: 2000000 }],
      ['Node 2', { bytesPerSecond: 7000000 }],
      ['Node 20', { error: 'offline' }],
    ]));
  `, context);
  for (const [value, expected] of [
    ['download', ['Node 2', 'Node 10', 'Node 1', 'Node 20']],
    ['delay', ['Node 10', 'Node 2', 'Node 1', 'Node 20']],
    ['name', ['Node 1', 'Node 2', 'Node 10', 'Node 20']],
  ]) {
    sort.value = value;
    context.renderNodeGrid();
    assert.deepEqual([...grid.innerHTML.matchAll(/data-name="([^"]+)"/g)].map(match => match[1]), expected);
    assert.match(grid.innerHTML, /aria-label="Node 10" aria-pressed="true"/);
    assert.match(grid.innerHTML, /aria-label="Node 2 · 重新测速"/);
    assert.match(grid.innerHTML, /aria-label="Node 20 · 重新测速"/);
  }
});

test('download queue serializes real names and preserves results after one failure', async () => {
  const context = frontend();
  vm.runInContext("downloadSession='run'; state.proxyRunning=true", context);
  context.renderNodeGrid = () => {};
  const calls = [], pending = deferred();
  context.api = async (path, options) => {
    assert.equal(path, '/nodes/download');
    const { session, group, node } = JSON.parse(options.body);
    assert.equal(session, 'run');
    assert.equal(group, '♻️ 自动选择');
    calls.push(node);
    if (node === 'A') return pending.promise;
    if (node === 'B') throw Error('unavailable');
    return { bytesPerSecond: 8000000 };
  };
  const task = context.measureNodes(['A', 'B', '节点 / C']);
  await context.measureNodes(['must not run']);
  assert.deepEqual(calls, ['A']);
  pending.resolve({ bytesPerSecond: 1200000 });
  await task;
  assert.deepEqual(calls, ['A', 'B', '节点 / C']);
  const results = vm.runInContext('downloadResults.get(AUTO_SELECT_GROUP)', context);
  assert.equal(results.get('A').bytesPerSecond, 1200000);
  assert.equal(results.get('B').error, 'unavailable');
  assert.equal(results.get('节点 / C').bytesPerSecond, 8000000);
});

test('four-stream samples remain separate from single-stream results and rankings', async () => {
  const context = frontend();
  const grid = { contains: () => false, querySelectorAll: () => [] };
  context.document.querySelector = selector => ({ '#nodeGrid': grid, '#nodeSort': {value:'download'} })[selector];
  vm.runInContext(`downloadSession='run'; state.proxyRunning=true; manualStreams=4;
    state.proxyGroup={now:'A',all:['A','B']};
    nodeQuality={profile:'dorm',quality:{samples:[{node:'B',kind:'download',rate:99000000,connections:1,at:'2026-01-01'}]}};
  `, context);
  context.fetchProxies = () => {};
  context.api = async (_,options) => {
    assert.equal(JSON.parse(options.body).connections,4);
    return {bytesPerSecond:15000000,connections:4,measuredAt:'2026-01-02'};
  };
  await context.measureNodes(['A']);
  assert.match(grid.innerHTML,/15\.00/);
  assert.doesNotMatch(grid.innerHTML,/99\.00/);
  vm.runInContext("manualStreams=1;renderNodeGrid()", context);
  assert.match(grid.innerHTML,/99\.00/);
  assert.doesNotMatch(grid.innerHTML,/15\.00/);
});

test('delay uses median of successful probes and reports timeouts separately', async () => {
  const context=frontend();
  vm.runInContext("state.proxyRunning=true;state.proxyGroup={all:['A','B']};nodeQuality={profile:'dorm'}", context);
  context.renderNodeGrid=context.fetchProxies=context.addLog=()=>{};
  const timings={A:[70,98,10],B:[32,0,20]};
  context.controllerGet=async path=>{
    const node=path.split('/')[2];
    return {ok:true,json:async()=>({delay:timings[node].shift()})};
  };
  let posted;
  context.api=async (_,opts)=>{posted=JSON.parse(opts.body)};
  await context.runDelayTest();
  assert.deepEqual(posted.delays,{A:70,B:26});
  assert.deepEqual(posted.timeouts,{A:0,B:1});
  assert.equal(posted.attempts,3);
});

test('access pool shows real candidates and forwards the live size separately from test streams', async () => {
  const context = frontend();
  const names = Array.from({length:28}, (_,i) => 'Node ' + i);
  let size = 4;
  const group = '♻️ 自动选择';
  const quality = () => ({profile:'dorm',quality:{samples:[]},poolSize:size,candidates:names,activeNodes:names.slice(0,size)});
  context.controllerGet = async () => ({ok:true,json:async () => ({proxies:{[group]:{now:'hidden',all:['hidden',...names]}}})});
  context.loadNodeQuality = async () => quality();
  context.renderNodeGrid = context.addLog = () => {};
  vm.runInContext("downloadSession='run';state.helperOnline=true;state.proxyRunning=true", context);
  await context.fetchProxies();
  assert.deepEqual([...vm.runInContext('state.proxyGroup.all',context)],names);
  context.api = async (path,opts) => {
    assert.equal(path,'/nodes/quality');
    const write = JSON.parse(opts.body);
    assert.equal(write.mode,'auto');
    assert.equal(write.session,'run');
    size = write.poolSize;
    return quality();
  };
  await context.switchProxy('',8);
  assert.equal(vm.runInContext('nodeQuality.activeNodes.length',context),8);
  assert.equal(vm.runInContext('manualStreams',context),1);
});

for (const action of ['cancel', 'reconnect']) {
  test(`download queue discards a late result on ${action}`, async () => {
    const context = frontend();
    context.clearProxyList = context.renderNodeGrid = () => {};
    vm.runInContext("downloadSession='run'; state.proxyRunning=true", context);
    const pending = deferred(), calls = [];
    let signal;
    context.api = async (_, options) => {
      signal = options.signal;
      calls.push(JSON.parse(options.body).node);
      return pending.promise;
    };
    const task = context.measureNodes(['A', 'B']);
    if (action === 'cancel') context.cancelDownloadQueue();
    else context.changeDownloadSession('second');
    assert.equal(signal.aborted, true);
    pending.resolve({ bytesPerSecond: 12 });
    await task;
    assert.deepEqual(calls, ['A']);
    assert.equal(vm.runInContext('downloadResults.get(AUTO_SELECT_GROUP)?.size || 0', context), 0);
  });
}

for (const observer of ['pollStatus', 'refreshBackendState']) {
  for (const operation of ['start', 'stop']) {
    test(`${observer} discards a status read during ${operation}`, async () => {
      const context = frontend();
      const state = vm.runInContext('state', context);
      const starting = operation === 'start';
      Object.assign(state, { helperOnline: true, proxyRunning: !starting, runtimePresent: true, runtimeChecked: true, devMode: true });
      const sent = deferred();
      const command = deferred();
      const stale = deferred();
      context.api = async (path, options) => {
        if (path === '/status') return stale.promise;
        if (path === '/runtime') return { present: true };
        assert.equal(path, '/proxy/' + operation);
        if (starting) {
          assert.equal(JSON.parse(options.body).dynamicControllerPort, true);
          assert.equal(JSON.parse(options.body).adaptiveAccessPool, true);
        }
        sent.resolve();
        return command.promise;
      };
      const renders = [];
      context.setRunning = running => { renders.push(running); state.proxyRunning = running; };
      for (const name of ['addLog', 'fabPhase', 'autoDelayTestAfterStart', 'setMode', 'ensureNoticeChecked',
        'maybeAutoRegisterWarp', 'maybeArmAutoRun', 'refreshChainStatus', 'refreshCloudStatus', 'updateSettingsUI']) {
        context[name] = () => {};
      }
      const action = starting ? context.startProxyFlow() : context.stopProxyApi();
      await sent.promise;
      const pending = context[observer]();
      command.resolve({ controllerPort: 49191, controllerSecret: 'new-session' });
      const result = await action;
      if (starting) assert.equal(result.ok, true);
      else context.setRunning(false);
      stale.resolve({ proxy: { running: !starting }, settings: {}, controllerPort: 9090, controllerSecret: 'stale' });
      await pending;
      assert.equal(state.proxyRunning, starting);
      if (starting) {
        assert.equal(state.controllerSecret, 'new-session');
        assert.equal(state.controllerPort, 49191);
      }
      assert.deepEqual(renders, [starting]);
    });
  }
}
