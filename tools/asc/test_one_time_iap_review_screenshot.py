#!/usr/bin/env python3
"""One-time IAP screenshot upload contract; never contacts Apple."""

import io
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest.mock import patch
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
import one_time_iap_review_screenshot as shots


def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))


def png(width=640, height=960, color_type=2):
    channels = 4 if color_type == 6 else 3
    row = b"\0" + b"\x45" * (width * channels)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, color_type, 0, 0, 0)) + \
        chunk(b"IDAT", zlib.compress(row * height)) + chunk(b"IEND", b"")


class FakeClient:
    def __init__(self):
        self.calls = []
        self.sku = "com.rendprop.app.credits.100"
        self.product_state = "MISSING_METADATA"
        self.current = None
        self.uploaded = None
        self.delivery_state = "COMPLETE"

    def get_all(self, path, params=None):
        self.calls.append(("GET_ALL", path))
        assert path == "/v1/apps/app/inAppPurchasesV2"
        return [{"type": "inAppPurchases", "id": "iap-1", "attributes": {
            "productId": self.sku, "inAppPurchaseType": "CONSUMABLE", "state": self.product_state,
        }}]

    def get_optional(self, path):
        self.calls.append(("GET_OPTIONAL", path))
        assert path == "/v2/inAppPurchases/iap-1/appStoreReviewScreenshot"
        return {"data": self.current} if self.current else None

    def post(self, path, body):
        self.calls.append(("POST", path))
        assert path == "/v1/inAppPurchaseAppStoreReviewScreenshots"
        assert body["data"]["type"] == shots.RESOURCE
        assert body["data"]["relationships"]["inAppPurchaseV2"] == \
            {"data": {"type": "inAppPurchases", "id": "iap-1"}}
        self.uploaded = {"size": body["data"]["attributes"]["fileSize"],
                         "name": body["data"]["attributes"]["fileName"]}
        return {"data": {"type": shots.RESOURCE, "id": "shot-1", "attributes": {
            "uploadOperations": [{"url": "https://upload.apple.test/part", "method": "PUT",
                                  "offset": 0, "length": self.uploaded["size"],
                                  "requestHeaders": [{"name": "Content-Type", "value": "image/png"}]}],
        }}}

    def transport(self, method, url, headers, data):
        self.calls.append((method, url))
        assert url == "https://upload.apple.test/part"
        assert headers == {"Content-Type": "image/png"}
        assert len(data) == self.uploaded["size"]
        self.uploaded["bytes"] = data
        return 200, {}, b""

    def patch(self, path, body):
        self.calls.append(("PATCH", path))
        assert path == "/v1/inAppPurchaseAppStoreReviewScreenshots/shot-1"
        assert body["data"]["attributes"]["uploaded"] is True
        self.current = {"type": shots.RESOURCE, "id": "shot-1", "attributes": {
            "fileName": self.uploaded["name"], "fileSize": self.uploaded["size"],
            "sourceFileChecksum": body["data"]["attributes"]["sourceFileChecksum"],
            "assetDeliveryState": {"state": self.delivery_state},
        }, "relationships": {"inAppPurchaseV2": {"data": {"type": "inAppPurchases", "id": "iap-1"}}}}
        return {"data": self.current}

    def get(self, path):
        self.calls.append(("GET", path))
        assert path == "/v1/inAppPurchaseAppStoreReviewScreenshots/shot-1"
        return {"data": self.current}


class ScreenshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.image = Path(self.temp.name) / "real-purchase.png"
        self.image.write_bytes(png())
        self.client = FakeClient()
        self.out = io.StringIO()
        self.app = patch.object(shots.asc, "require_app", return_value={"id": "app"})
        self.app.start()
        self.addCleanup(self.app.stop)

    def run_action(self, action, image=True, digest=None, sku=None):
        return shots.run(self.client, action, sku or self.client.sku,
                         self.image if image else None, digest, self.out)

    def test_plan_and_status_are_read_only_and_show_exact_digest(self):
        self.assertEqual(self.run_action("status", image=False), 0)
        self.assertEqual(self.run_action("plan"), 0)
        self.assertIn("DRY RUN", self.out.getvalue())
        self.assertIn(shots.inspect_png(self.image).sha256, self.out.getvalue())
        self.assertFalse(any(call[0] in ("POST", "PUT", "PATCH") for call in self.client.calls))

    def test_apply_reserve_put_commit_get_and_exact_parent_readback(self):
        digest = shots.inspect_png(self.image).sha256
        self.assertEqual(self.run_action("apply", digest=digest), 0)
        self.assertEqual([c[0] for c in self.client.calls],
                         ["GET_ALL", "GET_OPTIONAL", "GET_OPTIONAL", "POST", "PUT", "PATCH", "GET", "GET_OPTIONAL"])
        self.assertEqual(self.client.uploaded["bytes"], self.image.read_bytes())
        self.assertEqual(self.client.current["attributes"]["sourceFileChecksum"], shots.inspect_png(self.image).md5)
        prior = len(self.client.calls)
        self.assertEqual(self.run_action("apply", digest=digest), 0)
        self.assertFalse(any(call[0] in ("POST", "PUT", "PATCH") for call in self.client.calls[prior:]))

    def test_wrong_digest_and_different_existing_image_stop_before_write(self):
        with self.assertRaisesRegex(shots.ScreenshotError, "confirm-sha256"):
            self.run_action("apply", digest="0" * 64)
        self.assertEqual(self.client.calls, [])
        self.client.current = {"type": shots.RESOURCE, "id": "old", "attributes": {
            "sourceFileChecksum": "other", "assetDeliveryState": {"state": "COMPLETE"}}}
        with self.assertRaisesRegex(shots.ScreenshotError, "different or uncommitted"):
            self.run_action("apply", digest=shots.inspect_png(self.image).sha256)
        self.assertFalse(any(call[0] in ("POST", "PUT", "PATCH") for call in self.client.calls))

    def test_processing_readback_never_reuploads(self):
        self.client.delivery_state = "UPLOAD_COMPLETE"
        digest = shots.inspect_png(self.image).sha256
        self.assertEqual(self.run_action("apply", digest=digest), 3)
        prior = len(self.client.calls)
        self.assertEqual(self.run_action("apply", digest=digest), 3)
        self.assertFalse(any(call[0] in ("POST", "PUT", "PATCH") for call in self.client.calls[prior:]))

    def test_bad_product_or_apple_product_conflict_stops(self):
        with self.assertRaisesRegex(shots.ScreenshotError, "Only the exact"):
            self.run_action("plan", sku="com.rendprop.app.other")
        self.client.sku = "com.rendprop.app.website.premium.property"
        with self.assertRaisesRegex(shots.ScreenshotError, "Expected one exact"):
            shots.run(self.client, "plan", "com.rendprop.app.credits.100", self.image, None, self.out)
        self.assertFalse(any(call[0] in ("POST", "PUT", "PATCH") for call in self.client.calls))

    def test_luxury_site_exact_product_uses_the_same_dry_run_guard(self):
        self.client.sku = "com.rendprop.app.website.premium.property"
        self.assertEqual(self.run_action("plan"), 0)
        self.assertIn(self.client.sku, self.out.getvalue())
        self.assertFalse(any(call[0] in ("POST", "PUT", "PATCH") for call in self.client.calls))

    def test_rejects_wrong_size_transparency_and_corrupted_png(self):
        for data in (png(800, 900), png(color_type=6), png()[:-1] + b"x"):
            self.image.write_bytes(data)
            with self.assertRaises(shots.ScreenshotError):
                self.run_action("plan")
        self.assertEqual(self.client.calls, [])


if __name__ == "__main__":
    unittest.main()
