/* Rendprop site JS — theme, motion, sliders. No dependencies. */

/* ---------------------------------------------------------------------------
   `?ref=` — READ DELIBERATELY NOWHERE.

   Tour pages (`/f/<slug>`) and portfolio pages (`/a/<handle>`) link back here
   as `https://rendprop.com/?ref=tour` and `?ref=portfolio`
   (services/edge/tour-host/src/attribution.ts `siteUrl`). It exists so the
   surface that sent a visitor is present in the request — in a server log and
   in a same-site referrer — and so there is ONE spelling of it already in the
   wild when the owner ever wants the number.

   This file does not read it, and must not start. No cookie, no localStorage,
   no beacon, no third-party script: the privacy policy says in as many words
   that there is "no third-party analytics SDK, no advertising SDK, no
   advertising identifier (IDFA), and no tracking pixel", and reading a
   campaign parameter into any kind of per-visitor store is how that sentence
   stops being true. If this ever needs a number, count it server-side from the
   Worker's own logs, where no identifier is involved.

   (Apple's `ct=` on the App Store links below is a different thing entirely:
   it is a query parameter on an OUTBOUND link, read by Apple in App Store
   Connect, never by us and never stored on the device. The JSON-LD
   `installUrl`/`downloadUrl` values on index.html and pricing.html stay
   parameter-free on purpose — they identify the app, they are not a click.)
   --------------------------------------------------------------------------- */
(function () {
  "use strict";
  document.documentElement.classList.add("js");

  /* ---------- Theme: auto → light → dark, persisted ---------- */
  var KEY = "rp-theme";
  var SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">';
  var ICON = {
    auto: SVG + '<circle cx="12" cy="12" r="8.5"/><path d="M12 3.5v17A8.5 8.5 0 0012 3.5z" fill="currentColor" stroke="none"/></svg>',
    sun: SVG + '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2.5M12 19v2.5M2.5 12H5M19 12h2.5M5.3 5.3l1.8 1.8M16.9 16.9l1.8 1.8M5.3 18.7l1.8-1.8M16.9 7.1l1.8-1.8"/></svg>',
    moon: SVG + '<path d="M20 14.5A8.5 8.5 0 019.5 4a8.5 8.5 0 1010.5 10.5z"/></svg>',
    menu: SVG + '<path d="M4 7h16M4 12h16M4 17h16"/></svg>',
    close: SVG + '<path d="M6 6l12 12M18 6L6 18"/></svg>'
  };
  function applyTheme(v) {
    if (v === "light" || v === "dark") document.documentElement.setAttribute("data-theme", v);
    else document.documentElement.removeAttribute("data-theme");
    var btn = document.getElementById("themeBtn");
    if (btn) {
      btn.innerHTML = v === "light" ? ICON.sun : v === "dark" ? ICON.moon : ICON.auto;
      btn.setAttribute("aria-label", "Theme: " + (v || "auto") + " — click to change");
      btn.title = "Theme: " + (v || "auto");
    }
  }
  function storedTheme() { try { return localStorage.getItem(KEY) || ""; } catch (e) { return ""; } }
  window.rpCycleTheme = function () {
    var cur = storedTheme();
    var next = cur === "" ? "light" : cur === "light" ? "dark" : "";
    try { next ? localStorage.setItem(KEY, next) : localStorage.removeItem(KEY); } catch (e) {}
    // Suppress every transition for the swap so the palette flips instantly (no half-second sweep).
    var de = document.documentElement;
    de.classList.add("theme-switch");
    applyTheme(next);
    void de.offsetWidth; // force the class + new palette to commit before we release the guard
    requestAnimationFrame(function () {
      requestAnimationFrame(function () { de.classList.remove("theme-switch"); });
    });
  };
  applyTheme(storedTheme());

  document.addEventListener("DOMContentLoaded", function () {
    applyTheme(storedTheme()); // sync the button icon once it exists

    /* ---------- Nav ---------- */
    var nav = document.getElementById("nav");
    if (nav) {
      var onScrollNav = function () { nav.classList.toggle("scrolled", scrollY > 12); };
      addEventListener("scroll", onScrollNav, { passive: true }); onScrollNav();
    }

    /* Theme button — bound here, not with an inline onclick, so the page's CSP
       never has to allow inline script execution. */
    var themeBtn = document.getElementById("themeBtn");
    if (themeBtn) themeBtn.addEventListener("click", window.rpCycleTheme);

    /* ---------- Mobile menu ----------
       Under 900px the page links are a panel instead of a row. Without this
       they were simply hidden and a phone had no way into the other pages. */
    var menuBtn = document.getElementById("menuBtn");
    var menu = document.getElementById("navMenu");
    if (menuBtn && menu) {
      var setMenu = function (open) {
        menu.setAttribute("data-open", open ? "true" : "false");
        menuBtn.setAttribute("aria-expanded", open ? "true" : "false");
        menuBtn.innerHTML = open ? ICON.close : ICON.menu;
      };
      setMenu(false);
      menuBtn.addEventListener("click", function (e) {
        e.stopPropagation();
        var open = menu.getAttribute("data-open") !== "true";
        setMenu(open);
        // The panel sits before the button in the document, so a keyboard
        // user's next Tab would otherwise skip it. Hand focus to the first page link.
        if (open && menuBtn.matches(":focus-visible")) { var first = menu.querySelector("a"); if (first) first.focus(); }
      });
      menu.addEventListener("click", function (e) { if (e.target.tagName === "A") setMenu(false); });
      document.addEventListener("click", function (e) {
        if (menu.getAttribute("data-open") === "true" && !menu.contains(e.target)) setMenu(false);
      });
      document.addEventListener("keydown", function (e) {
        if (e.key === "Escape" && menu.getAttribute("data-open") === "true") { setMenu(false); menuBtn.focus(); }
      });
    }

    /* ---------- Reveal on scroll ---------- */
    var io = new IntersectionObserver(function (es) {
      es.forEach(function (e) { if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); } });
    }, { threshold: 0.14, rootMargin: "0px 0px -6% 0px" });
    document.querySelectorAll(".reveal").forEach(function (el) { io.observe(el); });

    /* ---------- Before/after sliders ---------- */
    document.querySelectorAll(".ba").forEach(function (ba) {
      var range = ba.querySelector('input[type="range"]');
      if (!range) return;
      var set = function () { ba.style.setProperty("--cut", range.value + "%"); };
      range.addEventListener("input", set, { passive: true }); set();
    });

    /* ---------- The room behind the page ----------
       Sections carry data-scene; as one reaches the middle of the viewport
       its room cross-fades in. Secondary rooms load only when first needed. */
    var sceneImgs = Array.prototype.slice.call(document.querySelectorAll(".scene img[data-scene]"));
    var sceneSections = Array.prototype.slice.call(document.querySelectorAll("main [data-scene]"));
    var railLinks = Array.prototype.slice.call(document.querySelectorAll(".rail a[href^='#']"));
    var railTargets = railLinks.map(function (a) { return document.getElementById(a.getAttribute("href").slice(1)); });
    var currentScene = "", currentRail = -1, tops = [], railTops = [], tick = false;
    function measure() {
      tops = sceneSections.map(function (s) { return s.getBoundingClientRect().top + scrollY; });
      railTops = railTargets.map(function (s) { return s ? s.getBoundingClientRect().top + scrollY : Infinity; });
    }
    function showScene(name) {
      if (name === currentScene) return;
      currentScene = name;
      sceneImgs.forEach(function (img) {
        var on = img.dataset.scene === name;
        if (on && img.dataset.src) { img.srcset = img.dataset.srcset; img.src = img.dataset.src; delete img.dataset.src; delete img.dataset.srcset; }
        img.classList.toggle("is-on", on);
      });
    }
    function update() {
      tick = false;
      var mid = scrollY + innerHeight * 0.5, name = "";
      for (var i = 0; i < tops.length; i++) if (tops[i] <= mid) name = sceneSections[i].dataset.scene;
      if (name) showScene(name);
      if (railLinks.length) {
        var line = scrollY + innerHeight * 0.38, idx = -1;
        for (var j = 0; j < railTops.length; j++) if (railTops[j] <= line) idx = j;
        if (idx !== currentRail) {
          currentRail = idx;
          railLinks.forEach(function (a, k) { if (k === idx) a.setAttribute("aria-current", "true"); else a.removeAttribute("aria-current"); });
        }
      }
    }
    function onScroll() { if (!tick) { tick = true; requestAnimationFrame(update); } }
    if (sceneSections.length || railLinks.length) {
      measure(); update();
      addEventListener("scroll", onScroll, { passive: true });
      addEventListener("resize", function () { measure(); onScroll(); }, { passive: true });
      addEventListener("load", function () { measure(); onScroll(); });
      // Warm the other rooms once the page is idle so the first cross-fade is ready.
      var warm = function () { sceneImgs.forEach(function (img) { if (img.dataset.src) { img.srcset = img.dataset.srcset; img.src = img.dataset.src; delete img.dataset.src; delete img.dataset.srcset; } }); };
      if ("requestIdleCallback" in window) requestIdleCallback(warm, { timeout: 4000 }); else setTimeout(warm, 2500);
    }
  });
})();
