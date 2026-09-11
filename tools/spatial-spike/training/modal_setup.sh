#!/usr/bin/env bash
# Install public dependencies BEFORE any room data reaches the ephemeral host.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
export MAX_JOBS=4
export PIP_NO_CACHE_DIR=1
export OMP_NUM_THREADS=4
apt-get update
apt-get install -y --no-install-recommends git build-essential libgl1 libglib2.0-0 ffmpeg
git clone --depth 1 --branch v1.5.3 https://github.com/nerfstudio-project/gsplat.git /opt/gsplat-phase-a
test "$(git -C /opt/gsplat-phase-a rev-parse HEAD)" = 937e29912570c372bed6747a5c9bf85fed877bae
python -m pip install --no-build-isolation -r /opt/gsplat-phase-a/examples/requirements.txt numpy==1.26.4 Pillow==12.1.1 tyro==0.9.35 ninja
python -m pip install --no-build-isolation -e /opt/gsplat-phase-a
python -m pip check
python /opt/gsplat-phase-a/examples/simple_trainer.py --help >/opt/room-experiment/trainer-help.txt
# Cache the exact trainer's public metric weights; the room phase can then run
# with outbound networking denied rather than fetching weights beside media.
python -c 'from torchmetrics.image.lpip import LearnedPerceptualImagePatchSimilarity; LearnedPerceptualImagePatchSimilarity(net_type="alex", normalize=True)'
python -c 'import torch; import gsplat.cuda._backend; assert torch.cuda.is_available(); assert torch.cuda.device_count() == 1; assert "L4" in torch.cuda.get_device_name(0)'
python -m pip freeze >/opt/room-experiment/resolved-setup.txt
