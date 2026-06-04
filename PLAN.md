# Plan: Replace Claude Code .jsonl with `claude agents --json`

## Summary

Remove the never-working Claude Code .jsonl file parsing (~120 lines) and replace it with a `claude agents --json` poller for live session status + `waitingFor` display. Add a backward-compat shim so existing `config.claudecode` users don't break.

---

## A. Config Changes (+ Compat) ✅

No config block rename — `claudecode` config key kept as-is. No compat shim needed.

---

## B. Remove All Claude Code .jsonl Code ✅

All `.jsonl` file reading code removed: `claudeEncodeDir()`, `claudeProjectDir()`, `fetchClaudeCodeForWindow()`, `fetchClaudeCodeData()`, `startClaudeCodePolling()`, `_ccCache`, `_ccPending`, `_ccPathKey`, `ccSnippet()`, `_claudeCodeData`, `_claudeCodePollTimer`, all `ccData` render references. `claudeState()` (title-based `✳`/`·`/`🔔`) kept for flash responsiveness.

Also removed redundant `cfg` parameter from `_gatherWindowData()`.

---

## C. Add `claude agents --json` Polling ✅

**Module-level variable:** `_claudeAgentsData = {}` — keyed by `cwd` (directory), value `{ status, waitingFor }`

**`fetchClaudeAgentsData()`:**
- Guard: skip if `_claudeAgentsPending`
- Runs `claude agents --json` via `hs.task`
- On completion: `pcall(hs.json.decode, stdout)`, index results by `.cwd`
- Store in `_claudeAgentsData`, call `buildSidebar()`

**`startClaudeAgentsPolling()`:**
- Immediate call + `hs.timer` at `config.claude.pollInterval`

**`startFlashing()`:** Change `cfg.claudecode.flashInterval` → `cfg.claude.flashInterval`

---

## D. State Detection — Dual Source

**Keep** `claudeState()` (title-based: `✳`/`·`/`🔔`) for flash responsiveness on title changes (5s poll is too slow to toggle flash).

In `_gatherWindowData()`, **prefer agent data**:
```lua
local claudeData = fullPath and _claudeAgentsData[fullPath]
if claudeData and claudeData.status then
    stateOverride = claudeData.status  -- "waiting" / "busy" / "idle"
end
```
Use `stateOverride` for button colors; keep `claudeState()` as fallback. Keep `🔔` bell detection from title only.

---

## E. Button Layout — Dynamic No-Gap Lines

**Button height:** All buttons same height = `max(detailLine count for any window)`. Pre-compute in `_gatherWindowData()`.

**Font sizes:**
- Line 1: `dfs + 1`
- Line 2–3: `dfs`
- Lines 4+: `dfs - 1`

**Line composition (no blank lines — each line only present if its data exists, subsequent lines shift up):**

| Pos | Condition | Display | Color |
|-----|-----------|---------|-------|
| 1 | Always | Label (custom > host > basename > "Window N") | `cfg.textColor` |
| 2 | basename exists and != label | PWD basename | `{0.75, 0.75, 0.8, 0.85}` |
| 3 | branch/PR/worktree | `⎇ PR #42` / `⎇ ws:name` / `⎇ main` | per type (existing) |
| 4 | ocData exists | header: `"opencode"` | `{0.6, 0.6, 0.9, 0.85}` |
| 5 | ocData.modelID | Model name (short) | `{0.75, 0.75, 0.8, 0.85}` |
| 6 | ocData.agent | Agent name | `{0.75, 0.75, 0.8, 0.85}` |
| 7 | ocData has tokens | `"1.2k in · 3.4k out"` | `{0.75, 0.75, 0.8, 0.85}` |
| 8 | claudeData exists | header: `"claude"` | `{0.6, 0.6, 0.9, 0.85}` |
| 9 | claudeData.waitingFor | `"⏳ permission prompt"` | `cfg.waitingFlashColor` |
| 10 | claudeData.status and != waiting | `"busy"` / `"idle"` | `{0.75, 0.75, 0.8, 0.85}` |

**Structure key:** Update `buttonStructureKey()` to include a hash of the number of detail lines. When line count changes → `needsAnyWindowRebuild = true`.

**Render functions:** `_renderFullSidebar()` appends text elements sequentially per window, `_renderInPlace()` updates them by position. Both iterate the pre-computed `detailLines` array on each `wd`.

**`sidebarStateSnapshot()`:** Include a hash of detail lines so snapshot mismatches trigger rebuilds.

---

## F. Wire Up

**`start()`:** Replace `claudecode` polling branch with:
```lua
if cfg.claude.enabled then
    self:startClaudeAgentsPolling()
end
```

**`stop()`:** Stop + nil `_claudeAgentsPollTimer`, clear `_claudeAgentsPending`

**`init()`:** `_claudeAgentsPending = false`, `_claudeAgentsData = {}`

**`windowDestroyed`:** Clear `_claudeAgentsData` entry for destroyed window's path (not critical — poll overwrites — but clean).

---

## G. CHANGELOG + README

**CHANGELOG:** Add entry covering: removed .jsonl parsing, added `claude agents --json` polling, restructured button layout (dynamic no-gap lines), new `claude` config block, removed `claudecode` config (auto-migrated).

**README:** Replace `claudecode` section with `claude` section in config table. Document waitingFor display on buttons. Drop "Claude Code tokens" references.

---

## Summary

| Metric | Value |
|--------|-------|
| Lines removed | ~120 |
| Lines added | ~80 |
| Net | -40 lines, simpler, more reliable |
| Breaking changes | None (compat shim migrates old config) |
