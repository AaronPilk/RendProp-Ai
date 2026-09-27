"""Synthetic-only geometry/bytes/negative tests; no network, GPU or customer data."""
import json
import math
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from PIL import Image

import prepare_capture as adapter


SESSION = "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb"


def fixture(root):
    (root / "images").mkdir()
    (root / "frames").mkdir()
    manifest = {**adapter.CONVENTIONS, "session_id": SESSION, "frames": [], "feature_point_observations":2000}
    for i in range(20):
        name = f"{i+1:06d}"
        image = Image.new("RGB", (80, 60), (180, 70, 30))
        exif = Image.Exif()
        exif[274] = 1
        image.save(root / "images" / f"{name}.jpg", exif=exif)
        pose = [[1, 0, 0, i*0.02], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]
        points = [{"id": str(2**63 + j), "position": [(j%10-5)*0.08, (j//10-5)*0.08, -2]}
                  for j in range(100)]
        metadata = {"schema_version": 1, "session_id": SESSION,
                    "image": f"images/{name}.jpg", "camera_to_world": pose,
                    "intrinsics": [[60, 0, 40], [0, 60, 30], [0, 0, 1]],
                    "image_resolution": {"width": 80, "height": 60}, "timestamp": 10+i,
                    "tracking_state": {"state": "normal", "reason": None}, "raw_feature_points": points}
        sidecar = f"frames/{name}.json"
        (root / sidecar).write_text(json.dumps(metadata))
        manifest["frames"].append(sidecar)
    (root / "manifest.json").write_text(json.dumps(manifest))


HELDOUT_COLOR = (0, 255, 255)  # Never painted on a training frame.
LATE_HELDOUT_ID = "900001"     # Seen in frames 0-16 only; last observation is held out.


def training_color(index):
    return (40 + index % 120, 120, 60)


def synthetic_capture(root, frames=20, shared_points=120, unique_points=5):
    """Varied per-frame observations for split/leakage/parity checks.

    Every frame re-estimates the shared point IDs (z drifts per frame), carries
    unique per-frame IDs, and held-out frames (index % 8 == 0) are painted a
    colour no training frame ever shows. Returns the per-frame point lists.
    """
    (root / "images").mkdir()
    (root / "frames").mkdir()
    manifest = {**adapter.CONVENTIONS, "session_id": SESSION, "frames": [],
                "feature_point_observations": 0, "image_bytes": 0}
    per_frame = []
    for i in range(frames):
        name = f"{i+1:06d}"
        heldout = i % 8 == 0
        image = Image.new("RGB", (80, 60), HELDOUT_COLOR if heldout else training_color(i))
        exif = Image.Exif()
        exif[274] = 1
        image_path = root / "images" / f"{name}.jpg"
        image.save(image_path, quality=100, subsampling=0, exif=exif)
        angle = 0.0005 * i
        c, s = math.cos(angle), math.sin(angle)
        pose = [[c, 0, s, 0.02 * i], [0, 1, 0, 0.001 * i], [-s, 0, c, 0], [0, 0, 0, 1]]
        points = [{"id": str(j + 1), "position": [(j % 12 - 5.5) * 0.15 + 0.02 * i,
                                                   (j // 12 - 4.5) * 0.15, -2 - 0.0001 * i]}
                  for j in range(shared_points)]
        points += [{"id": str(10**6 + i * 10 + j), "position": [0.02 * i + 0.1 * j - 0.2, -0.3, -1.5 - 0.001 * i]}
                   for j in range(unique_points)]
        if i <= 16:
            points.append({"id": LATE_HELDOUT_ID, "position": [0.02 * i, 0.05, -1.8 - 0.001 * i]})
        metadata = {"schema_version": 1, "session_id": SESSION,
                    "image": f"images/{name}.jpg", "camera_to_world": pose,
                    "intrinsics": [[60, 0, 40], [0, 60, 30], [0, 0, 1]],
                    "image_resolution": {"width": 80, "height": 60}, "timestamp": 10 + i,
                    "tracking_state": {"state": "normal", "reason": None}, "raw_feature_points": points}
        sidecar = f"frames/{name}.json"
        (root / sidecar).write_text(json.dumps(metadata))
        manifest["frames"].append(sidecar)
        manifest["feature_point_observations"] += len(points)
        manifest["image_bytes"] += image_path.stat().st_size
        per_frame.append(points)
    (root / "manifest.json").write_text(json.dumps(manifest))
    return per_frame


class CaptureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="spatial-adapter-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / "capture"
        self.root.mkdir()
        fixture(self.root)

    def alter_frame(self, mutate, frame=1):
        path = self.root / "frames" / f"{frame:06d}.json"
        data = json.loads(path.read_text())
        mutate(data)
        path.write_text(json.dumps(data))

    def test_identity_arkit_camera_projects_forward_right_and_up(self):
        pose = [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]]
        k = [[100,0,320],[0,100,240],[0,0,1]]
        self.assertEqual(adapter.project([0,0,-2], pose, k), (320,240))
        self.assertEqual(adapter.project([1,1,-2], pose, k), (370,190))
        self.assertIsNone(adapter.project([0,0,2], pose, k))

    def test_translated_rotated_camera_uses_same_world_point(self):
        # Camera centre (3,2,1), camera looks world -X; native up stays +Y.
        pose = [[0,0,1,3],[0,1,0,2],[-1,0,0,1],[0,0,0,1]]
        self.assertEqual(adapter.project([1,2,1], pose, [[100,0,40],[0,100,30],[0,0,1]]), (40,30))
        rotation, translation = adapter.world_to_cv(pose)
        for row in range(3):
            self.assertAlmostEqual(sum(rotation[row][col]*pose[col][3] for col in range(3)) + translation[row], 0)

    def test_quaternion_reconstructs_all_half_turns_and_general_rotation(self):
        for angle in (0, 0.3, math.pi/2, math.pi):
            for axis in range(3):
                q = [math.cos(angle/2), 0, 0, 0]
                q[axis+1] = math.sin(angle/2)
                w,x,y,z = q
                r = [[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)],
                     [2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],
                     [2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]]
                actual = adapter.rotation_quaternion(r)
                self.assertAlmostEqual(abs(sum(a*b for a,b in zip(q, actual))), 1)

    def test_real_jpeg_and_binary_layout_round_trip(self):
        capture = adapter.load_capture(self.root)
        self.assertEqual(len(capture["seeds"]), 100)
        self.assertEqual(capture["seeds"][0]["source_id"], str(2**63))
        output = Path(self.temp.name) / "prepared"
        report = adapter.write_dataset(capture, output)
        self.assertFalse(report["gpu_training_performed"])
        self.assertEqual((output / "images/000001.jpg").read_bytes(), (self.root / "images/000001.jpg").read_bytes())
        with (output / "sparse/0/cameras.bin").open("rb") as f:
            self.assertEqual(struct.unpack("<Q", f.read(8))[0], 20)
            self.assertEqual(struct.unpack("<IiQQ4d", f.read(56)), (1,1,80,60,60,60,40,30))
            f.read(19*56)
            self.assertEqual(f.read(), b"")

    def test_quadrant_colors_prove_image_axes(self):
        # Native camera +Y is the TOP of the sensor JPEG, +X is RIGHT.
        expected = {0:(230,20,20), 1:(20,230,20), 2:(20,20,230), 3:(230,230,20)}
        points = [[-0.6,0.6,-2],[0.6,0.6,-2],[-0.6,-0.6,-2],[0.6,-0.6,-2]]
        for i in range(1,21):
            image = Image.new("RGB", (80,60))
            for quadrant, color in expected.items():
                x, y = (quadrant%2)*40, (quadrant//2)*30
                image.paste(color, (x,y,x+40,y+30))
            exif = Image.Exif()
            exif[274] = 1
            image.save(self.root / "images" / f"{i:06d}.jpg", quality=100, subsampling=0, exif=exif)
            self.alter_frame(lambda d: d.update(raw_feature_points=[{"id":str(j),"position":p} for j,p in enumerate(points)]), i)
        path = self.root / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest["feature_point_observations"] = 80
        path.write_text(json.dumps(manifest))
        capture = adapter.load_capture(self.root, min_points=4)
        for seed in capture["seeds"]:
            self.assertTrue(all(abs(a-b)<3 for a,b in zip(seed["rgb"], expected[int(seed["source_id"])])))

    def test_binary_asymmetric_pose_projects_independent_local_point(self):
        capture = adapter.load_capture(self.root)
        yaw, roll = 0.4, -0.3
        cy,sy,cz,sz = math.cos(yaw),math.sin(yaw),math.cos(roll),math.sin(roll)
        rotation = [[cz*cy,-sz,cz*sy],[sz*cy,cz,sz*sy],[-sy,0,cy]]
        center = [1.2,-0.7,2.3]
        pose = [[*rotation[i],center[i]] for i in range(3)] + [[0,0,0,1]]
        capture["frames"][0]["pose"] = pose
        output = Path(self.temp.name) / "asymmetric"
        adapter.write_dataset(capture, output)
        with (output / "sparse/0/images.bin").open("rb") as stream:
            stream.read(8)
            row = struct.unpack("<I4d3dI", stream.read(64))
        w,x,y,z = row[1:5]
        decoded = [[1-2*(y*y+z*z),2*(x*y-z*w),2*(x*z+y*w)],
                   [2*(x*y+z*w),1-2*(x*x+z*z),2*(y*z-x*w)],
                   [2*(x*z-y*w),2*(y*z+x*w),1-2*(x*x+y*y)]]
        # Construct in ARKit camera space and transform by the INPUT pose.
        local = [0.2,0.4,-2]
        world = [sum(rotation[i][j]*local[j] for j in range(3))+center[i] for i in range(3)]
        cv = [sum(decoded[i][j]*world[j] for j in range(3))+row[5+i] for i in range(3)]
        for actual, expected in zip(cv, [0.2,-0.4,2]):
            self.assertAlmostEqual(actual, expected)
        self.assertAlmostEqual(60*cv[0]/cv[2]+40, 46)
        self.assertAlmostEqual(60*cv[1]/cv[2]+30, 18)

    def test_binary_images_and_points_layout(self):
        output = Path(self.temp.name) / "binary-layout"
        adapter.write_dataset(adapter.load_capture(self.root), output)
        with (output / "sparse/0/images.bin").open("rb") as f:
            self.assertEqual(struct.unpack("<Q", f.read(8))[0], 20)
            for i in range(20):
                entry = struct.unpack("<I4d3dI", f.read(64))
                self.assertEqual(entry[:5], (i+1, 0, 1, 0, 0))
                self.assertAlmostEqual(entry[5], -i*0.02)
                self.assertEqual(entry[6:], (0,0,i+1))
                self.assertEqual(f.read(11), f"{i+1:06d}.jpg".encode()+b"\x00")
                self.assertEqual(struct.unpack("<Q", f.read(8))[0], 0)
            self.assertEqual(f.read(), b"")
        with (output / "sparse/0/points3D.bin").open("rb") as f:
            self.assertEqual(struct.unpack("<Q", f.read(8))[0], 100)
            first = struct.unpack("<Q3d3BdQ", f.read(51))
            self.assertEqual(first[:4], (1,-0.4,-0.4,-2))
            self.assertEqual(first[-2:], (0,0))
            self.assertTrue(all(abs(a-b) <= 3 for a,b in zip(first[4:7], (180,70,30))))
            f.read(99*51)
            self.assertEqual(f.read(), b"")

    def test_negative_metadata_cases_fail(self):
        original = (self.root / "frames/000001.json").read_text()
        mutations = {
            "mixed epoch": lambda d: d.update(session_id="bbbbbbbb-1111-2222-3333-bbbbbbbbbbbb"),
            "tracking": lambda d: d.update(tracking_state={"state":"limited", "reason":"initializing"}),
            "negative timestamp": lambda d: d.update(timestamp=-1),
            "boolean timestamp": lambda d: d.update(timestamp=True),
            "nonfinite": lambda d: d["camera_to_world"][0].__setitem__(3, float("nan")),
            "transposed": lambda d: d["camera_to_world"][3].__setitem__(0, 1),
            "reflected": lambda d: d["camera_to_world"][0].__setitem__(0,-1),
            "nonrigid": lambda d: d["camera_to_world"][0].__setitem__(0,2),
            "intrinsics transposed": lambda d: d["intrinsics"][2].__setitem__(0,40),
            "zero focal": lambda d: d["intrinsics"][0].__setitem__(0,0),
            "jpeg mismatch": lambda d: d["image_resolution"].__setitem__("width",81),
            "path traversal": lambda d: d.update(image="../escape.jpg"),
            "missing JPEG": lambda d: d.update(image="images/missing.jpg"),
            "missing points": lambda d: d.pop("raw_feature_points"),
            "numeric UInt64": lambda d: d["raw_feature_points"][0].update(id=2**63),
            "duplicate id": lambda d: d["raw_feature_points"].append(d["raw_feature_points"][0]),
            "invalid point": lambda d: d["raw_feature_points"][0].update(position=[0,0,float("inf")]),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name):
                (self.root / "frames/000001.json").write_text(original)
                self.alter_frame(mutate)
                with self.assertRaises(adapter.CaptureError):
                    adapter.load_capture(self.root)

    def test_empty_seed_cloud_and_pure_rotation_fail(self):
        for i in range(1,21):
            self.alter_frame(lambda d: d.update(raw_feature_points=[]), i)
        path = self.root / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest["feature_point_observations"] = 0
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(adapter.CaptureError, "poses alone"):
            adapter.load_capture(self.root)

    def test_pure_rotation_fails_even_with_points(self):
        for i in range(1,21):
            self.alter_frame(lambda d: d["camera_to_world"][0].__setitem__(3,0), i)
        with self.assertRaisesRegex(adapter.CaptureError, "translation radius"):
            adapter.load_capture(self.root)

    def test_duplicate_timestamp_and_images_fail(self):
        self.alter_frame(lambda d: d.update(timestamp=10), 2)
        with self.assertRaisesRegex(adapter.CaptureError, "timestamps"):
            adapter.load_capture(self.root)
        self.alter_frame(lambda d: d.update(timestamp=11, image="images/000001.jpg"), 2)
        with self.assertRaisesRegex(adapter.CaptureError, "duplicate JPEG"):
            adapter.load_capture(self.root)

    def test_exif_rotation_and_truncated_jpeg_fail(self):
        path = self.root / "images/000001.jpg"
        image = Image.new("RGB", (80,60))
        exif = Image.Exif()
        exif[274] = 6
        image.save(path, exif=exif)
        with self.assertRaisesRegex(adapter.CaptureError, "EXIF"):
            adapter.load_capture(self.root)
        path.write_bytes(path.read_bytes()[:200])
        with self.assertRaises(adapter.CaptureError):
            adapter.load_capture(self.root)

    def test_noncomplete_manifest_and_duplicate_json_fail(self):
        path = self.root / "manifest.json"
        data = json.loads(path.read_text())
        for status in ("recording", "interrupted", "failed", "limit_reached"):
            data["status"] = status
            path.write_text(json.dumps(data))
            with self.assertRaisesRegex(adapter.CaptureError, "status"):
                adapter.load_capture(self.root)
        path.write_text('{"schema_version":1,"schema_version":1}')
        with self.assertRaisesRegex(adapter.CaptureError, "duplicate JSON"):
            adapter.load_capture(self.root)

    def test_manifest_units_alignment_and_observation_count_fail(self):
        path = self.root / "manifest.json"
        original = json.loads(path.read_text())
        for key, value in (("units", "feet"), ("world_alignment", "camera"),
                           ("feature_point_observations", 1), ("feature_point_observations", True)):
            with self.subTest(key=key, value=value):
                path.write_text(json.dumps({**original, key:value}))
                with self.assertRaises(adapter.CaptureError):
                    adapter.load_capture(self.root)

    def test_missing_exif_and_excess_points_fail(self):
        path = self.root / "images/000001.jpg"
        original = path.read_bytes()
        Image.new("RGB", (80,60)).save(path)
        with self.assertRaisesRegex(adapter.CaptureError, "EXIF"):
            adapter.load_capture(self.root)
        path.write_bytes(original)
        self.alter_frame(lambda d: d.update(raw_feature_points=[{}]*50001))
        with self.assertRaisesRegex(adapter.CaptureError, "50,000"):
            adapter.load_capture(self.root)

    def test_existing_output_and_changed_input_fail(self):
        capture = adapter.load_capture(self.root)
        with self.assertRaisesRegex(adapter.CaptureError, "already exists"):
            adapter.write_dataset(capture, self.root)
        path = self.root / "images/000001.jpg"
        path.write_bytes(path.read_bytes() + b"changed")
        output = Path(self.temp.name) / "partial"
        with self.assertRaisesRegex(adapter.CaptureError, "changed after"):
            adapter.write_dataset(capture, output)
        self.assertFalse((output / "adapter-report.json").exists())

    def test_unreadable_manifest_and_sidecar_raise_capture_error(self):
        # Callers (worker, handoff, CLI) rely on CaptureError, not raw OSError.
        with self.assertRaisesRegex(adapter.CaptureError, "cannot read"):
            adapter.load_capture(Path(self.temp.name) / "absent")
        capture = adapter.load_capture(self.root)
        (self.root / "frames/000001.json").unlink()
        with self.assertRaisesRegex(adapter.CaptureError, "missing/outside capture file"):
            adapter.load_capture(self.root)
        with self.assertRaisesRegex(adapter.CaptureError, "missing/outside capture file"):
            adapter.verify_source_metadata(capture)
        (self.root / "manifest.json").unlink()
        with self.assertRaisesRegex(adapter.CaptureError, "cannot read"):
            adapter.verify_source_metadata(capture)

    def test_symlink_escape_fails(self):
        outside = Path(self.temp.name) / "outside.jpg"
        outside.write_bytes((self.root / "images/000001.jpg").read_bytes())
        (self.root / "images/link.jpg").symlink_to(outside)
        self.alter_frame(lambda d: d.update(image="images/link.jpg"))
        with self.assertRaisesRegex(adapter.CaptureError, "outside"):
            adapter.load_capture(self.root)

    def test_cli_known_failure_exits_nonzero_and_creates_no_success_output(self):
        path = self.root / "manifest.json"
        data = json.loads(path.read_text())
        data["status"] = "interrupted"
        path.write_text(json.dumps(data))
        output = Path(self.temp.name) / "should-not-exist"
        result = subprocess.run([sys.executable, str(Path(adapter.__file__)), str(self.root), "--output", str(output)],
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAIL", result.stderr)
        self.assertFalse(output.exists())


class TrainingHoldoutTests(unittest.TestCase):
    """Every-eighth holdout, training-only seeds and staged publication."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="spatial-holdout-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / "capture"
        self.root.mkdir()
        self.per_frame = synthetic_capture(self.root)

    @staticmethod
    def read_points(output):
        with (output / "sparse/0/points3D.bin").open("rb") as stream:
            count = struct.unpack("<Q", stream.read(8))[0]
            rows = [struct.unpack("<Q3d3BdQ", stream.read(51)) for _ in range(count)]
            assert stream.read() == b""
        return [(row[1:4], row[4:7]) for row in rows]

    def oracle_points3d(self, root, manifest_frames):
        """Independent restatement of the frozen benchmark rule: latest visible
        estimate and same-frame pixel from frames whose sorted index % 8 != 0,
        one seed per micrometre cell in ascending-ID order."""
        seeds = {}
        for index, sidecar in enumerate(manifest_frames):
            if index % 8 == 0:
                continue
            frame = json.loads((root / sidecar).read_text())
            with Image.open(root / frame["image"]) as image:
                rgb = image.convert("RGB")
            for point in frame["raw_feature_points"]:
                uv = adapter.project(point["position"], frame["camera_to_world"], frame["intrinsics"])
                if uv is not None and 0 <= uv[0] < 80 and 0 <= uv[1] < 60:
                    seeds[point["id"]] = (point["position"], rgb.getpixel((int(uv[0]), int(uv[1]))))
        distinct = {}
        for identifier in sorted(seeds, key=int):
            distinct.setdefault(tuple(round(v, 6) for v in seeds[identifier][0]), seeds[identifier])
        body = struct.pack("<Q", len(distinct))
        for index, (position, rgb) in enumerate(distinct.values(), start=1):
            body += struct.pack("<Q3d3BdQ", index, *position, *rgb, 0.0, 0)
        return body

    def test_heldout_frames_never_seed_geometry_or_colour(self):
        capture = adapter.load_capture(self.root)
        output = self.base / "dataset"
        report = adapter.write_dataset(capture, output)
        points = self.read_points(output)
        heldout = [i for i in range(20) if i % 8 == 0]
        self.assertEqual(heldout, [0, 8, 16])
        heldout_positions = {tuple(round(v, 6) for v in p["position"])
                             for i in heldout for p in self.per_frame[i]}
        training_ids = {p["id"] for i in range(20) if i % 8 != 0 for p in self.per_frame[i]}
        heldout_only_ids = {p["id"] for i in heldout for p in self.per_frame[i]} - training_ids
        self.assertEqual(len(heldout_only_ids), 15)  # 5 unique IDs per held-out frame
        for position, rgb in points:
            cell = tuple(round(v, 6) for v in position)
            # Held-out estimates differ from every training estimate by their z drift.
            self.assertNotIn(cell, heldout_positions, "seed geometry came from a held-out frame")
            self.assertGreater(max(abs(a - b) for a, b in zip(rgb, HELDOUT_COLOR)), 100,
                               "seed colour was sampled from a held-out frame")
        # Latest training observation wins, never the later held-out one.
        late = [p for i in (15, 16) for p in self.per_frame[i] if p["id"] == LATE_HELDOUT_ID]
        self.assertEqual([round(p["position"][2], 6) for p in late], [-1.815, -1.816])
        z_values = {round(position[2], 6) for position, _ in points}
        self.assertIn(-1.815, z_values)
        self.assertNotIn(-1.816, z_values)
        # Shared IDs seen in every frame keep the estimate of the last training frame (19).
        self.assertIn(round(-2 - 0.0001 * 19, 6), z_values)
        self.assertNotIn(round(-2 - 0.0001 * 16, 6), z_values)
        expected_seeds = len(training_ids)  # all synthetic points project inside the raster
        self.assertEqual((len(points), capture["visible_point_ids"], report["initial_points"]),
                         (expected_seeds, expected_seeds, expected_seeds))
        self.assertEqual(report["seed_observations"], sum(len(self.per_frame[i]) for i in range(20) if i % 8 != 0))
        self.assertEqual(report["capture_point_observations"], sum(map(len, self.per_frame)))
        self.assertEqual(report["point_observations"], report["capture_point_observations"])
        self.assertTrue(report["seed_colors_from_training_only"])
        self.assertTrue(report["seed_geometry_from_training_observations_only"])

    def test_points3d_bytes_match_independent_training_only_oracle(self):
        for frames in (20, 27):
            with self.subTest(frames=frames):
                root = self.base / f"capture-{frames}"
                root.mkdir()
                synthetic_capture(root, frames=frames)
                output = self.base / f"dataset-{frames}"
                adapter.write_dataset(adapter.load_capture(root), output)
                manifest = json.loads((root / "manifest.json").read_text())
                self.assertEqual((output / "sparse/0/points3D.bin").read_bytes(),
                                 self.oracle_points3d(root, manifest["frames"]))

    def test_every_eighth_split_uses_sorted_output_names_and_is_reported(self):
        for frames in (20, 27):
            with self.subTest(frames=frames):
                root = self.base / f"capture-{frames}"
                root.mkdir()
                synthetic_capture(root, frames=frames)
                output = self.base / f"dataset-{frames}"
                report = adapter.write_dataset(adapter.load_capture(root), output)
                names = sorted(p.name for p in (output / "images").iterdir())
                self.assertEqual(len(names), frames)
                self.assertEqual(names, [f"{i:06d}.jpg" for i in range(1, frames + 1)])
                self.assertEqual(report["evaluation_images"], [n for i, n in enumerate(names) if i % 8 == 0])
                self.assertEqual(report["training_images"], [n for i, n in enumerate(names) if i % 8 != 0])
                self.assertEqual(report["seed_image_names"], report["training_images"])
                self.assertEqual(sorted(report["training_images"] + report["evaluation_images"]), names)
                self.assertEqual(len(report["evaluation_images"]), math.ceil(frames / 8))
                self.assertEqual(report["evaluation_images"][0], "000001.jpg")
                self.assertEqual(report["adapter_profile"], adapter.ADAPTER_PROFILE)
                self.assertEqual(adapter.EVALUATION_EVERY, 8)

    def test_min_frames_and_min_points_bounds(self):
        for min_frames in (19, 401, True, 20.0):
            with self.subTest(min_frames=min_frames):
                with self.assertRaisesRegex(adapter.CaptureError, "minimums"):
                    adapter.load_capture(self.root, min_frames=min_frames)
        for min_points in (3, 0, True):
            with self.subTest(min_points=min_points):
                with self.assertRaisesRegex(adapter.CaptureError, "minimums"):
                    adapter.load_capture(self.root, min_points=min_points)
        self.assertEqual(len(adapter.load_capture(self.root, min_frames=20)["frames"]), 20)
        with self.assertRaisesRegex(adapter.CaptureError, "requires 21–400 frames"):
            adapter.load_capture(self.root, min_frames=21)
        with self.assertRaisesRegex(adapter.CaptureError, "requires 400–400 frames"):
            adapter.load_capture(self.root, min_frames=400)
        # Training-only seed count is what the minimum applies to.
        with self.assertRaisesRegex(adapter.CaptureError, "training-only ARKit seeds; need 100000"):
            adapter.load_capture(self.root, min_points=100000)
        path = self.root / "manifest.json"
        manifest = json.loads(path.read_text())
        manifest["frames"] = manifest["frames"] + [f"frames/{i:06d}.json" for i in range(21, 402)]
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(adapter.CaptureError, "20–400 frames"):
            adapter.load_capture(self.root)

    def test_four_hundred_frame_capture_loads_with_maximum_minimum(self):
        root = self.base / "capture-400"
        root.mkdir()
        synthetic_capture(root, frames=400)
        capture = adapter.load_capture(root, min_frames=400)
        self.assertEqual(len(capture["frames"]), 400)
        self.assertEqual(len(capture["capture_metadata_sha256"]), 400)

    def test_metadata_changed_after_load_is_refused_without_output(self):
        capture = adapter.load_capture(self.root)
        adapter.verify_source_metadata(capture)
        sidecar = self.root / "frames/000002.json"
        original = sidecar.read_text()
        sidecar.write_text(original + " ")  # Same JSON value, different bytes.
        with self.assertRaisesRegex(adapter.CaptureError, "frame metadata changed"):
            adapter.verify_source_metadata(capture)
        output = self.base / "dataset"
        with self.assertRaisesRegex(adapter.CaptureError, "frame metadata changed"):
            adapter.write_dataset(capture, output)
        self.assertFalse(output.exists())
        self.assertEqual([p.name for p in self.base.iterdir() if "preparing" in p.name], [])
        sidecar.write_text(original)
        adapter.verify_source_metadata(capture)
        manifest = self.root / "manifest.json"
        manifest_text = manifest.read_text()
        manifest.write_text(manifest_text + "\n")
        with self.assertRaisesRegex(adapter.CaptureError, "manifest changed"):
            adapter.write_dataset(capture, output)
        self.assertFalse(output.exists())
        manifest.write_text(manifest_text)
        adapter.verify_source_metadata(capture)
        sidecar.unlink()
        with self.assertRaisesRegex(adapter.CaptureError, "missing/outside capture file"):
            adapter.verify_source_metadata(capture)

    def test_output_inside_capture_root_or_its_alias_is_refused(self):
        capture = adapter.load_capture(self.root)
        before = sorted(p.name for p in self.root.iterdir())
        alias = self.base / "alias"
        alias.symlink_to(self.root, target_is_directory=True)
        for output in (self.root / "dataset", self.root / "frames/dataset", alias / "dataset", alias / "x/y"):
            with self.subTest(output=str(output.relative_to(self.base))):
                with self.assertRaisesRegex(adapter.CaptureError, "outside the capture directory"):
                    adapter.write_dataset(capture, output)
                self.assertFalse(output.exists())
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), before)
        with self.assertRaisesRegex(adapter.CaptureError, "already exists"):
            adapter.write_dataset(capture, self.base)

    def test_staged_publication_leaves_no_staging_directory(self):
        capture = adapter.load_capture(self.root)
        output = self.base / "nested" / "dataset"
        report = adapter.write_dataset(capture, output)
        self.assertTrue((output / "adapter-report.json").is_file())
        self.assertEqual(json.loads((output / "adapter-report.json").read_text()), report)
        self.assertEqual(sorted(p.name for p in output.parent.iterdir()), ["dataset"])
        self.assertEqual(sorted(p.name for p in output.iterdir()), ["adapter-report.json", "images", "sparse"])

    def test_interrupted_staged_write_leaves_neither_staging_nor_output(self):
        capture = adapter.load_capture(self.root)
        output = self.base / "dataset"
        original = adapter._write_dataset
        seen = []
        def interrupted(capture, staged):
            seen.append(staged)
            staged.mkdir(parents=True)
            (staged / "partial.bin").write_bytes(b"synthetic only")
            raise KeyboardInterrupt("injected after partial staged write")
        with patch.object(adapter, "_write_dataset", interrupted):
            with self.assertRaises(KeyboardInterrupt):
                adapter.write_dataset(capture, output)
        self.assertEqual(len(seen), 1)
        self.assertTrue(seen[0].parent.name.startswith(".dataset-preparing-"))
        self.assertEqual(seen[0].parent.parent, output.parent.resolve())
        self.assertFalse(seen[0].parent.exists())
        self.assertFalse(output.exists())
        self.assertEqual([p.name for p in self.base.iterdir() if "preparing" in p.name], [])
        adapter._write_dataset = original


if __name__ == "__main__":
    unittest.main()
