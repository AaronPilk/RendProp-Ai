"""Temporal motion QC and the smooth-v2 finish, on actual encoded video.

Synthetic shots move a 1080p window over a fixed textured canvas along a known
path, so every expected number is known: a 3 Hz walking bob, a steady glide,
30 fps re-timing, horizon roll and walk-through travel. Each check is paired
with a control that must fail, so the oracle is shown to discriminate.
"""
import datetime
import math
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "container"))
import motion_qc
import smooth_finish
from compose import compose, probe, run
from photo_motion import motion_filter, static_saved_photo_filter
from renderer import validate_task


def texture(width, height, seed):
    rng = np.random.default_rng(seed)
    noise = rng.normal(0, 1, (height // 8 + 1, width // 8 + 1))
    # Never darker than RGB 30, so a black warp fill on any frame edge is unambiguous.
    image = Image.fromarray(np.uint8(np.clip(128 + 40 * noise, 30, 255))).resize((width, height), Image.Resampling.BICUBIC).convert("RGB")
    draw = ImageDraw.Draw(image)
    for _ in range(int(width * height / 6000)):
        x, y, r = int(rng.integers(0, width)), int(rng.integers(0, height)), int(rng.integers(6, 60))
        colour = tuple(int(c) for c in rng.integers(40, 250, 3))
        if rng.random() < .5:
            draw.rectangle([x, y, x + 2 * r, y + r], outline=colour, width=3)
        else:
            draw.ellipse([x, y, x + r, y + r], fill=colour)
    for i in range(0, width, 97):
        draw.line([i, 0, i, height], fill=(230, 230, 230), width=2)
    for j in range(0, height, 89):
        draw.line([0, j, width, j], fill=(40, 40, 40), width=2)
    return image.filter(ImageFilter.GaussianBlur(.6))


def shot(path, size, *, pan=0.0, bob=0.0, roll_wobble_deg=0.0, roll_drift_deg=0.0, zoom=0.0, retime=None, seed=7, frames=121):
    """Source pixels: pan per frame, 3 Hz bob amplitude, roll wobble/drift, push-in fraction."""
    width, height = size
    canvas = texture(int(width * 1.5), int(height * 1.5), seed)
    canvas_width, canvas_height = canvas.size
    args = [shutil.which("ffmpeg"), "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24", "-s", f"{width}x{height}", "-r", "24", "-i", "-"]
    if retime:
        args += ["-vf", f"fps={retime}"]
    args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "12", "-pix_fmt", "yuv420p", str(path)]
    encoder = subprocess.Popen(args, stdin=subprocess.PIPE)
    for t in range(frames):
        scale = 1 + zoom * t / (frames - 1)
        angle = math.radians(roll_wobble_deg) * math.sin(2 * math.pi * 3 * t / 24 + 1) + math.radians(roll_drift_deg) * t / (frames - 1)
        cx = canvas_width / 2 + pan * t
        cy = canvas_height / 2 + bob * math.sin(2 * math.pi * 3 * t / 24)
        a, b, d, e = math.cos(angle) / scale, -math.sin(angle) / scale, math.sin(angle) / scale, math.cos(angle) / scale
        frame = canvas.transform((width, height), Image.Transform.AFFINE,
                                 (a, b, cx - a * width / 2 - b * height / 2, d, e, cy - d * width / 2 - e * height / 2), Image.Resampling.BICUBIC)
        encoder.stdin.write(frame.tobytes())
    encoder.stdin.close()
    assert encoder.wait() == 0
    return path


def dark_edge_pixels(path, count=120, width=1920, height=1080, below=12):
    """Pixels darker than any texture value on the outer two rows/columns.

    The texture is never darker than RGB 30, so a black warp fill would show as
    whole dark strips (thousands of pixels); encoder ringing gives a handful.
    """
    data = run([shutil.which("ffmpeg"), "-v", "error", "-i", str(path), "-frames:v", str(count), "-f", "rawvideo", "-pix_fmt", "gray", "-"]).stdout
    frames = np.frombuffer(data, np.uint8).reshape(-1, height, width)
    edges = np.concatenate([frames[:, :2, :].reshape(len(frames), -1), frames[:, -2:, :].reshape(len(frames), -1),
                            frames[:, :, :2].reshape(len(frames), -1), frames[:, :, -2:].reshape(len(frames), -1)], axis=1)
    return int((edges < below).sum()), len(frames)


class TemporalMotionQC(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(tempfile.mkdtemp(prefix="motion-qc-"))
        landscape = (2400, 1350)  # cover scale 0.8: final pixels = 0.8 x source pixels
        cls.bob = shot(cls.root / "bob.mp4", landscape, pan=1.5, bob=3.0)
        cls.glide = shot(cls.root / "glide.mp4", landscape, pan=1.5)
        cls.retimed = shot(cls.root / "retimed.mp4", landscape, pan=1.5, retime=30)
        cls.walk_in = shot(cls.root / "walk-in.mp4", landscape, zoom=.8, roll_drift_deg=3.0)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.root)

    def test_known_walking_bob_is_measured_in_final_pixels_and_refused(self):
        report = motion_qc.measure(self.bob)
        metrics, reasons = report["metrics"], report["verdict"]["reasons"]
        # 3.0 source px amplitude x 0.8 cover scale = 2.4 final px; 2-98% span of a sine ~ 2 x 0.99 x 2.4.
        self.assertAlmostEqual(metrics["bob_pp_px"], 4.75, delta=.4)
        self.assertEqual(metrics["cadence_hz"], 3.0)
        self.assertGreater(metrics["cadence_acf"], .8)
        self.assertAlmostEqual(metrics["pan_x_pct"], -1.5 * 120 * .8 / 1920 * 100, delta=.3)
        self.assertIn("vertical_bob", reasons)
        self.assertIn("walking_cadence", reasons)
        self.assertFalse(report["verdict"]["pass"])

    def test_steady_glide_passes_and_keeps_its_travel(self):
        report = motion_qc.measure(self.glide)
        self.assertTrue(report["verdict"]["pass"], report)
        self.assertLess(report["metrics"]["bob_pp_px"], .3)
        self.assertLess(report["metrics"]["sway_pp_px"], .3)
        self.assertAlmostEqual(report["metrics"]["pan_x_pct"], -7.5, delta=.3)
        self.assertEqual(report["metrics"]["duplicate_ratio"], 0)

    def test_30fps_retiming_of_24fps_frames_is_seen_as_repeated_frames(self):
        report = motion_qc.measure(self.retimed)
        self.assertEqual(report["metrics"]["fps"], 30.0)
        self.assertAlmostEqual(report["metrics"]["duplicate_ratio"], .2, delta=.02)
        self.assertIn("duplicate_frames", report["verdict"]["reasons"])

    def test_walk_in_travel_and_horizon_roll_are_refused(self):
        metrics = motion_qc.measure(self.walk_in)["metrics"]
        self.assertAlmostEqual(metrics["zoom_pct"], 80, delta=3)
        # Slow roll (0.025 deg per frame) through x264 reads up to ~12% low; 3 deg stays far above the 1 deg limit.
        self.assertAlmostEqual(abs(metrics["roll_drift_deg"]), 3.0, delta=.45)
        reasons = motion_qc.verdict(metrics)["reasons"]
        self.assertIn("walk_through_travel", reasons)
        self.assertIn("horizon_roll", reasons)


class SmoothFinish(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(tempfile.mkdtemp(prefix="smooth-v2-"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.root)

    def test_bob_removed_with_measured_trim_native_cadence_and_intended_move_kept(self):
        source = shot(self.root / "landscape-bob.mp4", (2400, 1350), pan=1.5, bob=3.0, seed=11)
        output = self.root / "landscape-smooth.mp4"
        report = smooth_finish.finish_shot(source, output, test_fast=True)
        self.assertIn("vertical_bob", report["before_verdict"]["reasons"])
        self.assertTrue(report["after_verdict"]["pass"], report["after_verdict"])
        self.assertLess(report["after"]["bob_pp_px"], .6)
        self.assertEqual(report["correction_strength"], 1.0)
        self.assertLessEqual(report["zoom"], smooth_finish.ZOOM_CAP)
        self.assertAlmostEqual(report["edge_trim_pct"], 100 * (1 - 1 / report["zoom"]), places=2)
        self.assertGreater(report["max_correction_px"], 1.5)
        self.assertAlmostEqual(report["after"]["pan_x_pct"], report["before"]["pan_x_pct"], delta=.3)
        stream = next(s for s in probe(output)["streams"] if s["codec_type"] == "video")
        self.assertEqual((stream["width"], stream["height"], stream["r_frame_rate"], stream["avg_frame_rate"]), (1920, 1080, "24/1", "24/1"))
        dark, frames = dark_edge_pixels(output)
        self.assertEqual(frames, 120)
        self.assertLessEqual(dark, 8, "no frame edge may show warp fill")
        self.assertEqual(report["after"]["duplicate_ratio"], 0)

    def test_warp_that_would_leave_real_pixels_is_refused_before_encoding(self):
        source = shot(self.root / "guard.mp4", (2400, 1350), pan=1.0, seed=16)
        frames = [(1.0, 0.0, np.array([25.0, 0.0]))] * 120
        with self.assertRaises(smooth_finish.FinishError):
            smooth_finish.render(source, self.root / "guard-out.mp4", "16:9", {"zoom": 1.0, "strength": 1.0, "frames": frames}, 2400, 1350, test_fast=True)
        self.assertFalse((self.root / "guard-out.mp4").exists())

    def test_control_without_path_smoothing_is_still_refused(self):
        source = shot(self.root / "control-bob.mp4", (2400, 1350), pan=1.5, bob=3.0, seed=12)
        with patch.object(smooth_finish, "STABILIZE_SECONDS", 0.0):
            report = smooth_finish.finish_shot(source, self.root / "control.mp4", test_fast=True)
        self.assertFalse(report["after_verdict"]["pass"])
        self.assertIn("vertical_bob", report["after_verdict"]["reasons"])

    def test_portrait_source_uses_vertical_headroom_and_levels_roll_wobble(self):
        source = shot(self.root / "portrait.mp4", (2000, 2668), bob=4.0, roll_wobble_deg=.3, zoom=.2, seed=13)
        report = smooth_finish.finish_shot(source, self.root / "portrait-smooth.mp4", test_fast=True)
        self.assertIn("roll_wobble", report["before_verdict"]["reasons"])
        self.assertTrue(report["after_verdict"]["pass"], report["after_verdict"])
        self.assertLess(report["zoom"], 1.01, "vertical bob costs no zoom inside a portrait source's spare height")
        self.assertAlmostEqual(report["after"]["zoom_pct"], report["before"]["zoom_pct"], delta=1.5)

    def test_exact_1080_source_is_not_upscaled_to_hide_bob(self):
        source = shot(self.root / "exact.mp4", (1920, 1080), pan=1.0, bob=2.0, seed=14)
        report = smooth_finish.finish_shot(source, self.root / "exact-smooth.mp4", test_fast=True)
        self.assertEqual((report["zoom"], report["correction_strength"]), (1.0, 0.0))
        self.assertFalse(report["after_verdict"]["pass"], "bob that cannot be removed within real pixels stays visible to QC")

    def test_30fps_source_is_refused(self):
        source = shot(self.root / "thirty.mp4", (2400, 1350), pan=1.0, retime=30, seed=15)
        with self.assertRaises(smooth_finish.FinishError):
            smooth_finish.finish_shot(source, self.root / "thirty-smooth.mp4", test_fast=True)


class PlanGeometry(unittest.TestCase):
    def path(self, x, y=None, angle=None):
        x = np.asarray(x, dtype=float)
        zeros = np.zeros_like(x)
        return {"x": x, "y": zeros if y is None else np.asarray(y, float), "angle": zeros if angle is None else np.asarray(angle, float),
                "log_scale": zeros.copy()}

    def test_zoom_is_the_exact_border_free_minimum(self):
        frames = [(1.0, 0.0, np.array([10.0, 0.0]))]
        # Window half-width 960 inside a 1920-wide cover with a 1 px kernel margin: 960 / (959 - 10).
        self.assertAlmostEqual(smooth_finish.required_zoom(frames, 1920, 1080, 1920, 1080), 960 / 949, places=9)
        rotated = [(1.0, math.radians(1.0), np.zeros(2))]
        expected = max((960 * math.cos(math.radians(1)) + 540 * math.sin(math.radians(1))) / 959,
                       (960 * math.sin(math.radians(1)) + 540 * math.cos(math.radians(1))) / 539)
        self.assertAlmostEqual(smooth_finish.required_zoom(rotated, 1920, 1080, 1920, 1080), expected, places=9)

    def test_correction_beyond_the_cap_is_weakened_never_bordered(self):
        bob = 60 * np.sin(2 * np.pi * 3 * np.arange(120) / 24)
        result = smooth_finish.plan(self.path(np.zeros(120), bob), 1920, 1080, 1920, 1080, zoom_limit=2.0)
        self.assertLess(result["strength"], 1.0)
        self.assertLessEqual(result["zoom"], smooth_finish.ZOOM_CAP + 1e-9)
        self.assertEqual(result["limited_by"], "zoom_cap")

    def test_steady_glide_needs_no_correction(self):
        result = smooth_finish.plan(self.path(np.arange(120) * 3.0), 1920, 1080, 1920, 2560, zoom_limit=1.3)
        self.assertLess(result["max_correction_px"], .05)
        self.assertLess(result["zoom"], 1.002)


class V1Unchanged(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.root = Path(tempfile.mkdtemp(prefix="smooth-compose-"))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.root)

    def test_v1_strings_are_unchanged(self):
        self.assertEqual(motion_filter(2560, 1440, 1920, 1080, "push_in"),
                         "crop=2560:1440,zoompan=z='1+0.020000000*min(1,on/149)':x='(iw-iw/zoom)/2':y='(ih-ih/zoom)/2':d=150:s=1920x1080:fps=30,setsar=1,format=yuv420p")
        self.assertEqual(static_saved_photo_filter(1600, 900, 1920, 1080),
                         "crop=1600:900:(iw-ow)/2:(ih-oh)/2,scale=1920:1080:flags=lanczos,setsar=1,fps=30,format=yuv420p")
        recorded = []
        source = shot(self.root / "v1.mp4", (2400, 1350), pan=1.0, seed=21)
        with patch("compose.run", side_effect=lambda args, timeout=300: recorded.append(args) or run(args, timeout)):
            result = compose([source], self.root / "v1-out", test_fast=True)
        encode = next(args for args in recorded if "-vf" in args)
        shot_filter = encode[encode.index("-vf") + 1]
        self.assertEqual(shot_filter, "scale=1920:1080:force_original_aspect_ratio=increase,crop=1920:1080,setsar=1,fps=30,format=yuv420p")
        self.assertNotIn("temporal_qc", result)
        stream = next(s for s in result["facts"]["streams"] if s["codec_type"] == "video")
        self.assertEqual(stream["r_frame_rate"], "30/1")

    def test_task_keys_are_closed(self):
        expires = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=1)).isoformat()
        job, lease = "10000000-0000-4000-8000-000000000001", "20000000-0000-4000-8000-000000000002"
        compose_task = {"action": "compose", "job_id": job, "lease_token": lease, "manifest_sha256": "a" * 64,
                        "purpose": "listing", "aspect": "16:9", "sources": [{"position": 0, "bytes": 12, "motion_kind": "ai"}],
                        "presentation": {"transition": "cut"}, "output": {"asset_id": job, "poster_asset_id": lease}, "expires_at": expires}
        validate_task(compose_task)
        with self.assertRaises(ValueError):
            validate_task({**compose_task, "temporal_qc": {"profile": "temporal-motion-v1", "aspect": "16:9"}})
        extract = {"action": "extract_frames", "job_id": job, "attempt_id": job, "lease_token": lease, "clip": {}, "expires_at": expires}
        validate_task(extract)
        validate_task({**extract, "temporal_qc": {"profile": "temporal-motion-v1", "aspect": "9:16"}})
        for bad in [{"profile": "temporal-motion-v2", "aspect": "16:9"}, {"profile": "temporal-motion-v1", "aspect": "4:3"},
                    {"profile": "temporal-motion-v1", "aspect": "16:9", "limits": {}}, "temporal-motion-v1"]:
            with self.assertRaises(ValueError):
                validate_task({**extract, "temporal_qc": bad})


if __name__ == "__main__":
    unittest.main()
