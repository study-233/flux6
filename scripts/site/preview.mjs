import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import { buildSite } from './build.mjs';

const args = process.argv.slice(2);
const option = (name, fallback) => args.includes(name) ? args[args.indexOf(name) + 1] : fallback;
const host = option('--host', '127.0.0.1');
const port = Number(option('--port', '4173'));
if (!['127.0.0.1', 'localhost'].includes(host)) throw new Error('Preview binds to loopback only');
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid preview port');
const directory = await buildSite();
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css', '.js': 'text/javascript', '.json': 'application/json', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.md': 'text/plain; charset=utf-8' };
const server = http.createServer(async (req, res) => {
  if (!['GET', 'HEAD'].includes(req.method)) { res.writeHead(405); res.end(); return; }
  try {
    const pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
    const file = path.resolve(directory, '.' + (pathname.endsWith('/') ? pathname + 'index.html' : pathname));
    if (!file.startsWith(directory + path.sep)) { res.writeHead(403); res.end(); return; }
    const data = await fs.readFile(file);
    res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'text/plain; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff' });
    res.end(req.method === 'HEAD' ? undefined : data);
  } catch { res.writeHead(404); res.end('Not found'); }
});
server.listen(port, host, () => console.log(`Local: http://${host}:${port}/`));
server.on('error', error => { console.error(error.message); process.exitCode = 1; });
