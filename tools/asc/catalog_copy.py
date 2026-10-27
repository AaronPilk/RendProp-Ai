#!/usr/bin/env python3
"""Reconcile only Rendprop's 1.0.5 subscription and review copy.

`plan` uses authenticated GETs. After the funded monthly catalog is active,
`apply` patches changed en-US subscription
localizations, the 1.0.5 listing, and its App Review notes, then reads each
resource back. It never changes products, prices, offers, availability, a
build, screenshots, review staging, or release state.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from decimal import Decimal
import re
import sys

import asc


VERSION = "1.0.5"
EXPECTED_APP_ID = "6808982413"
RELEASE_PRICE_DATE = "2026-10-30"
SOURCE = asc.REPO_ROOT / "apps/ios/Rendprop/Purchases/Products.swift"
CORE = (
    ("pro", "com.rendprop.app.pro29.monthly", 60, "29.99"),
    ("max", "com.rendprop.app.starter.monthly", 120, "49.99"),
    ("ultra", "com.rendprop.app.pro.monthly", 250, "99.99"),
    ("team", "com.rendprop.app.team.monthly", 600, "249.99"),
)


class CopyError(Exception):
    pass


def specs():
    """The deliberately narrow ten-SKU copy target; annual SKUs stay untouched."""
    ids = {product_id for _plan, product_id, _credits, _price in CORE}
    ids.update("com.rendprop.app.team%d.monthly" % n for n in range(4, 10))
    result = {row["productId"]: row for row in
              asc.SUBSCRIPTIONS + asc.TEAM_SEAT_SUBSCRIPTIONS
              if row["productId"] in ids}
    if set(result) != ids:
        raise CopyError("The ASC catalog does not contain exactly the expected ten SKUs")
    for plan, product_id, credits, price in CORE:
        row = result[product_id]
        if row["usd"] != price or row["description"] != (
                "%s AI credits monthly; %d %s." %
                (format(credits, ","), 3 if plan == "team" else 1,
                 "seats" if plan == "team" else "seat")):
            raise CopyError("ASC catalog drift for %s" % product_id)
    for seats in range(4, 10):
        row = result["com.rendprop.app.team%d.monthly" % seats]
        credits = 600 + 100 * (seats - 3)
        if (row["usd"] != "%d.99" % (249 + 50 * (seats - 3)) or
                row["description"] != "%s AI credits monthly; %d seats." %
                (format(credits, ","), seats)):
            raise CopyError("ASC Team %d catalog drift" % seats)
    return [result[product_id] for product_id in
            [item[1] for item in CORE] +
            ["com.rendprop.app.team%d.monthly" % n for n in range(4, 10)]]


def verify_source():
    """Refuse to publish the tool's copy if the native catalog has changed."""
    swift = SOURCE.read_text(encoding="utf-8")
    for plan, product_id, credits, _price in CORE:
        patterns = (
            r'case \.' + plan + r':\s+return "' + re.escape(product_id) + r'"',
            r'case \.' + plan + r':\s+return PlanAllowances\(credits:\s*' + str(credits) + r'\b',
        )
        if any(re.search(pattern, swift) is None for pattern in patterns):
            raise CopyError("Native plan/catalog drift for %s" % product_id)
    for seats in range(4, 10):
        product_id = "com.rendprop.app.team%d.monthly" % seats
        credits = 600 + 100 * (seats - 3)
        pattern = (r'\.init\(productID:\s*"' + re.escape(product_id) +
                   r'",\s*seats:\s*' + str(seats) +
                   r',\s*monthlyCredits:\s*' + str(credits) + r'\)')
        if re.search(pattern, swift) is None:
            raise CopyError("Native Team %d catalog drift" % seats)
    return "union(TeamSeatVariant.all.map(\\.productID))" in swift


def _one(rows, label):
    if len(rows) != 1:
        raise CopyError("Expected exactly one %s, found %d" % (label, len(rows)))
    return rows[0]


def _relationship_id(row, name):
    return (((row.get("relationships") or {}).get(name) or {}).get("data") or {}).get("id")


def _validate_price_and_trial(client, subscription, spec):
    product_id = spec["productId"]
    offers = client.get_all("/v1/subscriptions/%s/introductoryOffers" % subscription["id"])
    valid_offers = [o for o in offers if all((
        o.get("attributes", {}).get("offerMode") == "FREE_TRIAL",
        o.get("attributes", {}).get("duration") == "ONE_WEEK",
        o.get("attributes", {}).get("numberOfPeriods") == 1,
        o.get("attributes", {}).get("targetSubscriptionPlanType") == "UPFRONT",
        o.get("attributes", {}).get("endDate") is None,
        (o.get("attributes", {}).get("startDate") or "9999-12-31") <=
            datetime.now(timezone.utc).date().isoformat(),
    ))]
    if not valid_offers:
        raise CopyError("%s has no open 7-day free trial" % product_id)
    prices, included = client.get_all_included(
        "/v1/subscriptions/%s/prices" % subscription["id"],
        params={"include": "subscriptionPricePoint,territory", "limit": 200})
    points = {row["id"]: row.get("attributes", {}).get("customerPrice")
              for row in included if row.get("type") == "subscriptionPricePoints"}
    matches = []
    for row in prices:
        if _relationship_id(row, "territory") != "USA":
            continue
        attrs = row.get("attributes") or {}
        if attrs.get("preserved") is True or attrs.get("planType") not in (None, "UPFRONT"):
            continue
        point = points.get(_relationship_id(row, "subscriptionPricePoint"))
        if point is not None and Decimal(str(point)) == Decimal(spec["usd"]):
            matches.append(attrs.get("startDate"))
    if len(matches) != 1:
        raise CopyError("%s has %d exact non-preserved USA USD %s prices" %
                        (product_id, len(matches), spec["usd"]))
    if product_id in {"com.rendprop.app.starter.monthly",
                      "com.rendprop.app.pro.monthly",
                      "com.rendprop.app.team.monthly"} and matches[0] != RELEASE_PRICE_DATE:
        raise CopyError("%s has price date %s, expected %s" %
                        (product_id, matches[0], RELEASE_PRICE_DATE))
    return matches[0]


def _copy_file(name, limit):
    value = (asc.METADATA_DIR / (name + ".txt")).read_text(encoding="utf-8").strip()
    if not value or len(value) > limit:
        raise CopyError("%s.txt has %d characters; expected 1-%d" %
                        (name, len(value), limit))
    return value


def _change(kind, resource, attrs):
    current = resource.get("attributes") or {}
    changed = {k: v for k, v in attrs.items() if current.get(k) != v}
    return {"kind": kind, "id": resource["id"], "attrs": changed}


def plan(client):
    team_variants_dormant = verify_source()
    catalog = specs()
    app = asc.require_app(client)
    if app["id"] != EXPECTED_APP_ID:
        raise CopyError("App ID %s is not the vetted Rendprop app" % app["id"])
    group = asc.find_group(client, app["id"])
    if group is None:
        raise CopyError("Rendprop subscription group is missing")
    by_product = {row.get("attributes", {}).get("productId"): row for row in
                  client.get_all("/v1/subscriptionGroups/%s/subscriptions" % group["id"])}
    changes = []
    evidence = []
    for spec in catalog:
        product_id = spec["productId"]
        subscription = by_product.get(product_id)
        if not subscription or subscription.get("attributes", {}).get("subscriptionPeriod") != "ONE_MONTH":
            raise CopyError("%s is missing or not monthly" % product_id)
        price_date = _validate_price_and_trial(client, subscription, spec)
        local = _one([row for row in client.get_all(
            "/v1/subscriptions/%s/subscriptionLocalizations" % subscription["id"])
            if row.get("attributes", {}).get("locale") == "en-US"],
            product_id + " en-US localization")
        attrs = {"name": asc.check_sub_text(spec["displayName"], asc.SUB_DISPLAY_NAME_MAX,
                                             "display name", spec),
                 "description": asc.check_sub_text(spec["description"], asc.SUB_DESCRIPTION_MAX,
                                                   "description", spec)}
        changes.append(_change("subscriptionLocalizations", local, attrs))
        evidence.append((product_id, spec["usd"], price_date, attrs, local.get("attributes") or {}))

    version = _one([row for row in client.get_all(
        "/v1/apps/%s/appStoreVersions" % app["id"],
        params={"filter[platform]": "IOS", "limit": 200})
        if row.get("attributes", {}).get("versionString") == VERSION], "iOS 1.0.5 version")
    state = version.get("attributes", {}).get("appVersionState") or version.get("attributes", {}).get("appStoreState")
    if state != "PREPARE_FOR_SUBMISSION":
        raise CopyError("Version %s is %s; expected PREPARE_FOR_SUBMISSION" % (VERSION, state))
    local = _one([row for row in client.get_all(
        "/v1/appStoreVersions/%s/appStoreVersionLocalizations" % version["id"])
        if row.get("attributes", {}).get("locale") == "en-US"], "version en-US localization")
    listing = {"description": _copy_file("description", 4000),
               "promotionalText": _copy_file("promotional_text", 170),
               "whatsNew": _copy_file("release_notes", 4000)}
    changes.append(_change("appStoreVersionLocalizations", local, listing))
    detail = client.get_optional("/v1/appStoreVersions/%s/appStoreReviewDetail" % version["id"])
    if not detail or not (detail.get("data") or {}).get("id"):
        raise CopyError("Version 1.0.5 App Review detail is missing")
    notes = _copy_file("review_notes", 4000)
    if team_variants_dormant and "Team 4-9-seat products are not offered" not in notes:
        raise CopyError("Review notes must disclose dormant Team 4-9-seat products")
    if not team_variants_dormant and (
            "Team 4-9-seat products are not offered" in notes or
            "additional Team seats" not in notes or "additional Team seats" not in listing["description"]):
        raise CopyError("Public and review copy must describe newly sold additional Team seats")
    changes.append(_change("appStoreReviewDetails", detail["data"], {"notes": notes}))
    return app["id"], version["id"], changes, evidence


def run(client, action, confirm_app_id=None, confirm_version_id=None,
        confirm_credit_activation=False, out=None):
    out = out or sys.stdout
    app_id, version_id, changes, evidence = plan(client)
    out.write("App %s, iOS version %s (%s)\n" % (app_id, VERSION, version_id))
    for product_id, amount, price_date, desired, current in evidence:
        out.write("  %s: USA USD %s %s; 7-day trial; %s / %s%s\n" %
                  (product_id, amount, "from " + price_date if price_date else "current",
                   desired["name"], desired["description"],
                   " [change]" if any(current.get(k) != v for k, v in desired.items()) else ""))
    pending = [change for change in changes if change["attrs"]]
    out.write("%s: %d of %d resources need copy updates.\n" %
              (action.capitalize(), len(pending), len(changes)))
    for change in pending:
        out.write("  %s %s: %s\n" %
                  (change["kind"], change["id"], ", ".join(sorted(change["attrs"]))))
    if action == "plan":
        return 0
    if confirm_app_id != app_id or confirm_version_id != version_id:
        raise CopyError("Apply requires --confirm-app-id %s and --confirm-version-id %s" %
                        (app_id, version_id))
    if not confirm_credit_activation:
        raise CopyError("Apply requires --confirm-credit-activation after a live readback "
                        "of active monthly credit catalog, funded schedules and serving policy")
    for change in pending:
        kind, identifier, attrs = change["kind"], change["id"], change["attrs"]
        path = "/v1/%s/%s" % (kind, identifier)
        client.patch(path, {"data": {"type": kind, "id": identifier, "attributes": attrs}})
        readback = client.get(path)
        actual = (readback.get("data") or {}).get("attributes") or {}
        if any(actual.get(k) != value for k, value in attrs.items()):
            raise CopyError("Apple did not confirm %s %s; stop and inspect before retry" %
                            (kind, identifier))
        out.write("  readback confirmed %s %s\n" % (kind, identifier))
    return 0


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "apply"))
    parser.add_argument("--confirm-app-id")
    parser.add_argument("--confirm-version-id")
    parser.add_argument("--confirm-credit-activation", action="store_true",
                        help="operator confirms a fresh live readback of funded retail credit activation")
    args = parser.parse_args(argv)
    try:
        client = asc.Client(asc.load_credentials(), verbose=False)
        return run(client, args.action, args.confirm_app_id, args.confirm_version_id,
                   args.confirm_credit_activation)
    except (CopyError, asc.AscError) as exc:
        print("FAILED: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
