#!/bin/bash
# build-app.sh — Builds AgentBar.app bundle from the Swift Package.
# Usage: ./scripts/build-app.sh
# Output: build/AgentBar.app  (drag this to /Applications)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="AgentBar"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ICON_SCRIPT="$PROJECT_DIR/scripts/generate-icons.swift"
ICON_FILE="$PROJECT_DIR/Resources/AppIcon.icns"

echo "==> Building $APP_NAME (release)…"
cd "$PROJECT_DIR"
swift build -c release --scratch-path .build 2>&1

echo "==> Rendering app icon"
swift "$ICON_SCRIPT"

BINARY="$(swift build -c release --scratch-path .build --show-bin-path)/$APP_NAME"
if [ ! -f "$BINARY" ]; then
    echo "ERROR: Binary not found at $BINARY"
    exit 1
fi

if [ ! -f "$ICON_FILE" ]; then
    echo "ERROR: App icon not found at $ICON_FILE"
    exit 1
fi

echo "==> Creating app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Copy app icon
cp "$ICON_FILE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

echo "==> Ad-hoc signing app bundle"
codesign --force --sign - "$APP_BUNDLE"

echo "==> Done! App bundle created at:"
echo "    $APP_BUNDLE"
echo ""
echo "To install, run:"
echo "    cp -R $APP_BUNDLE /Applications/"
echo ""
echo "Or simply drag $APP_BUNDLE to your Applications folder."
