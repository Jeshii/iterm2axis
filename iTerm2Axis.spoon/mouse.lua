function OBJ:_closeMenus()
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
end

local function shouldConsumeSidebarClick(clickPt)
	if not OBJ.sidebarCanvas or not OBJ.sidebarCanvas:isShowing() then
		return false
	end
	for _, win in ipairs(hs.window.orderedWindows()) do
		if not win:isMinimized() then
			local f = win:frame()
			if RECT_CONTAINS(f, clickPt.x, clickPt.y) then
				if win:level() > hs.window.windowLevels.normal then
					return false
				end
			end
		end
	end
	return true
end

function OBJ:handleSidebarClick(x, y, rightClick)
	local app = hs.application.get(ITERM_BID)
	if app then
		app:activate()
	end

	if not self._buttonFrames then
		return
	end

	for _, btn in ipairs(self._buttonFrames) do
		if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
			if rightClick then
				self:showWindowMenu(btn.windowId)
				return
			end
			self.activeWindowId = btn.windowId
			FLASH.stopFlashing(btn.windowId)
			if self._btnBgElements then
				for wid, bgIdx in pairs(self._btnBgElements) do
					local c = (wid == btn.windowId) and self.config.activeButtonColor or self.config.buttonColor
					self.sidebarCanvas:elementAttribute(bgIdx, "fillColor", COLOR(c))
				end
			end
			local win = hs.window.get(btn.windowId)
			if win then
				win:raise()
				win:focus()
			end
			hs.timer.doAfter(0.05, function()
				self:syncCanvasLevel()
			end)
			return
		end
	end

	if rightClick then
		self:showGlobalMenu()
	end
end

function OBJ:showWindowMenu(windowId)
	self:_closeMenus()

	local items = {
		{
			label = "Move Up",
			shortcut = self._hotkeyLabels.moveUp,
			action = function()
				self:moveWindowById(windowId, -1)
			end,
		},
		{
			label = "Move Down",
			shortcut = self._hotkeyLabels.moveDown,
			action = function()
				self:moveWindowById(windowId, 1)
			end,
		},
		{
			label = "Move to Top",
			shortcut = self._hotkeyLabels.moveToTop,
			action = function()
				self:moveWindowToExtent(windowId, "top")
			end,
		},
		{
			label = "Move to Bottom",
			shortcut = self._hotkeyLabels.moveToBottom,
			action = function()
				self:moveWindowToExtent(windowId, "bottom")
			end,
		},
		{
			label = ACTION_LABELS.refresh,
			shortcut = self._hotkeyLabels.refresh,
			action = function()
				self:forceRetile()
			end,
		},
		{
			label = ACTION_LABELS.toggle,
			shortcut = self._hotkeyLabels.toggle,
			action = function()
				self:toggleSidebar()
			end,
		},
		{
			label = ACTION_LABELS.swapSide,
			shortcut = self._hotkeyLabels.swapSide,
			action = function()
				self:toggleSide()
			end,
		},
	}

	self:_renderPopupMenu(items)
end

function OBJ:_renderPopupMenu(items)
	local ROW_H = 22
	local PAD_X = 10
	local PAD_Y = 4
	local MENU_W = 210
	local MENU_H = #items * ROW_H + PAD_Y * 2

	local mouse = hs.mouse.absolutePosition()
	local ss = hs.screen.mainScreen() or hs.screen.primaryScreen()
	local screen = ss:frame()

	local mx = math.min(mouse.x, screen.x + screen.w - MENU_W - 4)
	local my = math.min(mouse.y, screen.y + screen.h - MENU_H - 4)

	local canvas = hs.canvas.new({ x = mx, y = my, w = MENU_W, h = MENU_H })
	canvas:level(hs.canvas.windowLevels.popUpMenu)
	canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

	canvas:appendElements({
		type = "rectangle",
		frame = { x = 0, y = 0, w = MENU_W, h = MENU_H },
		fillColor = COLOR(CFG.menuBgColor),
		strokeColor = { red = 0.35, green = 0.35, blue = 0.40, alpha = 0.8 },
		strokeWidth = 1,
		roundedRectRadii = { xRadius = 5, yRadius = 5 },
	})

	canvas:appendElements({
		type = "rectangle",
		frame = { x = 3, y = PAD_Y, w = MENU_W - 6, h = ROW_H },
		fillColor = { red = 0.25, green = 0.4, blue = 0.6, alpha = 0 },
		strokeWidth = 0,
		roundedRectRadii = { xRadius = 3, yRadius = 3 },
	})
	local HIGHLIGHT_IDX = 2

	for i, item in ipairs(items) do
		local rowY = PAD_Y + (i - 1) * ROW_H
		canvas:appendElements({
			type = "text",
			frame = { x = PAD_X, y = rowY + 4, w = MENU_W - PAD_X * 2, h = ROW_H - 4 },
			text = item.label,
			textColor = { red = 0.9, green = 0.9, blue = 0.9, alpha = 1 },
			textSize = 12,
			textAlignment = "left",
		})
		if item.shortcut then
			canvas:appendElements({
				type = "text",
				frame = { x = PAD_X, y = rowY + 4, w = MENU_W - PAD_X * 2, h = ROW_H - 4 },
				text = item.shortcut,
				textColor = { red = 0.6, green = 0.6, blue = 0.65, alpha = 0.85 },
				textSize = 11,
				textAlignment = "right",
			})
		end
	end

	canvas:show()
	self._menuCanvas = canvas

	local function closeMenu()
		self:_closeMenus()
		if self._needsRebuild then
			self._needsRebuild = nil
			self:buildSidebar()
		end
	end

	local function rowAtY(ly)
		local row = math.floor((ly - PAD_Y) / ROW_H) + 1
		if row >= 1 and row <= #items then
			return row
		end
		return nil
	end

	self._menuEventTap = hs.eventtap.new(
		{ hs.eventtap.event.types.mouseMoved, hs.eventtap.event.types.leftMouseDown },
		function(e)
			local consumed
			local ok, err = pcall(function()
				local pos = e:location()
				local lx = pos.x - mx
				local ly = pos.y - my
				local kind = e:getType()

				if kind == hs.eventtap.event.types.mouseMoved then
					local row = rowAtY(ly)
					if row then
						local rowY = PAD_Y + (row - 1) * ROW_H
						canvas:elementAttribute(HIGHLIGHT_IDX, "frame", { x = 3, y = rowY, w = MENU_W - 6, h = ROW_H })
						canvas:elementAttribute(HIGHLIGHT_IDX, "fillColor", COLOR(CFG.menuHighlightColor))
					else
						canvas:elementAttribute(
							HIGHLIGHT_IDX,
							"fillColor",
							COLOR({ red = 0.25, green = 0.4, blue = 0.6, alpha = 0 })
						)
					end
				elseif kind == hs.eventtap.event.types.leftMouseDown then
					consumed = true
					local row = rowAtY(ly)
					if row and lx >= 0 and lx <= MENU_W then
						local action = items[row].action
						closeMenu()
						action()
					else
						closeMenu()
					end
				end
			end)
			if not ok then
				print("[iterm2axis] _menuEventTap error:", err)
				closeMenu()
			end
			return consumed or false
		end
	)
	self._menuEventTap:start()

	self._menuKeyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
		local consumed
		local ok, err = pcall(function()
			if e:getKeyCode() == hs.keycodes.map["escape"] then
				closeMenu()
				consumed = true
			end
		end)
		if not ok then
			print("[iterm2axis] _menuKeyTap error:", err)
		end
		return consumed or false
	end)
	self._menuKeyTap:start()
end

function OBJ:showGlobalMenu()
	self:_closeMenus()

	local items = {
		{
			label = ACTION_LABELS.refresh,
			shortcut = self._hotkeyLabels.refresh,
			action = function()
				self:forceRetile()
			end,
		},
		{
			label = ACTION_LABELS.toggle,
			shortcut = self._hotkeyLabels.toggle,
			action = function()
				self:toggleSidebar()
			end,
		},
		{
			label = ACTION_LABELS.swapSide,
			shortcut = self._hotkeyLabels.swapSide,
			action = function()
				self:toggleSide()
			end,
		},
	}
	self:_renderPopupMenu(items)
end

function OBJ:_setupSidebarClickTap()
	if self._clickTap then
		self._clickTap:stop()
	end
	self._clickTap = hs.eventtap.new({
		hs.eventtap.event.types.leftMouseDown,
		hs.eventtap.event.types.rightMouseDown,
	}, function(e)
		local ok, err = pcall(function()
			if not self._sidebarVisible then
				return
			end
			local sf = self.sidebarCanvas and self.sidebarCanvas:frame()
			if not sf then
				return
			end
			local mouse = e:location()
			if RECT_CONTAINS(sf, mouse.x, mouse.y) then
				if shouldConsumeSidebarClick(mouse) then
					self._lastClickConsumed = true
					local isRight = e:getType() == hs.eventtap.event.types.rightMouseDown
					self:handleSidebarClick(mouse.x - sf.x, mouse.y - sf.y, isRight)
					return true
				end
			end
			self._lastClickConsumed = false
		end)
		if not ok then
			print("[iterm2axis] _clickTap error:", err)
		end
		return false
	end)
	self._clickTap:start()
end

function OBJ:_rebuildSidebar()
	if self.sidebarCanvas and self._sidebarVisible then
		self._lastSidebarSnapshot = nil
		self:buildSidebar()
	end
end

function OBJ:_setupDragTap()
	if self._dragWatchTap then
		self._dragWatchTap:stop()
	end
	self._dragWatchTap = hs.eventtap.new({
		hs.eventtap.event.types.leftMouseDragged,
		hs.eventtap.event.types.leftMouseUp,
	}, function(e)
		local etype = e:getType()
		if etype == hs.eventtap.event.types.leftMouseUp then
			if self._dragActive then
				self._dragActive = false
				self._lastDragHoverId = nil
				self:_rebuildSidebar()
			end
			return false
		end

		if not self._sidebarVisible or not self.sidebarCanvas then
			return false
		end

		local sf = self.sidebarCanvas:frame()
		local mouse = e:location()

		if RECT_CONTAINS(sf, mouse.x, mouse.y) then
			if not self._lastClickConsumed then
				return false
			end

			self._dragActive = true
			local lx = mouse.x - sf.x
			local ly = mouse.y - sf.y
			local hoveredId
			for _, btn in ipairs(self._buttonFrames or {}) do
				if lx >= btn.x and lx <= btn.x + btn.w and ly >= btn.y and ly <= btn.y + btn.h then
					hoveredId = btn.windowId
					break
				end
			end

			if hoveredId and hoveredId ~= self._lastDragHoverId then
				self._lastDragHoverId = hoveredId
				self:bringWindowToFront(hoveredId)
				self:_rebuildSidebar()
			end
		elseif self._dragActive then
			self._lastDragHoverId = nil
			self:_rebuildSidebar()
		end

		return false
	end)
	self._dragWatchTap:start()
end
