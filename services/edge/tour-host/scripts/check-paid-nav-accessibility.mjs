#!/usr/bin/env node
// Check the actual rendered paid navigation in Chromium and WebKit. All media
// requests are blocked; the fixture never contacts an API or publishes a site.
import assert from "node:assert/strict";
import { chromium, webkit } from "../node_modules/@playwright/test/index.mjs";
import { buildSrc } from "./build-src.mjs";

const load = buildSrc("paid-nav-accessibility-" + process.pid);
const { renderTourPage } = await load("player");
const { buildDemoTour } = await load("demo");
let minimumContrast = Infinity;

function parseColor(value) {
  const match = value.match(/^rgba?\(([^)]+)\)$/);
  assert.ok(match, `Expected a computed rgb color, got ${value}`);
  const parts = match[1].split(/,\s*|\s+/).filter(Boolean).map(Number);
  assert.ok(parts.length >= 3 && parts.slice(0, 3).every(Number.isFinite), `Invalid color ${value}`);
  return { rgb: parts.slice(0, 3), alpha: parts[3] ?? 1 };
}

function over(foreground, background) {
  return foreground.rgb.map((channel, index) => channel * foreground.alpha + background[index] * (1 - foreground.alpha));
}

function luminance(rgb) {
  const linear = rgb.map(channel => {
    const value = channel / 255;
    return value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4;
  });
  return linear[0] * .2126 + linear[1] * .7152 + linear[2] * .0722;
}

function contrast(foreground, background) {
  const [lighter, darker] = [luminance(foreground), luminance(background)].sort((a, b) => b - a);
  return (lighter + .05) / (darker + .05);
}

async function inspectNav(page, tag) {
  const result = await page.evaluate(() => {
    const nav = document.querySelector("#listing-nav");
    const navStyle = getComputedStyle(nav);
    const actions = [...nav.querySelectorAll("a,button,summary")]
      .filter(element => {
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.opacity !== "0";
      })
      .map(element => {
        const layers = [];
        for (let node = element; node; node = node.parentElement) {
          layers.unshift(getComputedStyle(node).backgroundColor);
          if (node === nav) break;
        }
        return { label: element.getAttribute("aria-label") || element.textContent.trim(), color: getComputedStyle(element).color, layers };
      });
    return {
      background: navStyle.backgroundColor,
      backdropFilter: navStyle.backdropFilter,
      webkitBackdropSupported: CSS.supports("-webkit-backdrop-filter", "blur(1px)"),
      webkitBackdropFilter: navStyle.getPropertyValue("-webkit-backdrop-filter"),
      inactiveLinks: [...nav.querySelectorAll(".listing-nav-links a:not([aria-current])")].length,
      secondaryWalkthrough: nav.querySelectorAll(".walkthrough-secondary").length,
      actions,
    };
  });
  assert.equal(parseColor(result.background).alpha, 1, `${tag}: nav material is opaque over arbitrary imagery`);
  assert.equal(result.backdropFilter, "none", `${tag}: nav has no backdrop blur`);
  if (result.webkitBackdropSupported) assert.equal(result.webkitBackdropFilter, "none", `${tag}: nav has no WebKit backdrop blur`);
  assert.ok(result.inactiveLinks >= 3 && result.secondaryWalkthrough === 1, `${tag}: fixture includes muted links and recorded walkthrough`);
  assert.ok(result.actions.length >= 4, `${tag}: visible nav text controls were measured`);
  for (const action of result.actions) {
    for (const [underlay, color] of [["black", [0, 0, 0]], ["white", [255, 255, 255]]]) {
      const background = action.layers.reduce((base, layer) => over(parseColor(layer), base), color);
      const foreground = over(parseColor(action.color), background);
      const ratio = contrast(foreground, background);
      minimumContrast = Math.min(minimumContrast, ratio);
      assert.ok(ratio >= 4.5, `${tag}: ${action.label} has ${ratio.toFixed(2)}:1 over ${underlay}, expected 4.5:1`);
    }
  }
  return result.actions.length;
}

let checks = 0;
for (const [browserName, engine] of [["chromium", chromium], ["webkit", webkit]]) {
  const browser = await engine.launch({
    headless: true,
    ...(browserName === "chromium" ? { executablePath: process.env.STUDIO_BROWSER_EXECUTABLE || chromium.executablePath() } : {}),
  });
  try {
    for (const theme of ["signature-estate", "coastal-luxe"]) {
      const tour = buildDemoTour();
      tour.website_theme = theme;
      tour.listing_video = {
        url: "/synthetic-film.mp4", poster_url: "/synthetic-poster.svg", duration_s: 8,
        width: 1920, height: 1080, disclosure: "Synthetic fixture film.", branding_policy: "unbranded",
      };
      for (const width of [390, 1440]) {
        const context = await browser.newContext({ viewport: { width, height: 900 }, javaScriptEnabled: false });
        try {
          await context.route("**/*", route => route.abort());
          const page = await context.newPage();
          for (const propertyPage of ["home", "gallery"]) {
            const html = renderTourPage(tour, "/closed-api", "", "", {
              origin: "https://fixture.invalid", publicBase: "/property", page: propertyPage,
            });
            await page.setContent(html, { waitUntil: "domcontentloaded" });
            const tag = `${browserName} ${theme} ${width}px ${propertyPage}`;
            checks += await inspectNav(page, tag);
            if (width === 390) {
              await page.locator(".property-page-menu summary").click();
              assert.equal(await page.locator(".property-page-menu-links a:visible").count(), 5, `${tag}: native menu exposes every page and Top`);
              checks += await inspectNav(page, `${tag} menu open`);
            }
            if (browserName === "chromium") {
              const session = await context.newCDPSession(page);
              await session.send("Emulation.setEmulatedMedia", { features: [{ name: "prefers-reduced-transparency", value: "reduce" }] });
              assert.equal(await page.evaluate(() => matchMedia("(prefers-reduced-transparency: reduce)").matches), true, `${tag}: Chromium exposes reduced transparency`);
              checks += await inspectNav(page, `${tag} reduced transparency`);
              await session.send("Emulation.setEmulatedMedia", { features: [] });
              await session.detach();
            }
          }
        } finally {
          await context.close();
        }
      }
    }
  } finally {
    await browser.close();
  }
}
console.log(`Paid nav accessibility: ${checks} visible controls passed 4.5:1 over black/white (minimum ${minimumContrast.toFixed(2)}:1), with opaque unblurred material in Chromium and WebKit.`);
