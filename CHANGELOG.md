## 2026-06-03

- Fixed toggle sidebar loop: added `_toggleLock` flag that suppresses drift detection in `handleWindowMoveOrResize` during programmatic window moves from `toggleSidebar`; also added `_sidebarEnabled` guard to `tileITermWindows` to prevent stale geometry tiling when the sidebar is hidden
- Fixed `_leftClickTap`: restored `hs.window.orderedWords()` walk to determine the topmost window at the click coordinate — the `frontmostApplication()` shortcut dropped all sidebar clicks when any other app had focus, even if iTerm2 windows covered the sidebar area
- Fixed `_appWatcher` deactivation level: changed from `windowLevels.normal` to `windowLevels.floating - 1` for consistency with `syncCanvasLevel` (normal level gets buried under other app windows on recent macOS)
- Fixed orphaned context menu taps: `_doBuildSidebar` now cleans up `_menuCanvas`/`_menuEventTap`/`_menuKeyTap` before any canvas rebuild, preventing stale global interceptors if a rebuild fires while the menu is open
- Fixed sidebar visibility loss: `syncCanvasLevel` non-iTerm2 branch changed from `windowLevels.normal` to `windowLevels.floating - 1` — `normal` level can be buried behind iTerm2 windows on macOS Sonoma/Sequoia; `floating - 1` stays above most content while still yielding focus

## 2026-06-02

- Fixed `toggleSidebar` show bug: removed manual `sidebarCanvas:show()` after `refreshLayout()` — the canvas show is now handled by the debounced `_doBuildSidebar` (which fires 50ms later), preventing the show from hitting a stale or nil canvas reference before the rebuild completes
- Fixed `_doBuildSidebar`: moved `canvas:show()` to after `syncCanvasLevel()` so the level is set before the canvas renders, preventing it from being buried behind iTerm windows on macOS
- Fixed syntax error in `getOpenPRForWindow`: args table (`{"-c", ...}`) was being passed as 3rd arg to `hs.timer.doAfter` instead of `hs.task.new` — same pattern fix as `getGitBranchForPath`

- Added `_sidebarEnabled` guard to `syncCanvasLevel` for safety; added `sidebarCanvas` nil guard in `toggleSidebar` show branch to prevent potential crash

- Fixed `toggleSidebar` bug: on hide, iTerm windows now expand left to fill the vacated sidebar area; on show, sidebar position is read directly from the existing canvas frame instead of using a broken heuristic that subtracted `sidebarWidth` from iTerm's current X

- Fixed right-click context menu showing duplicate entries (Rename through Move to Bottom appeared twice in `showWindowMenu` items table)

- Fixed `⌘⇧N` new window hotkey: replaced `hs.application.find("iTerm2")` with `hs.application.get("com.googlecode.iterm2")` and added a 0.15s delay before sending `⌘N` so iTerm2 has time to gain focus
- Revised default hotkeys: toggle sidebar `⌘⇧A` → `⌘⇧B`, rename `⌘⇧W` → `⌘⇧E`, move up/down `⌘⇧[/]` → `⌘⇧↑/↓`, move to top/bottom `⌘⇧↑/↓` → `⌘⇧⌥↑/↓`; updated context menu shortcut labels to match

- Replaced `hs.dialog.textPrompt` with an inline vim-style rename bar at the bottom of the sidebar — type `⌘⇧W` or right-click → Rename to show the bar, `Return` to commit, `Escape` to cancel, `⌘V` to paste, `⌦` to clear
- Rename bar: 40-char max length with visual `[max]` nudge, `▏` slim cursor, 6px bottom margin, paste strips newlines
- Added rename state management (`startRenameMode`, `commitRename`, `cancelRenameMode`) with global `hs.eventtap` key capture and a 0.5s blinking cursor
- Added `_saveCustomName` helper shared by both dialog and bar rename paths
- Added `BAR_H = 18` constant reserving space for the rename bar at the bottom of the canvas
- Rename mode auto-cancels on: mouse click, iTerm2 deactivation, screen change, or `stop()`

- Fixed clicks being swallowed by sidebar canvas when a floating app (e.g. Calendar) overlapped it: disabled `canvasMouseEvents` (sidebar no longer captures clicks at the OS level)
- Removed redundant `mouseCallback` — all click handling is now done by `_leftClickTap` / `_rightClickTap` eventtaps
- Changed `_leftClickTap` guard from `frontmostApplication()` to walking `hs.window.orderedWindows()` — finds the first window actually covering the click coordinate, so clicks pass through to floating apps above the canvas at that exact point
- Fixed `bringWindowToFront` not updating button colors immediately on keyboard-triggered focus switching (e.g. ⌥⌘↑/↓) — now paints colors synchronously, matching the click-path behavior
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

- Replaced `hs.chooser` context menu with a canvas-based popup menu (`showWindowMenu`) — avoids the chooser UI and provides native-feeling hover highlight and click handling via `hs.eventtap`
- Removed `iTerm Settings` menu item (the `showPreferencesTip` overlay and `preferences_tip.png` asset)
- Added `_menuCanvas`/`_menuEventTap`/`_menuKeyTap` state fields for the new context menu; cleaned up in `stop()` and `init()`
- Added iTerm2 configuration section to README documenting the "Reuse previous session's directory" setting
- Added keyboard shortcut labels (⌘⇧W, ⌘⇧[, etc.) to each canvas context menu item, right-aligned in dimmer text
