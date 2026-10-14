"""Private CPU FFmpeg composition; its caller resolves lease-owned inputs.

Inputs are local, server-verified pass-QC clips in already normalized SDR.
Original-photo motion must be prepared explicitly from its selected JPEG.
Production uses the existing conditional HDR tone-map helper, not tag-only.
No customer/media path is interpolated into a shell or filter expression.
"""
from __future__ import annotations

import json
import hashlib
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path


class QualityError(Exception):
    pass


@dataclass(frozen=True)
class MusicSource:
    """Resolved by trusted catalog adapter, never from customer file/URL claims."""
    track_id: str
    path: Path
    sha256: str
    license_revision: str
    credit: str


def run(args, timeout=300):
    return subprocess.run(args, check=True, capture_output=True, timeout=timeout)


def probe(path: Path):
    result = run([shutil.which("ffprobe"), "-v", "error", "-show_streams", "-show_format", "-of", "json", str(path)], timeout=30)
    return json.loads(result.stdout)


def compose(clips: list[Path], directory: Path, *, aspect="16:9", narration: Path | None = None,
            music: MusicSource | None = None, music_gain=.18, duck_gain=.07, duck_narration=True, test_fast=False,
            presentation=None, words=None, discard_inputs=False):
    """Bounded per-clip processing; never opens all100 decoders at once.

    Exact five-second clips and every clip in frozen order are mandatory.
    Narration is optional and must already have a private owned audio receipt.
    The adapter binds narration to the immutable owned voice-result receipt.
    """
    if not 1 <= len(clips) <= 100 or aspect not in {"16:9", "9:16"}:
        raise QualityError("closed source/aspect contract")
    width, height = (1920, 1080) if aspect == "16:9" else (1080, 1920)
    directory.mkdir(parents=True, exist_ok=True)
    canonical = []
    elapsed_duration = 5 * len(clips)
    if not 0 <= music_gain <= .5:
        raise QualityError("bounded music gain required")
    if music is not None:
        if not music.track_id or not music.license_revision or hashlib.sha256(music.path.read_bytes()).hexdigest() != music.sha256:
            raise QualityError("licensed music identity could not be verified")
        music_facts = probe(music.path)
        if len([s for s in music_facts["streams"] if s["codec_type"] == "audio"]) != 1:
            raise QualityError("one verified music stream required")
    for i, source in enumerate(clips):
        facts = probe(source)
        videos = [stream for stream in facts["streams"] if stream["codec_type"] == "video"]
        if len(videos) != 1:
            raise QualityError("one verified video stream required")
        video = videos[0]
        if video["width"] > 8192 or video["height"] > 8192 or video["width"] * video["height"] > 33177600 or source.stat().st_size > 128 * 1024 * 1024:
            raise QualityError("source exceeds bounded decode/transport size")
        if video["width"] < width or video["height"] < height:
            raise QualityError("source lacks actual1080 framing pixels; no upscaling")
        if not 4.97 <= float(facts["format"]["duration"]) <= 5.08:
            raise QualityError("all source clips must be exactly5 seconds")
        if video.get("color_transfer") in {"smpte2084", "arib-std-b67"}:
            raise QualityError("HDR needs the separately tested conditional tone-map")
        if any(side.get("rotation", 0) != 0 for side in video.get("side_data_list", [])):
            raise QualityError("rotation must be normalized before quality admission")
        output = directory / f"shot-{i:03d}.mp4"
        # Full-screen framing: explicit center crop. No padding/blurred panels.
        # Input dimension gate means this operation never needs to upscale.
        filters = f"scale={width}:{height}:force_original_aspect_ratio=increase,crop={width}:{height},setsar=1,fps=30,format=yuv420p"
        run([shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", str(source),
             "-map", "0:v:0", "-an", "-t", "5", "-vf", filters,
             "-c:v", "libx264", "-preset", "ultrafast" if test_fast else "medium", "-crf", "18", "-maxrate", "24M", "-bufsize", "48M", "-threads", "2",
             "-pix_fmt", "yuv420p", "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709",
             "-movflags", "+faststart", str(output)])
        canonical.append(output)
        if discard_inputs:
            source.unlink()  # Only the adapter's disposable per-task downloads.
    from presentation import timeline, overlay
    presentation = presentation or {}
    canonical, elapsed_duration, starts = timeline(canonical, directory, presentation.get("transition", "cut"))
    # Controlled file names contain no input-controlled quotes/newlines.
    manifest = directory / "concat.txt"
    manifest.write_text("".join(f"file '{path.name}'\n" for path in canonical))
    clean = directory / "clean.mp4"
    run([shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-f", "concat", "-safe", "1", "-i", str(manifest),
         "-map", "0:v:0", "-an", "-c:v", "copy", "-movflags", "+faststart", str(clean)])
    visual = overlay(clean, directory, width, height, presentation, starts, elapsed_duration, words or [])
    master = directory / "master.mp4"
    args = [shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", str(visual)]
    if narration is not None:
        # Muxed once at final output; missing/short narration cannot shorten video.
        audio = probe(narration)
        if len([s for s in audio["streams"] if s["codec_type"] == "audio"]) != 1:
            raise QualityError("one verified narration stream required")
        if float(audio["format"]["duration"]) > elapsed_duration + .1:
            raise QualityError("narration exceeds video; refuse cutting spoken words")
        args += ["-i", str(narration)]
    if music is not None:
        args += ["-stream_loop", "-1", "-i", str(music.path)]
        music_index = 2 if narration is not None else 1
        music_chain = f"[{music_index}:a]aresample=48000,aformat=channel_layouts=stereo,volume={music_gain},atrim=duration={elapsed_duration},asetpts=PTS-STARTPTS[m]"
        if narration is not None:
            voice_chain = f"[1:a]aresample=48000,aformat=channel_layouts=stereo,apad,atrim=duration={elapsed_duration},asetpts=PTS-STARTPTS,asplit=2[n][side]"
            if duck_narration:
                if not 0 <= duck_gain <= music_gain:
                    raise QualityError("bounded duck gain required")
                ratio = duck_gain / music_gain if music_gain else 0
                voice_duration = float(audio["format"]["duration"])
                mix = f"[side]anullsink;[m]volume='if(lt(t,{voice_duration}),{ratio},1)':eval=frame[ducked];[n][ducked]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0"
            else:
                mix = "[side]anullsink;[n][m]amix=inputs=2:duration=longest:dropout_transition=0:normalize=0"
            filters = music_chain + ";" + voice_chain + ";" + mix + ",alimiter=limit=0.95:level=0:latency=1[a]"
        else:
            filters = music_chain + ";[m]alimiter=limit=0.95:level=0:latency=1[a]"
        args += ["-filter_complex", filters, "-map", "0:v:0", "-map", "[a]", "-c:a", "aac", "-b:a", "192k", "-ar", "48000"]
    elif narration is not None:
        args += ["-map", "0:v:0", "-map", "1:a:0", "-af", "apad", "-c:a", "aac", "-b:a", "192k", "-ar", "48000"]
    else:
        args += ["-map", "0:v:0", "-an"]
    args += ["-c:v", "copy", "-t", str(elapsed_duration), "-movflags", "+faststart", str(master)]
    run(args)
    final = probe(master)
    video = next(s for s in final["streams"] if s["codec_type"] == "video")
    if (video["width"], video["height"]) != (width, height) or abs(float(final["format"]["duration"]) - elapsed_duration) > 0.1:
        raise QualityError("final measured geometry/duration refused")
    poster = directory / "poster.jpg"
    run([shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-ss", "0.25", "-i", str(master), "-frames:v", "1", "-q:v", "2", str(poster)], timeout=30)
    return {"master": master, "poster": poster, "width": width, "height": height, "duration_s": elapsed_duration,
            "source_count": len(canonical), "facts": final,
            "music": None if music is None else {"track_id": music.track_id, "sha256": music.sha256,
                "license_revision": music.license_revision, "credit": music.credit, "gain": music_gain, "duck_gain": duck_gain, "duck_narration": duck_narration}}
