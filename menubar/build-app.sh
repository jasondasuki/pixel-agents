#!/bin/sh
# Builds PixelAgentsMenuBar.app (menu bar only, no Dock icon) next to this script.
set -eu
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/PixelMenuBar"

APP=PixelAgentsMenuBar.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PixelMenuBar"
cp -R Resources/pets "$APP/Contents/Resources/pets"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.pixel-agents.menubar</string>
  <key>CFBundleName</key><string>Pixel Agents Menu Bar</string>
  <key>CFBundleExecutable</key><string>PixelMenuBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature so Gatekeeper treats it as a coherent local bundle.
codesign --force --sign - "$APP"
echo "Built $(pwd)/$APP"
