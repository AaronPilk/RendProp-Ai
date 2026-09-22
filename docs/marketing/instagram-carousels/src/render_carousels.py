import os as _os; _HERE=_os.path.dirname(_os.path.abspath(__file__))
import sys, os, re, json
sys.path.insert(0,_os.path.dirname(_os.path.abspath(__file__)))
from PIL import Image, ImageDraw
from slidekit import *
from carousel_copy import C

OUT = _os.path.join(_HERE,"..","out")
M = 84                      # margin
CW = W - M*2                # content width
warnings = []

def new(seed):
    img = ground("dark", seed); return img, ImageDraw.Draw(img)

def eyebrow(draw, n, feature, y=150):
    txt = f"{n:02d}  ·  {feature.upper()}"
    f = XBOLD(27); x = M
    for ch in txt:
        draw.text((x,y), ch, font=f, fill=LAVENDER); x += draw.textlength(ch,font=f)+3.2
    return y + 56

# ── slide 1 ──────────────────────────────────────────────────────────────────
def s_hook(c, n, total):
    img, d = new(n)
    y = eyebrow(d, n, c["feature"])
    rule(d, M, y+8, 132); y += 52
    y = block(img, d, c["hook"], HEAD, 104, M, y, CW, 560, PAPER, leading=1.03)
    y += 64
    block(img, d, c["sub"], BODY, 40, M, y, CW-40, 300, MUTED, leading=1.42)
    footer(img, d); swipe(d)
    return img

# ── numbered steps ───────────────────────────────────────────────────────────
def s_steps(c, n, total, title, items, idx):
    img, d = new(n+idx)
    eyebrow(d, n, c["feature"])
    th = measure(d, title, HEAD, 74, CW, 220, leading=1.06)
    body_h = sum(max(measure(d, it, BODY, 37, CW-92, 200, leading=1.34), 58) + 40 for it in items)
    TOP, BOT = 250, H-180
    y = max(TOP, TOP + ((BOT-TOP) - (th + 60 + body_h))//2)
    y = block(img, d, title, HEAD, 74, M, y, CW, 220, PAPER, leading=1.06) + 60
    for i, it in enumerate(items):
        d.ellipse([M, y, M+58, y+58], fill=(VIOLET if i%2==0 else MID))
        num = str(i+1); f = XBOLD(30)
        d.text((M+29-d.textlength(num,font=f)/2, y+13), num, font=f, fill=PAPER)
        yy = block(img, d, it, BODY, 37, M+92, y+2, CW-92, 200, PAPER, leading=1.34)
        y = max(yy, y+58) + 40
    if y > H-170: warnings.append(f"{c['slug']} steps overflow y={y}")
    footer(img, d, idx+2, total); return img

# ── the big statement ────────────────────────────────────────────────────────
def s_big(c, n, total, headline, sub, idx):
    img, d = new(n+idx)
    y = eyebrow(d, n, c["feature"])
    lines = headline.split("\n")
    size = 128
    while size > 50 and any(d.textlength(l, font=HEAD(size)) > CW for l in lines): size -= 4
    f = HEAD(size); lh = int(size*1.02)
    y = int(H*0.30)
    for i,l in enumerate(lines):
        d.text((M, y+i*lh), l, font=f, fill=PAPER)
    y += len(lines)*lh + 46
    rule(d, M, y, 132); y += 54
    block(img, d, sub, BODY, 38, M, y, CW-30, 300, MUTED, leading=1.44)
    footer(img, d, idx+2, total); return img

# ── three points ─────────────────────────────────────────────────────────────
def s_points(c, n, total, title, items, idx):
    img, d = new(n+idx)
    eyebrow(d, n, c["feature"])
    th = measure(d, title, HEAD, 74, CW, 220, leading=1.06)
    body_h = sum(measure(d, it, BODY, 39, CW-108, 260, leading=1.36) + 68 + 24 for it in items)
    TOP, BOT = 250, H-180
    y = max(TOP, TOP + ((BOT-TOP) - (th + 56 + body_h))//2)
    y = block(img, d, title, HEAD, 74, M, y, CW, 220, PAPER, leading=1.06) + 56
    for it in items:
        # size the card to the text, rather than cramming the text into a card
        th  = measure(d, it, BODY, 39, CW-108, 260, leading=1.36)
        hgt = th + 68
        d.rounded_rectangle([M, y, W-M, y+hgt], radius=26,
                            fill=(20,22,30), outline=(38,34,58), width=2)
        d.ellipse([M+24, y+hgt//2-8, M+40, y+hgt//2+8], fill=VIOLET)
        block(img, d, it, BODY, 39, M+64, y+34, CW-108, 260, PAPER, leading=1.36)
        y += hgt + 24
    if y > H-170: warnings.append(f"{c['slug']} points overflow y={y}")
    footer(img, d, idx+2, total); return img

# ── the disclosure slide ─────────────────────────────────────────────────────
def s_disclose(c, n, total, title, body, idx):
    img, d = new(n+idx)
    y = eyebrow(d, n, c["feature"])
    y = int(H*0.30)
    d.rounded_rectangle([M, y, W-M, y+300], radius=32, fill=(24,20,44), outline=VIOLET, width=3)
    chip = "VIRTUALLY STAGED"
    cw = d.textlength(chip, font=XBOLD(26))
    d.rounded_rectangle([M+40, y+44, M+40+cw+96, y+96], radius=26, fill=VIOLET)
    # the four-point star, drawn rather than typed — Inter has no U+2726
    sx, sy, s = M+72, y+70, 11
    d.polygon([(sx, sy-s), (sx+s*0.32, sy-s*0.32), (sx+s, sy),
               (sx+s*0.32, sy+s*0.32), (sx, sy+s), (sx-s*0.32, sy+s*0.32),
               (sx-s, sy), (sx-s*0.32, sy-s*0.32)], fill=PAPER)
    d.text((M+94, y+56), chip, font=XBOLD(26), fill=PAPER)
    block(img, d, title, HEAD, 56, M+40, y+128, CW-80, 90, PAPER)
    yy = y + 340
    block(img, d, body, BODY, 38, M, yy, CW-30, 340, MUTED, leading=1.44)
    footer(img, d, idx+2, total); return img

# ── the pricing slide ────────────────────────────────────────────────────────
def s_plans(c, n, total, title, rows, idx):
    img, d = new(n+idx)
    eyebrow(d, n, c["feature"])
    th = measure(d, title, HEAD, 74, CW, 200)
    TOP, BOT = 250, H-180
    y = max(TOP, TOP + ((BOT-TOP) - (th + 54 + len(rows)*236))//2)
    y = block(img, d, title, HEAD, 74, M, y, CW, 200, PAPER) + 54
    for i,(name, price, detail) in enumerate(rows):
        top = y
        hgt = 214
        d.rounded_rectangle([M, top, W-M, top+hgt], radius=28,
                            fill=(26,22,48) if i==1 else (20,22,30),
                            outline=(VIOLET if i==1 else (38,34,58)), width=3 if i==1 else 2)
        d.text((M+36, top+30), name, font=XBOLD(32), fill=LAVENDER)
        pf = HEAD(52)
        d.text((W-M-36-d.textlength(price,font=pf), top+22), price, font=pf, fill=PAPER)
        block(img, d, detail, BODY, 30, M+36, top+92, CW-72, 110, MUTED, leading=1.36)
        y = top + hgt + 22
    if y > H-170: warnings.append(f"{c['slug']} plans overflow y={y}")
    footer(img, d, idx+2, total); return img

# ── the close ────────────────────────────────────────────────────────────────
def s_cta(c, n, total):
    img, d = new(n+9)
    mk = mark(300); img.alpha_composite(mk, ((W-mk.width)//2, int(H*0.22)))
    y = int(H*0.22) + mk.height + 60
    t = "RENDPROP"; f = HEAD(76)
    d.text(((W-d.textlength(t,font=f))//2, y), t, font=f, fill=PAPER); y += 118
    t2 = "Win the listing. Skip the film crew."
    f2 = BODY(38); d.text(((W-d.textlength(t2,font=f2))//2, y), t2, font=f2, fill=MUTED); y += 96
    btn_w, btn_h = 560, 104
    bx = (W-btn_w)//2
    d.rounded_rectangle([bx, y, bx+btn_w, y+btn_h], radius=btn_h//2, fill=VIOLET)
    t3 = "Try it free for 7 days"; f3 = XBOLD(36)
    d.text((bx+(btn_w-d.textlength(t3,font=f3))//2, y+30), t3, font=f3, fill=PAPER)
    y += btn_h + 44
    t4 = "Link in bio  ·  @rendprop"; f4 = BOLD(30)
    d.text(((W-d.textlength(t4,font=f4))//2, y), t4, font=f4, fill=LAVENDER)
    footer(img, d, total, total); return img

# ── run ──────────────────────────────────────────────────────────────────────
made = 0
index = []
for i, c in enumerate(C, start=1):
    total = len(c["slides"]) + 2
    folder = os.path.join(OUT, f"reel-{i:02d}-{c['slug']}")
    os.makedirs(folder, exist_ok=True)
    slides = [("hook", s_hook(c, i, total))]
    for j, sl in enumerate(c["slides"]):
        kind = sl[0]
        if kind == "steps":     im = s_steps(c, i, total, sl[1], sl[2], j)
        elif kind == "big":     im = s_big(c, i, total, sl[1], sl[2], j)
        elif kind == "points":  im = s_points(c, i, total, sl[1], sl[2], j)
        elif kind == "disclose":im = s_disclose(c, i, total, sl[1], sl[2], j)
        elif kind == "plans":   im = s_plans(c, i, total, sl[1], sl[2], j)
        else: raise SystemExit("unknown slide kind "+kind)
        slides.append((kind, im))
    slides.append(("cta", s_cta(c, i, total)))
    for k,(kind, im) in enumerate(slides, start=1):
        p = os.path.join(folder, f"{k:02d}-{kind}.png")
        im.convert("RGB").save(p, quality=95); made += 1
    index.append({"n":i,"feature":c["feature"],"slug":c["slug"],"slides":len(slides),"folder":os.path.basename(folder)})

json.dump(index, open(os.path.join(OUT,"index.json"),"w"), indent=1)
print(f"rendered {made} slides across {len(C)} carousels")
print("overflow warnings:", len(warnings))
for w in warnings[:10]: print("  ", w)
