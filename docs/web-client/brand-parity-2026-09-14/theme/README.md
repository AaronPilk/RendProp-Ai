# Rendprop Studio appearance verification

Studio shares the iPhone's adaptive palette, rounded cards, feature colors and purple hero. The shell, Properties, AI tools, business tools, planner and reel controls use shared CSS tokens. The video canvas keeps a dark viewing surface in both appearances.

| Token | Light | Dark |
|---|---|---|
| Background | `#FAFAFC` | `#0E0D14` |
| Card | `#FFFFFF` | `#1A1825` |
| Main text | `#1C192D` | `#F2F0FA` |
| Accent | `#7C3AED` | `#9B6DFF` |

Source references: [`Theme.swift`](../../../../apps/ios/Rendprop/DesignSystem/Theme.swift), `RPGradient` and `ProjectFeature` in [`RendpropApp.swift`](../../../../apps/ios/Rendprop/RendpropApp.swift). The desktop's small secondary labels and status text use stronger tones for readability. Feature gradients retain their native endpoints with a small backing behind white copy. Icons and AI badges use the native translucent white treatment. No web fonts or new production image assets were added.

**System** is the default. **Light** and **Dark** are stored only in this browser under `rendprop.studio.appearance.v1`; appearance does not write an account record. System follows operating-system changes, and a saved preference updates other Studio tabs. Invalid or unavailable browser storage falls back safely.

The [verification receipt](receipt.json) records:

- Seven appearance behavior checks, including reload, cross-tab changes and unavailable storage.
- Sixteen measured contrast pairs covering body text, card text, secondary labels, links, primary buttons and status notices in both modes. Every measured pair exceeds 4.5:1; the lowest is 5.18:1. These measurements cover the listed semantic pairs, not image or gradient content.
- Twenty layout checks: five workspaces at 1440 and 390 pixels, in light and dark. All use the exact native background/main-text colors and have no document-wide horizontal overflow. Scrollable tool tabs and tables keep their intended scrolling.
- Source SHA-256 values for the CSS and appearance modules that were verified.

The workflow layout fixtures are isolated and use synthetic records. Their remote image requests are blocked; no screenshots from those incomplete image fixtures are included here. The sibling release evidence uses the connected branded fixture with synthetic image responses for Home and reel screenshots. No owner account screenshots are included.

Run the verification from `apps/studio` after installing the pinned dependencies:

```sh
STUDIO_BROWSER_EXECUTABLE='/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' node tests/theme-browser.mjs
```

The [runner](../../../../apps/studio/tests/theme-browser.mjs) builds the real components and fixture entries, starts a temporary local server, blocks non-local browser requests, and prints the temporary receipt directory. It does not require a running development server or credentials. Set `STUDIO_BROWSER_EXECUTABLE` to an installed browser, or omit it when Playwright's bundled browser is installed.
