#!/usr/bin/env python3
"""
Rendprop marketing reel — zero-browser fallback renderer (1080x1920).

Pillow draws the background and the glass caption cards; ffmpeg composites them
over the agent's walkthrough clip with timed fades and a progress bar. This is
the path that rendered the shipped sample. The HyperFrames composition
(`../composition/index.html`) is the higher-fidelity production path.

    python3 gen.py --listing listing.json --clip walkthrough.mp4 --out ./out
    bash ./out/render.sh                       # -> ./out/reel.mp4

    python3 gen.py --write-example listing.json    # start from a template

Everything is data-driven: no listing text, no path, and no font is hard-coded to
one machine (audit F-G-22 — the mark was loaded from an absolute
`/sessions/<author-sandbox>/...` path, output went to a `/tmp/mktg` that was
never created, and the listing copy was baked into the source, so the script
could only ever run once, on one laptop).

Dependencies: Pillow (required) and ffmpeg (required, for the composite and for
rasterising the SVG mark — no cairosvg needed; the repo's ffmpeg is built with
librsvg). cairosvg is used if it happens to be installed. The mark is optional:
without a rasteriser the reel renders without it and says so.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter, ImageFont
except ImportError:                                        # pragma: no cover
    sys.exit("FATAL: Pillow is required — pip install Pillow")

W, H = 1080, 1920
REPO_SERVICES = Path(__file__).resolve().parents[2]        # …/services
DEFAULT_MARK = REPO_SERVICES / "edge/tour-host/public/assets/rendprop-mark.svg"

# Font lookup: named families first, then whatever the box actually has. Falls
# back to Pillow's bundled default rather than dying on a machine without
# Poppins (the old code assumed one Google-fonts directory).
FONT_DIRS = [
    "/usr/share/fonts/truetype/google-fonts/",
    "/usr/share/fonts/truetype/",
    "/usr/local/share/fonts/",
    "/Library/Fonts/", "/System/Library/Fonts/Supplemental/",
    str(Path.home() / ".fonts"),
]
FONT_CANDIDATES = {
    "bold": ["Poppins-Bold.ttf", "DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf",
             "Arial Bold.ttf", "Helvetica.ttc"],
    "semibold": ["Poppins-SemiBold.ttf", "Poppins-Medium.ttf", "DejaVuSans-Bold.ttf",
                 "LiberationSans-Bold.ttf"],
    "regular": ["Poppins-Regular.ttf", "DejaVuSans.ttf", "LiberationSans-Regular.ttf",
                "Arial.ttf"],
}

EXAMPLE_LISTING = {
    "brand": "RENDPROP",
    "tag": "PRIVATE TOUR",
    "kicker": "Private Listing",
    "address_lines": ["1180 Crestline", "Ridge"],
    "blurb_lines": ["A glass-and-oak modern estate", "above the canyon."],
    "stats": ["5 Beds", "6 Baths", "6,200 Sq Ft", "0.7 Acres"],
    "hero_kicker": "The life here",
    "hero_lines": ["Vanishing-edge pool.", "180° of open water."],
    "features": ["Chef's kitchen", "European white oak", "Glass wine wall", "Rooftop terrace"],
    "price_label": "OFFERED AT",
    "price": "$4,250,000",
    "cta_title": "Book a private showing",
    "cta_url": "rendprop.com",
    "caption_seconds": 4.0,
}


# ── font helpers ──────────────────────────────────────────────────────────────

def _find_font(kind: str) -> str | None:
    for name in FONT_CANDIDATES[kind]:
        for d in FONT_DIRS:
            p = Path(d) / name
            if p.exists():
                return str(p)
    return None


class Fonts:
    def __init__(self) -> None:
        self.paths = {k: _find_font(k) for k in FONT_CANDIDATES}
        missing = [k for k, v in self.paths.items() if not v]
        if missing:
            print(f"  · no dedicated font for {missing} — using Pillow's default "
                  f"(install Poppins or DejaVu for the shipped look)")

    def get(self, kind: str, size: int):
        path = self.paths.get(kind)
        if path:
            try:
                return ImageFont.truetype(path, size)
            except OSError:
                pass
        try:
            return ImageFont.load_default(size)            # Pillow >= 10.1
        except TypeError:                                   # pragma: no cover
            return ImageFont.load_default()


# ── drawing helpers ───────────────────────────────────────────────────────────

def lerp(a, b, t):
    t = max(0.0, min(1.0, t))
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def ls_text(d, xy, txt, f, fill, ls):
    """Letter-spaced text. Returns the x cursor after the last glyph."""
    x, y = xy
    for ch in txt:
        d.text((x, y), ch, font=f, fill=fill, anchor="la")
        x += d.textlength(ch, font=f) + ls
    return x


def ls_width(d, txt, f, ls):
    return sum(d.textlength(c, font=f) + ls for c in txt) - ls if txt else 0


def rasterise_mark(svg: Path, png: Path, size: int = 50) -> bool:
    """SVG → PNG via cairosvg, else ffmpeg (librsvg), else skip. Never raises."""
    if not svg.exists():
        print(f"  · brand mark not found at {svg} — rendering without it")
        return False
    try:
        import cairosvg  # type: ignore
        cairosvg.svg2png(url=str(svg), write_to=str(png),
                         output_width=size, output_height=size)
        return True
    except Exception:                                       # noqa: BLE001
        pass
    if shutil.which("ffmpeg"):
        r = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(svg),
                            "-vf", f"scale={size}:{size}", str(png)],
                           capture_output=True, text=True)
        if r.returncode == 0 and png.exists():
            return True
        print(f"  · ffmpeg could not rasterise {svg.name}: {r.stderr.strip()[:160]}")
    print("  · no SVG rasteriser (cairosvg or an ffmpeg with librsvg) — "
          "rendering without the brand mark")
    return False


# ── the asset set ─────────────────────────────────────────────────────────────

def build(listing: dict, out: Path, mark_svg: Path) -> list[str]:
    out.mkdir(parents=True, exist_ok=True)                  # used to assume /tmp/mktg existed
    fonts = Fonts()
    made: list[str] = []

    # background: vertical gradient + a blurred purple bloom + the frame outline
    bg = Image.new("RGBA", (W, H), (11, 10, 18, 255))
    d = ImageDraw.Draw(bg)
    c0, c1, c2 = (11, 10, 18), (26, 16, 48), (11, 10, 18)
    for y in range(H):
        t = y / H
        col = lerp(c0, c1, t / 0.55) if t < 0.55 else lerp(c1, c2, (t - 0.55) / 0.45)
        d.line([(0, y), (W, y)], fill=col + (255,))
    tint = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(tint).ellipse([W * 0.5 - 560, -160, W * 0.5 + 560, 760],
                                 fill=(124, 58, 237, 70))
    bg = Image.alpha_composite(bg, tint.filter(ImageFilter.GaussianBlur(170)))
    d = ImageDraw.Draw(bg)
    d.rounded_rectangle([60, 340, 1020, 944], radius=30, outline=(255, 255, 255, 34), width=2)

    mark_png = out / "mk.png"
    text_x = 60
    if rasterise_mark(mark_svg, mark_png):
        bg.alpha_composite(Image.open(mark_png).convert("RGBA"), (60, 52))
        text_x = 126
    ls_text(d, (text_x, 64), listing.get("brand", "RENDPROP"),
            fonts.get("bold", 26), (255, 255, 255, 255), 8)
    tag, f_tag = listing.get("tag", "PRIVATE TOUR"), fonts.get("semibold", 19)
    ls_text(d, (1020 - ls_width(d, tag, f_tag, 6), 70), tag, f_tag, (255, 255, 255, 175), 6)
    bg.convert("RGB").save(out / "bg.png")
    made.append("bg.png")

    # rounded mask for the video band
    m = Image.new("L", (960, 604), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, 959, 603], radius=30, fill=255)
    m.save(out / "rmask.png")
    made.append("rmask.png")

    # band overlay: legibility gradient + the "live" chip
    band = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    bd = ImageDraw.Draw(band)
    for i in range(230):
        bd.line([(62, 944 - i), (1018, 944 - i)], fill=(6, 5, 12, int(150 * (i / 230))))
    lx, ly = 84, 884
    lab, f_l = listing.get("band_label", "Live walkthrough"), fonts.get("bold", 20)
    tw = bd.textlength(lab, font=f_l)
    bd.rounded_rectangle([lx, ly, lx + tw + 70, ly + 44], radius=22,
                         fill=(16, 14, 24, 150), outline=(255, 255, 255, 55), width=1)
    bd.ellipse([lx + 20, ly + 16, lx + 32, ly + 28], fill=(155, 109, 255, 255))
    bd.text((lx + 44, ly + 22), lab, font=f_l, fill=(255, 255, 255, 255), anchor="lm")
    band.save(out / "band.png")
    made.append("band.png")

    # progress bar
    bar = Image.new("RGBA", (1080, 9), (0, 0, 0, 0))
    brd = ImageDraw.Draw(bar)
    for x in range(1080):
        brd.line([(x, 0), (x, 9)], fill=lerp((155, 109, 255), (124, 58, 237), x / 1080) + (255,))
    bar.save(out / "bar.png")
    made.append("bar.png")

    # ── caption cards ────────────────────────────────────────────────────────
    def newcap():
        return Image.new("RGBA", (W, H), (0, 0, 0, 0))

    def kicker(dr, y, txt):
        dr.rounded_rectangle([60, y + 8, 92, y + 10], radius=1, fill=(124, 58, 237, 255))
        ls_text(dr, (104, y), str(txt).upper(), fonts.get("bold", 22),
                (196, 168, 255, 255), 6)

    def chips(img, dr, labels, y0, fsz):
        f = fonts.get("bold", fsz)
        x, y, padx, pady = 60, y0, 26, 16
        for lab in labels:
            cw = dr.textlength(lab, font=f) + padx * 2
            ch = fsz + pady * 2
            if x + cw > 60 + 960:
                x, y = 60, y + ch + 14
            pan = Image.new("RGBA", img.size, (0, 0, 0, 0))
            ImageDraw.Draw(pan).rounded_rectangle([x, y, x + cw, y + ch], radius=17,
                                                  fill=(24, 21, 36, 150),
                                                  outline=(255, 255, 255, 44), width=1)
            img.alpha_composite(pan)
            dr = ImageDraw.Draw(img)
            dr.text((x + padx, y + ch / 2), lab, font=f, fill=(255, 255, 255, 255), anchor="lm")
            x += cw + 15

    c = newcap(); dr = ImageDraw.Draw(c)
    kicker(dr, 1010, listing.get("kicker", ""))
    for i, line in enumerate(listing.get("address_lines", [])[:2]):
        dr.text((60, 1052 + i * 98), line, font=fonts.get("bold", 90), fill=(255, 255, 255, 255))
    for i, line in enumerate(listing.get("blurb_lines", [])[:2]):
        dr.text((60, 1276 + i * 42), line, font=fonts.get("regular", 31),
                fill=(255, 255, 255, 205))
    c.save(out / "cap1.png"); made.append("cap1.png")

    c = newcap(); dr = ImageDraw.Draw(c)
    chips(c, dr, listing.get("stats", []), 1070, 32)
    c.save(out / "cap2.png"); made.append("cap2.png")

    c = newcap(); dr = ImageDraw.Draw(c)
    kicker(dr, 1010, listing.get("hero_kicker", ""))
    for i, line in enumerate(listing.get("hero_lines", [])[:2]):
        dr.text((60, 1060 + i * 90), line, font=fonts.get("bold", 74), fill=(255, 255, 255, 255))
    c.save(out / "cap3.png"); made.append("cap3.png")

    c = newcap(); dr = ImageDraw.Draw(c)
    chips(c, dr, listing.get("features", []), 1070, 27)
    c.save(out / "cap4.png"); made.append("cap4.png")

    c = newcap(); dr = ImageDraw.Draw(c)
    ls_text(dr, (60, 1034), listing.get("price_label", "OFFERED AT"),
            fonts.get("semibold", 27), (255, 255, 255, 175), 6)
    dr.text((58, 1076), listing.get("price", ""), font=fonts.get("bold", 118),
            fill=(206, 183, 255, 255))
    c.save(out / "cap5.png"); made.append("cap5.png")

    c = newcap(); dr = ImageDraw.Draw(c)
    pan = Image.new("RGBA", c.size, (0, 0, 0, 0))
    ImageDraw.Draw(pan).rounded_rectangle([120, 1120, 960, 1352], radius=30,
                                          fill=(18, 15, 28, 160),
                                          outline=(255, 255, 255, 42), width=1)
    c.alpha_composite(pan)
    dr = ImageDraw.Draw(c)
    dr.text((540, 1200), listing.get("cta_title", ""), font=fonts.get("bold", 56),
            fill=(255, 255, 255, 255), anchor="mm")
    dr.text((540, 1284), listing.get("cta_url", ""), font=fonts.get("bold", 32),
            fill=(196, 168, 255, 255), anchor="mm")
    c.save(out / "cap6.png"); made.append("cap6.png")
    return made


# ── the composite command (audit F-G-22: the README pointed at a header that
#    did not exist, so nobody could actually turn these PNGs into a reel) ──────

def write_render_script(out: Path, clip: Path, listing: dict) -> Path:
    per = float(listing.get("caption_seconds", 4.0) or 4.0)
    total = round(per * 6, 3)
    fades = []
    for i in range(6):
        start = round(i * per, 3)
        fades.append(
            f"[cap{i + 1}]format=rgba,fade=t=in:st={start}:d=0.4:alpha=1,"
            f"fade=t=out:st={round(start + per - 0.4, 3)}:d=0.4:alpha=1[c{i + 1}]"
        )
    overlays = []
    prev = "[withband]"
    for i in range(6):
        start, end = round(i * per, 3), round((i + 1) * per, 3)
        nxt = f"[o{i + 1}]" if i < 5 else "[capped]"
        overlays.append(f"{prev}[c{i + 1}]overlay=0:0:enable='between(t,{start},{end})'{nxt}")
        prev = nxt

    script = f"""#!/usr/bin/env bash
# Generated by gen.py — composites the caption cards over the walkthrough clip.
# Regenerate with:  python3 gen.py --listing <listing.json> --clip <clip> --out {out}
set -euo pipefail
cd "$(dirname "$0")"

CLIP="${{1:-{clip}}}"
OUT="${{2:-reel.mp4}}"
DUR={total}

# EVERY still input is looped for the full duration. A bare `-i still.png` is a
# one-frame stream, and alphamerge/overlay end when their shortest input does —
# that silently produced a 1-frame "reel".
ffmpeg -y -hide_banner \\
  -loop 1 -t "$DUR" -i bg.png \\
  -stream_loop -1 -i "$CLIP" \\
  -loop 1 -t "$DUR" -i rmask.png \\
  -loop 1 -t "$DUR" -i band.png \\
  -loop 1 -t "$DUR" -i bar.png \\
  -loop 1 -t "$DUR" -i cap1.png -loop 1 -t "$DUR" -i cap2.png \\
  -loop 1 -t "$DUR" -i cap3.png -loop 1 -t "$DUR" -i cap4.png \\
  -loop 1 -t "$DUR" -i cap5.png -loop 1 -t "$DUR" -i cap6.png \\
  -filter_complex "
    [1:v]scale=960:604:force_original_aspect_ratio=increase,crop=960:604,setsar=1,fps=30,trim=duration={total},setpts=PTS-STARTPTS[clip];
    [clip][2:v]alphamerge[clipmasked];
    [0:v][clipmasked]overlay=60:340[stage];
    [stage][3:v]overlay=0:0[withband];
    [5:v]null[cap1];[6:v]null[cap2];[7:v]null[cap3];
    [8:v]null[cap4];[9:v]null[cap5];[10:v]null[cap6];
    {(';' + chr(10) + '    ').join(fades)};
    {(';' + chr(10) + '    ').join(overlays)};
    [4:v]scale=1080:9,setsar=1[barimg];
    [capped][barimg]overlay=x='-1080+1080*t/{total}':y=1911[v]
  " \\
  -map "[v]" -t "$DUR" -an \\
  -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -movflags +faststart \\
  -r 30 "$OUT"

echo "-> $OUT"
"""
    path = out / "render.sh"
    path.write_text(script)
    os.chmod(path, 0o755)
    return path


# ── CLI ───────────────────────────────────────────────────────────────────────

def main() -> int:
    ap = argparse.ArgumentParser(description="Rendprop marketing reel asset generator")
    ap.add_argument("--listing", help="JSON file with the listing copy (see --write-example)")
    ap.add_argument("--clip", default="clip.mp4", help="agent walkthrough clip for render.sh")
    ap.add_argument("--out", default="out", help="output directory (created if missing)")
    ap.add_argument("--mark", default=str(DEFAULT_MARK), help="brand mark SVG")
    ap.add_argument("--write-example", metavar="PATH",
                    help="write a template listing JSON and exit")
    args = ap.parse_args()

    if args.write_example:
        Path(args.write_example).write_text(json.dumps(EXAMPLE_LISTING, indent=2) + "\n")
        print(f"wrote {args.write_example}")
        return 0

    listing = dict(EXAMPLE_LISTING)
    if args.listing:
        try:
            listing.update(json.loads(Path(args.listing).read_text()))
        except (OSError, ValueError) as e:
            return int(bool(sys.stderr.write(f"FATAL: could not read {args.listing}: {e}\n"))) or 1
    else:
        print("· no --listing given — using the demo listing (see --write-example)")

    out = Path(args.out).resolve()
    made = build(listing, out, Path(args.mark).expanduser())
    script = write_render_script(out, Path(args.clip), listing)
    print(f"assets generated in {out}: {sorted(made)}")
    print(f"composite with: bash {script} <clip.mp4> [out.mp4]")
    if not shutil.which("ffmpeg"):
        print("  ⚠ ffmpeg is not on PATH — render.sh will not run here")
    return 0


if __name__ == "__main__":
    sys.exit(main())
