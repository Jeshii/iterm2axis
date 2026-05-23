# iTerm2axis

A Hammerspoon window manager that provides a left-side sidebar for managing stacked iTerm2 windows, emulating some of the functionality of cmux while keeping iTerm2's native tmux support. This empowers you to open tmux sessions on different computers in different windows, preserving tabs but allowing quick switching between machines. Also useful for keeping track of multiple coding agent sessions.

## Project Structure

- `init.lua` — The Hammerspoon config file

## Hotkeys

- `⌘⇧A` — Show/hide the sidebar
- `⌘⇧N` — New iTerm window (auto-tiled)
- `⌘⇧R` — Refresh layout

## Installation

- Copy this `init.lua` file to `~/.hammerspoon/init.lua` and reload/start Hammerspoon