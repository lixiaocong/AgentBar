#!/bin/bash
# install-app.sh — Builds AgentBar.app with the embedded widget extension, installs it, and launches it.
# Usage: ./scripts/install-app.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="AgentBar"
BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"
DERIVED_DATA_DIR="$PROJECT_DIR/.xcodebuild"
XCODEPROJ="$PROJECT_DIR/${APP_NAME}.xcodeproj"
ICON_SCRIPT="$PROJECT_DIR/scripts/generate-icons.swift"
ICON_FILE="$PROJECT_DIR/Resources/AppIcon.icns"
APP_ENTITLEMENTS="$PROJECT_DIR/Resources/${APP_NAME}.entitlements"
WIDGET_ENTITLEMENTS="$PROJECT_DIR/Resources/${APP_NAME}Widget.entitlements"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
PLISTBUDDY="/usr/libexec/PlistBuddy"
BUILD_VERSION="$(date +%Y%m%d%H%M%S)"

cd "$PROJECT_DIR"

echo "==> Rendering app icon"
if [ -f "$ICON_SCRIPT" ]; then
    swift "$ICON_SCRIPT"
fi

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "ERROR: xcodegen is required to build the widget-enabled app."
    echo "Install it with: brew install xcodegen"
    exit 1
fi

echo "==> Generating Xcode project"
xcodegen generate

if [ ! -d "$XCODEPROJ" ]; then
    echo "ERROR: Xcode project was not generated at $XCODEPROJ"
    exit 1
fi

if [ ! -f "$APP_ENTITLEMENTS" ] || [ ! -f "$WIDGET_ENTITLEMENTS" ]; then
    echo "ERROR: Entitlements files are missing."
    exit 1
fi

echo "==> Building $APP_NAME (release)…"
rm -rf "$DERIVED_DATA_DIR"
xcodebuild \
    -project "$XCODEPROJ" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -derivedDataPath "$DERIVED_DATA_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build

BUILT_APP="$DERIVED_DATA_DIR/Build/Products/Release/$APP_NAME.app"
if [ ! -d "$BUILT_APP" ]; then
    echo "ERROR: Built app bundle not found at $BUILT_APP"
    exit 1
fi

echo "==> Creating app bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$BUILD_DIR"
cp -R "$BUILT_APP" "$APP_BUNDLE"

if [ -f "$ICON_FILE" ]; then
    echo "==> Copying app icon into bundle resources"
    mkdir -p "$APP_BUNDLE/Contents/Resources"
    cp "$ICON_FILE" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

echo "==> Stamping bundle version $BUILD_VERSION"
if [ -x "$PLISTBUDDY" ]; then
    "$PLISTBUDDY" -c "Set :CFBundleVersion $BUILD_VERSION" "$APP_BUNDLE/Contents/Info.plist" || true
fi

if [ -f "$ICON_FILE" ] && [ -d "$APP_BUNDLE/Contents/PlugIns" ]; then
    echo "==> Copying app icon into widget extension resources"
    while IFS= read -r appex; do
        mkdir -p "$appex/Contents/Resources"
        cp "$ICON_FILE" "$appex/Contents/Resources/AppIcon.icns"
        if [ -x "$PLISTBUDDY" ]; then
            "$PLISTBUDDY" -c "Set :CFBundleVersion $BUILD_VERSION" "$appex/Contents/Info.plist" || true
        fi
    done < <(find "$APP_BUNDLE/Contents/PlugIns" -depth -name "*.appex" -print)
fi

if [ -d "$APP_BUNDLE/Contents/PlugIns" ]; then
    while IFS= read -r appex; do
        codesign --force --sign - --entitlements "$WIDGET_ENTITLEMENTS" "$appex"
    done < <(find "$APP_BUNDLE/Contents/PlugIns" -depth -name "*.appex" -print)
fi

echo "==> Ad-hoc signing app bundle"
codesign --force --sign - --entitlements "$APP_ENTITLEMENTS" "$APP_BUNDLE"

if [ -x "$LSREGISTER" ]; then
    echo "==> Registering app bundle with LaunchServices"
    "$LSREGISTER" -f -R -trusted "$APP_BUNDLE"
fi

touch "$APP_BUNDLE"

if pgrep -f "$INSTALL_PATH/Contents/MacOS/$APP_NAME" >/dev/null 2>&1; then
    echo "==> Stopping installed app"
    pkill -f "$INSTALL_PATH/Contents/MacOS/$APP_NAME" || true
    sleep 1
fi

if [ -d "$INSTALL_PATH" ]; then
    if command -v pluginkit >/dev/null 2>&1; then
        while IFS= read -r appex; do
            pluginkit -r "$appex" || true
        done < <(find "$INSTALL_PATH/Contents/PlugIns" -depth -name "*.appex" -print 2>/dev/null)
    fi

    echo "==> Replacing existing install"
    rm -rf "$INSTALL_PATH"
fi

echo "==> Installing app bundle to $INSTALL_PATH"
ditto "$APP_BUNDLE" "$INSTALL_PATH"

if [ -x "$LSREGISTER" ]; then
    echo "==> Registering installed app with LaunchServices"
    "$LSREGISTER" -f -R -trusted "$INSTALL_PATH"
fi

if command -v pluginkit >/dev/null 2>&1; then
    echo "==> Registering widget extension with PlugInKit"
    while IFS= read -r appex; do
        pluginkit -a "$appex" || true
    done < <(find "$INSTALL_PATH/Contents/PlugIns" -depth -name "*.appex" -print)
fi

touch "$INSTALL_PATH"

echo "==> Launching $APP_NAME"
open "$INSTALL_PATH"

echo "==> Done"
echo "    App bundle: $APP_BUNDLE"
echo "    Installed app: $INSTALL_PATH"
