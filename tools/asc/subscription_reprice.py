#!/usr/bin/env python3
"""Schedule Ultra and Team US monthly prices; verify Max stays at USD 49.00.

The broad ``asc.py subscriptions apply`` intentionally refuses an existing
price mismatch. This narrower command can plan a future USA price change and
preserves the current price for existing subscribers. It never creates products,
changes other territories, stages a review, or submits an app.

Request fields are from Apple's App Store Connect OpenAPI 4.5.1 (2026-10-06),
SubscriptionPriceCreateRequest. Apple normally allows scheduling one to two
days ahead; a three-day minimum here gives room for storefront time zones.
"""

from __future__ import annotations

import argparse
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
import sys

import asc


MAX_PRODUCT_ID = "com.rendprop.app.starter.monthly"
MAX_USD = Decimal("49.00")
EXISTING_MONTHLY_IDS = (
    "com.rendprop.app.pro.monthly",      # Ultra
    "com.rendprop.app.team.monthly",     # Team, three seats
)
MIN_SCHEDULE_LEAD_DAYS = 3


class RepriceError(Exception):
    """A state or price conflict that must be inspected before any write."""


def _amount(value):
    try:
        amount = Decimal(str(value))
    except (TypeError, ValueError, InvalidOperation):
        raise RepriceError("Apple returned a price point without a valid amount")
    if not amount.is_finite():
        raise RepriceError("Apple returned a non-finite price point amount")
    return amount


def _related_id(row, name):
    return ((((row or {}).get("relationships") or {}).get(name) or {})
            .get("data") or {}).get("id")


def _date(value, label):
    if not isinstance(value, str) or len(value) != 10:
        raise RepriceError("%s must be YYYY-MM-DD" % label)
    try:
        parsed = date.fromisoformat(value)
    except ValueError:
        raise RepriceError("%s must be a valid YYYY-MM-DD date" % label)
    if parsed.isoformat() != value:
        raise RepriceError("%s must be YYYY-MM-DD" % label)
    return parsed


def _target_specs():
    by_id = {row["productId"]: row for row in asc.SUBSCRIPTIONS}
    return [by_id[product_id] for product_id in EXISTING_MONTHLY_IDS]


def _subscription_rows(client):
    app = asc.require_app(client)
    group = asc.find_group(client, app["id"])
    if group is None:
        raise RepriceError("Rendprop's subscription group does not exist")
    rows = client.get_all("/v1/subscriptionGroups/%s/subscriptions" % group["id"])
    by_product = {}
    for row in rows:
        product_id = asc.attributes_of(row).get("productId")
        if product_id in by_product:
            raise RepriceError("Apple returned duplicate subscription %s" % product_id)
        by_product[product_id] = row
    return by_product


def _usa_schedule(client, subscription_id, today):
    """Return (current amount, future rows), ignoring preserved old cohorts.

    A change dated today remains pending: Apple's territory-specific effective
    hour cannot be inferred from a date-only API response. Unknown rows fail
    closed rather than being treated as a matching price.
    """
    prices, included = client.get_all_included(
        "/v1/subscriptions/%s/prices" % subscription_id,
        params={"include": "subscriptionPricePoint,territory", "limit": 200},
    )
    points = {row["id"]: _amount(asc.attributes_of(row).get("customerPrice"))
              for row in included if row.get("type") == "subscriptionPricePoints"
              and row.get("id")}
    current = []
    future = []
    for price in prices:
        if _related_id(price, "territory") != asc.USA_TERRITORY:
            continue
        attrs = asc.attributes_of(price)
        if attrs.get("preserved") is True:
            continue
        # Apple's UPFRONT means the ordinary subscription bills once for each
        # period. MONTHLY is a *12-month commitment* billed in monthly pieces,
        # and must never be selected for Rendprop's standard one-month SKU.
        if attrs.get("planType") not in (None, "UPFRONT"):
            raise RepriceError("USA has an unexpected subscription price plan type")
        point_id = _related_id(price, "subscriptionPricePoint")
        if point_id not in points:
            raise RepriceError("Apple omitted a USA subscription price point")
        start = attrs.get("startDate")
        start_date = _date(start, "Apple startDate") if start else None
        row = {"id": price.get("id"), "date": start_date,
               "amount": points[point_id], "point_id": point_id}
        if start_date is not None and start_date >= today:
            future.append(row)
        else:
            current.append(row)
    if not current:
        # Apple may mark the old price preserved as soon as a future increase
        # is scheduled. A matching future schedule can still be recognized
        # idempotently, but the present new-buyer price is then unprovable.
        if future:
            return None, future
        raise RepriceError("USA subscription has no provable current new-buyer price")
    current.sort(key=lambda row: row["date"] or date.min, reverse=True)
    if len(current) > 1 and current[0]["date"] == current[1]["date"]:
        raise RepriceError("USA has ambiguous current price rows with the same start date")
    return current[0]["amount"], future


def _exact_point(client, subscription_id, target):
    points = client.get_all(
        "/v1/subscriptions/%s/pricePoints" % subscription_id,
        params={"filter[territory]": asc.USA_TERRITORY,
                "filter[planType]": "UPFRONT",
                "include": "territory", "limit": 8000},
    )
    matches = []
    for point in points:
        if point.get("type") != "subscriptionPricePoints" or not point.get("id"):
            continue
        related = _related_id(point, "territory")
        encoded = asc.price_point_territory(point)
        # A filtered response alone cannot prove that an opaque point belongs
        # to USA. Demand both available territory signals agree with USA.
        if related != asc.USA_TERRITORY or encoded != asc.USA_TERRITORY:
            continue
        if _amount(asc.attributes_of(point).get("customerPrice")) == target:
            matches.append(point["id"])
    if len(matches) != 1:
        raise RepriceError(
            "Apple offers %d provably exact USA USD %s points for subscription %s"
            % (len(matches), target, subscription_id))
    return matches[0]


def plan_changes(client, effective_date, today=None):
    """Read the complete target set and validate it before any write."""
    today = today or datetime.now(timezone.utc).date()
    desired_date = _date(effective_date, "--effective-date")
    by_product = _subscription_rows(client)
    max_subscription = by_product.get(MAX_PRODUCT_ID)
    if max_subscription is None or not max_subscription.get("id") or \
            asc.attributes_of(max_subscription).get("subscriptionPeriod") != "ONE_MONTH":
        raise RepriceError("Existing Max subscription is missing or not monthly")
    max_current, max_future = _usa_schedule(client, max_subscription["id"], today)
    if max_current != MAX_USD or max_future:
        raise RepriceError(
            "Max must remain at current USA USD 49.00 with no future price; "
            "inspect Apple before repricing Ultra or Team")
    decisions = []
    for spec in _target_specs():
        product_id = spec["productId"]
        subscription = by_product.get(product_id)
        if subscription is None or not subscription.get("id"):
            raise RepriceError("Existing subscription %s is missing" % product_id)
        if asc.attributes_of(subscription).get("subscriptionPeriod") != "ONE_MONTH":
            raise RepriceError("%s is not a one-month subscription" % product_id)
        target = _amount(spec["usd"])
        current, future = _usa_schedule(client, subscription["id"], today)
        if len(future) > 1:
            raise RepriceError("%s has multiple future USA prices" % product_id)
        if future:
            scheduled = future[0]
            if scheduled["date"] != desired_date or scheduled["amount"] != target:
                raise RepriceError(
                    "%s already has a different future USA schedule (%s, USD %s); "
                    "refusing to overwrite it" %
                    (product_id, scheduled["date"], scheduled["amount"]))
            state = "already-scheduled"
            point_id = scheduled["point_id"]
        elif current == target:
            state = "already-current"
            point_id = None
        else:
            if current is None:
                raise RepriceError("%s has no provable current USA price" % product_id)
            if target < current:
                raise RepriceError(
                    "%s would decrease from USD %s; Apple cannot preserve the "
                    "higher current subscriber price" % (product_id, current))
            if desired_date < today + timedelta(days=MIN_SCHEDULE_LEAD_DAYS):
                raise RepriceError(
                    "%s needs a future effective date at least %d UTC calendar "
                    "days ahead (%s or later)" %
                    (product_id, MIN_SCHEDULE_LEAD_DAYS,
                     today + timedelta(days=MIN_SCHEDULE_LEAD_DAYS)))
            point_id = _exact_point(client, subscription["id"], target)
            state = "schedule"
        decisions.append({"product_id": product_id, "subscription_id": subscription["id"],
                          "current": current, "target": target,
                          "effective_date": desired_date, "point_id": point_id,
                          "state": state})
    return decisions


def price_create_body(decision):
    return {"data": {
        "type": "subscriptionPrices",
        "attributes": {
            "startDate": decision["effective_date"].isoformat(),
            "preserveCurrentPrice": True,
            "planType": "UPFRONT",
        },
        "relationships": {
            "subscription": asc.relationship("subscriptions", decision["subscription_id"]),
            "territory": asc.relationship("territories", asc.USA_TERRITORY),
            "subscriptionPricePoint": asc.relationship(
                "subscriptionPricePoints", decision["point_id"]),
        },
    }}


def run(client, action, effective_date, confirm_preserve=False, out=None, today=None):
    out = out or sys.stdout
    if action not in ("plan", "apply"):
        raise RepriceError("Use plan or apply")
    if action == "apply" and not confirm_preserve:
        raise RepriceError("Apply requires --confirm-preserve-existing-prices")
    decisions = plan_changes(client, effective_date, today=today)
    for item in decisions:
        current_label = ("USD %.2f" % item["current"]
                         if item["current"] is not None else "unverified")
        out.write("%s: current USA %s; target USD %.2f; %s %s\n" %
                  (item["product_id"], current_label, item["target"],
                   item["state"], item["effective_date"]))
    changes = [item for item in decisions if item["state"] == "schedule"]
    existing = [item for item in decisions if item["state"] == "already-scheduled"]
    if existing:
        out.write("Existing future schedules are left untouched; the API price "
                  "listing does not prove whether their subscriber prices were "
                  "preserved. Inspect those in App Store Connect.\n")
    if action == "plan":
        out.write("Read-only plan: %d new USA schedules; preserve existing subscribers.\n"
                  % len(changes))
        return 0
    for item in changes:
        client.post("/v1/subscriptionPrices", price_create_body(item))
        # If Apple accepted a write but did not expose it on read-back, stop;
        # the operator must inspect the remote schedule before any retry.
        _current, future = _usa_schedule(
            client, item["subscription_id"],
            today or datetime.now(timezone.utc).date())
        if len(future) != 1 or future[0]["date"] != item["effective_date"] or \
                future[0]["amount"] != item["target"]:
            raise RepriceError("Apple did not confirm the %s future USA schedule; "
                               "inspect before retrying" % item["product_id"])
    if changes:
        out.write("Applied %d future USA price schedule(s) with a request to "
                  "preserve existing subscriber prices.\n" % len(changes))
    else:
        out.write("No new USA price schedules applied.\n")
    return 0


def main(argv=None, out=None, client=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "apply"))
    parser.add_argument("--effective-date", required=True, metavar="YYYY-MM-DD")
    parser.add_argument("--confirm-preserve-existing-prices", action="store_true")
    parser.add_argument("--key-dir", type=Path, default=asc.DEFAULT_KEY_DIR)
    parser.add_argument("--quiet", action="store_true")
    args = parser.parse_args(argv)
    out = out or sys.stdout
    try:
        if client is None:
            client = asc.Client(asc.load_credentials(args.key_dir),
                                verbose=not args.quiet, out=out)
        return run(client, args.action, args.effective_date,
                   confirm_preserve=args.confirm_preserve_existing_prices, out=out)
    except (RepriceError, asc.AscError) as exc:
        out.write("FAILED: %s\n" % exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
