// May be embedded in the old WebView's origin. Never load app.js to export.
export const preferenceKeys = Object.freeze([
  'freev6-theme', 'freev6-dynamic-color', 'freev6-pure-black',
  'freev6-bg-mode', 'freev6-webgl-glass', 'freev6-wallpaper',
  'freev6-guide-done', 'freev6-skip-version', 'freev6-notice-read',
  'freev6-traffic-stats', 'freev6-halloween-force', 'freev6-halloween-greeted',
]);

export function exportPreferences(storage) {
  const values = {};
  for (const key of preferenceKeys) {
    const value = storage.getItem(key);
    if (value !== null) values[key] = value;
  }
  return { format: 'freev6-ui-preferences', version: 1, values };
}

// A standalone export UI: no helper call, token access or app.js import.
export function backupText(storage) {
  const text = JSON.stringify(exportPreferences(storage), null, 2);
  if (new TextEncoder().encode(text).length > 6 * 1024 * 1024) {
    throw new Error('界面备份超过 6 MiB，请先清除过大的壁纸后重试');
  }
  return text;
}
if (typeof document !== 'undefined') {
  document.getElementById('exportPreferencesButton')?.addEventListener('click', () => {
    const status = document.getElementById('exportPreferencesStatus');
    try {
      globalThis.flushTrafficStats?.(true);
      const text = backupText(localStorage);
      const dialog = document.createElement('dialog');
      dialog.style.cssText = 'max-width:600px;width:85%;border-radius:20px;padding:24px;';
      const heading = document.createElement('h3'); heading.textContent = '导出界面偏好';
      const description = document.createElement('p');
      description.textContent = '保存 JSON 后，在 Flutter 客户端的设置中导入。若下载未出现，可复制下方文本并保存为 UTF-8 JSON 文件。';
      const area = document.createElement('textarea');
      area.readOnly = true; area.value = text; area.setAttribute('aria-label', '界面偏好备份 JSON');
      area.style.cssText = 'width:100%;height:160px;box-sizing:border-box;';
      const link = document.createElement('a'); link.textContent = '下载 JSON';
      const url = URL.createObjectURL(new Blob([text], {type:'application/json'}));
      link.href = url; link.download = 'freev6-ui-preferences.json';
      const copy = document.createElement('button'); copy.textContent = '复制备份';
      copy.addEventListener('click', async () => {
        area.focus(); area.select();
        try { await navigator.clipboard.writeText(text); copy.textContent = '已复制'; }
        catch { copy.textContent = '请按 Ctrl+C 复制'; }
      });
      const close = document.createElement('button'); close.textContent = '关闭';
      close.addEventListener('click', () => dialog.close());
      for (const button of [link, copy, close]) button.style.marginRight = '12px';
      dialog.append(heading, description, area, link, copy, close);
      dialog.addEventListener('close', () => { URL.revokeObjectURL(url); dialog.remove(); }, {once:true});
      document.body.append(dialog); dialog.showModal();
      if (status) status.textContent = '';
    } catch (error) { if (status) status.textContent = `导出失败：${error.message}`; }
  });
}
