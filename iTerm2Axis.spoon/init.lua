-- iTerm2 Axis - Hammerspoon Window Manager
-- A left-side sidebar for managing stacked iTerm2 windows

local axis = {}
axis.config = {
    sidebarWidth = 160,
    sidebarColor = { red = 0.12, green = 0.12, blue = 0.14, alpha = 0.95 },
    buttonColor = { red = 0.2, green = 0.2, blue = 0.22, alpha = 1 },
    buttonHoverColor = { red = 0.3, green = 0.3, blue = 0.35, alpha = 1 },
    activeButtonColor = { red = 0.25, green = 0.5, blue = 0.8, alpha = 1 },
    textColor = { red = 0.9, green = 0.9, blue = 0.9, alpha = 1 },
    helpMenuHeight = 200,
    moveButtonHeight = 30,
    windowButtonHeight = 36,
    padding = 8,
}

-- State
axis.windows = {}        -- { {name="main", window=hs.window, ...}, ...}
axis.sidebarCanvas = nil
axis.helpCanvas = nil
axis.isHelpVisible = false
axis.activeWindowId = nil
axis.dragging = false
axis.dragStart = { x = 0, y = 0 }
axis.sidebarStart = { x = 0, y = 0, w = 0, h = 0 }
axis.helpMenuOpen = false
axis._currentScreen = nil  -- tracked screen for sidebar

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
    table.sort(result, function(a, b)
        return a:id() < b:id()
    end)
    return result
end

local function color(c)
    return { red = c.red, green = c.green, blue = c.blue, alpha = c.alpha }
end

-- ─────────────────────────────────────────────
-- Layout
-- ─────────────────────────────────────────────

function axis.findWindowScreen(wins)
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

function axis.getScreen()
    if axis._currentScreen then
        return axis._currentScreen
    end
    local wins = getITermWindows()
    local screen = axis.findWindowScreen(wins)
    axis._currentScreen = screen
    return screen
end

function axis.computeLayout()
    local screen = axis.getScreen()
    local f = screen:frame()
    local cfg = axis.config

    -- If the sidebar has been manually repositioned, use its actual
    -- position as the anchor instead of assuming screen left edge.
    local sidebarX = f.x
    if axis.sidebarCanvas then
        local sf = axis.sidebarCanvas:frame()
        -- Only trust the sidebar position if it's on the same screen
        if math.abs(sf.y - f.y) < f.h then
            sidebarX = sf.x
        end
    end

    local sidebar = {
        x = sidebarX,
        y = f.y,
        w = cfg.sidebarWidth,
        h = f.h,
    }

    local iterm = {
        x = sidebarX + cfg.sidebarWidth,
        y = f.y,
        w = f.w - cfg.sidebarWidth - (sidebarX - f.x),
        h = f.h,
    }

    local helpH = axis.helpMenuOpen and cfg.helpMenuHeight or 0

    return {
        screen = screen,
        screenFrame = f,
        sidebar = sidebar,
        iterm = iterm,
        helpHeight = helpH,
    }
end

-- ─────────────────────────────────────────────
-- Sidebar
-- ─────────────────────────────────────────────

function axis.buildSidebar()
    if axis.sidebarCanvas then
        axis.sidebarCanvas:delete()
        axis.sidebarCanvas = nil
    end

    local layout = axis.computeLayout()
    local sb = layout.sidebar
    local cfg = axis.config

    local canvas = hs.canvas.new({
        x = sb.x, y = sb.y, w = sb.w, h = sb.h
    })
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

    axis._buttonFrames = {}

    for i, win in ipairs(itermWins) do
        local winId = win:id()
        local isActive = (winId == axis.activeWindowId)
        local btnColor = isActive and cfg.activeButtonColor or cfg.buttonColor

        -- Button background
        canvas:appendElements({
            type = "rectangle",
            frame = { x = cfg.padding, y = y, w = sb.w - cfg.padding * 2, h = cfg.windowButtonHeight },
            fillColor = color(btnColor),
            strokeWidth = 0,
            roundedRectRadii = { xRadius = 4, yRadius = 4 },
        })

        -- Button label
        local title = win:title() or ("Window " .. i)
        if #title > 18 then
            title = title:sub(1, 16) .. "…"
        end

        canvas:appendElements({
            type = "text",
            frame = { x = cfg.padding + 6, y = y + 2, w = sb.w - cfg.padding * 2 - 12, h = cfg.windowButtonHeight },
            text = title,
            textColor = color(cfg.textColor),
            textSize = 11,
            textAlignment = "left",
        })

        axis._buttonFrames[i] = {
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
        text = (axis.helpMenuOpen and "▴  Help" or "▾  Help"),
        textColor = { red = 0.7, green = 0.7, blue = 0.75, alpha = 1 },
        textSize = 11,
        textAlignment = "center",
    })

    axis._helpButtonFrame = {
        x = cfg.padding, y = y,
        w = sb.w - cfg.padding * 2, h = 28,
    }

    axis.sidebarCanvas = canvas
    canvas:show()
end

-- ─────────────────────────────────────────────
-- Help Menu
-- ─────────────────────────────────────────────

function axis.buildHelpMenu()
    if axis.helpCanvas then
        axis.helpCanvas:delete()
        axis.helpCanvas = nil
    end

    if not axis.helpMenuOpen then return end

    local layout = axis.computeLayout()
    local sb = layout.sidebar
    local cfg = axis.config

    local helpY = sb.h - layout.helpHeight

    local canvas = hs.canvas.new({
        x = sb.x, y = sb.y + helpY, w = sb.w, h = layout.helpHeight
    })
    canvas:level(hs.canvas.windowLevels.floating)
    canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

    -- Background
    canvas:appendElements({
        type = "rectangle",
        frame = { x = 0, y = 0, w = sb.w, h = layout.helpHeight },
        fillColor = { red = 0.1, green = 0.1, blue = 0.12, alpha = 0.95 },
        strokeWidth = 0,
    })

    -- Top border
    canvas:appendElements({
        type = "rectangle",
        frame = { x = 0, y = 0, w = sb.w, h = 1 },
        fillColor = { red = 0.3, green = 0.3, blue = 0.35, alpha = 0.5 },
        strokeWidth = 0,
    })

    -- Help content
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
                or { red = 0.7, green = 0.7, blue = 0.75, alpha = 1 },
            textSize = 10,
            textAlignment = "left",
        })
        y = y + 14
    end

    axis.helpCanvas = canvas
    canvas:show()
end

-- ─────────────────────────────────────────────
-- Window Management
-- ─────────────────────────────────────────────

function axis.tileITermWindows()
    local layout = axis.computeLayout()
    local itermFrame = layout.iterm

    local wins = getITermWindows()
    for _, win in ipairs(wins) do
        win:setFrame({
            x = itermFrame.x,
            y = itermFrame.y,
            w = itermFrame.w,
            h = itermFrame.h,
        })
    end
end

function axis.bringWindowToFront(windowId)
    local win = hs.window.find(windowId)
    if not win then return end

    axis.activeWindowId = windowId

    win:raise()
    win:focus()

    axis.buildSidebar()
end

function axis.moveAllWindows(dx, dy)
    local wins = getITermWindows()
    for _, win in ipairs(wins) do
        local f = win:frame()
        win:setFrame({
            x = f.x + dx,
            y = f.y + dy,
            w = f.w,
            h = f.h,
        })
    end
    if axis.sidebarCanvas then
        local sf = axis.sidebarCanvas:frame()
        axis.sidebarCanvas:setTopLeft({ x = sf.x + dx, y = sf.y + dy })
    end
    if axis.helpCanvas then
        local hf = axis.helpCanvas:frame()
        axis.helpCanvas:setTopLeft({ x = hf.x + dx, y = hf.y + dy })
    end
end

-- ─────────────────────────────────────────────
-- Mouse Handling
-- ─────────────────────────────────────────────

function axis.handleSidebarClick(x, y)
    if not axis._buttonFrames then return end

    -- Check help button
    local hb = axis._helpButtonFrame
    if hb and x >= hb.x and x <= hb.x + hb.w and y >= hb.y and y <= hb.y + hb.h then
        axis.helpMenuOpen = not axis.helpMenuOpen
        axis.buildSidebar()
        axis.buildHelpMenu()
        axis.tileITermWindows()
        return
    end

    -- Check window buttons
    for _, btn in ipairs(axis._buttonFrames) do
        if x >= btn.x and x <= btn.x + btn.w and y >= btn.y and y <= btn.y + btn.h then
            axis.bringWindowToFront(btn.windowId)
            return
        end
    end
end

-- ─────────────────────────────────────────────
-- Drag to Move
-- ─────────────────────────────────────────────

function axis.startDrag()
    local mouse = hs.mouse.absolutePosition()
    axis.dragStart = { x = mouse.x, y = mouse.y }
    axis.dragging = true
end

function axis.updateDrag()
    if not axis.dragging then return end
    local mouse = hs.mouse.absolutePosition()
    local dx = mouse.x - axis.dragStart.x
    local dy = mouse.y - axis.dragStart.y
    if dx ~= 0 or dy ~= 0 then
        axis.moveAllWindows(dx, dy)
        axis.dragStart = { x = mouse.x, y = mouse.y }
    end
end

function axis.stopDrag()
    axis.dragging = false
end

-- ─────────────────────────────────────────────
-- Hotkeys
-- ─────────────────────────────────────────────

-- Toggle axis visibility
hs.hotkey.bind({ "cmd", "shift" }, "A", function()
    if axis.sidebarCanvas then
        local isVisible = axis.sidebarCanvas:isVisible()
        if isVisible then
            axis.sidebarCanvas:hide()
            if axis.helpCanvas then axis.helpCanvas:hide() end
        else
            axis.buildSidebar()
            axis.buildHelpMenu()
            axis.tileITermWindows()
        end
    else
        axis.buildSidebar()
        axis.buildHelpMenu()
        axis.tileITermWindows()
    end
end)

-- New iTerm window
hs.hotkey.bind({ "cmd", "shift" }, "N", function()
    local iterm = hs.application.find("iTerm2")
    if iterm then
        iterm:activate()
        hs.eventtap.keyStroke({ "cmd" }, "n")
        hs.timer.doAfter(0.5, function()
            axis.buildSidebar()
            axis.tileITermWindows()
        end)
    else
        hs.application.open("com.googlecode.iterm2")
        hs.timer.doAfter(1.0, function()
            axis.buildSidebar()
            axis.tileITermWindows()
        end)
    end
end)

-- Refresh layout
hs.hotkey.bind({ "cmd", "shift" }, "R", function()
    axis.buildSidebar()
    axis.buildHelpMenu()
    axis.tileITermWindows()
end)

-- ─────────────────────────────────────────────
-- Mouse Event Tap for Sidebar
-- ─────────────────────────────────────────────

if axis._mouseTap then axis._mouseTap:stop() end

axis._mouseTap = hs.eventtap.new(
    { hs.eventtap.event.types.leftMouseDown, hs.eventtap.event.types.leftMouseDragged, hs.eventtap.event.types.leftMouseUp },
    function(event)
        local eventType = event:getType()
        local mouse = hs.mouse.absolutePosition()

        if not axis.sidebarCanvas then return false end
        local sf = axis.sidebarCanvas:frame()

        local inMoveArea = mouse.x >= sf.x and mouse.x <= sf.x + sf.w
            and mouse.y >= sf.y and mouse.y <= sf.y + axis.config.moveButtonHeight

        local inSidebar = mouse.x >= sf.x and mouse.x <= sf.x + sf.w
            and mouse.y >= sf.y and mouse.y <= sf.y + sf.h

        if eventType == hs.eventtap.event.types.leftMouseDown then
            if inMoveArea then
                axis.startDrag()
                return true
            elseif inSidebar then
                local localX = mouse.x - sf.x
                local localY = mouse.y - sf.y
                axis.handleSidebarClick(localX, localY)
                return true
            end
        elseif eventType == hs.eventtap.event.types.leftMouseDragged then
            if axis.dragging then
                axis.updateDrag()
                return true
            end
        elseif eventType == hs.eventtap.event.types.leftMouseUp then
            if axis.dragging then
                axis.stopDrag()
                return true
            end
        end

        return false
    end
)
axis._mouseTap:start()

-- ─────────────────────────────────────────────
-- Auto-refresh on window changes
-- ─────────────────────────────────────────────

if axis._winWatcher then axis._winWatcher:stop() end

axis._winWatcher = hs.window.filter.new("iTerm2")
axis._winWatcher:subscribe("windowCreated", function()
    hs.timer.doAfter(0.3, function()
        axis.buildSidebar()
        axis.tileITermWindows()
    end)
end)
axis._winWatcher:subscribe("windowDestroyed", function()
    hs.timer.doAfter(0.3, function()
        axis.buildSidebar()
    end)
end)
axis._winWatcher:subscribe("windowTitleChanged", function()
    hs.timer.doAfter(0.1, function()
        axis.buildSidebar()
    end)
end)
-- Subscribe to window moved and resized events for immediate response
axis._winWatcher:subscribe("windowMoved", function()
    axis.handleWindowMoveOrResize()
end)
axis._winWatcher:subscribe("windowResized", function()
    axis.handleWindowMoveOrResize()
end)

-- ─────────────────────────────────────────────
-- Screen change watcher
-- ─────────────────────────────────────────────

if axis._screenWatcher then axis._screenWatcher:stop() end

axis._screenWatcher = hs.screen.watcher.new(function()
    hs.timer.doAfter(0.3, function()
        axis.buildSidebar()
        axis.buildHelpMenu()
        axis.tileITermWindows()
    end)
end)
axis._screenWatcher:start()

-- Debounced handler for window move/resize events
axis._resizeDebounceTimer = nil

function axis.handleWindowMoveOrResize()
    -- Cancel any existing timer
    if axis._resizeDebounceTimer then
        axis._resizeDebounceTimer:stop()
    end
    
    -- Set a new timer to execute after a short delay
    axis._resizeDebounceTimer = hs.timer.doAfter(0.15, function()
        if axis.dragging then return end

        local wins = getITermWindows()
        if #wins == 0 then return end

        -- Detect screen change
        local winScreen = axis.findWindowScreen(wins)
        local screenChanged = (winScreen ~= axis._currentScreen)

        local layout = axis.computeLayout()
        local iterm = layout.iterm
        local cfg = axis.config

        -- Build the "expected" content frame based on where the sidebar
        -- actually is (if we have one).  After a manual move this will
        -- match the adjusted position; on a fresh layout it will match
        -- the full-screen default.
        local expected = nil
        if axis.sidebarCanvas then
            local sf = axis.sidebarCanvas:frame()
            expected = {
                x = sf.x + sf.w,
                y = sf.y,
                w = sf.w > 0 and (iterm.w) or iterm.w,
                h = sf.h,
            }
        else
            expected = iterm
        end

        if screenChanged then
            axis._currentScreen = winScreen
            axis.buildSidebar()
            axis.buildHelpMenu()
            axis.tileITermWindows()
            return
        end

        -- Find a window that has drifted from the expected content frame.
        -- Prefer the frontmost drifted window since that's the one the
        -- user most likely just moved or resized.
        local driftedWin = nil
        local function isDrifted(win)
            local f = win:frame()
            return math.abs(f.x - expected.x) > 5 or
                   math.abs(f.y - expected.y) > 5 or
                   math.abs(f.w - expected.w) > 5 or
                   math.abs(f.h - expected.h) > 5
        end
        -- Search front-to-back so the topmost drifted window wins
        for i = #wins, 1, -1 do
            if isDrifted(wins[i]) then
                driftedWin = wins[i]
                break
            end
        end

        if driftedWin then
            -- Re-read the drifted window's current frame after the move/resize
            local f = driftedWin:frame()

            -- Step 1: Redraw the sidebar along the left edge of this window
            local sidebarW = cfg.sidebarWidth
            local sidebarX = f.x

            if axis.sidebarCanvas then
                axis.sidebarCanvas:setFrame({
                    x = sidebarX,
                    y = f.y,
                    w = sidebarW,
                    h = f.h,
                })
            end
            if axis.helpCanvas then
                local helpH = axis.helpMenuOpen and cfg.helpMenuHeight or 0
                axis.helpCanvas:setFrame({
                    x = sidebarX,
                    y = f.y + f.h - helpH,
                    w = sidebarW,
                    h = helpH,
                })
            end

            -- Step 2: Slide the left edge right by sidebarWidth
            local contentX = sidebarX + sidebarW
            local contentW = f.w - sidebarW

            -- If too narrow to eat into the window, place sidebar
            -- to the left instead (same logic as before)
            if contentW < 100 then
                local screenLeft = layout.screenFrame.x
                sidebarX = f.x - sidebarW
                if sidebarX < screenLeft then
                    sidebarX = screenLeft
                end
                contentX = sidebarX + sidebarW
                contentW = f.x + f.w - contentX
                -- Reposition sidebar at the clamped location
                if axis.sidebarCanvas then
                    axis.sidebarCanvas:setFrame({
                        x = sidebarX,
                        y = f.y,
                        w = sidebarW,
                        h = f.h,
                    })
                end
                if axis.helpCanvas then
                    local helpH = axis.helpMenuOpen and cfg.helpMenuHeight or 0
                    axis.helpCanvas:setFrame({
                        x = sidebarX,
                        y = f.y + f.h - helpH,
                        w = sidebarW,
                        h = helpH,
                    })
                end
            end

            -- Step 3: Apply this adjusted frame to ALL iTerm windows
            local newFrame = {
                x = contentX,
                y = f.y,
                w = contentW,
                h = f.h,
            }
            for _, w in ipairs(wins) do
                w:setFrame(newFrame)
            end

            -- Step 4: Rebuild sidebar with updated content
            axis.buildSidebar()
            axis.buildHelpMenu()

            -- Update tracked screen
            local center = { x = contentX + contentW / 2, y = f.y + f.h / 2 }
            local newScreen = hs.screen.find(center)
            if newScreen then
                axis._currentScreen = newScreen
            end
        end
    end)
end

-- ─────────────────────────────────────────────
-- Initialize
-- ─────────────────────────────────────────────

axis.buildSidebar()
axis.buildHelpMenu()
axis.tileITermWindows()

hs.alert.show("iTerm2 Axis loaded ✓", 1.5)
