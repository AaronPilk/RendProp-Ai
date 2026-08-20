#!/usr/bin/env python3
"""
Rendprop AI cost-test CLI — answers "what will the AI cost?" without standing up
the whole stack.

  # Projected cost of a fully-enhanced 8-room listing (pure math, no keys needed):
  python cli.py estimate --rooms 8 --declutter --restage --hero

  # One REAL provider call (needs the relevant key) + a cost_ledger row:
  python cli.py run --image room.jpg --feature restage --style modern
  python cli.py run --image room.jpg --feature declutter --mask mask.png
  python cli.py run --image room.jpg --feature hero --seconds 5

  # Just show what a single call WOULD cost (no API call):
  python cli.py run --image room.jpg --feature restage --style modern --dry-run

Estimates come straight from providers/costs.py (the single unit-cost table).
A real `run` prints the ACTUAL billed cost (token-based for QC) and, if
SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY are set, writes the ledger row + rolls
up render_jobs.cost_cents.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import router
from config import SETTINGS, STYLES, style_prompt
from cost_ledger import CostLedger
from providers import costs
from providers.base import ProviderError
from router import BudgetExceeded, JobBudget, JobContext

HERO_MOTION = ("smooth steady walkthrough glide forward through the room, cinematic "
               "gimbal motion, keep the room geometry and architecture identical")


def _money(cents: float) -> str:
    return f"${cents/100:,.4f}"


# ── estimate ──────────────────────────────────────────────────────────────────

def cmd_estimate(args: argparse.Namespace) -> None:
    declutter, restage, hero = args.declutter, args.restage, args.hero
    if not (declutter or restage or hero):
        declutter = restage = hero = True  # default: the fully-enhanced bundle

    br = costs.estimate_job(
        rooms=args.rooms, declutter=declutter, restage=restage, hero=hero,
        hero_seconds=args.hero_seconds, restage_route=args.route, qc_model=args.qc_model,
    )

    print(f"\nRendprop AI cost estimate — {args.rooms} room(s), route='{args.route}'\n")
    print(f"  {'feature':<11}{'units':>8}{'¢/unit':>12}{'total':>16}")
    print("  " + "-" * 46)
    for l in br["lines"]:
        print(f"  {l['feature']:<11}{l['units']:>8}{l['unit_cost_cents']:>12.4f}"
              f"{_money(l['total_cents']):>16}")
    print("  " + "-" * 46)
    print(f"  {'TOTAL':<11}{'':>8}{'':>12}{_money(br['total_cents']):>16}")
    print(f"\n  Per-listing AI COGS: {_money(br['total_cents'])} "
          f"(cap is MAX_GEN_COST_PER_JOB_CENTS = {_money(SETTINGS.max_gen_cost_per_job_cents)})")

    over = br["total_cents"] > SETTINGS.max_gen_cost_per_job_cents
    if over:
        print("  ⚠ Estimate EXCEEDS the per-job cap — the router would abort mid-job.")

    # Context vs add-on pricing (declutter +$19, restage +$49).
    addon = (1900 if declutter else 0) + (4900 if restage else 0)
    if addon:
        pct = 100 * br["total_cents"] / addon
        print(f"  vs add-on price {_money(addon)} → COGS is {pct:.1f}% of revenue.")
    print("\n  Note: QC lines use the flat pre-call estimate; a real `run` bills QC")
    print("  from actual Claude token usage (prompt-cached rubric = cheaper still).\n")


# ── run (one real call) ───────────────────────────────────────────────────────

def _single_estimate_cents(feature: str, args: argparse.Namespace) -> float:
    if feature == "restage":
        return costs.restage_cost_cents(args.route)
    if feature == "declutter":
        return costs.declutter_cost_cents() if args.mask else costs.restage_cost_cents("gemini")
    if feature == "hero":
        return costs.hero_cost_cents(args.seconds)
    raise SystemExit(f"Unknown feature '{feature}'")


def cmd_run(args: argparse.Namespace) -> None:
    feature = args.feature
    image_path = Path(args.image)
    if not image_path.exists():
        sys.exit(f"Image not found: {image_path}")

    est = _single_estimate_cents(feature, args)
    print(f"\n{feature} on {image_path.name} — estimated {_money(est)} "
          f"(route='{args.route}')")

    if args.dry_run:
        print("  --dry-run: no API call made.\n")
        return

    ctx = JobContext(job_id=args.job_id, org_id=args.org_id,
                     budget=JobBudget(SETTINGS.max_gen_cost_per_job_cents),
                     ledger=CostLedger(), restage_route=args.route)
    ctx.hydrate_budget()
    if not ctx.ledger.enabled:
        print("  (no SUPABASE_URL/SERVICE_ROLE_KEY → ledger runs local; cost still printed)")

    image = image_path.read_bytes()
    try:
        if feature == "restage":
            if not args.style:
                sys.exit("restage needs --style modern|rustic|minimalist|scandinavian")
            res = router.restage(ctx, image, style_prompt(args.style))
            _save(res.data, image_path, "restage", args)
        elif feature == "declutter":
            mask = Path(args.mask).read_bytes() if args.mask else None
            res = router.declutter(ctx, image, mask)
            _save(res.data, image_path, "declutter", args)
        elif feature == "hero":
            res = router.hero_clip(ctx, image, HERO_MOTION, args.seconds)
            _save(res.data, image_path, "hero", args, ext="mp4")
        else:
            sys.exit(f"--feature must be restage|declutter|hero (got {feature})")
    except BudgetExceeded as e:
        sys.exit(f"Aborted by cost cap: {e}")
    except ProviderError as e:
        sys.exit(f"\nProvider error (is the right API key set?):\n  {e}\n")

    print(f"  ACTUAL cost: {_money(res.total_cents)}  "
          f"[{res.provider}/{res.model}, units={res.units}]")
    print(f"  job spend now {_money(ctx.budget.spent_cents)} / "
          f"cap {_money(ctx.budget.ceiling_cents)}")
    print(f"  ledger: {'wrote row to Supabase' if ctx.ledger.enabled else 'local only'} "
          f"({len(ctx.ledger.rows)} row this run)\n")


def _save(data: bytes, src: Path, feature: str, args: argparse.Namespace, ext: str = "jpg") -> None:
    out = Path(args.out) if args.out else src.with_name(f"{src.stem}-{feature}.{ext}")
    out.write_bytes(data)
    print(f"  output → {out}  ({len(data):,} bytes)")


# ── argparse ──────────────────────────────────────────────────────────────────

def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description="Rendprop AI cost-test CLI")
    sub = ap.add_subparsers(dest="cmd", required=True)

    est = sub.add_parser("estimate", help="projected cost from the unit-cost table")
    est.add_argument("--rooms", type=int, default=8)
    est.add_argument("--declutter", action="store_true")
    est.add_argument("--restage", action="store_true")
    est.add_argument("--hero", action="store_true")
    est.add_argument("--hero-seconds", type=int, default=5)
    est.add_argument("--route", default=SETTINGS.restage_route, choices=["gemini", "fal", "kie"])
    est.add_argument("--qc-model", default=SETTINGS.anthropic_model_qc)
    est.set_defaults(func=cmd_estimate)

    run = sub.add_parser("run", help="one real provider call + cost + ledger row")
    run.add_argument("--image", required=True)
    run.add_argument("--feature", required=True, choices=["restage", "declutter", "hero"])
    run.add_argument("--style", choices=list(STYLES), default=None)
    run.add_argument("--mask", default=None, help="declutter mask (white = clutter)")
    run.add_argument("--seconds", type=int, default=5, help="hero clip length (2–12)")
    run.add_argument("--route", default=SETTINGS.restage_route, choices=["gemini", "fal", "kie"])
    run.add_argument("--out", default=None)
    run.add_argument("--job-id", default=None)
    run.add_argument("--org-id", default=None)
    run.add_argument("--dry-run", action="store_true")
    run.set_defaults(func=cmd_run)
    return ap


def main() -> None:
    args = build_parser().parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
