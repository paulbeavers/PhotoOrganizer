#!/bin/zsh
# Builds "Photo Organizer.app" into ./build (the development build).
#
#   ./scripts/build-app.sh                  release configuration, App Sandbox on
#   ./scripts/build-app.sh --no-sandbox     without the sandbox
#   ./scripts/build-app.sh --debug          debug configuration
#
# Signs with the "Developer ID Application" identity (the one ./scripts/package.sh releases with),
# else "Apple Development", else ad hoc; override with SIGN_IDENTITY="...". Dev and release builds
# must share a team: macOS ties the sandboxed app's container and saved folder bookmarks to it, and
# asks "access data from other apps?" when a differently signed build opens the same container.
# For a distributable, notarized DMG use ./scripts/package.sh, which re-signs a copy with the
# Developer ID.
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

APP="build/Photo Organizer.app"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/PhotoOrganizer"

rm -rf "$APP" build/PhotoOrganizer.app   # (the latter: the bundle's name before v0.3)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PhotoOrganizer"
cp Resources/Info.plist "$APP/Contents/Info.plist"
install -m 644 LICENSE "$APP/Contents/Resources/LICENSE.txt"   # MIT, travels with every copy

# Build provenance.
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then COMMIT="$COMMIT (modified)"; fi
/usr/libexec/PlistBuddy -c "Add :PhotoOrganizerGitCommit string $COMMIT" "$APP/Contents/Info.plist"

# App icon, rendered by the app itself (Services/AppIcon.swift).
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
"$BIN" --render-icon build/icon-1024.png
for s in 16 32 128 256 512; do
    sips -z $s $s build/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" build/icon-1024.png

IDENTITIES="$(security find-identity -v -p codesigning)"
IDENTITY="${SIGN_IDENTITY:-$(sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' <<<"$IDENTITIES" | head -1)}"
IDENTITY="${IDENTITY:-$(sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' <<<"$IDENTITIES" | head -1)}"
IDENTITY="${IDENTITY:--}"
SIGN_ARGS=(--force --sign "$IDENTITY" --options runtime)
if [[ "$SANDBOX" == 1 ]]; then
    SIGN_ARGS+=(--entitlements Resources/PhotoOrganizer.entitlements)
fi
codesign "${SIGN_ARGS[@]}" "$APP"

echo "Built $APP ($CONFIG, sandbox: $([[ $SANDBOX == 1 ]] && echo on || echo off), signed: $IDENTITY)"
