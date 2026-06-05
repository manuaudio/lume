#!/bin/bash
# Builds a double-clickable, native Lume.app bundle (release) with the custom icon.
#   ./tools/build-app.sh             # normal (unsandboxed) build + install
#   ./tools/build-app.sh --run       # also launch the installed app when done
#   ./tools/build-app.sh --sandbox   # sign with App Sandbox entitlements (opt-in)
# Produces dist/Lume.app and installs a copy to /Applications (falls back to
# ~/Applications if /Applications isn't writable). This is the ONLY supported way
# to run Lume as a real app — never ship/run the bare `swift build` binary, which
# has no bundle identity, icon, or Launchpad/Spotlight presence.
set -euo pipefail

SANDBOX=0
RUN=0
for arg in "$@"; do
  case "$arg" in
    --sandbox) SANDBOX=1 ;;
    --run|--open) RUN=1 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

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

# Version: human string stays 1.0; build number is the git commit count so every
# build is monotonically identifiable (falls back to 1 outside a git checkout).
SHORT_VER="1.0"
BUILD_NUM="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

# Unquoted heredoc so ${SHORT_VER}/${BUILD_NUM} expand; the plist has no other '$'.
cat > "$APP/Contents/Info.plist" <<PLIST
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
  <key>CFBundleShortVersionString</key> <string>${SHORT_VER}</string>
  <key>CFBundleVersion</key>         <string>${BUILD_NUM}</string>
  <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
  <key>CFBundleDevelopmentRegion</key> <string>en</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <key>LSApplicationCategoryType</key> <string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSSupportsAutomaticTermination</key> <true/>
  <key>NSSupportsSuddenTermination</key> <true/>
  <key>NSHumanReadableCopyright</key> <string>© 2026 Lume</string>
  <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so it launches cleanly as a locally built app. With --sandbox,
# sign WITH the App Sandbox entitlements (ad-hoc signing + entitlements is enough
# to activate the sandbox for a locally-run app).
#
# NOTE: a sandboxed Lume can only read folders the user grants via the open panel
# (no browse-from-home), and its SwiftData store lives in the per-app container
# (~/Library/Containers/com.lume.app/…), so existing tags/favorites/notes from the
# unsandboxed build won't be visible. This is why sandboxing is opt-in, not default.
if [ "${SANDBOX:-0}" = "1" ]; then
  echo "▸ Signing WITH App Sandbox entitlements…"
  codesign --force --deep --sign - --entitlements "$ROOT/tools/Lume.entitlements" "$APP" >/dev/null 2>&1 \
    || { echo "✗ Sandboxed signing failed"; exit 1; }
else
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
fi

echo "✓ Built $APP"

# Quit any running copy BEFORE replacing it on disk — otherwise we'd swap the
# binary out from under a live process (stale/zombie state, and the relaunch
# below would just re-focus the old instance).
osascript -e 'quit app "Lume"' >/dev/null 2>&1 || true
pkill -x LumeApp >/dev/null 2>&1 || true
sleep 1

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
  DEST="$HOME/Applications/Lume.app"
  echo "✓ Installed to $DEST (/, Applications not writable)"
fi

# Refresh Launch Services so the new bundle is registered for Spotlight/Launchpad.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f "$DEST" >/dev/null 2>&1 || true

if [ "$RUN" = "1" ]; then
  echo "▸ Launching ${DEST}…"
  open "$DEST"
fi
