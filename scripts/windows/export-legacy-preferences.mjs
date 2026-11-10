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
