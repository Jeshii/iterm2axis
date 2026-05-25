--- iTerm2Axis - Hammerspoon Window Manager Spoon
--- A left-side sidebar for managing stacked iTerm2 windows, emulating cmux-like layout.
---
--- Download: [https://github.com/Jeshii/iterm2axis](https://github.com/Jeshii/iterm2axis)
--- @author Jesse Fuller
--- @license MIT

local obj = {}
obj.__index = obj

-- Metadata
obj.name     = "iTerm2Axis"
obj.version  = "0.1.0"
obj.author   = "Jesse Fuller"
obj.license  = "MIT - https://opensource.org/licenses/MIT"
obj.homepage = "https://github.com/Jeshii/iterm2axis"

obj.config = {
    sidebarWidth      = 160,
    sidebarColor      = { red = 0.12, green = 0.12, blue = 0.14, alpha = 0.95 },
    buttonColor       = { red = 0.2,  green = 0.2,  blue = 0.22, alpha = 1 },
    buttonHoverColor  = { red = 0.3,  green = 0.3,  blue = 0.35, alpha = 1 },
    activeButtonColor = { red = 0.25, green = 0.5,  blue = 0.8,  alpha = 1 },
    textColor         = { red = 0.9,  green = 0.9,  blue = 0.9,  alpha = 1 },

    windowButtonHeight = 74,  -- tall enough for 4 lines (opencode)
    padding           = 8,

    opencode = {
        enabled      = true,
        port         = 4096,
        pollInterval = 5,
    },
}

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

local function isITerm(win)
    if not win then return false end
    local app = win:application()
    if not app then return false end
    return app:bundleID() == "com.googlecode.iterm2"
end

local function getITermWindows()
    local all = hs.window.allWindows()
    local result = {}
    for _, w in ipairs(all) do
        if isITerm(w) and w:isStandard() and not w:isMinimized() then
            table.insert(result, w)
        end
    end
    table.sort(result, function(a, b) return a:id() < b:id() end)
    return result
end

local function color(c)
    return { red = c.red, green = c.green, blue = c.blue, alpha = c.alpha }
end

-- Parse iTerm2 window title into its components.
-- Handles formats:
--   "user@host: /full/path"   (shell integration with host + PWD)
--   "user@host: ~/path"       (tilde path)
--   "/full/path"              (PWD only)
--   "~/path"                  (tilde PWD only)
--   "dirname"                 (plain name, no path)
-- Returns: { host = string|nil, fullPath = string|nil, basename = string|nil }
local function parseTitleComponents(title)
    if not title or title == "" then return {} end
    local home = os.getenv("HOME") or ""

    local host, pathPart

    -- Try "user@host: /path" or "user@host: ~/path"
    local h, p = title:match("^[^@]+@([^:]+):%s*(~?/.+)$")
    if h and p then
        host = h
        pathPart = p
    else
        -- Try bare path (no host prefix)
        pathPart = title:match("^(~?/[^%s].*)$") or title:match("%s(~?/[^%s]+)%s*$")
    end

    local fullPath = pathPart and pathPart:gsub("^~", home):gsub("%s+$", "")
    local basename = fullPath and fullPath:match("([^/]+)%s*$")

    -- If still no basename, fall back to the last non-separator token in the raw title
    if not basename or basename == "" then
        basename = title:match("([^%s/:]+)%s*$")
    end

    return {
        host     = host,
        fullPath = fullPath,
        basename = basename,
    }
end

-- Per-window git branch cache, keyed by windowId.
-- Only re-runs `git rev-parse` when a window's title actually changes.
local _gitBranchCache = {}  -- [windowId] = branch string or false
local _gitTitleCache  = {}  -- [windowId] = last title seen

local function getGitBranchForWindow(win)
    if not win then return nil end
    local winId = win:id()
    local title = win:title() or ""

    -- Return cached value if title hasn't changed
    if _gitTitleCache[winId] == title then
        return _gitBranchCache[winId] or nil
    end

    -- Title changed (or first run) — update caches
    _gitTitleCache[winId] = title

    local home = os.getenv("HOME") or ""
    local branch
    local parts = parseTitleComponents(title)

    -- Strategy 1: use the full path extracted from the title
    if parts.fullPath then
        branch = hs.execute("git -C '" .. parts.fullPath .. "' rev-parse --abbrev-ref HEAD 2>/dev/null")
    end

    -- Strategy 2: fall back to treating basename as a dir under $HOME
    if (not branch or branch:gsub("%s+", "") == "") and parts.basename then
        branch = hs.execute(
            "git -C '" .. home .. "/" .. parts.basename .. "' rev-parse --abbrev-ref HEAD 2>/dev/null"
        )
    end

    branch = branch and branch:gsub("%s+$", "")
    local result = (branch and branch ~= "") and branch or false
    _gitBranchCache[winId] = result
    return result or nil
end

-- ─────────────────────────────────────────────
-- Opencode helpers
-- ─────────────────────────────────────────────

local function shortModelName(id)
    if not id or id == "" then return nil end
    local name = id:match("[^/]+$") or id
    name = name:gsub(":free$", ""):gsub(":default$", ""):gsub(":high$", ""):gsub(":max$", "")
    name = name:gsub("^deepseek%-", "ds-")
    if #name > 14 then name = name:sub(1, 12) .. "…" end
    return name
end

local function fmtTokens(n)
    if n >= 1000000 then return string.format("%.1fM", n / 1e6) end
    if n >= 1000 then return string.format("%.1fk", n / 1e3) end
    return tostring(n)
end

function obj:fetchOpenCodeData()
    local newData = {}
    local loaded = false

    -- Try HTTP API first (opencode serve)
    local okHttp, httpResult = pcall(hs.execute, "curl -s -m 2 http://127.0.0.1:" .. self.config.opencode.port .. "/session 2>/dev/null")
    if okHttp and httpResult and httpResult ~= "" then
        local ok, sessions = pcall(hs.json.decode, httpResult)
        if ok and type(sessions) == "table" then
            for _, s in ipairs(sessions) do
                if s.directory then
                    local existing = newData[s.directory]
                    if not existing or (s.time_updated or 0) > existing.updated then
                        local m = {}
                        if s.model then
                            local ok2, parsed = pcall(hs.json.decode, s.model)
                            if ok2 and type(parsed) == "table" then m = parsed end
                        end
                        newData[s.directory] = {
                            title    = s.title,
                            modelID  = m.id,
                            provider = m.providerID,
                            agent    = s.agent,
                            tokensIn = s.tokens_input or 0,
                            tokensOut = s.tokens_output or 0,
                            updated  = s.time_updated or 0,
                        }
                    end
                end
            end
            loaded = true
        end
    end

    -- Fall back to SQLite database
    if not loaded then
        local dbPath = os.getenv("HOME") .. "/.local/share/opencode/opencode.db"
        local sql = "SELECT title, directory, model, agent, tokens_input, tokens_output, time_updated FROM session ORDER BY time_updated DESC"
        local cmd = "sqlite3 -json '" .. dbPath .. "' \"" .. sql .. "\" 2>/dev/null"
        local okDB, dbResult = pcall(hs.execute, cmd)
        if okDB and dbResult and dbResult ~= "" then
            local ok, sessions = pcall(hs.json.decode, dbResult)
            if ok and type(sessions) == "table" then
                for _, s in ipairs(sessions) do
                    if s.directory and not newData[s.directory] then
                        local m = {}
                        if s.model then
                            local ok2, parsed = pcall(hs.json.decode, s.model)
                            if ok2 and type(parsed) == "table" then m = parsed end
                        end
                        newData[s.directory] = {
                            title    = s.title,
                            modelID  = m.id,
                            provider = m.providerID,
                            agent    = s.agent,
                            tokensIn = s.tokens_input or 0,
                            tokensOut = s.tokens_output or 0,
                            updated  = s.time_updated or 0,
                        }
                    end
                end
            end
        end
    end

    self._opencodeData = newData
end

function obj:startOpenCodePolling()
    self:fetchOpenCodeData()
    if self._opencodePollTimer then self._opencodePollTimer:stop() end
    self._opencodePollTimer = hs.timer.new(self.config.opencode.pollInterval, function()
        self:fetchOpenCodeData()
        if self.sidebarCanvas and self.sidebarCanvas:isShowing() then
            self:buildSidebar()
        end
    end)
    self._opencodePollTimer:start()
end

-- ─────────────────────────────────────────────
-- Layout
-- ─────────────────────────────────────────────

function obj:findWindowScreen(wins)
    if #wins == 0 then return hs.screen.mainScreen() end
    local win = wins[1]
    local wf = win:frame()
    local winCenter = { x = wf.x + wf.w / 2, y = wf.y + wf.h / 2 }
    for _, screen in ipairs(hs.screen.allScreens()) do
        local sf = screen:frame()
        if winCenter.x >= sf.x and winCenter.x < sf.x + sf.w and
           winCenter.y >= sf.y and winCenter.y < sf.y + sf.h then
            return screen
        end
    end
    return hs.screen.mainScreen()
end

function obj:getScreen()
    if self._currentScreen then return self._currentScreen end
    local wins = getITermWindows()
    local screen = self:findWindowScreen(wins)
    self._currentScreen = screen
    return screen
end

function obj:getSidebarAnchor()
    if self._pendingSidebarFrame then
        return self._pendingSidebarFrame
    end
    if self.sidebarCanvas then
        return self.sidebarCanvas:frame()
    end
    local screen = self:getScreen()
    local f = screen:frame()
    return { x = f.x, y = f.y, w = self.config.sidebarWidth, h = f.h }
end

function obj:computeLayout()
    local anchor = self:getSidebarAnchor()
    local screen = self:getScreen()
    local f      = screen:frame()
    local cfg    = self.config

    local sidebar = { x = anchor.x, y = anchor.y, w = cfg.sidebarWidth, h = anchor.h }
    local iterm   = {
        x = anchor.x + cfg.sidebarWidth,
        y = anchor.y,
        w = (f.x + f.w) - (anchor.x + cfg.sidebarWidth),
        h = anchor.h,
    }

    return {
        screen      = screen,
        screenFrame = f,
        sidebar     = sidebar,
        iterm       = iterm,
    }
end

-- ─────────────────────────────────────────────
-- Sidebar
-- ─────────────────────────────────────────────

function obj:buildSidebar()
    if self.sidebarCanvas then
        if not self._pendingSidebarFrame then
            self._pendingSidebarFrame = self.sidebarCanvas:frame()
        end
        self.sidebarCanvas:delete()
        self.sidebarCanvas = nil
    end

    local layout = self:computeLayout()
    local sb  = layout.sidebar
    local cfg = self.config

    local canvas = hs.canvas.new({ x = sb.x, y = sb.y, w = sb.w, h = sb.h })
    canvas:level(hs.canvas.windowLevels.floating)
    canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)
    canvas:alpha(1)

    -- Background
    canvas:appendElements({
        type = "rectangle",
        frame = { x = 0, y = 0, w = sb.w, h = sb.h },
        fillColor = color(cfg.sidebarColor),
        strokeWidth = 0,
    })

    -- Right border
    canvas:appendElements({
        type = "rectangle",
        frame = { x = sb.w - 1, y = 0, w = 1, h = sb.h },
        fillColor = { red = 0.3, green = 0.3, blue = 0.35, alpha = 0.5 },
        strokeWidth = 0,
    })

    -- Window buttons
    local itermWins = getITermWindows()
    local y = 6
    self._buttonFrames = {}

    -- If we have a saved ordering, reorder itermWins to match
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

    local textW = sb.w - cfg.padding * 2 - 12
    local textX = cfg.padding + 6

    for i, win in ipairs(itermWins) do
        local winId    = win:id()
        local isActive = (winId == self.activeWindowId)
        local btnColor = isActive and cfg.activeButtonColor or cfg.buttonColor
        local rawTitle = win:title() or ""
        local parts    = parseTitleComponents(rawTitle)

        -- Button background
        canvas:appendElements({
            type = "rectangle",
            frame = { x = cfg.padding, y = y, w = sb.w - cfg.padding * 2, h = cfg.windowButtonHeight },
            fillColor = color(btnColor),
            strokeWidth = 0,
            roundedRectRadii = { xRadius = 4, yRadius = 4 },
        })

        -- ── Line 1: custom rename → hostname → "Window N" fallback ──
        local label = self._customNames[winId]
            or parts.host
            or ("Window " .. i)
        if #label > 18 then label = label:sub(1, 16) .. "…" end
        canvas:appendElements({
            type          = "text",
            frame         = { x = textX, y = y + 5, w = textW, h = 15 },
            text          = label,
            textColor     = color(cfg.textColor),
            textSize      = 11,
            textAlignment = "left",
        })

        -- ── Line 2: PWD basename ──
        if parts.basename then
            local base = parts.basename
            if #base > 20 then base = base:sub(1, 18) .. "…" end
            canvas:appendElements({
                type          = "text",
                frame         = { x = textX, y = y + 22, w = textW, h = 13 },
                text          = base,
                textColor     = { red = 0.75, green = 0.75, blue = 0.8, alpha = 0.85 },
                textSize      = 10,
                textAlignment = "left",
            })
        end

        -- ── Line 3: git branch ──
        local branch = getGitBranchForWindow(win)
        if branch then
            if #branch > 20 then branch = branch:sub(1, 18) .. "…" end
            canvas:appendElements({
                type          = "text",
                frame         = { x = textX, y = y + 38, w = textW, h = 13 },
                text          = "⎇ " .. branch,
                textColor     = { red = 0.5, green = 0.75, blue = 0.5, alpha = 0.9 },
                textSize      = 10,
                textAlignment = "left",
            })
        end

        -- ── Line 4: opencode session info ──
        local ocData = parts.fullPath and self._opencodeData[parts.fullPath]
        if ocData then
            local modelStr = shortModelName(ocData.modelID) or ""
            local agentStr = ocData.agent or ""
            local tokStr = ""
            if ocData.tokensIn and ocData.tokensIn > 0 then
                tokStr = fmtTokens(ocData.tokensIn) .. " in"
                if ocData.tokensOut and ocData.tokensOut > 0 then
                    tokStr = tokStr .. " · " .. fmtTokens(ocData.tokensOut) .. " out"
                end
            end
            local segments = {}
            if modelStr ~= "" then table.insert(segments, modelStr) end
            if agentStr ~= "" then table.insert(segments, agentStr) end
            if tokStr ~= "" then table.insert(segments, tokStr) end
            local ocText = table.concat(segments, "  ")
            if #ocText > 26 then ocText = ocText:sub(1, 24) .. "…" end
            canvas:appendElements({
                type          = "text",
                frame         = { x = textX, y = y + 53, w = textW, h = 12 },
                text          = ocText,
                textColor     = { red = 0.6, green = 0.6, blue = 0.9, alpha = 0.85 },
                textSize      = 9,
                textAlignment = "left",
            })
        end

        self._buttonFrames[i] = {
            x = cfg.padding, y = y,
            w = sb.w - cfg.padding * 2, h = cfg.windowButtonHeight,
            windowId = winId,
        }
        y = y + cfg.windowButtonHeight + 4
    end

    self.sidebarCanvas = canvas
    self._pendingSidebarFrame = nil
    canvas:show()
end

-- ─────────────────────────────────────────────
-- Window Management
-- ─────────────────────────────────────────────

function obj:tileITermWindows()
    if not self.sidebarCanvas then return end
    local sf = self.sidebarCanvas:frame()
    local screen = self:getScreen()
    local screenFrame = screen:frame()
    local contentW = (screenFrame.x + screenFrame.w) - (sf.x + sf.w)
    local newFrame = { x = sf.x + sf.w, y = sf.y, w = contentW, h = sf.h }
    for _, win in ipairs(getITermWindows()) do
        win:setFrame(newFrame)
    end
end

function obj:bringWindowToFront(windowId)
    local win = hs.window.get(windowId)
    if not win then return end
    self.activeWindowId = windowId
    win:raise()
    win:focus()
    self:buildSidebar()
end

-- ─────────────────────────────────────────────
-- Mouse Handling
-- ─────────────────────────────────────────────

function obj:handleSidebarClick(x, y, rightClick)
    if not self._buttonFrames then return end

    for _, btn in ipairs(self._buttonFrames) do
        if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
            if rightClick then
                self:showWindowMenu(btn.windowId)
            end
            return
        end
    end
end

function obj:renameWindow(windowId)
    local win = hs.window.get(windowId)
    local currentName = self._customNames[windowId] or (win and win:title()) or ""
    local button, input = hs.dialog.textPrompt(
        "Rename Window",
        "Enter a custom name for this window:",
        currentName,
        "Rename",
        "Cancel"
    )
    if button == "Rename" and input and input ~= "" then
        self._customNames[windowId] = input
        self:buildSidebar()
    elseif button == "Rename" and (not input or input == "") then
        self._customNames[windowId] = nil
        self:buildSidebar()
    end
end

function obj:showWindowMenu(windowId)
    local choices = {
        { text = "Rename", subText = "Set a custom name for this window    ⌘⇧W" },
        { text = "Move Up", subText = "Reorder this window higher    ⌘⇧[" },
        { text = "Move Down", subText = "Reorder this window lower    ⌘⇧]" },
        { text = "Move to Top", subText = "Move this window to the top    ⌘⇧↑" },
        { text = "Move to Bottom", subText = "Move this window to the bottom    ⌘⇧↓" },
        { text = "Refresh Layout", subText = "Re-tile all windows    ⌘⇧R" },
        { text = "Show/Hide Axis", subText = "Toggle sidebar visibility    ⌘⇧A" },
        { text = "iTerm Settings", subText = "Show setup guide for reusing session directory" },
    }

    -- Show opencode session info for this window if available
    local win = hs.window.get(windowId)
    local title = win and win:title() or ""
    local parts = parseTitleComponents(title)
    if parts.fullPath and self._opencodeData[parts.fullPath] then
        local oc = self._opencodeData[parts.fullPath]
        local modelStr = shortModelName(oc.modelID) or "?"
        local titleStr = oc.title or "Untitled"
        if #titleStr > 40 then titleStr = titleStr:sub(1, 38) .. "…" end
        table.insert(choices, 1, {
            text = "OpenCode: " .. modelStr .. " (" .. (oc.agent or "?") .. ")",
            subText = titleStr .. "  ·  " .. fmtTokens(oc.tokensIn or 0) .. " in, " .. fmtTokens(oc.tokensOut or 0) .. " out",
        })
    end

    local chooser = hs.chooser.new(function(choice)
        if not choice then return end
        if choice.text == "Rename" then
            self:renameWindow(windowId)
        elseif choice.text == "Move Up" then
            self:moveWindowById(windowId, -1)
        elseif choice.text == "Move Down" then
            self:moveWindowById(windowId, 1)
        elseif choice.text == "Move to Top" then
            self:moveWindowToExtent(windowId, "top")
        elseif choice.text == "Move to Bottom" then
            self:moveWindowToExtent(windowId, "bottom")
        elseif choice.text == "Refresh Layout" then
            self:buildSidebar()
            self:tileITermWindows()
        elseif choice.text == "Show/Hide Axis" then
            if self.sidebarCanvas then
                if self.sidebarCanvas:isVisible() then
                    self.sidebarCanvas:hide()
                else
                    self:buildSidebar()
                    self:tileITermWindows()
                end
            else
                self:buildSidebar()
                self:tileITermWindows()
            end
        elseif choice.text == "iTerm Settings" then
            self:showPreferencesTip()
        end
    end)
    chooser:choices(choices)
    chooser:searchSubText(false)
    chooser:show()
end

function obj:showPreferencesTip()
    if self._tipCanvas then
        self._tipCanvas:delete()
        self._tipCanvas = nil
        if self._tipKey then self._tipKey:delete(); self._tipKey = nil end
        return
    end

    local spoonDir = hs.spoons.scriptPath():match("^(.+/)")
    local imgPath = spoonDir .. "preferences_tip.png"
    local img = hs.image.imageFromPath(imgPath)
    if not img then
        hs.alert.show("Tip image not found", 2)
        return
    end

    local screen = hs.screen.mainScreen():frame()
    local imgSize = img:size()

    local pad = 60
    local cw = screen.w - pad * 2
    local ch = screen.h - pad * 2

    local scale = math.min(cw / imgSize.w, ch / imgSize.h, 1)
    local iw = math.floor(imgSize.w * scale)
    local ih = math.floor(imgSize.h * scale)
    local ix = math.floor((cw - iw) / 2)
    local iy = math.floor((ch - ih) / 2)

    local canvas = hs.canvas.new({ x = screen.x, y = screen.y, w = screen.w, h = screen.h })
    canvas:level(hs.canvas.windowLevels.floating)
    canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

    canvas:appendElements({
        type = "rectangle",
        frame = { x = 0, y = 0, w = screen.w, h = screen.h },
        fillColor = { red = 0, green = 0, blue = 0, alpha = 0.5 },
        strokeWidth = 0,
    })
    canvas:appendElements({
        type = "image",
        image = img,
        frame = { x = pad + ix, y = pad + iy, w = iw, h = ih },
    })

    canvas:canvasMouseEvents(true)
    canvas:mouseCallback(function(_, _, event)
        if event == "leftMouseDown" then
            canvas:delete()
            if self._tipCanvas == canvas then self._tipCanvas = nil end
            if self._tipKey then self._tipKey:delete(); self._tipKey = nil end
        end
    end)

    self._tipKey = hs.hotkey.bind({}, "escape", function()
        canvas:delete()
        if self._tipCanvas == canvas then self._tipCanvas = nil end
        if self._tipKey then self._tipKey:delete(); self._tipKey = nil end
    end)

    canvas:show()
    self._tipCanvas = canvas
end

function obj:moveWindowById(windowId, direction)
    if not self._orderedWindowIds then self._orderedWindowIds = {} end
    if #self._orderedWindowIds == 0 then
        local wins = getITermWindows()
        for _, win in ipairs(wins) do
            table.insert(self._orderedWindowIds, win:id())
        end
    end
    if #self._orderedWindowIds < 2 then return end

    local currentIdx
    for i, id in ipairs(self._orderedWindowIds) do
        if id == windowId then currentIdx = i; break end
    end
    if not currentIdx then return end

    local newIdx = currentIdx + direction
    if newIdx < 1 or newIdx > #self._orderedWindowIds then return end

    self._orderedWindowIds[currentIdx], self._orderedWindowIds[newIdx] =
        self._orderedWindowIds[newIdx], self._orderedWindowIds[currentIdx]
    self:buildSidebar()
end

function obj:moveWindowToExtent(windowId, extent)
    if not self._orderedWindowIds then self._orderedWindowIds = {} end
    if #self._orderedWindowIds == 0 then
        local wins = getITermWindows()
        for _, win in ipairs(wins) do
            table.insert(self._orderedWindowIds, win:id())
        end
    end
    if #self._orderedWindowIds < 2 then return end

    local currentIdx
    for i, id in ipairs(self._orderedWindowIds) do
        if id == windowId then currentIdx = i; break end
    end
    if not currentIdx then return end

    local targetIdx = extent == "top" and 1 or #self._orderedWindowIds
    if currentIdx == targetIdx then return end

    table.remove(self._orderedWindowIds, currentIdx)
    table.insert(self._orderedWindowIds, targetIdx, windowId)
    self:buildSidebar()
end

-- ─────────────────────────────────────────────
-- Per-Window UIElement Watcher (for resize events)
-- ─────────────────────────────────────────────

function obj:watchWindow(win)
    if not win then return end
    local id = win:id()
    if self._windowWatchers[id] then return end
    local watcher = win:newWatcher(function(element, event)
        if event == hs.uielement.watcher.windowResized
        or event == hs.uielement.watcher.windowMoved then
            self:handleWindowMoveOrResize()
        end
    end, self)
    watcher:start({
        hs.uielement.watcher.windowResized,
        hs.uielement.watcher.windowMoved,
    })
    self._windowWatchers[id] = watcher
end

-- ─────────────────────────────────────────────
-- Window Move/Resize Handler (debounced)
-- ─────────────────────────────────────────────

function obj:handleWindowMoveOrResize()
    if self._resizeDebounceTimer then
        self._resizeDebounceTimer:stop()
    end
    self._resizeDebounceTimer = hs.timer.doAfter(0.3, function()
        local wins = getITermWindows()
        if #wins == 0 then return end

        local winScreen     = self:findWindowScreen(wins)
        local screenChanged = (winScreen ~= self._currentScreen)
        local cfg           = self.config

        if screenChanged then
            self._currentScreen       = winScreen
            self._pendingSidebarFrame = nil
            self:buildSidebar()
            self:tileITermWindows()
            return
        end

        local currentAnchor = self:getSidebarAnchor()
        local expectedX = currentAnchor.x + cfg.sidebarWidth
        local expectedY = currentAnchor.y
        local expectedH = currentAnchor.h

        local driftedWin = nil
        for i = #wins, 1, -1 do
            local f = wins[i]:frame()
            if math.abs(f.x - expectedX) > 5
            or math.abs(f.y - expectedY) > 5
            or math.abs(f.h - expectedH) > 5 then
                driftedWin = wins[i]
                break
            end
        end

        if driftedWin then
            local f        = driftedWin:frame()
            local sf       = winScreen:frame()
            local sidebarW = cfg.sidebarWidth

            if f.w <= sidebarW then return end

            local anchorX  = f.x
            local sidebarX = math.max(anchorX, sf.x)
            local contentX = sidebarX + sidebarW
            local maxW     = (sf.x + sf.w) - contentX
            if maxW <= 0 then return end
            local contentW = math.min(f.w - sidebarW, maxW)

            self._pendingSidebarFrame = { x = sidebarX, y = f.y, w = sidebarW, h = f.h }
            self._currentScreen = winScreen

            local newFrame = { x = contentX, y = f.y, w = contentW, h = f.h }
            for _, w in ipairs(wins) do w:setFrame(newFrame) end

            self:buildSidebar()
        end
    end)
end

-- ─────────────────────────────────────────────
-- Spoon API: bindHotkeys
-- ─────────────────────────────────────────────

--- iTerm2Axis:bindHotkeys(mapping)
--- Method
--- Bind hotkeys for iTerm2Axis.
---
--- Parameters:
---  * mapping - A table with keys: toggle, newWindow, refresh
---    Each value is a table: { modifiers, key }
function obj:bindHotkeys(mapping)
    local map = mapping or {}

    local toggleMods, toggleKey         = table.unpack(map.toggle       or {{"cmd","shift"}, "A"})
    local newWinMods, newWinKey         = table.unpack(map.newWindow    or {{"cmd","shift"}, "N"})
    local refreshMods, refreshKey       = table.unpack(map.refresh      or {{"cmd","shift"}, "R"})
    local renameMods, renameKey         = table.unpack(map.renameWindow or {{"cmd","shift"}, "W"})
    local moveUpMods, moveUpKey         = table.unpack(map.moveUp       or {{"cmd","shift"}, "["})
    local moveDownMods, moveDownKey     = table.unpack(map.moveDown     or {{"cmd","shift"}, "]"})
    local moveTopMods, moveTopKey       = table.unpack(map.moveToTop    or {{"cmd","shift"}, "up"})
    local moveBottomMods, moveBottomKey = table.unpack(map.moveToBottom or {{"cmd","shift"}, "down"})

    hs.hotkey.bind(toggleMods, toggleKey, function()
        if self.sidebarCanvas then
            if self.sidebarCanvas:isVisible() then
                self.sidebarCanvas:hide()
            else
                self:buildSidebar(); self:tileITermWindows()
            end
        else
            self:buildSidebar(); self:tileITermWindows()
        end
    end)

    hs.hotkey.bind(newWinMods, newWinKey, function()
        local iterm = hs.application.find("iTerm2")
        if iterm then
            iterm:activate()
            hs.eventtap.keyStroke({"cmd"}, "n")
            hs.timer.doAfter(0.5, function() self:buildSidebar(); self:tileITermWindows() end)
        else
            hs.application.open("com.googlecode.iterm2")
            hs.timer.doAfter(1.0, function() self:buildSidebar(); self:tileITermWindows() end)
        end
    end)

    hs.hotkey.bind(refreshMods, refreshKey, function()
        self:buildSidebar(); self:tileITermWindows()
    end)

    hs.hotkey.bind(renameMods, renameKey, function()
        if self.activeWindowId then self:renameWindow(self.activeWindowId) end
    end)

    hs.hotkey.bind(moveUpMods, moveUpKey, function()
        if self.activeWindowId then self:moveWindowById(self.activeWindowId, -1) end
    end)

    hs.hotkey.bind(moveDownMods, moveDownKey, function()
        if self.activeWindowId then self:moveWindowById(self.activeWindowId, 1) end
    end)

    hs.hotkey.bind(moveTopMods, moveTopKey, function()
        if self.activeWindowId then self:moveWindowToExtent(self.activeWindowId, "top") end
    end)

    hs.hotkey.bind(moveBottomMods, moveBottomKey, function()
        if self.activeWindowId then self:moveWindowToExtent(self.activeWindowId, "bottom") end
    end)
end

-- ─────────────────────────────────────────────
-- Spoon API: start / stop
-- ─────────────────────────────────────────────

function obj:start()
    if self._mouseTap then self._mouseTap:stop() end
    self._mouseTap = hs.eventtap.new(
        {
            hs.eventtap.event.types.leftMouseDown,
            hs.eventtap.event.types.rightMouseDown,
            hs.eventtap.event.types.leftMouseDragged,
            hs.eventtap.event.types.leftMouseUp,
        },
        function(event)
            local eventType = event:getType()
            local mouse     = hs.mouse.absolutePosition()

            if not self.sidebarCanvas then return false end
            local sf = self.sidebarCanvas:frame()

            local inSidebar = mouse.x >= sf.x and mouse.x <= sf.x + sf.w
                and mouse.y >= sf.y and mouse.y <= sf.y + sf.h

            if eventType == hs.eventtap.event.types.leftMouseDown then
                if inSidebar then
                    local lx, ly = mouse.x - sf.x, mouse.y - sf.y
                    if self._buttonFrames then
                        for _, btn in ipairs(self._buttonFrames) do
                            if lx >= btn.x and lx <= btn.x + btn.w
                            and ly >= btn.y and ly <= btn.y + btn.h then
                                self:bringWindowToFront(btn.windowId)
                                return true
                            end
                        end
                    end
                    return true
                end
            elseif eventType == hs.eventtap.event.types.rightMouseDown then
                if inSidebar then
                    self:handleSidebarClick(mouse.x - sf.x, mouse.y - sf.y, true)
                    return true
                end
            end
            return false
        end
    )
    self._mouseTap:start()

    if self._winWatcher then self._winWatcher:stop() end
    self._winWatcher = hs.window.filter.new("iTerm2")
    self._winWatcher:subscribe("windowCreated", function(win)
        if win then self:watchWindow(win) end
        hs.timer.doAfter(0.3, function() self:buildSidebar(); self:tileITermWindows() end)
    end)
    self._winWatcher:subscribe("windowDestroyed", function(win)
        local id = win and win:id()
        if id then
            if self._windowWatchers[id] then
                self._windowWatchers[id]:stop()
                self._windowWatchers[id] = nil
            end
            _gitBranchCache[id] = nil
            _gitTitleCache[id]  = nil
        end
        hs.timer.doAfter(0.3, function() self:buildSidebar() end)
    end)
    self._winWatcher:subscribe("windowTitleChanged", function(win)
        if win then
            local id = win:id()
            _gitTitleCache[id] = nil
        end
        hs.timer.doAfter(0.1, function() self:buildSidebar() end)
    end)
    self._winWatcher:subscribe("windowMoved", function()
        self:handleWindowMoveOrResize()
    end)
    self._winWatcher:subscribe("windowFocused", function()
        if self.sidebarCanvas and self.sidebarCanvas:isShowing() then
            self:handleWindowMoveOrResize()
        end
    end)

    for _, win in ipairs(getITermWindows()) do
        self:watchWindow(win)
    end

    if self._screenWatcher then self._screenWatcher:stop() end
    self._screenWatcher = hs.screen.watcher.new(function()
        hs.timer.doAfter(0.3, function()
            self:buildSidebar(); self:tileITermWindows()
        end)
    end)
    self._screenWatcher:start()

    self:buildSidebar()
    self:tileITermWindows()

    if self.config.opencode.enabled then
        self:startOpenCodePolling()
    end

    hs.alert.show("iTerm2 Axis loaded ✓", 1.5)
    return self
end

function obj:stop()
    if self._mouseTap      then self._mouseTap:stop();      self._mouseTap      = nil end
    if self._winWatcher    then self._winWatcher:stop();    self._winWatcher    = nil end
    if self._screenWatcher then self._screenWatcher:stop(); self._screenWatcher = nil end
    for _, w in pairs(self._windowWatchers or {}) do w:stop() end
    self._windowWatchers = {}
    if self.sidebarCanvas then self.sidebarCanvas:delete(); self.sidebarCanvas = nil end
    if self._tipCanvas    then self._tipCanvas:delete();    self._tipCanvas    = nil end
    if self._tipKey       then self._tipKey:delete();       self._tipKey       = nil end
    _gitBranchCache = {}
    _gitTitleCache  = {}
    if self._opencodePollTimer then self._opencodePollTimer:stop(); self._opencodePollTimer = nil end
    return self
end

function obj:init()
    self.windows        = {}
    self.sidebarCanvas  = nil
    self.activeWindowId = nil
    self._currentScreen = nil
    self._buttonFrames  = {}
    self._resizeDebounceTimer = nil
    self._pendingSidebarFrame = nil
    self._mouseTap       = nil
    self._winWatcher     = nil
    self._screenWatcher  = nil
    self._tipCanvas      = nil
    self._tipKey         = nil
    self._windowWatchers   = {}
    self._customNames      = {}
    self._orderedWindowIds = {}
    self._opencodeData     = {}
    self._opencodePollTimer = nil
    _gitBranchCache        = {}
    _gitTitleCache         = {}
    return self
end

return obj
