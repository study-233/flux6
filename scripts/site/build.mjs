import fs from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('../../', import.meta.url));
const SOURCE = path.join(ROOT, 'site');
export const OUTPUT = path.join(ROOT, 'dist/site');

export async function buildSite() {
  const release = JSON.parse(await fs.readFile(path.join(SOURCE, 'release.json'), 'utf8'));
  if (!/^v\d+\.\d+\.\d+$/.test(release.tag)) throw new Error('Invalid release tag');
  for (const asset of release.assets) {
    if (!asset.url.startsWith(`https://github.com/study-233/free-v6/releases/download/${release.tag}/`)
      || !/^sha256:[a-f0-9]{64}$/.test(asset.digest) || !(asset.size > 0)) {
      throw new Error(`Invalid release asset: ${asset.name}`);
    }
  }
  const changelogs = {
    zh: await fs.readFile(path.join(SOURCE, 'CHANGELOG.md'), 'utf8'),
    en: await fs.readFile(path.join(SOURCE, 'CHANGELOG.en.md'), 'utf8'),
  };
  const context = vm.createContext({ Intl });
  vm.runInContext(await fs.readFile(path.join(SOURCE, 'assets/shared.js'), 'utf8'), context);
  const { translate, parseChangelog, timelineHtml, escapeHtml, changelogMeta } = context.Flux6Site;
  let html = await fs.readFile(path.join(SOURCE, 'index.html'), 'utf8');
  // Render the Chinese entry page so content and release notes work without JavaScript.
  html = html.replace(/(<[^>]+data-i18n="([^"]+)"[^>]*>)[^<]*(<\/[^>]+>)/g,
    (_, open, key, close) => open + escapeHtml(translate('zh', key)) + close);
  html = html.replace(/<title>.*?<\/title>/, `<title>${escapeHtml(translate('zh', 'pageTitle'))}</title>`);
  for (const [attribute, key] of [['name="description"', 'pageDescription'], ['property="og:title"', 'pageTitle'], ['property="og:description"', 'pageDescription']]) {
    html = html.replace(new RegExp(`(<meta ${attribute} content=")[^"]*`), `$1${escapeHtml(translate('zh', key))}`);
  }
  const versions = parseChangelog(changelogs.zh);
  if (versions[0]?.tag !== release.tag) throw new Error('Release metadata and changelog disagree');
  html = html.replace('<div class="timeline" id="timeline"></div>',
    `<div class="timeline" id="timeline">${timelineHtml(versions.map(version => ({ version, groups: version.groups })), { lang: 'zh', query: '', latestTag: release.tag }).html}</div>`);
  html = html.replace('<p class="section-sub" id="cl-meta"></p>', `<p class="section-sub" id="cl-meta">${changelogMeta(versions, 'zh')}</p>`);
  html = html.replace('data-i18n="heroReleaseLoading">最新版本', `data-i18n="heroReleaseLoading">${release.tag} 已发布`);
  const data = JSON.stringify({ release, changelogs }).replaceAll('<', '\\u003c');
  await fs.mkdir(path.join(OUTPUT, 'assets'), { recursive: true });
  await fs.cp(path.join(SOURCE, 'assets'), path.join(OUTPUT, 'assets'), { recursive: true });
  for (const name of ['LICENSE', 'UPSTREAM.json', 'CHANGELOG.md', 'CHANGELOG.en.md', 'release.json']) {
    await fs.copyFile(path.join(SOURCE, name), path.join(OUTPUT, name));
  }
  for (const [input, output] of [
    ['assets/branding/icon.svg', 'favicon.svg'],
    ['assets/branding/128x128.png', 'icon.png'],
    ['docs/compose/audits/2026-11-07-p5-p6/visual/offline-1232.png', 'assets/macos.png'],
    ['docs/images/android-home.jpg', 'assets/android.jpg'],
  ]) await fs.copyFile(path.join(ROOT, input), path.join(OUTPUT, output));
  await fs.writeFile(path.join(OUTPUT, 'assets/data.js'), `globalThis.Flux6Data = ${data};\n`);
  await fs.writeFile(path.join(OUTPUT, 'index.html'), html);
  await fs.writeFile(path.join(OUTPUT, '.nojekyll'), '');
  console.log(`Built Flux6 website: ${OUTPUT}`);
  return OUTPUT;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await buildSite();
