#!/usr/bin/env python3
"""Read-only App Review gate for Rendprop's two one-time purchases.

This deliberately cannot create, reprice, upload, activate, or submit an IAP.
Run immediately before adding the consumables to the app-version submission.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from decimal import Decimal
import sys

import asc
import credit_pack_iap as pack


@dataclass(frozen=True)
class Product:
    sku: str
    price: Decimal
    name: str


PRODUCTS = (
    Product("com.rendprop.app.credits.100", Decimal("39.99"), "100 Rendprop Credits"),
    Product("com.rendprop.app.website.premium.property", Decimal("25.00"), "Luxury Property Website"),
)


def _attributes(resource):
    return (resource or {}).get("attributes") or {}


def inspect_product(client, app_id: str, expected: Product) -> list[str]:
    """Return concrete blockers, including the parent product and draft version.

    Apple's current API places localizations on an IAP version but review
    screenshots on the parent IAP. Checking only the version misses the most
    common source of MISSING_METADATA for these two products.
    """
    blockers: list[str] = []
    rows = client.get_all(
        f"/v1/apps/{app_id}/inAppPurchasesV2",
        params={"filter[productId]": expected.sku, "limit": 200},
    )
    matches = [row for row in rows if _attributes(row).get("productId") == expected.sku]
    if len(matches) != 1:
        return [f"expected one exact product, found {len(matches)}"]
    product = matches[0]
    product_id = product.get("id")
    if not product_id or product.get("type") != "inAppPurchases":
        return ["malformed product resource"]
    attrs = _attributes(product)
    if attrs.get("inAppPurchaseType") != "CONSUMABLE":
        blockers.append("product is not CONSUMABLE")
    if attrs.get("state") != "READY_TO_SUBMIT":
        blockers.append(f"Apple product state is {attrs.get('state') or 'missing'}")
    if not (attrs.get("reviewNote") or "").strip():
        blockers.append("review note is missing")

    availability = pack.read_availability(client, product_id)
    if availability != (False, ["USA"]):
        blockers.append(f"availability is {availability!r}, expected USA only")
    price = pack.read_us_price(client, product_id)
    if price != expected.price:
        blockers.append(f"USA price is {price}, expected {expected.price}")

    versions, draft = pack.read_versions(client, product_id)
    if draft is None:
        blockers.append("editable IAP version is missing")
    else:
        localization = pack.read_localization(client, draft["id"])
        loc = _attributes(localization)
        if not localization:
            blockers.append("en-US localization is missing")
        else:
            if loc.get("name") != expected.name:
                blockers.append(f"en-US name is {loc.get('name')!r}, expected {expected.name!r}")
            description = (loc.get("description") or "").strip()
            if not description or len(description) > 45:
                blockers.append("en-US description is missing or exceeds 45 characters")
    if len(versions) != 1:
        blockers.append(f"expected one IAP version, found {len(versions)}")

    # The v2 relationship is current. v1 silently yields a 404 and would make a
    # valid screenshot appear absent.
    screenshot = client.get_optional(
        f"/v2/inAppPurchases/{product_id}/appStoreReviewScreenshot"
    )
    screenshot_data = (screenshot or {}).get("data")
    if not screenshot_data:
        blockers.append("App Review screenshot is missing")
    else:
        shot_attrs = _attributes(screenshot_data)
        state = (shot_attrs.get("assetDeliveryState") or {}).get("state")
        if state != "COMPLETE" or not shot_attrs.get("sourceFileChecksum"):
            blockers.append(f"App Review screenshot is {state or 'uncommitted'}")
    return blockers


def main(argv=None, client=None, out=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--require-ready", action="store_true",
                        help="Exit nonzero if either product is not ready for review")
    args = parser.parse_args(argv)
    out = out or sys.stdout
    client = client or asc.Client(asc.load_credentials(), verbose=False)
    app = asc.require_app(client)
    blocked = False
    for product in PRODUCTS:
        reasons = inspect_product(client, app["id"], product)
        out.write(f"{product.sku}: {'READY_TO_SUBMIT' if not reasons else 'BLOCKED'}\n")
        for reason in reasons:
            out.write(f"  - {reason}\n")
        blocked |= bool(reasons)
    return 1 if blocked and args.require_ready else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (asc.AscError, pack.CreditPackError) as exc:
        sys.stderr.write(f"IAP readiness: {exc}\n")
        sys.exit(2)
