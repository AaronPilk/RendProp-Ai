"""Source-wiring checks for Republish (build 58): no simulator, network or device.

`AppModel.republishExisting` refuses to republish while the listing's facts or
photos are unsynced. Part of that refusal reads `listing.lastError`, which is
also the app's best-effort warning line (a poster that didn't upload, a photo
that didn't land, an edit's missing "View original", a failed republish). That
line is never cleared by a successful facts sync, so a stale warning would veto
every retry before the retry ran. These checks pin the fix — the stale line is
cleared at the start of the republish, after the in-flight guard, before any
sync — and prove the refusal itself is still there.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / 'apps/ios/Rendprop/RendpropApp.swift'

CLEAR = 'setLastError(nil, for: id)'
IN_FLIGHT = 'defer { publishInFlight.remove(id) }'
FACTS_SYNC = 'await syncListing(id)'
FACTS_GUARD = 'synced.needsServerSync != true'
FACTS_ERROR_GUARD = 'synced.lastError == nil'
PHOTO_GUARD = '!gallerySyncInFlight.contains(id), !gallerySyncPending.contains(id)'
PHOTO_ERROR_GUARD = "listings.first(where: { $0.id == id })?.lastError == nil"
SUCCESS_CLEAR = 'l.lastError = nil'
FAILURE_REPORT = 'setLastError(Self.userMessage(for: error), for: id)'
SLUG_GUARD = 'guard published.slug == currentSlug else {'


def block(source, anchor):
    start = source.index(anchor)
    brace = source.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        if source[end] == '{':
            depth += 1
        elif source[end] == '}':
            depth -= 1
        end += 1
    return source[start:end]


def republish(source=None):
    return block(source if source is not None else APP.read_text(),
                 'func republishExisting(listingID id: UUID, cellularApproved: Bool = false) async throws -> URL {')


def at(body, needle):
    assert needle in body, 'republish lost: ' + needle
    return body.index(needle)


def check(body):
    """Raise AssertionError unless the republish body clears a stale warning
    exactly once, after the in-flight guard and before the first sync, while
    keeping every refusal that makes the clear safe."""
    assert body.count(CLEAR) == 1, 'stale warning must be cleared exactly once'
    clear = at(body, CLEAR)
    assert at(body, IN_FLIGHT) < clear, 'clear must follow the in-flight guard'
    assert clear < at(body, FACTS_SYNC), 'clear must precede the facts sync'
    assert at(body, FACTS_SYNC) < at(body, FACTS_GUARD) < at(body, FACTS_ERROR_GUARD), \
        'facts refusal must follow the facts sync and still read the fresh warning'
    assert at(body, FACTS_ERROR_GUARD) < at(body, PHOTO_GUARD) < at(body, PHOTO_ERROR_GUARD), \
        'photo refusal must follow the facts refusal and still read the fresh warning'
    assert at(body, FAILURE_REPORT) < at(body, SLUG_GUARD) < at(body, SUCCESS_CLEAR), \
        'a failed republish must still write its own reason; success clears it'
    assert body.count('throw AIImagePrep.error("Your listing changes haven\'t reached the live page yet.') == 1
    assert body.count('throw AIImagePrep.error("Your photos haven\'t reached the live page yet.') == 1


class RepublishRetrySourceTests(unittest.TestCase):
    def test_actual_source_clears_stale_warning_before_sync(self):
        check(republish())

    def test_missing_clear_negative_control_is_rejected(self):
        body = republish()
        mutant = body.replace(CLEAR, '// stale warning left in place')
        self.assertNotEqual(body, mutant)
        with self.assertRaises(AssertionError):
            check(mutant)

    def test_clear_after_sync_negative_control_is_rejected(self):
        body = republish()
        mutant = body.replace(CLEAR, '', 1).replace(FACTS_SYNC, FACTS_SYNC + '\n        ' + CLEAR, 1)
        self.assertEqual(mutant.count(CLEAR), 1)
        with self.assertRaises(AssertionError):
            check(mutant)

    def test_dropped_refusal_negative_control_is_rejected(self):
        body = republish()
        for needle in (FACTS_GUARD, FACTS_ERROR_GUARD, PHOTO_GUARD, PHOTO_ERROR_GUARD):
            mutant = body.replace(needle, 'true', 1)
            self.assertNotEqual(body, mutant, needle)
            with self.assertRaises(AssertionError, msg=needle):
                check(mutant)

    def test_clear_is_inside_republish_only(self):
        # The ordinary publish keeps its own semantics: it reports a poster
        # problem on success and must not inherit this clear.
        source = APP.read_text()
        publish = block(source, 'func publishTour(listing: Listing,')
        self.assertNotIn(CLEAR, publish)
        self.assertIn('l.lastError = posterProblem', publish)


if __name__ == '__main__':
    unittest.main()
