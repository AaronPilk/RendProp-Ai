import os
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import cairosvg
W,H=1080,1920
gf="/usr/share/fonts/truetype/google-fonts/"
def pick(*names):
    for n in names:
        if os.path.exists(n): return n
    return names[-1]
POPB=pick(gf+"Poppins-Bold.ttf")
POPS=pick(gf+"Poppins-SemiBold.ttf",gf+"Poppins-Medium.ttf",POPB)
POPR=pick(gf+"Poppins-Regular.ttf","/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",POPB)
def F(p,s): return ImageFont.truetype(p,s)
def lerp(a,b,t): return tuple(int(a[i]+(b[i]-a[i])*t) for i in range(3))
def ls_text(d,xy,txt,f,fill,ls,anchor_left=True):
    x,y=xy
    for ch in txt:
        d.text((x,y),ch,font=f,fill=fill,anchor="la"); x+=d.textlength(ch,font=f)+ls
    return x
def ls_width(d,txt,f,ls): return sum(d.textlength(c,font=f)+ls for c in txt)-ls

# ---------- background ----------
bg=Image.new("RGBA",(W,H),(11,10,18,255)); d=ImageDraw.Draw(bg)
c0=(11,10,18); c1=(26,16,48); c2=(11,10,18)
for y in range(H):
    t=y/H
    col=lerp(c0,c1,t/0.55) if t<0.55 else lerp(c1,c2,(t-0.55)/0.45)
    d.line([(0,y),(W,y)],fill=col+(255,))
tint=Image.new("RGBA",(W,H),(0,0,0,0)); td=ImageDraw.Draw(tint)
td.ellipse([W*0.5-560,-160,W*0.5+560,760],fill=(124,58,237,70))
bg=Image.alpha_composite(bg,tint.filter(ImageFilter.GaussianBlur(170))); d=ImageDraw.Draw(bg)
d.rounded_rectangle([60,340,1020,944],radius=30,outline=(255,255,255,34),width=2)
cairosvg.svg2png(url="/sessions/dreamy-confident-ritchie/mnt/Rendprop AI/repo/services/edge/tour-host/public/assets/rendprop-mark.svg",
                 write_to="/tmp/mktg/mk.png",output_width=50,output_height=50)
bg.alpha_composite(Image.open("/tmp/mktg/mk.png").convert("RGBA"),(60,52))
ls_text(d,(126,64),"RENDPROP",F(POPB,26),(255,255,255,255),8)
tg="PRIVATE TOUR"; fT=F(POPS,19)
d.text((1020,70),"",font=fT); 
ls_text(d,(1020-ls_width(d,tg,fT,6),70),tg,fT,(255,255,255,175),6)
bg.convert("RGB").save("/tmp/mktg/bg.png")

# rounded mask for the video band (grayscale)
m=Image.new("L",(960,604),0); md=ImageDraw.Draw(m); md.rounded_rectangle([0,0,959,603],radius=30,fill=255)
m.save("/tmp/mktg/rmask.png")
# live chip baked onto a band overlay (drawn later as its own overlay on video) -> simpler: bake into each cap? keep as static overlay
band=Image.new("RGBA",(W,H),(0,0,0,0)); bd=ImageDraw.Draw(band)
# bottom gradient inside band for legibility
for i in range(230):
    a=int(150*(i/230))
    bd.line([(62,944-i),(1018,944-i)],fill=(6,5,12,a))
# live chip
lx,ly=84,884
lab="Live walkthrough"; fL=F(POPB,20); tw=bd.textlength(lab,font=fL)
bd.rounded_rectangle([lx,ly,lx+tw+70,ly+44],radius=22,fill=(16,14,24,150),outline=(255,255,255,55),width=1)
bd.ellipse([lx+20,ly+16,lx+32,ly+28],fill=(155,109,255,255))
bd.text((lx+44,ly+22),lab,font=fL,fill=(255,255,255,255),anchor="lm")
band.save("/tmp/mktg/band.png")
# progress bar (1080x9 purple gradient)
bar=Image.new("RGBA",(1080,9),(0,0,0,0)); brd=ImageDraw.Draw(bar)
for x in range(1080): brd.line([(x,0),(x,9)],fill=lerp((155,109,255),(124,58,237),x/1080)+(255,))
bar.save("/tmp/mktg/bar.png")

def newcap(): return Image.new("RGBA",(W,H),(0,0,0,0))
def kicker(d,y,txt):
    f=F(POPB,22); d.rounded_rectangle([60,y+8,92,y+10],radius=1,fill=(124,58,237,255))
    ls_text(d,(104,y),txt.upper(),f,(196,168,255,255),6)
def chips(img,d,labels,y0,fsz):
    f=F(POPB,fsz); x=60; y=y0; padx=26; pady=16
    for lab in labels:
        tw=d.textlength(lab,font=f); cw=tw+padx*2; ch=fsz+pady*2
        if x+cw>60+960: x=60; y+=ch+14
        pan=Image.new("RGBA",img.size,(0,0,0,0)); pd=ImageDraw.Draw(pan)
        pd.rounded_rectangle([x,y,x+cw,y+ch],radius=17,fill=(24,21,36,150),outline=(255,255,255,44),width=1)
        img.alpha_composite(pan); d=ImageDraw.Draw(img)
        d.text((x+padx,y+ch/2),lab,font=f,fill=(255,255,255,255),anchor="lm"); x+=cw+15

# cap1 address
c=newcap(); d=ImageDraw.Draw(c); kicker(d,1010,"Private Listing")
d.text((60,1052),"1180 Crestline",font=F(POPB,90),fill=(255,255,255,255))
d.text((60,1150),"Ridge",font=F(POPB,90),fill=(255,255,255,255))
d.text((60,1276),"A glass-and-oak modern estate",font=F(POPR,31),fill=(255,255,255,205))
d.text((60,1318),"above the canyon.",font=F(POPR,31),fill=(255,255,255,205))
c.save("/tmp/mktg/cap1.png")
# cap2 stats
c=newcap(); d=ImageDraw.Draw(c); chips(c,d,["5 Beds","6 Baths","6,200 Sq Ft","0.7 Acres"],1070,32); c.save("/tmp/mktg/cap2.png")
# cap3 hero
c=newcap(); d=ImageDraw.Draw(c); kicker(d,1010,"The life here")
d.text((60,1060),"Vanishing-edge pool.",font=F(POPB,74),fill=(255,255,255,255))
d.text((60,1150),"180° of open water.",font=F(POPB,74),fill=(255,255,255,255)); c.save("/tmp/mktg/cap3.png")
# cap4 features
c=newcap(); d=ImageDraw.Draw(c); chips(c,d,["Chef’s kitchen","European white oak","Glass wine wall","Rooftop terrace"],1070,27); c.save("/tmp/mktg/cap4.png")
# cap5 price
c=newcap(); d=ImageDraw.Draw(c)
ls_text(d,(60,1034),"OFFERED AT",F(POPS,27),(255,255,255,175),6)
d.text((58,1076),"$4,250,000",font=F(POPB,118),fill=(206,183,255,255)); c.save("/tmp/mktg/cap5.png")
# cap6 cta glass card
c=newcap(); d=ImageDraw.Draw(c)
pan=Image.new("RGBA",c.size,(0,0,0,0)); pd=ImageDraw.Draw(pan)
pd.rounded_rectangle([120,1120,960,1352],radius=30,fill=(18,15,28,160),outline=(255,255,255,42),width=1)
c.alpha_composite(pan); d=ImageDraw.Draw(c)
d.text((540,1200),"Book a private showing",font=F(POPB,56),fill=(255,255,255,255),anchor="mm")
d.text((540,1284),"rendprop.com",font=F(POPB,32),fill=(196,168,255,255),anchor="mm"); c.save("/tmp/mktg/cap6.png")
print("assets generated:", [f for f in os.listdir('/tmp/mktg') if f.endswith('.png')])
print("fonts:",os.path.basename(POPB),os.path.basename(POPS),os.path.basename(POPR))
