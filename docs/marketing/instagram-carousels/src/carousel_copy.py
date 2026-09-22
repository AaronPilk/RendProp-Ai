# 20 carousels. Every claim below is taken from the shipped App Store
# description — nothing here is a feature that has not shipped.
# Deliberately excluded: the agent-on-camera reel (server only, no client yet)
# and the spatial 3D tour (specced today, not built).

C = [
{"slug":"flythrough","feature":"The Flythrough",
 "hook":"Your phone just replaced the drone",
 "sub":"Walk the house. Rendprop turns it into a smooth, drone-style flythrough.",
 "slides":[
   ("steps","How it actually works",["Walk the space and record on your iPhone.",
     "Tag the rooms you want people to jump to.","Rendprop builds the flythrough.",
     "You get a link you can send to anyone."]),
   ("big","No drone.\nNo crew.\nNo editor.","The three line items that used to make a listing video cost $600 and take four days."),
   ("points","What you get back",["A cinematic tour of the whole property",
     "A link that opens in any browser","Rooms a buyer can jump straight to"]),
 ]},

{"slug":"share-link","feature":"The Share Link",
 "hook":"One link. Text it, email it, print it.",
 "sub":"Every tour becomes a web page. No app needed to watch it.",
 "slides":[
   ("points","Where the link goes",["In a text to a buyer, 30 seconds after the showing",
     "On the flyer, as a QR code","In the listing email that usually gets ignored"]),
   ("big","They scroll.\nThe house moves.","Nobody has to download anything, make an account, or figure out a viewer."),
   ("points","Why it beats a video file",["It opens instantly on any phone",
     "It never lands in a spam folder as a 200MB attachment","You can see it was opened"]),
 ]},

{"slug":"room-tags","feature":"Room Tags",
 "hook":"Buyers skip to the kitchen anyway",
 "sub":"So let them. Tag your rooms and every one becomes a jump point.",
 "slides":[
   ("points","How buyers actually watch",["They watch 20 seconds",
     "They look for the kitchen and the primary","They send it on if it is easy to send"]),
   ("big","Tag it once.\nJump to it forever.","Room tags become the chapter rail under the player and the room list on the page."),
   ("points","What it does for you",["A buyer finds what they care about in one tap",
     "The floor plan links to the same rooms","It works on the unbranded MLS link too"]),
 ]},

{"slug":"blue-sky","feature":"Blue Sky",
 "hook":"It was overcast. Nobody has to know.",
 "sub":"One tap swaps a grey sky for a clear one. The exterior stops looking cold.",
 "slides":[
   ("big","One tap.","Not a mask, not a brush, not twenty minutes in Photoshop that you were never going to do."),
   ("points","When you reach for it",["The only day you could shoot was grey",
     "The listing goes live tomorrow","The exterior is the first photo and it is flat"]),
   ("disclose","Labelled, always","Every AI edit is marked as virtually staged on your tour, and the untouched original is published beside it."),
 ]},

{"slug":"twilight","feature":"Twilight",
 "hook":"The twilight shot, without the twilight",
 "sub":"Turn a midday exterior into the dusk shot that gets the click.",
 "slides":[
   ("big","Twilight photos\nget clicked more.","Every agent knows it. Almost nobody books the second shoot to get one."),
   ("points","What it saves you",["A second trip out at the right hour",
     "The photographer's twilight surcharge","Waiting for a night the weather cooperates"]),
   ("disclose","Labelled, always","Marked as virtually staged on the tour, with the untouched original published beside it."),
 ]},

{"slug":"green-lawn","feature":"Green Lawn",
 "hook":"Listing in February. Lawn from July.",
 "sub":"Bring a dormant or patchy lawn back to green in one tap.",
 "slides":[
   ("points","Nobody is fooled by a brown lawn",["It reads as neglected, not seasonal",
     "It is the first thing in the first photo","It has nothing to do with the house"]),
   ("big","The house is\nthe product.","Not the month you happened to list it in."),
   ("disclose","Labelled, always","Marked as virtually staged, original published alongside."),
 ]},

{"slug":"tidy","feature":"Tidy The Room",
 "hook":"The sellers said they would tidy up",
 "sub":"They did not. Clear the clutter in one tap instead of rescheduling.",
 "slides":[
   ("points","What it handles",["The countertop that has everything on it",
     "The laundry basket in the corner of the primary","The toys you politely did not mention"]),
   ("big","Do not reshoot.\nRetouch.","A second visit costs you a half day. This costs you a tap."),
   ("disclose","Labelled, always","Marked as virtually staged on the tour, original published beside it."),
 ]},

{"slug":"staging","feature":"Virtual Staging",
 "hook":"An empty room is a hard sell",
 "sub":"Add furniture to a vacant listing so buyers can see the scale.",
 "slides":[
   ("points","Why empty rooms hurt",["Buyers cannot judge how big a room really is",
     "Empty reads as distressed","Photos of bare walls do not get saved"]),
   ("big","Physical staging:\nthousands.","Virtual staging: a tap, on a photo you already took."),
   ("disclose","Labelled, always","Marked as virtually staged for every viewer, with the unfurnished original published beside it."),
 ]},

{"slug":"reels","feature":"Reels With Your Voice",
 "hook":"Your listing photos, as a vertical reel",
 "sub":"With your own voiceover and word-by-word captions.",
 "slides":[
   ("points","What comes out",["A short vertical video, ready for Reels or TikTok",
     "Your voice over it, not a robot","Captions that land word by word"]),
   ("big","Photos you\nalready have.","You are not shooting anything new. The reel is built from the listing shoot."),
   ("points","Why bother",["Most of the market still posts a static photo",
     "Vertical video is what the feed rewards","It takes minutes, not an evening"]),
 ]},

{"slug":"aerial","feature":"Aerial Intro",
 "hook":"An opening shot that lifts off the house",
 "sub":"From an exterior photo you already have. No drone, no licence.",
 "slides":[
   ("points","What it replaces",["A licensed drone operator",
     "The permission conversation","The $200 line item on a $300k listing"]),
   ("big","The first\nthree seconds.","An establishing shot is what makes a listing video feel like a production."),
   ("disclose","Always disclosed","The aerial intro is marked as AI-generated on every tour it appears on."),
 ]},

{"slug":"floor-plan","feature":"Floor Plan",
 "hook":"Scan the room. Get the floor plan.",
 "sub":"3D room scanning on supported iPhones, or upload a plan you already have.",
 "slides":[
   ("points","Why buyers want it",["They cannot picture the layout from photos",
     "It answers the question every showing starts with","It is the page they screenshot"]),
   ("big","Measured,\nnot guessed.","Scanned in 3D with the phone's own sensors, so the shape is real."),
   ("points","Two ways in",["Scan it while you are already there",
     "Or upload the plan the builder gave you","Either way it lands on the tour page"]),
 ]},

{"slug":"two-links","feature":"Two Links, Every Time",
 "hook":"One link for the MLS. One for you.",
 "sub":"Every tour publishes twice: a branded page, and an unbranded twin.",
 "slides":[
   ("points","Why two",["The MLS forbids branding in a virtual-tour field",
     "Your own marketing needs your name on it","Doing it by hand is how agents get flagged"]),
   ("big","Branded.\nUnbranded.\nBoth, automatically.","You never have to think about which link goes where again."),
   ("points","What is on each",["Branded: your card, your photo, your contact form",
     "Unbranded: the tour, and nothing that identifies you",
     "Same flythrough, same rooms, same quality"]),
 ]},

{"slug":"agent-card","feature":"Your Card On Every Tour",
 "hook":"The tour gets forwarded. Your name goes with it.",
 "sub":"Name, business, photo, phone and social links on every branded page.",
 "slides":[
   ("points","Where tours end up",["Forwarded to a spouse who was not at the showing",
     "Sent to a parent helping with the down payment",
     "Posted in a group chat you will never see"]),
   ("big","Every forward\nis a referral.","If your name is on it."),
   ("points","On the card",["Your photo and your name","Your phone, tap to call",
     "Your socials, so they can check you out first"]),
 ]},

{"slug":"leads","feature":"Lead Capture",
 "hook":"The tour page asks for the enquiry",
 "sub":"A contact form sits on every branded tour. Enquiries land in the app.",
 "slides":[
   ("points","The gap this closes",["Someone watches the whole tour at 11pm",
     "They are not going to call you in the morning","They will type a name and a number right then"]),
   ("big","Watch, then ask.","The form is on the same page, at the end of the tour, while they are still interested."),
   ("points","What you get",["The enquiry in your inbox inside the app",
     "Which listing it came from","No third-party CRM required to start"]),
 ]},

{"slug":"modes","feature":"Not Only Homes",
 "hook":"Real estate is one of five modes",
 "sub":"Event venues, restaurants, retail and gyms each get their own.",
 "slides":[
   ("points","Who else needs a tour",["An event venue selling a Saturday in June",
     "A restaurant selling the private dining room",
     "A gym selling the floor before someone walks in"]),
   ("big","Pick your mode.\nThe app changes.","The fields you fill in, the words on screen and the sample tour all match what you sell."),
   ("points","Same engine underneath",["The same flythrough","The same share link",
     "The same photo tools, worded for your business"]),
 ]},

{"slug":"no-account","feature":"No Account Needed",
 "hook":"Use the whole thing without signing up",
 "sub":"Record, build, publish and share a tour without ever making an account.",
 "slides":[
   ("points","What works without an account",["Recording a walkthrough",
     "Building the flythrough","Publishing and sharing the link"]),
   ("big","Sign in only\nif you want to.","Sign in with Apple is optional. It carries your workspace to a new phone, and a team seat needs it because a seat belongs to a person."),
   ("points","Why we built it this way",["You should see it work before you commit",
     "No email wall between you and the product","Nothing is asked for that is not needed"]),
 ]},

{"slug":"disclosure","feature":"Every AI Edit Is Labelled",
 "hook":"We label the AI. On purpose.",
 "sub":"Every altered photo says so, and the untouched original is published beside it.",
 "slides":[
   ("points","Why this matters to you",["Misleading listing photos are a licence problem",
     "Buyers who feel tricked at the showing do not make offers",
     "Disclosure is becoming the rule, not the courtesy"]),
   ("big","The original\nis right there.","Every edited photo publishes with the real one alongside it. Nothing is hidden."),
   ("points","On every tour",["A visible virtually staged label",
     "The AI aerial marked as AI-generated","A compliance list of every AI asset used"]),
 ]},

{"slug":"plans","feature":"The Plans",
 "hook":"What a plan actually gets you",
 "sub":"Monthly allowances for tour renders and every AI feature.",
 "slides":[
   ("plans","Three plans",[("STARTER","$49/mo","4 tour renders · 100 photo edits · 6 reel clips · 2 aerial intros"),
                            ("PRO","$99/mo","10 tour renders · 200 photo edits · 12 reel clips · 4 aerial intros"),
                            ("TEAM","$249/mo","25 tour renders · 400 photo edits · 25 reel clips · 8 aerial intros · 2 seats")]),
   ("big","One listing.","That is roughly what a plan costs against what a single listing video used to."),
   ("points","Also worth knowing",["Starter and Pro are monthly or yearly",
     "Yearly is ten months for twelve","Every plan starts with 7 days free"]),
 ]},

{"slug":"free-trial","feature":"7 Days Free",
 "hook":"Seven days, then decide",
 "sub":"Every plan starts with a 7-day free trial. One per Apple ID.",
 "slides":[
   ("points","What to do with the week",["Put a real listing through it, not a test",
     "Send the link to an actual buyer","Watch what they do with it"]),
   ("big","Do not test it.\nUse it.","A trial spent on a fake listing tells you nothing. Run your next real one through it."),
   ("points","The fine print, plainly",["Cancel any time in your iPhone Settings",
     "Cancel 24 hours before it ends and you are not charged",
     "Nothing is charged during the trial"]),
 ]},

{"slug":"your-content","feature":"Your Content Stays Yours",
 "hook":"We do not train on your listings",
 "sub":"Your videos and photos are yours. Not our marketing. Not model training.",
 "slides":[
   ("points","What we will never do",["Use your media in our own marketing",
     "Train an AI model on it","Do either without your written permission"]),
   ("big","Written\npermission.","Not a checkbox you missed. Not a clause in an update. Written permission, or it does not happen."),
   ("points","Your side of it",["Only record spaces you have the right to record",
     "Only publish what you are allowed to publish","We say so in the app, not just the terms"]),
 ]},
]
