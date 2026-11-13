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

## Verification

`make test` runs the pure layout, configuration, ordering and stack tests. `make integration-test` opens isolated test windows and checks tiling and fixed-size handling; it requires a logged-in macOS desktop and Accessibility permission. The integration test limits Talus to its own fixture process and closes it afterward. `make multi-integration-test` checks four windows across two isolated fixture processes; `make latency-test` measures an isolated window creation event to layout. These also open temporary test windows. `make xmonad-oracle XMONAD_SRC=/path/to/xmonad/src` additionally compares stack wraparound with XMonad and requires GHC.

The app icon is generated from vector drawing code in `Scripts/DrawAppIcon.swift`. The menu bar uses the matching monochrome template in `Sources/StatusIcon.swift`, so macOS supplies the appropriate tint.

## Menu-bar status

Talus shows the native Spaces of the focused display in the macOS menu bar:
`[1] 2•  Tall` means Space 1 is current and Space 2 is a full-screen Space.
Numbers are positions on that display. The native Space list uses an
undocumented macOS interface and may stop working after a system update; `?`
means it is unavailable, rather than guessing. When macOS is configured to use
separate Spaces per display, this first version shows the focused display's
list; behavior on real multi-monitor setups remains unverified.

The optional config fields `statusFormat`, `statusTextFile`, and
`statusStateFile` provide scripting integration. For example:

```json
{
  "statusFormat": "{spaces} | {layout} | {title} | {custom}",
  "statusTextFile": "~/Library/Application Support/Talus/custom.txt",
  "statusStateFile": "~/Library/Application Support/Talus/status.json"
}
```

Available fields are `{spaces}`, `{layout}`, `{title}`, `{count}`, and
`{custom}`. The custom text file is read at most every two seconds; a program
may write UTF-8 text there. The optional state file is atomically replaced on
changes with JSON including Space identifiers, active flags, layout, window
count, focus title and pause state. It is created with owner-only permissions;
selecting `statusStateFile` explicitly opts in to writing the active window
title to disk. Neither file is used unless configured. Restart Talus after
editing the JSON configuration.
