# Talus

Experimental macOS window manager inspired by XMonad. Swift only; no X11. This is not yet a daily-use release.

Build and test with `make all test` on macOS with Xcode Command Line Tools. Run `build/talus`; macOS requires Accessibility permission. The program will move visible windows. Quit other window managers before starting and save your work. Control-C quits. Control-Option-P pauses/resumes.

Control-Option J/K focuses the next/previous window on the screen; add Shift to swap. Return swaps the focused window with master. H/L changes the master width. Comma/period changes the master count; Space cycles Tall, Mirror Tall, and Full. Window creation/destruction uses Accessibility notifications with a two-second fallback reconciliation.

Current prototype: Tall, Mirror Tall, and Full; uses macOS Spaces for desktop switching, and retains window ordering across a Space switch while running. No Talus workspace shortcuts, configuration, floating rules, login startup, or packaged app. Native Spaces switching and moving windows between them are handled by macOS. Individual applications can reject requested frames or omit notifications; real multi-app, multi-monitor, Spaces and performance behavior remains to be tested. The program does not currently restore window positions on exit.
