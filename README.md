# CXS Tray

Small macOS menu bar app for switching the active Codex auth managed by `cxs`.

It shows the values from `cxs usage` in the menu bar menu. Selecting an account:

1. gracefully asks the running Codex app to quit,
2. runs `cxs sync <account>`,
3. launches Codex again with `open -a Codex`,
4. refreshes usage/default-account state.

## Requirements

- macOS 13+
- Swift 6 toolchain / Xcode command line tools
- `cxs` available at `/opt/homebrew/bin/cxs`, `/usr/local/bin/cxs`, or somewhere on `PATH`
- Codex installed as a macOS app named `Codex`

## Run From Source

```sh
swift run CXSTray
```

## Install

Install the menu bar app into `~/Applications` and register a user LaunchAgent:

```sh
bash scripts/install.sh
```

This creates:

```text
~/Applications/CXSTray.app
~/Library/LaunchAgents/com.cxs.tray.plist
```

The LaunchAgent opens the installed app copy, not the workspace build output.

To uninstall:

```sh
bash scripts/uninstall.sh
```

## Build

```sh
swift build -c release
```

The compiled binary will be at `.build/release/CXSTray`.

To create a double-clickable menu bar app bundle without installing it:

```sh
bash scripts/build-app.sh
open .build/release/CXSTray.app
```

## Codex App Name

If the installed app is not named `Codex`, launch with:

```sh
CXS_TRAY_CODEX_APP_NAME="Your App Name" swift run CXSTray
```

or persist the setting:

```sh
defaults write com.cxs.tray CodexAppName "Your App Name"
```

## Notes

- The menu refreshes every 5 minutes.
- The status item title shows the current default account's 5-hour remaining value.
- If Codex is not running when an account is selected, the app still syncs auth and launches Codex.
