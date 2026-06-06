function RENDER.computeBtnHeight(numRows, dfs)
	local PAD_TOP = 5
	local PAD_BOTTOM = 6
	local GAP = 3
	local h = PAD_TOP
	for rowPos = 1, numRows do
		local fs = rowPos == 1 and (dfs + 1) or (rowPos <= 3 and dfs or dfs - 1)
		h = h + fs + 4
		if rowPos < numRows then
			h = h + GAP
		end
	end
	return h + PAD_BOTTOM
end

function RENDER.ocSnippet(data, fullPath)
	if not data or not fullPath or not data[fullPath] then
		return ""
	end
	local d = data[fullPath]
	return tostring(d.tokensIn or 0) .. "/" .. tostring(d.tokensOut or 0)
end

function RENDER.sidebarStateSnapshot(wins, activeId, opencodeData)
	local parts = {}
	for _, win in ipairs(wins) do
		local id = win:id()
		local fullPath = CACHE.wc(id).wd or ""
		local claudeAgent = fullPath and CACHE._claudeAgentsData[fullPath]
		local ti = CACHE.wc(id).tabInfo
		local tabInfoStr = ti
				and table.concat({
					tostring(ti.tabCount),
					tostring(ti.focusedIdx),
					ti.tabName or "",
				}, ":")
			or ""
		table.insert(
			parts,
			table.concat({
				tostring(id),
				win:title() or "",
				tabInfoStr,
				tostring(id == activeId),
				tostring(FLASH.claudeState(win) or ""),
				tostring(fullPath),
				tostring(CACHE.wc(id).branch or ""),
				tostring(CACHE.wc(id).wsName or ""),
				RENDER.ocSnippet(opencodeData, fullPath),
				tostring(claudeAgent and claudeAgent.status or ""),
				tostring(claudeAgent and claudeAgent.waitingFor or ""),
			}, "\t")
		)
	end
	return table.concat(parts, "|")
end

function RENDER.sidebarStructureSnapshot(wins, sbW, sbH)
	return #wins .. ":" .. sbW .. "x" .. sbH
end

function RENDER.line3Display(wd)
	if wd.prFromTitle then
		return {
			text = "⎇ PR #" .. wd.prFromTitle,
			color = CFG.prColor,
		}
	elseif wd.wsName then
		return {
			text = "⎇ ws:" .. wd.wsName,
			color = CFG.wsNameColor,
		}
	elseif wd.branch then
		return {
			text = "⎇ " .. wd.branch,
			color = CFG.branchColor,
		}
	end
	return nil
end

function RENDER.makeTabLabel(tabInfo)
	if not tabInfo or not tabInfo.tabName or tabInfo.tabName == "" then
		return nil
	end
	local tabCount = math.max(tabInfo.tabCount or 1, 1)
	local focusedIdx = math.max(tabInfo.focusedIdx or 1, 1)
	if focusedIdx > tabCount then
		focusedIdx = tabCount
	end
	local before = string.rep("・", focusedIdx - 1)
	local after = string.rep("・", tabCount - focusedIdx)
	return before .. tabInfo.tabName .. after
end

local HEADER_COLOR = { red = 0.6, green = 0.6, blue = 0.9, alpha = 0.85 }
local DETAIL_COLOR = { red = 0.75, green = 0.75, blue = 0.8, alpha = 0.85 }

function RENDER.buildTextRows(wd)
	local dfs = CFG.defaultFontSize
	local rows = {}
	table.insert(rows, { text = wd.label, fs = dfs + 1, color = CFG.textColor })
	if wd.hostname and wd.hostname ~= wd.label then
		table.insert(rows, { text = wd.hostname, fs = dfs, color = DETAIL_COLOR })
	end
	if wd.basename then
		table.insert(rows, { text = wd.basename, fs = dfs, color = DETAIL_COLOR })
	end
	local l3 = RENDER.line3Display(wd)
	if l3 then
		table.insert(rows, { text = l3.text, fs = dfs, color = l3.color })
	end
	if wd.ocData then
		table.insert(rows, { text = "opencode", fs = dfs - 1, color = HEADER_COLOR })
		local modelStr = SHORT_MODEL_NAME(wd.ocData.modelID)
		if modelStr then
			table.insert(rows, { text = modelStr, fs = dfs - 1, color = DETAIL_COLOR })
		end
		if wd.ocData.agent and wd.ocData.agent ~= "" then
			table.insert(rows, { text = wd.ocData.agent, fs = dfs - 1, color = DETAIL_COLOR })
		end
		if wd.ocData.tokensIn and wd.ocData.tokensIn > 0 then
			local tokStr = FMT_TOKENS(wd.ocData.tokensIn) .. " in"
			if wd.ocData.tokensOut and wd.ocData.tokensOut > 0 then
				tokStr = tokStr .. " · " .. FMT_TOKENS(wd.ocData.tokensOut) .. " out"
			end
			table.insert(rows, { text = tokStr, fs = dfs - 1, color = DETAIL_COLOR })
		end
	end
	if wd.claudeAgent then
		table.insert(rows, { text = "claude", fs = dfs - 1, color = HEADER_COLOR })
		if wd.claudeAgent.waitingFor then
			table.insert(
				rows,
				{ text = "⏳ " .. wd.claudeAgent.waitingFor, fs = dfs - 1, color = CFG.waitingFlashColor }
			)
		end
		if wd.claudeAgent.status and wd.claudeAgent.status ~= "waiting" then
			table.insert(rows, { text = wd.claudeAgent.status, fs = dfs - 1, color = DETAIL_COLOR })
		end
	end
	return rows
end

function OBJ:buildSidebar()
	if self._buildDebounceTimer then
		self._buildDebounceTimer:stop()
		self._buildDebounceTimer = nil
	end
	if self._menuCanvas then
		self._needsRebuild = true
		return
	end
	self._buildDebounceTimer = hs.timer.doAfter(0.05, function()
		self._buildDebounceTimer = nil
		self:_doBuildSidebar()
	end)
end

function OBJ:_orderedWindows(wins)
	local itermWins = wins
	if self._orderedWindowIds and #self._orderedWindowIds > 0 then
		local winMap = {}
		for _, win in ipairs(itermWins) do
			winMap[win:id()] = win
		end
		local ordered = {}
		for _, wid in ipairs(self._orderedWindowIds) do
			if winMap[wid] then
				table.insert(ordered, winMap[wid])
				winMap[wid] = nil
			end
		end
		for _, win in ipairs(itermWins) do
			if winMap[win:id()] then
				table.insert(ordered, win)
			end
		end
		itermWins = ordered
	end
	return itermWins
end

function RENDER.windowStatusColor(state, isActive, isDragHover, isFlashing, isFocused)
	if isDragHover then
		return CFG.dragHighlightColor
	elseif state == "waiting" and isFlashing and not isFocused then
		return CFG.waitingFlashColor
	elseif state == "bell" and isFlashing and not isFocused then
		return CFG.bell.flashColor
	elseif state == "busy" then
		return CFG.busyColor
	elseif isActive then
		return CFG.activeButtonColor
	else
		return CFG.buttonColor
	end
end

function OBJ:_gatherWindowData(orderedWins)
	local winData = {}
	local focusedWin = hs.window.focusedWindow()
	for i, win in ipairs(orderedWins) do
		local winId = win:id()
		local isActive = (winId == self.activeWindowId)
		local rawTitle = win:title() or ""
		local parts = PARSE_TITLE_COMPONENTS(rawTitle)
		FETCH_WINDOW_INFO(win)
		local fullPath = CACHE.wc(winId).wd
		local claudeAgent = fullPath and CACHE._claudeAgentsData[fullPath]
		local state = FLASH.claudeState(win)
		if claudeAgent and claudeAgent.status and claudeAgent.status ~= "idle" then
			if claudeAgent.status == "waiting" then
				state = "waiting"
			elseif claudeAgent.status == "busy" then
				state = "busy"
			end
		end
		local isFocused = focusedWin and focusedWin:id() == winId
		local isDragHover = self._dragActive and (winId == self._lastDragHoverId)
		local btnColor = RENDER.windowStatusColor(state, isActive, isDragHover, FLASH.flashState(winId), isFocused)

		local prFromTitle = PARSE_PR_FROM_TITLE(rawTitle)
		if prFromTitle and prFromTitle <= 0 then
			prFromTitle = nil
		end
		local basename = fullPath and fullPath:match("([^/]+)%s*$") or parts.basename
		local branch = fullPath and GET_GIT_BRANCH_FOR_PATH(fullPath, winId) or nil
		local wsName = CACHE.wc(winId).wsName or nil
		local hostname = CACHE.wc(winId).hostname or parts.host
		local tabInfo = CACHE.wc(winId).tabInfo
		local tabName = tabInfo and tabInfo.tabName
		local dottedLabel = tabInfo and RENDER.makeTabLabel(tabInfo)
		local label = dottedLabel or basename or hostname or ("Window " .. i)

		if tabName and basename and basename == tabName then
			basename = nil
		elseif not tabName and basename and basename == label then
			basename = nil
		end

		local ocData
		if fullPath and self._opencodeData[fullPath] then
			ocData = self._opencodeData[fullPath]
		else
			for _, data in pairs(self._opencodeData or {}) do
				if data.title and rawTitle:find(data.title, 1, true) then
					ocData = data
					break
				end
			end
		end
		winData[i] = {
			win = win,
			winId = winId,
			btnColor = btnColor,
			label = label,
			hostname = hostname,
			basename = basename,
			branch = branch,
			wsName = wsName,
			prFromTitle = prFromTitle,
			ocData = ocData,
			claudeAgent = claudeAgent,
			textRows = RENDER.buildTextRows({
				label = label,
				hostname = hostname,
				branch = branch,
				wsName = wsName,
				prFromTitle = prFromTitle,
				ocData = ocData,
				claudeAgent = claudeAgent,
			}),
		}
	end
	return winData
end

local PAD_TOP = 5
local GAP = 3

function RENDER.computeTextArea(textW, rows)
	local areas = {}
	local y = PAD_TOP
	for _, row in ipairs(rows) do
		local rh = row.fs + 4
		table.insert(areas, { x = 6, y = y, w = textW, h = rh })
		y = y + rh + GAP
	end
	return areas
end

function OBJ:_renderFullSidebar(sb, winData, structureSnap, btnH)
	if self.sidebarCanvas then
		if not self._pendingSidebarFrame then
			self._pendingSidebarFrame = self.sidebarCanvas:frame()
		end
		self.sidebarCanvas:delete()
		self.sidebarCanvas = nil
	end

	self.sidebarCanvas = hs.canvas.new({ x = sb.x, y = sb.y, w = sb.w, h = sb.h })
	self.sidebarCanvas:level(hs.canvas.windowLevels.normal)
	self.sidebarCanvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
	self.sidebarCanvas:alpha(1)
	self.sidebarCanvas:clickActivating(false)
	local function noop() end
	self.sidebarCanvas:mouseCallback(noop)
	self._lastStructureSnapshot = structureSnap

	self.sidebarCanvas:appendElements({
		type = "rectangle",
		frame = { x = 0, y = 0, w = sb.w, h = sb.h },
		fillColor = COLOR(CFG.sidebarColor),
		strokeWidth = 0,
	})

	self.sidebarCanvas:appendElements({
		type = "rectangle",
		frame = { x = sb.w - 1, y = 0, w = 1, h = sb.h },
		fillColor = COLOR(CFG.borderColor),
		strokeWidth = 0,
	})

	local textW = sb.w - CFG.padding * 2 - 12
	local elemIdx = 3
	local y = 6

	self._btnBgElements = {}
	self._buttonFrames = {}

	for i, wd in ipairs(winData) do
		local winId = wd.winId
		local rows = wd.textRows
		local areas = RENDER.computeTextArea(textW, rows)

		self.sidebarCanvas:appendElements({
			type = "rectangle",
			frame = { x = CFG.padding, y = y, w = sb.w - CFG.padding * 2, h = btnH },
			fillColor = COLOR(wd.btnColor),
			strokeWidth = 0,
			roundedRectRadii = { xRadius = 4, yRadius = 4 },
		})
		local bgElemIdx = elemIdx
		elemIdx = elemIdx + 1

		for ri, row in ipairs(rows) do
			local a = areas[ri]
			self.sidebarCanvas:appendElements({
				type = "text",
				frame = { x = CFG.padding + 6, y = y + a.y, w = a.w, h = a.h },
				text = row.text,
				textColor = COLOR(row.color),
				textSize = row.fs,
				textAlignment = "left",
			})
			elemIdx = elemIdx + 1
		end

		self._btnBgElements[winId] = bgElemIdx

		self._buttonFrames[i] = {
			x = CFG.padding,
			y = y,
			w = sb.w - CFG.padding * 2,
			h = btnH,
			windowId = winId,
		}
		y = y + btnH + 4
	end

	self._pendingSidebarFrame = nil
end

function OBJ:_doBuildSidebar()
	if not self._sidebarVisible then
		self._buildPending = false
		return
	end
	if self._buildPending then
		return
	end
	self._buildPending = true

	local ok = pcall(function()
		self:_closeMenus()

		local wins = CACHE.getITermWindows()

		if #wins == 0 then
			if self.sidebarCanvas then
				self.sidebarCanvas:hide()
				self._sidebarVisible = false
			end
			return
		end

		local snap = RENDER.sidebarStateSnapshot(wins, self.activeWindowId, self._opencodeData)
		if snap == self._lastSidebarSnapshot then
			return
		end
		self._lastSidebarSnapshot = snap

		local sb = self:layoutFrames(self:getScreen():frame(), self:getSidebarAnchor()).sidebar

		local structureSnap = RENDER.sidebarStructureSnapshot(wins, sb.w, sb.h)
		-- True on first render or when window count/sidebar size changes;
		-- false on state-only changes so we skip retiling.
		local needsRetile = (self.sidebarCanvas == nil) or (structureSnap ~= self._lastStructureSnapshot)

		local orderedWins = self:_orderedWindows(wins)
		local winData = self:_gatherWindowData(orderedWins)
		local maxNumRows = 1
		for _, wd in ipairs(winData) do
			if #wd.textRows > maxNumRows then
				maxNumRows = #wd.textRows
			end
		end
		local btnH = RENDER.computeBtnHeight(maxNumRows, CFG.defaultFontSize)

		self:_renderFullSidebar(sb, winData, structureSnap, btnH)

		self:syncCanvasLevel()
		self.sidebarCanvas:show()
		self._sidebarVisible = true
		if needsRetile and self._sidebarEnabled and not self._skipTileOnThisBuild then
			self:tileITermWindows(sb)
		end
		self._skipTileOnThisBuild = false
		if self._swapInProgress then
			self._swapInProgress = false
			hs.alert.show(ACTION_LABELS.swapSide .. " Completed")
		end
		if self._refreshInProgress then
			self._refreshInProgress = false
			hs.alert.show(ACTION_LABELS.refresh .. " Completed")
		end
	end)

	if not ok then
		if self.sidebarCanvas then
			self.sidebarCanvas:delete()
			self.sidebarCanvas = nil
		end
		self._lastSidebarSnapshot = nil
		self._lastStructureSnapshot = nil
		self._buttonFrames = {}
		self._btnBgElements = {}
	end

	self._buildPending = false
end
