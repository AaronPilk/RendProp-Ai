# Rendprop brand assets

`rendprop-mark.svg` is the mark as **true vector** — redrawn from the App Store
icon rather than upscaled from it. The original artwork was drawn as a chain of
overlapping dots, so its edges beaded; this is a smooth tapered ribbon fitted to
that artwork's own measured centreline, width profile and arrowhead. Scale it to
anything. Everything else here is rendered from it.

| file | use |
|---|---|
| `rendprop-mark.svg` | the mark, vector, transparent — print, web, anywhere |
| `rendprop-mark-4096-transparent.png` | the mark on transparency, 4096² |
| `rendprop-ig-profile-dark-4096.png` | Instagram / social avatar. **Preferred** — it holds a white feed |
| `rendprop-ig-profile-light-4096.png` | avatar for dark surfaces |

**Why the avatars are not just the app icon.** Instagram, X and LinkedIn crop an
avatar to a CIRCLE. The app icon puts "RENDPROP" along the bottom edge and the
mark off-centre, so a circular crop cuts the wordmark off and leaves the mark
lopsided. These centre the mark inside the circle's safe area and drop the
wordmark, which is the normal avatar treatment for a logo of this shape.

The stroke is also ~18% heavier than the app icon's. An avatar renders at 32px
in a comments row, and the original weight disappears there. That is a
deliberate icon-legibility variant, not a rebrand — the app icon itself is
unchanged.

## Palette

| | hex | use |
|---|---|---|
| Violet | `#7C3AED` | the arrowhead and the top of the gradient |
| Mid violet | `#8B4FEF` | gradient |
| Light violet | `#A97CF2` | gradient |
| Lavender | `#D9C6FA` | the gradient's tail |
| Ink | `#0B0D10` | dark ground |
| Paper | `#F2F3F5` | light ground |

`#9b6dff` also appears in `services/edge/tour-host/src/html.ts` as the tour
page's accent.
