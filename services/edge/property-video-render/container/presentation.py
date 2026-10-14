"""Bounded native-option presentation, with two transition decoders maximum.

Uses server-installed Liberation Sans (SIL OFL), never Apple's proprietary font.
Text lives in controlled files; client strings never enter the filter syntax.
At30fps overlap is rounded to the nearest whole frame, and measured final
duration rather than an invented 5s*count is the output authority.
"""
import math
import os
import shutil
import textwrap
from pathlib import Path
from compose import QualityError, run


def transition_frames(name):
    if name not in {"cut", "dissolve", "whip"}:
        raise QualityError("unsupported_transition")
    return {"cut": 0, "dissolve": 8, "whip": 5}[name]


def encode_args():
    return ["-c:v", "libx264", "-preset", "medium", "-crf", "18", "-maxrate", "24M", "-bufsize", "48M", "-threads", "2", "-pix_fmt", "yuv420p",
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-movflags", "+faststart"]


def timeline(clips, directory, name):
    frames = transition_frames(name)
    if not frames or len(clips) == 1:
        return clips, 5.0 * len(clips), [5.0 * i for i in range(len(clips))]
    duration = frames / 30.0
    segments = []
    for i, clip in enumerate(clips):
        # Incoming/outgoing parts are in the transition; never duplicate them.
        start = duration if i else 0
        end = 5.0 - (duration if i < len(clips) - 1 else 0)
        body = directory / f"body-{i:03d}.mp4"
        run([shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-ss", str(start), "-i", str(clip),
             "-an", "-t", str(end - start), "-vf", "setpts=PTS-STARTPTS,fps=30,setsar=1", *encode_args(), str(body)])
        segments.append(body)
        if i < len(clips) - 1:
            bridge = directory / f"transition-{i:03d}.mp4"
            effect = "fade" if name == "dissolve" else "slideleft"
            filters = (f"[0:v]trim=duration={duration},setpts=PTS-STARTPTS,fps=30,settb=1/30[a];"
                       f"[1:v]trim=duration={duration},setpts=PTS-STARTPTS,fps=30,settb=1/30[b];"
                       f"[a][b]xfade=transition={effect}:duration={duration}:offset=0,fps=30,format=yuv420p[v]")
            run([shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-ss", str(5.0 - duration), "-i", str(clip),
                 "-i", str(clips[i + 1]), "-filter_complex_threads", "1", "-filter_complex", filters, "-map", "[v]", "-an", "-t", str(duration), *encode_args(), str(bridge)])
            segments.append(bridge)
    return segments, 5.0 * len(clips) - duration * (len(clips) - 1), [(5.0 - duration) * i for i in range(len(clips))]


def font_path():
    path = Path(os.environ.get("RENDER_FONT", "/usr/share/fonts/truetype/liberation2/LiberationSans-Bold.ttf"))
    if not path.is_file():
        raise QualityError("licensed_caption_font_missing")
    return path


def text_value(raw, max_length=250):
    if not isinstance(raw, str) or len(raw) > max_length or any(ord(c) < 32 and c not in "\n\t" for c in raw):
        raise QualityError("bounded_caption_text")
    return " ".join(raw.split())


def overlay(source, directory, width, height, presentation, starts, elapsed, words):
    title = presentation.get("title_card")
    labels = presentation.get("shot_labels", [])
    style = presentation.get("shot_caption_style", "off")
    spoken = presentation.get("spoken_captions", False)
    if style not in {"off", "lowerThird", "punchCard", "highlightBox"} or not isinstance(spoken, bool):
        raise QualityError("unsupported_caption_style")
    if len(labels) not in {0, len(starts)} or len(words) > 2000:
        raise QualityError("caption_identity_conflict")
    if not title and (style == "off" or not any(labels)) and not (spoken and words):
        return source
    font = font_path()
    filters = []
    counter = 0
    def text(raw, size, x, y, start, end, *, box=False, alpha="1", wrap=36):
        nonlocal counter
        value = text_value(raw)
        if not value or end <= start:
            return
        rows = textwrap.wrap(value, width=wrap, break_long_words=False, break_on_hyphens=False)
        if len(rows) > 3:
            raise QualityError("caption_too_long_for_canvas")
        path = directory / f"text-{counter:04d}.txt"
        counter += 1
        path.write_text("\n".join(rows), encoding="utf-8")
        # All interpolated paths/numbers are controller-generated, never text.
        def escaped(raw):
            return str(raw).replace("\\", "\\\\").replace("'", "\\'").replace(":", "\\:")
        filters.append(f"drawtext=fontfile='{escaped(font)}':textfile='{escaped(path)}':expansion=none:fontsize={size}:"
                       f"fontcolor=white:x={x}:y={y}:borderw=3:bordercolor=black@0.6:line_spacing=8:"
                       f"alpha='{alpha}':enable='gte(t,{start})*lt(t,{end})'" + (":box=1:boxcolor=0x7938ef:boxborderw=12" if box else ""))
    if title:
        text(title.get("title", ""), 62, "(w-text_w)/2", "h*0.38-text_h/2", 0, min(2, elapsed), alpha="if(lt(t,1.6),1,max(0,(2-t)/0.4))", wrap=28 if width == 1080 else 48)
        text(title.get("subtitle", ""), 39, "(w-text_w)/2", "h*0.47", 0, min(2, elapsed), alpha="if(lt(t,1.6),1,max(0,(2-t)/0.4))", wrap=40)
        text(title.get("watermark", ""), 28, "w-text_w-75", "h-text_h-75", 0, elapsed, alpha="0.55", wrap=40)
    if style != "off":
        for i, raw in enumerate(labels):
            if raw is None:
                continue
            start, end = max(starts[i], 2 if title else 0), min(elapsed, starts[i] + 5)
            if end - start < .5:
                continue
            raw = " ".join(text_value(raw).upper().split()[:5])
            centered = style == "punchCard"
            top = .36 if centered and spoken else .42 if centered else .62 if spoken else .8
            if style == "lowerThird":
                filters.append(f"drawbox=x=55:y=ih*{top}-90:w=7:h=90:color=0x7938ef:t=fill:enable='gte(t,{start})*lt(t,{end})'")
            text(raw, 78 if not centered else 96, "(w-text_w)/2" if centered else "w*0.07", f"h*{top}-text_h", start, end, box=style == "highlightBox", wrap=22 if width == 1080 else 36)
    if spoken:
        last = 0.0
        for word in words:
            start, end = float(word["start"]), float(word["end"])
            if not math.isfinite(start) or not math.isfinite(end) or start < last or not start < end <= elapsed + .1:
                raise QualityError("word_timing_refused")
            last = start
            text(word["text"], 68, "(w-text_w)/2", "h*0.84-text_h", start, min(end, elapsed), wrap=24)
    if not filters:
        return source
    output = directory / "presented.mp4"
    script = directory / "overlays.txt"
    script.write_text(",".join(filters))
    run([shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", str(source),
         "-an", "-filter_script:v", str(script), *encode_args(), str(output)], timeout=1200)
    return output
