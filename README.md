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
  "masterCount": 1,
  "ignoreApps": ["com.example.SomeApp"]
}
```

Every key is optional. Modifier names are `control`, `option`, and `command`; at least one is required, and Shift is reserved for swap shortcuts. Ratio must be 0.2–0.8 and master count 1–20. `ignoreApps` contains application bundle identifiers. Invalid configuration prevents startup and is reported on standard error. Conflicting hotkeys are reported on standard error; other bindings remain available.

## Verification

`make test` runs the pure layout, configuration, ordering and stack tests. `make integration-test` opens isolated test windows and checks tiling and fixed-size handling; it requires a logged-in macOS desktop and Accessibility permission. The integration test limits Talus to its own fixture process and closes it afterward. `make xmonad-oracle XMONAD_SRC=/path/to/xmonad/src` additionally compares stack wraparound with XMonad and requires GHC.
