# Talus User Manual

> Complete user guide for **Talus** — an XMonad-inspired tiling window manager for macOS 15+ written in 100% pure Geisha.

## Contents

1. [Requirements & Installation](#1-requirements--installation)
2. [Accessibility Permission & Persistent Local Signing](#2-accessibility-permission--persistent-local-signing)
3. [Layouts & Window Operations](#3-layouts--window-operations)
4. [Native Spaces vs. Virtual Workspaces](#4-native-spaces-vs-virtual-workspaces)
5. [Application Rules & Floating Windows](#5-application-rules--floating-windows)
6. [Settings Window & Live Reload](#6-settings-window--live-reload)
7. [Launch at Login](#7-launch-at-login)
8. [Command-Line Interface & Environment Variables](#8-command-line-interface--environment-variables)
9. [Troubleshooting & Known Caveats](#9-troubleshooting--known-caveats)

---

## 1. Requirements & Installation

- **Operating System**: macOS 15.0 (Sequoia) or later on Apple Silicon (`arm64`).
- **System Integrity Protection (SIP)**: Remains **fully enabled**. Talus uses only standard Accessibility (`AXUIElement`), Carbon global hotkeys, AppKit, `SMAppService`, and read-only WindowServer/SkyLight queries.

### Option A — Prebuilt Release

1. Download `Talus-macos-arm64.zip` (and optional `.sha256`) from [GitHub Releases](https://github.com/nameoverflow/talus/releases).
2. Extract the archive and move `Talus.app` into `/Applications/Talus.app`.
3. Launch `/Applications/Talus.app`. Because release builds are ad-hoc signed without Apple notarization, macOS Gatekeeper may ask you to confirm via **System Settings → Privacy & Security → Open Anyway**.

### Option B — Build from Source

Install the [Geisha](https://github.com/geisha-lang/geisha.gsa) toolchain (`~/.geisha/bin/geisha`), then:

```sh
git clone https://github.com/nameoverflow/talus.git
cd talus
make setup-cert   # optional, recommended: creates local code-signing certificate
make install      # builds & installs /Applications/Talus.app and starts it
make install-man  # optional: installs talus(1) and talus.toml(5) man pages
```

> **Note**: Always install Talus into `/Applications/Talus.app` rather than `~/Applications` so Launch Services, Login Items (`SMAppService.mainApp`), and Accessibility TCC grants track a single canonical bundle path.

---

## 2. Accessibility Permission & Persistent Local Signing

macOS requires Accessibility permission for any window manager to inspect and move other applications' windows.

1. Launch `Talus.app`. If not yet trusted, Talus prompts for Accessibility permission.
2. Open **System Settings → Privacy & Security → Accessibility** and enable **Talus**.
3. If macOS briefly reports `kAXErrorAPIDisabled` even after granting trust (a known TCC edge case right after toggling), Talus automatically relaunches itself once to pick up the fresh TCC session.

### Why `make setup-cert` Matters for Local Builds

Ad-hoc signatures (`-`) change their CDHash on every rebuild, causing macOS TCC to revoke Accessibility permission whenever you recompile. Running `make setup-cert` once creates a 10-year self-signed certificate named **`Talus Local Code Signing`** in your login keychain (trusted strictly for `Code Signing`).

For local development, you can also create an untracked `geisha.local.toml` in the repository root:

```toml
[target.macos]
codesign = "Talus Local Code Signing"
```

When `geisha.local.toml` is present, `make app` / `make install` preserves its configured signing identity automatically. For sharing a bundle with another Mac, always run `make dist`, which re-signs a separate copy with ad-hoc `-` to avoid unknown-certificate errors (`-67062`) on other machines.

---

## 3. Layouts & Window Operations

Talus organizes tiled windows on each display into a **master pane** and a **stack pane**.

```text
   Tall (default)             Mirror Tall                    Full
┌─────────┬───────┐        ┌─────────────────┐        ┌─────────────────┐
│         │  S 1  │        │     Master      │        │                 │
│ Master  ├───────┤        ├────────┬────────┤        │  Focused Window │
│         │  S 2  │        │  S 1   │  S 2   │        │   (outer_gap    │
│         ├───────┤        └────────┴────────┘        │     only)       │
│         │  S 3  │                                   │                 │
└─────────┴───────┘                                   └─────────────────┘
```

- **Tall**: Master pane on the left (`master_ratio`, default `0.5`); remaining windows stacked vertically on the right.
- **Mirror Tall**: Master pane across the top; remaining windows tiled horizontally below.
- **Full**: Every tiled window occupies the full usable display area (respecting `outer_gap` only); switching focus raises the newly focused window on top.

### Gaps

- `outer_gap` (`0..64` logical points): margin between tiled windows and the display's usable frame (menu bar / Dock excluded).
- `inner_gap` (`0..64` logical points): spacing between master and stack columns/rows and between stacked windows in `Tall` and `Mirror Tall`.
- On narrow displays or deeply stacked columns, Talus automatically shrinks gaps so windows never collapse or overflow the usable frame.

### Keyboard Controls

All shortcuts combine your configured `modifiers` (default `Control + Option`, written `<Mod>` below) with a key:

| Shortcut | Behavior |
| --- | --- |
| `<Mod> + J` / `K` | Focus next / previous window in the cyclic stack |
| `<Mod> + Shift + J` / `K` | Swap focused window with next / previous window |
| `<Mod> + Return` | Promote focused window to master (or swap master with first stack window) |
| `<Mod> + H` / `L` | Decrease / increase `master_ratio` by `ratio_step` (clamped to `0.2..0.8`) |
| `<Mod> + ,` / `.` | Increase / decrease `master_count` (`1..20`) |
| `<Mod> + Space` | Cycle `Tall` → `Mirror Tall` → `Full` |
| `<Mod> + T` | Toggle floating on the focused window (floating windows keep their own frames) |
| `<Mod> + P` | Pause / resume tiling; pausing restores parked virtual-workspace windows |
| `<Mod> + 1..9` | Switch to virtual workspace `1..count` (virtual mode only) |
| `<Mod> + Shift + 1..9` | Move focused window to virtual workspace `1..count` (virtual mode only) |

---

## 4. Native Spaces vs. Virtual Workspaces

Configure workspace management under `[workspaces]` in `~/.talus.toml` (or in **Settings → General**):

### Native Mode (`mode = "native"`, default)

- Talus tiles the visible windows on whatever macOS Space is active.
- The menu bar displays your native Spaces (using read-only SkyLight queries), marking full-screen Spaces with a dot (`•`) or `?` if Space metadata is unavailable.

### Virtual Mode (`mode = "virtual"`)

- Talus manages `count` (`1..9`) independent workspaces on top of a single macOS Space—giving you **instant, zero-animation** `<Mod>+1..9` switching.
- **1px Corner Parking**: Windows belonging to inactive workspaces are parked so 1 logical pixel remains on-screen at a display corner (required by macOS WindowServer so windows stay addressable without minimizing).
- **Per-Workspace State**: Each virtual workspace keeps its own layout (`Tall`/`Mirror`/`Full`), `master_ratio`, `master_count`, window stack order, and floating flags.
- **Session Persistence**: State is written asynchronously and atomically (`0o600` owner-only permissions) to:
  ```text
  ~/Library/Application Support/Talus/session-state.json
  ```
  and restored automatically on restart.
- **Safe Restoration**: Switching back to `native` mode, pausing (`<Mod>+P`), or quitting Talus cleanly restores every parked window back inside its display's usable frame before exiting.
- **Click-to-Switch**: Clicking a workspace badge in the macOS menu bar switches directly to that virtual workspace.

---

## 5. Application Rules & Floating Windows

Under `[rules]`, you can control how Talus treats specific applications by macOS Bundle Identifier (for example, `com.apple.Safari`, `com.mitchellh.ghostty`, `com.tencent.xinWeChat`):

- **`ignore_apps`**: Talus completely ignores all windows belonging to these apps.
- **`[rules.app_workspaces]`**: In `virtual` mode, newly discovered windows of a matched app are automatically assigned to the target workspace (by 1-based number `1..9` or by workspace label name).
- **`[[rules.float_windows]]`**: Automatically float matching windows—either all windows of an app, only titles matching `titles` (case-insensitive substring or `*` glob), or all windows *except* main titles listed in `except_titles`.

See [Configuration Reference](CONFIGURATION.md#rules-section) for full syntax and examples.

---

## 6. Settings Window & Live Reload

Open the native AppKit Settings window in any of three ways:

- Click the Talus menu-bar item → **设置…** (`⌘,`)
- Reopen `/Applications/Talus.app` while it is already running
- Run `/Applications/Talus.app/Contents/MacOS/Talus --settings` (optionally `--tab=general|layout|rules|status`)

### Comment-Preserving Saves

Saving from the Settings UI patches your existing TOML file in place using Geisha's `std.toml.patch`, keeping your comments, blank lines, and unrelated formatting intact.

### External Editing & Hot Reload

Talus watches the active config file's modification time (every ~2 seconds) and also provides **重新载入配置 (`⌘R`)** in the menu bar. Invalid syntax or out-of-range values during live reload are logged to stderr without crashing the running session.

---

## 7. Launch at Login

Talus manages login startup via Apple's `SMAppService.mainApp` API.

- Toggle **登录后自动启动** in **Settings → General** or directly from the **menu-bar dropdown menu**.
- State is owned by macOS Login Items—never stored in `~/.talus.toml` and never auto-registered silently when opening Settings.
- If macOS reports `.requiresApproval`, the switch stays off and Settings displays a direct button to open **System Settings → General → Login Items**.

---

## 8. Command-Line Interface & Environment Variables

### CLI Flags

```text
Talus [--settings] [--settings-only] [--tab=general|layout|rules|status]
      [--render-icon <out.png>] [--render-previews <dir>] [--probe-login-item]
```

| Flag | Purpose |
| --- | --- |
| `--settings` | Launch Talus normally and immediately open the Settings window |
| `--settings-only` | Open only the Settings window without starting tiling or hotkeys |
| `--tab=<name>` | Select initial Settings tab (`general`, `layout`, `rules`, `status`) |
| `--render-icon <out.png>` | Render Talus's 1024×1024 vector app icon PNG and exit |
| `--render-previews <dir>` | Render 2x Retina dark/light Settings window screenshots and exit |
| `--probe-login-item` | Isolated `SMAppService` test probe (refuses to run outside bundle ID `local.talus.testing.login`) |

### Environment Variables

| Variable | Effect |
| --- | --- |
| `TALUS_CONFIG` | Explicit path to a `.toml` or `.json` config file (overrides standard lookup order; supports `~`) |
| `TALUS_LEGACY_FOCUS=1` | Force legacy full focus activation sequence instead of optimized `_SLPSGetFrontProcess` path |
| `TALUS_TRACE_EVENTS=1` | Print Accessibility, workspace, and executor diagnostic events to stderr |
| `TALUS_TRACE_STATUS=1` | Print menu-bar status rendering diagnostics to stderr |
| `TALUS_TEST_PID` | Restrict window discovery/management to specific PID(s) during automated integration tests |
| `TALUS_TEST_HOTKEYS=1` | Keep Carbon hotkeys active even when `TALUS_TEST_PID` is set |

---

## 9. Troubleshooting & Known Caveats

- **Accessibility stops working after rebuilding**: Run `make setup-cert` once and rebuild with `make install` so the signature remains `Talus Local Code Signing`.
- **Apps that delay applying AX geometry (e.g., Zen Browser)**: Talus verifies every move/resize by reading back the actual AX frame after writing; if an app acknowledges before settling, Talus treats it as retryable rather than caching a wrong position.
- **Smooth-move slide-in animations when switching virtual workspaces**: Talus temporarily disables each app's `AXEnhancedUserInterface` attribute during geometry writes and restores its original value afterward.
- **Multi-monitor native Spaces**: Native Space enumeration relies on undocumented read-only SkyLight interfaces; real multi-display edge cases may vary across macOS point releases.
- **Single-instance lock**: Talus holds an advisory `flock` lock in `$TMPDIR` so a second launch does not fight the running instance for hotkeys or window frames.
