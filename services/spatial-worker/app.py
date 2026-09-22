"""Deployable cloud scheduler. Importing this file allocates NO GPU or job.

Deployment is a separate release gate: configured operational budgets, service
authentication, provider billing headroom and a real-room acceptance run first.
"""
import os
from pathlib import Path
import modal

# Modal reimports this module at /root/app.py inside the container. That path
# has no parents[2]; uploaded worker sources deliberately live at /workspace.
REPO = Path(__file__).resolve().parents[2] if modal.is_local() else Path("/workspace")
APP_NAME = "rendprop-spatial-worker"
# A disabled deployment must stay disabled even if an existing named Secret has
# an old ENABLED=true value. Runtime activation is a separate reviewed release.
DEPLOYMENT_ENABLED = False
app = modal.App(APP_NAME)
# Reuse the experiment's content-addressed base rather than floating latest.
image = (modal.Image.from_registry(
    "pytorch/pytorch@sha256:3d614dfd422b7e43647491cbf07d6acc516c032fc49c594a94afdebd52552fb9")
    .pip_install("modal==1.5.3", "Pillow==12.1.1"))
# Explicit source inventory. A folder mount must not pick up a future private
# receipt, .env file or exported room that somebody puts next to these scripts.
SOURCE_FILES = (
    "services/spatial-worker/worker.py", "services/spatial-worker/modal_provider.py",
    "services/spatial-worker/provider_journal.py",
    "services/spatial-worker/app.py",
    "services/spatial-worker/setup_service.sh", "tools/spatial-spike/training/modal_room.py",
    "tools/spatial-spike/training/run_training.py", "tools/spatial-spike/training/prepare_capture.py",
    "tools/spatial-spike/training/modal_setup.sh", "tools/spatial-spike/viewer/package.json",
    "tools/spatial-spike/viewer/package-lock.json",
)
if modal.is_local():
    # File mounts are constructed on the deploying machine, not revalidated
    # against the cloud module's different filesystem during container import.
    for relative in SOURCE_FILES:
        image = image.add_local_file(REPO / relative, "/workspace/" + relative)


@app.function(image=image, schedule=modal.Period(minutes=1) if DEPLOYMENT_ENABLED else None, timeout=7500,
              cpu=(2.0, 2.0), memory=(4096, 4096), max_containers=1, retries=0,
              region="us", secrets=[modal.Secret.from_name("rendprop-spatial-control-plane")] if DEPLOYMENT_ENABLED else [])
def process_next():
    if not DEPLOYMENT_ENABLED or os.environ.get("SPATIAL_WORKER_ENABLED") != "true":
        return {"status": "disabled"}
    import sys
    sys.path.insert(0, "/workspace/services/spatial-worker")
    from worker import ControlPlane, JobFailure, require, run_one
    from modal_provider import ModalProvider
    # The control plane separately refuses queuing/claims when its durable
    # operational budget is disabled. This switch avoids even idle HTTP polls.
    hosts = set(os.environ.get("SPATIAL_INPUT_HOSTS", "").split(",")) - {""}
    require(bool(hosts), "missing_input_origin_allowlist")
    api = ControlPlane(os.environ["SPATIAL_API_URL"], os.environ["SPATIAL_SERVICE_TOKEN"])
    try:
        return run_one(api, ModalProvider(modal, app), hosts)
    except JobFailure as error:
        # Return failure as failure: Modal invocation and release harnesses must
        # not turn an exception into a green {ok:true} report.
        raise RuntimeError(error.code) from None
