function OBJ:layoutFrames(screenFrame, anchorFrame)
	local isLeft = CFG.sidebarSide ~= "right"
	local sw = CFG.sidebarWidth
	local sf, af = screenFrame, anchorFrame

	local sidebarX
	if isLeft then
		sidebarX = math.max(af.x, sf.x)
	else
		sidebarX = math.min(af.x + af.w, sf.x + sf.w) - sw
	end

	local contentX, contentW
	if isLeft then
		contentX = sidebarX + sw
		contentW = (sf.x + sf.w) - contentX
	else
		contentX = sf.x
		contentW = sidebarX - sf.x
	end

	return {
		sidebar = { x = sidebarX, y = af.y, w = sw, h = af.h },
		content = { x = contentX, y = af.y, w = contentW, h = af.h },
	}
end

function OBJ:findWindowScreen(wins)
	if #wins == 0 then
		return hs.screen.mainScreen()
	end
	local win = wins[1]
	local wf = win:frame()
	local winCenter = { x = wf.x + wf.w / 2, y = wf.y + wf.h / 2 }
	for _, screen in ipairs(hs.screen.allScreens()) do
		local sf = screen:frame()
		if winCenter.x >= sf.x and winCenter.x < sf.x + sf.w and winCenter.y >= sf.y and winCenter.y < sf.y + sf.h then
			return screen
		end
	end
	return hs.screen.mainScreen()
end

function OBJ:getScreen()
	if self._currentScreen then
		return self._currentScreen
	end
	local wins = CACHE.getITermWindows()
	local screen = self:findWindowScreen(wins)
	self._currentScreen = screen
	return screen
end

function OBJ:getSidebarAnchor()
	if self._pendingSidebarFrame then
		return self._pendingSidebarFrame
	end
	if self.sidebarCanvas then
		return self.sidebarCanvas:frame()
	end
	local screen = self:getScreen()
	local f = screen:frame()

	local offset = (self.config.sidebarSide ~= "right") and 0 or (f.w - self.config.sidebarWidth)
	return { x = f.x + offset, y = f.y, w = self.config.sidebarWidth, h = f.h }
end

function OBJ:tileITermWindows(sb)
	local screenFrame = self:getScreen():frame()
	local newFrame
	if self._sidebarVisible then
		local anchor = sb or self:getSidebarAnchor()
		newFrame = self:layoutFrames(screenFrame, anchor).content
	else
		newFrame = screenFrame
	end
	print(
		string.format(
			"[iterm2axis] tileITermWindows: visible=%s frame={x=%.0f,y=%.0f,w=%.0f,h=%.0f}",
			tostring(self._sidebarVisible),
			newFrame.x,
			newFrame.y,
			newFrame.w,
			newFrame.h
		)
	)
	self:_withTilingGuard(function()
		for _, win in ipairs(CACHE.getITermWindows()) do
			if not win:isFullScreen() then
				win:setFrame(newFrame)
			end
		end
	end)
end

function OBJ:_withTilingGuard(fn)
	self._tilingInProgress = true
	if self._tilingClearTimer then
		self._tilingClearTimer:stop()
	end
	fn()
	self._tilingClearTimer = hs.timer.doAfter(self.config.settleDelay + 0.1, function()
		self._tilingInProgress = false
		self._tilingClearTimer = nil
	end)
end

function OBJ:refreshLayout()
	local wins = CACHE.getITermWindows()
	if #wins > 0 then
		local anchorWin = hs.window.focusedWindow()
		if not (anchorWin and IS_ITERM(anchorWin)) then
			anchorWin = wins[1]
		end
		local f = anchorWin:frame()
		local sf = anchorWin:screen():frame()
		self._pendingSidebarFrame = self:layoutFrames(sf, f).sidebar
		self._currentScreen = anchorWin:screen()
		self._lastStructureSnapshot = nil
		self._lastSidebarSnapshot = nil
	end
	self._skipTileOnThisBuild = false
	self:buildSidebar()
	self:syncCanvasLevel()
	self:tileITermWindows()
	self._skipTileOnThisBuild = true
end

function OBJ:toggleSidebar()
	if self._sidebarVisible then
		if self.sidebarCanvas then
			self.sidebarCanvas:hide()
		end
		self._sidebarVisible = false
		self._toggleLock = true
		self._lastStructureSnapshot = nil
		hs.timer.doAfter(0.5, function()
			self._toggleLock = false
		end)
		hs.alert.show("Sidebar Hidden")
	else
		self._sidebarVisible = true
		self._toggleLock = true
		self._pendingSidebarFrame = nil
		self._lastStructureSnapshot = nil
		self._lastSidebarSnapshot = nil

		local wins = CACHE.getITermWindows()
		if #wins > 0 then
			local anchorWin = hs.window.focusedWindow()
			if not (anchorWin and IS_ITERM(anchorWin)) then
				anchorWin = wins[1]
			end
			local f = anchorWin:frame()
			local sf = anchorWin:screen():frame()
			self._pendingSidebarFrame = self:layoutFrames(sf, f).sidebar
			self._currentScreen = anchorWin:screen()
		end

		self:buildSidebar()
		self:syncCanvasLevel()
		hs.timer.doAfter(0.5, function()
			self._toggleLock = false
		end)
		hs.alert.show("Sidebar Shown")
	end
end

function OBJ:forceRetile()
	self._lastStructureSnapshot = nil
	self._lastSidebarSnapshot = nil
	self._pendingSidebarFrame = nil
	self:refreshLayout()
end

function OBJ:toggleSide()
	self._swapInProgress = true
	self.config.sidebarSide = (self.config.sidebarSide ~= "right") and "right" or "left"
	self:forceRetile()
end

function OBJ:bringWindowToFront(windowId)
	local win = hs.window.get(windowId)
	if not win then
		return
	end
	FLASH.stopFlashing(windowId)
	self.activeWindowId = windowId

	if self.sidebarCanvas and self._btnBgElements then
		for wid, bgIdx in pairs(self._btnBgElements) do
			local c = (wid == windowId) and self.config.activeButtonColor or self.config.buttonColor
			self.sidebarCanvas:elementAttribute(bgIdx, "fillColor", COLOR(c))
		end
	end

	local ok = pcall(function()
		local app = win:application()
		if app then
			app:activate()
		end
		win:raise()
		win:focus()
	end)
	if not ok then
		return
	end

	hs.timer.doAfter(0.05, function()
		self:syncCanvasLevel()
	end)
end

function OBJ:syncCanvasLevel()
	if not self.sidebarCanvas then
		return
	end

	self.sidebarCanvas:level(hs.canvas.windowLevels.normal)

	local frontApp = hs.application.frontmostApplication()
	if frontApp and frontApp:bundleID() == ITERM_BID then
		self.sidebarCanvas:orderAbove(nil)
	end
end

function OBJ:_syncOrderedIds()
	if not self._orderedWindowIds then
		self._orderedWindowIds = {}
	end

	local wins = CACHE.getITermWindows()
	local liveIds = {}
	for _, win in ipairs(wins) do
		liveIds[win:id()] = true
	end

	local filtered = {}
	local filteredSet = {}
	for _, id in ipairs(self._orderedWindowIds) do
		if liveIds[id] then
			table.insert(filtered, id)
			filteredSet[id] = true
		end
	end
	for _, win in ipairs(wins) do
		if not filteredSet[win:id()] then
			table.insert(filtered, win:id())
		end
	end
	self._orderedWindowIds = filtered
	return filtered
end

function OBJ:moveWindowById(windowId, direction)
	local filtered = self:_syncOrderedIds()
	if #filtered < 2 then
		return
	end

	local currentIdx
	for i, id in ipairs(self._orderedWindowIds) do
		if id == windowId then
			currentIdx = i
			break
		end
	end
	if not currentIdx then
		return
	end

	local newIdx = currentIdx + direction
	if newIdx < 1 or newIdx > #self._orderedWindowIds then
		return
	end

	self._orderedWindowIds[currentIdx], self._orderedWindowIds[newIdx] =
		self._orderedWindowIds[newIdx], self._orderedWindowIds[currentIdx]
	hs.settings.set(SETTINGS_KEY_ORDER, self._orderedWindowIds)
	self._lastStructureSnapshot = nil
	self._lastSidebarSnapshot = nil
	self:buildSidebar()
end

function OBJ:moveWindowToExtent(windowId, extent)
	local filtered = self:_syncOrderedIds()
	if #filtered < 2 then
		return
	end

	local currentIdx
	for i, id in ipairs(self._orderedWindowIds) do
		if id == windowId then
			currentIdx = i
			break
		end
	end
	if not currentIdx then
		return
	end

	local targetIdx = extent == "top" and 1 or #self._orderedWindowIds
	if currentIdx == targetIdx then
		return
	end

	table.remove(self._orderedWindowIds, currentIdx)
	table.insert(self._orderedWindowIds, targetIdx, windowId)
	hs.settings.set(SETTINGS_KEY_ORDER, self._orderedWindowIds)
	self._lastStructureSnapshot = nil
	self._lastSidebarSnapshot = nil
	self:buildSidebar()
end

function OBJ:focusNextWindow(direction)
	local wins = CACHE.getITermWindows()
	if #wins < 2 then
		return
	end

	self:_syncOrderedIds()
	if #self._orderedWindowIds == 0 then
		return
	end

	local currentIdx
	if self.activeWindowId then
		for i, id in ipairs(self._orderedWindowIds) do
			if id == self.activeWindowId then
				currentIdx = i
				break
			end
		end
	end

	if not currentIdx then
		self:bringWindowToFront(self._orderedWindowIds[1])
		return
	end

	local newIdx = currentIdx + direction
	if newIdx < 1 then
		newIdx = #self._orderedWindowIds
	end
	if newIdx > #self._orderedWindowIds then
		newIdx = 1
	end

	self:bringWindowToFront(self._orderedWindowIds[newIdx])
end
