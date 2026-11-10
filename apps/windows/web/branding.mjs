export const catIcons = Object.freeze([
  ['cow', '奶牛猫 · 默认'], ['orange', '橘猫'], ['prism', '炫彩猫'],
  ['four-color', '四色猫'], ['earth', '地球猫'],
]);
export function normalizeIcon(value) {
  return catIcons.some(([id]) => id === value) ? value : 'cow';
}
export function createIconSelection({ storage, apply }) {
  const key = 'freev6-app-icon';
  let selected;
  try { selected = normalizeIcon(storage.getItem(key)); } catch { selected = 'cow'; }
  let busy = false;
  return {
    get selected() { return selected; },
    async restore() { await apply(selected); },
    async select(requested) {
      if (normalizeIcon(requested) !== requested) throw new Error('无效的图标。');
      if (busy) return;
      busy = true;
      const previous = selected;
      try {
        await apply(requested);
        storage.setItem(key, requested);
        selected = requested;
      } catch (error) {
        await apply(previous).catch(() => {});
        throw error;
      } finally { busy = false; }
    },
  };
}
if (typeof document !== 'undefined') {
  const host = document.getElementById('appIconChoices');
  const error = document.getElementById('appIconError');
  const buttons = [];
  const selection = createIconSelection({
    storage: { getItem: key => localStorage.getItem(key), setItem: (key, value) => localStorage.setItem(key, value) },
    apply: async id => {
      const invoke = window.__TAURI_INTERNALS__?.invoke;
      if (invoke) await invoke('app_icon_set', { id });
    },
  });
  function render() {
    for (const button of buttons) button.setAttribute('aria-pressed', String(button.dataset.icon === selection.selected));
    document.getElementById('appBrandIcon').src = `branding/${selection.selected}.svg`;
    document.getElementById('appIconFavicon').href = `branding/${selection.selected}.svg`;
  }
  for (const [id, label] of catIcons) {
    const button = document.createElement('button');
    button.className = 'app-icon-choice'; button.dataset.icon = id; button.type = 'button';
    const image = document.createElement('img'); image.src = `branding/${id}.svg`; image.alt = '';
    button.append(image, document.createTextNode(label));
    button.addEventListener('click', async () => {
      buttons.forEach(item => { item.disabled = true; }); error.textContent = '';
      try { await selection.select(id); render(); }
      catch { error.textContent = '图标切换失败，请重试。'; }
      finally { buttons.forEach(item => { item.disabled = false; }); }
    });
    buttons.push(button); host.append(button);
  }
  render();
  buttons.forEach(item => { item.disabled = true; });
  selection.restore().catch(() => { error.textContent = '图标恢复失败，请重新选择。'; })
    .finally(() => { buttons.forEach(item => { item.disabled = false; }); });
}
