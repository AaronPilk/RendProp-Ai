#!/usr/bin/env bash
# Public dependencies only. Called before any private PLY reaches the sandbox.
# Runtime libraries follow https://developer.playcanvas.com/user-manual/splat-transform/docker/
# No NVIDIA driver package is installed or replaced: Modal projects the host ICD.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl xz-utils vulkan-tools libgl1 libglvnd0 libglx0 libegl1 libxext6
test -s /etc/vulkan/icd.d/nvidia_icd.json
curl --fail --silent --show-error --location \
  https://nodejs.org/dist/v22.22.0/node-v22.22.0-linux-x64.tar.xz \
  --output /opt/room-experiment/node.tar.xz
# Same Node release and official archive digest as the existing service setup.
echo '9aa8e9d2298ab68c600bd6fb86a6c13bce11a4eca1ba9b39d79fa021755d7c37  /opt/room-experiment/node.tar.xz' | sha256sum --check --status
tar -xJf /opt/room-experiment/node.tar.xz -C /usr/local --strip-components=1
test "$(node --version)" = v22.22.0
cd /opt/room-experiment/converter
npm ci --ignore-scripts --no-audit --no-fund
test -x node_modules/.bin/splat-transform
