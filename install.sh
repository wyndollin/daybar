#!/bin/bash
# DayBar installer: today's calendar and reminders in the macOS menu bar.
#   curl -fsSL https://marcdebatlle.com/bars/install.sh | bash
#
# Downloads the latest release into ~/Applications and opens it. If the download
# fails and a Swift toolchain is present, it builds from source instead.
# Uninstall:  curl -fsSL https://marcdebatlle.com/bars/install.sh | bash -s -- --uninstall
set -euo pipefail

REPO="wyndollin/daybar"
APP_NAME="DayBar"
DEST="$HOME/Applications"
APP="$DEST/$APP_NAME.app"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || fail "DayBar is a macOS app."
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 26 ] || fail "DayBar needs macOS 26 or later (you have $(sw_vers -productVersion))."

if [ "${1:-}" = "--uninstall" ]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "$APP"
  defaults delete local.daybar 2>/dev/null || true
  say "DayBar removed."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$DEST"

install_release() {
  say "Downloading the latest DayBar release…"
  curl -fsSL "https://github.com/$REPO/releases/latest/download/$APP_NAME.zip" -o "$TMP/$APP_NAME.zip" || return 1
  ditto -x -k "$TMP/$APP_NAME.zip" "$TMP/out" || return 1
  [ -d "$TMP/out/$APP_NAME.app" ] || return 1
}

install_source() {
  command -v swift >/dev/null || fail "Download failed and no Swift toolchain found. Install Xcode, or retry later."
  say "Building DayBar from source…"
  git clone --depth 1 "https://github.com/$REPO.git" "$TMP/src" >/dev/null 2>&1 || fail "Could not clone $REPO."
  "$TMP/src/scripts/build-app.sh" "$TMP/out" >/dev/null || fail "Build failed."
}

install_release || install_source

pkill -x "$APP_NAME" 2>/dev/null && sleep 1 || true
rm -rf "$APP"
mv "$TMP/out/$APP_NAME.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

say "Installed $APP"
open "$APP"
cat <<'MSG'

DayBar is now in your menu bar.
  • Allow Calendar and Reminders access when macOS asks.
  • Hover the menu bar item to see today; press ⌥Space to quick-add.
  • To start it at login: System Settings → General → Login Items → add DayBar.
MSG
