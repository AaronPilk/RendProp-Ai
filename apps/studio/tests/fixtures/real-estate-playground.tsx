import { mountConnectedFixture } from './connected-runtime';
import { previewNavigationAllowed, previewOrigin } from '../../scripts/real-estate-playground-guards.mjs';
// Same feature CSS and ordering as the production entry, after runtime's base CSS.
import '../../src/features/listings/listings.css';
import '../../src/features/sync/make-video.css';
import '../../src/features/creative/creative.css';
import '../../src/editor/conversation.css';
import '../../src/editor/editor.css';
import './real-estate-playground.css';

previewOrigin(location.origin);
const status = document.getElementById('preview-status')!;
const notice = document.querySelector<HTMLElement>('.real-estate-preview-notice')!;
const measureNotice = () => document.documentElement.style.setProperty('--real-estate-preview-notice-height', `${notice.getBoundingClientRect().height}px`);
new ResizeObserver(measureNotice).observe(notice);
measureNotice();
const allow = (href: string, download = false) => previewNavigationAllowed(href, location.origin, download);
const blocked = () => { status.textContent = 'External links and services are disabled in this local preview. Your demo session is still open.'; };
const disabledHref = `${location.origin}/playground?view=overview#external-link-disabled`;
const localizeLinks = () => document.querySelectorAll<HTMLAnchorElement>('a[href]').forEach(anchor => {
  if (!allow(anchor.href, anchor.hasAttribute('download'))) {
    anchor.dataset.previewExternal = 'true'; anchor.href = disabledHref;
  } else if (anchor.href !== disabledHref) delete anchor.dataset.previewExternal;
});
new MutationObserver(localizeLinks).observe(document.body, { subtree: true, childList: true, attributes: true, attributeFilter: ['href', 'download'] });
localizeLinks();
for (const type of ['click', 'auxclick']) document.addEventListener(type, event => {
  const anchor = (event.target as Element | null)?.closest?.('a[href]') as HTMLAnchorElement | null;
  if (anchor && (anchor.dataset.previewExternal || !allow(anchor.href, anchor.hasAttribute('download')))) { event.preventDefault(); event.stopImmediatePropagation(); blocked(); }
}, true);
document.addEventListener('submit', event => {
  const form = event.target as HTMLFormElement;
  if (!allow(form.action)) { event.preventDefault(); event.stopImmediatePropagation(); blocked(); }
}, true);
const open = window.open.bind(window);
window.open = ((url?: string | URL, target?: string, features?: string) => {
  if (!url || !allow(String(url))) { blocked(); return null; }
  return open(url, target, features);
}) as typeof window.open;
// Service requests use the injected in-memory fetcher. Any unrelated browser
// fetch must remain a read from this local static server (or a local blob).
const fetchLocal = window.fetch.bind(window);
window.fetch = (async (input, init) => {
  const url = new URL(input instanceof Request ? input.url : String(input), location.href);
  const method = init?.method ?? (input instanceof Request ? input.method : 'GET');
  if (!allow(url.href, true) || !['GET', 'HEAD'].includes(method.toUpperCase()) || url.pathname.startsWith('/functions/')) {
    blocked(); throw new Error('Network services are disabled in the local real-estate preview.');
  }
  return fetchLocal(input, { ...init, redirect: 'error', credentials: 'omit' });
}) as typeof window.fetch;
mountConnectedFixture({ preview: true });
