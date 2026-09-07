#!/usr/bin/env python3
"""narrate_elevenlabs.py — the v2 script's `Say:` lines → one ElevenLabs .mp3 per segment.

    python3 tools/video/narrate_elevenlabs.py --list-voices
    python3 tools/video/narrate_elevenlabs.py \
        --script docs/marketing/onboarding-video-v2/SCRIPT.md --out narration/

Reads `Say:` per segment the same way `build_onboarding.py` does (segment ids
come from `## NN · M:SS–M:SS · Title` headings) and writes `narration/<id>.mp3`
for every segment that has one, plus `narration/durations.json` (via `ffprobe`,
skipped with a note if it is not on PATH). A segment with no `Say:` line (a
silent card) is skipped — nothing to speak.

THE KEY. `--key-file` (default `~/Rendprop AI/_bridge/.elevenlabs-key`) holds
the raw ElevenLabs API key and nothing else. It is read once, held in memory,
sent only as the `xi-api-key` header on api.elevenlabs.io requests, and never
printed, logged, or written anywhere — not even in `--dry-run` or an error
message. Put it there with e.g. `umask 077; echo sk_... > ~/"Rendprop AI"/_bridge/.elevenlabs-key`.

THE VOICE. `--list-voices` prints every voice this key can use — id, name,
category, and its labels — so the owner picks one and pins it with `--voice`.
Left unset, the tool auto-picks the first PREMADE voice whose labels mention
"warm"; ElevenLabs' own catalogue rarely ships one, so in practice this falls
back to a documented calm American narration voice (`FALLBACK_VOICE` below —
"Rachel", the voice docs/VOICEOVER-CONTRACT.md's own example already names).
Voice IDs are not forever — verify with `--list-voices` before a real take.

RESUMING. Existing `narration/<id>.mp3` files are left alone (a partial run —
a daily quota, a network drop — resumes for free); pass `--overwrite` to
redo everything, or `--only 01,02,05` to redo specific segments.

Retries 429 and 5xx with backoff (honouring `Retry-After` on a 429); anything
else (401, 422 — a bad key, a bad voice id) fails immediately with ElevenLabs'
own error message. stdlib only — `urllib`, no `requests`, no SDK.
"""
import argparse, json, os, random, sys, time, urllib.error, urllib.parse, urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from build_onboarding import parse_script, probe  # noqa: E402 — sibling module, same directory

API_BASE = "https://api.elevenlabs.io"
OUTPUT_FORMAT = "mp3_44100_128"           # matches services/supabase/functions/_shared/providers/elevenlabs.ts
DEFAULT_MODEL = "eleven_multilingual_v2"
DEFAULT_KEY_FILE = "~/Rendprop AI/_bridge/.elevenlabs-key"

# A calm, American, narration-friendly premade voice — ElevenLabs' long-standing
# default and the example docs/VOICEOVER-CONTRACT.md's own API sample names.
# Voice catalogues change; treat this as a last resort, not a promise it still
# exists on any given account — `--list-voices` is the source of truth.
FALLBACK_VOICE_ID = "21m00Tcm4TlvDq8ikWAM"
FALLBACK_VOICE_NAME = "Rachel (documented fallback — verify with --list-voices)"


def read_api_key(path):
    """The raw key, and nothing else — never returned alongside the path or
    logged by a caller. A missing/empty file is a fatal, actionable error that
    never echoes what (if anything) was in it."""
    full = os.path.expanduser(path)
    if not os.path.isfile(full):
        sys.exit("no ElevenLabs key at %s — put the raw key in that file (nothing else) and re-run.\n"
                  "  umask 077; echo sk_your_key_here > %s" % (path, path))
    with open(full, "r", encoding="utf-8") as f:
        key = f.read().strip()
    if not key:
        sys.exit("%s exists but is empty — put the raw ElevenLabs key in it." % path)
    return key


def http_request(url, key, method="GET", body=None, accept=None, timeout=60):
    """One HTTP call. Returns (status, bytes). Raises urllib.error.HTTPError /
    URLError on failure — callers decide what is retryable."""
    headers = {"xi-api-key": key}
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
        headers["Content-Type"] = "application/json"
    if accept:
        headers["Accept"] = accept
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.status, resp.read()


def with_retries(fn, retries, base_delay, what):
    """Call fn() with no args; retry 429/5xx and network errors with backoff
    (honouring a 429's Retry-After when present). Anything else — a bad key, a
    bad voice id, a validation error — fails on the first try with ElevenLabs'
    own message, since retrying it would only waste quota."""
    attempt = 0
    while True:
        try:
            return fn()
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", "replace")[:500]
            retryable = e.code == 429 or e.code >= 500
            if not retryable or attempt >= retries:
                sys.exit("%s failed: HTTP %d — %s" % (what, e.code, detail))
            delay = None
            retry_after = e.headers.get("Retry-After") if e.headers else None
            if retry_after:
                try:
                    delay = float(retry_after)
                except ValueError:
                    delay = None
            if delay is None:
                delay = min(30.0, base_delay * (2 ** attempt)) + random.uniform(0, 0.5)
            print("WARN %s: HTTP %d (attempt %d/%d) — retrying in %.1fs" % (what, e.code, attempt + 1, retries, delay))
            time.sleep(delay)
            attempt += 1
        except urllib.error.URLError as e:
            if attempt >= retries:
                sys.exit("%s failed: %s" % (what, e.reason))
            delay = min(30.0, base_delay * (2 ** attempt)) + random.uniform(0, 0.5)
            print("WARN %s: %s (attempt %d/%d) — retrying in %.1fs" % (what, e.reason, attempt + 1, retries, delay))
            time.sleep(delay)
            attempt += 1


def list_voices(key, retries=3, base_delay=1.0):
    """[{voice_id, name, category, labels}] for every voice this key can use."""
    status, body = with_retries(lambda: http_request(API_BASE + "/v1/voices", key), retries, base_delay, "list voices")
    doc = json.loads(body.decode("utf-8"))
    return doc.get("voices", [])


def pick_default_voice(voices):
    """(voice_id, name, note) — the first premade voice labelled "warm", else
    the documented fallback."""
    for v in voices:
        if v.get("category") != "premade":
            continue
        labels = v.get("labels") or {}
        values = " ".join(str(x) for x in labels.values()).lower()
        if "warm" in values:
            return v.get("voice_id"), v.get("name", "?"), "auto-picked: premade, labelled warm"
    return FALLBACK_VOICE_ID, FALLBACK_VOICE_NAME, "fallback: no premade \"warm\" voice on this account"


def resolve_voice(key, explicit, retries, base_delay):
    """(voice_id, name, note). An explicit --voice never touches the network —
    the owner already knows what they picked, and this must also work with no
    key file at all (a --voice --dry-run preview). Otherwise this fetches the
    real catalogue (the key file must still exist; only the API call itself is
    allowed to fail here) so a preview shows the SAME voice a real run would
    pick — a fetch failure (offline, a stale key) falls back to the documented
    voice rather than blocking the plan from printing, but says so loudly
    either way, dry run or not."""
    if explicit:
        return explicit, explicit, "explicit --voice"
    try:
        return pick_default_voice(list_voices(key, retries, base_delay))
    except SystemExit as e:
        print("WARN could not fetch the voice catalogue (%s) — falling back to the documented voice; "
              "pass --voice to pin one explicitly." % e)
        return FALLBACK_VOICE_ID, FALLBACK_VOICE_NAME, "fallback: voice catalogue fetch failed"


def synthesize(key, voice_id, model_id, text, voice_settings, retries, base_delay):
    """The mp3 bytes for one line."""
    url = "%s/v1/text-to-speech/%s?output_format=%s" % (API_BASE, urllib.parse.quote(voice_id, safe=""), OUTPUT_FORMAT)
    body = {"text": text, "model_id": model_id, "voice_settings": voice_settings}
    what = "synthesize (%d chars)" % len(text)
    status, audio = with_retries(lambda: http_request(url, key, method="POST", body=body, accept="audio/mpeg"),
                                 retries, base_delay, what)
    return audio


def select_segments(script, only=None):
    """(segments, warnings). `segments` is [(id, say)] in id order for every
    parsed segment with a non-blank Say: line — a silent card (no Say:) is
    never included, nothing else decides that. `only`, if given, is an
    iterable of ids to keep; an id it names that is not in the result (no
    Say: line, or not in the script at all) comes back as a warning string
    rather than failing outright, since the other ids may still be worth
    running."""
    segments = [(sid, s["say"].strip()) for sid, s in sorted(script.items()) if s.get("say", "").strip()]
    warnings = []
    if only:
        wanted = {x.strip() for x in only if x.strip()} if not isinstance(only, str) else \
                 {x.strip() for x in only.split(",") if x.strip()}
        segments = [(sid, say) for sid, say in segments if sid in wanted]
        missing = wanted - {sid for sid, _ in segments}
        if missing:
            warnings.append("--only names segment(s) with no Say: line (or not in the script): %s"
                            % ", ".join(sorted(missing)))
    return segments, warnings


def build_plan(segments, out_dir, overwrite):
    """[(id, say, path, skip)] — `skip` is True for a segment whose mp3 already
    exists and `overwrite` was not asked for."""
    plan = []
    for sid, say in segments:
        path = os.path.join(out_dir, "%s.mp3" % sid)
        exists = os.path.exists(path)
        plan.append((sid, say, path, exists and not overwrite))
    return plan


def collect_durations(out_dir, ids):
    """{id: seconds} via ffprobe for every narration/<id>.mp3 that exists — or
    {} with a note if ffprobe is not on PATH (the build still works either way;
    it only uses durations.json as a quick eyeball, not an input)."""
    import shutil
    if not shutil.which("ffprobe"):
        print("NOTE ffprobe not on PATH — durations.json will be empty; build_onboarding.py probes each file itself")
        return {}
    out = {}
    for sid in ids:
        path = os.path.join(out_dir, "%s.mp3" % sid)
        if os.path.exists(path):
            out[sid] = round(probe(path)["duration"], 3)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--key-file", default=DEFAULT_KEY_FILE, help="path to a file holding only the raw API key")
    ap.add_argument("--list-voices", action="store_true", help="print every voice this key can use, then exit")
    ap.add_argument("--script", help="the .md script (SCRIPT.md) — required unless --list-voices")
    ap.add_argument("--out", default="narration", help="output dir for <id>.mp3 + durations.json")
    ap.add_argument("--voice", help="an ElevenLabs voice id; default: first premade voice labelled \"warm\", "
                                    "else the documented fallback (see --list-voices)")
    ap.add_argument("--model", default=DEFAULT_MODEL)
    ap.add_argument("--stability", type=float, default=0.5)
    ap.add_argument("--similarity", type=float, default=0.75, help="similarity_boost")
    ap.add_argument("--style", type=float, default=0.05, help="low by design — a coach, not a performance")
    ap.add_argument("--speaker-boost", dest="speaker_boost", action="store_true", default=True)
    ap.add_argument("--no-speaker-boost", dest="speaker_boost", action="store_false")
    ap.add_argument("--only", help="comma-separated segment ids to (re)generate, e.g. 01,02,05")
    ap.add_argument("--overwrite", action="store_true", help="regenerate a segment even if its mp3 already exists")
    ap.add_argument("--retries", type=int, default=5)
    ap.add_argument("--retry-delay", type=float, default=2.0, help="base seconds for exponential backoff")
    ap.add_argument("--sleep", type=float, default=0.3, help="politeness delay between successive calls")
    ap.add_argument("--dry-run", action="store_true", help="print the plan — voice, model, per-segment status — call nothing")
    a = ap.parse_args()

    if a.list_voices:
        key = read_api_key(a.key_file)
        voices = list_voices(key, a.retries, a.retry_delay)
        print("%-22s %-24s %-10s %s" % ("voice_id", "name", "category", "labels"))
        for v in voices:
            labels = ", ".join("%s=%s" % (k, val) for k, val in (v.get("labels") or {}).items())
            print("%-22s %-24s %-10s %s" % (v.get("voice_id", "?"), v.get("name", "?")[:24],
                                            v.get("category", "?"), labels))
        return

    if not a.script:
        sys.exit("--script is required (or pass --list-voices on its own)")
    if not os.path.exists(a.script):
        sys.exit("missing --script: %s" % a.script)

    script = parse_script(a.script)
    segments, seg_warnings = select_segments(script, a.only)
    for w in seg_warnings:
        print("WARN " + w)
    if not segments:
        sys.exit("no segment in %s has a Say: line — nothing to narrate" % a.script)

    # The key file itself must exist even for a preview UNLESS --voice is also
    # given (then nothing here ever touches the network or the key).
    key = None if (a.dry_run and a.voice) else read_api_key(a.key_file)
    voice_id, voice_name, voice_note = resolve_voice(key, a.voice, a.retries, a.retry_delay)
    voice_settings = {"stability": a.stability, "similarity_boost": a.similarity, "style": a.style,
                      "use_speaker_boost": a.speaker_boost}

    os.makedirs(a.out, exist_ok=True)
    print("voice: %s (%s) — %s" % (voice_id, voice_name, voice_note))
    print("model: %s   settings: %s" % (a.model, voice_settings))
    plan = build_plan(segments, a.out, a.overwrite)
    for sid, say, path, skip in plan:
        exists = os.path.exists(path)
        words = len(say.split())
        status = "SKIP (exists)" if skip else ("OVERWRITE" if exists else "generate")
        print("%-4s %3d words  %-13s %s" % (sid, words, status, say[:72] + ("…" if len(say) > 72 else "")))

    if a.dry_run:
        print("DRY RUN — no ElevenLabs calls made, nothing written.")
        return

    made = []
    for sid, say, path, skip in plan:
        if skip:
            continue
        audio = synthesize(key, voice_id, a.model, say, voice_settings, a.retries, a.retry_delay)
        with open(path, "wb") as f:
            f.write(audio)
        print("OK %s  %d bytes -> %s" % (sid, len(audio), path))
        made.append(sid)
        if a.sleep > 0 and sid != plan[-1][0]:
            time.sleep(a.sleep)

    durations = collect_durations(a.out, [sid for sid, *_ in plan])
    with open(os.path.join(a.out, "durations.json"), "w", encoding="utf-8") as f:
        json.dump(durations, f, indent=2, sort_keys=True)
    print("wrote %s (%d file(s) generated, %d already had an mp3)"
          % (os.path.join(a.out, "durations.json"), len(made), len(plan) - len(made)))


if __name__ == "__main__":
    main()
