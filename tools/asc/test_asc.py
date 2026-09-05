#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Unit tests for tools/asc/asc.py. Standard library only.

Run from the repo root:
    python3 -m unittest discover -s tools/asc -v
or:
    python3 tools/asc/test_asc.py

The JWT tests generate a throwaway EC key with openssl, sign with asc.py's own
code path, then verify the signature with `openssl dgst -verify` after converting
the raw r||s signature back to DER. That proves the DER parsing is correct in
both directions against a real ECDSA implementation.
"""

import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
from decimal import Decimal
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import asc  # noqa: E402


HAVE_OPENSSL = shutil.which("openssl") is not None


# ---------------------------------------------------------------------------
# base64url and DER
# ---------------------------------------------------------------------------


class Base64UrlTests(unittest.TestCase):
    def test_strips_padding_and_uses_url_alphabet(self):
        # 0xFB 0xFF encodes to "+/8=" in standard base64; base64url must give "-_8".
        self.assertEqual(asc.b64url_encode(b"\xfb\xff"), "-_8")
        self.assertEqual(asc.b64url_encode(b""), "")
        self.assertEqual(asc.b64url_encode(b"a"), "YQ")
        self.assertEqual(asc.b64url_encode(b"ab"), "YWI")
        self.assertEqual(asc.b64url_encode(b"abc"), "YWJj")

    def test_round_trip(self):
        for raw in (b"", b"\x00", b"\xff" * 64, bytes(range(256))):
            self.assertEqual(asc.b64url_decode(asc.b64url_encode(raw)), raw)

    def test_no_padding_characters_survive(self):
        for length in range(1, 40):
            encoded = asc.b64url_encode(b"x" * length)
            self.assertNotIn("=", encoded)
            self.assertNotIn("+", encoded)
            self.assertNotIn("/", encoded)


class DerSignatureTests(unittest.TestCase):
    def test_round_trip_random_values(self):
        for raw in (
            b"\x01" * 64,
            b"\x00" * 31 + b"\x05" + b"\x00" * 31 + b"\x07",  # small r and s
            b"\xff" * 64,  # high bit set on both halves
            bytes(range(64)),
        ):
            der = asc.raw_to_der_signature(raw)
            self.assertEqual(asc.der_to_raw_signature(der), raw)

    def test_der_integers_are_padded_when_high_bit_set(self):
        raw = b"\xff" * 32 + b"\x01" * 32
        der = asc.raw_to_der_signature(raw)
        # r starts with 0xff, so DER must prepend 0x00 to keep it positive.
        self.assertEqual(der[0], 0x30)
        self.assertEqual(der[2], 0x02)
        self.assertEqual(der[3], 33)  # 32 bytes + the sign pad
        self.assertEqual(der[4], 0x00)

    def test_short_der_integers_are_left_padded_to_32_bytes(self):
        # SEQUENCE { INTEGER 0x05, INTEGER 0x07 }
        der = bytes([0x30, 0x06, 0x02, 0x01, 0x05, 0x02, 0x01, 0x07])
        raw = asc.der_to_raw_signature(der)
        self.assertEqual(len(raw), 64)
        self.assertEqual(raw[:32], b"\x00" * 31 + b"\x05")
        self.assertEqual(raw[32:], b"\x00" * 31 + b"\x07")

    def test_short_form_length_is_used_for_p256(self):
        # Two 32-byte halves with sign padding give a 70-byte body, under 0x80,
        # so a P-256 signature always uses the short form.
        der = asc.raw_to_der_signature(b"\xaa" * 64)
        self.assertEqual(der[1], 70)
        self.assertLess(der[1], 0x80)

    def test_long_form_length_is_accepted(self):
        # 64-byte halves push the body past 127 bytes, forcing the 0x81 long form.
        raw = b"\xaa" * 128
        der = asc.raw_to_der_signature(raw)
        self.assertEqual(der[1], 0x81)
        self.assertEqual(asc.der_to_raw_signature(der, size=64), raw)

    def test_rejects_malformed_input(self):
        for bad in (b"", b"\x31\x06\x02\x01\x05\x02\x01\x07", b"\x30", b"\x30\x02\x02\x01"):
            with self.assertRaises(asc.AscError):
                asc.der_to_raw_signature(bad)

    def test_rejects_trailing_bytes(self):
        der = bytes([0x30, 0x06, 0x02, 0x01, 0x05, 0x02, 0x01, 0x07])
        with self.assertRaises(asc.AscError):
            # A SEQUENCE claiming 8 bytes but holding two 3-byte INTEGERs.
            asc.der_to_raw_signature(bytes([0x30, 0x08, 0x02, 0x01, 0x05, 0x02, 0x01, 0x07, 0x00, 0x00]))
        self.assertEqual(len(asc.der_to_raw_signature(der)), 64)


# ---------------------------------------------------------------------------
# JWT, signed and verified with a throwaway EC key
# ---------------------------------------------------------------------------


@unittest.skipUnless(HAVE_OPENSSL, "openssl is required")
class JwtTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="asc-jwt-")
        sec1 = os.path.join(cls.tmp, "ec.key")
        cls.p8 = os.path.join(cls.tmp, "AuthKey_ABCD123456.p8")
        cls.pub = os.path.join(cls.tmp, "public.pem")
        # A throwaway P-256 key, in the same PKCS#8 shape Apple hands out.
        subprocess.check_call(
            ["openssl", "ecparam", "-genkey", "-name", "prime256v1", "-noout", "-out", sec1],
            stderr=subprocess.DEVNULL,
        )
        subprocess.check_call(
            ["openssl", "pkcs8", "-topk8", "-nocrypt", "-in", sec1, "-out", cls.p8],
            stderr=subprocess.DEVNULL,
        )
        subprocess.check_call(
            ["openssl", "ec", "-in", cls.p8, "-pubout", "-out", cls.pub],
            stderr=subprocess.DEVNULL,
        )
        cls.credentials = asc.Credentials(
            "ABCD123456", "57246542-96fe-1a63-e053-0824d011072a", cls.p8
        )

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_header_and_payload_are_exactly_what_apple_requires(self):
        token = asc.build_jwt(self.credentials, issued_at=1528407600, ttl=900)
        header_b64, payload_b64, signature_b64 = token.split(".")

        header = json.loads(asc.b64url_decode(header_b64))
        self.assertEqual(header, {"alg": "ES256", "kid": "ABCD123456", "typ": "JWT"})

        payload = json.loads(asc.b64url_decode(payload_b64))
        self.assertEqual(
            payload,
            {
                "iss": "57246542-96fe-1a63-e053-0824d011072a",
                "iat": 1528407600,
                "exp": 1528408500,
                "aud": "appstoreconnect-v1",
            },
        )
        # ES256 signatures are exactly 64 bytes (two 32-byte integers).
        self.assertEqual(len(asc.b64url_decode(signature_b64)), 64)

    def test_lifetime_never_exceeds_twenty_minutes(self):
        token = asc.build_jwt(self.credentials, issued_at=1000, ttl=20 * 60)
        payload = json.loads(asc.b64url_decode(token.split(".")[1]))
        self.assertEqual(payload["exp"] - payload["iat"], 1200)
        with self.assertRaises(asc.AscError):
            asc.build_jwt(self.credentials, issued_at=1000, ttl=20 * 60 + 1)

    def test_signature_verifies_with_openssl(self):
        """raw r||s -> DER -> `openssl dgst -verify` must accept it."""
        token = asc.build_jwt(self.credentials, issued_at=1528407600, ttl=600)
        header_b64, payload_b64, signature_b64 = token.split(".")
        signing_input = ("%s.%s" % (header_b64, payload_b64)).encode("ascii")

        raw = asc.b64url_decode(signature_b64)
        der = asc.raw_to_der_signature(raw)

        message_path = os.path.join(self.tmp, "message.bin")
        signature_path = os.path.join(self.tmp, "signature.der")
        with open(message_path, "wb") as handle:
            handle.write(signing_input)
        with open(signature_path, "wb") as handle:
            handle.write(der)

        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-verify", self.pub,
             "-signature", signature_path, message_path],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertEqual(result.returncode, 0,
                         "openssl rejected the signature: %s" % result.stderr.decode())
        self.assertIn(b"Verified OK", result.stdout)

    def test_tampered_payload_fails_verification(self):
        token = asc.build_jwt(self.credentials, issued_at=1528407600, ttl=600)
        header_b64, payload_b64, signature_b64 = token.split(".")
        tampered = ("%s.%sX" % (header_b64, payload_b64)).encode("ascii")

        message_path = os.path.join(self.tmp, "tampered.bin")
        signature_path = os.path.join(self.tmp, "tampered.der")
        with open(message_path, "wb") as handle:
            handle.write(tampered)
        with open(signature_path, "wb") as handle:
            handle.write(asc.raw_to_der_signature(asc.b64url_decode(signature_b64)))

        result = subprocess.run(
            ["openssl", "dgst", "-sha256", "-verify", self.pub,
             "-signature", signature_path, message_path],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        self.assertNotEqual(result.returncode, 0)

    def test_credentials_load_key_id_from_filename(self):
        directory = tempfile.mkdtemp(prefix="asc-creds-")
        try:
            shutil.copy(self.p8, os.path.join(directory, "AuthKey_9ZZQ7X2K4L.p8"))
            with open(os.path.join(directory, "config"), "w") as handle:
                handle.write("# comment\nISSUER_ID=11111111-2222-3333-4444-555555555555\n")
            credentials = asc.load_credentials(directory)
            self.assertEqual(credentials.key_id, "9ZZQ7X2K4L")
            self.assertEqual(credentials.issuer_id, "11111111-2222-3333-4444-555555555555")
        finally:
            shutil.rmtree(directory, ignore_errors=True)

    def test_missing_issuer_id_is_a_clear_error(self):
        directory = tempfile.mkdtemp(prefix="asc-creds-")
        try:
            shutil.copy(self.p8, os.path.join(directory, "AuthKey_9ZZQ7X2K4L.p8"))
            with open(os.path.join(directory, "config"), "w") as handle:
                handle.write("NOT_THE_RIGHT_KEY=x\n")
            with self.assertRaises(asc.AscError) as caught:
                asc.load_credentials(directory)
            self.assertIn("ISSUER_ID", str(caught.exception))
        finally:
            shutil.rmtree(directory, ignore_errors=True)


# ---------------------------------------------------------------------------
# Price points
# ---------------------------------------------------------------------------


def price_point(identifier, customer_price):
    return {
        "type": "subscriptionPricePoints",
        "id": identifier,
        "attributes": {"customerPrice": customer_price, "proceeds": customer_price},
    }


class PricePointTests(unittest.TestCase):
    def setUp(self):
        self.out = io.StringIO()
        self.points = [
            price_point("p-49", "49.00"),
            price_point("p-99", "99.00"),
            price_point("p-249", "249.00"),
            price_point("p-490", "490.00"),
            price_point("p-990", "990.00"),
            price_point("p-99999", "999.99"),
        ]

    def test_exact_match_is_chosen_without_a_warning(self):
        point, exact, difference = asc.choose_price_point(self.points, "249.00", out=self.out)
        self.assertEqual(point["id"], "p-249")
        self.assertTrue(exact)
        self.assertEqual(difference, Decimal("0"))
        self.assertEqual(self.out.getvalue(), "")

    def test_every_rendprop_monthly_and_annual_price_resolves_exactly(self):
        for amount, expected in (("49.00", "p-49"), ("99.00", "p-99"),
                                 ("249.00", "p-249"), ("490.00", "p-490"),
                                 ("990.00", "p-990")):
            point, exact, _ = asc.choose_price_point(self.points, amount, out=self.out)
            self.assertEqual(point["id"], expected)
            self.assertTrue(exact)

    def test_nearest_is_chosen_and_warns_loudly(self):
        # 2490.00 is above the ladder, as Apple's annual points often are.
        point, exact, difference = asc.choose_price_point(self.points, "2490.00", out=self.out)
        self.assertEqual(point["id"], "p-99999")
        self.assertFalse(exact)
        self.assertEqual(difference, Decimal("999.99") - Decimal("2490.00"))
        printed = self.out.getvalue()
        self.assertIn("PRICE POINT WARNING", printed)
        self.assertIn("2490.00", printed)
        self.assertIn("999.99", printed)

    def test_nearest_picks_the_closer_of_two_neighbours(self):
        points = [price_point("low", "100.00"), price_point("high", "110.00")]
        point, exact, _ = asc.choose_price_point(points, "109.00", out=self.out)
        self.assertEqual(point["id"], "high")
        self.assertFalse(exact)

    def test_ties_prefer_the_lower_price(self):
        points = [price_point("low", "100.00"), price_point("high", "110.00")]
        point, _exact, _ = asc.choose_price_point(points, "105.00", out=self.out)
        self.assertEqual(point["id"], "low")

    def test_no_price_points_is_an_error(self):
        with self.assertRaises(asc.AscError):
            asc.choose_price_point([], "49.00", out=self.out)

    def test_points_without_a_customer_price_are_ignored(self):
        points = [{"type": "subscriptionPricePoints", "id": "empty", "attributes": {}},
                  price_point("p-49", "49.00")]
        point, exact, _ = asc.choose_price_point(points, "49.00", out=self.out)
        self.assertEqual(point["id"], "p-49")
        self.assertTrue(exact)


# ---------------------------------------------------------------------------
# Length validators
# ---------------------------------------------------------------------------


class LengthValidatorTests(unittest.TestCase):
    def test_limits_match_apples_published_values(self):
        self.assertEqual(asc.METADATA_LIMITS["name"], ("characters", 30))
        self.assertEqual(asc.METADATA_LIMITS["subtitle"], ("characters", 30))
        self.assertEqual(asc.METADATA_LIMITS["promotional_text"], ("characters", 170))
        self.assertEqual(asc.METADATA_LIMITS["description"], ("characters", 4000))
        self.assertEqual(asc.METADATA_LIMITS["keywords"], ("bytes", 100))
        self.assertEqual(asc.METADATA_LIMITS["release_notes"], ("characters", 4000))

    def test_values_at_the_limit_pass(self):
        self.assertEqual(asc.check_length("name", "x" * 30), "x" * 30)
        self.assertEqual(asc.check_length("promotional_text", "y" * 170), "y" * 170)
        self.assertEqual(asc.check_length("description", "z" * 4000), "z" * 4000)

    def test_one_over_the_limit_fails_with_a_useful_message(self):
        with self.assertRaises(asc.AscError) as caught:
            asc.check_length("name", "x" * 31)
        message = str(caught.exception)
        self.assertIn("31 characters", message)
        self.assertIn("30", message)
        self.assertIn("name.txt", message)

    def test_keywords_are_measured_in_bytes_not_characters(self):
        # 50 two-byte characters = 100 bytes: allowed.
        asc.check_length("keywords", "é" * 50)
        # 51 of them = 102 bytes: rejected, even though it is only 51 characters.
        with self.assertRaises(asc.AscError) as caught:
            asc.check_length("keywords", "é" * 51)
        self.assertIn("102 bytes", str(caught.exception))

    def test_unknown_fields_are_passed_through(self):
        self.assertEqual(asc.check_length("support_url", "https://rendprop.com"),
                         "https://rendprop.com")

    def test_subscription_text_limits(self):
        spec = {"productId": "com.rendprop.app.pro.monthly"}
        asc.check_sub_text("Pro Monthly", asc.SUB_DISPLAY_NAME_MAX, "display name", spec)
        with self.assertRaises(asc.AscError):
            asc.check_sub_text("x" * 31, asc.SUB_DISPLAY_NAME_MAX, "display name", spec)
        with self.assertRaises(asc.AscError):
            asc.check_sub_text("x" * 46, asc.SUB_DESCRIPTION_MAX, "description", spec)

    def test_every_configured_product_fits_apples_limits(self):
        for spec in asc.SUBSCRIPTIONS:
            self.assertLessEqual(len(spec["displayName"]), asc.SUB_DISPLAY_NAME_MAX,
                                 "%s display name too long" % spec["productId"])
            self.assertLessEqual(len(spec["description"]), asc.SUB_DESCRIPTION_MAX,
                                 "%s description too long" % spec["productId"])


class ConfigurationTests(unittest.TestCase):
    """Guard the facts this tool is built on."""

    def test_six_products_with_the_agreed_ids_and_periods(self):
        expected = {
            "com.rendprop.app.team.monthly": ("ONE_MONTH", "249.00", 1),
            "com.rendprop.app.team.annual": ("ONE_YEAR", "2490.00", 1),
            "com.rendprop.app.pro.monthly": ("ONE_MONTH", "99.00", 2),
            "com.rendprop.app.pro.annual": ("ONE_YEAR", "990.00", 2),
            "com.rendprop.app.starter.monthly": ("ONE_MONTH", "49.00", 3),
            "com.rendprop.app.starter.annual": ("ONE_YEAR", "490.00", 3),
        }
        self.assertEqual(len(asc.SUBSCRIPTIONS), 6)
        for spec in asc.SUBSCRIPTIONS:
            period, usd, level = expected[spec["productId"]]
            self.assertEqual(spec["period"], period)
            self.assertEqual(spec["usd"], usd)
            self.assertEqual(spec["groupLevel"], level)

    def test_enum_values_are_ones_apple_actually_defines(self):
        # From Apple's OpenAPI spec v4.4.1.
        periods = {"ONE_WEEK", "ONE_MONTH", "TWO_MONTHS", "THREE_MONTHS",
                   "SIX_MONTHS", "ONE_YEAR"}
        for spec in asc.SUBSCRIPTIONS:
            self.assertIn(spec["period"], periods)
        self.assertIn(asc.INTRO_OFFER_MODE, {"PAY_AS_YOU_GO", "PAY_UP_FRONT", "FREE_TRIAL"})
        self.assertIn(asc.INTRO_OFFER_DURATION,
                      {"THREE_DAYS", "ONE_WEEK", "TWO_WEEKS", "ONE_MONTH", "TWO_MONTHS",
                       "THREE_MONTHS", "SIX_MONTHS", "ONE_YEAR"})
        # ScreenshotDisplayType has no APP_IPHONE_69 member; the 6.9-inch sizes
        # (1320 x 2868) go into APP_IPHONE_67.
        self.assertEqual(asc.SCREENSHOT_DISPLAY_TYPE, "APP_IPHONE_67")
        self.assertEqual(asc.SCREENSHOT_EXPECTED_SIZE, (1320, 2868))
        self.assertEqual(asc.JWT_AUDIENCE, "appstoreconnect-v1")
        self.assertEqual(asc.NOTIFICATION_VERSION, "V2")

    def test_no_secret_material_is_hard_coded(self):
        source = Path(asc.__file__).read_text(encoding="utf-8")
        self.assertNotIn("BEGIN PRIVATE KEY", source)
        self.assertNotIn("BEGIN EC PRIVATE KEY", source)
        # The issuer id is a uuid; make sure no literal uuid is embedded.
        import re
        uuids = re.findall(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-"
                           r"[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b", source)
        self.assertEqual(uuids, [], "a uuid is hard-coded in asc.py: %s" % uuids)


# ---------------------------------------------------------------------------
# A fake in-memory App Store Connect, injected as a transport
# ---------------------------------------------------------------------------


class FakeAsc(object):
    """Enough of the App Store Connect API to exercise the planner end to end.

    Instances are callable with the transport signature
    (method, url, headers, body) -> (status, headers, body_bytes).
    """

    # related path segment -> (stored type, the relationship naming the parent)
    CHILDREN = {
        ("apps", "subscriptionGroups"): ("subscriptionGroups", "app"),
        ("subscriptionGroups", "subscriptionGroupLocalizations"):
            ("subscriptionGroupLocalizations", "subscriptionGroup"),
        ("subscriptionGroups", "subscriptions"): ("subscriptions", "group"),
        ("subscriptions", "subscriptionLocalizations"):
            ("subscriptionLocalizations", "subscription"),
        ("subscriptions", "prices"): ("subscriptionPrices", "subscription"),
        ("subscriptions", "introductoryOffers"):
            ("subscriptionIntroductoryOffers", "subscription"),
    }
    # POST collection -> stored type
    COLLECTIONS = {
        "subscriptionGroups": "subscriptionGroups",
        "subscriptionGroupLocalizations": "subscriptionGroupLocalizations",
        "subscriptions": "subscriptions",
        "subscriptionLocalizations": "subscriptionLocalizations",
        "subscriptionPrices": "subscriptionPrices",
        "subscriptionAvailabilities": "subscriptionAvailabilities",
        "subscriptionIntroductoryOffers": "subscriptionIntroductoryOffers",
    }

    def __init__(self, price_ladder=None, app_attributes=None):
        self.store = {}
        self.counter = 0
        self.calls = []
        self.writes = []
        self.last_headers = {}
        # Product ids the broad group listing pretends not to see. A targeted
        # filter[productId] lookup still finds them, which is what the planner's
        # 409 recovery does.
        self.hidden_products = set()
        attributes = {
            "name": "Rendprop",
            "bundleId": asc.BUNDLE_ID,
            "sku": "rendprop-ios",
            "primaryLocale": "en-US",
            "subscriptionStatusUrl": None,
            "subscriptionStatusUrlVersion": None,
            "subscriptionStatusUrlForSandbox": None,
            "subscriptionStatusUrlVersionForSandbox": None,
        }
        attributes.update(app_attributes or {})
        self.app_id = self._insert("apps", attributes, {})
        self.territories = ["USA", "GBR", "CAN", "AUS", "DEU", "FRA", "JPN"]
        self.price_ladder = price_ladder or [
            "49.00", "99.00", "249.00", "490.00", "990.00", "999.99",
        ]

    # -- storage ---------------------------------------------------------
    def _insert(self, kind, attributes, parents):
        self.counter += 1
        identifier = "%s-%d" % (kind, self.counter)
        self.store.setdefault(kind, {})[identifier] = {
            "type": kind,
            "id": identifier,
            "attributes": dict(attributes),
            "_parents": dict(parents),
        }
        return identifier

    def _public(self, resource):
        out = {k: v for k, v in resource.items() if not k.startswith("_")}
        out["relationships"] = {
            name: {"data": {"type": "unknown", "id": value}}
            for name, value in resource["_parents"].items()
        }
        return out

    def _children(self, kind, parent_kind, parent_id, relationship_name):
        return [
            self._public(r)
            for r in self.store.get(kind, {}).values()
            if r["_parents"].get(relationship_name) == parent_id
        ]

    # -- transport -------------------------------------------------------
    def __call__(self, method, url, headers, body):
        self.last_headers = dict(headers)
        parsed = urllib.parse.urlparse(url)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)
        payload = json.loads(body.decode("utf-8")) if body else None
        self.calls.append((method, path))
        if method != "GET":
            self.writes.append((method, path))
        status, data = self.route(method, path, query, payload)
        return status, {"X-Rate-Limit": "user-hour-lim:3500;user-hour-rem:3400"}, \
            json.dumps(data).encode("utf-8")

    def route(self, method, path, query, payload):
        parts = [p for p in path.split("/") if p][1:]  # drop the "v1"

        if method == "GET":
            return self.get(parts, query)
        if method == "POST":
            return self.post(parts, payload)
        if method == "PATCH":
            return self.patch(parts, payload)
        return 405, {"errors": [{"code": "METHOD", "title": "no", "detail": path, "status": "405"}]}

    def get(self, parts, query):
        if parts == ["apps"]:
            wanted = (query.get("filter[bundleId]") or [None])[0]
            data = [self._public(a) for a in self.store["apps"].values()
                    if a["attributes"]["bundleId"] == wanted]
            return 200, {"data": data, "links": {}}

        if parts == ["territories"]:
            return 200, {"data": [{"type": "territories", "id": t} for t in self.territories],
                         "links": {}}

        if len(parts) == 3:
            parent_kind, parent_id, child = parts
            key = (parent_kind, child)
            if key in self.CHILDREN:
                kind, relationship_name = self.CHILDREN[key]
                data = self._children(kind, parent_kind, parent_id, relationship_name)
                product_filter = query.get("filter[productId]")
                if product_filter:
                    data = [d for d in data
                            if d["attributes"].get("productId") in product_filter]
                elif self.hidden_products:
                    data = [d for d in data
                            if d["attributes"].get("productId") not in self.hidden_products]
                return 200, {"data": data, "links": {}}

            if key == ("subscriptions", "pricePoints"):
                points = [
                    {"type": "subscriptionPricePoints",
                     "id": "pp-%s-%s" % (parent_id, amount.replace(".", "")),
                     "attributes": {"customerPrice": amount}}
                    for amount in self.price_ladder
                ]
                return 200, {"data": points, "links": {}}

            if key == ("subscriptions", "subscriptionAvailability"):
                for resource in self.store.get("subscriptionAvailabilities", {}).values():
                    if resource["_parents"].get("subscription") == parent_id:
                        return 200, {"data": self._public(resource)}
                return 200, {"data": None}

            if key == ("subscriptionAvailabilities", "availableTerritories"):
                resource = self.store["subscriptionAvailabilities"][parent_id]
                listed = resource["attributes"].get("_territories") or []
                return 200, {"data": [{"type": "territories", "id": t} for t in listed],
                             "links": {}}

        return 404, {"errors": [{"code": "NOT_FOUND", "title": "Not found",
                                 "detail": "/".join(parts), "status": "404"}]}

    def post(self, parts, payload):
        if len(parts) != 1 or parts[0] not in self.COLLECTIONS:
            return 404, {"errors": [{"code": "NOT_FOUND", "title": "no such collection",
                                     "detail": "/".join(parts), "status": "404"}]}
        kind = self.COLLECTIONS[parts[0]]
        data = payload["data"]
        attributes = dict(data.get("attributes") or {})

        # Reject a duplicate product id the way App Store Connect does.
        if kind == "subscriptions":
            for resource in self.store.get("subscriptions", {}).values():
                if resource["attributes"].get("productId") == attributes.get("productId"):
                    return 409, {"errors": [{
                        "code": "ENTITY_ERROR.ATTRIBUTE.INVALID.DUPLICATE",
                        "title": "The product ID is already in use.",
                        "detail": attributes.get("productId"), "status": "409"}]}

        parents = {}
        for name, value in (data.get("relationships") or {}).items():
            inner = value.get("data")
            if isinstance(inner, dict):
                parents[name] = inner["id"]
            elif isinstance(inner, list):
                attributes["_territories"] = [item["id"] for item in inner]
        identifier = self._insert(kind, attributes, parents)
        return 201, {"data": self._public(self.store[kind][identifier])}

    def patch(self, parts, payload):
        if len(parts) != 2:
            return 404, {"errors": [{"code": "NOT_FOUND", "title": "no",
                                     "detail": "/".join(parts), "status": "404"}]}
        collection, identifier = parts
        kind = self.COLLECTIONS.get(collection, collection)
        resource = self.store.get(kind, {}).get(identifier)
        if resource is None:
            return 404, {"errors": [{"code": "NOT_FOUND", "title": "no",
                                     "detail": identifier, "status": "404"}]}
        resource["attributes"].update(payload["data"].get("attributes") or {})
        return 200, {"data": self._public(resource)}


class Args(object):
    def __init__(self, **kwargs):
        self.dry_run = False
        self.json = False
        self.quiet = True
        self.key_dir = None
        for key, value in kwargs.items():
            setattr(self, key, value)


class SubscriptionPlanTests(unittest.TestCase):
    def run_subscriptions(self, fake, dry_run=False):
        out = io.StringIO()
        client = asc.Client(credentials=None, transport=fake, verbose=False, out=out)
        code = asc.cmd_subscriptions(client, Args(dry_run=dry_run), out)
        return code, out.getvalue()

    def test_first_apply_creates_everything(self):
        fake = FakeAsc()
        code, output = self.run_subscriptions(fake)
        self.assertEqual(code, 0)

        self.assertEqual(len(fake.store.get("subscriptionGroups", {})), 1)
        group = list(fake.store["subscriptionGroups"].values())[0]
        self.assertEqual(group["attributes"]["referenceName"], "rendprop_plans")

        localizations = fake.store["subscriptionGroupLocalizations"]
        self.assertEqual(len(localizations), 1)
        self.assertEqual(list(localizations.values())[0]["attributes"]["name"],
                         "Rendprop Plans")

        self.assertEqual(len(fake.store["subscriptions"]), 6)
        self.assertEqual(len(fake.store["subscriptionLocalizations"]), 6)
        self.assertEqual(len(fake.store["subscriptionPrices"]), 6)
        self.assertEqual(len(fake.store["subscriptionAvailabilities"]), 6)
        self.assertEqual(len(fake.store["subscriptionIntroductoryOffers"]), 6)

    def test_products_get_the_agreed_attributes(self):
        fake = FakeAsc()
        self.run_subscriptions(fake)
        by_product = {r["attributes"]["productId"]: r["attributes"]
                      for r in fake.store["subscriptions"].values()}
        for spec in asc.SUBSCRIPTIONS:
            attributes = by_product[spec["productId"]]
            self.assertEqual(attributes["name"], spec["name"])
            self.assertEqual(attributes["subscriptionPeriod"], spec["period"])
            self.assertEqual(attributes["groupLevel"], spec["groupLevel"])
            self.assertIs(attributes["familySharable"], False)
            self.assertEqual(attributes["reviewNote"], asc.REVIEW_NOTE)

    def test_introductory_offers_are_one_week_free_trials(self):
        fake = FakeAsc()
        self.run_subscriptions(fake)
        for offer in fake.store["subscriptionIntroductoryOffers"].values():
            self.assertEqual(offer["attributes"]["offerMode"], "FREE_TRIAL")
            self.assertEqual(offer["attributes"]["duration"], "ONE_WEEK")
            self.assertEqual(offer["attributes"]["numberOfPeriods"], 1)
            # No territory relationship means every territory.
            self.assertNotIn("territory", offer["_parents"])

    def test_availability_covers_every_territory(self):
        fake = FakeAsc()
        self.run_subscriptions(fake)
        for availability in fake.store["subscriptionAvailabilities"].values():
            self.assertIs(availability["attributes"]["availableInNewTerritories"], True)
            self.assertEqual(sorted(availability["attributes"]["_territories"]),
                             sorted(fake.territories))

    def test_notification_urls_are_set_on_the_app(self):
        fake = FakeAsc()
        self.run_subscriptions(fake)
        attributes = fake.store["apps"][fake.app_id]["attributes"]
        self.assertEqual(attributes["subscriptionStatusUrl"], asc.NOTIFICATION_URL)
        self.assertEqual(attributes["subscriptionStatusUrlForSandbox"], asc.NOTIFICATION_URL)
        self.assertEqual(attributes["subscriptionStatusUrlVersion"], "V2")
        self.assertEqual(attributes["subscriptionStatusUrlVersionForSandbox"], "V2")

    def test_second_apply_is_a_no_op(self):
        fake = FakeAsc()
        self.run_subscriptions(fake)
        snapshot = json.dumps(fake.store, sort_keys=True)

        fake.writes = []
        code, output = self.run_subscriptions(fake)
        self.assertEqual(code, 0)
        self.assertEqual(fake.writes, [], "re-running made writes: %s" % fake.writes)
        self.assertEqual(json.dumps(fake.store, sort_keys=True), snapshot)
        self.assertIn("already correct, nothing to do", output)

    def test_dry_run_writes_nothing(self):
        fake = FakeAsc()
        code, output = self.run_subscriptions(fake, dry_run=True)
        self.assertEqual(code, 0)
        self.assertEqual(fake.writes, [])
        self.assertEqual(fake.store.get("subscriptions", {}), {})
        self.assertIn("WOULD create subscription group", output)
        self.assertIn("Re-run without --dry-run", output)

    def test_dry_run_after_apply_reports_no_changes(self):
        fake = FakeAsc()
        self.run_subscriptions(fake)
        fake.writes = []
        code, output = self.run_subscriptions(fake, dry_run=True)
        self.assertEqual(code, 0)
        self.assertEqual(fake.writes, [])
        self.assertIn("0 change(s) would be made", output)

    def test_partial_state_is_completed_not_duplicated(self):
        """Interrupt after the group exists; the next run fills in the rest."""
        fake = FakeAsc()
        group_id = fake._insert(
            "subscriptionGroups", {"referenceName": "rendprop_plans"}, {"app": fake.app_id}
        )
        fake._insert(
            "subscriptions",
            {"productId": "com.rendprop.app.pro.monthly", "name": "Pro Monthly",
             "familySharable": False, "subscriptionPeriod": "ONE_MONTH",
             "reviewNote": asc.REVIEW_NOTE, "groupLevel": 2},
            {"group": group_id},
        )
        code, _output = self.run_subscriptions(fake)
        self.assertEqual(code, 0)
        self.assertEqual(len(fake.store["subscriptionGroups"]), 1)
        self.assertEqual(len(fake.store["subscriptions"]), 6)
        product_ids = sorted(r["attributes"]["productId"]
                             for r in fake.store["subscriptions"].values())
        self.assertEqual(product_ids, sorted(s["productId"] for s in asc.SUBSCRIPTIONS))

    def test_wrong_attributes_are_corrected(self):
        fake = FakeAsc()
        group_id = fake._insert(
            "subscriptionGroups", {"referenceName": "rendprop_plans"}, {"app": fake.app_id}
        )
        subscription_id = fake._insert(
            "subscriptions",
            {"productId": "com.rendprop.app.pro.monthly", "name": "WRONG NAME",
             "familySharable": True, "subscriptionPeriod": "ONE_MONTH",
             "reviewNote": "stale", "groupLevel": 9},
            {"group": group_id},
        )
        self.run_subscriptions(fake)
        attributes = fake.store["subscriptions"][subscription_id]["attributes"]
        self.assertEqual(attributes["name"], "Pro Monthly")
        self.assertIs(attributes["familySharable"], False)
        self.assertEqual(attributes["groupLevel"], 2)
        self.assertEqual(attributes["reviewNote"], asc.REVIEW_NOTE)

    def test_annual_price_above_the_ladder_warns_loudly(self):
        fake = FakeAsc()  # ladder tops out at 999.99, below the 2490.00 annual
        _code, output = self.run_subscriptions(fake)
        self.assertIn("PRICE POINT WARNING", output)
        self.assertIn("2490.00", output)

    def test_exact_annual_price_produces_no_warning(self):
        fake = FakeAsc(price_ladder=["49.00", "99.00", "249.00",
                                     "490.00", "990.00", "2490.00"])
        _code, output = self.run_subscriptions(fake)
        self.assertNotIn("PRICE POINT WARNING", output)

    def test_duplicate_product_id_conflict_is_treated_as_existing(self):
        """A 409 on create must be recovered from, not abort the run."""
        fake = FakeAsc()
        group_id = fake._insert(
            "subscriptionGroups", {"referenceName": "rendprop_plans"}, {"app": fake.app_id}
        )
        # The product exists, but the broad listing does not show it, so the
        # planner tries to create it and gets Apple's duplicate-product-id 409.
        fake._insert(
            "subscriptions",
            {"productId": "com.rendprop.app.pro.monthly", "name": "Pro Monthly",
             "familySharable": False, "subscriptionPeriod": "ONE_MONTH",
             "reviewNote": asc.REVIEW_NOTE, "groupLevel": 2},
            {"group": group_id},
        )
        fake.hidden_products = {"com.rendprop.app.pro.monthly"}

        code, output = self.run_subscriptions(fake)
        self.assertEqual(code, 0)
        self.assertIn("already exists (HTTP 409)", output)
        # It recovered onto the existing product rather than creating a seventh.
        self.assertEqual(len(fake.store["subscriptions"]), 6)
        self.assertEqual(len(fake.store["subscriptionPrices"]), 6)

    def test_unrecoverable_409_still_fails(self):
        """If the conflicting product cannot be found, the error must surface."""
        fake = FakeAsc()
        group_id = fake._insert(
            "subscriptionGroups", {"referenceName": "rendprop_plans"}, {"app": fake.app_id}
        )
        fake._insert(
            "subscriptions",
            {"productId": "com.rendprop.app.pro.monthly", "name": "Pro Monthly"},
            {"group": "a-different-app's-group"},
        )
        out = io.StringIO()
        client = asc.Client(credentials=None, transport=fake, verbose=False, out=out)
        with self.assertRaises(asc.ApiError) as caught:
            asc.cmd_subscriptions(client, Args(), out)
        self.assertEqual(caught.exception.status, 409)

    def test_missing_app_record_fails_with_the_new_app_form(self):
        fake = FakeAsc()
        fake.store["apps"][fake.app_id]["attributes"]["bundleId"] = "com.example.other"
        out = io.StringIO()
        client = asc.Client(credentials=None, transport=fake, verbose=False, out=out)
        with self.assertRaises(asc.AscError) as caught:
            asc.cmd_subscriptions(client, Args(), out)
        self.assertIn("cannot create app records", str(caught.exception))


class AppCommandTests(unittest.TestCase):
    def test_app_found(self):
        fake = FakeAsc()
        out = io.StringIO()
        client = asc.Client(credentials=None, transport=fake, verbose=False, out=out)
        self.assertEqual(asc.cmd_app(client, Args(), out), 0)
        printed = out.getvalue()
        self.assertIn("Found the app record", printed)
        self.assertIn(asc.BUNDLE_ID, printed)

    def test_app_missing_prints_the_form_and_exits_non_zero(self):
        fake = FakeAsc()
        fake.store["apps"][fake.app_id]["attributes"]["bundleId"] = "com.example.other"
        out = io.StringIO()
        client = asc.Client(credentials=None, transport=fake, verbose=False, out=out)
        self.assertEqual(asc.cmd_app(client, Args(), out), 1)
        printed = out.getvalue()
        self.assertIn("New App", printed)
        self.assertIn("Rendprop: AI Property Tours", printed)
        self.assertIn(asc.BUNDLE_ID, printed)


class ClientTests(unittest.TestCase):
    def test_authorization_header_is_never_logged(self):
        fake = FakeAsc()
        out = io.StringIO()
        credentials = asc.Credentials("KEYID12345", "issuer-uuid", "/nonexistent.p8")
        client = asc.Client(credentials, transport=fake, verbose=True, out=out)
        client._token = "a.fake.token"          # skip signing
        client._token_expires = 2 ** 40
        client.get("/v1/apps", params={"filter[bundleId]": asc.BUNDLE_ID})

        # The token must be sent...
        self.assertEqual(fake.last_headers.get("Authorization"), "Bearer a.fake.token")
        # ...and must never reach the log.
        printed = out.getvalue()
        self.assertIn("GET", printed)
        self.assertIn("/v1/apps", printed)
        self.assertNotIn("a.fake.token", printed)
        self.assertNotIn("Authorization", printed)
        self.assertNotIn("Bearer", printed)
        self.assertNotIn("KEYID12345", printed)

    def test_rate_limit_header_is_captured(self):
        fake = FakeAsc()
        client = asc.Client(credentials=None, transport=fake, verbose=False, out=io.StringIO())
        client.get("/v1/apps", params={"filter[bundleId]": asc.BUNDLE_ID})
        self.assertIn("user-hour-lim", client.rate_limit)

    def test_429_becomes_a_clear_message(self):
        def transport(method, url, headers, body):
            return 429, {"X-Rate-Limit": "user-hour-lim:3500;user-hour-rem:0"}, \
                json.dumps({"errors": [{"code": "RATE_LIMIT_EXCEEDED", "status": "429",
                                        "title": "Too many requests", "detail": "slow down"}]}).encode()
        client = asc.Client(credentials=None, transport=transport, verbose=False, out=io.StringIO())
        with self.assertRaises(asc.AscError) as caught:
            client.get("/v1/apps")
        self.assertIn("rate limit", str(caught.exception).lower())

    def test_error_envelope_is_rendered_readably(self):
        def transport(method, url, headers, body):
            return 400, {}, json.dumps({"errors": [{
                "code": "ENTITY_ERROR.ATTRIBUTE.REQUIRED", "status": "400",
                "title": "A required attribute is missing",
                "detail": "You must provide a value for 'name'",
                "source": {"pointer": "/data/attributes/name"}}]}).encode()
        client = asc.Client(credentials=None, transport=transport, verbose=False, out=io.StringIO())
        with self.assertRaises(asc.ApiError) as caught:
            client.get("/v1/apps")
        message = str(caught.exception)
        self.assertIn("ENTITY_ERROR.ATTRIBUTE.REQUIRED", message)
        self.assertIn("/data/attributes/name", message)
        self.assertEqual(caught.exception.codes, ["ENTITY_ERROR.ATTRIBUTE.REQUIRED"])

    def test_get_optional_returns_none_for_404_and_null_data(self):
        def transport(method, url, headers, body):
            if "missing" in url:
                return 404, {}, b'{"errors":[{"code":"NOT_FOUND","status":"404","title":"x","detail":"y"}]}'
            return 200, {}, b'{"data": null}'
        client = asc.Client(credentials=None, transport=transport, verbose=False, out=io.StringIO())
        self.assertIsNone(client.get_optional("/v1/missing"))
        self.assertIsNone(client.get_optional("/v1/present"))

    def test_get_all_follows_pagination(self):
        pages = {
            "https://api.appstoreconnect.apple.com/v1/territories":
                {"data": [{"id": "USA"}], "links": {"next": "https://api.appstoreconnect.apple.com/v1/territories?cursor=2"}},
            "https://api.appstoreconnect.apple.com/v1/territories?cursor=2":
                {"data": [{"id": "GBR"}], "links": {}},
        }

        def transport(method, url, headers, body):
            key = url.split("&")[0]
            for candidate, page in pages.items():
                if key.startswith(candidate) and ("cursor=2" in key) == ("cursor=2" in candidate):
                    return 200, {}, json.dumps(page).encode()
            return 404, {}, b'{"errors":[]}'

        client = asc.Client(credentials=None, transport=transport, verbose=False, out=io.StringIO())
        items = client.get_all("/v1/territories")
        self.assertEqual([i["id"] for i in items], ["USA", "GBR"])


class PngTests(unittest.TestCase):
    def test_reads_dimensions_from_a_real_png_header(self):
        # A minimal 1320x2868 PNG header: signature + IHDR chunk.
        import struct
        ihdr = b"IHDR" + struct.pack(">II", 1320, 2868) + b"\x08\x06\x00\x00\x00"
        blob = (b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + ihdr
                + b"\x00\x00\x00\x00" + b"\x00" * 16)
        directory = tempfile.mkdtemp(prefix="asc-png-")
        try:
            path = Path(directory) / "01-home.png"
            path.write_bytes(blob)
            self.assertEqual(asc.png_dimensions(path), (1320, 2868))
            self.assertEqual(asc.png_dimensions(path), asc.SCREENSHOT_EXPECTED_SIZE)
        finally:
            shutil.rmtree(directory, ignore_errors=True)

    def test_non_png_returns_none(self):
        directory = tempfile.mkdtemp(prefix="asc-png-")
        try:
            path = Path(directory) / "not.png"
            path.write_bytes(b"this is not a png file at all, not even close ok")
            self.assertIsNone(asc.png_dimensions(path))
        finally:
            shutil.rmtree(directory, ignore_errors=True)


class UploadOperationTests(unittest.TestCase):
    def test_chunks_are_sent_at_the_right_offsets_with_apples_headers(self):
        data = bytes(range(256)) * 4  # 1024 bytes
        operations = [
            {"method": "PUT", "url": "https://upload.example/1", "offset": 0, "length": 600,
             "requestHeaders": [{"name": "Content-Type", "value": "image/png"}]},
            {"method": "PUT", "url": "https://upload.example/2", "offset": 600, "length": 424,
             "requestHeaders": [{"name": "Content-Type", "value": "image/png"}]},
        ]
        seen = []

        def transport(method, url, headers, body):
            seen.append((method, url, headers, body))
            return 200, {}, b""

        client = asc.Client(credentials=None, transport=transport, verbose=False, out=io.StringIO())
        asc.run_upload_operations(client, operations, data, io.StringIO())

        self.assertEqual(len(seen), 2)
        self.assertEqual(seen[0][3], data[0:600])
        self.assertEqual(seen[1][3], data[600:1024])
        self.assertEqual(b"".join(call[3] for call in seen), data)
        for call in seen:
            self.assertEqual(call[2], {"Content-Type": "image/png"})
            # The upload host must never see the App Store Connect bearer token.
            self.assertNotIn("Authorization", call[2])

    def test_a_failed_chunk_raises(self):
        def transport(method, url, headers, body):
            return 500, {}, b"boom"
        client = asc.Client(credentials=None, transport=transport, verbose=False, out=io.StringIO())
        with self.assertRaises(asc.AscError):
            asc.run_upload_operations(
                client,
                [{"method": "PUT", "url": "https://upload.example/1", "offset": 0,
                  "length": 4, "requestHeaders": []}],
                b"abcd", io.StringIO(),
            )


if __name__ == "__main__":
    unittest.main(verbosity=2)
