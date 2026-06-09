- This is a macOS program for counting how many keystrokes I make per day.

## Repo specs
- Written in Swift using SwiftUI for the user interface.
- No xcode garbage. I want to build from CLI
- **Build:**
  - `./build.sh` - dev build (yellow keyboard icon, "-dev" version suffix)
  - `./build.sh --release` - production build
- **Build, deploy, and restart:**
  ```
  ./build.sh && pkill -f "Input Stats.app" 2>/dev/null; rm -rf "/Applications/Input Stats.app" && cp -r "Input Stats.app" /Applications/ && open "/Applications/Input Stats.app"
  ```
- **Dev iterate loop:** `./dev.sh` (build + install the Dev bundle + relaunch), or `./dev.sh --run` to run in the foreground and see `print()` output.
- **RULE — rebuild after every code change:** whenever you change Swift source (or anything that affects the binary), you MUST run `./dev.sh` and confirm it compiles cleanly before reporting the task done. Never report a code change as complete without a successful build. If the build fails, fix it before stopping.

## Product specs
- It should show the number of keystrokes in the menubar.
- It should aggregate in "k"s if it's over 1k.
- I want it to sit in my menubar. No dock. Simple menu to quit and Start at login.
- When it's first launched it should try to register itself as login
- It should persist the keystroke count between launches and across devices, including with reconciling after offline periods, summing counts from multiple devices.
- There's a keyboard icon left of the count using this: https://www.svgrepo.com/svg/507754/keyboard
- If it doesn't have the right accessibility permission, it should render a warning icon next to the count and the irst item in the menu should be a CTA to open system preferences to the right place. The warning icon replaces the keyboard icon
- We want to very soundly and reliably reconcile across devices. It should handle race conditions like a new device coming online and thinking there's no state yet and starting a brand new file in iCloud
- We want to keep daily counts for at least 30 days, so we can show a history later. In the menubar we only show today's count, but when you open it in a section of the menu we should render:
    - Today's count
    - Yesterday's count
    - Average over the last 7 days
    - Average over the last 30 days
    - Record day count and date in mm/dd format
    - A link to open a more detailed history view
- When the menu is open from the menubar, remove the compression, show full number
- Sync every 5 minutes, and make sure to sync on app launch and app quit
- Render 2 decimal points in the menu
- In menubar, make the width the 'widest digit' times the number of digits (plus consideration for the dot), to avoid jumping when the number increases in digits
- When I hold the option key and the menu is open, render a special debug section that shows last sync, and a button to 'reset today'
- View History dialog should show a scrollable list of dates and counts. And a chart at the top with a dropdown for the number of days
- In the view history dialog, give me a button to open the iCloud Drive folder where the data is stored
- Track which apps keystrokes are made in. Show per-app breakdown in the History view with color-coded stacked bars
- Show top 5 apps individually, group the rest as "Others". Calculate top 5 based on the selected time period (7/30/60 days)
- Horizontal legend below the chart shows app colors. Legend items act as toggles to filter apps from the stats
- History view auto-refreshes every 5 minutes (matching menu bar sync) and on window focus

## High-resolution timeseries (drilldown)
- Besides keystrokes, track mouse/trackpad input: clicks (left/right/other), scroll/two-finger ticks, and pointer movement distance (pixels). All come from the CGEvent tap, which is reliable.
- Store all input as a local-only SQLite DB (`events.db` in Application Support, `TypingStats-Dev` folder for dev builds) bucketed at a 5-second base resolution. This data is per-device and is NOT synced to iCloud (the daily JSON remains the cross-device source of truth for keystroke totals).
- Capture: events accumulate in memory per 5s bucket and flush to SQLite on bucket rollover and on quit. The frontmost app bundle ID is cached (updated on app activation) to avoid per-event lookups.
- Retain raw 5s data for 30 days, then prune.
- History window has two tabs — **Keys** and **Mouse** — each with a **Daily / Timeseries** switch:
  - Keys › Daily: stacked bar by app (cross-device, from iCloud JSON) + per-day list. (Existing view.)
  - Keys › Timeseries: per-app multi-line over time (top 5 apps + Others), this Mac.
  - Mouse › Daily: stacked bar by event type (Clicks/Scroll) per day + separate pointer-movement bar chart + per-day list, this Mac.
  - Mouse › Timeseries: Clicks/Scroll multi-line + separate pointer-movement area chart, this Mac.
- Timeseries views have a span picker (1h/6h/24h/7d/30d) and a resolution drilldown picker gated per span so a chart never exceeds ~720 points (5s blocks only available for spans ≤1h). Daily mouse data is folded into local days from an hourly query (avoids UTC-day misalignment of 86400s buckets).