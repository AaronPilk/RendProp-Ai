"""Execute actual worker storage admission; closed HTTP and S3 boundaries only."""
from __future__ import annotations

import io
import os
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import db
import r2

ORG = "11111111-1111-4111-8111-111111111111"
KEY = "renders/22222222-2222-4222-8222-222222222222/render.mp4"


class StorageAdmissionTests(unittest.TestCase):
    def setUp(self):
        self.settings = SimpleNamespace(r2_bucket_uploads="rendprop-uploads", r2_bucket_renders="rendprop-renders",
                                        supabase_service_role_key="sb_secret_synthetic", db_schema="public")
        self.enterContext(patch.object(db, "SETTINGS", self.settings))
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "render.mp4"
        self.path.write_bytes(b"original")

    def response(self, payload):
        return SimpleNamespace(ok=True, status_code=200, text="json", json=lambda: payload)

    def test_actual_rpc_uses_exact_custody_size_and_modern_header(self):
        with patch.object(db, "_request", return_value=self.response({"reserved": True})) as request:
            db.reserve_media_storage(ORG, "rendprop-renders", KEY, 8)
        args, kw = request.call_args
        self.assertEqual(args, ("POST", "rpc/media_storage_reserve"))
        self.assertEqual(kw["json"], {"p_org": ORG, "p_bucket": "renders", "p_key": KEY, "p_bytes": 8})
        self.assertEqual(kw["headers"]["apikey"], "sb_secret_synthetic")
        self.assertNotIn("Authorization", kw["headers"])

    def test_legacy_transport_remains_explicit(self):
        self.settings.supabase_service_role_key = "synthetic-legacy"
        self.assertEqual(db._headers()["Authorization"], "Bearer synthetic-legacy")

    def test_invalid_workspace_bucket_or_size_never_calls_rpc(self):
        cases = [("bad", "rendprop-renders", 8), (ORG, "foreign", 8),
                 (ORG, "rendprop-renders", 0), (ORG, "rendprop-renders", True),
                 (ORG, "rendprop-renders", 12 * 1024**3 + 1)]
        with patch.object(db, "_request") as request:
            for org, bucket, size in cases:
                with self.subTest(org=org, bucket=bucket, size=size), self.assertRaises(db.DBError):
                    db.reserve_media_storage(org, bucket, KEY, size)
            request.assert_not_called()

    def test_unconfirmed_admission_is_not_success(self):
        with patch.object(db, "_request") as request:
            for payload in [[], {}, {"reserved": "true"}, {"reserved": False}]:
                request.return_value = self.response(payload)
                with self.subTest(payload=payload), self.assertRaises(db.DBError):
                    db.reserve_media_storage(ORG, "rendprop-renders", KEY, 8)

    def test_upload_reserves_before_s3_and_confirms_length(self):
        order = []
        client = Mock()
        client.upload_fileobj.side_effect = lambda f, *a, **kw: order.append(("put", f.read()))
        client.head_object.side_effect = lambda **kw: order.append(("head", kw)) or {"ContentLength": 8}
        with patch.object(db, "reserve_media_storage", side_effect=lambda *a: order.append(("reserve", a))), patch.object(r2, "_client", return_value=client):
            self.assertEqual(r2.upload_file(str(self.path), "rendprop-renders", KEY, org_id=ORG), KEY)
        self.assertEqual(order[0], ("reserve", (ORG, "rendprop-renders", KEY, 8)))
        self.assertEqual(order[1], ("put", b"original"))
        self.assertEqual(order[2], ("head", {"Bucket": "rendprop-renders", "Key": KEY}))

    def test_unknown_or_denied_admission_cannot_dispatch_or_release(self):
        with patch.object(db, "reserve_media_storage", side_effect=db.DBError("unknown admission")), patch.object(r2, "_client") as client:
            with self.assertRaises(r2.R2Error):
                r2.upload_file(str(self.path), "rendprop-renders", KEY, org_id=ORG)
            client.assert_not_called()

    def test_growing_source_cannot_exceed_reserved_extent(self):
        def reserve(*args):
            with self.path.open("ab") as f:
                f.write(b"unreserved")
        client = Mock()
        def put(f, *args, **kwargs):
            self.assertEqual(f.seek(0, os.SEEK_END), 8)
            f.seek(0)
            self.assertEqual(f.read(), b"original")
            self.assertEqual(f.read(), b"")
        client.upload_fileobj.side_effect = put
        client.head_object.return_value = {"ContentLength": 8}
        with patch.object(db, "reserve_media_storage", side_effect=reserve), patch.object(r2, "_client", return_value=client):
            r2.upload_file(str(self.path), "rendprop-renders", KEY, org_id=ORG)

    def test_unconfirmed_object_size_stops_publication(self):
        for payload in [{}, {"ContentLength": 7}, {"ContentLength": 9}]:
            client = Mock(); client.head_object.return_value = payload
            with self.subTest(payload=payload), patch.object(db, "reserve_media_storage"), patch.object(r2, "_client", return_value=client):
                with self.assertRaises(r2.R2Error):
                    r2.upload_file(str(self.path), "rendprop-renders", KEY, org_id=ORG)
                client.delete_object.assert_not_called()

    def test_sdk_seek_and_chunked_read_bounds(self):
        f = r2._BoundedUpload(io.BytesIO(b"abcdefgh-extra"), 8)
        self.assertTrue(f.readable()); self.assertTrue(f.seekable())
        self.assertEqual(f.read(3), b"abc")
        self.assertEqual(f.seek(-2, os.SEEK_END), 6)
        self.assertEqual(f.read(100), b"gh")
        for offset, whence in [(9, os.SEEK_SET), (-1, os.SEEK_SET), (1, os.SEEK_END)]:
            with self.subTest(offset=offset, whence=whence), self.assertRaises(ValueError):
                f.seek(offset, whence)


if __name__ == "__main__":
    unittest.main()
