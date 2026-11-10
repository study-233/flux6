// Link the browser modules without executing application code or requiring npm packages.
import { readFileSync, readdirSync } from 'node:fs';
import { SourceTextModule } from 'node:vm';

const web = new URL('../apps/windows/web/', import.meta.url);
const html = readFileSync(new URL('index.html', web), 'utf8');
const { imports } = JSON.parse(html.match(/<script type="importmap">([\s\S]*?)<\/script>/)[1]);
const prefixes = Object.keys(imports).filter(key => key.endsWith('/')).sort((a, b) => b.length - a.length);
const roots = [...html.matchAll(/<script\b[^>]*\bsrc="([^"]+)"/g)].map(match => new URL(match[1], web));
const modules = new Map();

function resolve(name, parent) {
  if (name.startsWith('./') || name.startsWith('../')) return new URL(name, parent);
  if (Object.hasOwn(imports, name)) return new URL(imports[name], web);
  const prefix = prefixes.find(key => name.startsWith(key));
  if (prefix) return new URL(imports[prefix] + name.slice(prefix.length), web);
  throw new Error(`Unmapped import ${name} in ${parent}`);
}

function load(url) {
  if (!url.href.startsWith(web.href)) throw new Error(`Module outside web/: ${url}`);
  if (!modules.has(url.href)) {
    const source = readFileSync(url, 'utf8');
    modules.set(url.href, new SourceTextModule(source, { identifier: url.href }));
    // The app also loads LiquidGlass on demand. Visit literal import() targets as entry points.
    for (const match of source.matchAll(/\bimport\s*\(\s*(?:(['"])([^'"]+)\1\s*\))?/g)) {
      if (!match[2]) throw new Error(`Cannot verify a computed import() in ${url}`);
      roots.push(resolve(match[2], url));
    }
  }
  return modules.get(url.href);
}

for (const url of roots) {
  const module = load(url);
  if (module.status === 'unlinked') {
    await module.link((name, parent) => load(resolve(name, parent.identifier)));
  }
}

const vendor = new URL('vendor/', web);
const unused = readdirSync(vendor, { recursive: true }).filter(name =>
  name.endsWith('.js') && !modules.has(new URL(name, vendor).href));
if (unused.length) {
  console.error(`Unused vendor modules:\n${unused.join('\n')}`);
  process.exitCode = 1;
} else {
  console.log(`Verified ${modules.size} local JavaScript files.`);
}
