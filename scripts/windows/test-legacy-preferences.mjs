import assert from 'node:assert/strict';
import test from 'node:test';
import { exportPreferences, preferenceKeys } from './export-legacy-preferences.mjs';

test('exports only the allowlist, including traffic and wallpaper', () => {
  const data = new Map([['freev6-theme', 'dark'], ['freev6-traffic-stats', '{"total":{"up":12,"down":34},"months":{}}'],
    ['freev6-wallpaper', 'data:image/jpeg;base64,AA=='], ['FREEV6_API_TOKEN', 'synthetic-secret']]);
  const accessed = [];
  const result = exportPreferences({getItem(key) { accessed.push(key); return data.get(key) ?? null; }});
  assert.equal(result.version, 1);
  assert.equal(result.format, 'freev6-ui-preferences');
  assert.equal(result.values['freev6-theme'], 'dark');
  assert.equal(result.values.FREEV6_API_TOKEN, undefined);
  assert.deepEqual(accessed, preferenceKeys);
});
test('storage read failures propagate instead of exporting an empty backup', () => {
  assert.throws(() => exportPreferences({ getItem() { throw Error('storage locked'); } }), /storage locked/);
});
