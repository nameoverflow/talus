# Talus

Experimental macOS window manager inspired by XMonad. Written in **100% pure Geisha** (`src/*.gsa` + `src/macos/*.gsa` using `objc.gsa` and `geisha build --target macos-app`): pure Geisha modules handle all tiling geometry, virtual workspaces, session persistence, TOML configuration (`std.toml.patch`, preserving user comments on save), status markup/template rendering, subprocess status command scheduling (`sys.proc`), per-app `std.actor` window discovery/execution, and the core window-manager state machine (`ManagerCore`), while directly driving macOS AppKit, Accessibility (`AXUIElement`), Carbon hotkeys, `SMAppService` Launch-at-Login, menu-bar `NSStatusItem` rendering, and the native Settings window; no X11, no Rust, no Swift. This is not yet a daily-use release.

Build and test with `make all test` on macOS 15 or later with Xcode Command Line Tools and the [Geisha](https://github.com/geisha-lang/geisha.gsa) toolchain (`geisha`). `make app` builds `build/Talus.app` (automatically signing with `Developer ID Application`, `Apple Development`, or `Talus Local Code Signing` if present, and falling back to ad-hoc `-` otherwise), with a menu-bar control to pause, toggle Launch at Login, open Settings (`⌘,`), reload configuration, and quit. Run `make setup-cert` once locally to create a persistent `Code Signing`-only self-signed certificate so macOS Accessibility permission survives rebuilds (`make install` updates `/Applications/Talus.app`), and use `make dist` to build a clean ad-hoc `build/Talus-macos.zip` for sharing with other Macs. The program will move visible windows. Quit other window managers before starting and save your work. Control-C quits. Control-Option-P pauses/resumes.

Control-Option J/K focuses the next/previous window on the screen; add Shift to swap. Return swaps the focused window with master. H/L changes the master width. Comma/period changes the master count; Space cycles Tall, Mirror Tall, and Full; T toggles floating for the focused window. Window creation/destruction uses Accessibility notifications with a two-second fallback reconciliation.

Current features: Tall, Mirror Tall, and Full layouts; switchable **native Spaces** (`mode = "native"`) or **Talus virtual workspaces** (`mode = "virtual"`, `count = 1..9`) with instant `<Mod>+1..9` workspace switching, `<Mod>+Shift+1..9` window throwing, independent per-workspace layout state, and automatic restoration of parked windows on quit or mode switch.

## Downloads and releases

Apple Silicon (arm64) packages are published on [GitHub Releases](https://github.com/nameoverflow/talus/releases).
Extract `Talus-macos-arm64.zip` and move `Talus.app` to `/Applications`. Builds explicitly target macOS 15.0 so newer local toolchains do not silently raise the minimum supported system version.
Release builds are ad-hoc signed, without Apple notarization; macOS Gatekeeper may require explicit approval.

The `macOS CI and Release` workflow builds, runs the test suite and command cleanup check, and verifies the packaged app on every pull request and push to `main`. Pushing a `vMAJOR.MINOR.PATCH` tag (for example, `v0.1.0`) runs the same checks and publishes the ZIP and SHA-256 checksum only after they pass. The tag supplies the bundle version. Manual workflow runs build the selected ref and publish only when that ref is a version tag.

## Configuration (TOML Dotfile & Graphical Settings UI)

Talus reads its configuration in the following order (unless `TALUS_CONFIG` is set):

1. `~/.talus.toml` (primary dotfile in home directory)
2. `~/.config/talus/config.toml`
3. `~/Library/Application Support/Talus/config.toml`
4. `~/Library/Application Support/Talus/config.json` (legacy JSON fallback)

You can configure Talus either through the built-in **Settings window** (click the Talus menu-bar item → **设置…** / `⌘,`, reopen `Talus.app`, or run `talus --settings`) or by editing `~/.talus.toml` directly. Changes saved from the Settings UI or written to the dotfile on disk are applied live without restarting Talus.

To start Talus automatically when you log in, open **设置… → 通用 → 登录后自动启动** in the installed `Talus.app`. This uses macOS Login Items and starts disabled unless already enabled in macOS. If approval is required, Settings links to **System Settings → General → Login Items**. The switch refreshes when you return to Talus; this per-user setting is managed by macOS, not the TOML file.

Example `~/.talus.toml`:

```toml
modifiers = ["option"]

[workspaces]
mode = "virtual"
count = 5
labels = ["term", "web", "code", "chat", "misc"]

[layout]
master_ratio = 0.5
ratio_step = 0.03
master_count = 1
outer_gap = 12
inner_gap = 8

[rules]
ignore_apps = ["com.example.SomeApp"]

[rules.app_workspaces]
"com.apple.Safari" = "web"
"com.apple.Terminal" = 1
```

Every key is optional. Modifier names are `control`, `option`, and `command`; at least one is required, and Shift is reserved for swap shortcuts. Ratio must be 0.2–0.8, ratio step greater than zero and at most 0.2, and master count 1–20. `ignore_apps` contains application bundle identifiers. Invalid configuration at startup is reported on standard error (or via an alert when launched as an app); invalid edits while running are logged without crashing the running session.

`outer_gap` leaves space between tiled windows and the display's usable edges;
`inner_gap` separates columns and stacked windows in Tall and Mirror Tall.
Both default to `0`, accept values from `0` to `64`, and use macOS logical points
(one point is two physical pixels on a 2× Retina display), rounded to whole points
when laying out windows. Full layout applies only the outer gap. Floating windows
keep their own frames. Gaps shrink on small displays or crowded stacks to keep
windows inside the usable area. Adjust them live in **快捷键与布局** in Settings,
or edit `[layout]` in the dotfile.

## Menu-bar status

Talus shows native Spaces and layout in the macOS menu bar. Space numbers are
positions on the focused display, a dot marks a full-screen Space, and `?`
means the Space list could not be read. This list uses an undocumented macOS
interface and may stop working after a system update; real multi-monitor
behavior remains unverified.

Configure the menu bar under `[status]` and `[[status.commands]]` in `~/.talus.toml` (or in the **菜单栏** tab of the Settings window):

```toml
[status]
show_icon = true
space_labels = ["term", "web", "chat"]
template = "%spaces%  <fc=#89CFC2>%layout%</fc>  %clock%"
workspace_current = "<fc=#10201E,#89CFC2> %label%%fullscreen% </fc>"
workspace_other = "%label%%fullscreen%"
fonts = ["Menlo-Regular"]

[[status.commands]]
name = "clock"
executable = "/bin/date"
arguments = ["+%H:%M"]
interval = 30
timeout = 2
```

Set `show_icon = false` if the text should occupy the entire item.
The supported substitutions are `%spaces%`, `%layout%`, `%title%`, `%count%`,
`%custom%`, and `%name%` for a configured command. `%%` emits a literal percent
sign. Workspace templates accept `%label%`, `%index%`, `%icon%`, `%occupied%`, and `%fullscreen%`
(`workspace_icons` supplies SF Symbol names or text icons for `%icon%`, while `<sf=symbol.name>` embeds any macOS SF Symbol inline).
`<fc=#RRGGBB>`, `<fc=#RRGGBB,#RRGGBB>`, and `<fc=,#RRGGBB>` (adaptive foreground)
set foreground and rounded-pill background, with nested `</fc>` tags; common colour names are also accepted.
`<box type=Bottom|Top|Full|HBoth|VBoth width=2 color=#RRGGBB>...</box>` draws xmobar-style underlines or pill borders.
`<fn=0>...</fn>` selects the first installed font named in `fonts`.
In `virtual` workspace mode, clicking any workspace segment in the menu bar switches directly to that workspace; right-clicking (or clicking the Talus icon / layout area) opens the menu.
`font_size` is in points (8–14). Missing fonts fall back to the system font.
Arbitrary Unicode characters are allowed, including glyphs supplied by installed
icon fonts. The menu item is capped at 400 points and may clip long output.

Commands are launched asynchronously as an executable and argument array (no
implicit shell). `interval` and `timeout` are seconds; output is bounded and
failed or timed-out commands display nothing. A command's output is literal by
default. Set `markup = true` on a command you trust to interpret its `<fc>`
and `<fn>` tags, including output from a Haskell program; see
`Examples/clock.hs`. To let a program render the whole item, set
`template = "%mybar%"` and define a `mybar` command with `markup = true`
(or choose **脚本完全接管** in the Settings UI).
The program can read the current state from `TALUS_STATUS_JSON`; an executable
example using Python's standard library is in `Examples/status.py`.
Set `on_change = true` to rerun it on Space, layout,
focus, count, or pause changes. The optional `state_file` also writes that JSON
atomically with owner-only permissions; setting it opts in to writing the
focused window title to disk.

Editable example configurations are in `Examples/status-compact.toml` and
`Examples/status-powerline.toml` (with legacy JSON equivalents kept alongside).

## Verification

`make test` runs pure tests, including TOML parsing, dotfile resolution, Settings UI view-model state, template parsing, command limits, and
window ordering. `make integration-test`, `make multi-integration-test`, and
`make latency-test` open isolated test windows; they require an unlocked macOS
desktop and Accessibility permission. `make haskell-status-test` exercises the Haskell example when `runghc` is installed.

Window discovery runs on a serial background queue. Structural events reconcile the
affected application, while a two-second full reconciliation remains as a fallback.
Focus events reuse cached geometry, and a confirmed programmatic focus releases its
echo guard immediately. Session saves are coalesced in the background and flushed
on exit. `make test` also checks event coalescing and rejection of stale discovery
results. `make virtual-integration-test` exercises real workspace throwing, rapid
switches, external focus, quit restoration, and the final saved session. Quit other
window managers before running the interactive integration tests.

`make focus-integration-test` compares the original and optimized focus paths
using real windows from two test applications. It checks the actual front process
and focused window rather than relying on activation requests returning success.
Focus uses two AX operations within an application and a third AXFrontmost write
when changing applications. A dynamically resolved, read-only process query avoids
NSWorkspace activation-cache lag; if unavailable, the activation write is retained.
AX errors fall back to the original focus sequence. `TALUS_LEGACY_FOCUS=1` forces
that sequence for compatibility comparisons. No SIP changes or process injection
are required.

Geometry writes run on a separate serial queue per application. Each window keeps
its latest complete target, so a superseded move cannot lose an earlier resize.
Each layout publishes its complete target snapshot, even when its sparse effect
list is empty; this supersedes any older queued target despite delayed physical
snapshots. The shell compares submitted goals rather than treating observed bounds
as proof that an asynchronous request has completed.
Logical input is processed in order; obsolete geometry and focus requests are
coalesced. Focus waits for the remaining geometry, and an explicit mouse click can
cancel queued focus. Pausing cancels queued writes; exit drains writes before
restoring parked windows. Main-thread status updates are coalesced and use cached
focus/title data. Read-only WindowServer bounds avoid a stalled application's AX
frame queries; unavailable bounds are refreshed through AX in the background.

`make window-executor-test` checks parallel applications, superseded goals, focus
barriers, cancellation, shutdown, and coalesced UI updates without moving windows.
`make layout-stress-test` uses two managed test applications and an unmanaged click
target. It briefly stops one fixture, issues resize/switch bursts, and verifies
that the other app progresses, an external click keeps focus, and quit restores
every parked window. It requires an unlocked desktop; quit other window managers
before running it. `TALUS_STRESS_BASELINE=1 TALUS_BIN=/path/to/old/talus` measures
the old path's resize delay without requiring it to pass the new concurrency checks.
`make xmonad-oracle XMONAD_SRC=/path/to/xmonad/src`
compares stack wraparound with XMonad and requires GHC.

The app icon is generated from vector drawing code in `src/macos/app_icon.gsa` (`talus --render-icon`).
The status image draws the same symbol next to the configured text.

New-window geometry is confirmed by reading the actual frame after AX writes.
Providers such as Zen can acknowledge before position/size has settled; an
unapplied target returns a retryable error instead of being cached as complete.
Foreground window-creation intent also supersedes an older queued focus once the
new window is discovered, preventing Full layout from raising the older window.
Explicit pointer or workspace input cancels that creation hint.
