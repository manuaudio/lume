#!/usr/bin/env bash
# Build a Release Lume.app and install it to /Applications as the canonical app.
#
# IMPORTANT (see memory "never-show-old-lume"): the user must only ever launch
# the NATIVE build. This script replaces /Applications/Lume.app with a fresh
# native build and re-signs it ad-hoc so the embedded LumeKit.framework loads.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "▸ Generating project…"
( cd "$ROOT" && xcodegen generate >/dev/null )

echo "▸ Building Release…"
xcodebuild -project "$ROOT/Lume.xcodeproj" -scheme Lume \
  -configuration Release -destination 'platform=macOS' build -quiet

REL="$(xcodebuild -project "$ROOT/Lume.xcodeproj" -scheme Lume \
  -configuration Release -showBuildSettings 2>/dev/null \
  | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/{print $2; exit}')/Lume.app"

echo "▸ Installing $REL → /Applications/Lume.app"
pkill -x Lume 2>/dev/null || true
sleep 0.3
rm -rf /Applications/Lume.app
cp -R "$REL" /Applications/Lume.app

# Re-sign the whole bundle as one unit so the embedded framework's signature is
# consistent with the app (defensive even with hardened runtime off).
codesign --force --deep --sign - /Applications/Lume.app

/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f /Applications/Lume.app

echo "✓ Installed native Lume → /Applications/Lume.app"
