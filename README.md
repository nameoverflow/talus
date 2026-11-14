# Talus

Experimental macOS window manager inspired by XMonad. Swift only; no X11. This is not yet a daily-use release.

Build and test with `make all test` on macOS with Xcode Command Line Tools. `make app` builds the ad-hoc-signed `build/Talus.app`, with a menu-bar control to pause, open Settings (`⌘,`), reload configuration, and quit. macOS requires Accessibility permission. The app is not notarized, and rebuilding may require granting permission again. The program will move visible windows. Quit other window managers before starting and save your work. Control-C quits. Control-Option-P pauses/resumes.

Control-Option J/K focuses the next/previous window on the screen; add Shift to swap. Return swaps the focused window with master. H/L changes the master width. Comma/period changes the master count; Space cycles Tall, Mirror Tall, and Full; T toggles floating for the focused window. Window creation/destruction uses Accessibility notifications with a two-second fallback reconciliation.

Current features: Tall, Mirror Tall, and Full layouts; switchable **native Spaces** (`mode = "native"`) or **Talus virtual workspaces** (`mode = "virtual"`, `count = 1..9`) with instant `<Mod>+1..9` workspace switching, `<Mod>+Shift+1..9` window throwing, independent per-workspace layout state, and automatic restoration of parked windows on quit or mode switch.

## Configuration (TOML Dotfile & Graphical Settings UI)

Talus reads its configuration in the following order (unless `TALUS_CONFIG` is set):

1. `~/.talus.toml` (primary dotfile in home directory)
2. `~/.config/talus/config.toml`
3. `~/Library/Application Support/Talus/config.toml`
4. `~/Library/Application Support/Talus/config.json` (legacy JSON fallback)

You can configure Talus either through the built-in **Settings window** (click the Talus menu-bar item → **设置…** / `⌘,`, reopen `Talus.app`, or run `talus --settings`) or by editing `~/.talus.toml` directly. Changes saved from the Settings UI or written to the dotfile on disk are applied live without restarting Talus.

Example `~/.talus.toml`:

```toml
modifiers = ["option"]

[workspaces]
mode = "virtual"
count = 5

[layout]
master_ratio = 0.5
ratio_step = 0.03
master_count = 1

[rules]
ignore_apps = ["com.example.SomeApp"]
```

Every key is optional. Modifier names are `control`, `option`, and `command`; at least one is required, and Shift is reserved for swap shortcuts. Ratio must be 0.2–0.8, ratio step greater than zero and at most 0.2, and master count 1–20. `ignore_apps` contains application bundle identifiers. Invalid configuration at startup is reported on standard error (or via an alert when launched as an app); invalid edits while running are logged without crashing the running session.

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
sign. Workspace templates accept `%label%`, `%index%`, and `%fullscreen%`.
`<fc=#RRGGBB>` and `<fc=#RRGGBB,#RRGGBB>` set foreground and foreground plus
background, with nested `</fc>` tags; common colour names are also accepted.
`<fn=0>...</fn>` selects the first installed font named in `fonts`.
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
`make latency-test` open isolated test windows; they require a logged-in macOS
desktop and Accessibility permission. `make haskell-status-test` exercises the Haskell example when `runghc` is installed.
`make xmonad-oracle XMONAD_SRC=/path/to/xmonad/src`
compares stack wraparound with XMonad and requires GHC.

The app icon is generated from vector drawing code in `Scripts/DrawAppIcon.swift`.
The status image draws the same symbol next to the configured text.
