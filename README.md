# iTerm2Axis

A Hammerspoon [Spoon](https://github.com/Hammerspoon/Spoons) that adds a floating sidebar (configurable left or right side) to iTerm2, letting you switch between stacked windows the way tmux lets you switch panes — without leaving the keyboard or spawning a new process.

## Features

- Floating sidebar (configurable left/right) showing all open iTerm2 windows — labeled by hostname (remote), current directory (local), or custom rename
- Click any window button to bring it to the front
- Keyboard navigation to cycle focus between windows
- Right-click any window for a context menu: Rename, Reorder, Refresh, Show/Hide Axis, Swap Side; right-click empty sidebar area for global menu
- Drag a tab over a sidebar button to bring that window to front (green highlight) — merge tabs across windows
- Configurable start hidden, swap sidebar side at runtime
- Auto-refreshes on window open/close/title change and screen layout changes

## Installation

1. Download or clone this repo.
2. Copy (or symlink) `iTerm2Axis.spoon` into `~/.hammerspoon/Spoons/`.
3. Add the following to your `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("iTerm2Axis")
spoon.iTerm2Axis:start()
spoon.iTerm2Axis:bindHotkeys({
    toggle       = {{"cmd", "shift"}, "B"},
    newWindow    = {{"cmd", "shift"}, "N"},
    refresh      = {{"cmd", "shift"}, "R"},
    renameWindow = {{"cmd", "shift"}, "E"},
    moveUp       = {{"cmd", "shift"}, "up"},
    moveDown     = {{"cmd", "shift"}, "down"},
    moveToTop    = {{"cmd", "shift", "alt"}, "up"},
    moveToBottom = {{"cmd", "shift", "alt"}, "down"},
    focusUp      = {{"alt", "cmd"}, "up"},
    focusDown    = {{"alt", "cmd"}, "down"},
    swapSide     = {{"cmd", "shift"}, "S"},
})
```

> **Important:** `bindHotkeys` must be called explicitly from your `init.lua` — the spoon does not register any hotkeys automatically. If you skip this call, no keyboard shortcuts will work. Call it with `{}` to use all defaults with no customisation:
> ```lua
> spoon.iTerm2Axis:bindHotkeys({})
> ```

4. Reload your Hammerspoon config (`⌘⇧R` in the Hammerspoon menu, or `hs.reload()` in the console).

## iTerm2 Configuration

For iTerm2Axis to properly detect the current working directory (and show git branch info, opencode/Claude Code session data), your iTerm2 profile must be configured to share the session working directory:

1. Open iTerm2 → **Settings** → **Profiles** → select your profile → **General** tab
2. Under **Working Directory**, select **Reuse previous session's directory**
3. (optional) Click **Advanced Configuration** to fine-tune behavior for new windows, tabs, and split panes independently

This ensures that each session reports its actual working directory to iTerm2 so the axis can read it via AppleScript (`session.path`).

## Hotkeys

All hotkeys have built-in defaults but **are only registered when you call `bindHotkeys`** in your `init.lua`. You can override any combo by passing your preferred modifiers and key, or omit any entry to accept the default.

| Key (default) | Mapping name | Action |
|---|---|---|
| ⌘⇧B | `toggle` | Show / hide the Axis sidebar |
| ⌘⇧N | `newWindow` | Open a new iTerm2 window |
| ⌘⇧R | `refresh` | Force-refresh the layout |
| ⌘⇧E | `renameWindow` | Rename the active window |
| ⌘⇧↑ | `moveUp` | Move active window up the sidebar |
| ⌘⇧↓ | `moveDown` | Move active window down the sidebar |
| ⌘⇧⌥↑ | `moveToTop` | Move active window to top of sidebar |
| ⌘⇧⌥↓ | `moveToBottom` | Move active window to bottom of sidebar |
| ⌥⌘↑ | `focusUp` | Focus the previous window in the sidebar |
| ⌥⌘↓ | `focusDown` | Focus the next window in the sidebar |
| ⌘⇧S | `swapSide` | Swap sidebar to the opposite side |

To override a combo, pass your preferred value in the `bindHotkeys` call:

```lua
spoon.iTerm2Axis:bindHotkeys({
    focusUp   = {{"ctrl", "alt", "cmd"}, "up"},   -- override
    focusDown = {{"ctrl", "alt", "cmd"}, "down"}, -- override
    -- all other keys will use their defaults
})
```

## Configuration

Customise `spoon.iTerm2Axis.config` before calling `:start()`:

```lua
spoon.iTerm2Axis.config.sidebarWidth = 200
spoon.iTerm2Axis.config.activeButtonColor = {red=0.8, green=0.3, blue=0.1, alpha=1}
```

The sidebar uses eventtap-based click interception and drag detection, so buttons respond to clicks, focus, and drag-over even when other apps are frontmost.

Available options (all optional — defaults are used for anything omitted):

```lua
spoon.iTerm2Axis.config = {
    sidebarWidth = 200,
    sidebarSide = "left",             -- "left" or "right"
    startHidden = false,              -- start with sidebar hidden
    sidebarColor = {red=0.12, green=0.12, blue=0.14, alpha=0.95},
    buttonColor = {red=0.2, green=0.2, blue=0.22, alpha=1},
    activeButtonColor = {red=0.25, green=0.4, blue=0.6, alpha=1},
    dragHighlightColor = {red=0.3, green=0.7, blue=0.4, alpha=0.9},
    textColor = {red=0.9, green=0.9, blue=0.9, alpha=1},
    windowButtonHeight = 90,
    padding = 8,
    font = ".AppleSystemUIFont",
    fontSize = 13,
    debug = false,
    opencode = {
        enabled = true,
        port = 4096,
        pollInterval = 5,
    },
    claudecode = {
        enabled = true,
        pollInterval = 5,
        flashInterval = 2.0,
    },
    bell = {
        enabled = true,
        flashInterval = 2.0,
        flashColor = {red=0.95, green=0.85, blue=0.4, alpha=0.85},
    },
}
```
