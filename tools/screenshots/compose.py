#!/usr/bin/env python3
"""compose.py - turn raw 6.9-inch simulator captures into framed App Store shots.

    python3 tools/screenshots/compose.py \
        --src docs/appstore/screenshots/6.9 \
        --plan docs/appstore/screenshots/plan.json \
        --out docs/appstore/screenshots/6.9-framed

    python3 tools/screenshots/compose.py --check --out docs/appstore/screenshots/6.9-framed

Standard library + Pillow only. Every output is exactly 1320 x 2868 (the App
Store's 6.9-inch portrait size), an RGB PNG under 8 MB, with no alpha channel
and no bezel - a rounded-corner screenshot on a brand background under a
one-line benefit headline, which is what the top of the category looks like.

THE PLAN. `plan.json` is a list of frames, in the order they are uploaded:

    [
      {"src": "01-published-tour.png",
       "out": "01-cinematic-tour.png",
       "headline": "Walk it once. A cinematic tour.",
       "subline": "Film a walkthrough on your phone ...",
       "bg": "violet"}
    ]

Per frame:
  src       the raw capture inside --src (a list of 2-3 files = the "stack"
            layout: the captures fan out left-to-right, the last one in front)
  out       the file name written into --out
  headline  <= 2 lines; aim for <= 32 characters (a warning above that, an
            error when it cannot be set in two lines at the smallest size).
            "\\n" forces the line break; otherwise the break is chosen so the
            two lines are as even as possible (balanced wrap).
  subline   optional, <= 2 lines
  bg        a preset name (violet, grape, indigo, ink, mist), "#rrggbb", or
            ["#top", "#bottom"] for a 2-stop vertical gradient
  fit       "bleed" (default: the screenshot runs off the bottom edge, the
            classic look) or "inset" (the whole screenshot inside the canvas)
  crop_top  drop this many raw pixels from the TOP of the capture(s) before
            framing (a mid-scroll capture whose nav bar sits
            over half-scrolled tiles starts at its first clean row instead)
  layout    for 2-3 sources: "stack" (default: the captures fan out
            left-to-right, the last in front) or "column" (the TOP of each
            capture, `crop_height` raw px tall, one under the other - three
            hero cards fully readable)
  crop_height  column layout: raw px kept from the top of each capture
            (default 760)
  radius    corner radius of the inset in px (default 90)
  font      optional per-frame override of the bold font file

A top-level object {"defaults": {...}, "frames": [...]} is accepted too; the
defaults are merged under every frame.

TEXT RULES enforced here: no emoji or symbols outside plain Latin text (the
App Store is not the place, and the fonts below do not carry them), headline
and subline must fit, and the headline colour must clear WCAG AA (4.5:1)
against the background behind it - the ratio is printed for every frame.

FONTS. The first of these that exists is used, and named in the output:
Inter, SF Pro Rounded / SF Pro (on a Mac), Poppins, Liberation Sans, FreeSans,
DejaVu Sans. Pass --font-bold / --font-regular to force a file. If only
DejaVu is found the run says so - it works, but install Inter or run on the
Mac for a better-looking set.

--check re-reads every output (the plan's, or every PNG in --out), validates
size, mode, file size and alpha, and writes `sheet.jpg` - a contact sheet of
the whole set in order - next to them. It exits non-zero on any failure.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:  # pragma: no cover - the one dependency
    sys.stderr.write("compose.py needs Pillow: python3 -m pip install pillow\n")
    sys.exit(2)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

CANVAS = (1320, 2868)          # App Store 6.9-inch portrait
MAX_BYTES = 8 * 1024 * 1024    # App Store Connect's per-image cap
HEADLINE_SOFT_LIMIT = 32       # characters; a warning, not an error
MIN_CONTRAST = 4.5             # WCAG AA for normal text

# The layout grid. Every frame shares it so the set lines up when swiped.
TEXT_TOP = 168                 # first headline baseline area starts here
TEXT_SIDE = 96                 # left/right text margin
INSET_TOP = 700                # where the screenshot starts (single layout)
INSET_WIDTH_RATIO = 0.86       # ~86% of the canvas width
INSET_BOTTOM_MARGIN = 120      # "inset" fit only
HEADLINE_SIZE = 104
HEADLINE_MIN_SIZE = 78
HEADLINE_LINE_HEIGHT = 1.10
SUBLINE_SIZE = 46
SUBLINE_MIN_SIZE = 38
SUBLINE_LINE_HEIGHT = 1.32
HEADLINE_SUBLINE_GAP = 34
DEFAULT_RADIUS = 90
SHADOW_BLUR = 44
SHADOW_OFFSET = (0, 30)
SHADOW_ALPHA = 0.42

# Stack layout (2-3 captures fanned left to right, the last one in front).
STACK_SCALE = 0.58
STACK_STEP_X = 250
STACK_STEP_Y = 200
STACK_TOP = 700
STACK_LEFT = 32
COLUMN_WIDTH_RATIO = 0.84      # "column" layout: a touch narrower than a single inset so three pieces fit
COLUMN_CROP_HEIGHT = 760       # raw px kept from the top of each capture
COLUMN_GAP = 40                # px between the pieces

# Brand palette - services/edge/tour-host/public/assets/site.css and
# apps/ios/Rendprop/DesignSystem/Theme.swift. Accent #7C3AED; the Home hero
# card runs #6D28D9 -> #7C3AED -> #4F46E5; the site's dark ground is #0B0A10,
# its light ground #F7F6FB.
PRESETS = {
    "violet": ("#5B21B6", "#7C3AED"),
    "grape": ("#4C1D95", "#6D28D9"),
    "indigo": ("#3730A3", "#4F46E5"),
    "ink": ("#1B1727", "#0B0A10"),
    "mist": ("#F7F6FB", "#ECE9F5"),
}
INK = "#17141F"                # site --ink
INK_DIM = "#4A4560"            # subline on a light ground (>= 7:1 on #F7F6FB)
WHITE = "#FFFFFF"
LAVENDER = "#EDE9FE"           # subline on violet (>= 4.5:1 on #7C3AED)

# Bold first, then a regular/medium companion for the subline.
FONT_CANDIDATES_BOLD = [
    # Inter
    "Inter-Bold.ttf", "Inter-SemiBold.ttf", "Inter_28pt-Bold.ttf", "Inter.ttc",
    # macOS - SF Pro Rounded matches the app's hero (design: .rounded); the
    # variable files need the weight set by name, handled in load_font().
    "SF-Pro-Rounded-Bold.otf", "SF-Pro-Display-Bold.otf", "SF-Pro-Text-Bold.otf",
    "SFNSRounded.ttf", "SFNS.ttf",
    # Google fonts commonly installed on Linux
    "Poppins-Bold.ttf", "Poppins-SemiBold.ttf",
    # Metric-compatible fallbacks
    "LiberationSans-Bold.ttf", "FreeSansBold.ttf", "DejaVuSans-Bold.ttf",
]
FONT_CANDIDATES_REGULAR = [
    "Inter-Medium.ttf", "Inter-Regular.ttf", "Inter_28pt-Medium.ttf", "Inter.ttc",
    "SF-Pro-Rounded-Medium.otf", "SF-Pro-Display-Medium.otf", "SF-Pro-Text-Medium.otf",
    "SFNSRounded.ttf", "SFNS.ttf",
    "Poppins-Medium.ttf", "Poppins-Regular.ttf",
    "LiberationSans-Regular.ttf", "FreeSans.ttf", "DejaVuSans.ttf",
]
FONT_DIRS = [
    "/usr/share/fonts", "/usr/local/share/fonts", os.path.expanduser("~/.fonts"),
    os.path.expanduser("~/.local/share/fonts"),
    "/System/Library/Fonts", "/Library/Fonts", os.path.expanduser("~/Library/Fonts"),
    "C:/Windows/Fonts",
]

# Text the fonts above can set and the App Store should carry: Latin letters,
# digits, common punctuation, curly quotes, dashes and the ellipsis. Anything
# else (emoji, symbols, other scripts) is refused so it can never render as a
# tofu box in an uploaded image.
ALLOWED_EXTRA = set("\u2018\u2019\u201c\u201d\u2013\u2014\u2026\u00b7\u00a0\u00e9\u00e8\u00e0\u00fc\u00f6\u00e4\u00f1\u00e7")


# The first set was staged under numbered names (bridge script 560, 2026-09-05)
# while the test names its attachments s01-... A plan may use either spelling.
LEGACY_NAMES = {
    "01-published-tour.png": "s08-published-tour.png",
    "02-home-showroom.png": "s01-home-showroom.png",
    "03-sample-tour.png": "s02-sample-tour.png",
    "04-photo-studio.png": "s04-photo-studio.png",
    "05-new-home.png": "s03-new-home.png",
}
LEGACY_NAMES.update({v: k for k, v in list(LEGACY_NAMES.items())})


class ComposeError(Exception):
    pass


def resolve_source(src_dir, name):
    """Find a raw capture by name, tolerating the two spellings the set has
    used and the `_0_<id>` suffix xcresulttool puts on exported attachments,
    so --src can point straight at ~/Rendprop AI/_bridge/out/storeshots.
    Returns the path, or None."""
    candidates = [name] + [alias for alias in (LEGACY_NAMES.get(name),) if alias]
    for candidate in candidates:
        exact = os.path.join(src_dir, candidate)
        if os.path.isfile(exact):
            return exact
    for candidate in candidates:
        matches = sorted(glob.glob(os.path.join(src_dir, os.path.splitext(candidate)[0] + "_*.png")))
        if matches:
            return matches[0]
    return None


# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------


def hex_to_rgb(value):
    value = value.strip()
    if not value.startswith("#") or len(value) not in (4, 7):
        raise ComposeError("bad colour %r (want #rrggbb)" % value)
    if len(value) == 4:
        value = "#" + "".join(ch * 2 for ch in value[1:])
    return tuple(int(value[i : i + 2], 16) for i in (1, 3, 5))


def rgb_to_hex(rgb):
    return "#%02X%02X%02X" % tuple(rgb)


def relative_luminance(rgb):
    def channel(c):
        c = c / 255.0
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (channel(c) for c in rgb)
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_ratio(a, b):
    la, lb = relative_luminance(a), relative_luminance(b)
    hi, lo = max(la, lb), min(la, lb)
    return (hi + 0.05) / (lo + 0.05)


def lerp_rgb(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def resolve_background(spec):
    """A preset name, "#rrggbb", or ["#top", "#bottom"] -> (top, bottom) RGB."""
    if spec is None:
        spec = "violet"
    if isinstance(spec, str):
        if spec.lower() in PRESETS:
            top, bottom = PRESETS[spec.lower()]
            return hex_to_rgb(top), hex_to_rgb(bottom), spec.lower()
        rgb = hex_to_rgb(spec)
        return rgb, rgb, spec
    if isinstance(spec, (list, tuple)) and len(spec) == 2:
        return hex_to_rgb(spec[0]), hex_to_rgb(spec[1]), "%s->%s" % tuple(spec)
    raise ComposeError("bad bg %r (preset, #rrggbb, or [#top, #bottom])" % (spec,))


def is_light(rgb):
    return relative_luminance(rgb) > 0.4


def gradient_colour_at(top, bottom, y, height=CANVAS[1]):
    return lerp_rgb(top, bottom, max(0.0, min(1.0, y / float(height - 1))))


# ---------------------------------------------------------------------------
# Fonts
# ---------------------------------------------------------------------------

_FONT_INDEX = None


def font_index():
    """Map basename -> full path for every font file under the usual dirs."""
    global _FONT_INDEX
    if _FONT_INDEX is None:
        _FONT_INDEX = {}
        for root in FONT_DIRS:
            if not os.path.isdir(root):
                continue
            for path in glob.glob(os.path.join(root, "**", "*"), recursive=True):
                if path.lower().endswith((".ttf", ".otf", ".ttc")):
                    _FONT_INDEX.setdefault(os.path.basename(path), path)
    return _FONT_INDEX


def find_font_file(candidates, override=None):
    if override:
        if os.path.isfile(override):
            return override
        raise ComposeError("font file not found: %s" % override)
    index = font_index()
    for name in candidates:
        if name in index:
            return index[name]
    raise ComposeError("no usable font found; pass --font-bold/--font-regular")


def load_font(path, size, prefer_weight):
    font = ImageFont.truetype(path, size)
    # Variable fonts (SFNS.ttf, Inter.ttc on some installs) default to their
    # lightest instance; pick the wanted weight by name when the file offers it.
    try:
        names = [n.decode("utf-8", "replace") if isinstance(n, bytes) else str(n)
                 for n in font.get_variation_names()]
    except (OSError, AttributeError, ValueError):
        names = []
    if names:
        for wanted in prefer_weight:
            for name in names:
                if name.lower() == wanted.lower():
                    try:
                        font.set_variation_by_name(name)
                    except (OSError, ValueError):
                        pass
                    return font
    return font


class Fonts(object):
    def __init__(self, bold_override=None, regular_override=None):
        self.bold_path = find_font_file(FONT_CANDIDATES_BOLD, bold_override)
        self.regular_path = find_font_file(FONT_CANDIDATES_REGULAR, regular_override)
        self._cache = {}

    def bold(self, size):
        return self._get(self.bold_path, size, ("Bold", "Semibold", "SemiBold", "Heavy"))

    def regular(self, size):
        return self._get(self.regular_path, size, ("Medium", "Regular", "Book"))

    def _get(self, path, size, weights):
        key = (path, size)
        if key not in self._cache:
            self._cache[key] = load_font(path, size, weights)
        return self._cache[key]

    def describe(self):
        bold = os.path.basename(self.bold_path)
        regular = os.path.basename(self.regular_path)
        note = ""
        if bold.startswith("DejaVu"):
            note = " (only DejaVu Sans was found - it works, but Inter or SF Pro looks better;" \
                   " install Inter or run this on the Mac)"
        elif bold.startswith(("Liberation", "FreeSans")):
            note = " (a metric fallback - install Inter or run this on the Mac for the SF look)"
        return "headline %s, subline %s%s" % (bold, regular, note)


# ---------------------------------------------------------------------------
# Text: validation, measuring, balanced wrapping
# ---------------------------------------------------------------------------


def validate_text(label, text):
    if text is None:
        return ""
    text = str(text).replace("\r\n", "\n").strip()
    for ch in text:
        if ch == "\n" or ch in ALLOWED_EXTRA:
            continue
        code = ord(ch)
        if 0x20 <= code <= 0x7E:
            continue
        raise ComposeError(
            "%s contains %r (U+%04X): only plain Latin text, no emoji or symbols" % (label, ch, code))
    return text


def text_width(font, text):
    left, _top, right, _bottom = font.getbbox(text)
    return right - left


def wrap_balanced(font, text, max_width, max_lines=2):
    """Split `text` into <= max_lines lines that fit `max_width`, as evenly as
    possible. An explicit "\n" is honoured. Returns None when it cannot fit."""
    if "\n" in text:
        lines = [part.strip() for part in text.split("\n") if part.strip()]
        if len(lines) > max_lines or any(text_width(font, line) > max_width for line in lines):
            return None
        return lines
    words = text.split()
    if not words:
        return []
    if text_width(font, text) <= max_width:
        return [text]
    if max_lines < 2:
        return None
    best = None
    for split in range(1, len(words)):
        first = " ".join(words[:split])
        second = " ".join(words[split:])
        w1, w2 = text_width(font, first), text_width(font, second)
        if w1 > max_width or w2 > max_width:
            continue
        # Even lines first - but a break at the end of a sentence reads better
        # than a perfectly even one ("Walk it once. / A cinematic tour."), and a
        # one-letter word stranded at the end of a line reads worst of all.
        score = abs(w1 - w2)
        if first[-1] in ".!?:":
            score *= 0.5
        if len(words[split - 1].strip(".,!?:;")) <= 1:
            score += max_width * 0.5
        if best is None or score < best[0]:
            best = (score, [first, second])
    return best[1] if best else None


def fit_text(fonts, kind, text, max_width, max_lines=2):
    """Largest size (down to the minimum) at which `text` wraps into max_lines."""
    if kind == "headline":
        size, floor, loader = HEADLINE_SIZE, HEADLINE_MIN_SIZE, fonts.bold
    else:
        size, floor, loader = SUBLINE_SIZE, SUBLINE_MIN_SIZE, fonts.regular
    while size >= floor:
        font = loader(size)
        lines = wrap_balanced(font, text, max_width, max_lines)
        if lines is not None:
            return font, size, lines
        size -= 2
    raise ComposeError("%s does not fit in %d lines even at %dpx: %r"
                       % (kind, max_lines, floor, text))


def draw_centered_lines(draw, lines, font, size, line_height, top, colour, canvas_width):
    """Draw lines centred horizontally, top-aligned at `top`, one `line_height`
    apart. The block's height is len(lines) * round(size * line_height)."""
    y = top
    step = int(round(size * line_height))
    ascent, _descent = font.getmetrics()
    for line in lines:
        width = text_width(font, line)
        # Anchor "ls" = left/baseline; offset the baseline by the ascent so the
        # visual top of the block is `top` regardless of the glyphs used.
        x = (canvas_width - width) / 2.0
        left_bearing = font.getbbox(line)[0]
        draw.text((x - left_bearing, y + ascent), line, font=font, fill=colour, anchor="ls")
        y += step


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------


def gradient(top, bottom, size=CANVAS):
    width, height = size
    strip = Image.new("RGB", (1, height))
    px = strip.load()
    for y in range(height):
        px[0, y] = lerp_rgb(top, bottom, y / float(height - 1))
    return strip.resize(size)


def rounded_mask(size, radius):
    mask = Image.new("L", size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, size[0] - 1, size[1] - 1), radius=radius, fill=255)
    return mask


def load_capture(path):
    try:
        image = Image.open(path)
    except (OSError, ValueError) as exc:
        raise ComposeError("cannot open %s: %s" % (path, exc))
    if image.size != CANVAS:
        raise ComposeError("%s is %dx%d; a raw 6.9-inch capture must be %dx%d"
                           % (os.path.basename(path), image.size[0], image.size[1], CANVAS[0], CANVAS[1]))
    return image.convert("RGB")


def crop_capture(capture, top=0, height=None):
    """The capture from `top` down (and, when given, only `height` px of it).
    Never upscales: the box is clamped to the image."""
    top = max(0, min(int(top), capture.size[1] - 1))
    bottom = capture.size[1] if height is None else min(capture.size[1], top + int(height))
    if bottom - top < 200:
        raise ComposeError("crop leaves only %d px of the capture" % (bottom - top))
    return capture.crop((0, top, capture.size[0], bottom))


def paste_inset(canvas, capture, box_left, box_top, width, radius, light_bg):
    """Scale `capture` to `width`, round its corners, drop a shadow, and paste
    it at (box_left, box_top). Anything past the canvas edge is cropped."""
    scale = width / float(capture.size[0])
    height = int(round(capture.size[1] * scale))
    scaled = capture.resize((width, height), Image.LANCZOS)
    mask = rounded_mask((width, height), radius)

    # Shadow: a blurred rounded rectangle behind the inset.
    pad = SHADOW_BLUR * 3
    shadow = Image.new("RGBA", (width + pad * 2, height + pad * 2), (0, 0, 0, 0))
    shadow_alpha = int(255 * (SHADOW_ALPHA if not light_bg else SHADOW_ALPHA * 0.55))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (pad, pad, pad + width - 1, pad + height - 1), radius=radius, fill=(0, 0, 0, shadow_alpha))
    shadow = shadow.filter(ImageFilter.GaussianBlur(SHADOW_BLUR))
    canvas.alpha_composite(shadow, (box_left - pad + SHADOW_OFFSET[0], box_top - pad + SHADOW_OFFSET[1]))

    layer = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    layer.paste(scaled, (0, 0), mask)
    # A hairline so the rounded edge stays crisp against the background.
    stroke = (255, 255, 255, 64) if not light_bg else (0, 0, 0, 34)
    ImageDraw.Draw(layer).rounded_rectangle((0, 0, width - 1, height - 1), radius=radius,
                                            outline=stroke, width=2)
    canvas.alpha_composite(layer, (box_left, box_top))
    return height


def render_frame(frame, src_dir, fonts, log):
    """Compose one frame. Returns (image, info dict)."""
    headline = validate_text("headline", frame.get("headline"))
    subline = validate_text("subline", frame.get("subline"))
    if not headline:
        raise ComposeError("frame %r has no headline" % frame.get("out"))
    top, bottom, bg_name = resolve_background(frame.get("bg"))
    light_bg = is_light(top) and is_light(bottom)
    radius = int(frame.get("radius", DEFAULT_RADIUS))
    fit = str(frame.get("fit", "bleed")).lower()
    if fit not in ("bleed", "inset"):
        raise ComposeError("frame %r: fit must be bleed or inset" % frame.get("out"))

    srcs = frame.get("src")
    if isinstance(srcs, str):
        srcs = [srcs]
    if not isinstance(srcs, list) or not srcs or len(srcs) > 3:
        raise ComposeError("frame %r: src must be a file name or a list of 2-3" % frame.get("out"))
    captures = []
    for name in srcs:
        path = resolve_source(src_dir, name)
        if path is None:
            raise ComposeError("frame %r: missing source %s in %s" % (frame.get("out"), name, src_dir))
        captures.append(load_capture(path))

    headline_colour = INK if light_bg else WHITE
    subline_colour = INK_DIM if light_bg else LAVENDER
    if frame.get("font"):
        # A per-frame headline face; the subline keeps the run's regular face.
        fonts = Fonts(bold_override=str(frame["font"]), regular_override=fonts.regular_path)

    canvas = gradient(top, bottom).convert("RGBA")
    draw = ImageDraw.Draw(canvas)
    text_width_max = CANVAS[0] - 2 * TEXT_SIDE

    # --- text -------------------------------------------------------------
    h_font, h_size, h_lines = fit_text(fonts, "headline", headline, text_width_max)
    s_font = s_size = None
    s_lines = []
    if subline:
        s_font, s_size, s_lines = fit_text(fonts, "subline", subline, text_width_max)

    h_block = int(round(h_size * HEADLINE_LINE_HEIGHT)) * len(h_lines)
    s_block = int(round(s_size * SUBLINE_LINE_HEIGHT)) * len(s_lines) if s_lines else 0
    gap = HEADLINE_SUBLINE_GAP if s_lines else 0
    band_top = TEXT_TOP
    band_bottom = (INSET_TOP if len(captures) == 1 else STACK_TOP) - 72
    block = h_block + gap + s_block
    # Centre the text block in the band so a one-line headline does not hang
    # at the top while a two-line one sits lower.
    y = band_top + max(0, (band_bottom - band_top - block) // 2)
    draw_centered_lines(draw, h_lines, h_font, h_size, HEADLINE_LINE_HEIGHT,
                        y, headline_colour, CANVAS[0])
    text_bottom = y + h_block
    if s_lines:
        draw_centered_lines(draw, s_lines, s_font, s_size, SUBLINE_LINE_HEIGHT,
                            y + h_block + gap, subline_colour, CANVAS[0])
        text_bottom = y + block

    # Contrast: the headline colour against the gradient across the headline
    # band, and the subline colour across its band.
    worst = min(contrast_ratio(hex_to_rgb(headline_colour), gradient_colour_at(top, bottom, yy))
                for yy in (y, y + h_block))
    if s_lines:
        worst_sub = min(contrast_ratio(hex_to_rgb(subline_colour), gradient_colour_at(top, bottom, yy))
                        for yy in (y + h_block + gap, y + block))
        worst = min(worst, worst_sub)
    if worst < MIN_CONTRAST:
        raise ComposeError("frame %r: text contrast %.2f:1 is below %.1f:1 on bg %s"
                           % (frame.get("out"), worst, MIN_CONTRAST, bg_name))

    # --- screenshot(s) -------------------------------------------------------
    multi_layout = str(frame.get("layout", "stack")).lower()
    if multi_layout not in ("stack", "column"):
        raise ComposeError("frame %r: layout must be stack or column" % frame.get("out"))
    if len(captures) == 1:
        width = int(round(CANVAS[0] * INSET_WIDTH_RATIO))
        inset_top = INSET_TOP
        capture = captures[0]
        if frame.get("crop_top"):
            capture = crop_capture(capture, top=int(frame["crop_top"]))
        if fit == "inset":
            avail = CANVAS[1] - inset_top - INSET_BOTTOM_MARGIN
            width = min(width, int(avail * capture.size[0] / float(capture.size[1])))
        left = (CANVAS[0] - width) // 2
        paste_inset(canvas, capture, left, inset_top, width, radius, light_bg)
        layout = "single/%s%s" % (fit, "/crop" if frame.get("crop_top") else "")
    elif multi_layout == "column":
        # The top of each capture, one under the other: three hero cards, all
        # readable. The last one bleeds off the bottom edge like a single frame.
        crop_h = int(frame.get("crop_height", COLUMN_CROP_HEIGHT))
        crop_t = int(frame.get("crop_top", 0))
        width = int(round(CANVAS[0] * COLUMN_WIDTH_RATIO))
        left = (CANVAS[0] - width) // 2
        y = STACK_TOP
        for capture in captures:
            piece = crop_capture(capture, top=crop_t, height=crop_h)
            shown = paste_inset(canvas, piece, left, y, width, radius, light_bg)
            y += shown + COLUMN_GAP
        layout = "column/%d" % len(captures)
    else:
        width = int(round(CANVAS[0] * STACK_SCALE))
        n = len(captures)
        # Fan the captures left to right; the last one lands in front.
        total = width + STACK_STEP_X * (n - 1)
        left0 = max(STACK_LEFT, (CANVAS[0] - total) // 2)
        for index, capture in enumerate(captures):
            paste_inset(canvas, capture, left0 + STACK_STEP_X * index,
                        STACK_TOP + STACK_STEP_Y * index, width, radius, light_bg)
        layout = "stack/%d" % n

    if text_bottom > (INSET_TOP if len(captures) == 1 else STACK_TOP) - 40:
        raise ComposeError("frame %r: text block (%d px) collides with the screenshot"
                           % (frame.get("out"), text_bottom))

    info = {
        "out": frame.get("out"),
        "src": srcs,
        "bg": bg_name,
        "layout": layout,
        "headline_size": h_size,
        "headline_lines": h_lines,
        "subline_size": s_size,
        "subline_lines": s_lines,
        "contrast": worst,
    }
    if len(headline) > HEADLINE_SOFT_LIMIT:
        log("  ! headline is %d characters (aim for <= %d): %r"
            % (len(headline), HEADLINE_SOFT_LIMIT, headline))
    return canvas.convert("RGB"), info


# ---------------------------------------------------------------------------
# Plan loading and the two commands
# ---------------------------------------------------------------------------


def load_plan(path):
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    defaults = {}
    frames = data
    if isinstance(data, dict):
        defaults = data.get("defaults") or {}
        frames = data.get("frames")
    if not isinstance(frames, list) or not frames:
        raise ComposeError("%s: expected a list of frames (or {defaults, frames})" % path)
    merged = []
    for index, frame in enumerate(frames, start=1):
        if not isinstance(frame, dict):
            raise ComposeError("%s: frame %d is not an object" % (path, index))
        item = dict(defaults)
        item.update(frame)
        for key in ("src", "out", "headline"):
            if not item.get(key):
                raise ComposeError("%s: frame %d has no %r" % (path, index, key))
        out = str(item["out"])
        if os.path.basename(out) != out or not out.lower().endswith(".png"):
            raise ComposeError("%s: frame %d: out must be a bare .png file name, got %r"
                               % (path, index, out))
        merged.append(item)
    outs = [f["out"] for f in merged]
    dupes = sorted(set(o for o in outs if outs.count(o) > 1))
    if dupes:
        raise ComposeError("%s: duplicate out names %s" % (path, ", ".join(dupes)))
    if len(merged) > 10:
        raise ComposeError("%s: App Store Connect takes at most 10 screenshots; the plan has %d"
                           % (path, len(merged)))
    return merged


def cmd_compose(args, log):
    frames = load_plan(args.plan)
    fonts = Fonts(args.font_bold, args.font_regular)
    log("fonts: %s" % fonts.describe())
    os.makedirs(args.out, exist_ok=True)
    written, labels, skipped = [], [], []
    for index, frame in enumerate(frames, start=1):
        if args.only and frame["out"] not in args.only:
            continue
        srcs = frame["src"] if isinstance(frame["src"], list) else [frame["src"]]
        missing = [s for s in srcs if resolve_source(args.src, s) is None]
        if missing:
            message = "%02d %s: missing source %s" % (index, frame["out"], ", ".join(missing))
            if args.skip_missing:
                log("  . SKIPPED " + message + " (capture it on the Mac first)")
                skipped.append(frame["out"])
                continue
            raise ComposeError(message + " in %s (pass --skip-missing to leave it out)" % args.src)
        image, info = render_frame(frame, args.src, fonts, log)
        target = os.path.join(args.out, frame["out"])
        image.save(target, "PNG", optimize=True)
        size = os.path.getsize(target)
        log("  + %02d %-28s %s  %s  headline %dpx x%d  contrast %.1f:1  %.1f MB"
            % (index, frame["out"], info["layout"], info["bg"], info["headline_size"],
               len(info["headline_lines"]), info["contrast"], size / (1024.0 * 1024.0)))
        for line in info["headline_lines"]:
            log("      | %s" % line)
        for line in info["subline_lines"]:
            log("      : %s" % line)
        written.append(target)
        labels.append("%02d" % index)
    log("wrote %d frame(s) to %s%s" % (len(written), args.out,
                                       ", skipped %d" % len(skipped) if skipped else ""))
    if not written:
        raise ComposeError("nothing was written")
    if not args.no_sheet:
        sheet = contact_sheet(written, os.path.join(args.out, "sheet.jpg"), labels)
        log("contact sheet: %s" % sheet)
    return 0


def check_one(path):
    """Validate one output. Returns a list of problems (empty = fine)."""
    problems = []
    try:
        image = Image.open(path)
        image.load()
    except (OSError, ValueError) as exc:
        return ["cannot open: %s" % exc]
    if image.format != "PNG":
        problems.append("not a PNG (%s)" % image.format)
    if image.size != CANVAS:
        problems.append("size %dx%d, want %dx%d" % (image.size + CANVAS))
    if image.mode not in ("RGB", "RGBA"):
        problems.append("mode %s, want RGB or RGBA" % image.mode)
    size = os.path.getsize(path)
    if size >= MAX_BYTES:
        problems.append("%.2f MB is over the 8 MB cap" % (size / (1024.0 * 1024.0)))
    if image.mode == "RGBA":
        low, _high = image.getchannel("A").getextrema()
        if low == 0:
            problems.append("has fully transparent pixels")
    return problems


def cmd_check(args, log):
    if args.plan:
        frames = load_plan(args.plan)
        paths = [os.path.join(args.out, f["out"]) for f in frames]
        if args.skip_missing:
            paths = [p for p in paths if os.path.isfile(p)]
    else:
        paths = sorted(p for p in glob.glob(os.path.join(args.out, "*.png")))
    if not paths:
        raise ComposeError("nothing to check in %s" % args.out)
    failures = 0
    for index, path in enumerate(paths, start=1):
        if not os.path.isfile(path):
            log("  FAIL %02d %-28s missing" % (index, os.path.basename(path)))
            failures += 1
            continue
        problems = check_one(path)
        if problems:
            failures += 1
            log("  FAIL %02d %-28s %s" % (index, os.path.basename(path), "; ".join(problems)))
        else:
            image = Image.open(path)
            log("  ok   %02d %-28s %dx%d %s %.2f MB"
                % (index, os.path.basename(path), image.size[0], image.size[1], image.mode,
                   os.path.getsize(path) / (1024.0 * 1024.0)))
    existing = [p for p in paths if os.path.isfile(p)]
    if existing and not args.no_sheet:
        sheet = contact_sheet(existing, os.path.join(args.out, "sheet.jpg"))
        log("contact sheet: %s" % sheet)
    if len(existing) < 3:
        log("  ! App Store Connect needs at least 3 screenshots in the set (have %d)" % len(existing))
        failures += 1
    if failures:
        raise ComposeError("%d problem(s) - fix them before uploading" % failures)
    log("all %d frame(s) pass" % len(existing))
    return 0


def contact_sheet(paths, target, labels=None, thumb_width=264, per_row=5):
    """One row per five frames, each thumbnail captioned with its file name
    (prefixed by its plan number when `labels` is given)."""
    thumb_height = int(thumb_width * CANVAS[1] / float(CANVAS[0]))
    pad, caption = 24, 44
    rows = (len(paths) + per_row - 1) // per_row
    cols = min(per_row, len(paths))
    sheet = Image.new("RGB", (pad + cols * (thumb_width + pad),
                              pad + rows * (thumb_height + caption + pad)), (245, 244, 250))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype(find_font_file(FONT_CANDIDATES_REGULAR), 17)
    except ComposeError:
        font = ImageFont.load_default()
    for index, path in enumerate(paths):
        row, col = divmod(index, per_row)
        x = pad + col * (thumb_width + pad)
        y = pad + row * (thumb_height + caption + pad)
        try:
            thumb = Image.open(path).convert("RGB").resize((thumb_width, thumb_height), Image.LANCZOS)
            sheet.paste(thumb, (x, y))
        except (OSError, ValueError):
            draw.rectangle((x, y, x + thumb_width, y + thumb_height), fill=(255, 220, 220))
        label = labels[index] if labels else "%02d" % (index + 1)
        text = "%s  %s" % (label, os.path.basename(path))
        while text_width(font, text) > thumb_width and len(text) > 8:
            text = text[:-2].rstrip(".") + "\u2026"
        draw.text((x, y + thumb_height + 10), text, font=font, fill=(23, 20, 31))
    sheet.save(target, "JPEG", quality=88)
    return target


def build_parser():
    parser = argparse.ArgumentParser(
        prog="compose.py",
        description="Frame raw 6.9-inch captures for the App Store (1320x2868).",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__.split("THE PLAN.", 1)[1] if "THE PLAN." in __doc__ else "")
    parser.add_argument("--src", default="docs/appstore/screenshots/6.9",
                        help="directory of raw 1320x2868 captures (default: %(default)s)")
    parser.add_argument("--plan", default=None,
                        help="plan.json (default: docs/appstore/screenshots/plan.json when composing)")
    parser.add_argument("--out", default="docs/appstore/screenshots/6.9-framed",
                        help="output directory (default: %(default)s)")
    parser.add_argument("--check", action="store_true",
                        help="validate the outputs in --out and write sheet.jpg; no rendering")
    parser.add_argument("--skip-missing", action="store_true",
                        help="leave out frames whose raw capture does not exist yet")
    parser.add_argument("--only", action="append", metavar="OUT", default=[],
                        help="render only this output file name; repeatable")
    parser.add_argument("--font-bold", default=None, help="headline font file")
    parser.add_argument("--font-regular", default=None, help="subline font file")
    parser.add_argument("--no-sheet", action="store_true", help="do not write sheet.jpg")
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)

    def log(message):
        sys.stdout.write(message + "\n")

    try:
        if args.check:
            return cmd_check(args, log)
        if not args.plan:
            args.plan = "docs/appstore/screenshots/plan.json"
        if not os.path.isfile(args.plan):
            raise ComposeError("no plan at %s" % args.plan)
        if not os.path.isdir(args.src):
            raise ComposeError("no source directory at %s" % args.src)
        return cmd_compose(args, log)
    except ComposeError as exc:
        sys.stderr.write("compose.py: %s\n" % exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
