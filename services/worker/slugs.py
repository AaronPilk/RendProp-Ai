#!/usr/bin/env python3
"""
Short, URL-safe, collision-resistant slugs for public tour URLs: /f/{slug}.

nanoid-style: cryptographically-random picks from a curated alphabet. We drop
look-alike characters (0/O/o, 1/l/I) so a slug read off a screen or said out loud
doesn't get mistyped. 10 chars over the 56-symbol alphabet ≈ 56^10 ≈ 3.0e17
keyspace — plenty for tour URLs, and the DB's UNIQUE(slug) plus a retry loop in
db.py makes an actual collision a non-event. (Audit F-G-23: the docstring said 57
and the alphabet has always had 56.)

CASE NOTE: these slugs are MIXED case, while `publish_render` (0008:241) mints
lowercase-only ones. Both are unique and both work, but `/f/{slug}` lookups are
case-sensitive, so a mixed-case slug is materially harder to read aloud or retype
than the app path's. If tours are ever meant to be dictated, unify on lowercase
(and keep the alphabet at least 32 symbols to hold the keyspace).
"""

from __future__ import annotations

import secrets

# No 0 O o, 1 l I — unambiguous when read aloud / typed.
_ALPHABET = "23456789abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ"


def new_slug(size: int = 10) -> str:
    return "".join(secrets.choice(_ALPHABET) for _ in range(size))
