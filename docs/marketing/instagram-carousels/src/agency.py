import os as _os; _HERE=_os.path.dirname(_os.path.abspath(__file__))
"""Carousel layouts, v2 — built around real app UI rather than text cards."""
import sys; sys.path.insert(0,_os.path.dirname(_os.path.abspath(__file__)))
from PIL import Image, ImageDraw, ImageFilter
from slidekit import *
from device import frame, CLEAN, DETAIL

M, CW = 84, W-168

def new(seed): 
    img = ground("dark", seed); return img, ImageDraw.Draw(img)

def eyebrow(d, n, feature, y=140):
    txt = feature.upper(); f = XBOLD(26); x = M
    for ch in txt: d.text((x,y), ch, font=f, fill=LAVENDER); x += d.textlength(ch,font=f)+3.2
    return y+52

def detail(key, width, radius=0.045):
    shot, cr = DETAIL[key]
    return frame(shot, width, crop=cr, radius_ratio=radius, bezel_ratio=0.012, glare=False)

def device(shot, width):
    return frame(shot, width, crop=CLEAN.get(shot))

def foot(img, d, n=None, total=None, swipe_on=False):
    mk = mark(54); img.alpha_composite(mk, (M, H-112))
    d.text((M+72, H-100), "RENDPROP", font=XBOLD(25), fill=PAPER)
    if swipe_on:
        x=W-M
        t="SWIPE"; f=XBOLD(23)
        d.text((x-d.textlength(t,font=f)-56, H-98), t, font=f, fill=LAVENDER)
        for i,dx in enumerate((0,14,28)):
            d.polygon([(x-42+dx,H-96),(x-42+dx,H-76),(x-32+dx,H-86)],
                      fill=LAVENDER if i==2 else (104,88,142))
    elif n:
        t=f"{n}/{total}"; f=BOLD(25)
        d.text((W-M-d.textlength(t,font=f), H-98), t, font=f, fill=MUTED)

# ── 1. HERO: headline, then the real app bleeding off the bottom ─────────────
def L_hero(n, total, feature, headline, sub, shot):
    img, d = new(n)
    y = eyebrow(d, n, feature); rule(d, M, y+6, 120); y += 46
    hh = measure(d, headline, HEAD, 86, CW, 300, leading=1.02)
    y = block(img, d, headline, HEAD, 86, M, y, CW, 300, PAPER, leading=1.02) + 34
    y = block(img, d, sub, BODY, 33, M, y, CW-80, 130, MUTED, leading=1.42) + 54
    # The device is the hero: seat it under the copy and let it run off the
    # bottom edge, which reads as "there is more of this" in a feed.
    dev = device(shot, 560)
    avail = (H - 132) - y
    if dev.height > avail + 180:          # a little bleed is good, a lot is a mistake
        dev = dev.crop((0, 0, dev.width, avail + 180))
    img.alpha_composite(dev, ((W-dev.width)//2, y))
    foot(img, d, swipe_on=True); return img

# ── 2. SHOWCASE: one real UI crop, big, with a label ─────────────────────────
def L_showcase(n, total, feature, title, caption, key, idx, width=880):
    """Words first, then the real UI sized to whatever height is left. Sizing the
    crop to the space — rather than dropping it at a fixed y and hoping — is what
    stops a tall screenshot pushing its own caption under the footer."""
    img, d = new(n+idx)
    y = eyebrow(d, n, feature) + 8
    y = block(img, d, title, HEAD, 60, M, y, CW, 150, PAPER, leading=1.05) + 14
    y = block(img, d, caption, BODY, 32, M, y, CW-30, 160, MUTED, leading=1.42) + 44

    avail_h = (H - 150) - y
    ui = detail(key, width)
    if ui.height > avail_h:
        scale = avail_h / ui.height
        ui = ui.resize((max(1,int(ui.width*scale)), max(1,int(ui.height*scale))), Image.LANCZOS)
    img.alpha_composite(ui, ((W-ui.width)//2, y + (avail_h-ui.height)//2))
    foot(img, d, idx+2, total); return img

# ── 3. STATEMENT ─────────────────────────────────────────────────────────────
def L_statement(n, total, feature, headline, sub, idx):
    img, d = new(n+idx); eyebrow(d, n, feature)
    lines = headline.split("\n"); size = 124
    while size > 52 and any(d.textlength(l, font=HEAD(size)) > CW for l in lines): size -= 4
    f = HEAD(size); lh = int(size*1.02); y = int(H*0.29)
    for i,l in enumerate(lines): d.text((M, y+i*lh), l, font=f, fill=PAPER)
    y += len(lines)*lh + 44; rule(d, M, y, 120); y += 52
    block(img, d, sub, BODY, 37, M, y, CW-30, 300, MUTED, leading=1.44)
    foot(img, d, idx+2, total); return img

# ── 4. STEPS beside a device ─────────────────────────────────────────────────
def L_steps(n, total, feature, title, items, shot, idx):
    img, d = new(n+idx); eyebrow(d, n, feature)
    y = 236
    y = block(img, d, title, HEAD, 62, M, y, CW, 150, PAPER) + 44
    for i,it in enumerate(items):
        th = measure(d, it, BODY, 33, 470, 200, leading=1.32)
        d.ellipse([M, y, M+50, y+50], fill=VIOLET if i%2==0 else MID)
        num=str(i+1); f=XBOLD(26)
        d.text((M+25-d.textlength(num,font=f)/2, y+11), num, font=f, fill=PAPER)
        block(img, d, it, BODY, 33, M+74, y+2, 470, 200, PAPER, leading=1.32)
        y += max(th, 50) + 30
    dev = device(shot, 400)
    img.alpha_composite(dev, (W-dev.width+62, H-dev.height-60))
    foot(img, d, idx+2, total); return img

# ── 5. TWO UI crops stacked, compare/contrast ────────────────────────────────
def L_pair(n, total, feature, title, a, b, idx):
    img, d = new(n+idx); eyebrow(d, n, feature)
    y = 232
    y = block(img, d, title, HEAD, 62, M, y, CW, 150, PAPER) + 40
    for (lbl, key) in (a, b):
        ui = detail(key, 720)
        img.alpha_composite(ui, ((W-ui.width)//2, y))
        y += ui.height + 12
        f = BOLD(28); d.text(((W-d.textlength(lbl,font=f))//2, y), lbl, font=f, fill=LAVENDER)
        y += 54
    foot(img, d, idx+2, total); return img

# ── 6. POINTS (kept, for the policy carousels) ───────────────────────────────
def L_points(n, total, feature, title, items, idx):
    img, d = new(n+idx); eyebrow(d, n, feature)
    th = measure(d, title, HEAD, 66, CW, 200)
    body = sum(measure(d, it, BODY, 37, CW-108, 260, leading=1.36)+66+22 for it in items)
    TOP, BOT = 250, H-180
    y = max(TOP, TOP + ((BOT-TOP)-(th+50+body))//2)
    y = block(img, d, title, HEAD, 66, M, y, CW, 200, PAPER) + 50
    for it in items:
        h = measure(d, it, BODY, 37, CW-108, 260, leading=1.36) + 66
        d.rounded_rectangle([M,y,W-M,y+h], radius=24, fill=(19,21,29), outline=(36,33,55), width=2)
        d.ellipse([M+24,y+h//2-8,M+40,y+h//2+8], fill=VIOLET)
        block(img, d, it, BODY, 37, M+64, y+33, CW-108, 260, PAPER, leading=1.36)
        y += h + 22
    foot(img, d, idx+2, total); return img

# ── 7. CTA ───────────────────────────────────────────────────────────────────
def L_cta(n, total, shot="02-home-showroom"):
    img, d = new(n+9)
    # the device, low and dimmed, as texture behind the close — never competing
    dev = device(shot, 560)
    faded = Image.new("RGBA", dev.size, (0,0,0,0))
    faded.paste(dev, (0,0), dev)
    alpha = faded.getchannel("A").point(lambda v: int(v*0.30))
    faded.putalpha(alpha)
    img.alpha_composite(faded, ((W-dev.width)//2, H-int(dev.height*0.62)))
    scrim = Image.new("RGBA",(W,H),(0,0,0,0))
    ImageDraw.Draw(scrim).rectangle([0,0,W,int(H*0.62)], fill=(11,13,16,170))
    img.alpha_composite(scrim.filter(ImageFilter.GaussianBlur(60)))
    y = 210
    mk = mark(150); img.alpha_composite(mk, ((W-mk.width)//2, y)); y += mk.height+34
    t="RENDPROP"; f=HEAD(62); d.text(((W-d.textlength(t,font=f))//2,y), t, font=f, fill=PAPER); y+=96
    t2="Win the listing. Skip the film crew."; f2=BODY(34)
    d.text(((W-d.textlength(t2,font=f2))//2,y), t2, font=f2, fill=MUTED); y+=76
    bw,bh=520,92; bx=(W-bw)//2
    d.rounded_rectangle([bx,y,bx+bw,y+bh], radius=bh//2, fill=VIOLET)
    t3="Free for 7 days"; f3=XBOLD(34)
    d.text((bx+(bw-d.textlength(t3,font=f3))//2, y+26), t3, font=f3, fill=PAPER); y+=bh+30
    t4="Link in bio  ·  @rendprop"; f4=BOLD(27)
    d.text(((W-d.textlength(t4,font=f4))//2,y), t4, font=f4, fill=LAVENDER)
    return img

from uikit import photo, screen_photo_studio, screen_tour, P

# ── PHOTO HERO: the property, full bleed, copy over a graduated scrim ────────
def L_photo_hero(n, total, feature, headline, sub, key, focus=0.5):
    img = Image.new("RGBA",(W,H),(11,13,16,255))
    ph = photo(W, H, key, focus); img.paste(ph,(0,0))
    sc = Image.new("RGBA",(W,H),(0,0,0,0)); sd = ImageDraw.Draw(sc)
    sd.rectangle([0,0,W,int(H*0.20)], fill=(0,0,0,175))
    N=18; y0=int(H*0.34)
    for i in range(N):
        ya=y0+int((H-y0)*i/N); yb=y0+int((H-y0)*(i+1)/N)
        sd.rectangle([0,ya,W,yb], fill=(0,0,0,int(6+i*12)))
    img.alpha_composite(sc.filter(ImageFilter.GaussianBlur(26)))
    d = ImageDraw.Draw(img)
    y = eyebrow(d, n, feature, y=104); rule(d, M, y+2, 120)
    hh = measure(d, headline, HEAD, 92, CW, 400, leading=1.02)
    sh = measure(d, sub, BODY, 34, CW-70, 160, leading=1.42)
    y = H - 200 - sh - 26 - hh
    y = block(img, d, headline, HEAD, 92, M, y, CW, 400, PAPER, leading=1.02) + 26
    block(img, d, sub, BODY, 34, M, y, CW-70, 160, (222,222,232), leading=1.42)
    foot(img, d, swipe_on=True); return img

# ── BEFORE / AFTER: the highest-performing format in this category ──────────
def L_before_after(n, total, feature, title, before_key, after_key, idx,
                   before_lbl="BEFORE", after_lbl="ONE TAP LATER"):
    img, d = new(n+idx); eyebrow(d, n, feature)
    y = 226
    y = block(img, d, title, HEAD, 60, M, y, CW, 140, PAPER, leading=1.05) + 34
    # size the two cards to the space that is actually left, so the second one
    # never slides under the footer
    cw = CW
    avail = (H - 160) - y
    chh = min(int(cw*0.62), (avail - 22)//2)
    r = 26
    for lbl, key, accent in ((before_lbl, before_key, (110,112,126)),
                             (after_lbl,  after_key,  VIOLET)):
        ph = photo(cw, chh, key)
        m = Image.new("L",(cw,chh),0); ImageDraw.Draw(m).rounded_rectangle([0,0,cw-1,chh-1], radius=r, fill=255)
        img.paste(ph,(M,y),m)
        d = ImageDraw.Draw(img)
        f = XBOLD(24); tw_ = d.textlength(lbl, font=f)
        d.rounded_rectangle([M+22, y+22, M+22+tw_+44, y+70], radius=24, fill=accent)
        d.text((M+44, y+34), lbl, font=f, fill=PAPER)
        y += chh + 22
    foot(img, d, idx+2, total); return img

# ── APP: a drawn screen in a device, beside the copy ────────────────────────
def L_app(n, total, feature, title, caption, which, idx, highlight=None):
    img, d = new(n+idx)
    y = eyebrow(d, n, feature) + 6
    y = block(img, d, title, HEAD, 58, M, y, CW, 140, PAPER, leading=1.05) + 12
    y = block(img, d, caption, BODY, 31, M, y, CW-40, 150, MUTED, leading=1.42) + 34
    scr = screen_photo_studio(620,1340,highlight=highlight) if which=="studio" else screen_tour(620,1340)
    dev = frame(scr, 520)
    avail = (H-150) - y
    if dev.height > avail:
        s = avail/dev.height
        dev = dev.resize((int(dev.width*s), int(dev.height*s)), Image.LANCZOS)
    img.alpha_composite(dev, ((W-dev.width)//2, y))
    foot(img, d, idx+2, total); return img

# ── CTA over the property ───────────────────────────────────────────────────
def L_cta2(n, total, key="ext_twilight"):
    img = Image.new("RGBA",(W,H),(11,13,16,255))
    img.paste(photo(W,H,key),(0,0))
    sc = Image.new("RGBA",(W,H),(0,0,0,0)); ImageDraw.Draw(sc).rectangle([0,0,W,H], fill=(9,10,14,190))
    img.alpha_composite(sc)
    d = ImageDraw.Draw(img)
    y = 300
    mk = mark(150); img.alpha_composite(mk, ((W-mk.width)//2, y)); y += mk.height + 34
    t="RENDPROP"; f=HEAD(62); d.text(((W-d.textlength(t,font=f))//2,y), t, font=f, fill=PAPER); y += 100
    t2="Win the listing. Skip the film crew."; f2=BODY(35)
    d.text(((W-d.textlength(t2,font=f2))//2,y), t2, font=f2, fill=(214,214,226)); y += 86
    bw,bh=540,98; bx=(W-bw)//2
    d.rounded_rectangle([bx,y,bx+bw,y+bh], radius=bh//2, fill=VIOLET)
    t3="Free for 7 days"; f3=XBOLD(35)
    d.text((bx+(bw-d.textlength(t3,font=f3))//2, y+28), t3, font=f3, fill=PAPER); y += bh+34
    t4="Link in bio  ·  @rendprop"; f4=BOLD(28)
    d.text(((W-d.textlength(t4,font=f4))//2,y), t4, font=f4, fill=LAVENDER)
    foot(img, d); return img
