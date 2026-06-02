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

local SETTINGS_KEY_ORDER          = "iTerm2Axis.orderedWindowIds"
local SETTINGS_KEY_NAMES          = "iTerm2Axis.customNames"
local SETTINGS_KEY_NAMES_BY_PATH  = "iTerm2Axis.customNamesByPath"

obj.config = {
    debug             = false,
    sidebarWidth      = 200,
    sidebarColor      = { red = 0.12, green = 0.12, blue = 0.14, alpha = 0.95 },
    buttonColor       = { red = 0.2,  green = 0.2,  blue = 0.22, alpha = 1 },
    activeButtonColor = { red = 0.25, green = 0.4,  blue = 0.6,  alpha = 1 },
    textColor         = { red = 0.9,  green = 0.9,  blue = 0.9,  alpha = 1 },

    windowButtonHeight = 90,  -- tall enough for 5 lines (opencode + claudecode)
    padding           = 8,

    opencode = {
        enabled      = true,
        port         = 4096,
        pollInterval = 5,
    },

    claudecode = {
        enabled       = true,
        pollInterval  = 5,
        flashInterval = 2.0,
        projectsDir   = os.getenv("HOME") .. "/.claude/projects",
    },

    bell = {
        enabled       = true,
        flashInterval = 2.0,
        flashColor    = { red = 0.95, green = 0.85, blue = 0.4, alpha = 0.85 },
    },
}

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

function obj:debugTitles()
    local wins = getITermWindows()
    hs.printf("=== iTerm2Axis Debug: %d windows ===", #wins)
    for i, win in ipairs(wins) do
        local title = win:title() or ""
        local parts = parseTitleComponents(title)
        hs.printf("Window %d: title=%q", i, title)
        hs.printf("  host=%s fullPath=%s basename=%s",
            tostring(parts.host),
            tostring(parts.fullPath),
            tostring(parts.basename)
        )
        -- Check Claude Code dir
        if parts.fullPath then
            local ccDir = claudeProjectDir(parts.fullPath)
            local files = {}
            local ok, iter, dirObj = pcall(hs.fs.dir, ccDir)
            if ok then
                for _ = 1, 3 do
                    local f = iter(dirObj)
                    if not f then break end
                    table.insert(files, f)
                end
                iter(dirObj)
            end
            local display = #files > 0 and table.concat(files, ", ") or "(empty)"
            hs.printf("  claudeDir=%s => %s", ccDir, display)
        end
        -- Check opencode match
        if obj._opencodeData then
            local matched = false
            for dir, _ in pairs(obj._opencodeData) do
                if parts.fullPath == dir then matched = true end
            end
            hs.printf("  opencode match: %s", tostring(matched))
        end
    end
    hs.printf("=== opencode dirs ===")
    for dir, data in pairs(obj._opencodeData or {}) do
        hs.printf("  %s => model=%s", dir, tostring(data.modelID))
    end
end

local function isITerm(win)
    if not win then return false end
    local ok, app = pcall(function() return win:application() end)
    if not ok or not app then return false end
    local ok2, bid = pcall(function() return app:bundleID() end)
    if not ok2 or not bid then return false end
    return bid == "com.googlecode.iterm2"
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
    -- Strip iTerm2 dimension suffix e.g. " — 256✕69"
    title = title:gsub("%s+[—–-]%s+%d+✕%d+%s*$", "")
    local home = os.getenv("HOME") or ""

    local host, pathPart

    -- Try "user@host: /path" or "user@host: ~/path"
    local h, p = title:match("^[^@]+@([^:]+):%s*(~?/.+)$")
    if h and p then
        host = h
        pathPart = p
    else
        -- SSH without path: "user@host"
        local h2 = title:match("^[^@]+@([^:%s]+)%s*$")
        if h2 then
            host = h2
        else
            -- Bare path (no host prefix)
            pathPart = title:match("^(~?/[^%s].*)$") or title:match("%s(~?/[^%s]+)%s*$")
        end
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

-- Extract a GitHub PR number from a Claude Code iTerm2 title.
-- Claude Code injects "PR #NNNN" into the titlebar when working in a workspace.
-- Example titles:
--   "✦ ✦ ✦ PR #42 — user@host: ~/repo"
--   "· PR #1234 — user@host: ~/repo"
--   "🔔 PR #7 — user@host: ~/repo"
-- Returns the PR number as an integer, or nil if not found.
local function parsePRFromTitle(title)
    if not title or title == "" then return nil end
    local n = title:match("PR%s*#(%d+)")
    return n and tonumber(n) or nil
end

-- Per-window git branch cache, keyed by windowId.
-- Uses hs.task for async git lookups so buildSidebar never blocks.
local _gitBranchCache   = {}  -- [windowId] = branch string or false
local _gitBranchPending = {}  -- [windowId] = true (fetch in flight)
local _gitWsNameCache   = {}  -- [windowId] = worktree leaf name string or false

-- Per-window working directory cache, keyed by windowId.
-- Invalidated on windowTitleChanged (which fires when PWD changes with shell integration).
local _wdCache  = {}  -- [windowId] = path string or false
local _wdFlight = {}  -- [windowId] = true (fetch in flight)

local function getWindowWorkingDir(win)
    if not win then return nil end
    local winId = win:id()

    if _wdCache[winId] ~= nil then
        return _wdCache[winId] or nil
    end

    if _wdFlight[winId] then return _wdCache[winId] or nil end
    _wdFlight[winId] = true

    local script = string.format([[
        tell application "iTerm2"
            try
                tell (first window whose id is %d)
                    tell current session
                        return variable named "session.path"
                    end tell
                end tell
            on error
                return ""
            end try
        end tell
    ]], winId)

    hs.task.new("/usr/bin/osascript", function(exitCode, stdout, stderr)
        _wdFlight[winId] = nil
        local path = stdout and stdout:gsub("%s+$", "")
        _wdCache[winId] = (path and path ~= "") and path or false
        if _wdCache[winId] and obj._customNamesByPath then
            local resolvedPath = _wdCache[winId]
            if resolvedPath then
                if obj._customNamesByPath[resolvedPath]
                and not obj._customNames[winId] then
                    obj._customNames[winId] = obj._customNamesByPath[resolvedPath]
                end
                if obj._pendingPathNames and obj._pendingPathNames[winId] ~= nil then
                    local pending = obj._pendingPathNames[winId]
                    obj._customNamesByPath[resolvedPath] = pending or nil  -- false sentinel → nil (clear)
                    hs.settings.set(SETTINGS_KEY_NAMES_BY_PATH, obj._customNamesByPath)
                    obj._pendingPathNames[winId] = nil
                end
            end
        end
        if obj.sidebarCanvas and obj.sidebarCanvas:isShowing() then
            obj:buildSidebar()
        end
    end, {"-e", script}):start()

    return _wdCache[winId] or nil
end

local function getGitBranchForPath(path, winId)
    if not path or not winId then return nil end

    if _gitBranchCache[winId] ~= nil and _wdCache[winId] == path then
        return _gitBranchCache[winId] or nil
    end

    if _gitBranchPending[winId] then return _gitBranchCache[winId] or nil end
    _gitBranchPending[winId] = true

    hs.task.new("/usr/bin/git", function(_, stdout, _)
        local branch = stdout and stdout:gsub("%s+$", "")
        if not branch or branch == "" or branch == "HEAD" then
            -- Chained fallback for detached HEAD / worktree (async, non-blocking)
            hs.task.new("/bin/sh", function(_, out, _)
                _gitBranchPending[winId] = nil
                local b, ws
                if out and out ~= "" then
                    b, ws = out:match("^([^\t]+)\t?(.*)$")
                    b  = b  and b:gsub("%s+$", "")
                    ws = ws and ws:gsub("%s+$", "")
                    if ws == "" then ws = nil end
                end
                _gitBranchCache[winId] = (b and b ~= "") and b or false
                local wsLeaf = ws and ws:match("([^/]+)%s*$")
                _gitWsNameCache[winId] = (wsLeaf and wsLeaf ~= "") and wsLeaf or false
                hs.timer.doAfter(0, function()
                    if obj.sidebarCanvas and obj.sidebarCanvas:isShowing() then
                        obj:buildSidebar()
                    end
                end)
            end, {"-c", [[
                cd ']] .. path .. [[' 2>/dev/null || exit 1
                TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) || exit 1
                git worktree list --porcelain 2>/dev/null | awk -v wt="$TOPLEVEL" '
                    /^worktree / { cur=$2; next }
                    /^branch /  { if (cur==wt) { sub("^branch refs/heads/",""); print $0"\t"cur } }
                ' | head -1
            ]]}):start()
            return
        end
        _gitBranchPending[winId] = nil
        _gitBranchCache[winId] = (branch and branch ~= "") and branch or false
        _gitWsNameCache[winId] = false
        hs.timer.doAfter(0, function()
            if obj.sidebarCanvas and obj.sidebarCanvas:isShowing() then
                obj:buildSidebar()
            end
        end)
    end, {"-C", path, "rev-parse", "--abbrev-ref", "HEAD"}):start()

    return _gitBranchCache[winId] or nil
end

-- Per-window Claude Code flash state for ✳ waiting indicator.
local _sharedFlashTimer  = nil   -- single hs.timer instance
local _flashingWindows   = {}    -- { [winId] = true } set of active windows
local _flashState       = {}
local _flashNormalColor = {}
local _flashType        = {}

-- Per-window Claude Code data cache, keyed by windowId.
-- Uses hs.task for async .jsonl reads so buildSidebar never blocks.
local _ccCache   = {}  -- [winId] = { model, tokensIn, tokensOut } or false
local _ccPending = {}  -- [winId] = true (fetch in flight)
local _ccPathKey = {}  -- [winId] = fullPath last fetched (invalidation key)

local function claudeState(win)
    local title = win:title() or ""
    local stripped = title:gsub("^🔔", "")
    if stripped:match("^✳") then return "waiting" end
    if stripped:match("^·")  then return "busy"    end
    if title:match("^🔔") then return "bell" end
    return nil
end

local function startFlashing(winId, flashType)
    if _flashingWindows[winId] then return end
    flashType = flashType or "waiting"
    _flashType[winId] = flashType
    _flashState[winId] = true
    local isActive = (winId == obj.activeWindowId)
    _flashNormalColor[winId] = isActive and obj.config.activeButtonColor or obj.config.buttonColor
    _flashingWindows[winId] = true

    if not _sharedFlashTimer then
        local interval = (flashType == "bell") and obj.config.bell.flashInterval or obj.config.claudecode.flashInterval
        _sharedFlashTimer = hs.timer.new(interval, function()
            for wid in pairs(_flashingWindows) do
                _flashState[wid] = not _flashState[wid]
                local bgIdx = obj._btnBgElements[wid]
                if bgIdx and obj.sidebarCanvas and obj.sidebarCanvas:isShowing() then
                    local normalCol = _flashNormalColor[wid]
                    local flashColor = (_flashType[wid] == "bell")
                        and obj.config.bell.flashColor
                        or { red = 0.9, green = 0.6, blue = 0.4, alpha = 0.85 }
                    local newColor = _flashState[wid]
                        and flashColor
                        or (normalCol and color(normalCol) or color(obj.config.buttonColor))
                    obj.sidebarCanvas:elementAttribute(bgIdx, "fillColor", color(newColor))
                end
            end
        end)
        _sharedFlashTimer:start()
    end
end

local function stopFlashing(winId)
    _flashingWindows[winId] = nil
    _flashState[winId] = nil
    _flashType[winId] = nil
    local normalColor = _flashNormalColor[winId]
    _flashNormalColor[winId] = nil

    -- Restore button color immediately
    if normalColor and obj.sidebarCanvas and obj.sidebarCanvas:isShowing() then
        local bgIdx = obj._btnBgElements[winId]
        if bgIdx then
            obj.sidebarCanvas:elementAttribute(bgIdx, "fillColor", color(normalColor))
        end
    end

    -- Stop shared timer if no windows remain
    if not next(_flashingWindows) and _sharedFlashTimer then
        _sharedFlashTimer:stop()
        _sharedFlashTimer = nil
    end
end

-- ─────────────────────────────────────────────
-- Opencode helpers
-- ─────────────────────────────────────────────

local function shortModelName(id)
    if not id or id == "" then return nil end
    local name = id:match("[^/]+$") or id
    return name
end

local function fmtTokens(n)
    if n >= 1000000 then return string.format("%.1fM", n / 1e6) end
    if n >= 1000 then return string.format("%.1fk", n / 1e3) end
    return tostring(n)
end

-- ─────────────────────────────────────────────
-- Claude Code helpers
-- ─────────────────────────────────────────────

local function claudeEncodeDir(absPath)
    return absPath:gsub("^/", ""):gsub("/", "-")
end

local function claudeProjectDir(absPath)
    return os.getenv("HOME") .. "/.claude/projects/" .. claudeEncodeDir(absPath)
end

-- Per-window PR cache, keyed by windowId.
-- Uses hs.task for async gh pr view so buildSidebar never blocks.
local _prCache       = {}  -- [windowId] = { number, title } or false
local _prBranchCache = {}  -- [windowId] = branch string last checked
local _prPending     = {}  -- [windowId] = true (fetch in flight)

local function getOpenPRForWindow(win)
    if not win then return nil end
    local winId    = win:id()
    local fullPath = getWindowWorkingDir(win)
    local branch   = fullPath and getGitBranchForPath(fullPath, winId) or nil
    if not branch then _prCache[winId] = false; return nil end

    if _prBranchCache[winId] == branch then
        return _prCache[winId] or nil
    end

    if _prPending[winId] then
        return _prCache[winId] or nil
    end
    _prBranchCache[winId] = branch

    if not fullPath then _prCache[winId] = false; return nil end

    _prPending[winId] = true
    hs.task.new("/bin/sh", function(_, stdout, _)
        _prPending[winId] = nil
        local ok, pr = pcall(hs.json.decode, stdout or "")
        _prCache[winId] = (ok and pr and pr.number) and pr or false
        hs.timer.doAfter(0, function()
            if obj.sidebarCanvas and obj.sidebarCanvas:isShowing() then
                obj:buildSidebar()
            end
        end)
    end, {"-c", "cd '" .. fullPath .. "' && perl -e 'alarm shift; exec @ARGV' 3 gh pr view --json number,title 2>/dev/null"}):start()

    return _prCache[winId] or nil
end

function obj:_finalizeOpenCodeData(newData)
    self._opencodeData = newData
    self._opencodePending = false
    if self.sidebarCanvas and self.sidebarCanvas:isShowing() then
        self:buildSidebar()
    end
end

function obj:fetchOpenCodeData()
    if self._opencodePending then return end
    self._opencodePending = true

    -- Try HTTP API first (opencode serve)
    local curlOk = pcall(function()
        hs.task.new("/usr/bin/curl", function(_, stdout, _)
            local newData = {}
            local hadResponse = stdout and stdout ~= ""

            if hadResponse then
                local ok, sessions = pcall(hs.json.decode, stdout)
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
                end
            end

            -- If HTTP returned data (or server responded with bad data), finalize
            if next(newData) or hadResponse then
                self:_finalizeOpenCodeData(newData)
                return
            end

            -- Fall back to SQLite database (no HTTP response at all)
            local dbPath = os.getenv("HOME") .. "/.local/share/opencode/opencode.db"
            local sql = "SELECT title, directory, model, agent, tokens_input, tokens_output, time_updated FROM session ORDER BY time_updated DESC"

            local sqlOk = pcall(function()
                hs.task.new("/usr/bin/sqlite3", function(_, dbStdout, _)
                    local newData = {}

                    if dbStdout and dbStdout ~= "" then
                        local ok, sessions = pcall(hs.json.decode, dbStdout)
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

                    self:_finalizeOpenCodeData(newData)
                end, {"-json", dbPath, sql}):start()
            end)
            if not sqlOk then
                self:_finalizeOpenCodeData({})
            end
        end, {"-s", "-m", "2", "http://127.0.0.1:" .. self.config.opencode.port .. "/session"}):start()
    end)
    if not curlOk then
        self._opencodePending = false
    end
end

function obj:startOpenCodePolling()
    self:fetchOpenCodeData()
    if self._opencodePollTimer then self._opencodePollTimer:stop() end
    self._opencodePollTimer = hs.timer.new(self.config.opencode.pollInterval, function()
        self:fetchOpenCodeData()
    end)
    self._opencodePollTimer:start()
end

local function fetchClaudeCodeForWindow(win, fullPath, callback)
    local winId = win:id()

    -- Already have fresh data for this path
    if _ccPathKey[winId] == fullPath and _ccCache[winId] ~= nil then
        if callback then callback() end
        return
    end

    -- Fetch already in flight
    if _ccPending[winId] then
        if callback then callback() end
        return
    end
    _ccPending[winId] = true

    local projectDir = claudeProjectDir(fullPath)

    -- Step 1: find the latest .jsonl file (async)
    hs.task.new("/bin/sh", function(_, latestFile, _)
        latestFile = latestFile and latestFile:gsub("%s+$", "") or ""
        if latestFile == "" then
            _ccPending[winId] = nil
            _ccCache[winId]   = false
            _ccPathKey[winId] = fullPath
            if callback then callback() end
            return
        end

        -- Step 2: tail the file (async, chained)
        hs.task.new("/bin/sh", function(_, content, _)
            _ccPending[winId] = nil
            local model, tokensIn, tokensOut = nil, 0, 0
            for line in (content or ""):gmatch("[^\n]+") do
                local ok, msg = pcall(hs.json.decode, line)
                if ok and type(msg) == "table" and msg.type == "assistant" and msg.message then
                    if msg.message.model then
                        model = msg.message.model
                    end
                    if msg.message.usage then
                        local u = msg.message.usage
                        tokensIn  = tokensIn  + (u.input_tokens  or 0)
                        tokensOut = tokensOut + (u.output_tokens or 0)
                    end
                end
            end
            _ccCache[winId]   = (model or tokensIn > 0)
                and { model = model, tokensIn = tokensIn, tokensOut = tokensOut }
                or false
            _ccPathKey[winId] = fullPath
            if callback then callback() end
        end, {"-c", "tail -50 '" .. latestFile .. "' 2>/dev/null"}):start()

    end, {"-c", "ls -t '" .. projectDir .. "'/*.jsonl 2>/dev/null | head -1"}):start()
end

function obj:fetchClaudeCodeData()
    local wins = getITermWindows()
    if #wins == 0 then return end

    local pending = #wins
    if pending == 0 then return end

    local function oneDone()
        pending = pending - 1
        if pending == 0 then
            local newData = {}
            for _, win in ipairs(wins) do
                local id = win:id()
                local fp = _wdCache[id]
                if fp and _ccCache[id] then
                    newData[fp] = _ccCache[id]
                end
            end
            self._claudeCodeData = newData
            if self.sidebarCanvas and self.sidebarCanvas:isShowing() then
                self:buildSidebar()
            end
        end
    end

    for _, win in ipairs(wins) do
        -- Phase 3 fix #5: use getWindowWorkingDir to trigger async fetch if cold
        local fullPath = getWindowWorkingDir(win)
        if not fullPath then
            oneDone()
        else
            fetchClaudeCodeForWindow(win, fullPath, oneDone)
        end
    end
end

function obj:startClaudeCodePolling()
    self:fetchClaudeCodeData()
    if self._claudeCodePollTimer then self._claudeCodePollTimer:stop() end
    self._claudeCodePollTimer = hs.timer.new(self.config.claudecode.pollInterval, function()
        self:fetchClaudeCodeData()
    end)
    self._claudeCodePollTimer:start()
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

local function ocSnippet(data, fullPath)
    if not data or not fullPath or not data[fullPath] then return "" end
    local d = data[fullPath]
    return tostring(d.tokensIn or 0) .. "/" .. tostring(d.tokensOut or 0)
end

-- Phase 3 fix #3: snapshot reads _ccCache[id] directly per-window so it
-- reflects the latest async fetch rather than the batched _claudeCodeData table.
local function ccSnippet(winId)
    local d = _ccCache[winId]
    if not d then return "" end
    return tostring(d.tokensIn or 0) .. "/" .. tostring(d.tokensOut or 0)
end

local function sidebarStateSnapshot(wins, activeId, opencodeData)
    local parts = {}
    for _, win in ipairs(wins) do
        local id = win:id()
        local fullPath = _wdCache[id] or ""
        table.insert(parts, table.concat({
            tostring(id),
            win:title() or "",
            tostring(obj._customNames and obj._customNames[id] or ""),
            tostring(id == activeId),
            tostring(_flashState[id] or false),
            tostring(claudeState(win) or ""),
            tostring(fullPath),
            tostring(_gitBranchCache[id] or ""),
            tostring(_gitWsNameCache[id] or ""),
            ocSnippet(opencodeData, fullPath),
            ccSnippet(id),
        }, "\t"))
    end
    return table.concat(parts, "|")
end

local function sidebarStructureSnapshot(wins, sbW, sbH)
    return #wins .. ":" .. sbW .. "x" .. sbH
end

local function buttonStructureKey(basename, branch, prFromTitle, wsName, ocData, ccData)
    return (basename and "1" or "0")
        .. (branch    and "1" or "0")
        .. (prFromTitle and "1" or "0")
        .. (wsName    and "1" or "0")
        .. (ocData   and "1" or "0")
        .. (ccData   and "1" or "0")
end

-- Returns { text, color } for Line 3 based on workspace priority.
-- Priority: PR number → worktree name → plain branch
local function line3Display(wd)
    if wd.prFromTitle then
        return {
            text  = "⎇ PR #" .. wd.prFromTitle,
            color = { red = 0.85, green = 0.6, blue = 0.9, alpha = 0.95 },
        }
    elseif wd.wsName then
        return {
            text  = "⎇ ws:" .. wd.wsName,
            color = { red = 0.9, green = 0.75, blue = 0.4, alpha = 0.9 },
        }
    elseif wd.branch then
        return {
            text  = "⎇ " .. wd.branch,
            color = { red = 0.5, green = 0.75, blue = 0.5, alpha = 0.9 },
        }
    end
    return nil
end

function obj:buildSidebar()
    -- Phase 3 fix #4: debounce rapid back-to-back calls (e.g. multiple async
    -- callbacks firing in the same event loop tick).
    if self._buildDebounceTimer then
        self._buildDebounceTimer:stop()
        self._buildDebounceTimer = nil
    end
    self._buildDebounceTimer = hs.timer.doAfter(0.05, function()
        self._buildDebounceTimer = nil
        self:_doBuildSidebar()
    end)
end

function obj:_doBuildSidebar()
    if self._buildPending then return end
    self._buildPending = true

    local wins = getITermWindows()
    local snap = sidebarStateSnapshot(wins, self.activeWindowId, self._opencodeData)
    if snap == self._lastSidebarSnapshot then
        self._buildPending = false
        return
    end
    self._lastSidebarSnapshot = snap

    local layout = self:computeLayout()
    local sb  = layout.sidebar
    local cfg = self.config

    local structureSnap = sidebarStructureSnapshot(wins, sb.w, sb.h)
    local needsFullRebuild = (self.sidebarCanvas == nil)
                          or (structureSnap ~= self._lastStructureSnapshot)

    -- Apply ordering to wins
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

    -- ── Pass 1: gather per-window data and detect structure changes ──
    local winData = {}
    local needsAnyWindowRebuild = false
    for i, win in ipairs(itermWins) do
        local winId    = win:id()
        local isActive = (winId == self.activeWindowId)
        local state    = claudeState(win)
        local btnColor
        local focusedWin = hs.window.focusedWindow()
        local isFocused  = focusedWin and focusedWin:id() == winId
        if state == "waiting" and _flashState[winId] and not isFocused then
            btnColor = { red = 0.9, green = 0.6, blue = 0.4, alpha = 0.85 }
        elseif state == "bell" and _flashState[winId] and not isFocused then
            btnColor = cfg.bell.flashColor
        elseif state == "busy" then
            btnColor = { red = 0.3, green = 0.6, blue = 0.35, alpha = 1 }
        elseif isActive then
            btnColor = cfg.activeButtonColor
        else
            btnColor = cfg.buttonColor
        end
        local rawTitle = win:title() or ""
        local parts    = parseTitleComponents(rawTitle)
        local prFromTitle = parsePRFromTitle(rawTitle)
        if prFromTitle and prFromTitle <= 0 then prFromTitle = nil end
        local fullPath = getWindowWorkingDir(win)
        local basename = fullPath and fullPath:match("([^/]+)%s*$") or parts.basename
        local branch = fullPath and getGitBranchForPath(fullPath, winId) or nil
        local wsName = _gitWsNameCache[winId] or nil
        local label = self._customNames[winId]
            or parts.host
            or basename
            or ("Window " .. i)

        -- Hide Line 2 (PWD) when it would duplicate Line 1
        if basename and basename == label then
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
        local ccData = _ccCache[winId]
        local bKey = buttonStructureKey(basename, branch, prFromTitle, wsName, ocData, ccData)

        if self._btnStructureKeys[winId] ~= bKey then
            needsAnyWindowRebuild = true
        end

        winData[i] = {
            win         = win,
            winId       = winId,
            btnColor    = btnColor,
            label       = label,
            basename    = basename,
            branch      = branch,
            wsName      = wsName,
            prFromTitle = prFromTitle,
            ocData      = ocData,
            ccData      = ccData,
            bKey        = bKey,
        }
    end

    local ok, err = pcall(function()
        if needsFullRebuild then
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
            self._sidebarVisible = true
            self._lastStructureSnapshot = structureSnap
        elseif needsAnyWindowRebuild then
            self.sidebarCanvas:replaceElements()
        end

        if needsFullRebuild or needsAnyWindowRebuild then
            -- Background
            self.sidebarCanvas:appendElements({
                type = "rectangle",
                frame = { x = 0, y = 0, w = sb.w, h = sb.h },
                fillColor = color(cfg.sidebarColor),
                strokeWidth = 0,
            })

            -- Right border
            self.sidebarCanvas:appendElements({
                type = "rectangle",
                frame = { x = sb.w - 1, y = 0, w = 1, h = sb.h },
                fillColor = { red = 0.3, green = 0.3, blue = 0.35, alpha = 0.5 },
                strokeWidth = 0,
            })

            local textW    = sb.w - cfg.padding * 2 - 12
            local textX    = cfg.padding + 6
            local elemIdx  = 3
            local y = 6

            self._btnBgElements = {}
            self._buttonFrames  = {}

            for i, wd in ipairs(winData) do
                local winId = wd.winId

                -- Button background
                self.sidebarCanvas:appendElements({
                    type = "rectangle",
                    frame = { x = cfg.padding, y = y, w = sb.w - cfg.padding * 2, h = cfg.windowButtonHeight },
                    fillColor = color(wd.btnColor),
                    strokeWidth = 0,
                    roundedRectRadii = { xRadius = 4, yRadius = 4 },
                })
                local map = { bg = elemIdx }
                elemIdx = elemIdx + 1

                -- ── Line 1: custom rename → hostname → "Window N" fallback ──
                self.sidebarCanvas:appendElements({
                    type          = "text",
                    frame         = { x = textX, y = y + 5, w = textW, h = 15 },
                    text          = wd.label,
                    textColor     = color(cfg.textColor),
                    textSize      = 11,
                    textAlignment = "left",
                })
                map.line1 = elemIdx
                elemIdx = elemIdx + 1

                -- ── Line 2: PWD basename ──
                if wd.basename then
                    self.sidebarCanvas:appendElements({
                        type          = "text",
                        frame         = { x = textX, y = y + 22, w = textW, h = 13 },
                        text          = wd.basename,
                        textColor     = { red = 0.75, green = 0.75, blue = 0.8, alpha = 0.85 },
                        textSize      = 10,
                        textAlignment = "left",
                    })
                    map.line2 = elemIdx
                    elemIdx = elemIdx + 1
                end

                -- ── Line 3: git branch / workspace / PR ──
                local l3 = line3Display(wd)
                if l3 then
                    self.sidebarCanvas:appendElements({
                        type          = "text",
                        frame         = { x = textX, y = y + 38, w = textW, h = 13 },
                        text          = l3.text,
                        textColor     = l3.color,
                        textSize      = 10,
                        textAlignment = "left",
                    })
                    map.line3 = elemIdx
                    elemIdx = elemIdx + 1
                end

                -- ── Line 4: opencode session info ──
                if wd.ocData then
                    local modelStr = shortModelName(wd.ocData.modelID) or ""
                    local agentStr = wd.ocData.agent or ""
                    local tokStr = ""
                    if wd.ocData.tokensIn and wd.ocData.tokensIn > 0 then
                        tokStr = fmtTokens(wd.ocData.tokensIn) .. " in"
                        if wd.ocData.tokensOut and wd.ocData.tokensOut > 0 then
                            tokStr = tokStr .. " · " .. fmtTokens(wd.ocData.tokensOut) .. " out"
                        end
                    end
                    local segments = {}
                    if modelStr ~= "" then table.insert(segments, modelStr) end
                    if agentStr ~= "" then table.insert(segments, agentStr) end
                    if tokStr ~= "" then table.insert(segments, tokStr) end
                    local ocText = table.concat(segments, "  ")
                    self.sidebarCanvas:appendElements({
                        type          = "text",
                        frame         = { x = textX, y = y + 53, w = textW, h = 12 },
                        text          = ocText,
                        textColor     = { red = 0.6, green = 0.6, blue = 0.9, alpha = 0.85 },
                        textSize      = 9,
                        textAlignment = "left",
                    })
                    map.line4 = elemIdx
                    elemIdx = elemIdx + 1
                end

                -- ── Line 5: Claude Code session info (read directly from _ccCache) ──
                if wd.ccData then
                    local modelShort = shortModelName(wd.ccData.model) or ""
                    local tokStr = ""
                    if wd.ccData.tokensIn > 0 then
                        tokStr = fmtTokens(wd.ccData.tokensIn) .. "▲ " .. fmtTokens(wd.ccData.tokensOut) .. "▼"
                    end
                    local pr = wd.prFromTitle and { number = wd.prFromTitle, title = "" }
                            or (self._ghAvailable and getOpenPRForWindow(wd.win) or nil)
                    local prStr = pr and ("#" .. pr.number) or ""
                    local segments = {}
                    if modelShort ~= "" then table.insert(segments, "cc:" .. modelShort) end
                    if tokStr     ~= "" then table.insert(segments, tokStr) end
                    if prStr      ~= "" then table.insert(segments, prStr) end
                    local ccText = table.concat(segments, "  ")
                    self.sidebarCanvas:appendElements({
                        type          = "text",
                        frame         = { x = textX, y = y + 68, w = textW, h = 12 },
                        text          = ccText,
                        textColor     = { red = 0.9, green = 0.6, blue = 0.4, alpha = 0.85 },
                        textSize      = 9,
                        textAlignment = "left",
                    })
                    map.line5 = elemIdx
                    elemIdx = elemIdx + 1
                end

                self._elementMap[winId] = map
                self._btnStructureKeys[winId] = wd.bKey
                self._btnBgElements[winId] = map.bg

                if self.config.debug then
                    hs.printf("elementMap[%d]: bg=%s l1=%s l2=%s l3=%s l4=%s l5=%s",
                        winId,
                        tostring(map.bg), tostring(map.line1), tostring(map.line2),
                        tostring(map.line3), tostring(map.line4), tostring(map.line5))
                end

                self._buttonFrames[i] = {
                    x = cfg.padding, y = y,
                    w = sb.w - cfg.padding * 2, h = cfg.windowButtonHeight,
                    windowId = winId,
                }
                y = y + cfg.windowButtonHeight + 4
            end

            self._pendingSidebarFrame = nil
            if needsFullRebuild then
                self.sidebarCanvas:show()
                self._sidebarVisible = true
            end
        else
            -- ── In-place update path: elementAttribute calls only ──
            self._buttonFrames = {}
            local y = 6
            for i, wd in ipairs(winData) do
                local winId = wd.winId
                local map   = self._elementMap[winId]
                if map then
                    self.sidebarCanvas:elementAttribute(map.bg, "fillColor", color(wd.btnColor))
                    self.sidebarCanvas:elementAttribute(map.line1, "text", wd.label)
                    if map.line2 then
                        local baseText = wd.basename or ""
                        self.sidebarCanvas:elementAttribute(map.line2, "text", baseText)
                    end
                    if map.line3 then
                        local l3 = line3Display(wd)
                        self.sidebarCanvas:elementAttribute(map.line3, "text", l3 and l3.text or "")
                    end
                    if map.line4 then
                        local ocText = ""
                        if wd.ocData then
                            local modelStr = shortModelName(wd.ocData.modelID) or ""
                            local agentStr = wd.ocData.agent or ""
                            local tokStr = ""
                            if wd.ocData.tokensIn and wd.ocData.tokensIn > 0 then
                                tokStr = fmtTokens(wd.ocData.tokensIn) .. " in"
                                if wd.ocData.tokensOut and wd.ocData.tokensOut > 0 then
                                    tokStr = tokStr .. " · " .. fmtTokens(wd.ocData.tokensOut) .. " out"
                                end
                            end
                            local segments = {}
                            if modelStr ~= "" then table.insert(segments, modelStr) end
                            if agentStr ~= "" then table.insert(segments, agentStr) end
                            if tokStr ~= "" then table.insert(segments, tokStr) end
                            ocText = table.concat(segments, "  ")
                        end
                        self.sidebarCanvas:elementAttribute(map.line4, "text", ocText)
                    end
                    if map.line5 then
                        local ccText = ""
                        if wd.ccData then
                            local modelShort = shortModelName(wd.ccData.model) or ""
                            local tokStr = ""
                            if wd.ccData.tokensIn > 0 then
                                tokStr = fmtTokens(wd.ccData.tokensIn) .. "▲ " .. fmtTokens(wd.ccData.tokensOut) .. "▼"
                            end
                            local win = hs.window.get(winId)
                            local pr = wd.prFromTitle and { number = wd.prFromTitle, title = "" }
                                    or (win and self._ghAvailable and getOpenPRForWindow(win) or nil)
                            local prStr = pr and ("#" .. pr.number) or ""
                            local segments = {}
                            if modelShort ~= "" then table.insert(segments, "cc:" .. modelShort) end
                            if tokStr     ~= "" then table.insert(segments, tokStr) end
                            if prStr      ~= "" then table.insert(segments, prStr) end
                            ccText = table.concat(segments, "  ")
                        end
                        self.sidebarCanvas:elementAttribute(map.line5, "text", ccText)
                    end
                end

                self._btnStructureKeys[winId] = wd.bKey

                self._buttonFrames[i] = {
                    x = cfg.padding, y = y,
                    w = sb.w - cfg.padding * 2, h = cfg.windowButtonHeight,
                    windowId = winId,
                }
                y = y + cfg.windowButtonHeight + 4
            end
            self._pendingSidebarFrame = nil
        end
    end)

    self._buildPending = false
    self:syncCanvasLevel()

    if not ok then
        hs.printf("buildSidebar crashed: %s", tostring(err))
    end
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

function obj:refreshLayout()
    local wins = getITermWindows()
    if #wins > 0 then
        local anchorWin = hs.window.focusedWindow()
        if not (anchorWin and isITerm(anchorWin)) then
            anchorWin = wins[1]
        end
        local f  = anchorWin:frame()
        local sf = anchorWin:screen():frame()
        local sidebarW = self.config.sidebarWidth
        local sidebarX = math.max(f.x, sf.x)
        self._pendingSidebarFrame = { x = sidebarX, y = f.y, w = sidebarW, h = f.h }
        self._currentScreen = anchorWin:screen()
        self._lastStructureSnapshot = nil
    end
    self:buildSidebar()
    self:tileITermWindows()
    self:syncCanvasLevel()
end

function obj:toggleSidebar()
    if self.sidebarCanvas and self._sidebarVisible then
        self.sidebarCanvas:hide()
        self._sidebarVisible = false
    else
        self:refreshLayout()
    end
end

function obj:bringWindowToFront(windowId)
    local win = hs.window.get(windowId)
    if not win then return end
    stopFlashing(windowId)
    self.activeWindowId = windowId
    local ok = pcall(function()
        win:raise()
        win:focus()
    end)
    if not ok then return end

    hs.timer.doAfter(0.05, function()
        self:syncCanvasLevel()
    end)

    self:buildSidebar()
end

function obj:syncCanvasLevel()
    if not self.sidebarCanvas then return end
    local targetWin = nil
    local focused = hs.window.focusedWindow()
    if focused and isITerm(focused) then
        targetWin = focused
    else
        local best, bestLvl = nil, -math.huge
        for _, w in ipairs(getITermWindows()) do
            local ok, lvl = pcall(function() return w:level() end)
            if ok and lvl and lvl > bestLvl then
                best, bestLvl = w, lvl
            end
        end
        targetWin = best
    end
    if targetWin then
        self.sidebarCanvas:level(hs.canvas.windowLevels.floating)
    else
        self.sidebarCanvas:level(hs.canvas.windowLevels.normal)
    end
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
        hs.settings.set(SETTINGS_KEY_NAMES, self._customNames)
        local fullPath = _wdCache[windowId]
        if fullPath then
            self._customNamesByPath[fullPath] = input
            hs.settings.set(SETTINGS_KEY_NAMES_BY_PATH, self._customNamesByPath)
        else
            self._pendingPathNames[windowId] = input
            if win then getWindowWorkingDir(win) end
        end
        hs.timer.doAfter(0.05, function()
            self._lastSidebarSnapshot = nil
            self:buildSidebar()
        end)
    elseif button == "Rename" and (not input or input == "") then
        self._customNames[windowId] = nil
        hs.settings.set(SETTINGS_KEY_NAMES, self._customNames)
        local fullPath = _wdCache[windowId]
        if fullPath then
            self._customNamesByPath[fullPath] = nil
            hs.settings.set(SETTINGS_KEY_NAMES_BY_PATH, self._customNamesByPath)
        else
            self._pendingPathNames[windowId] = false
            if win then getWindowWorkingDir(win) end
        end
        hs.timer.doAfter(0.05, function()
            self._lastSidebarSnapshot = nil
            self:buildSidebar()
        end)
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
    local oc
    if parts.fullPath and self._opencodeData[parts.fullPath] then
        oc = self._opencodeData[parts.fullPath]
    else
        for _, d in pairs(self._opencodeData or {}) do
            if d.title and title:find(d.title, 1, true) then
                oc = d
                break
            end
        end
    end
    if oc then
        local modelStr = shortModelName(oc.modelID) or "?"
        local titleStr = oc.title or "Untitled"
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
            self:refreshLayout()
        elseif choice.text == "Show/Hide Axis" then
            self:toggleSidebar()
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
    local wins = getITermWindows()
    local liveIds = {}
    for _, win in ipairs(wins) do liveIds[win:id()] = true end
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
    hs.settings.set(SETTINGS_KEY_ORDER, self._orderedWindowIds)
    self._lastStructureSnapshot = nil
    self._lastSidebarSnapshot = nil
    self:buildSidebar()
end

function obj:moveWindowToExtent(windowId, extent)
    if not self._orderedWindowIds then self._orderedWindowIds = {} end
    local wins = getITermWindows()
    local liveIds = {}
    for _, win in ipairs(wins) do liveIds[win:id()] = true end
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
    hs.settings.set(SETTINGS_KEY_ORDER, self._orderedWindowIds)
    self._lastStructureSnapshot = nil
    self._lastSidebarSnapshot = nil
    self:buildSidebar()
end

function obj:focusNextWindow(direction)
    local wins = getITermWindows()
    if #wins < 2 then return end

    if not self._orderedWindowIds then self._orderedWindowIds = {} end
    if #self._orderedWindowIds == 0 then
        for _, win in ipairs(wins) do
            table.insert(self._orderedWindowIds, win:id())
        end
    else
        local liveIds = {}
        for _, win in ipairs(wins) do liveIds[win:id()] = true end
        local filtered = {}
        for _, id in ipairs(self._orderedWindowIds) do
            if liveIds[id] then table.insert(filtered, id) end
        end
        local filteredSet = {}
        for _, id in ipairs(filtered) do filteredSet[id] = true end
        for _, win in ipairs(wins) do
            if not filteredSet[win:id()] then
                table.insert(filtered, win:id())
            end
        end
        self._orderedWindowIds = filtered
    end

    if #self._orderedWindowIds == 0 then return end

    local currentIdx
    if self.activeWindowId then
        for i, id in ipairs(self._orderedWindowIds) do
            if id == self.activeWindowId then currentIdx = i; break end
        end
    end

    if not currentIdx then
        self:bringWindowToFront(self._orderedWindowIds[1])
        return
    end

    local newIdx = currentIdx + direction
    if newIdx < 1 then newIdx = #self._orderedWindowIds end
    if newIdx > #self._orderedWindowIds then newIdx = 1 end

    self:bringWindowToFront(self._orderedWindowIds[newIdx])
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

        local focusedWin = hs.window.focusedWindow()
        local anchorWin
        if focusedWin and isITerm(focusedWin) then
            anchorWin = focusedWin
        else
            anchorWin = wins[1]
        end

        local newScreen     = anchorWin:screen()
        local screenChanged = (newScreen ~= self._currentScreen)

        if screenChanged then
            for _, win in ipairs(wins) do
                local id = win:id()
                _wdCache[id]         = nil
                _gitBranchCache[id]  = nil
                _gitWsNameCache[id]  = nil
                _prCache[id]         = nil
                _prBranchCache[id]   = nil
            end
            self._currentScreen       = newScreen
            self._pendingSidebarFrame = nil
            if self.sidebarCanvas then
                self.sidebarCanvas:delete()
                self.sidebarCanvas = nil
            end
            self._lastStructureSnapshot = nil
            self:buildSidebar()
            self:tileITermWindows()
            return
        end

        local cfg           = self.config
        local currentAnchor = self:getSidebarAnchor()
        local expectedX     = currentAnchor.x + cfg.sidebarWidth
        local expectedY     = currentAnchor.y
        local expectedH     = currentAnchor.h

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
            local sf       = newScreen:frame()
            local sidebarW = cfg.sidebarWidth

            if f.w <= sidebarW then return end

            local anchorX  = f.x
            local sidebarX = math.max(anchorX, sf.x)
            local contentX = sidebarX + sidebarW
            local maxW     = (sf.x + sf.w) - contentX
            if maxW <= 0 then return end
            local contentW = math.min(f.w - sidebarW, maxW)

            self._pendingSidebarFrame = { x = sidebarX, y = f.y, w = sidebarW, h = f.h }
            self._currentScreen = newScreen

            local newFrame = { x = contentX, y = f.y, w = contentW, h = f.h }
            for _, w in ipairs(wins) do w:setFrame(newFrame) end

            self._lastStructureSnapshot = nil
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
---  * mapping - A table with keys: toggle, newWindow, refresh, renameWindow,
---    moveUp, moveDown, moveToTop, moveToBottom, focusUp, focusDown
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
    local focusUpMods, focusUpKey       = table.unpack(map.focusUp      or {{"alt","cmd"}, "up"})
    local focusDownMods, focusDownKey   = table.unpack(map.focusDown    or {{"alt","cmd"}, "down"})

    hs.hotkey.bind(toggleMods, toggleKey, function()
        self:toggleSidebar()
    end)

    hs.hotkey.bind(newWinMods, newWinKey, function()
        local iterm = hs.application.find("iTerm2")
        if iterm then
            iterm:activate()
            hs.eventtap.keyStroke({"cmd"}, "n")
            hs.timer.doAfter(0.5, function() self._lastStructureSnapshot = nil; self:buildSidebar(); self:tileITermWindows() end)
        else
            hs.application.open("com.googlecode.iterm2")
            hs.timer.doAfter(1.0, function() self._lastStructureSnapshot = nil; self:buildSidebar(); self:tileITermWindows() end)
        end
    end)

    hs.hotkey.bind(refreshMods, refreshKey, function()
        self:refreshLayout()
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

    hs.hotkey.bind(focusUpMods, focusUpKey, function()
        self:focusNextWindow(-1)
    end)

    hs.hotkey.bind(focusDownMods, focusDownKey, function()
        self:focusNextWindow(1)
    end)

    hs.hotkey.bind({"cmd","shift","ctrl"}, "D", function()
        local all = hs.window.allWindows()
        for _, w in ipairs(all) do
            local app = w:application()
            if app and app:bundleID() == "com.googlecode.iterm2" then
                hs.printf("iTerm win %d: title=%q isStandard=%s",
                    w:id(), w:title() or "", tostring(w:isStandard()))
            end
        end
        hs.printf("opencode dirs:")
        for dir, _ in pairs(obj._opencodeData or {}) do
            hs.printf("  %q", dir)
        end
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
        },
        function(event)
            if not self.sidebarCanvas then return false end

            local eventType = event:getType()
            local sf = self.sidebarCanvas:frame()
            local mouse = hs.mouse.absolutePosition()

            local frontApp = hs.application.frontmostApplication()
            local frontIsITerm = frontApp and frontApp:bundleID() == "com.googlecode.iterm2"
            local inSidebar = self._sidebarVisible and frontIsITerm
                and mouse.x >= sf.x and mouse.x <= sf.x + sf.w
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
        hs.timer.doAfter(0.3, function() self._lastStructureSnapshot = nil; self:buildSidebar(); self:tileITermWindows() end)
    end)
    self._winWatcher:subscribe("windowDestroyed", function(win)
        local id = win and win:id()
        if id then
            if self._windowWatchers[id] then
                self._windowWatchers[id]:stop()
                self._windowWatchers[id] = nil
            end
            _gitBranchCache[id]   = nil
            _gitBranchPending[id] = nil
            _gitWsNameCache[id]   = nil
            _prCache[id]         = nil
            _prBranchCache[id]   = nil
            _prPending[id]       = nil
            _wdCache[id]         = nil
            _wdFlight[id]        = nil
            _ccCache[id]   = nil
            _ccPending[id] = nil
            _ccPathKey[id] = nil
            stopFlashing(id)
        end
        hs.timer.doAfter(0.3, function() self._lastStructureSnapshot = nil; self:buildSidebar() end)
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
                _wdCache[id]        = nil
                _ccCache[id]        = nil
                _ccPathKey[id]      = nil
                _gitBranchCache[id] = nil
                _gitWsNameCache[id] = nil
            end
            local focusedWin = hs.window.focusedWindow()
            local isFocused  = focusedWin and focusedWin:id() == id
            local state = claudeState(win)
            if state == "waiting" and not isFocused then
                startFlashing(id)
            elseif state == "bell" and not isFocused then
                startFlashing(id, "bell")
            else
                stopFlashing(id)
            end
        end
        if not isCCStateChange or isBellStateChange then
            hs.timer.doAfter(0.1, function() self:buildSidebar() end)
        end
    end)
    self._winWatcher:subscribe("windowMoved", function()
        self:handleWindowMoveOrResize()
    end)
    self._winWatcher:subscribe("windowFocused", function(win)
        if win and isITerm(win) then
            self.activeWindowId = win:id()
            stopFlashing(win:id())
            hs.timer.doAfter(0.05, function()
                self:syncCanvasLevel()
            end)
        end
        self:handleWindowMoveOrResize()
    end)

    -- Application focus watcher: drop canvas to normal when another app
    -- takes focus so it doesn't float on top of non-iTerm windows.
    if self._appWatcher then self._appWatcher:stop() end
    self._appWatcher = hs.application.watcher.new(function(appName, event, appObj)
      if event == hs.application.watcher.deactivated then
        local bid = appObj and appObj:bundleID()
        if bid == "com.googlecode.iterm2" and self.sidebarCanvas then
          self.sidebarCanvas:level(hs.canvas.windowLevels.normal)
        end
      elseif event == hs.application.watcher.activated then
        local bid = appObj and appObj:bundleID()
        if bid == "com.googlecode.iterm2" and self.sidebarCanvas and self._sidebarVisible then
          self.sidebarCanvas:level(hs.canvas.windowLevels.floating)
        end
      end
    end)
    self._appWatcher:start()

    -- Load path-keyed names BEFORE triggering async WD fetches, so the
    -- callback in getWindowWorkingDir finds _customNamesByPath populated.
    local savedNamesByPath = hs.settings.get(SETTINGS_KEY_NAMES_BY_PATH)
    if savedNamesByPath then
        self._customNamesByPath = savedNamesByPath
    end

    for _, win in ipairs(getITermWindows()) do
        self:watchWindow(win)
        -- bootstrap WD fetch on cold start so git/cc data
        -- is available as soon as the async AppleScript returns.
        getWindowWorkingDir(win)
    end

    -- Restore persisted order
    local savedOrder = hs.settings.get(SETTINGS_KEY_ORDER)

    if savedOrder then
        local liveWins = getITermWindows()
        local liveIds  = {}
        for _, w in ipairs(liveWins) do liveIds[w:id()] = true end
        local filtered = {}
        for _, id in ipairs(savedOrder) do
            local numId = tonumber(id)
            if numId and liveIds[numId] then table.insert(filtered, numId) end
        end
        self._orderedWindowIds = filtered
    end

    -- Apply path-keyed custom names for any window whose WD resolved synchronously
    if savedNamesByPath then
        local liveWins = getITermWindows()
        for _, w in ipairs(liveWins) do
            local id = w:id()
            local path = _wdCache[id]
            if path and savedNamesByPath[path] and not self._customNames[id] then
                self._customNames[id] = savedNamesByPath[path]
            end
        end
    end

    -- Deferred re-apply of path-keyed names once async WD fetches have settled
    local function reapplyPathNames()
        if not savedNamesByPath then return end
        local liveWins = getITermWindows()
        local needsRebuild = false
        for _, w in ipairs(liveWins) do
            local id = w:id()
            local path = _wdCache[id]
            if path and savedNamesByPath[path] and not self._customNames[id] then
                self._customNames[id] = savedNamesByPath[path]
                needsRebuild = true
            end
        end
        if needsRebuild and self.sidebarCanvas and self.sidebarCanvas:isShowing() then
            self._lastSidebarSnapshot = nil
            self:buildSidebar()
        end
    end
    hs.timer.doAfter(10, reapplyPathNames)
    hs.timer.doAfter(30, reapplyPathNames)

    if self._screenWatcher then self._screenWatcher:stop() end
    self._screenWatcher = hs.screen.watcher.new(function()
        hs.timer.doAfter(0.3, function()
            self._pendingSidebarFrame = nil
            self._currentScreen = nil
            if self.sidebarCanvas then
                self.sidebarCanvas:delete()
                self.sidebarCanvas = nil
            end
            self._lastStructureSnapshot = nil
            self:buildSidebar()
            self:tileITermWindows()
        end)
    end)
    self._screenWatcher:start()

    if self._spaceWatcher then self._spaceWatcher:stop() end
    self._spaceWatcher = hs.spaces.watcher.new(function()
        hs.timer.doAfter(0.15, function()
            self:syncCanvasLevel()
            if self.sidebarCanvas and self.sidebarCanvas:isShowing() then
                self:buildSidebar()
                self:tileITermWindows()
            end
        end)
    end)
    self._spaceWatcher:start()

    if self._levelPollTimer then self._levelPollTimer:stop() end
    self._levelPollTimer = hs.timer.new(1, function()
        self:syncCanvasLevel()
    end)
    self._levelPollTimer:start()

    self:buildSidebar()
    self:tileITermWindows()

    hs.task.new("/usr/bin/which", function(exitCode, stdout, _)
        self._ghAvailable = (exitCode == 0 and stdout and stdout:gsub("%s+$", "") ~= "")
    end, {"gh"}):start()

    if self.config.opencode.enabled then
        self:startOpenCodePolling()
    end

    if self.config.claudecode.enabled then
        self:startClaudeCodePolling()
    end

    hs.alert.show("iTerm2 Axis loaded ✓", 1.5)
    return self
end

function obj:stop()
    -- Flush any pending path-name assignments before clearing caches
    for winId, pending in pairs(self._pendingPathNames or {}) do
        local path = _wdCache[winId]
        if path and pending ~= nil then
            self._customNamesByPath[path] = pending or nil
        end
    end
    if self._orderedWindowIds and next(self._orderedWindowIds) then
        hs.settings.set(SETTINGS_KEY_ORDER, self._orderedWindowIds)
    end
    if self._customNamesByPath and next(self._customNamesByPath) then
        hs.settings.set(SETTINGS_KEY_NAMES_BY_PATH, self._customNamesByPath)
    end
    if self._appWatcher    then self._appWatcher:stop();    self._appWatcher    = nil end
    if self._mouseTap      then self._mouseTap:stop();      self._mouseTap      = nil end
    if self._winWatcher    then self._winWatcher:stop();    self._winWatcher    = nil end
    if self._screenWatcher then self._screenWatcher:stop(); self._screenWatcher = nil end
    if self._spaceWatcher then self._spaceWatcher:stop(); self._spaceWatcher = nil end
    if self._levelPollTimer then self._levelPollTimer:stop(); self._levelPollTimer = nil end
    for _, w in pairs(self._windowWatchers or {}) do w:stop() end
    self._windowWatchers = {}
    if self.sidebarCanvas then self.sidebarCanvas:delete(); self.sidebarCanvas = nil end
    if self._tipCanvas    then self._tipCanvas:delete();    self._tipCanvas    = nil end
    if self._tipKey       then self._tipKey:delete();       self._tipKey       = nil end
    if self._buildDebounceTimer then self._buildDebounceTimer:stop(); self._buildDebounceTimer = nil end
     _gitBranchCache   = {}
     _gitBranchPending = {}
     _gitWsNameCache   = {}
     _prCache         = {}
     _prBranchCache   = {}
     _prPending       = {}
     _wdCache         = {}
     _wdFlight        = {}
     if _sharedFlashTimer then _sharedFlashTimer:stop(); _sharedFlashTimer = nil end
     _flashingWindows   = {}
     _flashState        = {}
     _flashNormalColor  = {}
     _flashType         = {}
     _ccCache   = {}
     _ccPending = {}
     _ccPathKey = {}
     self._opencodePending = false
     if self._opencodePollTimer then self._opencodePollTimer:stop(); self._opencodePollTimer = nil end
    if self._claudeCodePollTimer then self._claudeCodePollTimer:stop(); self._claudeCodePollTimer = nil end
     self._elementMap          = {}
     self._btnStructureKeys   = {}
     self._pendingPathNames   = {}
     self._lastSidebarSnapshot = nil
     self._lastStructureSnapshot = nil
     return self
end

function obj:init()
    self.windows        = {}
    self.sidebarCanvas  = nil
    self.activeWindowId = nil
    self._currentScreen = nil
    self._buttonFrames  = {}
    self._resizeDebounceTimer  = nil
    self._buildDebounceTimer   = nil
    self._pendingSidebarFrame  = nil
    self._mouseTap       = nil
    self._winWatcher     = nil
    self._screenWatcher  = nil
    self._spaceWatcher   = nil
    self._levelPollTimer = nil
    self._appWatcher     = nil
    self._sidebarVisible = false
    self._tipCanvas      = nil
    self._tipKey         = nil
    self._windowWatchers   = {}
    self._customNames      = {}
    self._customNamesByPath = {}
    self._pendingPathNames  = {}
    self._orderedWindowIds = {}
    self._opencodeData     = {}
    self._opencodePending  = false
    self._opencodePollTimer = nil
    self._claudeCodeData      = {}
    self._claudeCodePollTimer = nil
    self._ghAvailable         = false
    self._btnBgElements       = {}
    self._elementMap          = {}
    self._btnStructureKeys   = {}
    self._lastSidebarSnapshot = nil
    self._lastStructureSnapshot = nil
     _gitBranchCache   = {}
     _gitBranchPending = {}
     _gitWsNameCache   = {}
     _prCache          = {}
     _prBranchCache    = {}
     _prPending        = {}
     _wdCache          = {}
     _wdFlight         = {}
     _sharedFlashTimer  = nil
     _flashingWindows   = {}
     _flashState        = {}
     _flashNormalColor  = {}
     _flashType         = {}
     _ccCache   = {}
     _ccPending = {}
     _ccPathKey = {}
     return self
end

return obj
