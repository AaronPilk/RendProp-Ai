#!/usr/bin/env python3
"""build_onboarding.py — the raw simulator take → the narrated onboarding video.

    python3 tools/video/build_onboarding.py --raw tour-raw.mp4 --marks marks.txt \
        --script docs/marketing/onboarding-video-script.md --narration narration/ --out out/

Inputs
  --raw        the screen recording from bridge-cmd-onboardingtour.sh (any size, portrait)
  --marks      its marks.txt: one `TOUR_MARK <segment> <seconds>` per segment (+ END)
  --script     the .md script; `## NN · M:SS–M:SS · Title` headings + `Caption:` lines
  --narration  optional dir with one audio file per segment: 01.mp3, 02.wav, 03.m4a …
Outputs (in --out)
  onboarding.mp4       1080-wide master at the source aspect (1206×2622 → 1080×2348),
                       H.264 + AAC, faststart, captions burned in, title + end card
  onboarding-9x16.mp4  1080×1920 social cut, derived from the master (rules in `social_filter`)
  captions.ass, timeline.json, narration-script.txt (the Say: lines, for a TTS pass)

Rules
  • The take is cut at the marks: segment k runs from mark k to mark k+1 (END closes the last).
  • A narration longer than its segment FREEZES that segment's last frame (tpad clone) until
    the narration ends, plus --tail; segments after it shift accordingly. (Chosen over "just
    let it overlap": the caption and the voice always describe the screen that is showing.)
  • A segment with no mark is dropped — no video, no narration, no caption for it.
  • Captions sit in the bottom third, white with a dark outline, at most two lines.

Script fields per segment (all optional but Caption/Say): `Caption:`, `Say:`, `On screen:` /
`Shot:` (ignored by the build), `Hook:` (a short line burned in at the TOP of the frame while
the segment's narration ends — the loop-back tease), `Trim: 9 s` (use only the first 9 s of
the segment's take footage, before pacing — a render wait, a long load).

Cards: `--title-seconds 0` drops the title card (a cold open). `--end-card TEXT` adds a card
after the body in the caption style (centred, same font and box) for `--end-card-seconds`,
before the rendprop.com / App Store card (`--end-seconds 0` drops that one).
`--hook-card ID=TEXT` adds or overrides a segment's Hook: from the command line.
`--only-scripted` drops marks the script does not mention — the same take and marks build a
30 s or 15 s cut from a shorter script that keeps the segment ids.
stdlib + ffmpeg/ffprobe only.
"""
import argparse, glob, json, os, re, shutil, subprocess, sys

FONT_PREFS = [  # (family, file globs) — first hit wins; a clean sans first
    ("Inter", ["/usr/share/fonts/**/Inter-Medium.ttf", "/usr/share/fonts/**/Inter-Regular.ttf",
               "/Library/Fonts/Inter-Medium.ttf", os.path.expanduser("~/Library/Fonts/Inter-Medium.ttf")]),
    ("Helvetica Neue", ["/System/Library/Fonts/HelveticaNeue.ttc"]),
    ("Poppins", ["/usr/share/fonts/**/Poppins-Medium.ttf", "/usr/share/fonts/**/Poppins-Regular.ttf"]),
    ("Noto Sans", ["/usr/share/fonts/**/NotoSans-Medium.ttf", "/usr/share/fonts/**/NotoSans-Regular.ttf"]),
    ("Roboto", ["/usr/share/fonts/**/Roboto-Medium.ttf", "/usr/share/fonts/**/Roboto-Regular.ttf"]),
    ("Liberation Sans", ["/usr/share/fonts/**/LiberationSans-Regular.ttf"]),
    ("DejaVu Sans", ["/usr/share/fonts/**/DejaVuSans.ttf"]),
    ("Arial", ["/System/Library/Fonts/Supplemental/Arial.ttf", "/Library/Fonts/Arial.ttf",
               "/usr/share/fonts/**/Arial.ttf"]),
]
AUDIO_EXT = (".mp3", ".wav", ".m4a", ".aac", ".ogg", ".flac")
DARK = "0x0B0B10"


def run(cmd, capture=False):
    if capture:
        return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    subprocess.run(cmd, check=True)


def probe(path):
    """width, height, duration, has_audio — via ffprobe."""
    out = run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type,width,height:format=duration",
               "-of", "json", path], capture=True)
    doc = json.loads(out)
    info = {"width": 0, "height": 0, "duration": float(doc.get("format", {}).get("duration", 0) or 0),
            "has_audio": False}
    for s in doc.get("streams", []):
        if s.get("codec_type") == "video" and not info["width"]:
            info["width"], info["height"] = int(s.get("width", 0)), int(s.get("height", 0))
        if s.get("codec_type") == "audio":
            info["has_audio"] = True
    return info


def parse_marks(path):
    """[(segment_id, seconds)] in file order, and the clock the marks were stamped on."""
    marks, clock = [], "unknown"
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        m = re.match(r"^#.*clock=(\w+)", line)
        if m:
            clock = m.group(1)
        m = re.match(r"^TOUR_MARK\s+(\S+)\s+([0-9.]+)", line)
        if m:
            marks.append((m.group(1), float(m.group(2))))
    return marks, clock


def parse_script(path):
    """{segment_id: {title, target, caption, say, hook, trim}} from the markdown script.

    `Hook:` is a wrapped multi-line field like Caption/Say. `Trim: 9 s` is a single
    value (seconds, the `s` optional) — not a wrapped field, so a line under it starts
    fresh rather than appending. `On screen:` / `Shot:` are recognised so a wrapped
    line under either does not spill into whatever field came before it, but neither
    is stored — the build only reads what it draws or speaks."""
    segs, cur = {}, None
    head = re.compile(r"^##\s+(\d{2})\s+·\s+(\d+):(\d{2})[–-](\d+):(\d{2})\s+·\s+(.+?)\s*$")
    field_re = re.compile(r"^\**(Caption|Say|Hook|On screen|Shot|Trim)\**:\**\s*(.*)$")
    stored = {"Caption": "caption", "Say": "say", "Hook": "hook"}
    for raw in open(path, encoding="utf-8"):
        line = raw.rstrip("\n")
        m = head.match(line)
        if m:
            sid, a, b, c, d, title = m.groups()
            cur = segs[sid] = {"title": title.strip(), "caption": "", "say": "", "hook": "",
                               "trim": None, "_field": None,
                               "target": (int(c) * 60 + int(d)) - (int(a) * 60 + int(b))}
            continue
        if line.startswith("## ") or line.startswith("---"):
            cur = None
            continue
        if cur is None:
            continue
        m = field_re.match(line)
        if m:
            label, rest = m.group(1), m.group(2).strip()
            if label == "Trim":
                tm = re.match(r"^([0-9.]+)\s*s?\b", rest)
                cur["trim"] = float(tm.group(1)) if tm else None
                cur["_field"] = None
            else:
                cur["_field"] = stored.get(label)          # None for On screen / Shot
                if cur["_field"]:
                    cur[cur["_field"]] = rest
        elif line.strip() == "":
            cur["_field"] = None
        elif cur["_field"]:                       # a wrapped continuation line
            cur[cur["_field"]] += " " + line.strip()
    for s in segs.values():
        s.pop("_field", None)
    return segs


def find_narration(folder, sid):
    if not folder:
        return None
    for ext in AUDIO_EXT:
        p = os.path.join(folder, sid + ext)
        if os.path.exists(p):
            return p
    return None


def pick_font(explicit):
    """(family, file) — the first preferred sans that exists here, via fc-list then known paths."""
    if explicit:
        return os.path.splitext(os.path.basename(explicit))[0].split("-")[0], explicit
    fc = {}
    if shutil.which("fc-list"):
        try:
            for line in run(["fc-list", ":", "family", "file"], capture=True).splitlines():
                if ":" in line:
                    file_, fam = line.split(":", 1)
                    for f in fam.split(","):
                        fc.setdefault(f.strip(), []).append(file_.strip())
        except subprocess.CalledProcessError:
            pass
    for family, globs in FONT_PREFS:
        files = [f for f in fc.get(family, []) if re.search(r"(Medium|Regular)(?!Italic)", f) or f.endswith(".ttc")]
        files.sort(key=lambda f: ("Medium" not in f, "Regular" not in f, f))
        for g in globs:
            files += glob.glob(g, recursive=True)
        files = [f for f in files if os.path.exists(f)]
        if files:
            return family, files[0]
    sys.exit("No usable font found — pass --font /path/to/a-sans.ttf")


def wrap_caption(text, max_chars):
    """One line when it fits, else the two-line split with the shortest long line; returns (lines, overflowed)."""
    words = text.split()
    if len(text) <= max_chars or len(words) < 2:
        return [text], len(text) > max_chars + 4
    best = min(range(1, len(words)), key=lambda i: max(len(" ".join(words[:i])), len(" ".join(words[i:]))))
    lines = [" ".join(words[:best]), " ".join(words[best:])]
    return lines, max(len(l) for l in lines) > max_chars + 4


def ass_time(t):
    h, rem = divmod(max(t, 0.0), 3600)
    m, s = divmod(rem, 60)
    return "%d:%02d:%05.2f" % (h, m, s)


def write_ass(path, timeline, W, H, family):
    fs, margin_v, margin_lr = round(W * 0.064), round(H * 0.19), round(W * 0.07)
    hook_fs, hook_margin_v = round(fs * 0.86), round(H * 0.05)
    lines = ["[Script Info]", "ScriptType: v4.00+", "PlayResX: %d" % W, "PlayResY: %d" % H, "WrapStyle: 2",
             "ScaledBorderAndShadow: yes", "", "[V4+ Styles]",
             "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, "
             "Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, "
             "Alignment, MarginL, MarginR, MarginV, Encoding",
             # BorderStyle 3 = an opaque box behind the text (BackColour, ~70% opaque
             # near-black): readable over the app's brightest tiles. Outline = the
             # box padding.
             "Style: Cap,%s,%d,&H00FFFFFF,&H00FFFFFF,&H4D141018,&H4D141018,1,0,0,0,100,100,0,0,3,%d,0,2,%d,%d,%d,1"
             % (family, fs, max(10, round(fs * 0.32)), margin_lr, margin_lr, margin_v),
             # Hook,: Alignment 8 = top-centre — the loop-back tease, out of the
             # caption's way, in the same box look at a slightly smaller size.
             "Style: Hook,%s,%d,&H00FFFFFF,&H00FFFFFF,&H4D141018,&H4D141018,1,0,0,0,100,100,0,0,3,%d,0,8,%d,%d,%d,1"
             % (family, hook_fs, max(9, round(hook_fs * 0.32)), margin_lr, margin_lr, hook_margin_v),
             "", "[Events]", "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text"]
    for seg in timeline:
        if seg["caption_lines"]:
            lines.append("Dialogue: 0,%s,%s,Cap,,0,0,0,,%s" % (
                ass_time(seg["out_start"] + 0.15), ass_time(seg["out_end"] - 0.15), "\\N".join(seg["caption_lines"])))
        if seg.get("hook_lines"):
            lines.append("Dialogue: 1,%s,%s,Hook,,0,0,0,,%s" % (
                ass_time(seg["hook_start"]), ass_time(seg["hook_end"]), "\\N".join(seg["hook_lines"])))
    open(path, "w", encoding="utf-8").write("\n".join(lines) + "\n")


def fesc(value):
    """Escape a value for use inside a filtergraph option (ffmpeg's level-1 escaping)."""
    return re.sub(r"([\\:,;'\[\]])", r"\\\1", str(value))


def drawtext(font_file, text, size, y_expr, color="white"):
    return ("drawtext=fontfile=%s:text=%s:fontsize=%d:fontcolor=%s:x=(w-text_w)/2:y=%s"
            % (fesc(font_file), fesc(text), size, color, y_expr))


def card(label, W, H, fps, seconds, font_file, big, small):
    f = "color=c=%s:s=%dx%d:r=%d:d=%.2f,format=yuv420p" % (DARK, W, H, fps, seconds)
    f += "," + drawtext(font_file, big, round(W * 0.11), "(h-text_h)/2-%d" % round(W * 0.07))
    f += "," + drawtext(font_file, small, round(W * 0.05), "(h-text_h)/2+%d" % round(W * 0.06), "0xC9C7D3")
    return f + "[%s]" % label


def end_card_max_chars(W):
    """Chars/line for `--end-card`: its own, more conservative budget than the
    caption's. `write_ass`'s max_chars is tuned for the caption's usual short
    phrase on whatever sans the Mac finds (Inter / Helvetica Neue); a CTA line is
    fixed text nobody will shorten in response to a warning, so this measures
    against a wide fallback sans instead of trusting that estimate (Poppins,
    ~0.48× fontsize per character, at the caption style's own W*0.064 size)."""
    fs = round(W * 0.064)
    return max(10, int(W * 0.82 / (fs * 0.52)))


def caption_style_card(label, W, H, fps, seconds, font_file, text):
    """A card in the CAPTION's own look (its font size + the same dark box) rather
    than the title/end card's big-headline look — for `--end-card`, which reads as
    one more thing the video says, not a logo slide. Returns (filter_str,
    overflowed) — main() warns on overflow the same way captions do."""
    fs = round(W * 0.064)                       # the caption style's own size (write_ass)
    lines, overflow = wrap_caption(text, end_card_max_chars(W))
    pad = max(14, round(fs * 0.34))
    gap = round(fs * 1.3)
    n = len(lines)
    f = "color=c=%s:s=%dx%d:r=%d:d=%.2f,format=yuv420p" % (DARK, W, H, fps, seconds)
    for i, line in enumerate(lines):
        offset = round((i - (n - 1) / 2.0) * gap)
        f += (",drawtext=fontfile=%s:text=%s:fontsize=%d:fontcolor=white:box=1:boxcolor=%s@0.78:"
              "boxborderw=%d:x=(w-text_w)/2:y=(h-text_h)/2%+d"
              % (fesc(font_file), fesc(line), fs, DARK, pad, offset))
    return f + "[%s]" % label, overflow


def social_filter(W, H):
    """1080×1920 from the master: fit inside, pad the sides on the dark card colour (no crop —
    the nav bar's type capsule and the tab bar both matter). A wider-than-9:16 source (never
    from the simulator) would instead be scaled to width and centre-cropped in height."""
    if W / H <= 1080 / 1920:
        return "scale=-2:1920:flags=lanczos,pad=1080:1920:(ow-iw)/2:(oh-ih)/2:color=%s" % DARK
    return "scale=1080:-2:flags=lanczos,crop=1080:1920"


def pace_segment(seg_len, narr_dur, tail, fit, min_len, max_len, max_speed):
    """How a segment of the take becomes a segment of the video.

    A UI walk is mostly waiting — elements settling, screens loading — so the
    take runs 2–4x longer than anyone would watch. With `fit` on, each segment
    is paced to its narration but never loses its content: the target length
    is the longer of (narration + tail) and (the whole segment at max_speed),
    clamped to [min_len, max_len]. The segment is sped up uniformly (setpts)
    to that length — every screen of the step stays in, just faster — and only
    a segment that would still run past max_len at max_speed is trimmed at
    the end. A segment shorter than its narration is held on its last frame,
    as before. The narration starts with the segment; a segment longer than
    its narration simply plays on under the caption.

    Returns (speed, src_len_used, out_len, hold)."""
    if not fit:
        hold = max(0.0, narr_dur + tail - seg_len) if narr_dur else 0.0
        return 1.0, seg_len, seg_len, hold
    wanted = (narr_dur + tail) if narr_dur else min_len
    target = max(min_len, min(max_len, max(wanted, seg_len / max_speed)))
    if seg_len <= target:
        hold = max(0.0, narr_dur + tail - seg_len) if narr_dur else 0.0
        return 1.0, seg_len, seg_len, hold
    speed = min(max_speed, seg_len / target)
    src_used = min(seg_len, target * speed)          # trim the end only when max_len bites
    out_len = src_used / speed
    hold = max(0.0, narr_dur + tail - out_len) if narr_dur else 0.0
    return round(speed, 4), round(src_used, 3), round(out_len, 3), round(hold, 3)


def parse_sources(values):
    """--source 13=141.5-157 → {"13": (141.5, 157.0)}: the take range a segment
    should use instead of its marks (the walk ended on the springboard, the
    step's own footage is dull, a screen from earlier says it better)."""
    out = {}
    for value in values or []:
        m = re.match(r"^\s*(\w+)\s*=\s*([0-9.]+)\s*-\s*([0-9.]+)\s*$", value)
        if not m:
            raise SystemExit("--source wants ID=START-END in take seconds, got %r" % value)
        a, b = float(m.group(2)), float(m.group(3))
        if b <= a:
            raise SystemExit("--source %s: END must be after START" % value)
        out[m.group(1)] = (a, b)
    return out


def parse_hook_cards(values):
    """--hook-card ID=TEXT → {"ID": "TEXT"}: sets or overrides a segment's Hook:
    line from the command line, e.g. for a cut-down script that skips the Hook:
    fields but should still tease the next one. TEXT may itself contain '=', so
    only the first one splits the id off."""
    out = {}
    for value in values or []:
        if "=" not in value:
            raise SystemExit("--hook-card wants ID=TEXT, got %r" % value)
        sid, text = value.split("=", 1)
        sid, text = sid.strip(), text.strip()
        if not sid or not text:
            raise SystemExit("--hook-card wants ID=TEXT, got %r" % value)
        out[sid] = text
    return out


def build_timeline(marks, script, raw_dur, narration_dir, offset, tail,
                   fit=False, min_len=5.0, max_len=20.0, max_speed=4.0, sources=None,
                   only_scripted=False):
    segs, warnings = [], []
    sources = sources or {}
    ids = [m[0] for m in marks]
    if "END" not in ids:
        warnings.append("no TOUR_MARK END — the last segment ends at its scripted target length")
    for i, (sid, t) in enumerate(marks):
        if sid == "END":
            break
        start = t + offset
        if i + 1 < len(marks):
            end = marks[i + 1][1] + offset
        else:
            end = start + script.get(sid, {}).get("target", 8)
        if sid in sources:
            start, end = sources[sid]
            warnings.append("segment %s uses the take at %.1f–%.1fs (--source), not its marks" % (sid, start, end))
        start, end = max(0.0, start), min(end, raw_dur)
        if end - start < 0.5:
            warnings.append("segment %s is %.2fs long in the take — dropped" % (sid, end - start))
            continue
        sc = script.get(sid)
        if sc is None:
            if only_scripted:
                warnings.append("segment %s is not in this script — dropped (--only-scripted)" % sid)
                continue
            warnings.append("mark %s has no segment in the script — no caption, no narration" % sid)
            sc = {"title": sid, "caption": "", "say": "", "hook": "", "trim": None, "target": 0}
        if sc.get("trim"):                        # Trim: cap the take BEFORE pacing (a render wait, a long load)
            trimmed_end = start + sc["trim"]
            if trimmed_end < end:
                end = trimmed_end
        narr = find_narration(narration_dir, sid)
        narr_dur = probe(narr)["duration"] if narr else 0.0
        seg_len = end - start
        speed, src_used, out_len, pad = pace_segment(seg_len, narr_dur if narr else 0.0, tail,
                                                     fit, min_len, max_len, max_speed)
        segs.append({"id": sid, "title": sc["title"], "src_start": round(start, 3),
                     "src_end": round(start + src_used, 3), "take_len": round(seg_len, 3),
                     "speed": speed, "len": round(out_len, 3), "narration": narr,
                     "narration_len": round(narr_dur, 3), "hold": round(pad, 3),
                     "caption": sc["caption"], "say": sc["say"], "hook": sc.get("hook", ""),
                     "target": sc["target"]})
    for sid in script:
        if sid not in ("00", "99") and sid not in [s["id"] for s in segs]:
            warnings.append("script segment %s has no mark in the take — skipped" % sid)
    return segs, warnings


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--raw", required=True); ap.add_argument("--marks", required=True)
    ap.add_argument("--script", required=True); ap.add_argument("--narration")
    ap.add_argument("--out", required=True)
    ap.add_argument("--offset", type=float, default=0.0, help="seconds added to every mark (negative = earlier)")
    ap.add_argument("--tail", type=float, default=0.4, help="breathing room after a narration that runs long")
    ap.add_argument("--width", type=int, default=1080); ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--gain", type=float, default=0.0, help="narration gain in dB")
    ap.add_argument("--font", help="a .ttf/.otf to use instead of the first one found")
    ap.add_argument("--title", default="Rendprop"); ap.add_argument("--subtitle", default="How it works")
    ap.add_argument("--end1", default="rendprop.com"); ap.add_argument("--end2", default="Rendprop on the App Store")
    ap.add_argument("--title-seconds", type=float, default=1.5,
                    help="0 drops the title card entirely — a cold open straight into segment 1")
    ap.add_argument("--end-seconds", type=float, default=2.0,
                    help="0 drops the rendprop.com / App Store card entirely")
    ap.add_argument("--end-card", help="one more card after the body, in the caption's look (e.g. the closing CTA)")
    ap.add_argument("--end-card-seconds", type=float, default=3.0)
    ap.add_argument("--fit", action="store_true",
                    help="pace every segment to its narration: speed up (max --max-speed) then trim the end; "
                         "a segment with no narration keeps --min-len seconds")
    ap.add_argument("--min-len", type=float, default=5.0); ap.add_argument("--max-len", type=float, default=20.0)
    ap.add_argument("--max-speed", type=float, default=4.0)
    ap.add_argument("--source", action="append", metavar="ID=START-END",
                    help="take range (seconds) for a segment instead of its marks; repeatable")
    ap.add_argument("--hook-card", action="append", metavar="ID=TEXT",
                    help="set or override a segment's Hook: loop-back tease from the command line; repeatable")
    ap.add_argument("--hook-seconds", type=float, default=2.5,
                    help="how long before a segment's end its Hook: line shows, top of frame")
    ap.add_argument("--only-scripted", action="store_true",
                    help="drop any mark this script does not have a heading for, instead of showing it "
                         "caption-less — build a 30s/15s cut-down from the same take and marks.txt by pointing "
                         "--script at a shorter script that only headers the segment ids it keeps")
    ap.add_argument("--preset", default="medium", help="libx264 preset (veryfast on a small machine)")
    ap.add_argument("--crf", type=int, default=18)
    ap.add_argument("--dry-run", action="store_true", help="validate, print the timeline and the commands, build nothing")
    a = ap.parse_args()

    for tool in ("ffmpeg", "ffprobe"):
        if not shutil.which(tool):
            sys.exit("%s is not on PATH (brew install ffmpeg / apt install ffmpeg)" % tool)
    # "Error : Filter not found" is all ffmpeg says when a build lacks a filter;
    # name the missing one instead (drawtext needs libfreetype, subtitles libass).
    have = set(re.findall(r"^\s*[TSC.]{3}\s+(\S+)", run(["ffmpeg", "-hide_banner", "-filters"], capture=True), re.M))
    need = ["drawtext", "subtitles", "tpad", "trim", "setpts", "fps", "scale", "split", "concat", "color",
            "anullsrc", "aresample", "aformat", "volume", "adelay", "amix", "crop", "pad"]
    missing = [f for f in need if f not in have]
    if missing:
        sys.exit("this ffmpeg lacks the filter(s) %s — use a build with libfreetype + libass "
                 "(brew's ffmpeg formula has both; a static download often does not)" % ", ".join(missing))
    for p in (a.raw, a.marks, a.script):
        if not os.path.exists(p):
            sys.exit("missing input: %s" % p)
    if a.narration and not os.path.isdir(a.narration):
        print("WARN narration dir %s does not exist — building captions-only" % a.narration)
        a.narration = None
    os.makedirs(a.out, exist_ok=True)

    raw = probe(a.raw)
    if not raw["width"] or raw["duration"] <= 0:
        sys.exit("%s has no readable video stream" % a.raw)
    marks, clock = parse_marks(a.marks)
    if not marks:
        sys.exit("no TOUR_MARK lines in %s" % a.marks)
    if clock != "recording":
        print("WARN marks clock=%s — they count from app launch, not from the recording; pass --offset "
              "<seconds from the recording's start to the app's launch>" % clock)
    script = parse_script(a.script)
    family, font_file = pick_font(a.font)
    W = a.width
    H = int(round(W * raw["height"] / raw["width"] / 2.0)) * 2
    segs, warnings = build_timeline(marks, script, raw["duration"], a.narration, a.offset, a.tail,
                                    fit=a.fit, min_len=a.min_len, max_len=a.max_len, max_speed=a.max_speed,
                                    sources=parse_sources(a.source), only_scripted=a.only_scripted)
    if not segs:
        sys.exit("no usable segments (check the marks against the take's %.1fs, or --only-scripted against the script)"
                 % raw["duration"])
    for sid, text in parse_hook_cards(a.hook_card).items():
        hit = [s for s in segs if s["id"] == sid]
        if not hit:
            warnings.append("--hook-card %s: no such segment in this build" % sid)
        for s in hit:
            s["hook"] = text

    # Output timeline + captions.
    max_chars = max(20, int(1 / (0.058 * 0.52)))       # ~ characters per line at the caption size
    t0 = a.title_seconds if a.title_seconds > 0 else 0.0
    t = t0
    for s in segs:
        s["out_start"] = round(t, 3)
        t += s["len"] + s["hold"]
        s["out_end"] = round(t, 3)
        s["caption_lines"], overflow = wrap_caption(s["caption"], max_chars) if s["caption"] else ([], False)
        if overflow:
            warnings.append("caption %s needs more than two lines — shorten it" % s["id"])
        if s["hook"]:
            s["hook_lines"], hover = wrap_caption(s["hook"], max_chars)
            if hover:
                warnings.append("hook %s needs more than two lines — shorten it" % s["id"])
            lead = min(a.hook_seconds, max(0.5, (s["out_end"] - s["out_start"]) - 0.2))
            s["hook_start"], s["hook_end"] = round(s["out_end"] - lead, 3), round(s["out_end"] - 0.1, 3)
        else:
            s["hook_lines"] = []
    body_end = t
    end_card_secs = a.end_card_seconds if a.end_card else 0.0
    end_secs = max(0.0, a.end_seconds)
    total = body_end + end_card_secs + end_secs
    if total > 150:
        warnings.append("total %.1fs is over the 150 s target — tighten the take or the narration" % total)
    if a.end_card and wrap_caption(a.end_card, end_card_max_chars(W))[1]:
        warnings.append("--end-card needs more than two lines — shorten it")

    # ---- report
    print("take: %dx%d %.1fs  marks: %d (%s clock)  font: %s  master: %dx%d@%d" % (
        raw["width"], raw["height"], raw["duration"], len(marks), clock, family, W, H, a.fps))
    print("%-4s %-28s %-15s %5s %6s %8s %6s %-15s %s" % ("seg", "title", "take", "x", "len", "narr", "hold", "out", "caption"))
    for s in segs:
        cap = " / ".join(s["caption_lines"])
        if s["hook"]:
            cap += "   HOOK@%.1fs: %s" % (s["hook_start"], s["hook"])
        print("%-4s %-28s %6.2f–%-7.2f %5.2f %6.2f %8s %6.2f %6.2f–%-7.2f %s" % (
            s["id"], s["title"][:28], s["src_start"], s["src_end"], s["speed"], s["len"],
            ("%.2f" % s["narration_len"]) if s["narration"] else "—", s["hold"], s["out_start"], s["out_end"], cap))
    card_bits = []
    if t0 > 0: card_bits.append("title %.1fs" % t0)
    if end_card_secs: card_bits.append("end-card %.1fs" % end_card_secs)
    if end_secs > 0: card_bits.append("end %.1fs" % end_secs)
    print("cards: %s   body %.1fs   TOTAL %.1fs" % (" + ".join(card_bits) or "none (cold open, no end cards)",
                                                     body_end - t0, total))
    for w in warnings:
        print("WARN " + w)
    json.dump({"take": raw, "clock": clock, "offset": a.offset, "master": [W, H], "segments": segs,
               "total": round(total, 3)}, open(os.path.join(a.out, "timeline.json"), "w"), indent=2)
    open(os.path.join(a.out, "narration-script.txt"), "w", encoding="utf-8").write(
        "".join("%s %s\n%s\n\n" % (s["id"], s["title"], s["say"]) for s in segs))
    ass_path = os.path.join(a.out, "captions.ass")
    write_ass(ass_path, segs, W, H, family)

    # ---- ffmpeg: video branches
    n = len(segs)
    fc = ["[0:v]fps=%d,scale=%d:%d:flags=lanczos,setsar=1,format=yuv420p,split=%d%s"
          % (a.fps, W, H, n, "".join("[v%d]" % i for i in range(n)))]
    for i, s in enumerate(segs):
        f = "[v%d]trim=start=%.3f:end=%.3f,setpts=PTS-STARTPTS" % (i, s["src_start"], s["src_end"])
        if s["speed"] > 1.0:
            f += ",setpts=PTS/%.4f,fps=%d" % (s["speed"], a.fps)
        if s["hold"] > 0:
            f += ",tpad=stop_mode=clone:stop_duration=%.3f" % s["hold"]
        fc.append(f + "[c%d]" % i)
    concat_in = []
    if t0 > 0:
        fc.append(card("title", W, H, a.fps, t0, font_file, a.title, a.subtitle))
        concat_in.append("[title]")
    concat_in += ["[c%d]" % i for i in range(n)]
    if a.end_card:
        fc.append(caption_style_card("endcard", W, H, a.fps, end_card_secs, font_file, a.end_card)[0])
        concat_in.append("[endcard]")
    if end_secs > 0:
        fc.append(card("end", W, H, a.fps, end_secs, font_file, a.end1, a.end2))
        concat_in.append("[end]")
    fc.append("%sconcat=n=%d:v=1:a=0[vcat]" % ("".join(concat_in), len(concat_in)))
    fc.append("[vcat]subtitles=filename=%s:fontsdir=%s[vout]" % (fesc("captions.ass"), fesc(os.path.dirname(font_file))))
    # ---- ffmpeg: audio — silence bed + each narration delayed to its segment's start
    inputs, alabels = [], []
    fc.append("anullsrc=r=48000:cl=stereo:d=%.3f[a0]" % total)
    for s in segs:
        if s["narration"]:
            idx = len(alabels) + 1                     # ffmpeg input index: 0 is the take
            inputs += ["-i", os.path.abspath(s["narration"])]
            fc.append("[%d:a]aresample=48000,aformat=channel_layouts=stereo,volume=%.1fdB,adelay=%d|%d[a%d]"
                      % (idx, a.gain, int(s["out_start"] * 1000), int(s["out_start"] * 1000), idx))
            alabels.append("[a%d]" % idx)
    fc.append("[a0]%samix=inputs=%d:duration=first:dropout_transition=0:normalize=0[aout]" % ("".join(alabels), len(alabels) + 1))

    master = os.path.abspath(os.path.join(a.out, "onboarding.mp4"))
    social = os.path.abspath(os.path.join(a.out, "onboarding-9x16.mp4"))
    cmd1 = ["ffmpeg", "-y", "-loglevel", "error", "-stats", "-i", os.path.abspath(a.raw)] + inputs + [
        "-filter_complex", ";".join(fc), "-map", "[vout]", "-map", "[aout]",
        "-c:v", "libx264", "-preset", a.preset, "-crf", str(a.crf), "-pix_fmt", "yuv420p", "-r", str(a.fps),
        "-c:a", "aac", "-b:a", "160k", "-ar", "48000", "-movflags", "+faststart", "-t", "%.3f" % total, master]
    cmd2 = ["ffmpeg", "-y", "-loglevel", "error", "-stats", "-i", master, "-vf", social_filter(W, H),
            "-c:v", "libx264", "-preset", a.preset, "-crf", str(a.crf), "-pix_fmt", "yuv420p",
            "-c:a", "copy", "-movflags", "+faststart", social]
    if a.dry_run:
        print("DRY RUN — wrote captions.ass, timeline.json, narration-script.txt to %s; would run:" % a.out)
        print("  (cd %s && %s)" % (a.out, " ".join(repr(c) if " " in c or ";" in c else c for c in cmd1)))
        print("  " + " ".join(cmd2))
        return
    run_in = dict(cwd=a.out)      # the subtitles filter gets a bare `captions.ass` — no path escaping games
    for label, cmd in (("master", cmd1), ("9x16", cmd2)):
        r = subprocess.run(cmd, capture_output=True, text=True, **run_in)
        if r.returncode != 0:
            sys.exit("ffmpeg (%s) failed with exit %d:\n%s" % (label, r.returncode, r.stderr.strip()[-3000:]))
    for p in (master, social):
        i = probe(p)
        print("OK %s  %dx%d  %.1fs  audio=%s  %.1f MB" % (os.path.basename(p), i["width"], i["height"], i["duration"],
                                                          i["has_audio"], os.path.getsize(p) / 1e6))
    if not any(s["narration"] for s in segs):
        print("NOTE captions-only: no narration files found%s — add narration/NN.mp3 and rebuild"
              % (" in " + a.narration if a.narration else ""))


if __name__ == "__main__":
    main()
