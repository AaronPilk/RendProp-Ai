import { writeFile } from 'node:fs/promises';
import { resolve, basename } from 'node:path';

const destination = process.argv[2];
if (!destination || !basename(destination).startsWith('SYNTHETIC-NOT-A-ROOM') || !destination.endsWith('.ply')) {
  throw new Error('Usage: node make-synthetic-fixture.mjs /private/path/SYNTHETIC-NOT-A-ROOM.ply');
}
const properties = ['x', 'y', 'z', 'nx', 'ny', 'nz', 'f_dc_0', 'f_dc_1', 'f_dc_2', 'opacity', 'scale_0', 'scale_1', 'scale_2', 'rot_0', 'rot_1', 'rot_2', 'rot_3'];
const points = [];
// A deterministic colored sphere. It only proves decoder/render plumbing and
// must never be reported as captured geometry, reconstruction, or phone FPS.
for (let lat = 0; lat < 32; lat++) {
  for (let lon = 0; lon < 64; lon++) {
    const u = lon / 64 * Math.PI * 2, v = (lat + .5) / 32 * Math.PI;
    const x = Math.cos(u) * Math.sin(v), y = Math.cos(v), z = Math.sin(u) * Math.sin(v);
    const color = [lon / 63, lat / 31, .35].map((c) => (c - .5) / .28209479177387814);
    points.push([x, y, z, 0, 0, 0, ...color, 3, ...Array(3).fill(Math.log(.04)), 1, 0, 0, 0]);
  }
}
const header = `ply\nformat binary_little_endian 1.0\ncomment SYNTHETIC NOT A ROOM; decoder test only\nelement vertex ${points.length}\n${properties.map((p) => `property float ${p}`).join('\n')}\nend_header\n`;
const data = Buffer.alloc(points.length * properties.length * 4);
let offset = 0;
for (const point of points) for (const value of point) { data.writeFloatLE(value, offset); offset += 4; }
await writeFile(resolve(destination), Buffer.concat([Buffer.from(header), data]), { flag: 'wx' });
console.log(`Wrote SYNTHETIC NOT A ROOM fixture: ${points.length} splats`);
