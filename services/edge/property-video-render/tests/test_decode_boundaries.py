"""Actual installed decoder boundaries; synthetic files and owned loopback only.

The direct URL case tests a helper defense, not admission of URLs by CPU tasks.
No package, decoder or media subprocess is replaced. The photo-quality transport
double copies exact owned bytes so both actual Pillow entry points are exercised.
"""
import contextlib
import datetime
import hashlib
import http.client
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "container"))
import numpy as np
from PIL import Image, UnidentifiedImageError
import compose as product
import motion_qc
import photo_quality
import prepare_image
import renderer
import smooth_finish


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def record(name, value):
    location = os.environ.get("RENDPROP_DECODE_BOUNDARY_EVIDENCE")
    if location:
        target = Path(location)
        target.mkdir(parents=True, exist_ok=True)
        with (target / (name + ".json")).open("x") as output:
            json.dump(value, output, indent=2, sort_keys=True)
            output.write("\n")


class PhotoDispatchBoundary(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def photo(self, kind):
        path = self.root / ("photo." + kind.lower())
        Image.new("RGB", (24, 16), (50, 100, 150)).save(path, kind)
        return path

    def quality(self, source, name):
        directory = self.root / name
        directory.mkdir()
        data = source.read_bytes()
        sha = hashlib.sha256(data).hexdigest()
        # The negative TIFF intentionally carries an allowed declared MIME;
        # exact bytes still need decoder dispatch admission independently.
        mime = {".jpeg": "image/jpeg", ".png": "image/png", ".webp": "image/webp"}.get(source.suffix, "image/png")
        source_item = {"bucket": "captures", "key": "owned/source", "etag": '"owned"',
                       "bytes": len(data), "sha256": sha, "mime": mime,
                       "url": "https://owned.fixture.invalid/source"}
        candidate_item = {**source_item, "key": "owned/candidate",
                          "url": "https://owned.fixture.invalid/candidate"}
        task = {"action": "prepare_photo_quality", "policy": "photo-fixed-features-v1",
                "check_id": "00000000-0000-4000-8000-000000000001",
                "evidence_id": "00000000-0000-4000-8000-000000000002",
                "lease_token": "00000000-0000-4000-8000-000000000003",
                "expires_at": (datetime.datetime.now(datetime.timezone.utc)
                               + datetime.timedelta(minutes=5)).isoformat(),
                "prepared_source": source_item, "candidate": candidate_item}

        def copy_owned(item, target, hosts, *, max_bytes):
            self.assertIn(item, (source_item, candidate_item))
            self.assertEqual(hosts, {"owned.fixture.invalid"})
            self.assertEqual((len(data), sha), (item["bytes"], item["sha256"]))
            self.assertLessEqual(len(data), max_bytes)
            Path(target).write_bytes(data)
            return sha

        with patch.object(photo_quality, "download", side_effect=copy_owned):
            return photo_quality.prepare_photo_quality(task, directory, {"owned.fixture.invalid"})

    @contextlib.contextmanager
    def observe_tiff_factory(self, path):
        Image.init()
        factory, accept = Image.OPEN["TIFF"]
        calls = []

        def observed(*args, **kwargs):
            calls.append("actual_TIFF_factory")
            return factory(*args, **kwargs)

        with patch.dict(Image.OPEN, {"TIFF": (observed, accept)}):
            # Prove the counter wraps the installed real parser before using it
            # as the no-dispatch oracle, then reset only that fixture control.
            with Image.open(path) as control:
                self.assertEqual(control.format, "TIFF")
                control.load()
            self.assertGreater(len(calls), 0)
            calls.clear()
            yield calls

    def test_supported_jpeg_png_webp_reach_actual_decode_and_quality(self):
        for kind in ("JPEG", "PNG", "WEBP"):
            with self.subTest(kind=kind):
                source = self.photo(kind)
                image, profile = prepare_image.decoded_srgb(source)
                try:
                    self.assertEqual((image.mode, image.size), ("RGB", (24, 16)))
                    self.assertGreater(len(profile), 100)
                    mean = np.asarray(image).mean(axis=(0, 1))
                    self.assertLess(float(np.max(np.abs(mean - [50, 100, 150]))), 5)
                finally:
                    image.close()
                output = self.quality(source, "quality-" + kind)
                manifest = output["receipt"]["manifest"]
                self.assertEqual(len(manifest["images"]), 10)
                self.assertEqual({p["input_sha256"] for p in manifest["parents"]}, {digest(source)})
                self.assertTrue(all(row["bytes"] > 0 for row in manifest["images"]))
                record("supported-photo-" + kind.lower(), {
                    "sourceSHA256": digest(source), "actualImageMode": "RGB", "size": [24, 16],
                    "qualityImageCount": 10, "qualityPixelHashes": [p["normalized_pixel_sha256"]
                                                                     for p in manifest["parents"]]})

    def test_unsupported_tiff_never_enters_primary_decoder(self):
        source = self.photo("TIFF")
        with self.observe_tiff_factory(source) as calls:
            with self.assertRaises((UnidentifiedImageError, ValueError)):
                prepare_image.decoded_srgb(source)
            record("primary-tiff-dispatch", {"sourceSHA256": digest(source),
                                             "actualTIFFFactoryCalls": len(calls), "expected": 0})
            self.assertEqual(calls, [], "unsupported_primary_photo_must_not_dispatch_TIFF")

    def test_unsupported_tiff_never_enters_quality_header_decoder(self):
        source = self.photo("TIFF")
        with self.observe_tiff_factory(source) as calls:
            with self.assertRaises((UnidentifiedImageError, ValueError)):
                self.quality(source, "unsupported-quality")
            record("quality-tiff-dispatch", {"sourceSHA256": digest(source),
                                             "actualTIFFFactoryCalls": len(calls), "expected": 0})
            self.assertEqual(calls, [], "unsupported_quality_photo_must_not_dispatch_TIFF")


class LocalMediaInputBoundary(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory()
        cls.root = Path(cls.temporary.name)
        cls.addClassCleanup(cls.temporary.cleanup)
        ffmpeg = shutil.which("ffmpeg")
        if not ffmpeg or not shutil.which("ffprobe"):
            raise AssertionError("actual_installed_FFmpeg_and_ffprobe_required")
        # Trusted synthesis remains lavfi; it is not routed through product
        # input constructors and cannot carry untrusted URLs or filters.
        product.run([ffmpeg, "-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
                     "color=c=red:s=1920x1080:r=24:d=1", "-an", "-c:v", "libx264",
                     "-preset", "ultrafast", "-threads", "2", "-pix_fmt", "yuv420p",
                     "-movflags", "+faststart", str(cls.root / "fixture.mp4")], timeout=20)
        for extension, codec in (("m4a", "aac"), ("mp3", "libmp3lame")):
            product.run([ffmpeg, "-v", "error", "-nostdin", "-y", "-f", "lavfi", "-i",
                         "sine=frequency=1000:duration=1:sample_rate=48000", "-c:a", codec,
                         str(cls.root / ("fixture." + extension))], timeout=10)
        product.run([ffmpeg, "-v", "error", "-nostdin", "-y", "-i", str(cls.root / "fixture.mp4"),
                     "-an", "-c:v", "copy", "-f", "mpegts", str(cls.root / "segment.ts")], timeout=10)
        for path in cls.root.iterdir():
            if path.is_file() and not 0 < path.stat().st_size <= 2 * 1024 * 1024:
                raise AssertionError("bounded_synthetic_loopback_fixture_required")

    @contextlib.contextmanager
    def server(self):
        bodies = {"/fixture.mp4": (self.root / "fixture.mp4").read_bytes(),
                  "/segment.ts": (self.root / "segment.ts").read_bytes()}
        requests = []
        lock = threading.Lock()

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                with lock:
                    requests.append(self.path)
                body = bodies.get(self.path)
                self.send_response(200 if body is not None else 404)
                self.send_header("Content-Length", str(len(body) if body is not None else 0))
                self.send_header("Connection", "close")
                self.end_headers()
                if body is not None:
                    try:
                        self.wfile.write(body)
                    except (BrokenPipeError, ConnectionResetError):
                        pass  # FFprobe may finish its bounded probe before EOF.

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            # Positive fixture transport proves the request counter/server work.
            connection = http.client.HTTPConnection(*server.server_address, timeout=2)
            try:
                connection.request("GET", "/fixture.mp4")
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertEqual(response.read(2 * 1024 * 1024 + 1), bodies["/fixture.mp4"])
            finally:
                connection.close()
            self.assertEqual(requests, ["/fixture.mp4"])
            requests.clear()
            yield "http://127.0.0.1:" + str(server.server_address[1]), requests
        finally:
            server.shutdown()
            server.server_close()
            thread.join(3)
            self.assertFalse(thread.is_alive(), "owned_loopback_server_must_stop")

    def test_local_mp4_m4a_mp3_and_actual_narration_decode(self):
        facts = product.probe(self.root / "fixture.mp4")
        video = next(s for s in facts["streams"] if s["codec_type"] == "video")
        self.assertEqual((video["width"], video["height"]), (1920, 1080))
        for extension in ("m4a", "mp3"):
            source = self.root / ("fixture." + extension)
            directory = self.root / ("inspect-" + extension)
            directory.mkdir()
            item = {"url": "https://owned.fixture.invalid/narration", "bytes": source.stat().st_size,
                    "sha256": digest(source)}

            def copy_owned(actual, target, hosts, *, max_bytes):
                self.assertEqual(actual, item)
                self.assertEqual(hosts, {"owned.fixture.invalid"})
                self.assertLessEqual(actual["bytes"], max_bytes)
                Path(target).write_bytes(source.read_bytes())
                return digest(source)

            with patch.object(renderer, "download", side_effect=copy_owned):
                result = renderer.inspect_audio({"source": item, "job_id": "fixture-job",
                                                 "lease_token": "fixture-lease", "manifest_sha256": "a" * 64},
                                                directory, {"owned.fixture.invalid"})
            self.assertEqual(result["audio_streams"], 1)
            self.assertTrue(.9 < result["duration_s"] < 1.2)
            record("local-audio-" + extension, {"sourceSHA256": digest(source),
                                                "duration_s": result["duration_s"], "audioStreams": 1})

    def test_ffprobe_must_not_attempt_direct_loopback_input(self):
        # The task contract already downloads media locally. This deliberately
        # passes a URL to the actual helper to prove its independent boundary.
        with self.server() as (origin, requests):
            failure = None
            try:
                product.probe(origin + "/fixture.mp4")
            except subprocess.CalledProcessError as error:
                failure = error
            record("direct-loopback-probe", {"actualRequests": list(requests), "expectedRequests": [],
                                              "refused": failure is not None,
                                              "stderrSHA256": hashlib.sha256(failure.stderr).hexdigest()
                                              if failure is not None else None})
            self.assertEqual(requests, [], "ffprobe_must_not_attempt_remote_input")
            self.assertIsNotNone(failure, "remote_protocol_must_be_refused")
            self.assertIn(b"not on whitelist", failure.stderr)
            self.assertIn(b"http", failure.stderr)
            self.assertIn(b"file,pipe", failure.stderr)

    def test_local_hls_must_not_fetch_loopback_segment(self):
        with self.server() as (origin, requests):
            playlist = self.root / "owned-loopback.m3u8"
            playlist.write_text("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:1\n"
                                "#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:1.0,\n"
                                + origin + "/segment.ts\n#EXT-X-ENDLIST\n")
            failure = None
            try:
                product.probe(playlist)
            except subprocess.CalledProcessError as error:
                failure = error
            record("local-hls-loopback", {"actualRequests": list(requests), "expectedRequests": [],
                                         "refused": failure is not None,
                                         "stderrSHA256": hashlib.sha256(failure.stderr).hexdigest()
                                         if failure is not None else None,
                                         "claim": "Old defaults may already refuse; not a new SSRF finding."})
            self.assertEqual(requests, [], "nested_playlist_must_not_attempt_remote_segment")
            self.assertIsNotNone(failure, "remote_playlist_protocol_must_be_refused")
            self.assertIn(b"not on whitelist", failure.stderr)
            self.assertIn(b"http", failure.stderr)

    def test_local_motion_probe_and_raw_frame_output(self):
        source = self.root / "fixture.mp4"
        stream = motion_qc.probe_stream(source)
        self.assertEqual((stream["width"], stream["height"]), (1920, 1080))
        frames = list(motion_qc.framed_gray_frames(source, 1920, 1080, max_frames=9))
        self.assertEqual(len(frames), 9)
        self.assertTrue(all(frame.shape == (540, 960) for frame in frames))
        record("local-motion-frames", {"frames": 9, "shape": [540, 960],
                                        "frameSHA256": [hashlib.sha256(frame.tobytes()).hexdigest()
                                                        for frame in frames]})

    def test_local_rawvideo_stdin_through_actual_smooth_renderer(self):
        source = self.root / "fixture.mp4"
        output = self.root / "three-frame-smooth.mp4"
        finish = {"strength": 1.0, "zoom": 1.02,
                  "frames": [(1.0, 0.0, np.zeros(2)) for _ in range(3)]}
        smooth_finish.render(source, output, "16:9", finish, 1920, 1080,
                             frames=3, fps=24, test_fast=True)
        facts = motion_qc.probe_stream(output)
        self.assertEqual(int(facts["nb_read_packets"]), 3)
        self.assertEqual((facts["width"], facts["height"]), (1920, 1080))
        self.assertEqual(facts["avg_frame_rate"], "24/1")
        duration = float(product.probe(output)["format"]["duration"])
        self.assertLess(abs(duration - 3 / 24), .01)
        record("local-smooth-rawvideo", {"sha256": digest(output), "packets": 3,
                                         "size": [1920, 1080], "rate": "24/1", "duration": duration})


if __name__ == "__main__":
    unittest.main()
