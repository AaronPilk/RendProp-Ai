/* Rendprop site JS — theme, motion, sliders. No dependencies. */
(function () {
  "use strict";
  document.documentElement.classList.add("js");

  /* ---------- Theme: auto → light → dark, persisted ---------- */
  var KEY = "rp-theme";
  function applyTheme(v) {
    if (v === "light" || v === "dark") document.documentElement.setAttribute("data-theme", v);
    else document.documentElement.removeAttribute("data-theme");
    var btn = document.getElementById("themeBtn");
    if (btn) {
      btn.textContent = v === "light" ? "☀︎" : v === "dark" ? "☾" : "◐";
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

    /* ---------- Motion (skip when reduced) ---------- */
    if (matchMedia("(prefers-reduced-motion: reduce)").matches) return;

    var plx = Array.prototype.slice.call(document.querySelectorAll(".plx-wrap img"));
    var heroBg = document.querySelector("[data-hero-plx] img");
    var ticking = false;
    function applyPlx() {
      ticking = false;
      var vh = innerHeight;
      plx.forEach(function (img) {
        var r = img.parentElement.getBoundingClientRect();
        if (r.bottom < 0 || r.top > vh) return;
        var p = (r.top + r.height / 2 - vh / 2) / vh;
        img.style.setProperty("--plx", (p * -36).toFixed(1) + "px");
      });
      if (heroBg) {
        var y = Math.min(scrollY, vh);
        heroBg.style.transform = "translateY(" + (y * 0.18).toFixed(1) + "px) scale(1.06)";
      }
    }
    addEventListener("scroll", function () {
      if (!ticking) { ticking = true; requestAnimationFrame(applyPlx); }
    }, { passive: true });
    applyPlx();

    if (matchMedia("(pointer: fine)").matches) {
      var cards = Array.prototype.slice.call(document.querySelectorAll("[data-mplx]"));
      if (cards.length) {
        var mx = 0, my = 0, mTick = false;
        addEventListener("pointermove", function (e) {
          mx = e.clientX / innerWidth - 0.5; my = e.clientY / innerHeight - 0.5;
          if (!mTick) {
            mTick = true;
            requestAnimationFrame(function () {
              mTick = false;
              cards.forEach(function (c) {
                var s = +c.dataset.mplx;
                c.style.translate = (mx * -s).toFixed(1) + "px " + (my * -s).toFixed(1) + "px";
              });
            });
          }
        }, { passive: true });
      }
    }
  });
})();
