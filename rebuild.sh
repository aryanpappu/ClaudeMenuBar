#!/bin/bash
# Developer loop: rebuild and relaunch the app (hooks are not touched).
set -euo pipefail
cd "$(dirname "$0")"
./install.sh --no-hooks
