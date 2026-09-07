#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Unit tests for tools/video/narrate_elevenlabs.py. Standard library only, NO
NETWORK — every ElevenLabs call is either unreachable by construction (an
explicit --voice / a fake fn) or exercised through `with_retries` with a stub.

Run from the repo root:
    python3 -m unittest discover -s tools/video -v
or:
    python3 tools/video/test_narrate_elevenlabs.py
"""
import io
import json
import os
import shutil
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import narrate_elevenlabs as ne  # noqa: E402

HAVE_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


SAMPLE_SCRIPT = """\
## 00 · 0:00–0:03 · Cold open
On screen: the hook shot.
Say: Every listing looks the same.
  Until yours flies.
Caption: Until yours flies

## 01 · 0:03–0:08 · Home
Shot: Home hero.
Caption: This is Rendprop

## 02 · 0:08–0:13 · Add a home
Say: Start with the space.
Caption: Start with the space
"""


# ---------------------------------------------------------------------------
# the script parser (via build_onboarding.parse_script, re-used verbatim) and
# select_segments — a silent card (segment 01, no Say:) must never come back.
# ---------------------------------------------------------------------------

class TestScriptParsing(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.script_path = os.path.join(self.tmp, "script.md")
        write(self.script_path, SAMPLE_SCRIPT)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_wrapped_say_line_is_joined_with_a_space(self):
        script = ne.parse_script(self.script_path)
        self.assertEqual(script["00"]["say"], "Every listing looks the same. Until yours flies.")

    def test_segment_with_no_say_line_is_blank_not_missing(self):
        script = ne.parse_script(self.script_path)
        self.assertIn("01", script)
        self.assertEqual(script["01"]["say"], "")

    def test_select_segments_drops_silent_cards(self):
        script = ne.parse_script(self.script_path)
        segments, warnings = ne.select_segments(script)
        self.assertEqual([sid for sid, _ in segments], ["00", "02"])
        self.assertEqual(warnings, [])

    def test_select_segments_preserves_id_order(self):
        # id "10" would sort before "02" as a string; select_segments sorts the
        # dict by key, so this also pins down that it is a plain string sort
        # (matching the two-digit ids the script format promises), not a trap
        # a numeric id ever needs to worry about in practice.
        script = {"02": {"say": "b"}, "00": {"say": "a"}}
        segments, _ = ne.select_segments(script)
        self.assertEqual([sid for sid, _ in segments], ["00", "02"])

    def test_only_filters_to_the_named_ids(self):
        script = ne.parse_script(self.script_path)
        segments, warnings = ne.select_segments(script, only="02")
        self.assertEqual(segments, [("02", "Start with the space.")])
        self.assertEqual(warnings, [])

    def test_only_accepts_a_list_as_well_as_a_csv_string(self):
        script = ne.parse_script(self.script_path)
        by_str, _ = ne.select_segments(script, only="00,02")
        by_list, _ = ne.select_segments(script, only=["00", "02"])
        self.assertEqual(by_str, by_list)

    def test_only_warns_on_an_id_with_no_say_line(self):
        script = ne.parse_script(self.script_path)
        segments, warnings = ne.select_segments(script, only="00,01")
        self.assertEqual([sid for sid, _ in segments], ["00"])
        self.assertEqual(len(warnings), 1)
        self.assertIn("01", warnings[0])

    def test_only_warns_on_an_id_absent_from_the_script_entirely(self):
        script = ne.parse_script(self.script_path)
        _, warnings = ne.select_segments(script, only="zz")
        self.assertEqual(len(warnings), 1)
        self.assertIn("zz", warnings[0])

    def test_no_say_lines_anywhere_yields_no_segments(self):
        path = os.path.join(self.tmp, "silent.md")
        write(path, "## 00 · 0:00–0:03 · Card\nCaption: Hi\n")
        segments, _ = ne.select_segments(ne.parse_script(path))
        self.assertEqual(segments, [])


# ---------------------------------------------------------------------------
# build_plan — resuming a partial run
# ---------------------------------------------------------------------------

class TestBuildPlan(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_existing_mp3_is_skipped_by_default(self):
        write(os.path.join(self.tmp, "00.mp3"), "already here")
        plan = ne.build_plan([("00", "hi"), ("01", "there")], self.tmp, overwrite=False)
        skip_by_id = {sid: skip for sid, _, _, skip in plan}
        self.assertTrue(skip_by_id["00"])
        self.assertFalse(skip_by_id["01"])

    def test_overwrite_regenerates_even_an_existing_file(self):
        write(os.path.join(self.tmp, "00.mp3"), "already here")
        plan = ne.build_plan([("00", "hi")], self.tmp, overwrite=True)
        self.assertFalse(plan[0][3])

    def test_plan_paths_are_id_dot_mp3_under_out_dir(self):
        plan = ne.build_plan([("07", "hi")], self.tmp, overwrite=False)
        self.assertEqual(plan[0][2], os.path.join(self.tmp, "07.mp3"))


# ---------------------------------------------------------------------------
# voice selection — "warm" premade first, else the documented fallback
# ---------------------------------------------------------------------------

class TestPickDefaultVoice(unittest.TestCase):
    def test_prefers_a_premade_voice_labelled_warm(self):
        voices = [
            {"voice_id": "cloned-warm", "name": "Clone", "category": "cloned",
             "labels": {"description": "warm"}},
            {"voice_id": "premade-cold", "name": "Cold One", "category": "premade",
             "labels": {"description": "brisk"}},
            {"voice_id": "premade-warm", "name": "Warm One", "category": "premade",
             "labels": {"description": "warm and calm"}},
        ]
        voice_id, name, note = ne.pick_default_voice(voices)
        self.assertEqual(voice_id, "premade-warm")
        self.assertIn("warm", note)

    def test_label_match_is_case_insensitive(self):
        voices = [{"voice_id": "v1", "name": "V1", "category": "premade", "labels": {"description": "WARM"}}]
        voice_id, _, _ = ne.pick_default_voice(voices)
        self.assertEqual(voice_id, "v1")

    def test_falls_back_when_no_premade_voice_is_labelled_warm(self):
        voices = [{"voice_id": "v1", "name": "V1", "category": "premade", "labels": {"description": "brisk"}}]
        voice_id, name, note = ne.pick_default_voice(voices)
        self.assertEqual(voice_id, ne.FALLBACK_VOICE_ID)
        self.assertIn("fallback", note)

    def test_falls_back_on_an_empty_catalogue(self):
        voice_id, _, note = ne.pick_default_voice([])
        self.assertEqual(voice_id, ne.FALLBACK_VOICE_ID)
        self.assertIn("fallback", note)

    def test_a_warm_cloned_voice_never_wins_over_a_plain_premade_one(self):
        # category must be "premade" — a warm-labelled clone is still skipped.
        voices = [{"voice_id": "clone", "name": "Clone", "category": "cloned", "labels": {"description": "warm"}}]
        voice_id, _, note = ne.pick_default_voice(voices)
        self.assertEqual(voice_id, ne.FALLBACK_VOICE_ID)


class TestResolveVoice(unittest.TestCase):
    def test_explicit_voice_never_touches_the_network(self):
        # key=None would blow up anything that tried to use it — proving this
        # path returns before doing so.
        voice_id, name, note = ne.resolve_voice(None, "abc123", retries=0, base_delay=0)
        self.assertEqual(voice_id, "abc123")
        self.assertEqual(note, "explicit --voice")


# ---------------------------------------------------------------------------
# the API key file — read once, never echoed
# ---------------------------------------------------------------------------

class TestReadApiKey(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_missing_file_exits_without_naming_a_key(self):
        path = os.path.join(self.tmp, "nope.key")
        with self.assertRaises(SystemExit) as ctx:
            ne.read_api_key(path)
        self.assertIn(path, str(ctx.exception))

    def test_empty_file_exits(self):
        path = os.path.join(self.tmp, "empty.key")
        write(path, "   \n")
        with self.assertRaises(SystemExit):
            ne.read_api_key(path)

    def test_key_is_stripped_of_surrounding_whitespace(self):
        path = os.path.join(self.tmp, "real.key")
        write(path, "  sk_abc123  \n")
        self.assertEqual(ne.read_api_key(path), "sk_abc123")

    def test_tilde_is_expanded(self):
        # The default --key-file lives under ~ — read_api_key must resolve it
        # via expanduser, not treat "~" as a literal path component.
        write(os.path.join(self.tmp, "under-home.key"), "sk_home_key")
        old_home = os.environ.get("HOME")
        os.environ["HOME"] = self.tmp
        try:
            self.assertEqual(ne.read_api_key("~/under-home.key"), "sk_home_key")
        finally:
            if old_home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = old_home


# ---------------------------------------------------------------------------
# with_retries — 429/5xx back off and retry; everything else fails fast.
# No real sleeping and no real HTTP: fn is a stub, time.sleep is patched out.
# ---------------------------------------------------------------------------

def make_http_error(code, body=b'{"detail":"nope"}', headers=None):
    fp = io.BytesIO(body)
    return urllib.error.HTTPError(url="https://api.elevenlabs.io/x", code=code, msg="err",
                                  hdrs=headers or {}, fp=fp)


class TestWithRetries(unittest.TestCase):
    def setUp(self):
        self._real_sleep = ne.time.sleep
        ne.time.sleep = lambda *_a, **_k: None      # no real delays in a test

    def tearDown(self):
        ne.time.sleep = self._real_sleep

    def test_retries_on_429_then_succeeds(self):
        calls = {"n": 0}

        def fn():
            calls["n"] += 1
            if calls["n"] < 3:
                raise make_http_error(429)
            return "ok"

        result = ne.with_retries(fn, retries=5, base_delay=0.01, what="test")
        self.assertEqual(result, "ok")
        self.assertEqual(calls["n"], 3)

    def test_retries_on_503_then_succeeds(self):
        calls = {"n": 0}

        def fn():
            calls["n"] += 1
            if calls["n"] < 2:
                raise make_http_error(503)
            return "ok"

        self.assertEqual(ne.with_retries(fn, retries=5, base_delay=0.01, what="test"), "ok")

    def test_401_fails_on_the_first_try_no_retry(self):
        calls = {"n": 0}

        def fn():
            calls["n"] += 1
            raise make_http_error(401, body=b'{"detail":"bad key"}')

        with self.assertRaises(SystemExit) as ctx:
            ne.with_retries(fn, retries=5, base_delay=0.01, what="test")
        self.assertEqual(calls["n"], 1)
        self.assertIn("bad key", str(ctx.exception))

    def test_exhausting_retries_on_429_exits(self):
        def fn():
            raise make_http_error(429)

        with self.assertRaises(SystemExit):
            ne.with_retries(fn, retries=2, base_delay=0.01, what="test")

    def test_a_retry_after_header_is_honoured_over_backoff(self):
        seen_delays = []
        ne.time.sleep = lambda d: seen_delays.append(d)
        calls = {"n": 0}

        def fn():
            calls["n"] += 1
            if calls["n"] == 1:
                raise make_http_error(429, headers={"Retry-After": "7"})
            return "ok"

        ne.with_retries(fn, retries=3, base_delay=0.01, what="test")
        self.assertEqual(seen_delays[0], 7.0)

    def test_url_error_is_retried(self):
        calls = {"n": 0}

        def fn():
            calls["n"] += 1
            if calls["n"] < 2:
                raise urllib.error.URLError("connection refused")
            return "ok"

        self.assertEqual(ne.with_retries(fn, retries=3, base_delay=0.01, what="test"), "ok")


# ---------------------------------------------------------------------------
# collect_durations — degrades cleanly with no ffprobe; correct with one.
# ---------------------------------------------------------------------------

class TestCollectDurations(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_returns_empty_when_ffprobe_is_not_on_path(self):
        # collect_durations does `import shutil` internally — it binds the same
        # cached module object, so patching shutil.which here reaches it too.
        original = shutil.which
        shutil.which = lambda name: None
        try:
            write(os.path.join(self.tmp, "00.mp3"), "not really audio")
            self.assertEqual(ne.collect_durations(self.tmp, ["00"]), {})
        finally:
            shutil.which = original

    @unittest.skipUnless(HAVE_FFMPEG, "ffmpeg/ffprobe not installed")
    def test_measures_a_real_mp3_with_ffprobe(self):
        import subprocess
        path = os.path.join(self.tmp, "00.mp3")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=mono",
                        "-t", "1.5", path], check=True)
        durations = ne.collect_durations(self.tmp, ["00", "missing"])
        self.assertIn("00", durations)
        self.assertAlmostEqual(durations["00"], 1.5, delta=0.2)
        self.assertNotIn("missing", durations)


if __name__ == "__main__":
    unittest.main()
