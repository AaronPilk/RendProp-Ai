"""The media verification gate must fail when it performed no media work."""
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import test_hdr_tonemap as hdr
import test_resource_limits as limits


class VerificationPrerequisiteTests(unittest.TestCase):
    def test_missing_hdr_binaries_are_a_failure(self):
        with patch.object(hdr.shutil, "which", return_value=None):
            self.assertEqual(hdr.main(), 1)

    def test_missing_resource_binaries_are_failures(self):
        limits.FAILURES.clear()
        with patch.object(limits.shutil, "which", return_value=None):
            limits.test_pixel_limit_via_probe_source()
            limits.test_output_size_cap()
        self.assertEqual(len(limits.FAILURES), 2)

    def test_empty_signalstats_cannot_be_zero_equals_zero_success(self):
        with patch.object(hdr, "run", return_value=SimpleNamespace(returncode=0, stdout='{"frames":[]}', stderr='')):
            with self.assertRaisesRegex(RuntimeError, "no.*measurements"):
                hdr.stats("synthetic.mp4")

    def test_failed_signalstats_cannot_be_used(self):
        with patch.object(hdr, "run", return_value=SimpleNamespace(returncode=1, stdout='', stderr='fixture failure')):
            with self.assertRaisesRegex(RuntimeError, "ffprobe failed"):
                hdr.stats("synthetic.mp4")


if __name__ == "__main__":
    unittest.main(verbosity=2)
