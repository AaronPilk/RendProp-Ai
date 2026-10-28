#!/usr/bin/env python3
"""Build the bundled, offline first-listing training film.

This uses macOS's installed Samantha voice, Pillow and ffmpeg. It makes no
network or paid-provider calls. Intermediate audio and frames belong in an
external work directory; only the final MP4 and transcript enter the app.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "docs/marketing/quick-start-20261028"
MOVIE = ROOT / "apps/ios/Rendprop/Resources/RendpropQuickStart.mp4"
TRANSCRIPT = ROOT / "apps/ios/Rendprop/Resources/RendpropQuickStart.txt"
W, H = 1080, 1920
FPS = 24
SAMPLE_RATE = 48_000
HOLD_SECONDS = 0.55
CHAPTERS = ["Find your way", "Build the home", "Photos & AI", "Make a video",
            "Optional video tools", "Publish the website", "Follow up & manage", "Account & usage"]
PALETTE = {
    "Find your way": (126, 68, 246), "Build the home": (78, 119, 245),
    "Photos & AI": (237, 87, 145), "Make a video": (47, 171, 214),
    "Optional video tools": (141, 89, 236), "Publish the website": (53, 161, 147),
    "Follow up & manage": (121, 93, 229), "Account & usage": (115, 101, 225),
}
FONT = Path("/System/Library/Fonts/HelveticaNeue.ttc")
FONT_DISPLAY = Path("/System/Library/Fonts/NewYork.ttf")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def run(args: list[str], *, timeout: int | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, check=True, text=True, capture_output=True, timeout=timeout)


def data() -> dict:
    value = json.loads((SOURCE / "scenes.json").read_text())
    scenes = value["scenes"]
    require(len(scenes) >= 30, "A full first-listing guide needs at least 30 scenes")
    require([s["id"] for s in scenes] == [f"{i:02d}" for i in range(1, len(scenes) + 1)],
            "Scene identifiers must be complete and ordered")
    require(list(dict.fromkeys(s["chapter"] for s in scenes)) == CHAPTERS, "Chapter order changed")
    for scene in scenes:
        require(scene["title"] and scene["narration"] and len(scene["steps"]) == 3,
                f"Incomplete scene {scene['id']}")
        require(len(scene["narration"].split()) >= 18, f"Too little instruction in scene {scene['id']}")
    require(FONT.exists() and FONT_DISPLAY.exists(), "Required system fonts unavailable")
    return value


def font(size: int, display: bool = False):
    from PIL import ImageFont
    return ImageFont.truetype(str(FONT_DISPLAY if display else FONT), size)


def fit_lines(draw, value: str, face, width: int) -> list[str]:
    words = value.split()
    lines: list[str] = []
    current = ""
    for word in words:
        candidate = word if not current else f"{current} {word}"
        if draw.textbbox((0, 0), candidate, font=face)[2] > width and current:
            lines.append(current)
            current = word
        else:
            current = candidate
    if current:
        lines.append(current)
    return lines


def wrapped(draw, value: str, x: int, y: int, face, fill, width: int, gap: int = 9) -> int:
    lines = fit_lines(draw, value, face, width)
    height = face.size + gap
    for line in lines:
        draw.text((x, y), line, font=face, fill=fill)
        y += height
    return y


def gradient(size: tuple[int, int], a, b):
    from PIL import Image, ImageDraw
    image = Image.new("RGB", size)
    draw = ImageDraw.Draw(image)
    for y in range(size[1]):
        t = y / max(1, size[1] - 1)
        draw.line((0, y, size[0], y), fill=tuple(round(a[k] * (1-t) + b[k]*t) for k in range(3)))
    return image


def rounded_card(canvas, box: tuple[int, int, int, int], fill, radius=42, shadow=18):
    from PIL import Image, ImageDraw, ImageFilter
    mask = Image.new("L", canvas.size)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    shade = mask.filter(ImageFilter.GaussianBlur(shadow))
    overlay = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    overlay.paste((0, 0, 0, 105), (0, 12, canvas.width, canvas.height + 12), shade)
    canvas.alpha_composite(overlay)
    panel = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    panel.paste(fill, (0, 0, canvas.width, canvas.height), mask)
    canvas.alpha_composite(panel)


def cover(source, size):
    from PIL import ImageOps
    return ImageOps.fit(source, size, method=3, centering=(0.5, 0.5))


def render_site_diagram(base, draw, kind: str, accent) -> None:
    """Source-aligned diagram, not a purported screenshot of a device build."""
    from PIL import Image, ImageDraw
    draw.text((119, 430), "PROPERTY SITE · ILLUSTRATIVE", font=font(23), fill=(94, 86, 112))
    if kind == "site-mls":
        for y, color, heading, detail in [
            (525, (65, 146, 130), "Your share link", "Agent card · enquiry form · QR"),
            (845, (90, 78, 110), "MLS link", "Unbranded property experience"),
        ]:
            draw.rounded_rectangle((120, y, 960, y+260), radius=33,
                                   fill=(250, 250, 252), outline=(223, 220, 231), width=2)
            draw.ellipse((150, y+52, 214, y+116), fill=color)
            draw.text((237, y+48), heading, font=font(43, True), fill=(35, 29, 48))
            draw.text((237, y+113), detail, font=font(28), fill=(99, 94, 107))
            draw.rounded_rectangle((157, y+183, 922, y+225), radius=19, fill=(237, 234, 242))
            draw.text((174, y+190), "address · published listing identifier", font=font(22), fill=color)
        draw.rounded_rectangle((120, 1215, 960, 1455), radius=32, fill=(232, 248, 244))
        draw.text((155, 1265), "Open the published page", font=font(38, True), fill=(28, 89, 79))
        draw.text((155, 1332), "Check cover, video, facts and contact", font=font(27), fill=(46, 102, 93))
        return
    # Shared paid-site material: photography, identity, explicit film Play,
    # separate recorded tour, gallery, and buyer contact. Design differs by theme.
    photo = Image.open(ROOT / "apps/ios/Rendprop/Resources/Assets.xcassets/BrandHomeHero.imageset/BrandHomeHero.jpg").convert("RGB")
    if kind == "site-choice":
        variants=[(500,(52,47,48),(203,176,119),"Signature Estate","Full-bleed · ivory · brass"),
                  (1015,(240,237,226),(21,112,108),"Coastal Luxe","Framed film · sand · sea glass")]
        for top, surface, ink, title, subtitle in variants:
            draw.rounded_rectangle((120,top,960,top+442),radius=32,fill=surface)
            image=cover(photo,(790,226))
            mask=Image.new("L",image.size)
            ImageDraw.Draw(mask).rounded_rectangle((0,0,789,225),radius=24,fill=255)
            base.paste(image,(145,top+27),mask)
            draw.rounded_rectangle((166,top+46,324,top+87),radius=21,fill=(255,255,255,232))
            draw.text((187,top+52),"Home",font=font(24),fill=(45,39,55))
            draw.text((151,top+282),title,font=font(44,True),fill=ink)
            draw.text((151,top+349),subtitle,font=font(26),fill=ink)
    else:
        draw.rounded_rectangle((120,500,960,1475),radius=32,fill=(240,237,228))
        image=cover(photo,(790,425))
        mask=Image.new("L",image.size)
        ImageDraw.Draw(mask).rounded_rectangle((0,0,789,424),radius=25,fill=255)
        base.paste(image,(145,582),mask)
        draw.rounded_rectangle((152,522,360,568),radius=23,fill=(255,255,255,240))
        draw.text((176,530),"Home",font=font(26),fill=(29,75,73))
        draw.rounded_rectangle((720,522,923,568),radius=23,fill=(21,112,108))
        draw.text((739,530),"Fly-through",font=font(24),fill="white")
        draw.ellipse((477,750,603,876),fill=(255,255,255))
        draw.polygon([(528,785),(528,840),(570,812)],fill=(20,91,87))
        draw.text((151,1053),"1180 Crestline Ridge",font=font(45,True),fill=(25,85,80))
        draw.text((151,1125),"$4,250,000",font=font(32),fill=(45,43,49))
        draw.line((151,1202,924,1202),fill=(198,201,194),width=2)
        draw.text((151,1232),"Story   ·   Gallery   ·   Contact",font=font(29),fill=(44,83,80))
        draw.text((151,1332),"Listing film plays on request",font=font(29),fill=(57,56,65))
        draw.text((151,1380),"Accepted aerial opening plays first",font=font(27),fill=(57,56,65))
        draw.text((151,1420),"Recorded walkthrough opens separately",font=font(25),fill=(57,56,65))


def render_app_diagram(base, draw, scene: dict, accent) -> None:
    """Feature-specific illustrated controls using current Build 130 labels."""
    from PIL import Image, ImageDraw
    kind=scene["art"]
    ident=scene["id"]
    ink=(35,31,49)
    muted=(106,101,116)
    line=(225,222,233)
    draw.text((118,432),"APP FLOW · ILLUSTRATIVE",font=font(24),fill=muted)
    draw.rounded_rectangle((120,500,960,1467),radius=37,fill=(250,250,252),outline=line,width=2)

    def title(value,y=538):
        draw.text((155,y),value,font=font(43,True),fill=ink)
    def row(y,heading,detail=None,selected=False,h=145):
        bg=(*accent,) if selected else (255,255,255)
        fg=(255,255,255) if selected else ink
        draw.rounded_rectangle((150,y,930,y+h),radius=27,fill=bg,outline=accent if selected else line,width=2)
        draw.text((182,y+21),heading,font=font(35),fill=fg)
        if detail:
            draw.text((182,y+81),detail,font=font(25),fill=(244,241,252) if selected else muted)
    def pill(box,label,selected=False,size=29):
        draw.rounded_rectangle(box,radius=(box[3]-box[1])//2,
                               fill=accent if selected else (248,247,251),
                               outline=accent if selected else line,width=2)
        draw.text((box[0]+23,box[1]+13),label,font=font(size),fill="white" if selected else ink)

    if kind=="video-flow":
        title({"17":"Choose your photos","18":"Choose the look","19":"Photo motion","20":"Framing review"}[ident])
        draw.text((155,608),{"17":"Tap in viewing order","18":"Select the screen shape","19":"Choose movement and seconds","20":"Check the start and end crops"}[ident],font=font(29),fill=muted)
        if ident=="17":
            exterior=Image.open(ROOT/"apps/ios/Rendprop/Resources/Assets.xcassets/BrandHomeHero.imageset/BrandHomeHero.jpg").convert("RGB")
            living=Image.open(ROOT/"apps/ios/Rendprop/Resources/Assets.xcassets/BrandPhotoTools.imageset/BrandPhotoTools.jpg").convert("RGB")
            staged=Image.open(SOURCE/"screens/review.jpg").convert("RGB").crop((97,155,784,1070))
            for i in range(3):
                x=153+i*263
                img=cover((exterior,living,staged)[i],(247,383))
                mask=Image.new("L",img.size)
                ImageDraw.Draw(mask).rounded_rectangle((0,0,246,382),radius=24,fill=255)
                base.paste(img,(x,710),mask)
                draw.ellipse((x+14,728,x+77,791),fill=accent)
                draw.text((x+34,735),str(i+1),font=font(32),fill="white")
                draw.text((x+10,1115),f"Photo {i+1}",font=font(28),fill=ink)
            pill((153,1242,400,1311),"Finished edits",True,24)
            pill((421,1242,610,1311),"Originals",False,24)
            pill((630,1242,882,1311),"All saved",False,24)
        elif ident=="18":
            pill((155,743,521,883),"Wide · 16:9",True,34)
            pill((544,743,914,883),"Tall · 9:16",False,34)
            row(1000,"Preview the crop","The same photo fits each shape differently",False,160)
            draw.text((160,1255),"Next: movement and timing",font=font(29),fill=accent)
        elif ident=="19":
            pill((155,738,521,853),"Photo motion",True,31)
            pill((544,738,914,853),"AI camera",False,31)
            row(920,"Movement style","Push in · Pull back · Side glide",False,145)
            row(1095,"Time on each photo","Entrance 2s · rooms 3s",False,145)
            pill((602,1315,913,1390),"Framing review",True,25)
        else:
            source=Image.open(ROOT/"apps/ios/Rendprop/Resources/Assets.xcassets/BrandPhotoTools.imageset/BrandPhotoTools.jpg").convert("RGB")
            img=cover(source,(704,598))
            mask=Image.new("L",img.size)
            ImageDraw.Draw(mask).rounded_rectangle((0,0,703,597),radius=28,fill=255)
            base.paste(img,(188,707),mask)
            pill((188,1328,495,1404),"Start frame",True,26)
            pill((515,1328,891,1404),"End frame",False,26)
    elif kind=="activity" or kind=="processing":
        title("Activity")
        draw.rounded_rectangle((155,615,925,706),radius=30,fill=(239,238,242))
        draw.text((183,634),"Search properties",font=font(30),fill=muted)
        for label,x,y in [("Active",155,755),("Ready",553,755),("Needs attention",155,856),("History",553,856)]:
            pill((x,y,x+370,y+75),label,label==("Needs attention" if ident=="33" else "Active"),26)
        heading="Review this job" if ident=="33" else "Video · in progress"
        detail="Open status, then use Retry or Review" if ident=="33" else "Preparing selected photos"
        row(1020,heading,detail,False,160)
        if ident=="33":
            draw.text((183,1290),"Progress not reported · review the status",font=font(27),fill=muted)
        else:
            draw.rounded_rectangle((184,1280,890,1294),radius=7,fill=line)
            draw.rounded_rectangle((184,1280,536,1294),radius=7,fill=accent)
            draw.text((183,1325),"50% · 1 of 2 photos · measured work",font=font(27),fill=muted)
    elif kind=="credits":
        title("Credits")
        row(635,"Available now","Shared workspace balance",False,160)
        row(820,"This month", "Included portion of the balance",False,155)
        row(999,"Purchased", "Does not expire",False,155)
        pill((155,1212,540,1292),"Add credits",True,30)
        pill((555,1212,925,1292),"Check pending",False,27)
    elif kind=="plans":
        title("Plan & usage")
        for i,name in enumerate(("Pro","Max","Ultra","Team")):
            row(630+i*175,name,"See current offer in Apple",name=="Max",145)
        draw.text((158,1371),"Restore purchases in Settings",font=font(28),fill=accent)
    elif kind=="share":
        title("Your link")
        row(638,"Share your link","Address + unique listing ID",False,180)
        pill((157,875,517,964),"Copy",True,31)
        pill((542,875,923,964),"QR",False,31)
        row(1034,"MLS link · unbranded","Check your local MLS rules",False,180)
    elif kind=="leads":
        title("Leads")
        pill((155,632,520,710),"All listings",True,29)
        row(786,"Buyer enquiry","From this property's website",False,215)
        draw.text((182,915),"Open the request, then follow up",font=font(27),fill=muted)
        row(1100,"Contact choice","Check your public buyer contact",False,180)
    elif kind=="account":
        title("Account")
        row(662,"Profile & contact card","Name, email, phone",False,185)
        row(875,"Settings & plan","Usage, Team, support, walkthrough",False,185)
        row(1088,"Ask AI","Help for the screen you are on",False,185)
    elif kind=="team":
        title("Team")
        row(640,"Selected workspace","Confirm before shared work",False,175)
        row(842,"Members & invitations","Seats depend on the current plan",False,175)
        row(1044,"Shared credit balance","Owner or admin buys eligible packs",False,175)
    elif kind=="gallery-cover":
        title("Gallery selection")
        sources=(Image.open(ROOT/"apps/ios/Rendprop/Resources/Assets.xcassets/BrandHomeHero.imageset/BrandHomeHero.jpg").convert("RGB"),
                 Image.open(ROOT/"apps/ios/Rendprop/Resources/Assets.xcassets/BrandPhotoTools.imageset/BrandPhotoTools.jpg").convert("RGB"))
        for i in range(2):
            x=157+i*397
            img=cover(sources[i],(370,415))
            mask=Image.new("L",img.size)
            ImageDraw.Draw(mask).rounded_rectangle((0,0,369,414),radius=26,fill=255)
            base.paste(img,(x,655),mask)
            if i==0:
                draw.ellipse((x+18,675,x+90,747),fill=accent)
                draw.line([(x+36,710),(x+49,725),(x+76,690)],fill="white",width=7)
        pill((160,1115,530,1200),"Use on listing",True,29)
        pill((556,1115,925,1200),"Use as cover",False,29)
        draw.text((160,1283),"Select all for listing · filtered group",font=font(28),fill=accent)
    elif kind=="studio":
        title("AI Photo Studio")
        row(636,"Declutter","Remove visible movable clutter",False,165)
        row(828,"Staging","Show a furnished possibility",False,165)
        row(1020,"Sky and more","Review each result against Original",False,165)
        pill((156,1280,924,1365),"Review usage before Generate",True,27)
    elif kind=="video-result":
        title("Your video is ready")
        source=Image.open(ROOT/"apps/ios/Rendprop/Resources/Assets.xcassets/BrandHomeHero.imageset/BrandHomeHero.jpg").convert("RGB")
        img=cover(source,(650,580))
        mask=Image.new("L",img.size)
        ImageDraw.Draw(mask).rounded_rectangle((0,0,649,579),radius=25,fill=255)
        base.paste(img,(214,630),mask)
        draw.ellipse((504,875,572,943),fill=(255,255,255))
        draw.polygon([(530,892),(530,929),(556,911)],fill=accent)
        pill((160,1250,920,1328),"Use on listing website",True,27)
        draw.text((195,1372),"Save to Photos  ·  Share video",font=font(28),fill=accent)
    elif kind=="contact":
        title("Buyer contact")
        row(650,"Your contact card","Review name, email and phone",False,220)
        row(906,"Listing contact","Select the right recipient",False,220)
        draw.text((157,1215),"Check again before publishing",font=font(31),fill=accent)
    elif kind=="tabs":
        title("Five places to work")
        for i,(name,desc) in enumerate((('Home','Start'),('Listings','Properties'),('Activity','Jobs'),('Leads','Enquiries'),('Account','You & plan'))):
            y=623+i*155
            row(y,name,desc,i==1,130)
    else:
        raise ValueError(f"No app diagram for {kind}")


def render_slide(scene: dict, index: int, count: int, destination: Path) -> None:
    from PIL import Image, ImageDraw, ImageFilter, ImageOps
    accent = PALETTE[scene["chapter"]]
    base = gradient((W, H), (22, 16, 39), (43, 25, 66)).convert("RGBA")
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    gd.ellipse((500, -280, 1430, 700), fill=(*accent, 68))
    gd.ellipse((-400, 1000, 440, 1990), fill=(61, 121, 234, 35))
    base.alpha_composite(glow.filter(ImageFilter.GaussianBlur(125)))
    d = ImageDraw.Draw(base)
    d.text((84, 57), "Rendprop", font=font(42, True), fill=(255, 255, 255))
    d.rounded_rectangle((750, 66, 997, 110), radius=22, fill=(91, 72, 115), outline=(159, 141, 179), width=2)
    d.text((778, 73), "FIELD GUIDE", font=font(24), fill=(255, 255, 255))
    chap_index = CHAPTERS.index(scene["chapter"]) + 1
    d.text((84, 150), f"CHAPTER {chap_index:02d}  ·  {scene['chapter'].upper()}", font=font(29), fill=(*accent,))
    title_font = font(58, True)
    title_lines = fit_lines(d, scene["title"], title_font, 910)
    require(len(title_lines) <= 2, f"Title too long: {scene['title']}")
    y = 205
    for line in title_lines:
        d.text((84, y), line, font=title_font, fill=(255, 255, 255))
        y += 68

    box = (78, 390, 1002, 1584)
    rounded_card(base, box, (251, 251, 254, 255))
    d = ImageDraw.Draw(base)
    art_path = SOURCE / "screens" / f"{scene['art']}.jpg"
    if scene["art"].startswith("site-"):
        render_site_diagram(base, d, scene["art"], accent)
    elif scene["art"] in {"video-flow","activity","processing","credits","plans","share","leads","account","team","contact","tabs","studio","video-result","gallery-cover"}:
        render_app_diagram(base,d,scene,accent)
    elif art_path.is_file():
        source = Image.open(art_path).convert("RGB")
        source.thumbnail((846, 1130), Image.Resampling.LANCZOS)
        x = (W - source.width) // 2
        yy = 420 + max(0, (1110-source.height)//2)
        mask = Image.new("L", source.size, 0)
        ImageDraw.Draw(mask).rounded_rectangle((0, 0, source.width-1, source.height-1), radius=24, fill=255)
        base.paste(source, (x, yy), mask)
        d = ImageDraw.Draw(base)
        d.text((119, 1535), "APP SCREEN EXCERPT", font=font(20), fill=(91, 88, 108))
    else:
        d.text((118, 436), "DO THIS IN THE APP", font=font(25), fill=(*accent,))
        if scene["art"] in {"hero", "photo", "aerial"}:
            brand = {"hero":"BrandHomeHero", "photo":"BrandPhotoTools", "aerial":"BrandVideoTools"}[scene["art"]]
            image = Image.open(ROOT / f"apps/ios/Rendprop/Resources/Assets.xcassets/{brand}.imageset/{brand}.jpg").convert("RGB")
            image = cover(image, (840, 385))
            mask = Image.new("L", image.size)
            ImageDraw.Draw(mask).rounded_rectangle((0,0,image.width-1,image.height-1),radius=30,fill=255)
            base.paste(image,(120,495),mask)
            item_top, item_gap, item_h = 925, 199, 164
        else:
            d.rounded_rectangle((122, 490, 960, 650), radius=34, fill=(*accent, 31), outline=(*accent, 100), width=2)
            d.text((154, 520), scene["chapter"], font=font(40, True), fill=(42, 31, 62))
            d.text((154, 583), "Follow the steps below", font=font(25), fill=(98, 90, 112))
            item_top, item_gap, item_h = 710, 266, 205
        for step_index, step in enumerate(scene["steps"]):
            yy = item_top + step_index*item_gap
            d.rounded_rectangle((120, yy, 960, yy+item_h), radius=30,
                                fill=(247, 246, 252), outline=(226, 223, 238), width=2)
            d.ellipse((145, yy+34, 225, yy+114), fill=(*accent,))
            number = str(step_index + 1)
            bb=d.textbbox((0,0),number,font=font(38))
            d.text((185-(bb[2]-bb[0])//2, yy+51), number, font=font(38), fill="white")
            end=wrapped(d,step.replace("→", "›"),255,yy+44,font(37), (38,31,55), 665,9)
            require(end <= yy+item_h-15, f"Step overflows scene {scene['id']}: {step}")
    # Instruction pills remain distinct from the screenshot and within the safe area.
    d.rounded_rectangle((84, 1634, 996, 1763), radius=56,
                        fill=(*accent, 72), outline=(*accent, 155), width=2)
    d.ellipse((118, 1670, 174, 1726), fill=(255, 255, 255))
    d.line([(132,1696),(143,1707),(162,1684)],fill=(*accent,),width=5,joint="curve")
    summary = scene["steps"][0].replace("→", "›")
    wrapped(d, summary, 195, 1671, font(30), (248, 245, 255), 745, 4)
    d.text((84, 1822), f"{index:02d} / {count:02d}", font=font(24), fill=(189, 178, 202))
    d.text((766, 1822), "YOUR HOME. YOUR STORY.", font=font(20), fill=(189, 178, 202))
    d.rounded_rectangle((84, 1875, 996, 1882), radius=4, fill=(117, 99, 139))
    d.rounded_rectangle((84, 1875, 84+round(912*index/count), 1882), radius=4, fill=(*accent,))
    destination.parent.mkdir(parents=True, exist_ok=True)
    base.convert("RGB").save(destination, quality=91, optimize=True, subsampling=0)


def synthesize(scene: dict, out: Path, voice: str, rate: int) -> tuple[bytes, float]:
    aiff = out / f"voice-{scene['id']}.aiff"
    raw = out / f"voice-{scene['id']}.raw"
    signature = hashlib.sha256(f"{voice}|{rate}|{scene['narration']}".encode()).hexdigest()
    marker=out / f"voice-{scene['id']}.sha256"
    if not (raw.exists() and marker.exists() and marker.read_text().strip()==signature):
        run(["say", "-v", voice, "-r", str(rate), "-o", str(aiff), scene["narration"]], timeout=90)
        run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(aiff),
             "-ar", str(SAMPLE_RATE), "-ac", "1", "-f", "s16le", str(raw)], timeout=90)
        marker.write_text(signature+"\n")
    content = raw.read_bytes()
    require(len(content)>0 and len(content)%2==0, f"Audio missing for {scene['id']}")
    return content, len(content)/(2*SAMPLE_RATE)


def stamp(seconds: float) -> str:
    millis = round(seconds*1000)
    hours, millis = divmod(millis, 3_600_000)
    minutes, millis = divmod(millis, 60_000)
    secs, millis = divmod(millis, 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d}.{millis:03d}"


def make_transcript(scenes: list[dict]) -> str:
    result=["Rendprop — Complete first-listing guide", "Narrated transcript and on-screen steps", ""]
    current=None
    for scene in scenes:
        if scene["chapter"]!=current:
            current=scene["chapter"]
            result += [current.upper(), ""]
        result += [f"{scene['id']}. {scene['title']}", scene["narration"],
                   "On screen: " + " • ".join(scene["steps"]), ""]
    result += ["Prices, trial eligibility, available credits, and AI processing access are shown by the app and Apple at the time of use. This guide does not start a purchase or guarantee an offer.", ""]
    return "\n".join(result)


def captions(scenes: list[dict], timeline: list[dict]) -> str:
    lines=["WEBVTT", ""]
    for scene, item in zip(scenes,timeline):
        sentences=[s.strip() for s in re.split(r"(?<=[.!?])\s+",scene["narration"]) if s.strip()]
        weights=[len(s.split()) for s in sentences]
        total=sum(weights)
        elapsed=0.0
        for sentence,weight in zip(sentences,weights):
            begin=item["start"]+elapsed
            elapsed+=item["audio_seconds"]*weight/total
            end=item["start"]+elapsed
            lines += [f"{stamp(begin)} --> {stamp(end)}", sentence, ""]
    return "\n".join(lines)


def ffquote(path: Path) -> str:
    return "'" + str(path).replace("'", "'\\''") + "'"


def main() -> None:
    p=argparse.ArgumentParser()
    p.add_argument("--work-dir", type=Path, required=True, help="External volume for intermediate frames/audio")
    p.add_argument("--render", action="store_true", help="Actually synthesize audio and encode the MP4")
    p.add_argument("--slides-only", action="store_true", help="Render slide artwork without audio/video")
    p.add_argument("--voice", default=None)
    p.add_argument("--voice-rate", type=int, default=None)
    args=p.parse_args()
    value=data();scenes=value["scenes"]
    require(args.render or args.slides_only, "Choose --render or --slides-only")
    require(shutil.which("ffmpeg") and shutil.which("ffprobe") and shutil.which("say"), "ffmpeg, ffprobe and say are required")
    args.work_dir.mkdir(parents=True,exist_ok=True)
    require(os.statvfs(args.work_dir).f_bavail*os.statvfs(args.work_dir).f_frsize > 2_000_000_000,
            "Keep at least 2 GB free on the render volume")
    slides=args.work_dir/"slides";slides.mkdir(exist_ok=True)
    for i,scene in enumerate(scenes,1):
        render_slide(scene,i,len(scenes),slides/f"slide-{scene['id']}.jpg")
    TRANSCRIPT.write_text(make_transcript(scenes),encoding="utf-8")
    if args.slides_only:
        print(json.dumps({"slides":len(scenes),"transcript":str(TRANSCRIPT),"work_dir":str(args.work_dir)}))
        return

    voice=args.voice or value["voice"]
    rate=args.voice_rate or value["voice_rate_wpm"]
    audio_path=args.work_dir/"narration.raw"
    timeline=[];position=0.0
    with audio_path.open("wb") as output:
        for scene in scenes:
            samples,duration=synthesize(scene,args.work_dir,voice,rate)
            output.write(samples)
            output.write(b"\0\0"*round(HOLD_SECONDS*SAMPLE_RATE))
            scene_duration=duration+round(HOLD_SECONDS*SAMPLE_RATE)/SAMPLE_RATE
            timeline.append({"id":scene["id"],"chapter":scene["chapter"],"title":scene["title"],
                             "start":position,"audio_seconds":duration,"end":position+scene_duration})
            position+=scene_duration
    total=position
    concat=args.work_dir/"slides.ffconcat"
    slide_entries=["ffconcat version 1.0\n"]
    for scene,item in zip(scenes,timeline):
        slide_path=slides / ("slide-"+scene["id"]+".jpg")
        slide_entries.append(f"file {ffquote(slide_path)}\nduration {item['end']-item['start']:.6f}\n")
    final_slide=slides / ("slide-"+scenes[-1]["id"]+".jpg")
    slide_entries.append(f"file {ffquote(final_slide)}\n")
    concat.write_text("".join(slide_entries))
    chapter_ranges=[]
    for chapter in CHAPTERS:
        group=[item for item in timeline if item["chapter"]==chapter]
        chapter_ranges.append((chapter,group[0]["start"],group[-1]["end"]))
    metadata=args.work_dir/"chapters.ffmeta"
    metadata.write_text(";FFMETADATA1\ntitle=Rendprop complete first-listing guide\n"+"".join(
        f"[CHAPTER]\nTIMEBASE=1/1000\nSTART={round(start*1000)}\nEND={round(end*1000)}\ntitle={name}\n"
        for name,start,end in chapter_ranges))
    (SOURCE/"captions.vtt").write_text(captions(scenes,timeline),encoding="utf-8")
    (SOURCE/"timeline.json").write_text(json.dumps({"duration_seconds":total,"scenes":timeline,
        "chapters":[{"title":n,"start":a,"end":b} for n,a,b in chapter_ranges]},indent=2)+"\n")
    temp_movie=args.work_dir/"quick-start-video.mp4"
    command=["ffmpeg","-hide_banner","-loglevel","warning","-y",
             "-f","concat","-safe","0","-i",str(concat),
             "-f","s16le","-ar",str(SAMPLE_RATE),"-ac","1","-i",str(audio_path),
             "-f","ffmetadata","-i",str(metadata),
             "-map","0:v:0","-map","1:a:0","-map_metadata","2","-map_chapters","2",
             "-vf",f"fps={FPS},scale=in_range=full:out_range=limited,format=yuv420p",
             "-color_range","tv","-colorspace","bt709","-color_primaries","bt709","-color_trc","bt709",
             "-c:v","libx264","-preset","veryfast","-crf","23",
             "-c:a","aac","-b:a","112k","-movflags","+faststart","-t",f"{total:.6f}",str(temp_movie)]
    process=subprocess.run(command,text=True,capture_output=True,timeout=1800)
    require(process.returncode==0, f"ffmpeg failed: {process.stderr[-3000:]}")
    shutil.copyfile(temp_movie,MOVIE)
    probe=json.loads(run(["ffprobe","-v","error","-show_format","-show_streams","-show_chapters","-of","json",str(MOVIE)],timeout=60).stdout)
    receipt={"source_commit":run(["git","rev-parse","HEAD"]).stdout.strip(),"scenes":len(scenes),
             "chapters":len(probe["chapters"]),"duration_seconds":float(probe["format"]["duration"]),
             "bytes":MOVIE.stat().st_size,"video_sha256":hashlib.sha256(MOVIE.read_bytes()).hexdigest(),
             "transcript_sha256":hashlib.sha256(TRANSCRIPT.read_bytes()).hexdigest(),
             "voice":voice,"voice_rate":rate,"paid_api_calls":0}
    (args.work_dir/"build-receipt.json").write_text(json.dumps(receipt,indent=2)+"\n")
    print(json.dumps(receipt,indent=2))


if __name__=="__main__":
    main()
