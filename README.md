# Talus

Experimental macOS window manager inspired by XMonad. Swift only; no X11. This is not yet a daily-use release.

Build and test with `make all test` on macOS with Xcode Command Line Tools. `make app` builds the ad-hoc-signed `build/Talus.app`, with a menu-bar control to pause and quit. macOS requires Accessibility permission. The app is not notarized, and rebuilding may require granting permission again. The program will move visible windows. Quit other window managers before starting and save your work. Control-C quits. Control-Option-P pauses/resumes.

Control-Option J/K focuses the next/previous window on the screen; add Shift to swap. Return swaps the focused window with master. H/L changes the master width. Comma/period changes the master count; Space cycles Tall, Mirror Tall, and Full. Window creation/destruction uses Accessibility notifications with a two-second fallback reconciliation.

Current prototype: Tall, Mirror Tall, and Full; uses macOS Spaces for desktop switching, and retains window ordering across a Space switch while running. No Talus workspace shortcuts, configuration, floating rules, or login startup. Native Spaces switching and moving windows between them are handled by macOS. Individual applications can reject requested frames or omit notifications; real multi-app, multi-monitor, Spaces and performance behavior remains to be tested. The program does not currently restore window positions on exit.
