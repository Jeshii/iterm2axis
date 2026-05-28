# iTerm2Axis

A Hammerspoon [Spoon](https://github.com/Hammerspoon/Spoons) that adds a floating sidebar to iTerm2, letting you switch between stacked windows the way tmux lets you switch panes — without leaving the keyboard or spawning a new process.

## Features

- Floating sidebar showing all open iTerm2 windows — labeled by hostname (remote), current directory (local), or custom rename
- Click any window button to bring it to the front
- Keyboard navigation to cycle focus between windows
- Right-click any window for a context menu: Rename, Reorder, Refresh, Show/Hide Axis, iTerm Settings Tip
- Auto-refreshes on window open/close/title change and screen layout changes

## Installation

1. Download or clone this repo.
2. Copy (or symlink) `iTerm2Axis.spoon` into `~/.hammerspoon/Spoons/`.
3. Add the following to your `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("iTerm2Axis")
spoon.iTerm2Axis:start()
spoon.iTerm2Axis:bindHotkeys({
    toggle       = {{"cmd", "shift"}, "A"},
    newWindow    = {{"cmd", "shift"}, "N"},
    refresh      = {{"cmd", "shift"}, "R"},
    renameWindow = {{"cmd", "shift"}, "W"},
    moveUp       = {{"cmd", "shift"}, "["},
    moveDown     = {{"cmd", "shift"}, "]"},
    moveToTop    = {{"cmd", "shift"}, "up"},
    moveToBottom = {{"cmd", "shift"}, "down"},
    focusUp      = {{"alt", "cmd"}, "up"},
    focusDown    = {{"alt", "cmd"}, "down"},
})
```

> **Important:** `bindHotkeys` must be called explicitly from your `init.lua` — the spoon does not register any hotkeys automatically. If you skip this call, no keyboard shortcuts will work. Call it with `{}` to use all defaults with no customisation:
> ```lua
> spoon.iTerm2Axis:bindHotkeys({})
> ```

4. Reload your Hammerspoon config (`⌘⇧R` in the Hammerspoon menu, or `hs.reload()` in the console).

## Hotkeys

All hotkeys have built-in defaults but **are only registered when you call `bindHotkeys`** in your `init.lua`. You can override any combo by passing your preferred modifiers and key, or omit any entry to accept the default.

| Key (default) | Mapping name | Action |
|---|---|---|
| ⌘⇧A | `toggle` | Show / hide the Axis sidebar |
| ⌘⇧N | `newWindow` | Open a new iTerm2 window |
| ⌘⇧R | `refresh` | Force-refresh the layout |
| ⌘⇧W | `renameWindow` | Rename the active window |
| ⌘⇧[ | `moveUp` | Move active window up the sidebar |
| ⌘⇧] | `moveDown` | Move active window down the sidebar |
| ⌘⇧↑ | `moveToTop` | Move active window to top of sidebar |
| ⌘⇧↓ | `moveToBottom` | Move active window to bottom of sidebar |
| ⌥⌘↑ | `focusUp` | Focus the previous window in the sidebar |
| ⌥⌘↓ | `focusDown` | Focus the next window in the sidebar |

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
