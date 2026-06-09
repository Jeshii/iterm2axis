function OBJ:watchWindow(win)
	if not win then
		return
	end
	local id = win:id()
	if self._windowWatchers[id] then
		return
	end
	local watcher = win:newWatcher(function(element, event)
		if event == hs.uielement.watcher.windowResized or event == hs.uielement.watcher.windowMoved then
			self:handleWindowMoveOrResize()
		end
	end, self)
	watcher:start({
		hs.uielement.watcher.windowResized,
		hs.uielement.watcher.windowMoved,
	})
	self._windowWatchers[id] = watcher
end

function OBJ:handleWindowMoveOrResize()
	if self._resizeDebounceTimer then
		self._resizeDebounceTimer:stop()
	end
	self._resizeDebounceTimer = hs.timer.doAfter(self.config.settleDelay, function()
		if self._toggleLock then
			return
		end
		if not self._sidebarVisible then
			return
		end

		local wins = CACHE.getITermWindows()
		if #wins == 0 then
			return
		end

		local focusedWin = hs.window.focusedWindow()
		local anchorWin
		if focusedWin and IS_ITERM(focusedWin) then
			anchorWin = focusedWin
		else
			anchorWin = wins[1]
		end

		local newScreen = anchorWin:screen()
		local screenChanged = (newScreen ~= self._currentScreen)

		if screenChanged then
			for _, win in ipairs(wins) do
				CACHE.invalidateWindow(
					win:id(),
					{ "wd", "tabInfo", "tabPending", "hostname", "branch", "wsName", "pr", "prBranch" }
				)
			end
			self._currentScreen = newScreen
			self._pendingSidebarFrame = nil
			if self.sidebarCanvas then
				self.sidebarCanvas:delete()
				self.sidebarCanvas = nil
			end
			self._lastStructureSnapshot = nil
			self:buildSidebar()
			return
		end

		local currentAnchor = self:getSidebarAnchor()
		local sf = newScreen:frame()

		local expectedEdge, edgeFn
		if self.config.sidebarSide ~= "left" then
			expectedEdge = currentAnchor.x
			edgeFn = function(f)
				return f.x + f.w
			end
		else
			expectedEdge = currentAnchor.x + CFG.sidebarWidth
			edgeFn = function(f)
				return f.x
			end
		end

		local driftedWin = nil
		for i = #wins, 1, -1 do
			local f = wins[i]:frame()
			if
				math.abs(edgeFn(f) - expectedEdge) > 5
				or math.abs(f.y - currentAnchor.y) > 5
				or math.abs(f.h - currentAnchor.h) > 5
			then
				driftedWin = wins[i]
				break
			end
		end

		if driftedWin then
			local f = driftedWin:frame()
			local sidebarW = CFG.sidebarWidth

			if f.w <= sidebarW then
				return
			end

			local l = self:layoutFrames(sf, { x = f.x, y = f.y, w = f.w, h = f.h })
			local contentW = math.min(f.w - sidebarW, l.content.w)
			if contentW <= 0 then
				return
			end

			self._pendingSidebarFrame = l.sidebar
			self._currentScreen = newScreen

			local contentX = math.max(l.content.x, math.min(f.x, l.content.x + l.content.w - contentW))
			local newFrame = { x = contentX, y = f.y, w = contentW, h = f.h }
			if self._tilingEnabled then
				for _, w in ipairs(wins) do
					w:setFrame(newFrame)
				end
			end

			self._skipTileOnThisBuild = true
			self._lastStructureSnapshot = nil
			self:buildSidebar()
		end
	end)
end

function OBJ:_rebuildAfterSettle(tileWhenHidden)
	hs.timer.doAfter(self.config.settleDelay, function()
		self._lastStructureSnapshot = nil
		self:buildSidebar()
		if tileWhenHidden and not self._sidebarVisible and self._tilingEnabled then
			self:tileITermWindows()
		end
	end)
end

local function stableCore(t)
	return (t or "")
		:gsub("^[^\x20-\x7e/~]+", "") -- strip any leading non-ASCII/non-path chars (spinners, bullets, etc.)
		:gsub("%s*[—–-]%s*%d+✕%d+%s*$", "")
		:gsub("^%s*(.-)%s*$", "%1")
end

function OBJ:_setupWindowWatcher()
	self._winWatcher:subscribe("windowCreated", function(win)
		if win then
			self:watchWindow(win)
		end
		CACHE.iTermWindowsCache = nil
		self:_rebuildAfterSettle(true)
	end)
	self._winWatcher:subscribe("windowDestroyed", function(win)
		local id = win and win:id()
		if id then
			if self._windowWatchers[id] then
				self._windowWatchers[id]:stop()
				self._windowWatchers[id] = nil
			end
			CACHE.winCache[id] = nil
			FLASH.stopFlashing(id)
		end
		CACHE.iTermWindowsCache = nil
		self:_rebuildAfterSettle(true)
	end)
	self._winWatcher:subscribe("windowMinimized", function()
		CACHE.iTermWindowsCache = nil
		self:_rebuildAfterSettle()
	end)
	self._winWatcher:subscribe("windowUnminimized", function(win)
		if win then
			self:watchWindow(win)
		end
		CACHE.iTermWindowsCache = nil
		self:_rebuildAfterSettle(true)
	end)
	self._winWatcher:subscribe("windowTitleChanged", function(win)
		local isCCStateChange
		local isBellStateChange
		if win then
			local id = win:id()
			local title = win:title() or ""
			local stripped = title:gsub("^🔔", "")
			isCCStateChange = stripped:match("^✳") or stripped:match("^·")
			isBellStateChange = title:match("^🔔")
			if not isCCStateChange and not isBellStateChange then
				local prevCore = stableCore(CACHE.wc(id).lastRawTitle or "")
				local newCore = stableCore(title)
				if newCore == prevCore then
					if not title:match("^[✳·🔔]") then
						-- Transient CC reset: core unchanged, all decorations
						-- dropped. Skip flash/rebuild to avoid stomping state.
						return
					end
				else
					CACHE.invalidateWindow(id, { "wd", "tabInfo", "tabPending", "hostname", "branch", "wsName" })
				end
			end
			CACHE.wc(id).lastRawTitle = title
			local focusedWin = hs.window.focusedWindow()
			local isFocused = focusedWin and focusedWin:id() == id
			local state = FLASH.claudeState(win)
			if state == "waiting" and not isFocused then
				FLASH.startFlashing(id)
			elseif state == "bell" and not isFocused then
				FLASH.startFlashing(id, "bell")
			elseif state == "busy" then
				-- Busy is shown as solid green (agents data) — stop flash
				-- and schedule a rebuild so _gatherWindowData sets busyColor.
				FLASH.stopFlashing(id)
				hs.timer.doAfter(self.config.settleDelay, function()
					self:buildSidebar()
				end)
			else
				FLASH.stopFlashing(id)
			end
		end
		-- Non‑CC title changes: real navigations and bells need a sidebar rebuild.
		if not isCCStateChange or isBellStateChange then
			hs.timer.doAfter(self.config.settleDelay, function()
				self:buildSidebar()
			end)
		end
	end)
	self._winWatcher:subscribe("windowMoved", function()
		self:handleWindowMoveOrResize()
	end)
	self._winWatcher:subscribe("windowFocused", function(win)
		if win and IS_ITERM(win) then
			local winId = win:id()
			self.activeWindowId = winId
			CACHE.wc(winId).lastRawTitle = win:title() or ""
			FLASH.stopFlashing(winId)
			if self.sidebarCanvas and self._btnBgElements then
				for wid, bgIdx in pairs(self._btnBgElements) do
					local c = (wid == winId) and self.config.activeButtonColor or self.config.buttonColor
					self.sidebarCanvas:elementAttribute(bgIdx, "fillColor", COLOR(c))
				end
			end
			CACHE.invalidateWindow(winId, { "hostname" })
			FETCH_WINDOW_INFO(win)
			hs.timer.doAfter(0.05, function()
				self:syncCanvasLevel()
			end)
		end
	end)
end

function OBJ:_restartWindowWatcher()
	if self._winWatcher then
		self._winWatcher:stop()
	end
	self._winWatcher = hs.window.filter.new("iTerm2")
	self:_setupWindowWatcher()
end

function OBJ:_setupAppWatcher()
	if self._appWatcher then
		self._appWatcher:stop()
	end
	self._appWatcher = hs.application.watcher.new(function(appName, event, appObj)
		if event == hs.application.watcher.deactivated then
			local bid = appObj and appObj:bundleID()
			if bid == ITERM_BID then
				self:syncCanvasLevel()
			end
		elseif event == hs.application.watcher.activated then
			local bid = appObj and appObj:bundleID()
			if bid == ITERM_BID and self._sidebarVisible then
				self:syncCanvasLevel()
			end
		end
	end)
	self._appWatcher:start()
end

function OBJ:_restorePersistedState()
	for _, win in ipairs(CACHE.getITermWindows()) do
		self:watchWindow(win)
		FETCH_WINDOW_INFO(win)
	end

	local savedOrder = hs.settings.get(SETTINGS_KEY_ORDER)

	if savedOrder then
		local liveWins = CACHE.getITermWindows()
		local liveIds = {}
		for _, w in ipairs(liveWins) do
			liveIds[w:id()] = true
		end
		local filtered = {}
		for _, id in ipairs(savedOrder) do
			local numId = tonumber(id)
			if numId and liveIds[numId] then
				table.insert(filtered, numId)
			end
		end
		self._orderedWindowIds = filtered
	end
end

function OBJ:_setupSleepWatcher()
	if self._sleepWatcher then
		self._sleepWatcher:stop()
	end
	self._sleepWatcher = hs.caffeinate.watcher.new(function(event)
		if event == hs.caffeinate.watcher.wake then
			hs.timer.doAfter(self.config.settleDelay, function()
				self:refreshSleepWake()
			end)
		end
	end)
	self._sleepWatcher:start()
end

function OBJ:refreshSleepWake()
	if not self._sidebarEnabled then
		return
	end
	self._pendingSidebarFrame = nil
	self._currentScreen = nil
	self._lastStructureSnapshot = nil
	self._lastSidebarSnapshot = nil
	CACHE.iTermWindowsCache = nil
	if self.sidebarCanvas then
		self.sidebarCanvas:delete()
		self.sidebarCanvas = nil
	end
	self:_setupSidebarClickTap()
	self:_setupDragTap()
	if self._sidebarVisible then
		self:buildSidebar()
	end
end

function OBJ:_setupScreenWatcher()
	if self._screenWatcher then
		self._screenWatcher:stop()
	end
	self._screenWatcher = hs.screen.watcher.new(function()
		hs.timer.doAfter(self.config.settleDelay, function()
			self._pendingSidebarFrame = nil
			self._currentScreen = nil
			CACHE.iTermWindowsCache = nil
			if self.sidebarCanvas then
				self.sidebarCanvas:delete()
				self.sidebarCanvas = nil
			end
			self._lastStructureSnapshot = nil
			if self._sidebarVisible then
				self:buildSidebar()
			end
		end)
	end)
	self._screenWatcher:start()
end

function OBJ:_setupSpaceWatcher()
	if self._spaceWatcher then
		self._spaceWatcher:stop()
	end
	self._spaceWatcher = hs.spaces.watcher.new(function()
		hs.timer.doAfter(self.config.settleDelay, function()
			self:syncCanvasLevel()
			if self.sidebarCanvas and self._sidebarEnabled and self._sidebarVisible then
				self:buildSidebar()
			end
		end)
	end)
	self._spaceWatcher:start()
end
