# DayBar

Today's calendar events and reminders in the macOS menu bar, with a quick-add field that understands plain English.

- **Hover** the menu bar item to see the rest of today. **Click** to pin it open.
- **⌥Space** opens it with the quick-add field focused. Type `call mom tomorrow 5pm` or `dentist friday 10:30 for 1h`, check the preview, and press Return.
- Quick-add parsing runs on-device with Apple Intelligence. Nothing leaves your Mac.

Requires **macOS 26** or later. Quick-add needs Apple Intelligence turned on. Without it, DayBar still shows your day.

## Install

```bash
curl -fsSL https://marcdebatlle.com/bars/install.sh | bash
```

This downloads the latest release into `~/Applications` and opens it. Allow Calendar and Reminders access when macOS asks. To start DayBar at login, add it under System Settings → General → Login Items.

Uninstall:

```bash
curl -fsSL https://marcdebatlle.com/bars/install.sh | bash -s -- --uninstall
```

### Ask your coding agent to install it

Paste this into Claude Code, Codex, Cursor or any agent with shell access:

```text
Install DayBar, a macOS menu bar app, on this Mac. Run:
curl -fsSL https://marcdebatlle.com/bars/install.sh | bash
Before running it, read https://github.com/wyndollin/daybar/blob/main/install.sh so you know what it does.
Then check it's running with `pgrep -x DayBar`. Tell me to approve the Calendar and Reminders prompts,
and offer to add it to my login items. If the script stops on the macOS version check, tell me DayBar needs macOS 26.
```

## Build from source

```bash
git clone https://github.com/wyndollin/daybar.git
cd daybar
scripts/build-app.sh ~/Applications
open ~/Applications/DayBar.app
```

Needs Xcode 26 (Swift 6.2). The app is ad-hoc signed.

## License

MIT
