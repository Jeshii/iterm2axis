# iTerm2Axis

A Hammerspoon [Spoon](https://github.com/Hammerspoon/Spoons) that adds a floating sidebar to iTerm2, letting you switch between stacked windows the way tmux lets you switch panes — without leaving the keyboard or spawning a new process.

## Features

- Floating sidebar showing all open iTerm2 windows
- Click any window button to bring it to the front
- Drag the **Move** handle to reposition the sidebar + windows together
- Help panel with configurable shortcut reference
- Auto-refreshes on window open/close/title change and screen layout changes

## Installation

1. Download or clone this repo.
2. Copy (or symlink) `iTerm2Axis.spoon` into `~/.hammerspoon/Spoons/`.
3. Add to your `~/.hammerspoon/init.lua`:

```lua
hs.loadSpoon("iTerm2Axis")
spoon.iTerm2Axis:bindHotkeys({
    toggle     = {{"cmd", "shift"}, "A"},
    newWindow  = {{"cmd", "shift"}, "N"},
    refresh    = {{"cmd", "shift"}, "R"},
})
spoon.iTerm2Axis:start()
```

## Default Hotkeys

| Key | Action |
|---|---|
| ⌘⇧A | Show / hide the Axis sidebar |
| ⌘⇧N | Open a new iTerm2 window |
| ⌘⇧R | Force-refresh the layout |

You can override any of these via `bindHotkeys` (see above).

## Configuration

Customise `spoon.iTerm2Axis.config` before calling `:start()`:

```lua
spoon.iTerm2Axis.config.sidebarWidth = 200
spoon.iTerm2Axis.config.activeButtonColor = {red=0.8, green=0.3, blue=0.1, alpha=1}
```

## License

MIT
