#!/usr/bin/env python3
"""Assemble the offline first-listing guide from actual Rendprop captures.

No UI is simulated by this renderer. Each pictured screen must be a checked-in
capture of the current iOS app or its property website. Narration comes from
owner-approved ElevenLabs scene files supplied in --voice-dir; this command
never calls a paid service or silently falls back to a system voice.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageOps

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "docs/marketing/quick-start-20261028"
CAPTURES = SOURCE / "captures"
VOICE_MASTERS = SOURCE / "voice"
MOVIE = ROOT / "apps/ios/Rendprop/Resources/RendpropQuickStart.mp4"
TRANSCRIPT = ROOT / "apps/ios/Rendprop/Resources/RendpropQuickStart.txt"
W, H = 1080, 1920
FPS = 24
SAMPLE_RATE = 48_000
HOLD_SECONDS = .4
CHAPTERS = ["Find your way", "Build the home", "Photos & AI", "Make a video",
            "Optional video tools", "Publish the website", "Follow up & manage", "Account & usage"]
ACCENTS = {
    "Find your way": "#7541e9", "Build the home": "#4775e5",
    "Photos & AI": "#d95891", "Make a video": "#2e9dba",
    "Optional video tools": "#7550dd", "Publish the website": "#2b8e81",
    "Follow up & manage": "#7657db", "Account & usage": "#6f55ce",
}
FONT = Path("/System/Library/Fonts/HelveticaNeue.ttc")
# Off-Mac renders (CI or a Linux box) may point QUICK_START_FONT_REGULAR /
# QUICK_START_FONT_BOLD at a Helvetica-metric face such as URW Nimbus Sans.
FONT_REGULAR = Path(os.environ.get("QUICK_START_FONT_REGULAR", str(FONT)))
FONT_BOLD = Path(os.environ.get("QUICK_START_FONT_BOLD", str(FONT)))


def require(test: bool, reason: str) -> None:
    if not test:
        raise SystemExit(reason)


def run(command: list[str], *, timeout: int = 60) -> bytes:
    result = subprocess.run(command, capture_output=True, timeout=timeout)
    require(result.returncode == 0, f"{' '.join(command[:4])} failed: {result.stderr[-1500:]!r}")
    return result.stdout


def sha(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def font(size: int, *, bold: bool = False) -> ImageFont.FreeTypeFont:
    face = FONT_BOLD if bold else FONT_REGULAR
    index = (1 if bold else 0) if face.suffix == ".ttc" else 0
    return ImageFont.truetype(str(face), size, index=index)


def wrap(draw: ImageDraw.ImageDraw, value: str, face: ImageFont.FreeTypeFont,
         max_width: int) -> list[str]:
    lines: list[str] = []
    line = ""
    for word in value.split():
        next_line = (line + " " + word).strip()
        if line and draw.textbbox((0, 0), next_line, font=face)[2] > max_width:
            lines.append(line)
            line = word
        else:
            line = next_line
    if line:
        lines.append(line)
    return lines


def load_source() -> tuple[list[dict], dict, dict]:
    value = json.loads((SOURCE / "scenes.json").read_text())
    scenes = value["scenes"]
    require(len(scenes) == 38, "The complete guide requires all 38 scenes")
    require([s["id"] for s in scenes] == [f"{n:02d}" for n in range(1, 39)],
            "Scene IDs changed")
    require(list(dict.fromkeys(s["chapter"] for s in scenes)) == CHAPTERS,
            "Chapter order changed")
    require(value["voice"] == "ElevenLabs Faye", "Only the owner-approved voice is valid")
    visuals = json.loads((SOURCE / "visuals.json").read_text())
    provenance = json.loads((CAPTURES / "provenance.json").read_text())
    require(set(visuals) == {s["id"] for s in scenes}, "Every scene needs a visual assignment")
    for scene in scenes:
        keys = visuals[scene["id"]]
        require(isinstance(keys, list) and 1 <= len(keys) <= 3,
                f"Scene {scene['id']} needs one to three real screens")
        for key in keys:
            item = provenance.get(key)
            require(item is not None and (CAPTURES / item["file"]).is_file(),
                    f"Missing authentic capture: {key} for scene {scene['id']}")
            require(item["source"].startswith(("Physical iPhone", "Current app simulator", "Current live mobile browser")),
                    f"Capture provenance is not a real app/browser screen: {key}")
            require(sha(CAPTURES / item["file"]) == item["file_sha256"],
                    f"Capture has changed: {key}")
    return scenes, visuals, provenance


def render_screen(scene: dict, image_path: Path, destination: Path,
                  scene_index: int, visual_index: int, visual_count: int) -> None:
    """Frame the unmodified app screen in a quiet Apple-style teaching card."""
    original = Image.open(image_path).convert("RGB")
    # A blurred copy fills the side gutters; the foreground is the actual UI.
    backdrop = ImageOps.fit(original, (W, H), method=Image.Resampling.LANCZOS)
    backdrop = backdrop.filter(ImageFilter.GaussianBlur(75)).convert("RGBA")
    tint = Image.new("RGBA", (W, H), (248, 247, 251, 232))
    base = Image.alpha_composite(backdrop, tint)
    draw = ImageDraw.Draw(base)
    accent = ACCENTS[scene["chapter"]]
    draw.rounded_rectangle((46, 46, 1034, 220), radius=44,
                           fill=(255, 255, 255, 235), outline=(228, 224, 238, 255), width=2)
    draw.text((78, 65), scene["chapter"].upper(), font=font(27, bold=True), fill=accent)
    draw.text((908, 65), f"{scene_index:02d}/38", font=font(24), fill="#736d80")
    title_lines = wrap(draw, scene["title"], font(49, bold=True), 920)
    require(len(title_lines) <= 2, f"Title does not fit: {scene['id']}")
    for line_index, line in enumerate(title_lines):
        draw.text((78, 108 + 55 * line_index), line, font=font(49, bold=True), fill="#211b30")
    # Real screen is kept whole. No controls, fields or result images are redrawn.
    scale = min(785 / original.width, 1610 / original.height)
    screen = original.resize((round(original.width * scale), round(original.height * scale)),
                             Image.Resampling.LANCZOS)
    x = (W - screen.width) // 2
    y = 243 + (1610 - screen.height) // 2
    shade = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    shadow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((x, y, x + screen.width, y + screen.height),
                                              radius=52, fill=220)
    shadow = shadow.filter(ImageFilter.GaussianBlur(22))
    shade.paste((47, 35, 72, 58), (0, 12, W, H + 12), shadow)
    base = Image.alpha_composite(base, shade)
    mask = Image.new("L", screen.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, screen.width - 1, screen.height - 1),
                                            radius=50, fill=255)
    base.paste(screen, (x, y), mask)
    draw = ImageDraw.Draw(base)
    draw.rounded_rectangle((x, y, x + screen.width - 1, y + screen.height - 1),
                           radius=50, outline=(215, 210, 226, 255), width=2)
    # The guide progress sits outside the pictured app, so it cannot obscure a control.
    draw.rounded_rectangle((66, 1889, 1014, 1901), radius=6, fill="#d9d3e4")
    complete = (scene_index - 1 + (visual_index + 1) / visual_count) / 38
    draw.rounded_rectangle((66, 1889, 66 + round(948 * complete), 1901),
                           radius=6, fill=accent)
    destination.parent.mkdir(parents=True, exist_ok=True)
    base.convert("RGB").save(destination, quality=91, subsampling=0, optimize=True)


def stamp(seconds: float) -> str:
    millis = round(seconds * 1000)
    hours, millis = divmod(millis, 3_600_000)
    minutes, millis = divmod(millis, 60_000)
    whole, millis = divmod(millis, 1000)
    return f"{hours:02d}:{minutes:02d}:{whole:02d}.{millis:03d}"


def make_transcript(scenes: list[dict]) -> str:
    lines = ["Rendprop — Complete first-listing guide", "ElevenLabs Faye narration · real app screens", ""]
    chapter = None
    for scene in scenes:
        if scene["chapter"] != chapter:
            chapter = scene["chapter"]
            lines += [chapter.upper(), ""]
        lines += [f"{scene['id']}. {scene['title']}", scene["narration"],
                  "On screen: " + " • ".join(scene["steps"]), ""]
    lines += ["Prices, trial eligibility, available credits, and AI processing access are shown by the app and Apple at the time of use. This guide does not start a purchase or guarantee an offer.", ""]
    return "\n".join(lines)


def captions(scenes: list[dict], timeline: list[dict]) -> str:
    result = ["WEBVTT", ""]
    for scene, item in zip(scenes, timeline):
        sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+", scene["narration"]) if s.strip()]
        total = sum(len(s.split()) for s in sentences)
        elapsed = 0.0
        for sentence in sentences:
            start = item["start"] + elapsed
            elapsed += item["audio_seconds"] * len(sentence.split()) / total
            result += [f"{stamp(start)} --> {stamp(item['start'] + elapsed)}", sentence, ""]
    return "\n".join(result)


def ffquote(path: Path) -> str:
    return "'" + str(path).replace("'", "'\\''") + "'"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--work-dir", type=Path, required=True)
    parser.add_argument("--voice-dir", type=Path, default=VOICE_MASTERS,
                        help="Directory with scene-XX.mp3 ElevenLabs masters (defaults to checked-in voice/)")
    parser.add_argument("--slides-only", action="store_true")
    parser.add_argument("--render", action="store_true")
    args = parser.parse_args()
    require(args.render != args.slides_only, "Choose exactly one of --render or --slides-only")
    require(shutil.which("ffmpeg") and shutil.which("ffprobe"), "ffmpeg and ffprobe are required")
    scenes, visuals, provenance = load_source()
    voice_receipt = json.loads((VOICE_MASTERS / "provenance.json").read_text())
    require(voice_receipt["model"] == "elevenlabs_v4_turbo" and voice_receipt["voice"] == "Faye",
            "Narration master provenance changed")
    voice_rows = {item["id"]: item for item in voice_receipt["scenes"]}
    require(set(voice_rows) == {scene["id"] for scene in scenes}, "Every scene needs a voice master")
    for scene in scenes:
        item = voice_rows[scene["id"]]
        original = args.voice_dir / item["file"]
        require(original.is_file() and sha(original) == item["file_sha256"],
                f"ElevenLabs master missing or changed: {scene['id']}")
        require(hashlib.sha256(scene["narration"].encode("utf-8")).hexdigest() == item["narration_sha256"],
                f"Narration text no longer matches paid audio for scene {scene['id']}")
    args.work_dir.mkdir(parents=True, exist_ok=True)
    require(os.statvfs(args.work_dir).f_bavail * os.statvfs(args.work_dir).f_frsize > 1_500_000_000,
            "Render volume needs at least 1.5 GB free")
    slides_dir = args.work_dir / "slides-real"
    slides_dir.mkdir(exist_ok=True)
    slides: list[tuple[str, Path]] = []
    for scene_index, scene in enumerate(scenes, 1):
        keys = visuals[scene["id"]]
        for visual_index, key in enumerate(keys):
            path = slides_dir / f"scene-{scene['id']}-{visual_index + 1}.jpg"
            render_screen(scene, CAPTURES / provenance[key]["file"], path,
                          scene_index, visual_index, len(keys))
            slides.append((scene["id"], path))
    TRANSCRIPT.write_text(make_transcript(scenes), encoding="utf-8")
    if args.slides_only:
        print(json.dumps({"scenes": len(scenes), "slides": len(slides), "work_dir": str(args.work_dir)}))
        return

    audio_path = args.work_dir / "narration-real.raw"
    timeline: list[dict] = []
    position = 0.0
    with audio_path.open("wb") as output:
        for scene in scenes:
            original = args.voice_dir / f"scene-{scene['id']}.mp3"
            require(original.is_file(), f"Missing paid ElevenLabs source: {original}")
            raw = run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(original),
                       "-ar", str(SAMPLE_RATE), "-ac", "1", "-f", "s16le", "pipe:1"], timeout=90)
            require(len(raw) >= SAMPLE_RATE * 2 and len(raw) % 2 == 0,
                    f"Empty narration scene {scene['id']}")
            output.write(raw)
            output.write(b"\0\0" * round(HOLD_SECONDS * SAMPLE_RATE))
            spoken = len(raw) / (SAMPLE_RATE * 2)
            length = spoken + round(HOLD_SECONDS * SAMPLE_RATE) / SAMPLE_RATE
            timeline.append({"id": scene["id"], "chapter": scene["chapter"],
                             "title": scene["title"], "start": position,
                             "audio_seconds": spoken, "end": position + length,
                             "visuals": visuals[scene["id"]],
                             "elevenlabs_source_sha256": sha(original)})
            position += length

    concat = args.work_dir / "slides-real.ffconcat"
    entries = ["ffconcat version 1.0\n"]
    for scene, item in zip(scenes, timeline):
        keys = visuals[scene["id"]]
        for visual_index, _ in enumerate(keys):
            path = slides_dir / f"scene-{scene['id']}-{visual_index + 1}.jpg"
            entries.append(f"file {ffquote(path)}\nduration {(item['end']-item['start'])/len(keys):.6f}\n")
    entries.append(f"file {ffquote(slides[-1][1])}\n")
    concat.write_text("".join(entries))
    chapters = []
    for name in CHAPTERS:
        group = [item for item in timeline if item["chapter"] == name]
        chapters.append({"title": name, "start": group[0]["start"], "end": group[-1]["end"]})
    metadata = args.work_dir / "chapters-real.ffmeta"
    metadata.write_text(";FFMETADATA1\ntitle=Rendprop complete first-listing guide\n" + "".join(
        f"[CHAPTER]\nTIMEBASE=1/1000\nSTART={round(x['start']*1000)}\n"
        f"END={round(x['end']*1000)}\ntitle={x['title']}\n" for x in chapters))
    (SOURCE / "captions.vtt").write_text(captions(scenes, timeline), encoding="utf-8")
    (SOURCE / "timeline.json").write_text(json.dumps(
        {"duration_seconds": position, "scenes": timeline, "chapters": chapters}, indent=2) + "\n")
    MOVIE.parent.mkdir(parents=True, exist_ok=True)
    temp_movie = args.work_dir / "quick-start-real.mp4"
    command = ["ffmpeg", "-hide_banner", "-loglevel", "warning", "-y",
               "-f", "concat", "-safe", "0", "-i", str(concat),
               "-f", "s16le", "-ar", str(SAMPLE_RATE), "-ac", "1", "-i", str(audio_path),
               "-f", "ffmetadata", "-i", str(metadata),
               "-map", "0:v:0", "-map", "1:a:0", "-map_metadata", "2", "-map_chapters", "2",
               # JPEG slide sources carry full-range pixels. Convert to limited-range
               # YUV so AVPlayer receives ordinary yuv420p instead of yuvj420p.
               "-vf", f"fps={FPS},scale=in_range=pc:out_range=tv,format=yuv420p",
               "-c:v", "libx264", "-preset", "veryfast",
               "-crf", "23", "-c:a", "aac", "-b:a", "112k", "-movflags", "+faststart",
               "-t", f"{position:.6f}", str(temp_movie)]
    process = subprocess.run(command, text=True, capture_output=True, timeout=2400)
    require(process.returncode == 0, f"ffmpeg encode failed: {process.stderr[-3000:]}")
    shutil.copyfile(temp_movie, MOVIE)
    probe = json.loads(run(["ffprobe", "-v", "error", "-show_format", "-show_streams",
                            "-show_chapters", "-of", "json", str(MOVIE)]))
    receipt = {"source_commit": run(["git", "rev-parse", "HEAD"]).decode().strip(),
               "scenes": len(scenes), "real_capture_slides": len(slides),
               "chapters": len(probe["chapters"]),
               "duration_seconds": float(probe["format"]["duration"]),
               "bytes": MOVIE.stat().st_size, "video_sha256": sha(MOVIE),
               "transcript_sha256": sha(TRANSCRIPT),
               "voice": "ElevenLabs Faye v4 Turbo", "voice_source_files": 38,
               "paid_api_calls_during_render": 0}
    (args.work_dir / "build-receipt-real.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
