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
    helpMenuHeight    = 200,
    moveButtonHeight  = 30,
    windowButtonHeight = 36,
    padding           = 8,
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

function obj:computeLayout()
    local screen = self:getScreen()
    local f = screen:frame()
    local cfg = self.config

    local sidebarX = f.x
    if self.sidebarCanvas then
        local sf = self.sidebarCanvas:frame()
        if math.abs(sf.y - f.y) < f.h then
            sidebarX = sf.x
        end
    end

    local sidebar = { x = sidebarX, y = f.y, w = cfg.sidebarWidth, h = f.h }
    local iterm   = {
        x = sidebarX + cfg.sidebarWidth,
        y = f.y,
        w = f.w - cfg.sidebarWidth - (sidebarX - f.x),
        h = f.h,
    }
    local helpH = self.helpMenuOpen and cfg.helpMenuHeight or 0

    return {
        screen      = screen,
        screenFrame = f,
        sidebar     = sidebar,
        iterm       = iterm,
        helpHeight  = helpH,
    }
end

-- ─────────────────────────────────────────────
-- Sidebar
-- ─────────────────────────────────────────────

function obj:buildSidebar()
    if self.sidebarCanvas then
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

    -- Move button (top)
    canvas:appendElements({
        type = "rectangle",
        frame = { x = 0, y = 0, w = sb.w, h = cfg.moveButtonHeight },
        fillColor = { red = 0.15, green = 0.15, blue = 0.18, alpha = 1 },
        strokeWidth = 0,
    })
    canvas:appendElements({
        type = "text",
        frame = { x = 0, y = 2, w = sb.w, h = cfg.moveButtonHeight },
        text = "⠿  Move",
        textColor = { red = 0.6, green = 0.6, blue = 0.65, alpha = 1 },
        textSize = 12,
        textAlignment = "center",
    })

    -- Separator
    canvas:appendElements({
        type = "rectangle",
        frame = { x = cfg.padding, y = cfg.moveButtonHeight, w = sb.w - cfg.padding * 2, h = 1 },
        fillColor = { red = 0.3, green = 0.3, blue = 0.35, alpha = 0.4 },
        strokeWidth = 0,
    })

    -- Window buttons
    local itermWins = getITermWindows()
    local y = cfg.moveButtonHeight + 6
    self._buttonFrames = {}

    for i, win in ipairs(itermWins) do
        local winId   = win:id()
        local isActive = (winId == self.activeWindowId)
        local btnColor = isActive and cfg.activeButtonColor or cfg.buttonColor

        canvas:appendElements({
            type = "rectangle",
            frame = { x = cfg.padding, y = y, w = sb.w - cfg.padding * 2, h = cfg.windowButtonHeight },
            fillColor = color(btnColor),
            strokeWidth = 0,
            roundedRectRadii = { xRadius = 4, yRadius = 4 },
        })

        local title = win:title() or ("Window " .. i)
        if #title > 18 then title = title:sub(1, 16) .. "…" end

        canvas:appendElements({
            type = "text",
            frame = { x = cfg.padding + 6, y = y + 2, w = sb.w - cfg.padding * 2 - 12, h = cfg.windowButtonHeight },
            text = title,
            textColor = color(cfg.textColor),
            textSize = 11,
            textAlignment = "left",
        })

        self._buttonFrames[i] = {
            x = cfg.padding, y = y,
            w = sb.w - cfg.padding * 2, h = cfg.windowButtonHeight,
            windowId = winId,
        }
        y = y + cfg.windowButtonHeight + 4
    end

    -- Separator before help
    canvas:appendElements({
        type = "rectangle",
        frame = { x = cfg.padding, y = y, w = sb.w - cfg.padding * 2, h = 1 },
        fillColor = { red = 0.3, green = 0.3, blue = 0.35, alpha = 0.4 },
        strokeWidth = 0,
    })
    y = y + 6

    -- Help toggle button
    canvas:appendElements({
        type = "rectangle",
        frame = { x = cfg.padding, y = y, w = sb.w - cfg.padding * 2, h = 28 },
        fillColor = { red = 0.18, green = 0.18, blue = 0.22, alpha = 1 },
        strokeWidth = 0,
        roundedRectRadii = { xRadius = 4, yRadius = 4 },
    })
    canvas:appendElements({
        type = "text",
        frame = { x = 0, y = y, w = sb.w, h = 28 },
        text = (self.helpMenuOpen and "▴  Help" or "▾  Help"),
        textColor = { red = 0.7, green = 0.7, blue = 0.75, alpha = 1 },
        textSize = 11,
        textAlignment = "center",
    })

    self._helpButtonFrame = {
        x = cfg.padding, y = y,
        w = sb.w - cfg.padding * 2, h = 28,
    }

    self.sidebarCanvas = canvas
    canvas:show()
end

-- ─────────────────────────────────────────────
-- Help Menu
-- ─────────────────────────────────────────────

function obj:buildHelpMenu()
    if self.helpCanvas then
        self.helpCanvas:delete()
        self.helpCanvas = nil
    end
    if not self.helpMenuOpen then return end

    local layout = self:computeLayout()
    local sb  = layout.sidebar
    local cfg = self.config
    local helpY = sb.h - layout.helpHeight

    local canvas = hs.canvas.new({
        x = sb.x, y = sb.y + helpY, w = sb.w, h = layout.helpHeight
    })
    canvas:level(hs.canvas.windowLevels.floating)
    canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

    canvas:appendElements({
        type = "rectangle",
        frame = { x = 0, y = 0, w = sb.w, h = layout.helpHeight },
        fillColor = { red = 0.1, green = 0.1, blue = 0.12, alpha = 0.95 },
        strokeWidth = 0,
    })
    canvas:appendElements({
        type = "rectangle",
        frame = { x = 0, y = 0, w = sb.w, h = 1 },
        fillColor = { red = 0.3, green = 0.3, blue = 0.35, alpha = 0.5 },
        strokeWidth = 0,
    })

    local helpLines = {
        "⌘ Shortcuts:",
        "",
        "⌘⇧A  Show/Hide Axis",
        "⌘⇧N  New iTerm window",
        "⌘⇧R  Refresh layout",
        "",
        "Custom Commands:",
        "",
        "Add your own in the",
        "help section of init.lua",
    }

    local y = 10
    for _, line in ipairs(helpLines) do
        local isHeader = line:sub(-1) == ":"
        canvas:appendElements({
            type = "text",
            frame = { x = cfg.padding, y = y, w = sb.w - cfg.padding * 2, h = 16 },
            text = line,
            textColor = isHeader
                and { red = 0.5, green = 0.7, blue = 1.0, alpha = 1 }
                or  { red = 0.7, green = 0.7, blue = 0.75, alpha = 1 },
            textSize = 10,
            textAlignment = "left",
        })
        y = y + 14
    end

    self.helpCanvas = canvas
    canvas:show()
end

-- ─────────────────────────────────────────────
-- Window Management
-- ─────────────────────────────────────────────

function obj:tileITermWindows()
    local layout     = self:computeLayout()
    local itermFrame = layout.iterm
    for _, win in ipairs(getITermWindows()) do
        win:setFrame({ x = itermFrame.x, y = itermFrame.y, w = itermFrame.w, h = itermFrame.h })
    end
end

function obj:bringWindowToFront(windowId)
    local win = hs.window.find(windowId)
    if not win then return end
    self.activeWindowId = windowId
    win:raise()
    win:focus()
    self:buildSidebar()
end

function obj:moveAllWindows(dx, dy)
    for _, win in ipairs(getITermWindows()) do
        local f = win:frame()
        win:setFrame({ x = f.x + dx, y = f.y + dy, w = f.w, h = f.h })
    end
    if self.sidebarCanvas then
        local sf = self.sidebarCanvas:frame()
        self.sidebarCanvas:setTopLeft({ x = sf.x + dx, y = sf.y + dy })
    end
    if self.helpCanvas then
        local hf = self.helpCanvas:frame()
        self.helpCanvas:setTopLeft({ x = hf.x + dx, y = hf.y + dy })
    end
end

-- ─────────────────────────────────────────────
-- Mouse Handling
-- ─────────────────────────────────────────────

function obj:handleSidebarClick(x, y)
    if not self._buttonFrames then return end

    local hb = self._helpButtonFrame
    if hb and x >= hb.x and x <= hb.x + hb.w and y >= hb.y and y <= hb.y + hb.h then
        self.helpMenuOpen = not self.helpMenuOpen
        self:buildSidebar()
        self:buildHelpMenu()
        self:tileITermWindows()
        return
    end

    for _, btn in ipairs(self._buttonFrames) do
        if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
            self:bringWindowToFront(btn.windowId)
            return
        end
    end
end

-- ─────────────────────────────────────────────
-- Drag to Move
-- ─────────────────────────────────────────────

function obj:startDrag()
    local mouse = hs.mouse.absolutePosition()
    self.dragStart = { x = mouse.x, y = mouse.y }
    self.dragging = true
end

function obj:updateDrag()
    if not self.dragging then return end
    local mouse = hs.mouse.absolutePosition()
    local dx = mouse.x - self.dragStart.x
    local dy = mouse.y - self.dragStart.y
    if dx ~= 0 or dy ~= 0 then
        self:moveAllWindows(dx, dy)
        self.dragStart = { x = mouse.x, y = mouse.y }
    end
end

function obj:stopDrag()
    self.dragging = false
end

-- ─────────────────────────────────────────────
-- Window Move/Resize Handler (debounced)
-- ─────────────────────────────────────────────

function obj:handleWindowMoveOrResize()
    if self._resizeDebounceTimer then
        self._resizeDebounceTimer:stop()
    end
    self._resizeDebounceTimer = hs.timer.doAfter(0.15, function()
        if self.dragging then return end

        local wins = getITermWindows()
        if #wins == 0 then return end

        local winScreen   = self:findWindowScreen(wins)
        local screenChanged = (winScreen ~= self._currentScreen)
        local layout      = self:computeLayout()
        local iterm       = layout.iterm
        local cfg         = self.config

        local expected = nil
        if self.sidebarCanvas then
            local sf = self.sidebarCanvas:frame()
            expected = { x = sf.x + sf.w, y = sf.y, w = iterm.w, h = sf.h }
        else
            expected = iterm
        end

        if screenChanged then
            self._currentScreen = winScreen
            self:buildSidebar()
            self:buildHelpMenu()
            self:tileITermWindows()
            return
        end

        local function isDrifted(win)
            local f = win:frame()
            return math.abs(f.x - expected.x) > 5 or
                   math.abs(f.y - expected.y) > 5 or
                   math.abs(f.w - expected.w) > 5 or
                   math.abs(f.h - expected.h) > 5
        end

        local driftedWin = nil
        for i = #wins, 1, -1 do
            if isDrifted(wins[i]) then
                driftedWin = wins[i]
                break
            end
        end

        if driftedWin then
            local f        = driftedWin:frame()
            local sidebarW = cfg.sidebarWidth
            local sidebarX = f.x

            if self.sidebarCanvas then
                self.sidebarCanvas:setFrame({ x = sidebarX, y = f.y, w = sidebarW, h = f.h })
            end
            if self.helpCanvas then
                local helpH = self.helpMenuOpen and cfg.helpMenuHeight or 0
                self.helpCanvas:setFrame({ x = sidebarX, y = f.y + f.h - helpH, w = sidebarW, h = helpH })
            end

            local contentX = sidebarX + sidebarW
            local contentW = f.w - sidebarW

            if contentW < 100 then
                local screenLeft = layout.screenFrame.x
                sidebarX = f.x - sidebarW
                if sidebarX < screenLeft then sidebarX = screenLeft end
                contentX = sidebarX + sidebarW
                contentW = f.x + f.w - contentX
                if self.sidebarCanvas then
                    self.sidebarCanvas:setFrame({ x = sidebarX, y = f.y, w = sidebarW, h = f.h })
                end
                if self.helpCanvas then
                    local helpH = self.helpMenuOpen and cfg.helpMenuHeight or 0
                    self.helpCanvas:setFrame({ x = sidebarX, y = f.y + f.h - helpH, w = sidebarW, h = helpH })
                end
            end

            local newFrame = { x = contentX, y = f.y, w = contentW, h = f.h }
            for _, w in ipairs(wins) do w:setFrame(newFrame) end

            self:buildSidebar()
            self:buildHelpMenu()

            local center    = { x = contentX + contentW / 2, y = f.y + f.h / 2 }
            local newScreen = hs.screen.find(center)
            if newScreen then self._currentScreen = newScreen end
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
---    e.g. { toggle = {{"cmd","shift"}, "A"}, newWindow = {{"cmd","shift"}, "N"}, refresh = {{"cmd","shift"}, "R"} }
function obj:bindHotkeys(mapping)
    local map = mapping or {}

    local toggleMods, toggleKey = table.unpack(map.toggle or {{"cmd","shift"}, "A"})
    local newWinMods, newWinKey = table.unpack(map.newWindow or {{"cmd","shift"}, "N"})
    local refreshMods, refreshKey = table.unpack(map.refresh or {{"cmd","shift"}, "R"})

    hs.hotkey.bind(toggleMods, toggleKey, function()
        if self.sidebarCanvas then
            if self.sidebarCanvas:isVisible() then
                self.sidebarCanvas:hide()
                if self.helpCanvas then self.helpCanvas:hide() end
            else
                self:buildSidebar()
                self:buildHelpMenu()
                self:tileITermWindows()
            end
        else
            self:buildSidebar()
            self:buildHelpMenu()
            self:tileITermWindows()
        end
    end)

    hs.hotkey.bind(newWinMods, newWinKey, function()
        local iterm = hs.application.find("iTerm2")
        if iterm then
            iterm:activate()
            hs.eventtap.keyStroke({"cmd"}, "n")
            hs.timer.doAfter(0.5, function()
                self:buildSidebar()
                self:tileITermWindows()
            end)
        else
            hs.application.open("com.googlecode.iterm2")
            hs.timer.doAfter(1.0, function()
                self:buildSidebar()
                self:tileITermWindows()
            end)
        end
    end)

    hs.hotkey.bind(refreshMods, refreshKey, function()
        self:buildSidebar()
        self:buildHelpMenu()
        self:tileITermWindows()
    end)
end

-- ─────────────────────────────────────────────
-- Spoon API: start / stop
-- ─────────────────────────────────────────────

--- iTerm2Axis:start()
--- Method
--- Start iTerm2Axis: build UI, attach watchers, and start mouse tap.
function obj:start()
    -- Mouse tap
    if self._mouseTap then self._mouseTap:stop() end
    self._mouseTap = hs.eventtap.new(
        {
            hs.eventtap.event.types.leftMouseDown,
            hs.eventtap.event.types.leftMouseDragged,
            hs.eventtap.event.types.leftMouseUp,
        },
        function(event)
            local eventType = event:getType()
            local mouse     = hs.mouse.absolutePosition()

            if not self.sidebarCanvas then return false end
            local sf = self.sidebarCanvas:frame()

            local inMoveArea = mouse.x >= sf.x and mouse.x <= sf.x + sf.w
                and mouse.y >= sf.y and mouse.y <= sf.y + self.config.moveButtonHeight
            local inSidebar = mouse.x >= sf.x and mouse.x <= sf.x + sf.w
                and mouse.y >= sf.y and mouse.y <= sf.y + sf.h

            if eventType == hs.eventtap.event.types.leftMouseDown then
                if inMoveArea then
                    self:startDrag()
                    return true
                elseif inSidebar then
                    self:handleSidebarClick(mouse.x - sf.x, mouse.y - sf.y)
                    return true
                end
            elseif eventType == hs.eventtap.event.types.leftMouseDragged then
                if self.dragging then self:updateDrag(); return true end
            elseif eventType == hs.eventtap.event.types.leftMouseUp then
                if self.dragging then self:stopDrag(); return true end
            end
            return false
        end
    )
    self._mouseTap:start()

    -- Window watcher
    -- NOTE: hs.window.filter does not support "windowResized" as an event.
    -- Use "windowMoved" to detect layout drift, which covers most resize-via-drag
    -- cases. For true resize events, an hs.uielement.watcher would be needed.
    if self._winWatcher then self._winWatcher:stop() end
    self._winWatcher = hs.window.filter.new("iTerm2")
    self._winWatcher:subscribe("windowCreated", function()
        hs.timer.doAfter(0.3, function() self:buildSidebar(); self:tileITermWindows() end)
    end)
    self._winWatcher:subscribe("windowDestroyed", function()
        hs.timer.doAfter(0.3, function() self:buildSidebar() end)
    end)
    self._winWatcher:subscribe("windowTitleChanged", function()
        hs.timer.doAfter(0.1, function() self:buildSidebar() end)
    end)
    self._winWatcher:subscribe("windowMoved", function()
        self:handleWindowMoveOrResize()
    end)

    -- Screen watcher
    if self._screenWatcher then self._screenWatcher:stop() end
    self._screenWatcher = hs.screen.watcher.new(function()
        hs.timer.doAfter(0.3, function()
            self:buildSidebar()
            self:buildHelpMenu()
            self:tileITermWindows()
        end)
    end)
    self._screenWatcher:start()

    -- Build initial UI
    self:buildSidebar()
    self:buildHelpMenu()
    self:tileITermWindows()

    hs.alert.show("iTerm2 Axis loaded ✓", 1.5)
    return self
end

--- iTerm2Axis:stop()
--- Method
--- Stop iTerm2Axis: tear down UI and watchers.
function obj:stop()
    if self._mouseTap    then self._mouseTap:stop();    self._mouseTap    = nil end
    if self._winWatcher  then self._winWatcher:stop();  self._winWatcher  = nil end
    if self._screenWatcher then self._screenWatcher:stop(); self._screenWatcher = nil end
    if self.sidebarCanvas  then self.sidebarCanvas:delete();  self.sidebarCanvas  = nil end
    if self.helpCanvas     then self.helpCanvas:delete();     self.helpCanvas     = nil end
    return self
end

--- iTerm2Axis:init()
--- Method
--- Called automatically by hs.loadSpoon(). Sets up the Spoon but does not
--- start watchers or build UI. Call :start() (and optionally :bindHotkeys())
--- to activate.
function obj:init()
    self.windows        = {}
    self.sidebarCanvas  = nil
    self.helpCanvas     = nil
    self.isHelpVisible  = false
    self.activeWindowId = nil
    self.dragging       = false
    self.dragStart      = { x = 0, y = 0 }
    self.sidebarStart   = { x = 0, y = 0, w = 0, h = 0 }
    self.helpMenuOpen   = false
    self._currentScreen = nil
    self._buttonFrames  = {}
    self._helpButtonFrame = nil
    self._resizeDebounceTimer = nil
    self._mouseTap      = nil
    self._winWatcher    = nil
    self._screenWatcher = nil
    return self
end

return obj
