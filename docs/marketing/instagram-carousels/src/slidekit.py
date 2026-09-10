import os as _os; _HERE=_os.path.dirname(_os.path.abspath(__file__))
"""Rendprop carousel slide kit — 1080x1350, the brand's own palette and mark."""
from PIL import Image, ImageDraw, ImageFilter, ImageFont
import cairosvg, io, os, math

W, H = 1080, 1350
F = _os.path.join(_HERE,"fonts")+"/"
MARK_SVG = _os.path.join(_HERE,"brand","rendprop-mark.svg")

INK      = (11, 13, 16)
INK_SOFT = (22, 24, 32)
VIOLET   = (124, 58, 237)
MID      = (139, 79, 239)
LIGHT    = (169, 124, 242)
LAVENDER = (217, 198, 250)
PAPER    = (242, 243, 245)
MUTED    = (150, 152, 166)

def font(name, size):
    return ImageFont.truetype(F + name, size)
HEAD  = lambda s: font("Manrope-0.ttf", s)   # ExtraBold
HEAD2 = lambda s: font("Manrope-1.ttf", s)   # Medium
BODY  = lambda s: font("Inter-2.ttf", s)     # Regular
BOLD  = lambda s: font("Inter-1.ttf", s)     # SemiBold
XBOLD = lambda s: font("Inter-0.ttf", s)     # ExtraBold

_mark_cache = {}
def mark(width, tint=None):
    """The real vector mark, rendered at any width."""
    key = (width, tint)
    if key in _mark_cache: return _mark_cache[key]
    png = cairosvg.svg2png(url=MARK_SVG, output_width=width*3, output_height=width*3)
    im = Image.open(io.BytesIO(png)).convert("RGBA")
    im = im.crop(im.getbbox())
    im = im.resize((width, int(im.height*width/im.width)), Image.LANCZOS)
    if tint:
        solid = Image.new("RGBA", im.size, tint + (255,))
        solid.putalpha(im.getchannel("A"))
        im = solid
    _mark_cache[key] = im
    return im

def ground(kind="dark", seed=0):
    """Dark ground with a violet bloom. `seed` moves the bloom so a run of
    slides does not look stamped from one plate."""
    base = Image.new("RGB", (W, H), INK if kind == "dark" else PAPER)
    glow = Image.new("RGB", (W, H), INK if kind == "dark" else PAPER)
    d = ImageDraw.Draw(glow)
    cx = W * (0.78 if seed % 2 == 0 else 0.18)
    cy = H * (0.14 + 0.1 * ((seed // 2) % 3))
    r  = W * 0.50
    # Restrained on purpose. The brand ground is near-black; the violet is an
    # accent behind it, not a wash over it. A heavy bloom also flattens the
    # white headline, which is the thing that has to carry a feed.
    col = (34, 24, 60) if kind == "dark" else (236, 230, 251)
    d.ellipse([cx-r, cy-r, cx+r, cy+r], fill=col)
    out = Image.blend(base, glow.filter(ImageFilter.GaussianBlur(220)), 0.62)
    return out.convert("RGBA")

def fit(draw, text, fnt_fn, size, max_w, max_h, min_size=28, leading=1.06):
    """Shrink until the wrapped block fits. Returns (lines, font, line_h)."""
    while size >= min_size:
        f = fnt_fn(size)
        words, lines, cur = text.split(), [], ""
        for wd in words:
            t = (cur + " " + wd).strip()
            if draw.textlength(t, font=f) <= max_w: cur = t
            else:
                if cur: lines.append(cur)
                cur = wd
        if cur: lines.append(cur)
        lh = int(size * leading)
        if all(draw.textlength(l, font=f) <= max_w for l in lines) and len(lines)*lh <= max_h:
            return lines, f, lh
        size -= 3
    f = fnt_fn(min_size)
    return [text], f, int(min_size*leading)

def block(img, draw, text, fnt_fn, size, x, y, max_w, max_h, fill, leading=1.06, track=0):
    lines, f, lh = fit(draw, text, fnt_fn, size, max_w, max_h, leading=leading)
    for i, l in enumerate(lines):
        if track:
            cx = x
            for ch in l:
                draw.text((cx, y + i*lh), ch, font=f, fill=fill); cx += draw.textlength(ch, font=f) + track
        else:
            draw.text((x, y + i*lh), l, font=f, fill=fill)
    return y + len(lines)*lh

def rule(draw, x, y, w=120, col=VIOLET, h=7):
    draw.rounded_rectangle([x, y, x+w, y+h], radius=h//2, fill=col)

def footer(img, draw, n=None, total=None, light=False):
    m = mark(58, tint=None if not light else None)
    img.alpha_composite(m, (72, H-118))
    draw.text((146, H-104), "RENDPROP", font=XBOLD(27),
              fill=PAPER if not light else INK)
    if n:
        draw.text((W-72-draw.textlength(f"{n}/{total}", font=BOLD(26)), H-100),
                  f"{n}/{total}", font=BOLD(26), fill=MUTED)

def swipe(draw):
    x = W-92
    draw.text((x-176, H-104), "SWIPE", font=XBOLD(25), fill=LAVENDER)
    for i,dx in enumerate((0,16,32)):
        draw.polygon([(x-52+dx, H-102),(x-52+dx, H-78),(x-40+dx, H-90)],
                     fill=(LAVENDER if i==2 else (110,92,150)))


def measure(draw, text, fnt_fn, size, max_w, max_h, leading=1.06):
    """Height the block WILL take, without drawing it. Lets a card be sized to
    its content instead of the content being crammed into a guessed card."""
    lines, f, lh = fit(draw, text, fnt_fn, size, max_w, max_h, leading=leading)
    return len(lines) * lh
