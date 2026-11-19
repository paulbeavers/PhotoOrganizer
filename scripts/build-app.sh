#!/bin/zsh
# Builds PhotoOrganizer.app into ./build.
#
#   ./scripts/build-app.sh                  release build, App Sandbox enabled
#   ./scripts/build-app.sh --no-sandbox     release build without the sandbox
#   ./scripts/build-app.sh --debug          debug configuration
#
# Signs with the first "Apple Development" identity in the keychain (override with
# SIGN_IDENTITY="..."), falling back to ad-hoc signing. A stable identity matters for the sandboxed
# build: macOS ties the app's container and saved folder bookmarks to its signature.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG=release
SANDBOX=1
for arg in "$@"; do
    case "$arg" in
        --no-sandbox) SANDBOX=0 ;;
        --debug) CONFIG=debug ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

APP="build/PhotoOrganizer.app"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/PhotoOrganizer"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PhotoOrganizer"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Photo Organizer</string>
    <key>CFBundleDisplayName</key><string>Photo Organizer</string>
    <key>CFBundleIdentifier</key><string>local.photoorganizer</string>
    <key>CFBundleExecutable</key><string>PhotoOrganizer</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.photography</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)}"
IDENTITY="${IDENTITY:--}"
SIGN_ARGS=(--force --sign "$IDENTITY" --options runtime)
if [[ "$SANDBOX" == 1 ]]; then
    SIGN_ARGS+=(--entitlements Resources/PhotoOrganizer.entitlements)
fi
codesign "${SIGN_ARGS[@]}" "$APP"

echo "Built $APP ($CONFIG, sandbox: $([[ $SANDBOX == 1 ]] && echo on || echo off), signed: $IDENTITY)"
