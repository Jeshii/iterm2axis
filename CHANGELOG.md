## 2026-06-02

- Fixed clicks being swallowed by sidebar canvas when a floating app (e.g. Calendar) overlapped it: disabled `canvasMouseEvents` (sidebar no longer captures clicks at the OS level)
- Removed redundant `mouseCallback` — all click handling is now done by `_leftClickTap` / `_rightClickTap` eventtaps
- Changed `_leftClickTap` dead-zone guard from `frontmostApplication()` to `hs.window.orderedWindows()[1]` so clicks pass through to apps floating above the canvas when iTerm2 isn't the topmost window
- Fixed canvas visibility bug: hide sidebar when all iTerm windows are closed/minimized, re-show when windows return
- Added `windowMinimized` / `windowUnminimized` subscriptions to trigger rebuilds on minimize/unminimize
- Added Git workspace / worktree support — parses PR numbers from iTerm2 title bar (`parsePRFromTitle`), detects worktree context from `git worktree list --porcelain` (_gitWsNameCache), displays workspace-aware Line 3 with color-coded states, short-circuits gh CLI when PR is already in the title
- Right-click handling moved to narrow `_rightClickTap` eventtap that only fires when iTerm2 is already frontmost
- Added `_leftClickTap` eventtap for fast left-click interception (fires before canvas mouseCallback, paints colors + focuses inline in eventtap)
- `_leftClickTap` swallows non-button sidebar clicks only when iTerm2 is frontmost — prevents click stealing from other apps overlapping the sidebar area
- Stripped `mouseCallback` down to `handleSidebarClick` only — left-click handling done entirely by `_leftClickTap`
- `windowFocused` subscriber now paints button colors immediately via `elementAttribute` (no debounce wait)
- Removed `_levelPollTimer` (1s syncCanvasLevel poll) — now fully reactive via `_appWatcher`
- `bringWindowToFront` calls `app:activate()` before `win:raise()`/`win:focus()` for faster cold-start focus switching
- Removed `buildSidebar` call from `bringWindowToFront` (redundant — windowFocused handles rebuild)
- Removed `handleWindowMoveOrResize` from `windowFocused` subscriber (focus changes don't move windows, was causing 300ms debounced stall / beach ball)
- Added 100ms TTL cache to `getITermWindows()` to avoid repeated `hs.window.allWindows()` calls during rapid sequential operations
