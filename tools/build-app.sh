#!/bin/bash
# Builds a double-clickable Lume.app bundle (release) with the custom icon.
#   ./tools/build-app.sh
# Produces dist/Lume.app and installs a copy to /Applications (falls back to
# ~/Applications if /Applications isn't writable).
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$(dirname "$0")/.."
ROOT="$PWD"

echo "▸ Building release…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="$ROOT/dist/Lume.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/LumeApp" "$APP/Contents/MacOS/LumeApp"
cp "$ROOT/Sources/LumeApp/Resources/Lume.icns" "$APP/Contents/Resources/Lume.icns"
# SPM resource bundle so Bundle.module (web assets, icon) resolves at runtime.
if [ -d "$BIN_DIR/LumeApp_LumeApp.bundle" ]; then
  cp -R "$BIN_DIR/LumeApp_LumeApp.bundle" "$APP/Contents/Resources/"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Lume</string>
  <key>CFBundleDisplayName</key>     <string>Lume</string>
  <key>CFBundleExecutable</key>      <string>LumeApp</string>
  <key>CFBundleIdentifier</key>      <string>com.lume.app</string>
  <key>CFBundleIconFile</key>        <string>Lume</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>1.0</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so it launches cleanly as a locally built app.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ Built $APP"

# Install a copy where it's discoverable in Launchpad/Spotlight.
# Remove any existing bundle first: `cp -R src dest` when dest exists copies
# src *into* dest (dest/Lume.app) instead of replacing it, which silently
# leaves the old binary in place.
DEST="/Applications/Lume.app"
rm -rf "$DEST" 2>/dev/null || true
if cp -R "$APP" "$DEST" 2>/dev/null; then
  echo "✓ Installed to $DEST"
else
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Lume.app"
  cp -R "$APP" "$HOME/Applications/Lume.app"
  echo "✓ Installed to $HOME/Applications/Lume.app (/, Applications not writable)"
fi
