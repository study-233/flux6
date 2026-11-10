import test from 'node:test';
import assert from 'node:assert/strict';
import { createIconSelection } from '../../apps/windows/web/branding.mjs';
function storage(initial) {
  let value=initial;
  return { getItem:()=>value, setItem:(_, next)=>{value=next;} };
}
test('default cow, persisted selection restored, unknown value falls back', async()=>{
 const disk=storage(null), calls=[];
 const first=createIconSelection({storage:disk,apply:async id=>calls.push(id)});
 assert.equal(first.selected,'cow');
 await first.select('earth');
 const second=createIconSelection({storage:disk,apply:async id=>calls.push(id)});
 await second.restore();
 assert.equal(second.selected,'earth'); assert.deepEqual(calls,['earth','earth']);
 assert.equal(createIconSelection({storage:storage('../bad'),apply:async()=>{}}).selected,'cow');
});
test('native failure keeps last choice and restores its icon', async()=>{
 const calls=[];
 const model=createIconSelection({storage:storage('cow'),apply:async id=>{calls.push(id);if(id==='prism')throw Error('native');}});
 await assert.rejects(model.select('prism'));
 assert.equal(model.selected,'cow'); assert.deepEqual(calls,['prism','cow']);
 await assert.rejects(model.select('unknown'));
});
test('storage failure restores previous icon', async()=>{
 const calls=[];
 const model=createIconSelection({storage:{getItem:()=>null,setItem:()=>{throw Error('disk');}},apply:async id=>calls.push(id)});
 await assert.rejects(model.select('orange'));
 assert.equal(model.selected,'cow'); assert.deepEqual(calls,['orange','cow']);
});
