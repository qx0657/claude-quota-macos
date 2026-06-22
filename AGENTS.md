# AGENTS.md

This file is for AI coding agents working on this repository.

## Project Overview

`claude-quota-macos` is a minimal macOS menu bar app for showing Claude quota usage. It mirrors the behavior of the sibling `claude-quota-windows` project, but uses native Swift/AppKit and system frameworks only.

The app is intentionally small:

- `Sources/ClaudeQuotaTray/main.swift` - application entry point, menu bar UI, data fetching, config storage, icon drawing, startup LaunchAgent, and statusLine installer.
- `Sources/CommonCryptoShim/` - tiny C shim over system CommonCrypto for Electron/Chromium safe storage decryption.
- `Package.swift` - Swift Package configuration.
- `build.sh` - builds and bundles `publish/ClaudeQuotaTray.app`.
- `README.md` - user-facing documentation.

## Build And Run

Use macOS with Swift toolchain/Xcode Command Line Tools.

```bash
swift build -c release
swift run -c release
```

To publish the app bundle:

```bash
./build.sh
```

To package a DMG:

```bash
./package-dmg.sh
```

Published output is expected at:

```text
publish/ClaudeQuotaTray.app
publish/ClaudeQuotaTray.dmg
```

Do not commit build outputs from `.build/` or `publish/`.

## Data Source Modes

Keep user-facing behavior aligned with `README.md`.

- Active mode: default mode. Reads Claude App local OAuth cache in memory and requests Anthropic usage API.
- Passive mode: reads `~/Library/Application Support/ClaudeQuotaTray/statusline-usage.json`, written by the Claude Code statusLine collector.
- Auto fallback mode: tries active mode first, then recent active cache, passive statusLine cache, and legacy `.credentials.json`.

Important implementation points:

- `Config.sourceMode` defaults to `.active`.
- `fetchUsage(sourceMode:)` routes source mode behavior.
- `tryFetchClaudeAppOAuthUsage()` is the primary active-mode fetcher.
- `tryReadStatusLineCache()` is the passive-mode reader.
- `StatusLineInstaller` should only affect passive mode and auto fallback's passive source.

## Privacy And Local Data

Preserve the privacy model:

- Do not save Claude access tokens, refresh tokens, or Cookies into `~/Library/Application Support/ClaudeQuotaTray`.
- It is okay to save non-sensitive usage cache data, such as used percentages, reset times, fetch timestamps, refresh interval, and selected source mode.
- Active mode should decrypt/read Claude App credentials only in memory.

## UI Behavior

The menu bar icon and menu both show two quota metrics:

- 5-hour quota.
- Weekly quota.

Color thresholds are based on remaining quota and should stay consistent:

- Remaining below 15%: red.
- Remaining below 35%: orange.
- Otherwise: green.

When refresh fails, keep showing the last successful usage data if available, and surface the stale/failure state in the tooltip/menu.

## Verification Checklist

For code changes, run at least:

```bash
swift build -c release
```

For bundling changes, also run:

```bash
./build.sh
./package-dmg.sh
```

For tray/menu/UI behavior changes, run the app locally and verify:

- Menu bar icon renders two visible bars.
- Context menu opens from the menu bar icon.
- Source mode menu reflects the selected mode.
- Failure/stale states remain understandable.
