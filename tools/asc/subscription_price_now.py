#!/usr/bin/env python3
"""Read-only audit and one-off restoration of the Max Oct 30 USA schedule.

Apple refused an immediate replacement for an approved subscription with
HTTP 409 after the future Max row was deleted. The previous immediate-price
operation is permanently disabled. ``plan`` uses GETs only. ``restore-max``
can recreate only the exact Max $49.99 USA phase for 2026-10-30, preserving
existing subscriber prices; Ultra and Team must still match their untouched
future phases. After a write it reads Apple back and stops on any mismatch.
The operator must separately verify StoreKit on a TestFlight iPhone.

Apple says approved subscriptions use scheduled changes, generally at least
one or two days in advance. No app version or review item is submitted here.
https://developer.apple.com/help/app-store-connect/manage-subscriptions/manage-pricing-for-auto-renewable-subscriptions
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import date
from decimal import Decimal
from pathlib import Path
import sys

import asc
import subscription_reprice as scheduled


EXPECTED_DATE = "2026-10-30"
# Apple resource IDs are not credentials. Pinning them prevents this one-off
# operation from touching a changed price phase or a different subscription.
SNAPSHOT = {
    "com.rendprop.app.starter.monthly": {
        "subscription_id": "6808987088",
        "old_price_id": "eyJhIjoiNjgwODk4NzA4OCIsImMiOiJVUyIsImQiOjAsInAiOiIwIn0",
        "future_price_id": "eyJhIjoiNjgwODk4NzA4OCIsImMiOiJVUyIsImQiOjIwNzU2LCJwIjoiMCJ9",
        "point_id": "eyJzIjoiNjgwODk4NzA4OCIsInQiOiJVU0EiLCJwIjoiMTAzMjcifQ",
        "old_usd": "49.00", "target_usd": "49.99",
    },
    "com.rendprop.app.pro.monthly": {
        "subscription_id": "6808987225",
        "old_price_id": "eyJhIjoiNjgwODk4NzIyNSIsImMiOiJVUyIsImQiOjAsInAiOiIwIn0",
        "future_price_id": "eyJhIjoiNjgwODk4NzIyNSIsImMiOiJVUyIsImQiOjIwNzU2LCJwIjoiMCJ9",
        "point_id": "eyJzIjoiNjgwODk4NzIyNSIsInQiOiJVU0EiLCJwIjoiMTA0NzcifQ",
        "old_usd": "99.00", "target_usd": "99.99",
    },
    "com.rendprop.app.team.monthly": {
        "subscription_id": "6808983164",
        "old_price_id": "eyJhIjoiNjgwODk4MzE2NCIsImMiOiJVUyIsImQiOjAsInAiOiIwIn0",
        "future_price_id": "eyJhIjoiNjgwODk4MzE2NCIsImMiOiJVUyIsImQiOjIwNzU2LCJwIjoiMCJ9",
        "point_id": "eyJzIjoiNjgwODk4MzE2NCIsInQiOiJVU0EiLCJwIjoiMTA2MDYifQ",
        "old_usd": "249.00", "target_usd": "249.99",
    },
}


class PriceNowError(Exception):
    """A remote state mismatch or refused operation."""


@dataclass(frozen=True)
class Decision:
    product_id: str
    state: str  # scheduled, deleted, or restored


def _related_id(row, name):
    return ((((row or {}).get("relationships") or {}).get(name) or {})
            .get("data") or {}).get("id")


def _usa_prices(client, subscription_id):
    prices, included = client.get_all_included(
        "/v1/subscriptions/%s/prices" % subscription_id,
        params={"include": "subscriptionPricePoint,territory", "limit": 200},
    )
    points = {row["id"]: scheduled._amount(asc.attributes_of(row).get("customerPrice"))
              for row in included if row.get("type") == "subscriptionPricePoints"
              and row.get("id")}
    result = []
    for price in prices:
        if _related_id(price, "territory") != asc.USA_TERRITORY:
            continue
        attrs = asc.attributes_of(price)
        point_id = _related_id(price, "subscriptionPricePoint")
        if attrs.get("planType") != "UPFRONT" or point_id not in points:
            raise PriceNowError("Unexpected USA plan type or missing price point")
        result.append({"id": price.get("id"), "date": attrs.get("startDate"),
                       "preserved": attrs.get("preserved"), "point_id": point_id,
                       "usd": points[point_id]})
    return result


def _state(client, product_id, spec):
    rows = _usa_prices(client, spec["subscription_id"])
    old = [row for row in rows if row["id"] == spec["old_price_id"]]
    if len(old) != 1 or old[0]["date"] is not None or \
            old[0]["usd"] != Decimal(spec["old_usd"]):
        raise PriceNowError("%s old USA price no longer matches snapshot" % product_id)
    rest = [row for row in rows if row["id"] != spec["old_price_id"]]
    if len(rest) > 1:
        raise PriceNowError("%s has extra USA price rows" % product_id)
    if not rest:
        # A prior attempt may have deleted the future row but failed to POST.
        # The pinned old row must still exist at its exact amount.
        return "deleted"
    row = rest[0]
    if row["point_id"] != spec["point_id"] or \
            row["usd"] != Decimal(spec["target_usd"]):
        raise PriceNowError("%s target point/amount drift" % product_id)
    if row["id"] == spec["future_price_id"] and \
            row["date"] == EXPECTED_DATE and \
            row["preserved"] is False and old[0]["preserved"] is True:
        return "scheduled"
    if row["id"] != spec["future_price_id"] and row["date"] == EXPECTED_DATE and \
            row["preserved"] is False and old[0]["preserved"] is True:
        return "restored"
    raise PriceNowError("%s price phase changed; inspect Apple before retry" % product_id)


def _preflight(client, snapshot):
    by_id = scheduled._subscription_rows(client)
    decisions = []
    if tuple(snapshot) != scheduled.EXISTING_MONTHLY_IDS:
        raise PriceNowError("Snapshot must contain exactly the three existing USA plans")
    for product_id, spec in snapshot.items():
        sub = by_id.get(product_id)
        if sub is None or sub.get("id") != spec["subscription_id"] or \
                asc.attributes_of(sub).get("subscriptionPeriod") != "ONE_MONTH":
            raise PriceNowError("%s subscription identity/period drift" % product_id)
        if asc.price_point_territory({"id": spec["point_id"]}) != asc.USA_TERRITORY:
            raise PriceNowError("%s target point is not USA" % product_id)
        exact = scheduled._exact_point(client, sub["id"],
                                       Decimal(spec["target_usd"]))
        if exact != spec["point_id"]:
            raise PriceNowError("%s exact USA point drift" % product_id)
        decisions.append(Decision(product_id, _state(client, product_id, spec)))
    return decisions


def _create_body(spec):
    return {"data": {"type": "subscriptionPrices", "attributes": {
        "startDate": EXPECTED_DATE, "preserveCurrentPrice": True, "planType": "UPFRONT"},
        "relationships": {
            "subscription": asc.relationship("subscriptions", spec["subscription_id"]),
            "territory": asc.relationship("territories", asc.USA_TERRITORY),
            "subscriptionPricePoint": asc.relationship(
                "subscriptionPricePoints", spec["point_id"]),
        }}}


def run(client, action, confirm_live=False, confirm_preserve=False,
        snapshot=SNAPSHOT, out=None):
    out = out or sys.stdout
    if action not in ("plan", "restore-max"):
        raise PriceNowError("Use plan or restore-max; immediate changes are disabled")
    if action == "restore-max" and not (confirm_live and confirm_preserve):
        raise PriceNowError("Restoration requires both live-reprice and subscriber-preservation flags")
    decisions = _preflight(client, snapshot)
    for item in decisions:
        spec = snapshot[item.product_id]
        out.write("%s: %s; USD %s -> %s; pinned %s future row\n" % (
            item.product_id, item.state, spec["old_usd"], spec["target_usd"],
            EXPECTED_DATE))
    if action == "plan":
        out.write("Read-only. No App Store Connect write made.\n")
        return 0
    max_id = "com.rendprop.app.starter.monthly"
    states = {item.product_id: item.state for item in decisions}
    if any(states[product_id] != "scheduled" for product_id in
           scheduled.EXISTING_MONTHLY_IDS if product_id != max_id):
        raise PriceNowError("Ultra or Team changed; no restoration write")
    if states[max_id] in ("scheduled", "restored"):
        out.write("Max Oct 30 schedule already present; no write.\n")
        return 0
    if states[max_id] != "deleted":
        raise PriceNowError("Max is not in the exact deleted-schedule state")
    spec = snapshot[max_id]
    if _state(client, max_id, spec) != "deleted":
        raise PriceNowError("Max changed after preflight; no write")
    client.post("/v1/subscriptionPrices", _create_body(spec))
    if _state(client, max_id, spec) != "restored":
        raise PriceNowError("Max schedule write not confirmed; inspect Apple")
    out.write("Apple confirmed restored Max Oct 30 USA $49.99 schedule.\n")
    return 0


def main(argv=None, out=None, client=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "restore-max"))
    parser.add_argument("--confirm-live-reprice", action="store_true")
    parser.add_argument("--confirm-preserve-existing-prices", action="store_true")
    parser.add_argument("--key-dir", type=Path, default=asc.DEFAULT_KEY_DIR)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)
    out = out or sys.stdout
    try:
        if client is None:
            client = asc.Client(asc.load_credentials(args.key_dir),
                                verbose=not args.quiet, out=out)
        return run(client, args.action, args.confirm_live_reprice,
                   args.confirm_preserve_existing_prices, out=out)
    except (PriceNowError, scheduled.RepriceError, asc.AscError) as exc:
        out.write("FAILED: %s\n" % exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
