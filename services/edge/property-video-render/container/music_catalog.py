"""Closed commercial-export CC0 catalog; no client-supplied tracks or URLs."""
CATALOG = {
    "calm": {
        "asset_sha256": "9503b0d6d59cdc76f69f786b6f2fd2fb6f39a747e245e8f02dc358b7fd4dbb36",
        "license_evidence_sha256": "8a5d6e54d255e734a434dbb63abb7fbcf759eb619be6735c123f467d444a9074",
        "credit": "First Light Particles — Yoiyami (CC0-1.0)",
    },
    "upbeat": {
        "asset_sha256": "ce55346893354d49746c689b3dde135ec1f3d9299d22ef8ec26b27a022020375",
        "license_evidence_sha256": "fa5b82351abf48b8b0877b1c10ed5163f3243a2cd7781c3b02dcb72ae4d26e27",
        "credit": "Scaling Up — Ruskerdax (CC0-1.0)",
    },
    "cinematic": {
        "asset_sha256": "119eaedb3c58948d6f6b346ec61aac58fa28174658714e06a6a5b8d0ec11bdc8",
        "license_evidence_sha256": "5f83d54c6e0d67b855d772f12615fe668c6678dc551cf1a95f382e96d89e3a45",
        "credit": "At Home - Orchestral — Wolfgang_ (CC0-1.0)",
    },
}


def validate_music(value):
    if value is None:
        return None
    track = CATALOG.get(value.get("track_id"))
    if (not track or value.get("asset_sha256") != track["asset_sha256"]
            or value.get("license_id") != "CC0-1.0"
            or value.get("license_evidence_sha256") != track["license_evidence_sha256"]
            or value.get("gain") != .18 or value.get("duck_gain") != .07):
        raise ValueError("unapproved_music")
    return track
