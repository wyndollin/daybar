#!/bin/bash
# Build DayBar.app from this checkout, ad-hoc signed.
#   scripts/build-app.sh <out-dir>
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:?usage: build-app.sh <out-dir>}"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/DayBar"

APP="$OUT/DayBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/DayBar"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.daybar</string>
  <key>CFBundleName</key><string>DayBar</string>
  <key>CFBundleDisplayName</key><string>DayBar</string>
  <key>CFBundleExecutable</key><string>DayBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.4</string>
  <key>CFBundleVersion</key><string>5</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>DayBar shows today's events in the menu bar and adds the ones you type. Everything stays on this Mac.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>DayBar lists the reminders due today and adds the ones you type. Everything stays on this Mac.</string>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"
echo "built $APP"
