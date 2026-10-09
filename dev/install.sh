#!/bin/bash
# Install the working tree for development: runs the checks, then the real
# installer (which restarts the Omarchy shell so new QML is picked up).
# Extra arguments go to install.sh, e.g. dev/install.sh --no-default
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
bash tests/run.sh
bash install.sh --dev "$@"
