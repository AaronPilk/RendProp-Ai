"""Tests for compose.py - run with `python3 -m pytest tools/screenshots -q`
(or `python3 -m unittest tools.screenshots.test_compose`).

Synthetic 1320 x 2868 captures stand in for the simulator PNGs, so the suite
needs nothing from the Mac. Rendering is exercised for real (Pillow), which is
the point: the frames these tests write are the frames the App Store gets.
"""

import io
import json
import os
import shutil
import sys
import tempfile
import unittest

from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compose  # noqa: E402


def make_capture(path, colour=(240, 240, 250)):
    image = Image.new("RGB", compose.CANVAS, colour)
    # A "status bar" and a "nav bar" so the thumbnails are not flat colour.
    for y in range(0, 160):
        for x in range(0, 1320, 7):
            image.putpixel((x, y), (30, 30, 40))
    image.save(path, "PNG")
    return path


class TempDir(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="compose-test-")
        self.src = os.path.join(self.root, "src")
        self.out = os.path.join(self.root, "out")
        os.makedirs(self.src)
        for name in ("01-published-tour.png", "02-home-showroom.png", "03-sample-tour.png"):
            make_capture(os.path.join(self.src, name))
        make_capture(os.path.join(self.src, "s09-venue-home_0_ABCDEF.png"), (250, 240, 240))

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def write_plan(self, frames, defaults=None):
        path = os.path.join(self.root, "plan.json")
        data = {"frames": frames}
        if defaults:
            data["defaults"] = defaults
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(data, handle)
        return path

    def run_main(self, argv):
        stdout, stderr = io.StringIO(), io.StringIO()
        old = sys.stdout, sys.stderr
        sys.stdout, sys.stderr = stdout, stderr
        try:
            code = compose.main(argv)
        finally:
            sys.stdout, sys.stderr = old
        return code, stdout.getvalue(), stderr.getvalue()


class SourceResolutionTests(TempDir):
    def test_exact_name(self):
        self.assertTrue(compose.resolve_source(self.src, "01-published-tour.png").endswith("01-published-tour.png"))

    def test_legacy_alias_both_ways(self):
        # The plan may say s08-published-tour.png while the directory holds 01-published-tour.png.
        self.assertTrue(compose.resolve_source(self.src, "s08-published-tour.png").endswith("01-published-tour.png"))
        make_capture(os.path.join(self.src, "s03-new-home.png"))
        self.assertTrue(compose.resolve_source(self.src, "05-new-home.png").endswith("s03-new-home.png"))

    def test_bridge_export_suffix(self):
        # xcresulttool exports s09-venue-home_0_<id>.png; the plan says s09-venue-home.png.
        self.assertTrue(compose.resolve_source(self.src, "s09-venue-home.png").endswith("s09-venue-home_0_ABCDEF.png"))

    def test_missing(self):
        self.assertIsNone(compose.resolve_source(self.src, "s14-leads.png"))


class TextTests(unittest.TestCase):
    def setUp(self):
        self.fonts = compose.Fonts()

    def test_balanced_wrap_prefers_a_sentence_break(self):
        font = self.fonts.bold(compose.HEADLINE_SIZE)
        lines = compose.wrap_balanced(font, "Walk it once. A cinematic tour.", 1128)
        self.assertEqual(lines, ["Walk it once.", "A cinematic tour."])

    def test_explicit_newline_is_honoured(self):
        font = self.fonts.bold(compose.HEADLINE_SIZE)
        self.assertEqual(compose.wrap_balanced(font, "Every tool\nin one place", 1128),
                         ["Every tool", "in one place"])

    def test_short_text_stays_on_one_line(self):
        font = self.fonts.bold(compose.HEADLINE_SIZE)
        self.assertEqual(compose.wrap_balanced(font, "One tap", 1128), ["One tap"])

    def test_too_long_shrinks_then_fails(self):
        with self.assertRaises(compose.ComposeError):
            compose.fit_text(self.fonts, "headline",
                             "This headline is far too long to ever fit on two lines of a phone-sized frame", 1128)

    def test_emoji_and_symbols_are_refused(self):
        with self.assertRaises(compose.ComposeError):
            compose.validate_text("headline", "Photos fixed \U0001F4F8")
        with self.assertRaises(compose.ComposeError):
            compose.validate_text("headline", "Tours → leads")
        self.assertEqual(compose.validate_text("headline", "It’s done — share it"), "It’s done — share it")

    def test_contrast_maths(self):
        self.assertAlmostEqual(compose.contrast_ratio((255, 255, 255), (0, 0, 0)), 21.0, places=1)
        self.assertGreater(compose.contrast_ratio((255, 255, 255), compose.hex_to_rgb("#7C3AED")), 4.5)
        self.assertGreater(compose.contrast_ratio(compose.hex_to_rgb(compose.LAVENDER),
                                                  compose.hex_to_rgb("#7C3AED")), 4.5)
        self.assertGreater(compose.contrast_ratio(compose.hex_to_rgb(compose.INK_DIM),
                                                  compose.hex_to_rgb("#F7F6FB")), 4.5)

    def test_every_preset_clears_aa_for_its_text_colours(self):
        for name, (top, bottom) in compose.PRESETS.items():
            top_rgb, bottom_rgb = compose.hex_to_rgb(top), compose.hex_to_rgb(bottom)
            light = compose.is_light(top_rgb) and compose.is_light(bottom_rgb)
            headline = compose.hex_to_rgb(compose.INK if light else compose.WHITE)
            subline = compose.hex_to_rgb(compose.INK_DIM if light else compose.LAVENDER)
            for y in range(0, 700, 50):
                behind = compose.gradient_colour_at(top_rgb, bottom_rgb, y)
                self.assertGreaterEqual(compose.contrast_ratio(headline, behind), 4.5, name)
                self.assertGreaterEqual(compose.contrast_ratio(subline, behind), 4.5, name)


class RenderTests(TempDir):
    def test_single_frame_is_exactly_the_store_size_and_rgb(self):
        plan = self.write_plan([{"src": "01-published-tour.png", "out": "01-a.png",
                                 "headline": "Walk it once. A cinematic tour.",
                                 "subline": "Film a walkthrough on your phone.", "bg": "violet"}])
        code, out, err = self.run_main(["--src", self.src, "--plan", plan, "--out", self.out])
        self.assertEqual(code, 0, err)
        image = Image.open(os.path.join(self.out, "01-a.png"))
        self.assertEqual(image.size, compose.CANVAS)
        self.assertEqual(image.mode, "RGB")
        self.assertIn("contrast", out)
        self.assertTrue(os.path.isfile(os.path.join(self.out, "sheet.jpg")))
        # The inset sits on the gradient: the top-left corner is background, the
        # centre of the inset band is the capture.
        self.assertEqual(image.getpixel((10, 10)), compose.hex_to_rgb("#5B21B6"))
        self.assertEqual(image.getpixel((660, 1800)), (240, 240, 250))

    def test_inset_fit_keeps_the_whole_capture_inside(self):
        plan = self.write_plan([{"src": "01-published-tour.png", "out": "01-a.png",
                                 "headline": "Inside the frame", "bg": "mist", "fit": "inset"}])
        code, _out, err = self.run_main(["--src", self.src, "--plan", plan, "--out", self.out])
        self.assertEqual(code, 0, err)
        image = Image.open(os.path.join(self.out, "01-a.png"))
        # Bottom rows are background again (the capture ends above the margin).
        self.assertNotEqual(image.getpixel((660, 2860)), (240, 240, 250))

    def test_stack_layout_takes_two_or_three_captures(self):
        plan = self.write_plan([{"src": ["01-published-tour.png", "02-home-showroom.png", "s09-venue-home.png"],
                                 "out": "03-stack.png", "headline": "Venues, gyms and restaurants too",
                                 "bg": "ink"}])
        code, out, err = self.run_main(["--src", self.src, "--plan", plan, "--out", self.out])
        self.assertEqual(code, 0, err)
        self.assertIn("stack/3", out)
        image = Image.open(os.path.join(self.out, "03-stack.png"))
        self.assertEqual(image.size, compose.CANVAS)
        # The front (last) capture is the pink one and covers the right-centre.
        self.assertEqual(image.getpixel((900, 2000)), (250, 240, 240))

    def test_missing_source_fails_unless_skipped(self):
        plan = self.write_plan([{"src": "s14-leads.png", "out": "09-leads.png", "headline": "Leads"},
                                {"src": "01-published-tour.png", "out": "01-a.png", "headline": "Fine"}])
        code, _out, err = self.run_main(["--src", self.src, "--plan", plan, "--out", self.out])
        self.assertEqual(code, 1)
        self.assertIn("missing source s14-leads.png", err)
        code, out, _err = self.run_main(["--src", self.src, "--plan", plan, "--out", self.out, "--skip-missing"])
        self.assertEqual(code, 0)
        self.assertIn("SKIPPED", out)
        self.assertTrue(os.path.isfile(os.path.join(self.out, "01-a.png")))
        self.assertFalse(os.path.isfile(os.path.join(self.out, "09-leads.png")))

    def test_plan_rules(self):
        too_many = [{"src": "01-published-tour.png", "out": "%02d.png" % i, "headline": "x"} for i in range(11)]
        with self.assertRaises(compose.ComposeError):
            compose.load_plan(self.write_plan(too_many))
        with self.assertRaises(compose.ComposeError):
            compose.load_plan(self.write_plan([{"src": "a.png", "out": "dup.png", "headline": "x"},
                                               {"src": "b.png", "out": "dup.png", "headline": "y"}]))
        with self.assertRaises(compose.ComposeError):
            compose.load_plan(self.write_plan([{"src": "a.png", "out": "sub/dir.png", "headline": "x"}]))
        with self.assertRaises(compose.ComposeError):
            compose.load_plan(self.write_plan([{"src": "a.png", "out": "a.png"}]))
        frames = compose.load_plan(self.write_plan([{"src": "a.png", "out": "a.png", "headline": "x"}],
                                                   defaults={"bg": "grape", "radius": 60}))
        self.assertEqual(frames[0]["bg"], "grape")
        self.assertEqual(frames[0]["radius"], 60)

    def test_long_headline_warns_but_renders(self):
        plan = self.write_plan([{"src": "01-published-tour.png", "out": "01-a.png",
                                 "headline": "One walkthrough. A cinematic tour."}])
        code, out, _err = self.run_main(["--src", self.src, "--plan", plan, "--out", self.out])
        self.assertEqual(code, 0)
        self.assertIn("aim for <= 32", out)

    def test_wrong_size_capture_is_refused(self):
        Image.new("RGB", (1290, 2796)).save(os.path.join(self.src, "bad.png"))
        plan = self.write_plan([{"src": "bad.png", "out": "01-a.png", "headline": "x"}])
        code, _out, err = self.run_main(["--src", self.src, "--plan", plan, "--out", self.out])
        self.assertEqual(code, 1)
        self.assertIn("1290x2796", err)


class CheckTests(TempDir):
    def test_check_passes_a_good_set_and_writes_the_sheet(self):
        frames = [{"src": "01-published-tour.png", "out": "%02d.png" % i, "headline": "Frame %d" % i}
                  for i in range(1, 4)]
        plan = self.write_plan(frames)
        code, _out, err = self.run_main(["--src", self.src, "--plan", plan, "--out", self.out, "--no-sheet"])
        self.assertEqual(code, 0, err)
        code, out, _err = self.run_main(["--check", "--out", self.out])
        self.assertEqual(code, 0, out)
        self.assertIn("all 3 frame(s) pass", out)
        self.assertTrue(os.path.isfile(os.path.join(self.out, "sheet.jpg")))

    def test_check_fails_wrong_size_alpha_and_too_few(self):
        os.makedirs(self.out)
        Image.new("RGB", (1290, 2796)).save(os.path.join(self.out, "01.png"))
        Image.new("RGBA", compose.CANVAS, (0, 0, 0, 0)).save(os.path.join(self.out, "02.png"))
        code, out, err = self.run_main(["--check", "--out", self.out, "--no-sheet"])
        self.assertEqual(code, 1)
        self.assertIn("size 1290x2796", out)
        self.assertIn("fully transparent", out)
        self.assertIn("at least 3", out)
        self.assertIn("problem(s)", err)

    def test_check_against_a_plan_reports_missing_outputs(self):
        plan = self.write_plan([{"src": "01-published-tour.png", "out": "01-a.png", "headline": "x"}])
        os.makedirs(self.out)
        code, out, _err = self.run_main(["--check", "--out", self.out, "--plan", plan, "--no-sheet"])
        self.assertEqual(code, 1)
        self.assertIn("missing", out)

    def test_over_eight_megabytes_is_flagged(self):
        os.makedirs(self.out)
        path = os.path.join(self.out, "big.png")
        Image.new("RGB", compose.CANVAS).save(path)
        with open(path, "ab") as handle:
            handle.write(b"\0" * (8 * 1024 * 1024))
        self.assertTrue(any("8 MB" in p for p in compose.check_one(path)))


if __name__ == "__main__":
    unittest.main(verbosity=2)
