import os as _os; _HERE=_os.path.dirname(_os.path.abspath(__file__))
import sys, os, json, shutil
sys.path.insert(0,_os.path.dirname(_os.path.abspath(__file__)))
from agency import *
from carousel_copy import C

OUT=_os.path.join(_HERE,"..","out")
shutil.rmtree(OUT, ignore_errors=True); os.makedirs(OUT, exist_ok=True)

# Per carousel: the hero photo, and (for the five photo tools) a before/after pair.
HERO = {
 "flythrough":"great_room","share-link":"ext_twilight","room-tags":"great_room",
 "blue-sky":"ext_before","twilight":"ext_before","green-lawn":"ext_before",
 "tidy":"living_before","staging":"room_before","reels":"kitchen","aerial":"ext_twilight",
 "floor-plan":"great_room","two-links":"ext_blue","agent-card":"kitchen","leads":"great_room",
 "modes":"kitchen","no-account":"ext_blue","disclosure":"room_after","plans":"ext_twilight",
 "free-trial":"ext_blue","your-content":"great_room",
}
PAIR = {
 "blue-sky":  ("ext_before","ext_blue","BEFORE","ONE TAP LATER"),
 "twilight":  ("ext_before","ext_twilight","SHOT AT MIDDAY","ONE TAP LATER"),
 "green-lawn":("ext_before","ext_lawn","LISTED IN FEBRUARY","ONE TAP LATER"),
 "tidy":      ("living_before","living_after","AS YOU FOUND IT","ONE TAP LATER"),
 "staging":   ("room_before","room_after","VACANT","VIRTUALLY STAGED"),
}
STUDIO_CHIP = {"twilight":0,"blue-sky":1,"green-lawn":2,"tidy":3,"staging":4,"reels":5}

made=0; index=[]
for i,c in enumerate(C, start=1):
    slug=c["slug"]; total=5
    folder=os.path.join(OUT,f"reel-{i:02d}-{slug}"); os.makedirs(folder,exist_ok=True)
    S=[]
    S.append(("01-hook", L_photo_hero(i,total,c["feature"],c["hook"],c["sub"],HERO[slug])))
    if slug in PAIR:
        b,a,bl,al = PAIR[slug]
        S.append(("02-before-after", L_before_after(i,total,c["feature"],"One tap. Same photo.",b,a,0,bl,al)))
        S.append(("03-app", L_app(i,total,c["feature"],"Where it lives",
                  "AI Photo Studio — on any photo you have already taken.","studio",1,
                  highlight=STUDIO_CHIP.get(slug))))
    else:
        which = "tour" if slug in ("flythrough","share-link","room-tags","two-links",
                                   "agent-card","leads","disclosure") else "studio"
        title,cap = ("This is what a buyer gets",
                     "A page they scroll through — price, beds, baths, and the room they are standing in.") \
                    if which=="tour" else ("Everything from one screen",
                     "Tour, reel, floor plan, aerial and your agent card, all saved to the same home.")
        S.append(("02-app", L_app(i,total,c["feature"],title,cap,which,0,
                                  highlight=STUDIO_CHIP.get(slug))))
        body=c["slides"]
        sl=body[1] if len(body)>1 else body[0]
        k=sl[0]
        if k=="big":        im=L_statement(i,total,c["feature"],sl[1],sl[2],1)
        elif k=="steps":    im=L_steps(i,total,c["feature"],sl[1],sl[2],"02-home-showroom",1)
        elif k=="disclose": im=L_statement(i,total,c["feature"],"Labelled,\nalways.",sl[2],1)
        elif k=="plans":
            from render_carousels import s_plans; im=s_plans(c,i,total,sl[1],sl[2],1)
        else:               im=L_points(i,total,c["feature"],sl[1],sl[2],1)
        S.append(("03-"+k, im))
    # a written slide, then the close
    body=c["slides"]; last=body[-1]; k=last[0]
    if k=="big":        im=L_statement(i,total,c["feature"],last[1],last[2],2)
    elif k=="points":   im=L_points(i,total,c["feature"],last[1],last[2],2)
    elif k=="disclose": im=L_statement(i,total,c["feature"],"Labelled,\nalways.",last[2],2)
    elif k=="steps":    im=L_steps(i,total,c["feature"],last[1],last[2],"02-home-showroom",2)
    else:
        from render_carousels import s_plans; im=s_plans(c,i,total,last[1],last[2],2)
    S.append(("04-"+k, im))
    S.append(("05-cta", L_cta2(i,total,"ext_twilight" if HERO[slug]!="ext_twilight" else "ext_blue")))
    for name,im in S:
        im.convert("RGB").save(os.path.join(folder,name+".png"), quality=95); made+=1
    index.append({"n":i,"feature":c["feature"],"slug":slug,"slides":len(S)})
json.dump(index, open(os.path.join(OUT,"index.json"),"w"), indent=1)
print(f"{made} slides / {len(C)} carousels")
