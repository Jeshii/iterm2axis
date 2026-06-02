## 2026-06-02

- Fixed canvas visibility bug: hide sidebar when all iTerm windows are closed/minimized, re-show when windows return
- Added `windowMinimized` / `windowUnminimized` subscriptions to trigger rebuilds on minimize/unminimize
- Added Git workspace / worktree support — parses PR numbers from iTerm2 title bar (`parsePRFromTitle`), detects worktree context from `git worktree list --porcelain` (`_gitWsNameCache`), and displays workspace-aware Line 3 with color-coded states (green for branch, purple for PR, amber for worktree), short-circuits `gh` CLI when PR is already in the title
