# Input Stats

A macOS menu bar app that tracks your daily **keyboard and mouse/trackpad** activity.

A fork of [Typing Stats](https://github.com/rauchg/typing-stats) by Guillermo Rauch, extended with
mouse/trackpad tracking (clicks, scroll, pointer movement) and a high-resolution timeseries
drilldown (down to 5-second blocks).

## Install

No notarized release / Homebrew cask — this is a personal public fork distributed as a direct download.

1. Download `InputStats.zip` from the [latest release](https://github.com/mewc/input-stats/releases/latest) and unzip it.
2. Move **Input Stats.app** to `/Applications`.
3. First launch is blocked by Gatekeeper (ad-hoc signed, not notarized). Either **right-click the app → Open**
   and confirm, or run:
   ```bash
   xattr -cr "/Applications/Input Stats.app"
   ```
4. Grant **Accessibility** permission when prompted.

## Features

- Live keystroke counter in the menu bar
- Daily / weekly / monthly keystroke stats, multi-device sync via iCloud
- Per-app keystroke breakdown
- **Mouse & trackpad tracking** — clicks, scroll, and pointer-movement distance
- **History window** with Keys / Mouse tabs, each with Daily (stacked bars) and Timeseries (lines) views
- **Timeseries drilldown** — span picker (1h–30d) with resolution down to 5s blocks, gated so wide
  windows can't render a punishing number of points
- Start at login

## Permissions

Accessibility permission is required to count input. You'll be prompted on first launch, or grant it in:

**System Settings → Privacy & Security → Accessibility**

## Build from source

```bash
./build.sh             # release build (Input Stats.app)
./build.sh --release   # same, explicit
./dev.sh               # dev build, install + relaunch (yellow icon, "(dev)" suffix)
./dev.sh --run         # dev build, run in foreground to see logs
```

## Releasing

Push a tag to publish a download-only GitHub release (CI builds, zips, and attaches the app):

```bash
git tag v0.1.0
git push origin v0.1.0
```

## Credits

- [Guillermo Rauch](https://github.com/rauchg) — original Typing Stats
- [Ghoshan Jaganathamani](https://github.com/ghostyfreak) — per-app analytics

## Uninstall

```bash
rm -rf "/Applications/Input Stats.app"
rm -rf ~/Library/Application\ Support/TypingStats
```
