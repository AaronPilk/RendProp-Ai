#!/usr/bin/env python3
"""
Short, URL-safe, collision-resistant slugs for public tour URLs: /f/{slug}.

nanoid-style: cryptographically-random picks from a curated alphabet. We drop
look-alike characters (0/O, 1/l/I) so a slug read off a screen or said out loud
doesn't get mistyped. 10 chars over a 57-symbol alphabet ≈ 57^10 ≈ 3.6e17 keyspace
— plenty for tour URLs, and the DB's UNIQUE(slug) plus a retry loop in db.py
makes an actual collision a non-event.
"""

from __future__ import annotations

import secrets

# No 0 O o, 1 l I — unambiguous when read aloud / typed.
_ALPHABET = "23456789abcdefghijkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ"


def new_slug(size: int = 10) -> str:
    return "".join(secrets.choice(_ALPHABET) for _ in range(size))
