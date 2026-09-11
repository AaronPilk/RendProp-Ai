#!/usr/bin/env bash
# All dependency acquisition happens BEFORE any capture is transferred.
set -euo pipefail
bash /opt/room-experiment/modal_setup.sh
apt-get install -y --no-install-recommends curl xz-utils
curl --fail --silent --show-error --location \
  https://nodejs.org/dist/v22.22.0/node-v22.22.0-linux-x64.tar.xz \
  --output /opt/room-experiment/node.tar.xz
# SHA256 from the official version-specific SHASUMS256, retrieved 2026-09-11.
echo '9aa8e9d2298ab68c600bd6fb86a6c13bce11a4eca1ba9b39d79fa021755d7c37  /opt/room-experiment/node.tar.xz' | sha256sum --check --status
tar -xJf /opt/room-experiment/node.tar.xz -C /usr/local --strip-components=1
test "$(node --version)" = v22.22.0
cd /opt/room-experiment/converter
npm ci --ignore-scripts --no-audit --no-fund
test -x node_modules/.bin/splat-transform
node_modules/.bin/splat-transform --help >/opt/room-experiment/converter-help.txt
