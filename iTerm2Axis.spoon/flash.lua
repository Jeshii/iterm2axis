local _sharedFlashTimer = nil
local _currentFlashInterval = nil
local _flashingWindows = {}
local _flashState = {}
local _flashNormalColor = {}
local _flashType = {}

function FLASH.claudeState(win)
	local title = win:title() or ""
	local stripped = title:gsub("^🔔", "")
	if stripped:match("^✳") then
		return "waiting"
	end
	if stripped:match("^·") then
		return "busy"
	end
	if title:match("^🔔") then
		return "bell"
	end
	return nil
end

function FLASH.flashIntervalForType(flashType)
	return (flashType == "bell") and CFG.bell.flashInterval or CFG.claudecode.flashInterval
end

function FLASH.flashState(winId)
	return _flashState[winId]
end

function FLASH.reset()
	if _sharedFlashTimer then
		_sharedFlashTimer:stop()
		_sharedFlashTimer = nil
	end
	_currentFlashInterval = nil
	_flashingWindows = {}
	_flashState = {}
	_flashNormalColor = {}
	_flashType = {}
end

function FLASH.minActiveFlashInterval()
	local minInterval = math.huge
	for wid in pairs(_flashingWindows) do
		local ft = _flashType[wid] or "waiting"
		local interval = FLASH.flashIntervalForType(ft)
		if interval < minInterval then
			minInterval = interval
		end
	end
	return minInterval
end

local function _adjustFlashTimer()
	if not next(_flashingWindows) then
		if _sharedFlashTimer then
			_sharedFlashTimer:stop()
			_sharedFlashTimer = nil
			_currentFlashInterval = nil
		end
		return
	end

	local newInterval = FLASH.minActiveFlashInterval()
	if not _sharedFlashTimer or newInterval ~= _currentFlashInterval then
		if _sharedFlashTimer then
			_sharedFlashTimer:stop()
		end
		_currentFlashInterval = newInterval
		_sharedFlashTimer = hs.timer.new(newInterval, function()
			for wid in pairs(_flashingWindows) do
				_flashState[wid] = not _flashState[wid]
				local bgIdx = OBJ._btnBgElements[wid]
				if bgIdx and OBJ.sidebarCanvas and OBJ.sidebarCanvas:isShowing() then
					local normalCol = _flashNormalColor[wid]
					local flashColor = (_flashType[wid] == "bell") and CFG.bell.flashColor or CFG.waitingFlashColor
					local newColor = _flashState[wid] and flashColor
						or (normalCol and COLOR(normalCol) or COLOR(CFG.buttonColor))
					OBJ.sidebarCanvas:elementAttribute(bgIdx, "fillColor", COLOR(newColor))
				end
			end
		end)
		_sharedFlashTimer:start()
	end
end

function FLASH.startFlashing(winId, flashType)
	flashType = flashType or "waiting"

	if _flashingWindows[winId] then
		if _flashType[winId] ~= flashType then
			_flashType[winId] = flashType
			_adjustFlashTimer()
		end
		return
	end

	_flashType[winId] = flashType
	_flashState[winId] = true
	local isActive = (winId == OBJ.activeWindowId)
	_flashNormalColor[winId] = isActive and CFG.activeButtonColor or CFG.buttonColor
	_flashingWindows[winId] = true
	_adjustFlashTimer()
end

function FLASH.stopFlashing(winId)
	_flashingWindows[winId] = nil
	_flashState[winId] = nil
	_flashType[winId] = nil
	local normalColor = _flashNormalColor[winId]
	_flashNormalColor[winId] = nil

	if normalColor and OBJ.sidebarCanvas and OBJ.sidebarCanvas:isShowing() then
		local bgIdx = OBJ._btnBgElements[winId]
		if bgIdx then
			OBJ.sidebarCanvas:elementAttribute(bgIdx, "fillColor", COLOR(normalColor))
		end
	end

	_adjustFlashTimer()
end
