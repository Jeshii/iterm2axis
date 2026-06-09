--- iTerm2Axis - Hammerspoon Window Manager Spoon
--- A left-side sidebar for managing stacked iTerm2 windows, emulating cmux-like layout.
---
--- Download: [https://github.com/Jeshii/iterm2axis](https://github.com/Jeshii/iterm2axis)
--- @author Jesse Fuller
--- @license MIT

OBJ = {}
OBJ.__index = OBJ
RENDER = {}
FLASH = {}

-- Metadata
OBJ.name = "iTerm2Axis"
OBJ.version = "0.1.0"
OBJ.author = "Jesse Fuller"
OBJ.license = "MIT - https://opensource.org/licenses/MIT"
OBJ.homepage = "https://github.com/Jeshii/iterm2axis"

SETTINGS_KEY_ORDER = "iTerm2Axis.orderedWindowIds"
ITERM_BID = "com.googlecode.iterm2"
HAMMERSPOON_BID = "org.hammerspoon.Hammerspoon"

OBJ.config = {
	debug = false,
	sidebarWidth = 200,
	defaultFontSize = 15,
	sidebarSide = "left",
	startHidden = false,
	sidebarColor = { red = 0.12, green = 0.12, blue = 0.14, alpha = 0.95 },
	buttonColor = { red = 0.2, green = 0.2, blue = 0.22, alpha = 1 },
	activeButtonColor = { red = 0.25, green = 0.4, blue = 0.6, alpha = 1 },
	textColor = { red = 0.9, green = 0.9, blue = 0.9, alpha = 1 },
	dragHighlightColor = { red = 0.3, green = 0.7, blue = 0.4, alpha = 0.9 },
	busyColor = { red = 0.3, green = 0.6, blue = 0.35, alpha = 1 },
	waitingFlashColor = { red = 0.9, green = 0.6, blue = 0.4, alpha = 0.85 },
	prColor = { red = 0.85, green = 0.6, blue = 0.9, alpha = 0.95 },
	borderColor = { red = 0.3, green = 0.3, blue = 0.35, alpha = 0.5 },
	wsNameColor = { red = 0.9, green = 0.75, blue = 0.4, alpha = 0.9 },
	branchColor = { red = 0.5, green = 0.75, blue = 0.5, alpha = 0.9 },
	menuBgColor = { red = 0.15, green = 0.15, blue = 0.17, alpha = 0.97 },
	menuHighlightColor = { red = 0.25, green = 0.4, blue = 0.6, alpha = 0.85 },

	padding = 8,

	settleDelay = 0.3,

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
		flashColor = { red = 0.95, green = 0.85, blue = 0.4, alpha = 0.85 },
	},
}
CFG = OBJ.config

MOD_SYMBOLS = {
	cmd = "⌘",
	shift = "⇧",
	alt = "⌥",
	ctrl = "⌃",
}

KEY_SYMBOLS = {
	up = "\xe2\x86\x91",
	down = "\xe2\x86\x93",
}

function FORMAT_HOTKEY_LABEL(mods, key)
	local result = ""
	for _, m in ipairs(mods) do
		result = result .. (MOD_SYMBOLS[m:lower()] or m)
	end
	return result .. (KEY_SYMBOLS[key:lower()] or key:upper())
end

ACTION_LABELS = {
	toggle = "Show/Hide Sidebar",
	toggleTiling = "Enable/Disable Tiling",
	swapSide = "Swap Side",
	refresh = "Refresh Layout",
}

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

function LOAD_VERSION()
	local scriptPath = hs.spoons.scriptPath()
	if scriptPath then
		local versionPath = scriptPath:gsub("init%.lua$", "VERSION")
		local f = io.open(versionPath, "r")
		if f then
			local v = f:read("*l")
			f:close()
			if v and v ~= "" then
				OBJ.version = v
			end
		end
	end
end
LOAD_VERSION()

function IS_ITERM(win)
	if not win then
		return false
	end
	local ok, app = pcall(function()
		return win:application()
	end)
	if not ok or not app then
		return false
	end
	local ok2, bid = pcall(function()
		return app:bundleID()
	end)
	if not ok2 or not bid then
		return false
	end
	return bid == ITERM_BID
end

BASE_PATH = hs.spoons.scriptPath():match("^(.*/)")
dofile(BASE_PATH .. "cache.lua")

function COLOR(c)
	return { red = c.red, green = c.green, blue = c.blue, alpha = c.alpha }
end

dofile(BASE_PATH .. "flash.lua")

dofile(BASE_PATH .. "fetchers.lua")

dofile(BASE_PATH .. "render.lua")

dofile(BASE_PATH .. "windows.lua")

dofile(BASE_PATH .. "mouse.lua")

dofile(BASE_PATH .. "watchers.lua")

-- ─────────────────────────────────────────────
-- Spoon API: bindHotkeys
-- ─────────────────────────────────────────────

--- iTerm2Axis:bindHotkeys(mapping)
--- Method
--- Bind hotkeys for iTerm2Axis.
---
--- Parameters:
---  * mapping - A table with keys: toggle, toggleTiling, newWindow, refresh,
---    moveUp, moveDown, moveToTop, moveToBottom, focusUp, focusDown, swapSide
---    Each value is a table: { modifiers, key }
function OBJ:bindHotkeys(mapping)
	local map = mapping or {}

	local toggleMods, toggleKey = table.unpack(map.toggle or { { "cmd", "shift" }, "B" })
	local newWinMods, newWinKey = table.unpack(map.newWindow or { { "cmd", "shift" }, "N" })
	local refreshMods, refreshKey = table.unpack(map.refresh or { { "cmd", "shift" }, "R" })
	local moveUpMods, moveUpKey = table.unpack(map.moveUp or { { "cmd", "shift" }, "up" })
	local moveDownMods, moveDownKey = table.unpack(map.moveDown or { { "cmd", "shift" }, "down" })
	local moveTopMods, moveTopKey = table.unpack(map.moveToTop or { { "cmd", "shift", "alt" }, "up" })
	local moveBottomMods, moveBottomKey = table.unpack(map.moveToBottom or { { "cmd", "shift", "alt" }, "down" })
	local focusUpMods, focusUpKey = table.unpack(map.focusUp or { { "alt", "cmd" }, "up" })
	local focusDownMods, focusDownKey = table.unpack(map.focusDown or { { "alt", "cmd" }, "down" })
	local swapSideMods, swapSideKey = table.unpack(map.swapSide or { { "cmd", "shift" }, "S" })
	local tilingMods, tilingKey = table.unpack(map.toggleTiling or { { "cmd", "shift" }, "T" })

	self._hotkeyLabels.toggle = FORMAT_HOTKEY_LABEL(toggleMods, toggleKey)
	self._hotkeyLabels.refresh = FORMAT_HOTKEY_LABEL(refreshMods, refreshKey)
	self._hotkeyLabels.moveUp = FORMAT_HOTKEY_LABEL(moveUpMods, moveUpKey)
	self._hotkeyLabels.moveDown = FORMAT_HOTKEY_LABEL(moveDownMods, moveDownKey)
	self._hotkeyLabels.moveToTop = FORMAT_HOTKEY_LABEL(moveTopMods, moveTopKey)
	self._hotkeyLabels.moveToBottom = FORMAT_HOTKEY_LABEL(moveBottomMods, moveBottomKey)
	self._hotkeyLabels.swapSide = FORMAT_HOTKEY_LABEL(swapSideMods, swapSideKey)
	self._hotkeyLabels.toggleTiling = FORMAT_HOTKEY_LABEL(tilingMods, tilingKey)

	hs.hotkey.bind(toggleMods, toggleKey, function()
		self:toggleSidebar()
	end)
	hs.hotkey.bind(swapSideMods, swapSideKey, function()
		self:toggleSide()
	end)

	hs.hotkey.bind(newWinMods, newWinKey, function()
		local iterm = hs.application.get(ITERM_BID)
		if iterm then
			iterm:activate()
			hs.timer.doAfter(0.15, function()
				hs.eventtap.keyStroke({ "cmd" }, "n")
				hs.timer.doAfter(0.5, function()
					self._lastStructureSnapshot = nil
					self:buildSidebar()
				end)
			end)
		else
			hs.application.open(ITERM_BID)
			hs.timer.doAfter(1.0, function()
				self._lastStructureSnapshot = nil
				self:buildSidebar()
			end)
		end
	end)

	hs.hotkey.bind(refreshMods, refreshKey, function()
		self:forceRetile()
	end)

	hs.hotkey.bind(moveUpMods, moveUpKey, function()
		if self.activeWindowId then
			self:moveWindowById(self.activeWindowId, -1)
		end
	end)

	hs.hotkey.bind(moveDownMods, moveDownKey, function()
		if self.activeWindowId then
			self:moveWindowById(self.activeWindowId, 1)
		end
	end)

	hs.hotkey.bind(moveTopMods, moveTopKey, function()
		if self.activeWindowId then
			self:moveWindowToExtent(self.activeWindowId, "top")
		end
	end)

	hs.hotkey.bind(moveBottomMods, moveBottomKey, function()
		if self.activeWindowId then
			self:moveWindowToExtent(self.activeWindowId, "bottom")
		end
	end)

	hs.hotkey.bind(focusUpMods, focusUpKey, function()
		self:focusNextWindow(-1)
	end)

	hs.hotkey.bind(focusDownMods, focusDownKey, function()
		self:focusNextWindow(1)
	end)

	hs.hotkey.bind(tilingMods, tilingKey, function()
		self:toggleTiling()
	end)
end

-- ─────────────────────────────────────────────
-- Spoon API: start / stop
-- ─────────────────────────────────────────────

function OBJ:start()
	self:_setupSidebarClickTap()
	self:_setupDragTap()
	self:_restartWindowWatcher()
	self:_setupAppWatcher()
	self:_restorePersistedState()
	self:_setupScreenWatcher()
	self:_setupSpaceWatcher()
	self:_setupSleepWatcher()

	self._sidebarVisible = not self.config.startHidden
	self:buildSidebar()

	hs.task
		.new("/usr/bin/which", function(exitCode, stdout, _)
			self._ghAvailable = (exitCode == 0 and stdout and stdout:gsub("%s+$", "") ~= "")
		end, { "gh" })
		:start()

	if self.config.opencode.enabled then
		self:startOpenCodePolling()
	end

	if self.config.claudecode.enabled then
		self:startClaudeAgentsPolling()
	end

	hs.alert.show("iTerm2Axis loaded ✓", 1.5)
	return self
end

function OBJ:stop()
	if self._orderedWindowIds and next(self._orderedWindowIds) then
		hs.settings.set(SETTINGS_KEY_ORDER, self._orderedWindowIds)
	end
	if self._appWatcher then
		self._appWatcher:stop()
		self._appWatcher = nil
	end
	if self._clickTap then
		self._clickTap:stop()
		self._clickTap = nil
	end
	if self._dragWatchTap then
		self._dragWatchTap:stop()
		self._dragWatchTap = nil
	end
	if self._winWatcher then
		self._winWatcher:stop()
		self._winWatcher = nil
	end
	if self._screenWatcher then
		self._screenWatcher:stop()
		self._screenWatcher = nil
	end
	if self._spaceWatcher then
		self._spaceWatcher:stop()
		self._spaceWatcher = nil
	end
	if self._sleepWatcher then
		self._sleepWatcher:stop()
		self._sleepWatcher = nil
	end
	for _, w in pairs(self._windowWatchers or {}) do
		w:stop()
	end
	self._windowWatchers = {}
	if self.sidebarCanvas then
		self.sidebarCanvas:delete()
		self.sidebarCanvas = nil
	end
	if self._menuCanvas then
		self._menuCanvas:delete()
		self._menuCanvas = nil
	end
	if self._menuEventTap then
		self._menuEventTap:stop()
		self._menuEventTap = nil
	end
	if self._menuKeyTap then
		self._menuKeyTap:stop()
		self._menuKeyTap = nil
	end
	if self._buildDebounceTimer then
		self._buildDebounceTimer:stop()
		self._buildDebounceTimer = nil
	end
	CACHE.iTermWindowsCache = nil
	CACHE.iTermWindowsCacheTime = 0
	CACHE.winCache = {}
	FLASH.reset()
	self._opencodePending = false
	if self._opencodePollTimer then
		self._opencodePollTimer:stop()
		self._opencodePollTimer = nil
	end
	self._claudeAgentsPending = false
	if self._claudeAgentsPollTimer then
		self._claudeAgentsPollTimer:stop()
		self._claudeAgentsPollTimer = nil
	end
	CACHE._claudeAgentsData = {}
	self._lastSidebarSnapshot = nil
	self._lastStructureSnapshot = nil
	return self
end

function OBJ:init()
	self.windows = {}
	self.sidebarCanvas = nil
	self.activeWindowId = nil
	self._currentScreen = nil
	self._buttonFrames = {}
	self._resizeDebounceTimer = nil
	self._buildDebounceTimer = nil
	self._pendingSidebarFrame = nil
	self._clickTap = nil
	self._winWatcher = nil
	self._screenWatcher = nil
	self._spaceWatcher = nil
	self._appWatcher = nil
	self._sidebarVisible = false
	self._sidebarEnabled = true
	self._tilingEnabled = true
	self._hotkeyLabels = {}
	self._swapInProgress = false
	self._refreshInProgress = false
	self._toggleLock = false
	self._windowWatchers = {}
	self._menuCanvas = nil
	self._menuEventTap = nil
	self._menuKeyTap = nil
	self._orderedWindowIds = {}
	self._opencodeData = {}
	self._opencodePending = false
	self._opencodePollTimer = nil
	self._claudeAgentsPending = false
	self._claudeAgentsPollTimer = nil
	self._ghAvailable = false
	self._btnBgElements = {}
	self._lastSidebarSnapshot = nil
	self._lastStructureSnapshot = nil
	CACHE.iTermWindowsCache = nil
	CACHE.iTermWindowsCacheTime = 0
	CACHE.winCache = {}
	FLASH.reset()
	self._dragWatchTap = nil
	self._dragActive = false
	self._lastDragHoverId = nil
	self._sleepWatcher = nil
	return self
end

return OBJ
