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

# Quick-add reads what you type with Apple Intelligence, on this Mac. Ask DayBar whether it can
# (at most 10 s, in case an older build doesn't know the flag) and say so plainly.
ai="$(perl -e 'alarm 10; exec @ARGV' "$APP/Contents/MacOS/DayBar" --check-ai 2>/dev/null || true)"
warn() { printf '\n\033[33m!\033[0m \033[1m%s\033[0m\n  %s\n' "$1" "$2"; }
case "$ai" in
  ready) printf '\n\033[32m✓\033[0m Apple Intelligence is on: quick-add will work.\n' ;;
  off) warn "Quick-add needs Apple Intelligence, and it is turned off." \
            "Turn it on in System Settings → Apple Intelligence & Siri. DayBar still shows your day without it." ;;
  downloading) warn "Apple Intelligence is still downloading." \
                    "Quick-add starts working once it finishes. DayBar already shows your day." ;;
  unsupported) warn "This Mac can't run Apple Intelligence, so quick-add won't work." \
                    "Everything else does: DayBar shows your day and your reminders." ;;
esac

open "$APP"
cat <<'MSG'

DayBar is now in your menu bar.
  • Allow Calendar and Reminders access when macOS asks.
  • Hover the menu bar item to see today; press ⌥Space to quick-add (needs Apple Intelligence).
  • It starts at login from now on; turn that off in System Settings → General → Login Items.
MSG
