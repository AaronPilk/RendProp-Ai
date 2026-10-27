#!/usr/bin/env python3
"""Reconcile Rendprop's one 100-credit consumable in App Store Connect.

This command deliberately does not submit a review, upload a screenshot, or
change an existing price/availability. ``status`` and ``plan`` only read Apple;
``apply`` requires the exact product ID as a second explicit argument.

Request shapes follow Apple's App Store Connect OpenAPI 4.5.1 (6 Oct 2026):
https://developer.apple.com/sample-code/app-store-connect/app-store-connect-openapi-specification.zip
"""

import argparse
from decimal import Decimal, InvalidOperation
import sys

import asc


PRODUCT_ID = "com.rendprop.app.credits.100"
INTERNAL_NAME = "100 Rendprop Credits"
DISPLAY_NAME = "100 Rendprop Credits"
DESCRIPTION = "100 nonexpiring credits for one workspace."
REVIEW_NOTE = (
    "Consumable 100-credit top-up for AI photo and media work in the current "
    "Rendprop workspace. Credits are granted only after server verification of "
    "the Apple transaction and do not expire."
)
LOCALE = "en-US"
BASE_TERRITORY = "USA"
CUSTOMER_PRICE = Decimal("29.99")
_DRAFT = "PREPARE_FOR_SUBMISSION"


class CreditPackError(Exception):
    """A conflict or missing prerequisite that must be resolved explicitly."""


def relationship(kind, identifier):
    return {"data": {"type": kind, "id": identifier}}


def attributes(row):
    return (row or {}).get("attributes") or {}


def related_id(row, name):
    return ((((row or {}).get("relationships") or {}).get(name) or {})
            .get("data") or {}).get("id")


def _amount(value):
    try:
        return Decimal(str(value))
    except (TypeError, ValueError, InvalidOperation):
        raise CreditPackError("Apple returned a price without a valid amount")


def find_product(client, app_id):
    """Use Apple's server filter, then enforce exact ID and unique app ownership."""
    rows = client.get_all(
        "/v1/apps/%s/inAppPurchasesV2" % app_id,
        params={"filter[productId]": PRODUCT_ID, "limit": 200},
    )
    matches = [r for r in rows if attributes(r).get("productId") == PRODUCT_ID]
    if len(matches) > 1:
        raise CreditPackError("Multiple Apple products have %s" % PRODUCT_ID)
    if not matches:
        return None
    row = matches[0]
    if row.get("type") != "inAppPurchases" or not row.get("id"):
        raise CreditPackError("Apple returned a malformed in-app purchase")
    if attributes(row).get("inAppPurchaseType") != "CONSUMABLE":
        raise CreditPackError("%s exists but is not CONSUMABLE" % PRODUCT_ID)
    return row


def product_create_body(app_id):
    return {"data": {
        "type": "inAppPurchases",
        "attributes": {
            "name": INTERNAL_NAME,
            "productId": PRODUCT_ID,
            "inAppPurchaseType": "CONSUMABLE",
            "reviewNote": REVIEW_NOTE,
        },
        "relationships": {"app": relationship("apps", app_id)},
    }}


def read_availability(client, product_id):
    response = client.get_optional(
        "/v2/inAppPurchases/%s/inAppPurchaseAvailability" % product_id)
    if not response:
        return None
    row = response.get("data")
    if not row or row.get("type") != "inAppPurchaseAvailabilities" or not row.get("id"):
        raise CreditPackError("Malformed in-app purchase availability")
    territories = client.get_all(
        "/v1/inAppPurchaseAvailabilities/%s/availableTerritories" % row["id"],
        params={"limit": 200},
    )
    return (bool(attributes(row).get("availableInNewTerritories")),
            sorted(t["id"] for t in territories if t.get("id")))


def availability_create_body(product_id):
    return {"data": {
        "type": "inAppPurchaseAvailabilities",
        "attributes": {"availableInNewTerritories": False},
        "relationships": {
            "inAppPurchase": relationship("inAppPurchases", product_id),
            "availableTerritories": {"data": [
                {"type": "territories", "id": BASE_TERRITORY},
            ]},
        },
    }}


def read_us_price(client, product_id):
    """None if unpriced; otherwise verify the entire USA manual schedule.

    Multiple USA entries could represent a scheduled change, which this initial
    product tool must not overwrite or silently count as a stable $29.99 price.
    """
    response = client.get_optional(
        "/v2/inAppPurchases/%s/iapPriceSchedule" % product_id)
    if not response:
        return None
    schedule = response.get("data")
    if not schedule or schedule.get("type") != "inAppPurchasePriceSchedules":
        raise CreditPackError("Malformed in-app purchase price schedule")
    base = related_id(schedule, "baseTerritory")
    if base and base != BASE_TERRITORY:
        raise CreditPackError("Existing base price territory is %s, not USA" % base)
    if not schedule.get("id"):
        raise CreditPackError("Apple price schedule has no ID")
    prices, included = client.get_all_included(
        "/v1/inAppPurchasePriceSchedules/%s/manualPrices" % schedule["id"],
        params={"filter[territory]": BASE_TERRITORY,
                "include": "inAppPurchasePricePoint,territory", "limit": 200},
    )
    points = {r["id"]: r for r in included
              if r.get("type") == "inAppPurchasePricePoints" and r.get("id")}
    usa = []
    for price in prices:
        territory = related_id(price, "territory")
        if territory and territory != BASE_TERRITORY:
            continue
        point = points.get(related_id(price, "inAppPurchasePricePoint"))
        if point is None:
            raise CreditPackError("Apple omitted the USA price point details")
        usa.append((price, _amount(attributes(point).get("customerPrice"))))
    if not prices:
        # Apple can allocate a schedule resource before its first price, as it
        # does for the app-level schedule. An empty schedule is still unpriced.
        return None
    if len(usa) != 1:
        raise CreditPackError(
            "Existing price schedule has %d USA manual prices; inspect it manually"
            % len(usa))
    price, amount = usa[0]
    if attributes(price).get("startDate") not in (None, "") or \
            attributes(price).get("endDate") not in (None, ""):
        raise CreditPackError("Existing USA price has dates; inspect it manually")
    return amount


def find_exact_price_point(client, product_id):
    points = client.get_all(
        "/v2/inAppPurchases/%s/pricePoints" % product_id,
        params={"filter[territory]": BASE_TERRITORY,
                "include": "territory", "limit": 8000},
    )
    exact = []
    for point in points:
        if point.get("type") != "inAppPurchasePricePoints":
            continue
        if related_id(point, "territory") != BASE_TERRITORY:
            continue
        if _amount(attributes(point).get("customerPrice")) == CUSTOMER_PRICE:
            exact.append(point)
    if len(exact) != 1:
        raise CreditPackError(
            "Apple offers %d exact USA $29.99 price points; refusing any substitute"
            % len(exact))
    return exact[0]["id"]


def price_schedule_create_body(product_id, point_id):
    handle = "${rendprop-credit-100-price}"
    return {
        "data": {
            "type": "inAppPurchasePriceSchedules",
            "relationships": {
                "inAppPurchase": relationship("inAppPurchases", product_id),
                "baseTerritory": relationship("territories", BASE_TERRITORY),
                "manualPrices": {"data": [
                    {"type": "inAppPurchasePrices", "id": handle},
                ]},
            },
        },
        "included": [{
            "type": "inAppPurchasePrices",
            "id": handle,
            "attributes": {"startDate": None},
            "relationships": {
                "inAppPurchaseV2": relationship("inAppPurchases", product_id),
                "inAppPurchasePricePoint": relationship(
                    "inAppPurchasePricePoints", point_id),
            },
        }],
    }


def read_versions(client, product_id):
    versions = client.get_all("/v2/inAppPurchases/%s/versions" % product_id,
                              params={"limit": 200})
    drafts = [v for v in versions if attributes(v).get("state") == _DRAFT]
    if len(drafts) > 1:
        raise CreditPackError("Multiple editable IAP versions exist; inspect manually")
    return versions, (drafts[0] if drafts else None)


def version_create_body(product_id):
    return {"data": {
        "type": "inAppPurchaseVersions",
        "relationships": {
            "inAppPurchase": relationship("inAppPurchases", product_id),
        },
    }}


def read_localization(client, version_id):
    rows = client.get_all(
        "/v1/inAppPurchaseVersions/%s/localizations" % version_id,
        params={"limit": 200},
    )
    en = [r for r in rows if attributes(r).get("locale") == LOCALE]
    if len(en) > 1:
        raise CreditPackError("Multiple en-US IAP localizations exist")
    return en[0] if en else None


def localization_create_body(version_id):
    return {"data": {
        "type": "inAppPurchaseLocalizations",
        "attributes": {
            "locale": LOCALE,
            "name": DISPLAY_NAME,
            "description": DESCRIPTION,
        },
        "relationships": {
            "version": relationship("inAppPurchaseVersions", version_id),
        },
    }}


def inspect(client, app_id):
    """Build a deterministic read-only status/plan with no speculative price ID."""
    product = find_product(client, app_id)
    if product is None:
        return {"product": None, "steps": [
            "Create the 100-credit CONSUMABLE under this app.",
            "Then configure USA-only availability and exact USD 29.99 pricing.",
            "Then create a draft IAP version and en-US localization.",
            "Review screenshot and first-IAP submission remain separate.",
        ]}
    product_id = product["id"]
    availability = read_availability(client, product_id)
    price = read_us_price(client, product_id)
    versions, draft = read_versions(client, product_id)
    if availability is not None and availability != (False, [BASE_TERRITORY]):
        raise CreditPackError("Existing availability differs from USA-only; inspect manually")
    if price is not None and price != CUSTOMER_PRICE:
        raise CreditPackError("Existing USA customer price is $%s, not $29.99" % price)
    if not draft and versions:
        raise CreditPackError("No editable IAP version; inspect existing versions manually")
    localization = read_localization(client, draft["id"]) if draft else None
    if localization and (attributes(localization).get("name") != DISPLAY_NAME or
                         attributes(localization).get("description") != DESCRIPTION):
        raise CreditPackError("Existing en-US localization differs; inspect manually")
    steps = []
    if availability is None:
        steps.append("Create USA-only territory availability.")
    if price is None:
        steps.append("Select Apple's exact USA $29.99 price point, then create its price schedule.")
    if draft is None:
        steps.append("Create a draft IAP version.")
    if localization is None:
        steps.append("Add en-US 100-credit display metadata to the draft version.")
    if not steps:
        steps.append("Product, USA availability, exact price, and en-US draft metadata match.")
    steps.append("Review screenshot and first-IAP submission remain separate.")
    return {"product": product, "availability": availability, "price": price,
            "version": draft, "localization": localization, "steps": steps}


def apply(client, app_id):
    """Perform only missing operations, reading again before each dependent POST."""
    before = inspect(client, app_id)
    product = before["product"]
    if product is None:
        client.post("/v2/inAppPurchases", product_create_body(app_id))
        product = find_product(client, app_id)
        if product is None:
            raise CreditPackError("Created product is not visible in Apple's readback")
    product_id = product["id"]
    state = inspect(client, app_id)
    if state["availability"] is None:
        client.post("/v1/inAppPurchaseAvailabilities",
                    availability_create_body(product_id))
        if read_availability(client, product_id) != (False, [BASE_TERRITORY]):
            raise CreditPackError("USA-only availability did not read back")
    state = inspect(client, app_id)
    if state["price"] is None:
        point_id = find_exact_price_point(client, product_id)
        client.post("/v1/inAppPurchasePriceSchedules",
                    price_schedule_create_body(product_id, point_id))
        if read_us_price(client, product_id) != CUSTOMER_PRICE:
            raise CreditPackError("Exact $29.99 price did not read back")
    state = inspect(client, app_id)
    if state["version"] is None:
        client.post("/v1/inAppPurchaseVersions", version_create_body(product_id))
        _, draft = read_versions(client, product_id)
        if draft is None:
            raise CreditPackError("Draft IAP version did not read back")
    else:
        draft = state["version"]
    state = inspect(client, app_id)
    if state["localization"] is None:
        client.post("/v2/inAppPurchaseLocalizations",
                    localization_create_body(draft["id"]))
        localization = read_localization(client, draft["id"])
        if localization is None:
            raise CreditPackError("en-US localization did not read back")
    return inspect(client, app_id)


def main(argv=None, client=None, out=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("status", "plan", "apply"))
    parser.add_argument("--confirm-product-id", default=None,
                        help="Required for apply; must exactly match the fixed product ID")
    args = parser.parse_args(argv)
    out = out or sys.stdout
    if args.command == "apply" and args.confirm_product_id != PRODUCT_ID:
        parser.error("apply requires --confirm-product-id %s" % PRODUCT_ID)
    if client is None:
        client = asc.Client(asc.load_credentials(), verbose=False)
    app = asc.require_app(client)
    app_id = app["id"]
    if args.command == "apply":
        state = apply(client, app_id)
    else:
        state = inspect(client, app_id)
    out.write("%s | %s | %s\n" % (PRODUCT_ID, args.command,
                                   "exists" if state["product"] else "absent"))
    if state["product"]:
        out.write("Apple IAP ID: %s\n" % state["product"]["id"])
    for step in state["steps"]:
        out.write("- %s\n" % step)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (asc.AscError, CreditPackError) as exc:
        sys.stderr.write("Credit pack: %s\n" % exc)
        sys.exit(1)
