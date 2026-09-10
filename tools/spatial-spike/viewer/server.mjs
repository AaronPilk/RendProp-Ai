import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { basename, resolve } from 'node:path';

const args = process.argv.slice(2);
const option = (name, fallback) => {
  const i = args.indexOf(name);
  if (i < 0) return fallback;
  if (!args[i + 1] || args[i + 1].startsWith('--')) throw new Error(`Missing ${name} value`);
  return args[i + 1];
};
const host = option('--host', '127.0.0.1');
const port = Number(option('--port', '8093'));
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid port');
const base = fileURLToPath(new URL('.', import.meta.url));
const files = new Map([
  ['/', ['index.html', 'text/html; charset=utf-8']],
  ['/viewer.mjs', ['viewer.mjs', 'text/javascript; charset=utf-8']],
  ['/benchmark.mjs', ['benchmark.mjs', 'text/javascript; charset=utf-8']],
  ['/style.css', ['style.css', 'text/css; charset=utf-8']],
  ['/vendor/playcanvas.min.js', ['node_modules/playcanvas/build/playcanvas.min.js', 'text/javascript; charset=utf-8']],
  ['/vendor/LICENSE', ['node_modules/playcanvas/LICENSE', 'text/plain; charset=utf-8']]
]);
const fixture = option('--fixture', null);
if (fixture) {
  if (!basename(fixture).startsWith('SYNTHETIC-NOT-A-ROOM') || !fixture.endsWith('.sog')) {
    throw new Error('--fixture is only for SYNTHETIC-NOT-A-ROOM*.sog test artifacts');
  }
  files.set('/fixture.sog', [resolve(fixture), 'application/octet-stream']);
}
const server = createServer(async (req, res) => {
  // Only this small allowlist is served. A LAN phone can fetch the viewer, but
  // neither the repository nor arbitrary room artifacts become a file server.
  const entry = files.get(new URL(req.url, 'http://localhost').pathname);
  if ((req.method !== 'GET' && req.method !== 'HEAD') || !entry) {
    res.writeHead(404); res.end('Not found'); return;
  }
  try {
    const data = await readFile(resolve(base, entry[0]));
    res.writeHead(200, {
      'Content-Type': entry[1],
      'Content-Length': data.byteLength,
      'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff',
      'Referrer-Policy': 'no-referrer',
      'Content-Security-Policy': "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; connect-src 'self' blob:; worker-src 'self' blob:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
    });
    res.end(req.method === 'HEAD' ? undefined : data);
  } catch {
    res.writeHead(500); res.end('Missing viewer dependency or test fixture; run npm ci');
  }
});
server.listen(port, host, () => {
  console.log(`Private Phase A viewer: http://${host}:${port}`);
  console.log('Room files are chosen on the viewing device and are never uploaded.');
});
