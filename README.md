# Input Stats

A macOS menu bar app that tracks your daily **keyboard and mouse/trackpad** activity.

A fork of [Typing Stats](https://github.com/rauchg/typing-stats) by Guillermo Rauch, extended with
mouse/trackpad tracking (clicks, scroll, pointer movement) and a high-resolution timeseries
drilldown (down to 5-second blocks).

Maintained by [mewc](https://mewc.info). For more, see [mewc.info](https://mewc.info)
and [drummerduck.com](https://drummerduck.com).

> **Privacy:** raw five-second input buckets stay local on your Mac. If you opt in with Google,
> numeric one-minute summaries and daily totals sync to your private account. Keystrokes themselves
> are never recorded. The app never captures characters, key codes, window titles, URLs, clipboard
> contents, screenshots, or raw input events. [Full privacy details](https://input-stats.drummerduck.com/privacy).

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
- Compact three-significant-digit menu-bar totals, with the full number shown while the menu is open
- Daily / weekly / monthly keystroke stats, multi-device sync via iCloud
- Per-app keystroke breakdown
- **Mouse & trackpad tracking** — clicks, scroll, and pointer-movement distance
- **History window** with Keys / Mouse tabs, each with Daily (stacked bars) and Timeseries (lines) views
- **Timeseries drilldown** — span picker (1h–30d) with resolution down to 5s blocks, gated so wide
  windows can't render a punishing number of points
- Start at login
- Free Google login for account-backed sync and a private web dashboard with per-app analytics
- De-identified community analytics using coarse app categories and a 20-account publication threshold

## Permissions

Accessibility permission is required to count input. You'll be prompted on first launch, or grant it in:

**System Settings → Privacy & Security → Accessibility**

## Build from source

```bash
./build.sh             # dev build (Input Stats (Dev).app)
./build.sh --release   # production build (Input Stats.app)
./dev.sh               # dev build, install + relaunch (yellow icon, "(dev)" suffix)
./dev.sh --run         # dev build, run in foreground to see logs
./test.sh              # sync/repair and count-format regression tests
./repair-data.sh       # dry-run repair of v0.1.8 carried daily totals
./repair-data.sh --apply # back up the iCloud JSON, then apply the repairs
```

`repair-data.sh` scans every device in the merged history. It only changes rows matching the exact
carried-count fingerprint, prints each proposed correction, and leaves the source untouched unless
`--apply` is supplied. Use `--file PATH` to inspect a copied or alternate sync JSON file.

When account sync is enabled, the app automatically backfills up to 30 days of active one-minute
summaries in retry-safe batches. Older daily key/app history remains available through the existing
daily sync data, so enabling the dashboard does not throw away prior history. You can also preview
and apply the carried-count repair from **Dashboard → Data**, where every applied repair creates a
30-day restore point first.

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
