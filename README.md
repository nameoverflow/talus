# Talus

Experimental macOS window manager inspired by XMonad. Swift only; no X11. This is not yet a daily-use release.

Build and test with `make all test` on macOS with Xcode Command Line Tools. Run `build/talus`; macOS requires Accessibility permission. The program will move visible windows. Quit other window managers before starting and save your work. Control-C quits. Control-Option-P pauses/resumes.

Control-Option J/K focuses the next/previous window on the screen; add Shift to swap. Return swaps the focused window with master. H/L changes the master width. Comma/period changes the master count; Space forces a retile. Window creation/destruction uses Accessibility notifications with a two-second fallback reconciliation.

Current prototype: Tall only, no workspace switching, configuration, floating rules, login startup, or packaged app. Individual applications can reject requested frames or omit notifications; real multi-app, multi-monitor, Spaces and performance behavior remains to be tested. The program does not currently restore window positions on exit.

The `workspace-experiment` branch adds experimental Control-Option 1–9 switching and Control-Option-Shift 1–9 moving, implemented via window minimization. This is not ready for daily use: animations cause visible delays and transient overlaps; app refusal and abrupt termination can leave windows minimized. Normal Ctrl-C/SIGTERM attempts to restore windows. Workspaces are global across screens and do not persist between runs.
