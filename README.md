# CXS Tray

Small macOS menu bar app for switching the active Codex auth managed by `cxs`.

This is an unofficial personal tool and is not affiliated with OpenAI. Use it
only with Codex accounts you own or are authorized to use.

It shows the values from `cxs usage` in the menu bar menu. Selecting an account:

1. gracefully asks the running Codex app to quit,
2. verifies Codex is no longer running,
3. runs `cxs sync <account>`,
4. runs `ocx ensure` if `ocx` is available,
5. launches Codex again with `open -a Codex`,
6. refreshes usage/default-account state.

## Requirements

- macOS 13+
- Swift 6 toolchain / Xcode command line tools
- `cxs` available at `/opt/homebrew/bin/cxs`, `/usr/local/bin/cxs`, `/Applications/Codex.app/Contents/Resources`, or somewhere on `PATH`
- Codex installed as a macOS app named `Codex`

## Run From Source

```sh
swift run CXSTray
```

## CLI Account Switch

The same executable can run the tray switch flow from a shell:

```sh
swift run CXSTray -- switch <account>
```

This quits the configured Codex app, verifies it is no longer running, runs
`cxs sync <account>`, runs `ocx ensure` when `ocx` is available, and relaunches
Codex. It is useful over SSH when you want to switch the active account before
using Codex remote.

If you installed the app bundle, you can call the installed executable directly:

```sh
~/Applications/CXSTray.app/Contents/MacOS/CXSTray switch <account>
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

`build-app.sh` creates a local app bundle with an ad-hoc signature. It is meant
for local use, not as a notarized public binary distribution.

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
- The status item title shows the current default account name and 5-hour remaining value.
- If Codex is not running when an account is selected, the app still syncs auth and launches Codex.
- When syncing accounts, the app asks running apps named `Codex` or whose bundle identifier contains `codex` to quit, verifies they are gone, and aborts the sync if Codex is still running after the timeout.

## Privacy and Security

- CXS Tray does not intentionally store Codex credentials.
- It invokes `cxs usage`, `cxs list`, and `cxs sync <account>`. Review the
  `cxs` tool you use to understand how it reads or writes Codex auth state.
- Account names, plan names, usage percentages, and reset times are visible in
  the macOS menu bar/menu and can appear in screenshots or screen shares.
- Command failures may be shown in the menu so you can diagnose local setup
  problems.

## License

MIT
