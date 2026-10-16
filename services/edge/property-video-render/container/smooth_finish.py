"""Finish profile smooth-v2: steady AI shots at their native cadence.

v1 framing (scale to cover + centre crop) is kept, then each frame is
re-sampled along a smoothed camera path: one rigid similarity warp per frame
(translation, small rotation, small scale) plus ONE static zoom for the whole
shot, solved so the frame never leaves real source pixels. Slow intended
movement stays; bob, sway and wobble faster than about 1 Hz are removed.

Consequences are measured, not assumed: the static zoom (edge trim) and the
largest applied shift/rotation are returned with before/after motion QC. The
zoom is capped and never exceeds the source's own pixels; at the cap the
correction is weakened instead of exposing borders, blurring or inventing
pixels. Planes are warped in YUV, so colour is never converted, and no frame
is duplicated: output frames are the provider's frames, in order.
"""
from __future__ import annotations

import math
import shutil
import time
from pathlib import Path

import numpy as np
from PIL import Image

import motion_qc
from process_deadline import BoundedProcess, ProcessDeadlineError

PROFILE = "smooth-v2"
FPS = 24
FRAMES = 120                 # exactly 5 seconds
STABILIZE_SECONDS = .4       # target path low-pass; QC high-pass is .25 s
ZOOM_CAP = 1.04              # at most 3.8% trimmed from each dimension of v1 framing
EDGE_MARGIN = 1.0            # source pixels kept clear for the interpolation kernel


class FinishError(Exception):
    pass


def _rotation(angle):
    c, s = math.cos(angle), math.sin(angle)
    return np.array([[c, -s], [s, c]])


def corrections(path, strength=1.0, seconds=None, fps=FPS):
    """Per frame (k, phi, D): output = frame(c + (k/Z) R(phi)(u - c) + D)."""
    keys = ("log_scale", "angle", "x", "y")
    if (not isinstance(path, dict) or any(key not in path or not isinstance(path[key], np.ndarray)
                                        or path[key].ndim != 1 or not np.isfinite(path[key]).all() for key in keys)
            or len({path[key].size for key in keys}) != 1 or not 3 <= path["x"].size <= motion_qc.MAX_ANALYSIS_FRAMES
            or isinstance(strength, bool) or not isinstance(strength, (int, float)) or not math.isfinite(strength)
            or not 0 <= strength <= 1):
        raise FinishError("finite_camera_path_required")
    smoothing = STABILIZE_SECONDS if seconds is None else seconds
    if (isinstance(fps, bool) or not isinstance(fps, (int, float)) or not math.isfinite(fps) or not 0 < fps <= 120
            or isinstance(smoothing, bool) or not isinstance(smoothing, (int, float))
            or not math.isfinite(smoothing) or not 0 <= smoothing <= 5):
        raise FinishError("bounded_smoothing_required")
    sigma = smoothing * fps
    target = {key: motion_qc.gaussian_smooth(path[key], sigma) for key in ("log_scale", "angle", "x", "y")}
    frames = []
    for t in range(path["x"].size):
        log_scale = path["log_scale"][t] + strength * (target["log_scale"][t] - path["log_scale"][t])
        angle = path["angle"][t] + strength * (target["angle"][t] - path["angle"][t])
        tx = path["x"][t] + strength * (target["x"][t] - path["x"][t])
        ty = path["y"][t] + strength * (target["y"][t] - path["y"][t])
        k = math.exp(path["log_scale"][t] - log_scale)
        phi = path["angle"][t] - angle
        offset = np.array([path["x"][t], path["y"][t]]) - k * _rotation(phi) @ np.array([tx, ty])
        frames.append((k, phi, offset))
    return frames


def required_zoom(frames, width, height, cover_width, cover_height, margin=EDGE_MARGIN):
    """Smallest static zoom keeping every output corner inside the source frame."""
    half = np.array([width / 2, height / 2])
    limit = np.array([cover_width / 2 - margin, cover_height / 2 - margin])
    corners = [np.array([sx * half[0], sy * half[1]]) for sx in (-1, 1) for sy in (-1, 1)]
    zoom = 1.0
    for k, phi, offset in frames:
        if (not math.isfinite(k) or k <= 0 or not math.isfinite(phi)
                or np.asarray(offset).shape != (2,) or not np.isfinite(offset).all()):
            raise FinishError("finite_warp_required")
        rotation = _rotation(phi)
        for corner in corners:
            rotated = k * (rotation @ corner)
            for axis in (0, 1):
                room = limit[axis] - offset[axis] if rotated[axis] > 0 else limit[axis] + offset[axis]
                if room <= 0:
                    return math.inf
                zoom = max(zoom, abs(rotated[axis]) / room)
    return zoom


def plan(path, width, height, cover_width, cover_height, zoom_limit, fps=FPS):
    """Full correction when its zoom fits the cap, else the strongest that does.

    A source with no spare pixels (exactly the output size) cannot be steadied
    without upscaling; it keeps v1 framing at native cadence (strength 0).
    """
    zoom_limit = min(ZOOM_CAP, zoom_limit)
    if required_zoom(corrections(path, 0.0, fps=fps), width, height, cover_width, cover_height) > zoom_limit:
        identity = [(1.0, 0.0, np.zeros(2)) for _ in range(path["x"].size)]
        return {"zoom": 1.0, "strength": 0.0, "frames": identity, "max_correction_px": 0.0,
                "max_rotation_deg": 0.0, "max_scale_pct": 0.0, "limited_by": "source_has_no_spare_pixels"}
    full = corrections(path, 1.0, fps=fps)
    needed = required_zoom(full, width, height, cover_width, cover_height)
    strength, chosen = 1.0, full
    if needed > zoom_limit:
        low, high = 0.0, 1.0
        for _ in range(24):
            middle = (low + high) / 2
            if required_zoom(corrections(path, middle, fps=fps), width, height, cover_width, cover_height) <= zoom_limit:
                low = middle
            else:
                high = middle
        strength, chosen = low, corrections(path, low, fps=fps)
        needed = required_zoom(chosen, width, height, cover_width, cover_height)
    if not math.isfinite(needed) or needed > zoom_limit + 1e-9:
        raise FinishError("no_border_free_framing")
    # D is the translation applied at the frame centre (zero when uncorrected).
    return {"zoom": needed, "strength": strength, "frames": chosen,
            "max_correction_px": round(max(float(np.hypot(*offset)) for _, _, offset in chosen), 3),
            "max_rotation_deg": round(max(abs(math.degrees(phi)) for _, phi, _ in chosen), 4),
            "max_scale_pct": round(100 * max(abs(k - 1) for k, _, _ in chosen), 4),
            "limited_by": "zoom_cap" if strength < 1 else None}


def _even(value):
    return max(2, int(math.floor(value / 2)) * 2)


def _affine(matrix, translation):
    return (matrix[0, 0], matrix[0, 1], translation[0], matrix[1, 0], matrix[1, 1], translation[1])


def render(source: Path, output: Path, aspect, finish, source_width, source_height, *, frames=FRAMES, fps=FPS, test_fast=False):
    """Decode at the zoomed working size, warp each YUV plane, encode at native cadence."""
    width, height = motion_qc.framing(aspect)
    if (type(source_width) is not int or type(source_height) is not int
            or source_width < width or source_height < height):
        raise FinishError("source_lacks_native_framing_pixels")
    encode_tail = ["-an", "-frames:v", str(frames), "-c:v", "libx264", "-preset", "ultrafast" if test_fast else "medium",
                   "-crf", "18", "-maxrate", "24M", "-bufsize", "48M", "-threads", "2", "-pix_fmt", "yuv420p",
                   "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-movflags", "+faststart", str(output)]
    if finish["strength"] == 0 and finish["zoom"] == 1.0:
        # Nothing to correct within real pixels: v1 framing, native cadence, no warp.
        try:
            with BoundedProcess([shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", str(source), "-map", "0:v:0",
                                 "-vf", f"scale={width}:{height}:force_original_aspect_ratio=increase,crop={width}:{height},setsar=1,format=yuv420p",
                                 *encode_tail], timeout=600) as encoder:
                if encoder.finish() != 0:
                    raise FinishError("finish_render_failed: " + encoder.stderr.decode(errors="replace")[:300])
        except ProcessDeadlineError as error:
            raise FinishError("finish_render_deadline_exceeded") from error
        return {"work_width": width, "work_height": height}
    cover = max(width / source_width, height / source_height)
    cover_width, cover_height = source_width * cover, source_height * cover
    zoom = finish["zoom"]
    work_width, work_height = _even(cover_width * zoom), _even(cover_height * zoom)
    scale_x, scale_y = work_width / cover_width, work_height / cover_height
    offset = np.array([(cover_width - width) / 2, (cover_height - height) / 2])
    centre = np.array([width / 2, height / 2])
    plans = []
    for k, phi, shift in finish["frames"][:frames]:
        # u (output, continuous) -> v1-framing source point -> cover -> working pixels.
        linear = (k / zoom) * _rotation(phi)
        base = centre + shift - linear @ centre + offset
        luma = np.diag([scale_x, scale_y]) @ linear
        luma_shift = np.array([scale_x, scale_y]) * base
        for corner in ((0, 0), (width, 0), (0, height), (width, height)):
            x, y = luma @ np.array(corner, dtype=float) + luma_shift
            if not (EDGE_MARGIN / 2 <= x <= work_width - EDGE_MARGIN / 2 and EDGE_MARGIN / 2 <= y <= work_height - EDGE_MARGIN / 2):
                raise FinishError("warp_would_expose_border")
        # 4:2:0 chroma, left-sited: luma x = 2*cx - .5, luma y = 2*cy.
        delta = np.array([-.5, 0.0])
        chroma_shift = (luma @ delta + luma_shift - delta) / 2
        plans.append((_affine(luma, luma_shift), _affine(luma, chroma_shift)))
    if len(plans) < frames:
        raise FinishError("too_few_source_frames")
    decode = [shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-i", str(source), "-map", "0:v:0", "-an",
              "-vf", f"scale={work_width}:{work_height}:flags=lanczos,format=yuv420p", "-frames:v", str(frames),
              "-f", "rawvideo", "-pix_fmt", "yuv420p", "-"]
    encode = [shutil.which("ffmpeg"), "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
              "-f", "rawvideo", "-pix_fmt", "yuv420p", "-s", f"{width}x{height}", "-r", str(fps), "-i", "-", *encode_tail]
    luma_size, chroma_size = work_width * work_height, (work_width // 2) * (work_height // 2)
    out_chroma = (width // 2, height // 2)
    written = 0
    deadline = time.monotonic() + 600
    try:
        with BoundedProcess(decode, timeout=600, deadline=deadline, read_stdout=True) as reader, \
                BoundedProcess(encode, timeout=600, deadline=deadline, write_stdin=True) as writer:
            for luma_coefficients, chroma_coefficients in plans:
                data = reader.read_exact(luma_size + 2 * chroma_size)
                if len(data) < luma_size + 2 * chroma_size:
                    break
                y = Image.frombuffer("L", (work_width, work_height), data[:luma_size], "raw", "L", 0, 1)
                u = Image.frombuffer("L", (work_width // 2, work_height // 2), data[luma_size:luma_size + chroma_size], "raw", "L", 0, 1)
                v = Image.frombuffer("L", (work_width // 2, work_height // 2), data[luma_size + chroma_size:], "raw", "L", 0, 1)
                writer.write(y.transform((width, height), Image.Transform.AFFINE, luma_coefficients, Image.Resampling.BICUBIC, fillcolor=0).tobytes())
                writer.write(u.transform(out_chroma, Image.Transform.AFFINE, chroma_coefficients, Image.Resampling.BICUBIC, fillcolor=128).tobytes())
                writer.write(v.transform(out_chroma, Image.Transform.AFFINE, chroma_coefficients, Image.Resampling.BICUBIC, fillcolor=128).tobytes())
                written += 1
            reader_code, writer_code = reader.finish(), writer.finish()
            if reader_code != 0 or writer_code != 0 or written != frames:
                raise FinishError("finish_render_failed: " + (reader.stderr + writer.stderr).decode(errors="replace")[:300])
    except ProcessDeadlineError as error:
        raise FinishError("finish_render_deadline_exceeded") from error
    except BrokenPipeError as error:
        raise FinishError("finish_encoder_closed") from error
    return {"work_width": work_width, "work_height": work_height}


def finish_shot(source: Path, output: Path, aspect="16:9", *, test_fast=False):
    """Stabilize one native-24fps AI clip; returns measured before/after facts."""
    width, height = motion_qc.framing(aspect)
    stream = motion_qc.probe_stream(source)
    if motion_qc.native_fps(stream) != FPS or stream.get("r_frame_rate") not in {"24/1"}:
        raise FinishError("smooth_v2_requires_native_24fps_clip")
    if int(stream.get("nb_read_packets") or 0) < FRAMES:
        raise FinishError("too_few_source_frames")
    source_width, source_height = int(stream["width"]), int(stream["height"])
    if source_width < width or source_height < height:
        raise FinishError("source_lacks_native_framing_pixels")
    steps = motion_qc.measure_steps(source, aspect, max_frames=FRAMES)
    before, path, _ = motion_qc.summarize(steps, FPS, aspect)
    cover = max(width / source_width, height / source_height)
    finish = plan(path, width, height, source_width * cover, source_height * cover, zoom_limit=1 / cover, fps=FPS)
    render(source, output, aspect, finish, source_width, source_height, test_fast=test_fast)
    after = motion_qc.measure(output, aspect)
    return {"profile": PROFILE, "fps": FPS, "frames": FRAMES,
            "zoom": round(finish["zoom"], 5), "edge_trim_pct": round(100 * (1 - 1 / finish["zoom"]), 3),
            "correction_strength": round(finish["strength"], 4),
            "max_correction_px": finish["max_correction_px"], "max_rotation_deg": finish["max_rotation_deg"],
            "max_scale_pct": finish["max_scale_pct"],
            "before": before, "before_verdict": motion_qc.verdict(before),
            "after": after["metrics"], "after_verdict": after["verdict"]}
