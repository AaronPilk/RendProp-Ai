#!/usr/bin/env python3
"""Guarded App Review screenshot upload for Rendprop's two consumable IAPs.

``status`` and ``plan`` use Apple GETs only. ``apply`` requires an exact local
SHA-256 acknowledgement and never replaces an existing screenshot. It only
reserves, uploads, commits and reads back one image; it never submits a review.

Apple's flow: https://developer.apple.com/documentation/appstoreconnectapi/managing-in-app-purchases
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import hashlib
from pathlib import Path
import shutil
import sys
import tempfile
import zlib

import asc


PRODUCTS = frozenset({
    "com.rendprop.app.credits.100",
    "com.rendprop.app.website.premium.property",
})
RESOURCE = "inAppPurchaseAppStoreReviewScreenshots"
MAX_PNG_BYTES = 20 * 1024 * 1024


class ScreenshotError(Exception):
    """A local or Apple-state conflict that must not trigger another write."""


@dataclass(frozen=True)
class Image:
    path: Path
    size: int
    dimensions: tuple[int, int]
    sha256: str
    md5: str


def inspect_png(path: Path) -> Image:
    if path.is_symlink() or not path.is_file() or path.suffix.lower() != ".png":
        raise ScreenshotError("Supply a regular PNG captured from the final app purchase screen")
    size = path.stat().st_size
    if not 33 <= size <= MAX_PNG_BYTES:
        raise ScreenshotError("PNG is empty, truncated, or exceeds the 20 MiB safety limit")
    data = path.read_bytes()
    if len(data) != size or not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ScreenshotError("PNG bytes changed or have an invalid signature")
    at, saw_idat, saw_iend, dimensions = 8, False, False, None
    while at < len(data):
        if at + 12 > len(data):
            raise ScreenshotError("PNG has a truncated chunk")
        length = int.from_bytes(data[at:at + 4], "big")
        kind = data[at + 4:at + 8]
        end = at + 12 + length
        if end > len(data):
            raise ScreenshotError("PNG has a truncated chunk")
        checksum = int.from_bytes(data[end - 4:end], "big")
        if zlib.crc32(data[at + 4:end - 4]) != checksum:
            raise ScreenshotError("PNG has an invalid chunk checksum")
        if at == 8:
            if kind != b"IHDR" or length != 13:
                raise ScreenshotError("PNG has no valid IHDR")
            dimensions = (int.from_bytes(data[at + 8:at + 12], "big"),
                          int.from_bytes(data[at + 12:at + 16], "big"))
            if data[at + 17] in (4, 6):
                raise ScreenshotError("PNG has an alpha channel; use an opaque iPhone screenshot")
        if kind == b"tRNS":
            raise ScreenshotError("PNG has transparency; use an opaque iPhone screenshot")
        if kind == b"IDAT":
            saw_idat = True
        if kind == b"IEND":
            if length or end != len(data):
                raise ScreenshotError("PNG has data after IEND")
            saw_iend = True
            break
        at = end
    if not saw_idat or not saw_iend or dimensions not in asc.IAP_REVIEW_IPHONE_PORTRAIT_SIZES:
        raise ScreenshotError("PNG is incomplete or not a supported native iPhone portrait size")
    return Image(path=path, size=size, dimensions=dimensions,
                 sha256=hashlib.sha256(data).hexdigest(), md5=hashlib.md5(data).hexdigest())


def read_product(client, app_id: str, sku: str) -> tuple[str, str]:
    rows = client.get_all(f"/v1/apps/{app_id}/inAppPurchasesV2",
                          params={"filter[productId]": sku, "limit": 200})
    matches = [row for row in rows if (row.get("attributes") or {}).get("productId") == sku]
    if len(matches) != 1:
        raise ScreenshotError(f"Expected one exact {sku} product in this app; found {len(matches)}")
    row = matches[0]
    attrs = row.get("attributes") or {}
    if row.get("type") != "inAppPurchases" or not row.get("id") or attrs.get("inAppPurchaseType") != "CONSUMABLE":
        raise ScreenshotError("Apple returned a malformed or non-consumable product")
    return row["id"], attrs.get("state") or "unknown"


def read_screenshot(client, product_id: str):
    result = client.get_optional(f"/v2/inAppPurchases/{product_id}/appStoreReviewScreenshot")
    row = (result or {}).get("data")
    if row and (row.get("type") != RESOURCE or not row.get("id")):
        raise ScreenshotError("Apple returned a malformed IAP review screenshot")
    return row


def existing_state(row, image: Image | None) -> str:
    if not row:
        return "MISSING"
    attrs = row.get("attributes") or {}
    state = (attrs.get("assetDeliveryState") or {}).get("state") or "UNKNOWN"
    checksum = attrs.get("sourceFileChecksum")
    if image and (not isinstance(checksum, str) or checksum.lower() != image.md5):
        raise ScreenshotError(
            "A different or uncommitted review screenshot already exists. Inspect it in App Store Connect; this tool never replaces it."
        )
    return state


def reserve_body(product_id: str, image: Image):
    return {"data": {"type": RESOURCE,
                     "attributes": {"fileName": image.path.name, "fileSize": image.size},
                     "relationships": {"inAppPurchaseV2": asc.relationship("inAppPurchases", product_id)}}}


def verify_readback(client, product_id: str, screenshot_id: str, image: Image) -> str:
    detail = client.get(f"/v1/inAppPurchaseAppStoreReviewScreenshots/{screenshot_id}")
    row = detail.get("data") or {}
    attrs = row.get("attributes") or {}
    related = (((row.get("relationships") or {}).get("inAppPurchaseV2") or {}).get("data") or {}).get("id")
    if row.get("id") != screenshot_id or row.get("type") != RESOURCE or \
            not isinstance(attrs.get("sourceFileChecksum"), str) or \
            attrs["sourceFileChecksum"].lower() != image.md5 or \
            attrs.get("fileSize") != image.size or \
            (related is not None and related != product_id):
        raise ScreenshotError("Apple readback did not match the committed screenshot; inspect status before any retry")
    linked = read_screenshot(client, product_id)
    if not linked or linked["id"] != screenshot_id:
        raise ScreenshotError("Apple has not linked the committed screenshot to the exact IAP; inspect status before any retry")
    return existing_state(linked, image)


def run(client, action: str, sku: str, image_path: Path | None,
        confirm_sha256: str | None, out) -> int:
    if sku not in PRODUCTS:
        raise ScreenshotError("Only the exact 100-credit and luxury-site product IDs are allowed")
    if action in ("plan", "apply") and image_path is None:
        raise ScreenshotError("Plan and apply require --image with a final-build iPhone PNG")
    image = inspect_png(image_path) if image_path else None
    if action == "apply" and (not confirm_sha256 or confirm_sha256.lower() != image.sha256):
        raise ScreenshotError("Apply requires --confirm-sha256 matching this exact PNG; run plan first")
    app = asc.require_app(client)
    product_id, product_state = read_product(client, app["id"], sku)
    current = read_screenshot(client, product_id)
    state = existing_state(current, image)
    out.write(f"{sku}: product {product_state}; review screenshot {state}\n")
    if image:
        out.write(f"  PNG {image.dimensions[0]}x{image.dimensions[1]}, {image.size} bytes\n")
        out.write(f"  SHA-256 {image.sha256}\n  Apple MD5 {image.md5}\n")
    if action == "status":
        return 0
    if current:
        out.write("  Existing exact screenshot; no upload or replacement.\n")
        return 0 if state == "COMPLETE" else 3
    if product_state not in ("MISSING_METADATA", "READY_TO_SUBMIT"):
        raise ScreenshotError(f"Product state {product_state} is not an editable review draft")
    if action == "plan":
        out.write("  DRY RUN: reserve, PUT, commit and GET one screenshot; no review submission.\n")
        return 0

    # Stage the exact checked bytes in a private directory. The shared asset
    # helper reads a Path, so this prevents a user-visible source file from
    # changing between the acknowledgement and Apple's upload.
    with tempfile.TemporaryDirectory(prefix="rendprop-iap-review-") as folder:
        staged_path = Path(folder) / image.path.name
        shutil.copyfile(image.path, staged_path)
        staged = inspect_png(staged_path)
        if staged.sha256 != image.sha256 or staged.md5 != image.md5:
            raise ScreenshotError("PNG changed before upload; no Apple write was made")
        if read_screenshot(client, product_id):
            raise ScreenshotError("A screenshot appeared before reservation; no Apple write was made")
        screenshot_id = asc.upload_asset(client, reserve_body(product_id, staged),
                                         "/v1/inAppPurchaseAppStoreReviewScreenshots",
                                         "/v1/inAppPurchaseAppStoreReviewScreenshots/%s",
                                         staged_path, out)
        state = verify_readback(client, product_id, screenshot_id, staged)
    out.write(f"  Apple readback: {state}; screenshot {screenshot_id}.\n")
    return 0 if state == "COMPLETE" else 3


def main(argv=None, client=None, out=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("status", "plan", "apply"),
                        help="status/plan are read-only; plan is the dry run")
    parser.add_argument("--product", required=True, choices=sorted(PRODUCTS))
    parser.add_argument("--image", type=Path)
    parser.add_argument("--confirm-sha256", help="exact digest printed by plan; required for apply")
    args = parser.parse_args(argv)
    out = out or sys.stdout
    client = client or asc.Client(asc.load_credentials(), verbose=False)
    return run(client, args.action, args.product, args.image, args.confirm_sha256, out)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (asc.AscError, ScreenshotError, OSError) as exc:
        sys.stderr.write(f"IAP review screenshot: {exc}\n")
        sys.exit(2)
