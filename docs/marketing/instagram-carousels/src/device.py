"""A real iPhone frame. A screenshot floating on a colour is what a founder
makes; a properly bezelled device with a soft contact shadow is what an agency
ships. Corner radius, bezel width and shadow falloff are all proportional so the
frame holds at any size."""
from PIL import Image, ImageDraw, ImageFilter

SHOTS = "/mnt/user-data/uploads/Rendprop AI/repo/docs/appstore/screenshots/6.9/"

def frame(shot, width, crop=None, radius_ratio=0.092, bezel_ratio=0.028,
          shadow=True, glare=True):
    im = shot if isinstance(shot, Image.Image) else Image.open(SHOTS + shot + ".png").convert("RGB")
    if crop: im = im.crop(crop)
    sw = width
    sh = int(im.height * sw / im.width)
    im = im.resize((sw, sh), Image.LANCZOS)

    r = int(sw * radius_ratio)
    m = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, sw-1, sh-1], radius=r, fill=255)
    screen = Image.new("RGBA", (sw, sh), (0,0,0,0)); screen.paste(im, (0,0), m)

    b = max(3, int(sw * bezel_ratio))
    fw, fh = sw + b*2, sh + b*2
    fr = r + b
    dev = Image.new("RGBA", (fw, fh), (0,0,0,0))
    dd = ImageDraw.Draw(dev)
    dd.rounded_rectangle([0,0,fw-1,fh-1], radius=fr, fill=(26,27,32,255))
    dd.rounded_rectangle([1,1,fw-2,fh-2], radius=fr-1, outline=(72,74,84,255), width=max(1,b//4))
    dev.alpha_composite(screen, (b,b))

    if glare:   # one soft diagonal highlight across the glass, low opacity
        g = Image.new("L", (fw, fh), 0)
        ImageDraw.Draw(g).polygon([(0,int(fh*0.10)),(fw,int(-fh*0.16)),
                                   (fw,int(fh*0.10)),(0,int(fh*0.36))], fill=26)
        g = g.filter(ImageFilter.GaussianBlur(fw//22))
        mask = Image.new("L",(fw,fh),0)
        ImageDraw.Draw(mask).rounded_rectangle([0,0,fw-1,fh-1], radius=fr, fill=255)
        g = Image.composite(g, Image.new("L",(fw,fh),0), mask)
        white = Image.new("RGBA",(fw,fh),(255,255,255,0)); white.putalpha(g)
        dev.alpha_composite(white)

    if not shadow: return dev
    pad = int(fw*0.20)
    out = Image.new("RGBA", (fw+pad*2, fh+pad*2), (0,0,0,0))
    sh_l = Image.new("L", out.size, 0)
    ImageDraw.Draw(sh_l).rounded_rectangle(
        [pad, pad+int(fh*0.035), pad+fw, pad+fh+int(fh*0.035)], radius=fr, fill=150)
    sh_l = sh_l.filter(ImageFilter.GaussianBlur(pad//2))
    shadow_im = Image.new("RGBA", out.size, (0,0,0,0)); shadow_im.putalpha(sh_l)
    out.alpha_composite(shadow_im)
    out.alpha_composite(dev, (pad, pad))
    return out

# Clean crops. Two of the five captures are mid-scroll and have overlap seams at
# the edges; these bands are the artefact-free part of each.
CLEAN = {
 "01-published-tour": None,
 "02-home-showroom":  (0, 0, 1320, 2180),
 "03-sample-tour":    (0, 330, 1320, 2420),
 "04-photo-studio":   None,
 "05-new-home":       None,
}
# Feature-specific detail crops — the actual control that does the thing.
DETAIL = {
 "photo-chips": ("04-photo-studio",   (30, 1560, 1290, 2030)),
 "photo-hero":  ("04-photo-studio",   (30,  560, 1290, 1180)),
 "toolbox":     ("03-sample-tour",    (20,  360, 1300, 1170)),
 "leads":       ("03-sample-tour",    (20, 1150, 1300, 1400)),
 "sample-tour": ("03-sample-tour",    (20, 1500, 1300, 2300)),
 "hero-card":   ("02-home-showroom",  (40,  330, 1280,  980)),
 "capture":     ("05-new-home",       (30,  980, 1290, 1560)),
 "tour-page":   ("01-published-tour", (0,   860, 1320, 1900)),
}
