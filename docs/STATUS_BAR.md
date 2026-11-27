# Status Bar & Scripting Guide

Talus renders an xmobar-inspired rich status bar directly inside a native macOS `NSStatusItem` (capped at 400 logical points width to keep the menu bar tidy).

## 1. Template Placeholders

Set `[status].template` in `~/.talus.toml`:

| Token | Meaning |
| --- | --- |
| `%spaces%` | Rendered list of native Spaces or virtual workspaces (using `workspace_current` / `workspace_other`) |
| `%layout%` | Current layout (`Tall`, `Mirror`, `Full`, or `Paused`) |
| `%title%` | Title of the currently focused window |
| `%count%` | Number of managed windows on the active Space/workspace |
| `%custom%` | Trimmed contents of `[status].text_file` (if configured) |
| `%<name>%` | Latest stdout from a configured `[[status.commands]]` entry |
| `%%` | Literal `%` character |

### Workspace Sub-Templates (`workspace_current` / `workspace_other`)

| Token | Meaning |
| --- | --- |
| `%label%` | Custom label from `labels`/`space_labels`, falling back to the 1-based index |
| `%index%` | 1-based workspace or Space index (`1`, `2`, …) |
| `%icon%` | Entry from `icons`/`workspace_icons` (rendered as an SF Symbol if valid, otherwise literal text) |
| `%occupied%` | Non-empty indicator when the workspace currently holds windows |
| `%fullscreen%` | `•` marker when a native Space is in macOS full-screen mode |

---

## 2. Rich Markup Grammar

Templates and trusted commands (`markup = true`) support nested tags (max nesting depth 16):

### Foreground & Pill Background (`<fc=...>...</fc>`)

- `<fc=#89CFC2>text</fc>` — foreground color only
- `<fc=#10201E,#89CFC2> text </fc>` — foreground + rounded-pill background
- `<fc=,#34414F> text </fc>` — adaptive foreground + rounded-pill background
- Supports `#RRGGBB` hex colors as well as common CSS/xmobar color names (`white`, `black`, `red`, `green`, `blue`, `yellow`, `cyan`, `magenta`, `orange`, `gray`, etc.).

### Borders & Underlines (`<box ...>...</box>`)

Draws xmobar-style underlines or rounded frames around a segment:

```text
<box type=Bottom width=2 color=#89CFC2> %label% </box>
<box type=Full width=1 color=#D37859 radius=4> %layout% </box>
```

Supported `type` values: `Bottom`, `Top`, `Full`, `HBoth`, `VBoth`. Optional `width` (points), `color`, and `radius`.

### Custom Fonts (`<fn=N>...</fn>`)

Selects the 0-based font index from `[status].fonts` (up to 16 fonts). Missing or uninstalled fonts gracefully fall back to the macOS system font. Base size is controlled by `[status].font_size` (`8.0..14.0` pt, default `11.5`).

```toml
[status]
fonts = ["Menlo-Regular", "SFMono-Semibold"]
font_size = 11.5
template = "%spaces%  <fn=1>%layout%</fn>  <fn=0>%clock%</fn>"
```

### Inline SF Symbols (`<sf=symbol.name>`)

Embeds any macOS SF Symbol inline, automatically tinted with the active `<fc>` foreground color:

```toml
template = "%spaces%  <fc=#89CFC2><sf=rectangle.split.2x1> %layout%</fc>  <sf=clock> %clock%"
```

---

## 3. Asynchronous Status Commands (`[[status.commands]]`)

External commands run asynchronously via Geisha's `sys.proc` inside their own POSIX process group (`cmdOwnGroup`):

- **No implicit shell**: `executable` must be an absolute path (`/bin/date`, `/usr/bin/env`, `/opt/homebrew/bin/...`) and `arguments` is passed verbatim as `argv`.
- **Bounded output**: stdout is drained safely up to 4 KB to prevent pipe deadlocks or SIGPIPE.
- **Guaranteed cleanup**: Timed-out commands and all running child processes receive `SIGTERM` followed by `SIGKILL` to the entire process group on timeout or Talus exit (verified by `make status-cleanup-test`).
- **Safe by default**: `markup` defaults to `false` so untrusted text (such as song titles or browser tabs containing `<` / `>`) cannot inject formatting tags.

### Example: Compact Clock + Battery

```toml
[status]
show_icon = true
template = "%spaces%  <fc=#89CFC2>%layout%</fc>  %clock%"
workspace_current = "<fc=#10201E,#89CFC2> %label%%fullscreen% </fc>"
workspace_other = "%label%%fullscreen%"

[[status.commands]]
name = "clock"
executable = "/bin/date"
arguments = ["+%H:%M"]
interval = 30
timeout = 2
```

---

## 4. Script Takeover & `TALUS_STATUS_JSON`

Every status command receives the current window-manager snapshot in the environment variable `TALUS_STATUS_JSON` (sorted keys):

```json
{
  "count": 3,
  "layout": "Tall",
  "paused": false,
  "spaces": [
    { "id": 1, "isCurrent": true, "isFullscreen": false, "windowCount": 2 },
    { "id": 2, "isCurrent": false, "isFullscreen": false, "windowCount": 1 }
  ],
  "title": "talus — zsh"
}
```

Set `on_change = true` and `markup = true` to let a script (Python, Haskell, Geisha, etc.) render the entire menu bar reactively on every Space, layout, focus, count, or pause change:

```toml
[status]
show_icon = false
template = "%mybar%"

[[status.commands]]
name = "mybar"
executable = "/usr/bin/python3"
arguments = ["/Users/you/.config/talus/status.py"]
interval = 60
timeout = 2
markup = true
on_change = true
```

See ready-to-run examples in [`Examples/status.py`](../Examples/status.py), [`Examples/clock.hs`](../Examples/clock.hs), [`Examples/status-compact.toml`](../Examples/status-compact.toml), and [`Examples/status-powerline.toml`](../Examples/status-powerline.toml).

### Atomic `state_file` Export

Setting `[status].state_file` (e.g. `"/tmp/talus-state.json"`) opts in to writing the exact same JSON snapshot atomically via `sys.fs.writeFileAtomicMode(..., 0o600)` so external bars (SketchyBar, SwiftBar, shell prompts) can read it without polling Talus.

---

## 5. Click Hit-Testing

In `virtual` workspace mode, each rendered workspace segment records its pixel hit-rect (`StatusWorkspaceHitRegion`). On click, Talus converts `NSEvent.mouseLocation` through the status item's window and button coordinate space (avoiding a macOS AppKit quirk where `NSApp.currentEvent.locationInWindow` can synthesize the button center) so clicking any workspace pill switches cleanly to that workspace while right-clicking or clicking outside workspace pills opens the Talus menu.
