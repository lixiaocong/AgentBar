#!/bin/bash
# install-app.sh — Builds, installs, and launches AgentBar.app.
# Usage: ./scripts/install-app.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_SCRIPT="$PROJECT_DIR/scripts/build-app.sh"
APP_NAME="AgentBar"
APP_BUNDLE="$PROJECT_DIR/build/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"

"$BUILD_SCRIPT"

if [ ! -d "$APP_BUNDLE" ]; then
    echo "ERROR: Built app bundle not found at $APP_BUNDLE"
    exit 1
fi

echo "==> Launching $APP_NAME"
open "$INSTALL_PATH"

echo "==> Done"
echo "    Installed app: $INSTALL_PATH"
echo "    Search for: Agent Bar"
