# Architecture & Internals

Talus is structured as a **100% pure-Geisha** codebase (`src/*.gsa` + `src/macos/*.gsa`), built directly into a native `arm64` macOS `.app` bundle via `geisha build --target macos-app` and [`github.com/geisha-lang/objc.gsa`](https://github.com/geisha-lang/objc.gsa)—with zero Rust, zero Swift, and zero custom C shims.

---

## 1. High-Level Data Flow

```text
  Carbon Hotkeys ──┐
  AXObserver Evts ─┼──► Main RunLoop (src/main.gsa)
  Config Watcher  ─┤        │
  Status Clicks   ─┘        ▼
                     ManagerCore (pure, src/manager.gsa)
                      • layout.gsa / screen_geometry.gsa
                      • window_stack.gsa / virtual_workspaces.gsa
                      • config.gsa (std.toml.patch)
                            │
        ┌───────────────────┼───────────────────┐
        ▼                   ▼                   ▼
  Per-PID Actors     StatusCommandsEngine  SessionWriter
  (executor.gsa +    (sys.proc own-group   (0o600 atomic
   window_discovery)  async + timeout)      debounced save)
        │                   │
        ▼                   ▼
  AXUIElement /      NSStatusItem Rich
  _SLPSGetFront      AppKit Render +
  Process            Settings Window
```

---

## 2. Pure Core Engine (`src/*.gsa`)

All window-management invariants live in pure, unit-testable Geisha modules with zero AppKit or Accessibility dependencies:

- **`layout.gsa`**: Computes exact `Rect` tiles for `Tall`, `Mirror Tall`, and `Full`, enforcing outer/inner gaps (`0..64` pt), whole-point rounding, graceful gap shrinking on constrained displays, and strict non-overlap / area invariants.
- **`screen_geometry.gsa`**: Converts between macOS AppKit (bottom-left origin) and Accessibility/Quartz (top-left origin) coordinates and computes 1px corner parking targets for inactive virtual workspaces.
- **`window_stack.gsa` & `window_history.gsa`**: XMonad-inspired cyclic stack navigation/swapping plus MRU focus history so closing or floating a window restores the most natural predecessor.
- **`virtual_workspaces.gsa` & `session_writer.gsa`**: Manages 1–9 virtual workspaces, per-workspace layouts, float flags, and coalesced background persistence (`sys.fs.writeFileAtomicMode(..., 0o600)`).
- **`config.gsa`**: Decodes TOML and legacy JSON, validates every bound, resolves dotfile precedence, and saves Settings changes in place via `std.toml.patch` so user comments remain untouched.
- **`status_markup.gsa` & `status_commands.gsa`**: Parses `<fc>/<box>/<fn>/<sf>` tags, computes workspace click hit regions, exports sorted-key JSON, and runs external commands in isolated POSIX process groups (`cmdOwnGroup`) with 4 KB pipe draining and `SIGTERM`→`SIGKILL` timeout enforcement.
- **`manager.gsa`**: Pure `ManagerCore` state machine that processes candidate snapshots, hotkeys, workspace switches, focus confirmations, and config reloads, emitting full geometry goal snapshots and focus/status effects.

---

## 3. Per-PID `std.actor` Concurrency (`src/macos/executor.gsa`, `window_discovery.gsa`)

macOS Accessibility (`AXUIElement`) IPC is synchronous per target application—a single stalled or slow app must never freeze tiling for other applications or block the main AppKit RunLoop.

Talus solves this cleanly under Geisha's compile-time `Send` checker:

- **One `Actor AppExecState` per application PID**:
  - `AXUIElement` handles (`ForeignPtr` with `CFRelease` finalizers) are created, cached, and released **exclusively inside that PID's Actor thread**.
  - Cross-thread communication passes only pure `Send` values (`WindowGoal`, `AppDiscoveryOutcome`, `ExecEvent`) over `Chan` / `MVar`—zero raw-pointer integer smuggling.
- **Parallel across apps, coalesced within an app**:
  - Window discovery fans out across running apps in parallel.
  - Geometry writes execute concurrently across distinct PIDs while superseding unstarted goals for the same window inside a single app's mailbox, always carrying the complete latest `(position, size)` target so a rapid move never drops a pending resize.
- **Full-snapshot goal publication & focus barriers**:
  - Every layout pass publishes the complete target snapshot (even when sparse diffs are empty) so stale queued moves are reliably superseded.
  - Programmatic focus waits for pending geometry barriers to settle, and explicit mouse/workspace input cancels stale queued focus immediately.
  - On quit, the executor drains in-flight geometry writes before restoring parked windows.
- **Main-thread event pump**:
  - Background Actors post `ExecEvent`s to a `Chan` and nudge the main AppKit RunLoop via `+[TalusMainEventPump performSelectorOnMainThread:@selector(pump) withObject:nil waitUntilDone:NO]`, avoiding global `Cell` taint across `Send` boundaries.

---

## 4. macOS Accessibility & Focus Invariants

- **Real frontmost process query (`src/macos/window_focus.gsa`)**:
  - Dynamically resolves read-only `_SLPSGetFrontProcess` + `GetProcessPID` via `sys.ffi` to avoid lag in `NSWorkspace.frontmostApplication`.
  - Normal focus uses `AXMain` + `AXRaise` within the same app and adds `AXFrontmost` when switching apps, falling back to the legacy full sequence on AX errors (or when `TALUS_LEGACY_FOCUS=1`).
- **Move animation guard & read-back settlement (`src/macos/ax_io.gsa`)**:
  - Temporarily sets `AXEnhancedUserInterface = false` on the target application before moving/resizing and restores the previous boolean afterward, preventing slow slide-in animations from parked corners.
  - Reads back the actual AX frame after writing; if an app (such as Zen Browser during window initialization) acknowledges before applying the frame, returns a retryable result instead of caching a false success.
- **`objc.gsa` ownership & lazy registration**:
  - Uses `+1` `alloc`/`init` for owned Foundation containers passed to `idAdopt` (avoiding over-release of `+0` autoreleased factories).
  - Registers dynamic ObjC helper classes lazily after `main()` starts.

---

## 5. Testing & CI Strategy

| Suite / Command | Scope |
| --- | --- |
| `Tests/core_tests.gsa` | Layout geometry, area conservation, screen parking, window stack/history, TOML decode/patch, virtual workspaces, atomic session writer, status markup, process-group commands, `ManagerCore` |
| `Tests/macos_tests.gsa` | AX geometry I/O & animation guard, SkyLight Spaces parser, `LaunchAtLogin` state machine, per-PID Actor coalescing/parallelism/settlement, vector icon & rich status rendering |
| `Tests/settings_tests.gsa` | Argument parser, `SettingsViewModel` modifiers, presets, comment-preserving TOML saves, preview generation |
| `make deployment-test` | Verifies actual Mach-O `LC_BUILD_VERSION minos == 15.0` via `xcrun vtool` |
| `make status-cleanup-test` | Spawns a child status command and confirms process-group teardown on Talus exit |
| `make integration-test` | Live desktop smoke test verifying tiling of resizable fixtures while preserving fixed-size windows |
| `make launch-at-login-integration-test` | Exercises `SMAppService.mainApp` register/read/unregister on an isolated signed `local.talus.testing.login` bundle |
