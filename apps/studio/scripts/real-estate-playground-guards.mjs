// Side-effect-free boundaries shared by the local server, entry, and safety tests.
export const PREVIEW_KIND = 'rendprop-real-estate-local-v1';
export function previewOrigin(value) {
  if (typeof value !== 'string' || !/^http:\/\/127\.0\.0\.1:[1-9]\d{0,4}$/.test(value)) throw new Error('Use an explicit http://127.0.0.1 port for the real-estate preview.');
  const url = new URL(value);
  if (url.origin !== value || Number(url.port) > 65535) throw new Error('Invalid preview port.');
  return value;
}
export function previewRequestAllowed(headers, origin) {
  previewOrigin(origin);
  if (headers.host !== new URL(origin).host || headers.origin !== undefined && headers.origin !== origin) return false;
  if (headers.referer !== undefined) {
    try { if (new URL(headers.referer).origin !== origin) return false; } catch { return false; }
  }
  return headers['sec-fetch-site'] === undefined || ['same-origin', 'none'].includes(headers['sec-fetch-site']);
}
export function previewNavigationAllowed(value, origin, download = false) {
  try {
    previewOrigin(origin);
    const url = new URL(value, origin);
    if (url.username || url.password) return false;
    return download && url.protocol === 'blob:' ? url.origin === origin : url.protocol === 'http:' && url.origin === origin;
  } catch { return false; }
}
export function previewCsp() {
  return "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' blob: data:; media-src 'self' blob:; connect-src 'self' blob:; font-src 'self'; worker-src 'self' blob:; object-src 'none'; frame-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";
}
export function previewBuildOptions(root, outDir, input) {
  return { configFile: false, envFile: false, envPrefix: [], root, publicDir: 'public', logLevel: 'error',
    define: { 'import.meta.env': JSON.stringify({ MODE: 'local-preview', DEV: false, PROD: true, BASE_URL: '/' }) },
    build: { outDir, emptyOutDir: false, rollupOptions: { input } } };
}
