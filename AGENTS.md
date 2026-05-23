# iTerm2axis

A Hammerspoon window manager that provides a left-side sidebar for managing stacked iTerm2 windows, emulating some of the functionality of cmux while keeping iTerm2's native tmux support. This empowers the user to open tmux sessions on different computers in different windows, preserving tabs but allowing quick switching between machines. Also useful for keeping track of multiple coding agent sessions.

## Project Structure

- `init.lua` — The main (and only) Hammerspoon config file. This is the source of truth.

## How It Works

- A floating sidebar canvas is drawn on the left side of the screen.
- All iTerm2 windows are tiled to fill the remaining space to the right of the sidebar.
- Each iTerm window is listed as a button in the sidebar; clicking raises that window to the top of the stack.
- A "Move" button at the top of the sidebar lets you drag the entire setup (sidebar + all iTerm windows) together.
- A "Help" toggle at the bottom shows keyboard shortcuts and custom commands.
- Auto-refreshes on iTerm window create/destroy/title-change events.
- Follows moved or resized windows intelligently.

## Hotkeys

- `⌘⇧A` — Show/hide the sidebar
- `⌘⇧N` — New iTerm window (auto-tiled)
- `⌘⇧R` — Refresh layout

## Important Rules

- **Do NOT automatically copy `init.lua` to `~/.hammerspoon/init.lua`.** The user will copy it manually after reviewing changes.
- All edits go into the repo's `init.lua`. The user handles deployment.
- When debugging, ask the user to check Hammerspoon's Console (menu bar icon → Console) or run `/Applications/Hammerspoon.app/Contents/MacOS/Hammerspoon` from a terminal to see errors.
