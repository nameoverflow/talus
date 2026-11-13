# Talus

Experimental macOS window manager inspired by XMonad. Swift only; no X11. This is not yet a daily-use release.

Build and test with `make all test` on macOS with Xcode Command Line Tools. `make app` builds the ad-hoc-signed `build/Talus.app`, with a menu-bar control to pause and quit. macOS requires Accessibility permission. The app is not notarized, and rebuilding may require granting permission again. The program will move visible windows. Quit other window managers before starting and save your work. Control-C quits. Control-Option-P pauses/resumes.

Control-Option J/K focuses the next/previous window on the screen; add Shift to swap. Return swaps the focused window with master. H/L changes the master width. Comma/period changes the master count; Space cycles Tall, Mirror Tall, and Full; T toggles floating for the focused window. Window creation/destruction uses Accessibility notifications with a two-second fallback reconciliation.

Current prototype: Tall, Mirror Tall, and Full; uses macOS Spaces for desktop switching, and retains window ordering across a Space switch while running. No Talus workspace shortcuts, automatic floating rules, or login startup. Native Spaces switching and moving windows between them are handled by macOS. Individual applications can reject requested frames or omit notifications; real multi-app, multi-monitor and performance behavior remains to be tested. The program does not currently restore window positions on exit.

## Configuration

Optional `~/Library/Application Support/Talus/config.json` (restart Talus after editing):

```json
{
  "modifiers": ["control", "option"],
  "masterRatio": 0.5,
  "ratioStep": 0.03,
  "masterCount": 1,
  "ignoreApps": ["com.example.SomeApp"]
}
```

Every key is optional. Modifier names are `control`, `option`, and `command`; at least one is required, and Shift is reserved for swap shortcuts. Ratio must be 0.2–0.8, ratio step greater than zero and at most 0.2, and master count 1–20. `ignoreApps` contains application bundle identifiers. Invalid configuration prevents startup and is reported on standard error. Conflicting hotkeys are reported on standard error; other bindings remain available.

## Menu-bar status

Talus shows native Spaces and layout in the macOS menu bar. Space numbers are
positions on the focused display, a dot marks a full-screen Space, and `?`
means the Space list could not be read. This list uses an undocumented macOS
interface and may stop working after a system update; real multi-monitor
behavior remains unverified.

The optional `~/Library/Application Support/Talus/config.json` defines the
menu-bar text as a template. For example:

```json
{
  "spaceLabels": ["term", "web", "chat"],
  "statusShowIcon": true,
  "statusTemplate": "%spaces%  <fc=#89CFC2>%layout%</fc>  %clock%",
  "workspaceCurrent": "<fc=#10201E,#89CFC2> %label%%fullscreen% </fc>",
  "workspaceOther": "%label%%fullscreen%",
  "statusFonts": ["Menlo-Regular"],
  "statusCommands": [
    {"name": "clock", "executable": "/bin/date", "arguments": ["+%H:%M"], "interval": 30, "timeout": 2}
  ]
}
```

Set `statusShowIcon` to `false` if the text should occupy the entire item.
The supported substitutions are `%spaces%`, `%layout%`, `%title%`, `%count%`,
`%custom%`, and `%name%` for a configured command. `%%` emits a literal percent
sign. Workspace templates accept `%label%`, `%index%`, and `%fullscreen%`.
`<fc=#RRGGBB>` and `<fc=#RRGGBB,#RRGGBB>` set foreground and foreground plus
background, with nested `</fc>` tags; common colour names are also accepted.
`<fn=0>...</fn>` selects the first installed font named in `statusFonts`.
`statusFontSize` is in points (8–14). Missing fonts fall back to the system font.
Arbitrary Unicode characters are allowed, including glyphs supplied by installed
icon fonts. The menu item is capped at 400 points and may clip long output.

Commands are launched asynchronously as an executable and argument array (no
implicit shell). `interval` and `timeout` are seconds; output is bounded and
failed or timed-out commands display nothing. A command's output is literal by
default. Set `"markup": true` on a command you trust to interpret its `<fc>`
and `<fn>` tags, including output from a Haskell program; see
`Examples/clock.hs`. To let a program render the whole item, make
`statusTemplate` just `%mybar%` and define a `mybar` command with `markup: true`.
The program can read the current state from `TALUS_STATUS_JSON`; an executable
example using Python's standard library is in `Examples/status.py`.
Set `"onChange": true` to rerun it on Space, layout,
focus, count, or pause changes. Each run receives `TALUS_STATUS_JSON` with the
current status, so programs can compute their own string. The optional
`statusStateFile` also writes that JSON atomically with owner-only permissions;
setting it opts in to writing the focused window title to disk.

The older `statusFormat` and `statusTextFile` fields remain supported when
`statusTemplate` is omitted. Only the `<fc>` and `<fn>` formatting tags are interpreted; other tags are
shown as text. Configuration is Talus's own JSON format, not executable Haskell.
A configured Haskell program may emit the entire menu text and formatting.
Clicking the item opens the Talus menu; individual Space labels are not clickable.

Two editable example configurations are in `Examples/status-compact.json` and
`Examples/status-powerline.json`. Restart Talus after changing its configuration.

## Verification

`make test` runs pure tests, including template parsing, command limits, and
window ordering. `make integration-test`, `make multi-integration-test`, and
`make latency-test` open isolated test windows; they require a logged-in macOS
desktop and Accessibility permission. `make haskell-status-test` exercises the Haskell example when `runghc` is installed.
`make xmonad-oracle XMONAD_SRC=/path/to/xmonad/src`
compares stack wraparound with XMonad and requires GHC.

The app icon is generated from vector drawing code in `Scripts/DrawAppIcon.swift`.
The status image draws the same symbol next to the configured text.
