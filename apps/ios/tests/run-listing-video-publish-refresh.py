#!/usr/bin/env python3
"""Keep the public listing-video card fresh after either publish path succeeds."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SOURCE = ROOT / "apps/ios/Rendprop/Screens/FlythroughDetailView.swift"


def publication_paths(source: str, start: str, end: str) -> tuple[str, str]:
    action = source[source.index(start) : source.index(end, source.index(start))]
    success = action[action.index("do {") : action.index("} catch {")]
    failure = action[action.index("} catch {") :]
    player_refresh = success.index("playerRefresh = UUID()")
    assert success.index("refreshPublishedVideo()") > player_refresh
    return success, failure


source = SOURCE.read_text()
paths = (
    ("private func republishNow()", "private func publishWithSession"),
    ("private func publishWithSession", "private var listingFactsNeedReview"),
)
for start, end in paths:
    success, failure = publication_paths(source, start, end)
    # The old behavior refreshed only the player. Removing the explicit card
    # refresh must fail this check even when the listing slug stays unchanged.
    broken = source.replace(success, success.replace("refreshPublishedVideo()", "", 1), 1)
    try:
        publication_paths(broken, start, end)
    except ValueError:
        pass
    else:
        raise AssertionError(f"Missing card-refresh regression in {start}")

# A republish may commit on the server before the response is lost. Its failure
# path must still read the public selection rather than trusting a stale card.
def assert_republish_failure_refresh(text: str) -> str:
    failure = publication_paths(text, *paths[0])[1]
    error_position = failure.index('republishFailure = AIFailure(error, title: "Couldn\'t republish")')
    assert failure.index("refreshPublishedVideo()") > error_position
    return failure


republish_failure = assert_republish_failure_refresh(source)
broken_failure = source.replace(
    republish_failure, republish_failure.replace("refreshPublishedVideo()", "", 1), 1
)
try:
    assert_republish_failure_refresh(broken_failure)
except ValueError:
    pass
else:
    raise AssertionError("Missing lost-response regression in republishNow")

print("Listing-video card refreshes after publish, republish, and a lost republish response: PASS")
