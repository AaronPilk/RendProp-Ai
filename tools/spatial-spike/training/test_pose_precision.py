"""Synthetic Float32 pose regressions against the real offline adapter.

The former Swift exact-row comparison explains the failure context only. These
tests do not execute Swift or establish the residuals of a physical ARKit frame.
No matrix is repaired to make it valid; validation must preserve raw values.
"""
import copy
import json
import math
import struct
import unittest

from prepare_capture import CaptureError, validate_pose, world_to_cv


def float32(value):
    """Round once to Float32, then widen its exact value to Python's float."""
    return struct.unpack("<f", struct.pack("<f", value))[0]


def float32_bits(bits):
    return struct.unpack("<f", struct.pack("<I", bits))[0]


def camera_pose(bottom_row=None):
    # Non-identity rotation and nonzero translation expose accidental transpose.
    return [[0.0, 0.0, 1.0, 1.25],
            [0.0, 1.0, 0.0, -2.5],
            [-1.0, 0.0, 0.0, 3.75],
            [0.0, 0.0, 0.0, 1.0] if bottom_row is None else list(bottom_row)]


def matrix_bytes(matrix):
    # Unlike numerical equality, this also detects rewriting signed zero.
    return struct.pack("<16d", *(value for row in matrix for value in row))


class PosePrecisionTests(unittest.TestCase):
    def test_float32_widening_and_json_preserve_raw_values(self):
        values = [0.0, -0.0, 1.0, float32_bits(0x3F800001),
                  float32_bits(0x3F7FFFFF), float32(1e-8), float32(60.12345)]
        for value in values:
            with self.subTest(value=value):
                widened = float(value)
                decoded = json.loads(json.dumps(widened, allow_nan=False))
                self.assertEqual(struct.pack("<f", widened), struct.pack("<f", value))
                self.assertEqual(struct.pack("<d", decoded), struct.pack("<d", widened))
        self.assertEqual(float32(0.0), 0.0)
        self.assertEqual(float32(1.0), 1.0)

    def test_float32_homogeneous_neighbors_pass_without_repair(self):
        rows = [[0.0, 0.0, 0.0, float32_bits(0x3F800001)],
                [0.0, 0.0, 0.0, float32_bits(0x3F7FFFFF)],
                [float32(1e-8), -float32(1e-8), float32(2e-8), float32_bits(0x3F800001)]]
        for row in rows:
            with self.subTest(row=row):
                # Before-proof context: Swift's former exact comparison rejects
                # these same values. It is not the adapter acceptance oracle.
                self.assertNotEqual(row, [0, 0, 0, 1])
                raw = camera_pose(row)
                before = matrix_bytes(raw)
                validated = validate_pose(raw)
                self.assertEqual(matrix_bytes(raw), before)
                self.assertEqual(matrix_bytes(validated), before)
                # The adapter interprets the validated upper 3x4 as affine;
                # it must not divide the raw rotation/translation by bottom w.
                rotation, translation = world_to_cv(validated)
                self.assertEqual(rotation, [[0, 0, -1], [0, -1, 0], [-1, 0, 0]])
                self.assertEqual(translation, [3.75, -2.5, 1.25])
                self.assertEqual(matrix_bytes(validated), before)

    def test_signed_zero_pose_is_accepted_and_preserved(self):
        raw = camera_pose([-0.0, 0.0, -0.0, 1.0])
        before = matrix_bytes(raw)
        self.assertEqual(matrix_bytes(validate_pose(raw)), before)
        self.assertEqual(matrix_bytes(raw), before)

    def test_homogeneous_zero_components_use_strict_absolute_boundary(self):
        # The literal boundary is exercised at zero, where subtraction does
        # not round the intended residual as it can for the component near one.
        cases = [(math.nextafter(1e-6, 0.0), True), (1e-6, False),
                 (math.nextafter(1e-6, math.inf), False),
                 (math.nextafter(-1e-6, 0.0), True), (-1e-6, False),
                 (math.nextafter(-1e-6, -math.inf), False)]
        for column in range(3):
            for value, accepted in cases:
                with self.subTest(column=column, value=value):
                    raw = camera_pose()
                    raw[3][column] = value
                    if accepted:
                        self.assertEqual(matrix_bytes(validate_pose(raw)), matrix_bytes(raw))
                    else:
                        with self.assertRaisesRegex(CaptureError, "homogeneous row"):
                            validate_pose(raw)

    def test_homogeneous_one_component_float32_boundary(self):
        # Float32 spacing below one is half the spacing above it. Eight ULPs
        # above / sixteen below remain inside 1e-6; the next values do not.
        for bits, accepted in [(0x3F800008, True), (0x3F800009, False),
                               (0x3F7FFFF0, True), (0x3F7FFFEF, False)]:
            with self.subTest(bits=hex(bits)):
                raw = camera_pose([0.0, 0.0, 0.0, float32_bits(bits)])
                if accepted:
                    self.assertEqual(matrix_bytes(validate_pose(raw)), matrix_bytes(raw))
                else:
                    with self.assertRaisesRegex(CaptureError, "homogeneous row"):
                        validate_pose(raw)

    def test_projective_rows_fail_instead_of_being_canonicalized(self):
        for row in [[1e-4, 0, 0, 1], [0, -1e-4, 0, 1], [0, 0, 1e-4, 1],
                    [0, 0, 0, 0.99], [0, 0, 0, 1.01], [0, 0, 0, 0],
                    [0, 0, 0, -1], [0, 0, 0, 2]]:
            with self.subTest(row=row):
                raw = camera_pose(row)
                before = matrix_bytes(raw)
                with self.assertRaisesRegex(CaptureError, "homogeneous row"):
                    validate_pose(raw)
                self.assertEqual(matrix_bytes(raw), before)

    def test_translated_transpose_reflection_scale_and_shear_fail(self):
        base = camera_pose()
        reflected = copy.deepcopy(base)
        for row in range(3):
            reflected[row][0] *= -1
        scaled_rotation = copy.deepcopy(base)
        for row in range(3):
            scaled_rotation[row][0] *= 1.002
        shear = copy.deepcopy(base)
        shear[0][1] = 0.1
        candidates = {"translated transpose": [list(row) for row in zip(*base)],
                      "reflection": reflected, "rotation scale": scaled_rotation,
                      "uniform projective scale": [[2 * value for value in row] for row in base],
                      "shear": shear}
        for label, raw in candidates.items():
            with self.subTest(label=label), self.assertRaises(CaptureError):
                validate_pose(raw)

    def test_nonfinite_nonnumeric_and_malformed_matrices_fail(self):
        # Check every matrix position, including translation, before tolerance
        # arithmetic could turn NaN comparisons into accidental acceptance.
        for row in range(4):
            for column in range(4):
                for value in (float("nan"), float("inf"), -float("inf"), True, "0", None):
                    with self.subTest(row=row, column=column, value=value):
                        raw = camera_pose()
                        raw[row][column] = value
                        with self.assertRaises(CaptureError):
                            validate_pose(raw)
        for raw in (None, [], camera_pose()[:3], [[0] * 3 for _ in range(4)],
                    [*camera_pose(), [0, 0, 0, 1]]):
            with self.subTest(shape=raw), self.assertRaises(CaptureError):
                validate_pose(raw)

    def test_pure_rotation_transpose_at_origin_is_indistinguishable(self):
        # A transposed rotation at the origin is another valid rigid pose.
        # Structural checks cannot promise to detect this semantic error;
        # serializer/interoperability tests must establish row/column meaning.
        raw = camera_pose()
        for row in range(3):
            raw[row][3] = 0.0
        transposed = [list(row) for row in zip(*raw)]
        self.assertNotEqual(transposed, raw)
        self.assertEqual(validate_pose(transposed), transposed)


if __name__ == "__main__":
    unittest.main()
