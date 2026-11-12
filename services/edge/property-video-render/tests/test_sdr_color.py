"""Actual known-SDR normalization, preserving the existing unknown/HDR policy."""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import types
import unittest
from pathlib import Path

CONTAINER = Path(__file__).resolve().parents[1] / "container"
sys.path.insert(0, str(CONTAINER))
import compose as product


class SDRColor(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        evidence = os.environ.get("RENDPROP_SDR_COLOR_EVIDENCE")
        cls.temp = None
        if evidence:
            cls.root = Path(evidence).resolve()
            cls.root.mkdir(parents=True, exist_ok=False)
        else:
            cls.temp = tempfile.TemporaryDirectory(prefix="rendprop-sdr-color-")
            cls.root = Path(cls.temp.name)
        cls.rows = []
        cls.sources = {}
        for name, color, primaries, transfer, matrix in [
            ("bt601", "smpte170m", "smpte170m", "smpte170m", "smpte170m"),
            ("bt2020-sdr", "bt2020", "bt2020", "bt2020-10", "bt2020nc"),
            ("bt709", "bt709", "bt709", "bt709", "bt709"),
        ]:
            path = cls.root / (name + ".mp4")
            product.run([shutil.which("ffmpeg"), "-v", "error", "-nostdin", "-y", "-f", "lavfi",
                         "-i", "testsrc2=s=1920x1080:r=24:d=5", "-vf", "colorspace=iall=bt709:all=" + color + ":format=yuv420p",
                         "-an", "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-threads", "2",
                         "-color_primaries", primaries, "-color_trc", transfer, "-colorspace", matrix,
                         "-color_range", "tv", str(path)], timeout=45)
            cls.sources[name] = path

    @classmethod
    def tearDownClass(cls):
        (cls.root / "receipt.json").write_text(json.dumps({"cases": cls.rows,
            "sourceHashes": {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                for p in [CONTAINER / "compose.py", Path(__file__)]}}, indent=2) + "\n")
        if cls.temp:
            cls.temp.cleanup()

    def canonical(self, path):
        facts = product.probe(path)
        video = next(s for s in facts["streams"] if s["codec_type"] == "video")
        self.assertEqual(tuple(video.get(k) for k in ["color_space", "color_transfer", "color_primaries"]),
                         ("bt709", "bt709", "bt709"), "known SDR must be fully converted, not mixed-tagged")
        self.assertEqual(video.get("color_range"), "tv")
        self.assertEqual((video["width"], video["height"]), (1920, 1080))
        self.assertEqual((video["avg_frame_rate"], video["r_frame_rate"], video["nb_frames"]), ("24/1", "24/1", "120"))
        self.assertAlmostEqual(float(facts["format"]["duration"]), 5, places=3)
        return video

    def matches_reference(self, path, reference):
        video = self.canonical(path)
        frames = [product.run([shutil.which("ffmpeg"), "-v", "error", "-i", str(p), "-frames:v", "1",
                              "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"], timeout=20).stdout
                  for p in [path, reference]]
        self.assertEqual(len(frames[0]), 1920 * 1080 * 3)
        self.assertEqual(len(frames[0]), len(frames[1]))
        mae = sum(abs(a-b) for a, b in zip(*frames)) / len(frames[0])
        self.assertLessEqual(mae, 2, "canonical output must match explicit full color conversion within encode rounding")
        return video, mae

    def test_known_sdr_converts_primaries_transfer_matrix_and_keeps_native_timing(self):
        for name, source in self.sources.items():
            output = product.compose([source], self.root / (name + "-actual"), composition_profile="steady-v2-cfr24")
            reference = self.root / (name + "-reference.mp4")
            product.run([shutil.which("ffmpeg"), "-v", "error", "-nostdin", "-y", "-i", str(source),
                         "-vf", "colorspace=all=bt709:range=tv:format=yuv420p", "-an", "-t", "5",
                         "-c:v", "libx264", "-preset", "medium", "-crf", "18", "-maxrate", "24M",
                         "-bufsize", "48M", "-threads", "2", "-pix_fmt", "yuv420p", "-color_primaries", "bt709",
                         "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv", str(reference)], timeout=45)
            video, mae = self.matches_reference(output["master"], reference)
            self.rows.append({"case": name, "facts": video, "referenceRGB_MAE": mae,
                              "masterSHA256": hashlib.sha256(output["master"].read_bytes()).hexdigest()})
        # No invented input metadata, new policy for partial/untagged sources,
        # or changes to the already canonical fast path (including unknown range).
        known = {"color_space": "smpte170m", "color_transfer": "smpte170m", "color_primaries": "smpte170m", "color_range": "tv"}
        for key in known:
            partial = dict(known); partial.pop(key)
            self.assertEqual(product.sdr_colorspace_conversion(partial), "")
        self.assertEqual(product.sdr_colorspace_conversion({}), "")
        for transfer in ["smpte2084", "arib-std-b67", "unknown"]:
            self.assertEqual(product.sdr_colorspace_conversion({**known, "color_transfer": transfer}), "")
        for color_range in [None, "tv", "pc"]:
            self.assertEqual(product.sdr_colorspace_conversion({"color_space": "bt709", "color_transfer": "bt709", "color_primaries": "bt709", "color_range": color_range}), "")
        # Compile the actual product without its one conversion admission line.
        # Some FFmpeg versions honor output tags without converting primaries.
        # Both positive and omitted paths use the same metadata AND pixel oracle.
        source = (CONTAINER / "compose.py").read_text()
        anchor = "        filters = sdr_colorspace_conversion(video) + filters\n"
        self.assertEqual(source.count(anchor), 1)
        module = types.ModuleType("sdr_conversion_omitted")
        sys.modules[module.__name__] = module
        try:
            exec(compile(source.replace(anchor, "", 1), str(CONTAINER / "compose.py"), "exec"), module.__dict__)
            for name in ["bt601", "bt2020-sdr"]:
                output = module.compose([self.sources[name]], self.root / (name + "-omitted"), composition_profile="steady-v2-cfr24")
                with self.assertRaisesRegex(AssertionError, "fully converted|explicit full color conversion") as refusal:
                    self.matches_reference(output["master"], self.root / (name + "-reference.mp4"))
                self.rows.append({"case": name + "-compiled-omission", "expectedCanonicalColorOracleRefusal": True,
                                  "oracle": str(refusal.exception)})
        finally:
            del sys.modules[module.__name__]
