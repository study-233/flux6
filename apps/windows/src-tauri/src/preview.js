// Injected by the isolated preview host before the production page loads.
(() => {
  const names = Array.from('ABCDEFGH', letter => '校园接入 ' + letter);
  const group = '♻️ 自动选择';
  let selected = names[0];
  let running = true;
  const quality = {pinned:'', poolSize:4, samples:[], switches:[]};
  const qualityResponse = () => ({group, session:running ? session : '', profile:'preview-network', quality,
    poolSize:quality.poolSize, candidates:names, activeNodes:running && !quality.pinned ? names.slice(0,quality.poolSize) : []});
  let session = 'preview-1', generation = 1;
  let settings = { mode: 'rule', campusCidrs: ['edu.cn'] };
  let upload = 0, download = 0, sample = 0;
  const nativeFetch = window.fetch.bind(window);
  const json = Response.json.bind(Response);
  const unavailable = () => json({ error: '此操作需要真实后台，离线预览中不可用。' }, { status: 503 });

  window.fetch = async (input, options = {}) => {
    const url = new URL(input instanceof Request ? input.url : input, location.href);
    const method = options.method || 'GET';
    if (url.origin === location.origin || url.hostname === 'ipc.localhost' || url.protocol === 'ipc:') {
      return nativeFetch(input, options);
    }
    if (url.href === 'https://api-ipv6.ip.sb/ip') return new Response('2001:da8::1');
    if (url.origin === 'http://127.0.0.1:49190') {
      if (url.pathname === '/connections') {
        sample++;
        upload += Math.round(130000 + 64000 * Math.sin(sample * 0.8));
        download += Math.round(1600000 + 970000 * Math.sin(sample * 0.45));
        return json({ uploadTotal: upload, downloadTotal: download, connections: [{ upload, download }] });
      }
      if (url.pathname === '/proxies') return json({ proxies: { [group]: { now: selected, all: names } } });
      if (method === 'PUT' && decodeURIComponent(url.pathname) === '/proxies/' + group) {
        selected = JSON.parse(options.body).name;
        return json({});
      }
      if (url.pathname.endsWith('/delay')) {
        const name = decodeURIComponent(url.pathname.split('/')[2]);
        return json({ delay: 24 + Math.max(0, names.indexOf(name)) * 13 });
      }
      return unavailable();
    }
    if (url.origin !== 'http://127.0.0.1:13335') return unavailable();
    switch (method + ' ' + url.pathname) {
      case 'GET /api/v1/status': return json({ settings, proxy: { running, pid: running ? generation : 0 }, warp: { registered: true }, controllerPort: running ? 49190 : 0, downloadSession: running ? session : '' });
      case 'GET /api/v1/nodes/quality': return json(qualityResponse());
      case 'PUT /api/v1/nodes/quality': {
        const input = JSON.parse(options.body);
        if (!running || input.session !== session || input.profile !== 'preview-network') return unavailable();
        if (input.mode === 'fixed' && !names.includes(input.node)) return unavailable();
        if (input.poolSize !== undefined) {
          if (input.mode !== 'auto' || ![2,4,8].includes(input.poolSize)) return unavailable();
          quality.poolSize = input.poolSize;
        }
        quality.pinned = input.mode === 'fixed' ? input.node : '';
        const next = quality.pinned || names[0];
        if (next !== selected) quality.switches.push({at:new Date().toISOString(),from:selected,to:next,reason:quality.pinned ? '手动固定节点' : '恢复自动优选'});
        selected = next;
        return json(qualityResponse());
      }
      case 'POST /api/v1/nodes/delays': {
        const {delays,attempts,timeouts} = JSON.parse(options.body);
        for (const [node, delay] of Object.entries(delays)) {
          quality.samples.push({node,delay,attempts,timeouts:timeouts?.[node],kind:'delay',source:'delay',at:new Date().toISOString()});
        }
        return json({ok:true});
      }
      case 'POST /api/v1/nodes/download': {
        const input = JSON.parse(options.body);
        if (!running || input.session !== session || input.group !== group || !names.includes(input.node)) return unavailable();
        await new Promise((resolve, reject) => {
          const signal = options.signal;
          function cancel() { clearTimeout(timer); reject(new DOMException('已取消', 'AbortError')); }
          const timer = setTimeout(() => { signal?.removeEventListener('abort', cancel); resolve(); }, 700);
          if (signal?.aborted) cancel();
          else signal?.addEventListener('abort', cancel, { once:true });
        });
        const connections = input.connections || 1;
        const rate = [4820000, 7310000, 3190000][names.indexOf(input.node) % 3] * (connections === 4 ? 2 : 1);
        quality.samples.push({node:input.node,kind:'download',rate,connections,source:'manual',at:new Date().toISOString()});
        return json({ bytes: 33554432, bytesPerSecond: rate, connections, measuredAt: new Date().toISOString() });
      }
      case 'GET /api/v1/runtime': return json({ present: true });
      case 'GET /api/v1/appearance': return json({ color: '#4d649c' });
      case 'GET /api/v1/update/latest': return json({ update: false });
      case 'GET /api/v1/chain-proxy': return json({ enabled: false, count: 0 });
      case 'GET /api/v1/cloud-config': return json({ enabled: false, locked: true });
      case 'GET /api/v1/notice': return json({ notices: [{
        id: 'offline-preview', title: 'Windows 原版界面预览',
        body: '节点和流量使用演示数据，可以切换页面和外观。', published: new Date().toISOString()
      }] });
      case 'POST /api/v1/proxy/start':
        running = true;
        upload = download = 0;
        session = 'preview-' + (++generation);
        return json({ pid: generation, downloadSession: session, controllerPort:49190 });
      case 'POST /api/v1/proxy/stop': running = false; return json({});
      case 'PUT /api/v1/settings': settings = JSON.parse(options.body); return json(settings);
      default: return unavailable();
    }
  };
  localStorage.setItem('freev6-guide-done', '1');
  document.addEventListener('DOMContentLoaded', () => {
    const label = document.createElement('span');
    label.textContent = 'Flux6 · 离线预览';
    label.style.cssText = 'align-self:center;padding-left:12px;font-size:12px;color:var(--md-on-surface-variant)';
    document.getElementById('titlebar').prepend(label);
  });
})();
