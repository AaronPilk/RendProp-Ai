#!/usr/bin/env python3
"""Offline, provisional Gaussian-count planning for the pinned Phase A runner.

This performs bounded integer/float arithmetic only. It does not read captures,
change training settings, import CUDA, spawn processes, or contact a service.
Supply the actual initial_points from a validated adapter report, not the number
of images or raw feature observations. A count estimate is not capture approval.
"""

import argparse
import json
import sys


GSPLAT_COMMIT = "937e29912570c372bed6747a5c9bf85fed877bae"
SOURCE_ROOT = f"https://github.com/nerfstudio-project/gsplat/blob/{GSPLAT_COMMIT}"
REFINE_START = 500
REFINE_STOP = 25000
REFINE_EVERY = 100
DISCLAIMER = (
    "upper bound under ideal growth, not a prediction of converged quality/VRAM/cost"
)


class GrowthInputError(ValueError):
    """Invalid or out-of-scope planning inputs."""


def _bounded_integer(value, name, lower, upper):
    # bool is an int subclass. Do not coerce strings, floats, NaN, or subclasses
    # with user-defined arithmetic into an apparently legitimate count.
    if type(value) is not int or not lower <= value <= upper:
        raise GrowthInputError(f"{name} must be an integer in {lower}–{upper}")


def _refines_at(step):
    """Pinned MCMC predicate; step is an internal zero-based loop index."""
    return REFINE_START < step < REFINE_STOP and step % REFINE_EVERY == 0


def estimate_growth(initial_seeds, max_steps=3000, max_gaussians=500000):
    """Return count bounds for one fresh, single-GPU run with steps_scaler=1.

    Bounds match run_training.py; this does not relax its seed/cap/run limits.
    Relocation preserves count. Successful sample_add appends the requested
    count; failures, early termination and export filtering are not simulated.
    """
    _bounded_integer(initial_seeds, "initial_seeds", 100, 500000)
    _bounded_integer(max_steps, "max_steps", 1, 7000)
    _bounded_integer(max_gaussians, "max_gaussians", 100, 500000)
    if initial_seeds > max_gaussians:
        raise GrowthInputError("initial_seeds cannot exceed max_gaussians")

    count = initial_seeds
    events = []
    final_artifact_count = initial_seeds
    artifact_events = 0
    for step in range(max_steps):
        # simple_trainer saves the final stats/checkpoint/PLY before that
        # iteration's optimizer and MCMC post-backward refinement. Do not
        # accidentally count a final-step addition in the saved artifact.
        if step == max_steps - 1:
            final_artifact_count = count
            artifact_events = len(events)
        if _refines_at(step):
            previous = count
            # Match upstream Python float multiplication + int truncation at
            # EACH event, not round(), a geometric power, or an integer ratio.
            count = min(max_gaussians, int(1.05 * count))
            events.append({"step_zero_based": step, "before": previous,
                           "after_upper_bound": count, "added_upper_bound": count - previous})

    return {
        "status": "provisional_offline_arithmetic_only",
        "interpretation": DISCLAIMER,
        "gsplat_version": "1.5.3",
        "gsplat_commit": GSPLAT_COMMIT,
        "sources": {
            "schedule_and_growth": f"{SOURCE_ROOT}/gsplat/strategy/mcmc.py#L108-L170",
            "relocation_and_addition": f"{SOURCE_ROOT}/gsplat/strategy/ops.py#L223-L309",
            "save_before_refinement": f"{SOURCE_ROOT}/examples/simple_trainer.py#L700-L824",
        },
        "assumptions": {
            "runner": "run_training.py; fresh sfm initialization; one GPU; no resume",
            "initial_seed_input": "actual adapter-report.json initial_points; not frame/observation count",
            "steps_scaler": 1.0,
            "refine_start_iter_exclusive": REFINE_START,
            "refine_stop_iter_exclusive": REFINE_STOP,
            "refine_every": REFINE_EVERY,
            "loop": "zero-based range(max_steps)",
            "per_event": "min(max_gaussians, int(1.05 * current_count)); Python float then int",
            "save_order": "final stats/checkpoint/PLY before final iteration refinement",
            "ideal_growth": "every scheduled relocation/addition succeeds; no early termination",
            "quality": "seed count/coverage/accuracy and convergence are not evaluated",
        },
        "initial_seeds": initial_seeds,
        "max_steps": max_steps,
        "max_gaussians": max_gaussians,
        "refinement_events": len(events),
        "effective_growth_events": sum(event["added_upper_bound"] > 0 for event in events),
        "final_artifact_refinement_events": artifact_events,
        "final_artifact_gaussians_upper_bound": final_artifact_count,
        "training_peak_gaussians_upper_bound": count,
        "final_artifact_step_zero_based": max_steps - 1,
        "events": events,
        "not_proved": ["capture validity", "reconstruction quality", "geometric accuracy",
                       "VRAM", "runtime", "cost", "successful GPU execution"],
    }


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        # argparse normally exits 2. All invalid planning inputs must exit 1.
        raise GrowthInputError(message)


def _cli_integer(value):
    # Reject huge/nonfinite inputs before conversion. All supported counts fit
    # in six ASCII decimal digits; signs/exponents/fractions are not counts.
    if not 1 <= len(value) <= 6 or not value.isascii() or not value.isdecimal():
        raise argparse.ArgumentTypeError("expected at most six ASCII decimal digits")
    return int(value)


def main(argv=None):
    parser = _Parser(description=__doc__, allow_abbrev=False)
    parser.add_argument("--initial-seeds", type=_cli_integer, required=True)
    parser.add_argument("--max-steps", type=_cli_integer, default=3000)
    parser.add_argument("--max-gaussians", type=_cli_integer, default=500000)
    try:
        args = parser.parse_args(argv)
        result = estimate_growth(args.initial_seeds, args.max_steps, args.max_gaussians)
        print(json.dumps(result, indent=2, allow_nan=False))
        return 0
    except GrowthInputError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
