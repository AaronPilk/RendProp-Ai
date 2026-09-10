import os as _os; _HERE=_os.path.dirname(_os.path.abspath(__file__))
"""Rendprop UI, redrawn as artwork.

Not screenshot crops. Every screen here is composed from the real app's own
layout, colours and copy, drawn at whatever resolution the slide needs — so a
carousel never contains a fragment of sky, a compression seam, or a status bar
that happens to be in shot.
"""
import sys; sys.path.insert(0,_os.path.dirname(_os.path.abspath(__file__)))
from PIL import Image, ImageDraw, ImageFilter, ImageFont

FDIR = _os.path.join(_HERE,"fonts")+"/"
SHOTS = "/mnt/user-data/uploads/Rendprop AI/repo/docs/appstore/screenshots/6.9/"
UI  = lambda s: ImageFont.truetype(FDIR+"Inter-2.ttf", s)   # regular
UIS = lambda s: ImageFont.truetype(FDIR+"Inter-1.ttf", s)   # semibold
UIB = lambda s: ImageFont.truetype(FDIR+"Inter-0.ttf", s)   # extrabold

WHITE=(255,255,255); INK=(17,19,24); GREY=(122,126,138); LINE=(232,233,238)
VIOLET=(124,58,237); VIOLET_L=(160,110,245)

PHOTO_DIR = _os.path.join(_HERE,"photos")+"/"

# Real estate photography generated for this brand: a single modern home shot
# once, then edited so each before/after pair is the SAME house, same camera,
# same framing, with only the advertised change. That is what makes a sky or a
# staging claim legible in a feed — a different house on each side proves
# nothing.
P = {
 "ext_before":  "ext-grey.jpg",       "ext_blue":   "ext-blue.jpg",
 "ext_twilight":"ext-twilight.jpg",   "ext_lawn":   "ext-lawn.jpg",
 "great_room":  "great-room.jpg",     "kitchen":    "kitchen.jpg",
 "living_before":"living-cluttered.jpg","living_after":"living-tidy.jpg",
 "room_before": "room-empty.jpg",     "room_after": "room-staged.jpg",
 "ranch":       "ranch.jpg",          "bedroom":    "bedroom.jpg",
 "bath":        "bath.jpg",           "dining":     "dining.jpg",
 "pool":        "pool.jpg",           "townhouse":  "townhouse.jpg",
 "venue":       "venue.jpg",          "office":     "office.jpg",
}
_pc = {}
def photo(w, h, key="great_room", focus=0.5):
    """A listing photo, filled to the box.

    focus is where the crop sits vertically: 0.0 keeps the top of the frame,
    1.0 keeps the bottom, 0.5 is centred. It matters because Instagram crops
    a 4:5 post to a square from the middle for the profile grid, so whatever
    sits in the middle of the frame is the tile. On the sky and lawn posts
    that has to be the sky, or the lawn, or the two exterior tiles come out
    identical in the grid."""
    if key not in _pc: _pc[key] = Image.open(PHOTO_DIR + P[key]).convert("RGB")
    im = _pc[key]
    sc = max(w/im.width, h/im.height)
    im = im.resize((max(1,int(im.width*sc)), max(1,int(im.height*sc))), Image.LANCZOS)
    x=(im.width-w)//2
    y=int((im.height-h)*min(1.0, max(0.0, focus)))
    return im.crop((x,y,x+w,y+h))


def _rr(d, box, r, **kw): d.rounded_rectangle(box, radius=r, **kw)

def status_bar(d, w, y, dark=False):
    c = WHITE if dark else INK
    d.text((int(w*0.085), y), "9:41", font=UIB(int(w*0.038)), fill=c)
    bx = int(w*0.80)
    for i,hh in enumerate((5,8,11,14)):
        d.rectangle([bx+i*int(w*0.016), y+int(w*0.030)-hh, bx+i*int(w*0.016)+int(w*0.010), y+int(w*0.030)], fill=c)
    bx2 = int(w*0.885)
    _rr(d,[bx2,y+int(w*0.006),bx2+int(w*0.052),y+int(w*0.030)], int(w*0.008), outline=c, width=2)
    d.rectangle([bx2+2,y+int(w*0.009),bx2+int(w*0.040),y+int(w*0.027)], fill=(52,199,89))

def nav_bar(d, w, y, title, back=True):
    if back:
        x=int(w*0.085); m=int(w*0.020)
        d.line([(x+m,y),(x,y+m),(x+m,y+m*2)], fill=VIOLET, width=max(2,int(w*0.007)))
    f=UIS(int(w*0.044)); d.text(((w-d.textlength(title,font=f))//2, y-int(w*0.012)), title, font=f, fill=INK)

def tab_bar(img, d, w, h):
    yb = h-int(w*0.20)
    d.rectangle([0,yb,w,h], fill=(250,250,252))
    d.line([(0,yb),(w,yb)], fill=LINE, width=2)
    labels=["Home","Homes","Profile","Settings"]
    for i,l in enumerate(labels):
        cx=int(w*(0.155+i*0.23)); active = i==0
        if active: _rr(d,[cx-int(w*0.075),yb+int(w*0.028),cx+int(w*0.075),yb+int(w*0.115)], int(w*0.030), fill=(240,235,254))
        d.ellipse([cx-int(w*0.026),yb+int(w*0.040),cx+int(w*0.026),yb+int(w*0.092)],
                  fill=VIOLET if active else (150,152,164))
        f=UI(int(w*0.028)); d.text((cx-d.textlength(l,font=f)/2, yb+int(w*0.100)), l, font=f,
                                   fill=VIOLET if active else (150,152,164))

# ── Screens ──────────────────────────────────────────────────────────────────
def screen_photo_studio(w, h, highlight=None):
    img = Image.new("RGB",(w,h),WHITE); d = ImageDraw.Draw(img)
    status_bar(d,w,int(w*0.055)); nav_bar(d,w,int(w*0.155),"AI Photo Studio")
    f=UI(int(w*0.030)); t="24 Willow Bend Court"
    d.text(((w-d.textlength(t,font=f))//2,int(w*0.205)), t, font=f, fill=GREY)
    y=int(w*0.28)
    for i,(lab,col) in enumerate((("Add photos",VIOLET),("Take a photo",(240,236,253)))):
        x0=int(w*0.055)+i*int(w*0.475); x1=x0+int(w*0.415)
        _rr(d,[x0,y,x1,y+int(w*0.115)], int(w*0.032), fill=col)
        fc = WHITE if i==0 else VIOLET
        f2=UIS(int(w*0.038)); d.text((x0+(x1-x0-d.textlength(lab,font=f2))/2, y+int(w*0.036)), lab, font=f2, fill=fc)
    y += int(w*0.175)
    ph = photo(int(w*0.89), int(w*0.60), "ext_before")
    m = Image.new("L", ph.size, 0); ImageDraw.Draw(m).rounded_rectangle([0,0,ph.size[0]-1,ph.size[1]-1], radius=int(w*0.045), fill=255)
    img.paste(ph, (int(w*0.055), y), m)
    y += int(w*0.60) + int(w*0.055)
    f3=UIS(int(w*0.036)); d.text((int(w*0.055), y), "One tap", font=f3, fill=INK); y += int(w*0.062)
    chips=[("Make it twilight",(96,84,190)),("Make the sky blue",(74,144,226)),
           ("Make the lawn green",(56,168,110)),("Tidy the room",(150,110,230)),
           ("Add furniture",(224,120,86)),("Turn it into video",(200,80,150))]
    cw=int(w*0.435); ch=int(w*0.088); gap=int(w*0.020)
    for i,(lab,col) in enumerate(chips):
        cx=int(w*0.055)+(i%2)*(cw+gap); cy=y+(i//2)*(ch+gap)
        on = highlight is not None and i==highlight
        _rr(d,[cx,cy,cx+cw,cy+ch], int(ch//2), fill=(243,240,252) if not on else (237,229,254),
            outline=VIOLET if on else (238,238,244), width=3 if on else 2)
        d.ellipse([cx+int(w*0.020),cy+ch//2-int(w*0.016),cx+int(w*0.052),cy+ch//2+int(w*0.016)], fill=col)
        f4=UI(int(w*0.029)); d.text((cx+int(w*0.070), cy+ch//2-int(w*0.020)), lab, font=f4, fill=INK)
    y += 3*(ch+gap) + int(w*0.045)
    # the disclosure strip the app really shows under an edited photo
    _rr(d,[int(w*0.055),y,int(w*0.945),y+int(w*0.135)], int(w*0.036),
        fill=(246,243,254), outline=(230,222,250), width=2)
    sx, sy, s = int(w*0.100), y+int(w*0.048), int(w*0.016)
    d.polygon([(sx,sy-s),(sx+s*0.34,sy-s*0.34),(sx+s,sy),(sx+s*0.34,sy+s*0.34),
               (sx,sy+s),(sx-s*0.34,sy+s*0.34),(sx-s,sy),(sx-s*0.34,sy-s*0.34)], fill=VIOLET)
    f5=UIS(int(w*0.029)); d.text((int(w*0.135), y+int(w*0.030)), "Labelled on your tour", font=f5, fill=INK)
    f6=UI(int(w*0.026)); d.text((int(w*0.135), y+int(w*0.072)), "The untouched original is published beside it.",
                                font=f6, fill=GREY)
    tab_bar(img,d,w,h); return img

def screen_tour(w, h, chapter="Great room"):
    """The tour page, as the app presents it.

    The photograph is a LANDSCAPE card at its native aspect, not a full-bleed
    portrait fill. That is a deliberate call: the only clean photography in the
    shipped assets is wide, and forcing a 0.46 portrait out of a 3.2 letterbox
    crops onto whatever happens to be in the middle — a doorframe, a newel post.
    A sharp, well-composed card beats a stretched fill every time.
    """
    img = Image.new("RGB",(w,h),(12,13,17)); d=ImageDraw.Draw(img)
    status_bar(d,w,int(w*0.055), dark=True)
    f=UIS(int(w*0.042)); t_="Demo listing page"
    d.text(((w-d.textlength(t_,font=f))//2,int(w*0.150)), t_, font=f, fill=(236,236,242))
    x=int(w*0.075); m=int(w*0.020)
    d.line([(x+m,int(w*0.163)),(x,int(w*0.183)),(x+m,int(w*0.203))], fill=VIOLET_L, width=max(2,int(w*0.007)))

    # the hero card
    cy = int(w*0.255); cw=int(w*0.90); ch=int(cw*0.62)
    ph = photo(cw, ch, "great_room")
    mk = Image.new("L",(cw,ch),0); ImageDraw.Draw(mk).rounded_rectangle([0,0,cw-1,ch-1], radius=int(w*0.048), fill=255)
    img.paste(ph, (int(w*0.05), cy), mk)
    ov = Image.new("RGBA",(cw,ch),(0,0,0,0)); od=ImageDraw.Draw(ov)
    for i in range(12):
        ya=int(ch*0.55)+int(ch*0.45*i/12); yb=int(ch*0.55)+int(ch*0.45*(i+1)/12)
        od.rectangle([0,ya,cw,yb], fill=(0,0,0,int(8+i*13)))
    od.rectangle([0,0,cw,int(ch*0.30)], fill=(0,0,0,90))
    ovm=Image.new("RGBA",(cw,ch),(0,0,0,0)); ovm.paste(ov,(0,0),mk)
    img.paste(Image.alpha_composite(img.crop((int(w*0.05),cy,int(w*0.05)+cw,cy+ch)).convert("RGBA"), ovm).convert("RGB"), (int(w*0.05),cy))
    d=ImageDraw.Draw(img)
    fw_=UIB(int(w*0.026)); xx=int(w*0.09)
    for chn in "RENDPROP": d.text((xx,cy+int(w*0.045)), chn, font=fw_, fill=(255,255,255)); xx+=d.textlength(chn,font=fw_)+int(w*0.007)
    fp=UIB(int(w*0.052)); pr="$4,250,000"
    d.text((int(w*0.95)-d.textlength(pr,font=fp), cy+int(w*0.038)), pr, font=fp, fill=WHITE)
    fs=UI(int(w*0.026)); ss="5 bd · 6 ba · 6,200 sqft"
    d.text((int(w*0.95)-d.textlength(ss,font=fs), cy+int(w*0.098)), ss, font=fs, fill=(228,228,236))
    fe=UIB(int(w*0.024)); d.text((int(w*0.09), cy+ch-int(w*0.115)), "NOW SHOWING", font=fe, fill=(228,215,255))
    fc=UIB(int(w*0.060)); d.text((int(w*0.09), cy+ch-int(w*0.085)), chapter, font=fc, fill=WHITE)
    bx=int(w*0.62); _rr(d,[bx,cy+int(w*0.045),bx+int(w*0.0),cy+int(w*0.045)],1)

    y = cy + ch + int(w*0.055)
    fh=UI(int(w*0.030)); hint="↕  Scroll inside the video to fly through"
    d.text(((w-d.textlength(hint,font=fh))//2, y), hint, font=fh, fill=(150,152,166)); y += int(w*0.075)

    # the room rail
    f2=UIS(int(w*0.032)); d.text((int(w*0.06), y), "Rooms in this tour", font=f2, fill=(236,236,242)); y+=int(w*0.070)
    rooms=[("Arrival",0),("Great room",1),("Chef's kitchen",0),("Primary suite",0)]
    for r,on in rooms:
        fr=UI(int(w*0.030)); rw=d.textlength(r,font=fr)+int(w*0.090)
        _rr(d,[int(w*0.06),y,int(w*0.06)+rw,y+int(w*0.082)], int(w*0.041),
            fill=(38,32,62) if on else (26,28,36), outline=VIOLET if on else (44,46,58), width=2)
        d.ellipse([int(w*0.085),y+int(w*0.030),int(w*0.108),y+int(w*0.053)], fill=VIOLET_L if on else (92,95,110))
        d.text((int(w*0.125), y+int(w*0.024)), r, font=fr, fill=WHITE if on else (196,198,208))
        y += int(w*0.100)

    # the lead form the tour page carries
    y += int(w*0.020)
    _rr(d,[int(w*0.06),y,int(w*0.94),y+int(w*0.175)], int(w*0.044), fill=(24,20,44), outline=VIOLET, width=2)
    f3=UIS(int(w*0.034)); d.text((int(w*0.095), y+int(w*0.032)), "Ask about this home", font=f3, fill=WHITE)
    f4=UI(int(w*0.027)); d.text((int(w*0.095), y+int(w*0.082)), "Your enquiry goes straight to the agent.", font=f4, fill=(178,180,192))
    _rr(d,[int(w*0.095),y+int(w*0.118),int(w*0.905),y+int(w*0.118)+int(w*0.0)],1)
    return img
