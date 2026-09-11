#!/usr/bin/env python3
"""Offline, actual-source EDL measurement; never a route-budget migration.

Requires pinned tiktoken 0.14.0 and a prepopulated TIKTOKEN_CACHE_DIR. See the
handoff for the isolated setup command. Network is denied here, including a
forgotten tokenizer download. o200k_base is a documented proxy, NOT an invented
mapping for Astra: tiktoken's model resolver does not currently recognise it.
"""
from __future__ import annotations

import hashlib
import argparse
import importlib.metadata
import json
import os
from pathlib import Path
import socket
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]
SOURCE_PATHS = [
    "tools/audit/agent_reel_headroom_fixture.ts",
    "tools/audit/measure_agent_reel_headroom.py",
    "services/supabase/functions/ai-copy/agentreel.ts",
    "services/supabase/functions/ai-copy/shotlist.ts",
    "services/supabase/functions/ai-copy/prompt.ts",
    "services/supabase/functions/ai-copy/index.ts",
    "services/supabase/functions/_shared/providers/openai.ts",
    "services/supabase/functions/_shared/providers/params.ts",
    "services/supabase/migrations/0034_agent_reel_and_video_ladder.sql",
    "services/supabase/tests/invariants.sql",
]
ASSERTIONS = 0


def check(ok: object, message: str) -> None:
    global ASSERTIONS
    ASSERTIONS += 1
    if not ok:
        raise AssertionError(message)


def deny_network(*_args: object, **_kwargs: object) -> None:
    raise AssertionError("measurement attempted a network connection; preload the public tokenizer data first")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assert-current-ceiling", action="store_true",
                        help="negative gate: fail if any measured canonical model JSON cannot fit the current700-token ceiling")
    args = parser.parse_args()
    source_before = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in SOURCE_PATHS}
    command = ["deno", "run", "--cached-only", "--no-config", "--no-lock", "--node-modules-dir=manual",
               "--deny-net", "--deny-env", "--deny-run", "--deny-write", "tools/audit/agent_reel_headroom_fixture.ts"]
    result = subprocess.run(command, cwd=ROOT, capture_output=True, text=True, timeout=30, check=False,
                            env={"PATH": os.environ.get("PATH", "/opt/homebrew/bin:/usr/bin:/bin")})
    if result.returncode:
        raise RuntimeError(f"fixture exit {result.returncode}: {result.stderr.strip()}")
    data = json.loads(result.stdout)
    check(data["schema_version"] == 1, "unsupported measurement fixture schema")
    check(len(data["fixtures"]) == 11, "all eleven actual-parser fixture scenarios must execute")
    check(data["caps"] == {"clip_seconds": 180, "transcript_phrases": 200, "phrase_chars": 200,
                          "offered_photos": 20, "windows": 12, "photo_id_code_units": 64, "caption_code_units": 28},
          "production shape contract changed")

    # Preload is a separate read-only public package/data download, never a
    # request to a model endpoint. The actual measurement must run offline.
    check(bool(os.environ.get("TIKTOKEN_CACHE_DIR")), "explicit tokenizer cache directory required")
    socket.socket = deny_network  # type: ignore[assignment]
    socket.create_connection = deny_network  # type: ignore[assignment]
    import tiktoken
    import tiktoken.model

    check(importlib.metadata.version("tiktoken") == "0.14.0", "use the reviewed tokenizer version, not a floating install")
    try:
        astra_encoding = tiktoken.encoding_name_for_model("gpt-6-astra")
    except KeyError:
        astra_encoding = None
    check(astra_encoding is None, "Astra mapping changed: replace the proxy disclosure after independent review")
    encoding = tiktoken.get_encoding("o200k_base")
    check(all(bytes([i]) in encoding._mergeable_ranks for i in range(256)), "byte fallback must exist for the canonical-byte upper bound")

    def tokens(text: str) -> int:
        encoded = encoding.encode(text, disallowed_special=())
        check(encoding.decode(encoded) == text, "tokenizer must exactly round-trip every measured string")
        check(len(encoded) <= len(text.encode("utf-8")), "byte-fallback token bound was violated")
        return len(encoded)

    rows = []
    for specimen in data["fixtures"]:
        check(specimen["windows"] == 12, "every measurement must use actual twelve-window planning")
        check(all(0 < n <= 64 for n in specimen["photo_id_code_units"]), "offered IDs must obey actual input cap")
        raw = specimen["model_response"]
        row = {"name": specimen["name"], "kind": specimen["kind"], "filled_windows": specimen["filled"],
               "model_json_utf8_bytes": len(raw.encode("utf-8")), "model_json_o200k_tokens": tokens(raw),
               "http_json_utf8_bytes": len(specimen["enriched_http_response"].encode("utf-8")),
               "http_json_o200k_tokens": tokens(specimen["enriched_http_response"]),
               "input_text_o200k_tokens": tokens(specimen["provider_input_text"]),
               "model_json_sha256": hashlib.sha256(raw.encode("utf-8")).hexdigest(),
               "http_json_sha256": hashlib.sha256(specimen["enriched_http_response"].encode("utf-8")).hexdigest()}
        # Illustrative STANDARD text-token prices, not provider usage receipts:
        # $10/M input =>0.001 cents/token; $50/M output =>0.005 cents/token.
        row["proxy_input_cents_at_astra_standard_price"] = round(row["input_text_o200k_tokens"] * 0.001, 6)
        row["proxy_visible_output_cents_at_astra_standard_price"] = round(row["model_json_o200k_tokens"] * 0.005, 6)
        rows.append(row)

    canonical = [r for r in rows if r["kind"].startswith("canonical")]
    largest = max(canonical, key=lambda r: r["model_json_o200k_tokens"])
    check(largest["model_json_o200k_tokens"] > 700, "negative control: 700 must not be reported sufficient for all measured legal shapes")
    check(max(r["model_json_utf8_bytes"] for r in canonical) == data["canonical_model_byte_bound"] == 6268,
          "actual canonical sample must reach the mathematical byte bound")
    base = next(r for r in rows if r["name"] == "bmp_64_ids_28_bmp_caption_12")
    padded = [r for r in rows if r["kind"] == "raw_shape_has_no_whitespace_bound"]
    check(all(r["http_json_sha256"] == base["http_json_sha256"] for r in padded), "padding must not change the parsed EDL")
    check(all(a["model_json_o200k_tokens"] < b["model_json_o200k_tokens"] for a, b in zip(padded, padded[1:])),
          "increasing accepted raw padding must demonstrably increase the measured token count")
    proposal = data["compact_proposal"]
    compact_tokens = tokens(proposal["canonical"])
    compact_bytes = len(proposal["canonical"].encode("ascii"))
    check(compact_tokens <= compact_bytes == 160 < 700, "proposed canonical compact output must fit below700 without dropping window IDs")
    source_after = {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in SOURCE_PATHS}
    check(source_before == source_after, "source changed during measurement")
    report = {
        "schema_version": 1, "accepted_measurement": True, "provider_calls": 0,
        "budget_or_invariant_changed": False,
        "scope": "offline exact o200k_base string counts; NOT Astra billing tokens, hidden reasoning, live generation, or a proven raw-output maximum",
        "command": command, "fixture_exit_code": result.returncode,
        "fixture_assertions": data["assertions"], "measurement_assertions": ASSERTIONS,
        "executed_fixture_scenarios": len(rows), "skipped": 0,
        "source_commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "source_sha256": source_after, "runtime": {"python": sys.version.split()[0], **data["runtime"]},
        "tokenizer": {"package": "tiktoken", "version": importlib.metadata.version("tiktoken"), "encoding": encoding.name,
                      "astra_model_mapping": astra_encoding,
                      "model_mapping_sha256": hashlib.sha256(Path(tiktoken.model.__file__).read_bytes()).hexdigest(),
                      "mergeable_ranks": len(encoding._mergeable_ranks),
                      "cache_file_sha256": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(Path(os.environ["TIKTOKEN_CACHE_DIR"]).iterdir()) if p.is_file()}},
        "caps": data["caps"], "measurements": rows,
        "largest_measured_canonical": largest["name"],
        "largest_measured_canonical_o200k_tokens": largest["model_json_o200k_tokens"],
        "canonical_model_utf8_byte_bound": data["canonical_model_byte_bound"],
        "all_measured_canonical_outputs_fit_current700": largest["model_json_o200k_tokens"] < 700,
        "compact_proposal": {**proposal, "canonical_utf8_bytes": compact_bytes, "canonical_o200k_tokens": compact_tokens,
                             "raw_whitespace_and_reasoning_not_bounded_by_shape": True},
    }
    if args.assert_current_ceiling:
        check(largest["model_json_o200k_tokens"] < 700,
              f"current700-token ceiling is not sufficient: legal canonical model JSON measured{largest['model_json_o200k_tokens']} o200k tokens before reasoning (proxy, not Astra billing)")
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"FAIL agent-reel measurement after {ASSERTIONS} assertions: {error}", file=sys.stderr)
        raise SystemExit(1)
