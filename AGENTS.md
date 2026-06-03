# iTerm2axis

A Hammerspoon window manager that provides a left-side sidebar for managing stacked iTerm2 windows, emulating some of the functionality of cmux while keeping iTerm2's native tmux support. This empowers the user to open tmux sessions on different computers in different windows, preserving tabs but allowing quick switching between machines. Also useful for keeping track of multiple coding agent sessions.

## Project Structure

- `iTerm2Axis.spoon/init.lua` — The main (and only) Hammerspoon config file. This is the source of truth.

## How It Works

- A floating sidebar canvas is drawn on the left side of the screen.
- All iTerm2 windows are tiled to fill the remaining space to the right of the sidebar.
- Each iTerm window is listed as a button in the sidebar — Line 1 shows the custom name, remote hostname, or local PWD basename (in that priority order); Line 2 shows PWD basename (when different from Line 1); Line 3 shows git branch
- Right-click on any sidebar button opens a context menu (`hs.chooser`) with actions: Rename, Move Up/Down/ToTop/ToBottom, Refresh Layout, Show/Hide Axis, iTerm Settings Tip.
- The sidebar snap formula: `sidebarX = math.max(f.x, sf.x)`; the iTerm window shrinks from its left edge so its right edge stays anchored.
- If a window is dragged off the sidebar's range (by more than sidebar width), the sidebar reattaches to the next overlapping window.

## Hotkeys

- `⌘⇧B` — Show/hide the sidebar
- `⌘⇧N` — New iTerm window (auto-tiled)
- `⌘⇧R` — Refresh layout
- `⌘⇧E` — Rename selected window
- `⌘⇧↑` — Move selected window up in sidebar
- `⌘⇧↓` — Move selected window down in sidebar
- `⌘⇧⌥↑` — Move selected window to top of sidebar
- `⌘⇧⌥↓` — Move selected window to bottom of sidebar
- `⌥⌘↑` — Focus previous iTerm window (cycles)
- `⌥⌘↓` — Focus next iTerm window (cycles)

## Important Rules

- **Do NOT automatically copy `iTerm2Axis.spoon` to `~/.hammerspoon/Spoons/`.** The user will copy it manually after reviewing changes.
- All edits go into the repo's `iTerm2Axis.spoon/init.lua`. The user handles deployment.
- When debugging, ask the user to check Hammerspoon's Console (menu bar icon → Console) or run `/Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon` from a terminal to see errors.
- Run `stylua` on any lua files you edit
- Do not push changes to the remote without asking first
- Window label priority: custom rename → remote hostname (parts.host) → local PWD basename → "Window N" fallback
- Update CHANGELOG.md after making any changes
- Inform the user if AGENTS.md or README.md need updates after making any changes
- When the user asks about releasing, remind them to update the version number at the top of `iTerm2Axis.spoon/init.lua`