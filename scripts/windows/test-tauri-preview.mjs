import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const fixture = readFileSync(new URL('../../apps/windows/src-tauri/src/preview.js', import.meta.url), 'utf8');

function createPreview() {
  const forwarded = [];
  const window = { fetch: async input => { forwarded.push(input); return Response.json({}); } };
  const location = new URL('http://tauri.localhost/');
  vm.runInNewContext(fixture, {
    window, location, URL, Request, Response,
    localStorage: { setItem() {} }, document: { addEventListener() {} },
  });
  return { fetch: window.fetch, forwarded };
}

test('offline preview handles helper actions in memory and blocks unknown destinations', async () => {
  const { fetch, forwarded } = createPreview();
  const base = 'http://127.0.0.1:13335/api/v1';
  await fetch(base + '/proxy/stop', { method: 'POST' });
  assert.equal((await (await fetch(base + '/status')).json()).proxy.running, false);
  await fetch(base + '/proxy/start', { method: 'POST' });
  assert.equal((await (await fetch(base + '/status')).json()).proxy.running, true);
  for (const url of [base + '/update/download', 'http://127.0.0.1:49152/api/v1/status', 'https://example.org/']) {
    assert.equal((await fetch(url)).status, 503);
  }
  assert.deepEqual(forwarded, []);
  await fetch('http://tauri.localhost/styles.css');
  assert.deepEqual(forwarded, ['http://tauri.localhost/styles.css']);
});

test('node list, traffic and delay share the controller advertised by the helper', async () => {
  const { fetch, forwarded } = createPreview();
  const base = 'http://127.0.0.1:13335/api/v1';
  const started = await (await fetch(base + '/proxy/start', {method:'POST'})).json();
  const status = await (await fetch(base + '/status')).json();
  assert.ok(started.pid > 0);
  assert.equal(started.pid, status.proxy.pid);
  assert.equal(started.controllerPort, status.controllerPort);
  assert.notEqual(status.controllerPort, 9090);
  const controller = 'http://127.0.0.1:' + status.controllerPort;
  const {proxies} = await (await fetch(controller + '/proxies')).json();
  const node = proxies['♻️ 自动选择'].now;
  const measured = await (await fetch(controller + '/proxies/' + encodeURIComponent(node) + '/delay')).json();
  assert.ok(measured.delay > 0);
  const totals = await (await fetch(controller + '/connections')).json();
  assert.ok(totals.uploadTotal > 0 && totals.downloadTotal > 0);
  assert.equal((await fetch('http://127.0.0.1:9090/proxies')).status, 503);
  assert.deepEqual(forwarded, []);
});
