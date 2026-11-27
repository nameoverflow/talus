# Configuration Reference (`~/.talus.toml`)

Every key in Talus's configuration is optional; omitted fields fall back to their defaults. All validation bounds below match `src/config.gsa` verbatim.

## File Resolution Precedence

Unless `TALUS_CONFIG` is set in the environment, Talus searches in this order:

1. `~/.talus.toml` *(primary dotfile)*
2. `~/.config/talus/config.toml` *(XDG-style)*
3. `~/Library/Application Support/Talus/config.toml`
4. `~/Library/Application Support/Talus/config.json` *(legacy JSON fallback)*

If none of these exist, Talus runs with defaults and creates `~/.talus.toml` when you save from Settings. If only legacy `config.json` exists, Talus reads it and migrates to `~/.talus.toml` on the first UI save.

---

## Top-Level Keys

### `modifiers`

- **Type**: `Array<String>`
- **Default**: `["control", "option"]`
- **Allowed values**: `"control"`, `"option"`, `"command"` (at least 1, no duplicates).
- **Note**: `"shift"` is reserved for swap (`<Mod>+Shift+J/K`) and workspace throw (`<Mod>+Shift+1..9`) shortcuts and cannot be included here.

```toml
modifiers = ["control", "option"]
```

---

## `[workspaces]`

| Key | Type | Default | Constraints | Description |
| --- | --- | --- | --- | --- |
| `mode` | `String` | `"native"` | `"native"` or `"virtual"` | Follow macOS Spaces or manage virtual workspaces |
| `count` | `Integer` | `5` | `1..9` | Number of virtual workspaces in `"virtual"` mode |
| `labels` | `Array<String>` | `[]` | ≤ 32 items, 1–16 chars each | Display labels for workspaces (`%label%`); also accepted as `[status].space_labels` |
| `icons` | `Array<String>` | `[]` | ≤ 32 items, 1–64 chars each | SF Symbol names or text glyphs for `%icon%`; also accepted as `[status].workspace_icons` |

```toml
[workspaces]
mode = "virtual"
count = 5
labels = ["term", "web", "code", "chat", "misc"]
icons = ["terminal", "safari", "chevron.left.forwardslash.chevron.right", "bubble.left", "tray"]
```

---

## `[layout]`

| Key | Type | Default | Constraints | Description |
| --- | --- | --- | --- | --- |
| `master_ratio` | `Float` | `0.5` | `0.2 .. 0.8` | Fraction of screen width (Tall) or height (Mirror Tall) given to the master pane |
| `ratio_step` | `Float` | `0.03` | `(0.0, 0.2]` | Adjustment increment per `<Mod>+H` / `<Mod>+L` keypress |
| `master_count` | `Integer` | `1` | `1 .. 20` | Initial number of windows placed in the master pane |
| `outer_gap` | `Float` | `0.0` | `0.0 .. 64.0` | Outer screen margin in macOS logical points (applied to Tall, Mirror Tall, and Full) |
| `inner_gap` | `Float` | `0.0` | `0.0 .. 64.0` | Inter-window gap in macOS logical points (Tall and Mirror Tall only) |

```toml
[layout]
master_ratio = 0.55
ratio_step = 0.03
master_count = 1
outer_gap = 10
inner_gap = 8
```

---

## `[rules]`

<a id="rules-section"></a>

### `ignore_apps`

- **Type**: `Array<String>`
- **Default**: `[]`
- Bundle identifiers whose windows Talus never manages, moves, or tiles.

```toml
[rules]
ignore_apps = [
  "com.apple.systempreferences",
  "com.raycast.macos",
]
```

### `[rules.app_workspaces]`

- **Type**: Table of `bundle_id = Integer (1..9) | String (workspace label)`
- **Constraints**: Up to 64 entries; non-empty trimmed bundle ID ≤ 200 chars; target `1..9` or label ≤ 16 chars.
- In `virtual` mode, routes newly discovered windows of an application to a fixed workspace.

```toml
[rules.app_workspaces]
"com.mitchellh.ghostty" = "term"
"com.apple.Safari" = "web"
"com.apple.mail" = 4
```

### `[[rules.float_windows]]`

- **Type**: Array of tables (up to 64 rules)
- Automatically floats windows matching the rule while keeping other windows of the same application tiled.

| Key | Type | Required | Constraints | Description |
| --- | --- | --- | --- | --- |
| `app` | `String` | Yes | 1–200 chars, trimmed | Application bundle identifier |
| `titles` | `Array<String>` | No | ≤ 32 patterns, ≤ 200 chars each | Float if window title matches any pattern |
| `except_titles` | `Array<String>` | No | ≤ 32 patterns, ≤ 200 chars each | Exclude matching titles from floating (takes precedence over `titles`) |

**Title matching semantics**:
- Patterns containing `*` use case-insensitive ASCII wildcard globbing (e.g. `"*Picture-in-Picture*"`, `"Settings*"`).
- Patterns without `*` in `titles` perform case-insensitive substring matching (an empty string `""` matches untitled windows).
- Patterns without `*` in `except_titles` match exact titles (case-insensitive).
- Omitting both `titles` and `except_titles` floats all windows of `app`.

```toml
# Float WeChat media viewer & sub-windows, keep main chat window tiled
[[rules.float_windows]]
app = "com.tencent.xinWeChat"
except_titles = ["微信", "WeChat"]

# Float browser DevTools & Picture-in-Picture popups
[[rules.float_windows]]
app = "app.zen-browser.zen"
titles = ["*Picture-in-Picture*", "Developer Tools*"]
```

---

## `[status]`

| Key | Type | Default | Constraints | Description |
| --- | --- | --- | --- | --- |
| `show_icon` | `Bool` | `true` | — | Show the Talus vector emblem next to status text |
| `template` | `String` | *(none)* | ≤ 1024 chars | Rich status template using `%tokens%` and `<fc>/<box>/<fn>/<sf>` tags (supersedes legacy `format`) |
| `format` | `String` | `"{spaces}  {layout}"` | ≤ 160 chars | Legacy format string used when `template` is omitted |
| `workspace_current` | `String` | `"<fc=#10201E,#89CFC2> %label%%fullscreen% </fc>"` | ≤ 512 chars | Markup template for the active Space / workspace |
| `workspace_other` | `String` | `"%label%%fullscreen%"` | ≤ 512 chars | Markup template for inactive Spaces / workspaces |
| `space_labels` | `Array<String>` | `[]` | ≤ 32 items, 1–16 chars | Alias for `[workspaces].labels` |
| `workspace_icons` | `Array<String>` | `[]` | ≤ 32 items, 1–64 chars | Alias for `[workspaces].icons` |
| `fonts` | `Array<String>` | `[]` | ≤ 16 names, 1–100 chars | Font list indexed by `<fn=0>`, `<fn=1>`, … |
| `font_size` | `Float` | `11.5` | `8.0 .. 14.0` | Base menu-bar font size in points |
| `text_file` | `String` | *(none)* | Must differ from `state_file` | Optional text file read into `%custom%` |
| `state_file` | `String` | *(none)* | Must differ from `text_file` | Optional path where Talus atomically writes JSON status (`0o600`) |

---

## `[[status.commands]]`

Up to **16** asynchronous external commands, referenced in `[status].template` as `%<name>%`.

| Key | Type | Default | Constraints | Description |
| --- | --- | --- | --- | --- |
| `name` | `String` | *(required)* | 1–32 chars `[A-Za-z][A-Za-z0-9_-]*`, unique, non-reserved | Placeholder name (`%name%`) |
| `executable` | `String` | *(required)* | Absolute path starting with `/`, ≤ 1024 chars | Executable launched directly (no implicit shell) |
| `arguments` | `Array<String>` | `[]` | ≤ 32 args, ≤ 1024 chars each | Argument vector |
| `interval` | `Float` | `10.0` | `1.0 .. 3600.0` | Polling period in seconds |
| `timeout` | `Float` | `2.0` | `0.1 .. 10.0` | Hard kill timeout (`SIGTERM` → `SIGKILL` to process group) |
| `markup` | `Bool` | `false` | — | Parse `<fc>`/`<box>`/`<fn>`/`<sf>` tags in command stdout (`false` treats output as literal text) |
| `on_change` | `Bool` | `false` | — | Re-run immediately whenever Space, layout, focus, count, or pause state changes |

Reserved command names (cannot be used): `spaces`, `layout`, `title`, `count`, `custom`, `label`, `index`, `fullscreen`, `occupied`, `icon`.

See [Status Bar & Scripting Guide](STATUS_BAR.md) for markup syntax, colors, and full `TALUS_STATUS_JSON` schema.
