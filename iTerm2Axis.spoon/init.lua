--- iTerm2Axis - Hammerspoon Window Manager Spoon
--- A left-side sidebar for managing stacked iTerm2 windows, emulating cmux-like layout.
---
--- Download: [https://github.com/Jeshii/iterm2axis](https://github.com/Jeshii/iterm2axis)
--- @author Jesse Fuller
--- @license MIT

local obj = {}
obj.__index = obj

-- Metadata
obj.name = "iTerm2Axis"
obj.version = "0.1.0"
obj.author = "Jesse Fuller"
obj.license = "MIT - https://opensource.org/licenses/MIT"
obj.homepage = "https://github.com/Jeshii/iterm2axis"

local SETTINGS_KEY_ORDER = "iTerm2Axis.orderedWindowIds"
local ITERM_BID = "com.googlecode.iterm2"
local HAMMERSPOON_BID = "org.hammerspoon.Hammerspoon"

obj.config = {
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
local cfg = obj.config

local MOD_SYMBOLS = {
	cmd = "⌘",
	shift = "⇧",
	alt = "⌥",
	ctrl = "⌃",
}

local KEY_SYMBOLS = {
	up = "\xe2\x86\x91",
	down = "\xe2\x86\x93",
}

local function formatHotkeyLabel(mods, key)
	local result = ""
	for _, m in ipairs(mods) do
		result = result .. (MOD_SYMBOLS[m:lower()] or m)
	end
	return result .. (KEY_SYMBOLS[key:lower()] or key:upper())
end

local ACTION_LABELS = {
	toggle = "Show/Hide Sidebar",
	swapSide = "Swap Side",
	refresh = "Refresh Layout",
}

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

local function loadVersion()
	local scriptPath = hs.spoons.scriptPath()
	if scriptPath then
		local versionPath = scriptPath:gsub("init%.lua$", "VERSION")
		local f = io.open(versionPath, "r")
		if f then
			local v = f:read("*l")
			f:close()
			if v and v ~= "" then
				obj.version = v
			end
		end
	end
end
loadVersion()

local function isITerm(win)
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

local _iTermWindowsCache = nil
local _iTermWindowsCacheTime = 0
local ITERM_CACHE_TTL = 0.1

local function getITermWindows()
	local now = hs.timer.secondsSinceEpoch()
	if _iTermWindowsCache and (now - _iTermWindowsCacheTime) < ITERM_CACHE_TTL then
		return _iTermWindowsCache
	end
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
	_iTermWindowsCache = result
	_iTermWindowsCacheTime = now
	return result
end

local function color(c)
	return { red = c.red, green = c.green, blue = c.blue, alpha = c.alpha }
end

local function computeBtnHeight(numRows, dfs)
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

-- Parse iTerm2 window title into its components.
-- Handles formats:
--   "user@host: /full/path"   (shell integration with host + PWD)
--   "user@host: ~/path"       (tilde path)
--   "/full/path"              (PWD only)
--   "~/path"                  (tilde PWD only)
--   "dirname"                 (plain name, no path)
-- Returns: { host = string|nil, fullPath = string|nil, basename = string|nil }
local function parseTitleComponents(title)
	if not title or title == "" then
		return {}
	end
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
		host = host,
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
	if not title or title == "" then
		return nil
	end
	local n = title:match("PR%s*#(%d+)")
	return n and tonumber(n) or nil
end

local function rectContains(rect, x, y)
	return rect and x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h
end

-- Per-window git branch cache, keyed by windowId.
-- Uses hs.task for async git lookups so buildSidebar never blocks.
local _gitBranchCache = {} -- [windowId] = branch string or false
local _gitBranchPending = {} -- [windowId] = true (fetch in flight)
local _gitWsNameCache = {} -- [windowId] = worktree leaf name string or false

-- Per-window working directory cache, keyed by windowId.
-- Invalidated on windowTitleChanged (which fires when PWD changes with shell integration).
local _wdCache = {} -- [windowId] = path string or false
local _tabInfoCache = {} -- [windowId] = { tabCount, focusedIdx, tabName }
local _tabInfoPending = {} -- [windowId] = true (fetch in flight)
local _hostnameCache = {} -- [windowId] = hostname string or false

local function _fetchWindowInfo(win)
	if not win then
		return nil
	end
	local winId = win:id()

	if _tabInfoCache[winId] and _wdCache[winId] then
		return _tabInfoCache[winId]
	end

	if _tabInfoPending[winId] then
		return _tabInfoCache[winId] or nil
	end
	_tabInfoPending[winId] = true

	-- Match by window title instead of CGWindowID, since iTerm2's AppleScript
	-- window ID differs from Hammerspoon's CGWindowID.
	local title = (win:title() or ""):gsub("%s+[—–-]%s+%d+✕%d+%s*$", "")
	local escapedTitle = title:gsub("\\", "\\\\"):gsub('"', '\\"')

	local script = string.format(
		[[
        tell application "iTerm2"
            try
                tell (first window whose name = "%s")
                    set RS to ASCII character 30
                    set tabCount to count of tabs
                    set tabName to ""
                    set focusedIdx to 0
                    try
                        set tabName to title of current tab
                    end try
                    repeat with i from 1 to tabCount
                        if title of tab i is tabName then
                            set focusedIdx to i
                            exit repeat
                        end if
                    end repeat
                    tell current session
                        set sessionPath to variable named "session.path"
                        set sessionHost to variable named "session.hostname"
                    end tell
                    return (tabCount as text) & RS & (focusedIdx as text) & RS & tabName & RS & sessionPath & RS & sessionHost
                end tell
            on error
                return ""
            end try
        end tell
    ]],
		escapedTitle
	)

	hs.task
		.new("/usr/bin/osascript", function(exitCode, stdout, stderr)
			_tabInfoPending[winId] = nil
			local path, hostname

			if stdout and stdout ~= "" then
				local tabCount, focusedIdx, tabName, tPath, tHost =
					stdout:match("^([^\x1e]+)\x1e([^\x1e]+)\x1e([^\x1e]+)\x1e([^\x1e]*)\x1e([^\x1e]*)$")
				if tabCount then
					_tabInfoCache[winId] = {
						tabCount = tonumber(tabCount),
						focusedIdx = tonumber(focusedIdx),
						tabName = tabName,
					}
					path = tPath
					hostname = tHost
				end
			end

			if not _tabInfoCache[winId] then
				_tabInfoCache[winId] = false
			end
			_wdCache[winId] = (path and path ~= "") and path or false
			_hostnameCache[winId] = (hostname and hostname ~= "") and hostname or false

			if obj.sidebarCanvas and obj._sidebarEnabled then
				obj:buildSidebar()
			end
		end, { "-e", script })
		:start()

	return _tabInfoCache[winId] or nil
end

local function getGitBranchForPath(path, winId)
	if not path or not winId then
		return nil
	end

	if _gitBranchCache[winId] ~= nil and _wdCache[winId] == path then
		return _gitBranchCache[winId] or nil
	end

	if _gitBranchPending[winId] then
		return _gitBranchCache[winId] or nil
	end
	_gitBranchPending[winId] = true

	hs.task
		.new("/usr/bin/git", function(_, stdout, _)
			local branch = stdout and stdout:gsub("%s+$", "")
			if not branch or branch == "" or branch == "HEAD" then
				-- Chained fallback for detached HEAD / worktree (async, non-blocking)
				hs.task
					.new("/bin/sh", function(_, out, _)
						_gitBranchPending[winId] = nil
						local b, ws
						if out and out ~= "" then
							b, ws = out:match("^([^\t]+)\t?(.*)$")
							b = b and b:gsub("%s+$", "")
							ws = ws and ws:gsub("%s+$", "")
							if ws == "" then
								ws = nil
							end
						end
						_gitBranchCache[winId] = (b and b ~= "") and b or false
						local wsLeaf = ws and ws:match("([^/]+)%s*$")
						_gitWsNameCache[winId] = (wsLeaf and wsLeaf ~= "") and wsLeaf or false
						hs.timer.doAfter(0, function()
							if obj.sidebarCanvas and obj._sidebarEnabled then
								obj:buildSidebar()
							end
						end)
					end, {
						"-c",
						[[
                cd ']]
							.. path
							.. [[' 2>/dev/null || exit 1
                TOPLEVEL=$(git rev-parse --show-toplevel 2>/dev/null) || exit 1
                git worktree list --porcelain 2>/dev/null | awk -v wt="$TOPLEVEL" '
                    /^worktree / { count++; cur=$2; next }
                    /^branch /  { if (cur==wt && count > 1) { sub("^branch refs/heads/",""); print $0"\t"cur } }
                ' | head -1
            ]],
					})
					:start()
				return
			end
			_gitBranchPending[winId] = nil
			_gitBranchCache[winId] = (branch and branch ~= "") and branch or false
			_gitWsNameCache[winId] = false
			hs.timer.doAfter(0, function()
				if obj.sidebarCanvas and obj._sidebarEnabled then
					obj:buildSidebar()
				end
			end)
		end, { "-C", path, "rev-parse", "--abbrev-ref", "HEAD" })
		:start()

	return _gitBranchCache[winId] or nil
end

-- Per-window Claude Code flash state for ✳ waiting indicator.
local _sharedFlashTimer = nil -- single hs.timer instance
local _flashingWindows = {} -- { [winId] = true } set of active windows
local _flashState = {}
local _flashNormalColor = {}
local _flashType = {}

-- Cache for `claude agents --json` data, keyed by cwd.
local _claudeAgentsData = {} -- [cwd] = { status, waitingFor }

local function claudeState(win)
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

local function startFlashing(winId, flashType)
	if _flashingWindows[winId] then
		return
	end
	flashType = flashType or "waiting"
	_flashType[winId] = flashType
	_flashState[winId] = true
	local isActive = (winId == obj.activeWindowId)
	_flashNormalColor[winId] = isActive and cfg.activeButtonColor or cfg.buttonColor
	_flashingWindows[winId] = true

	if not _sharedFlashTimer then
		local interval = (flashType == "bell") and cfg.bell.flashInterval or cfg.claudecode.flashInterval
		_sharedFlashTimer = hs.timer.new(interval, function()
			for wid in pairs(_flashingWindows) do
				_flashState[wid] = not _flashState[wid]
				local bgIdx = obj._btnBgElements[wid]
				if bgIdx and obj.sidebarCanvas and obj.sidebarCanvas:isShowing() then
					local normalCol = _flashNormalColor[wid]
					local flashColor = (_flashType[wid] == "bell") and cfg.bell.flashColor or cfg.waitingFlashColor
					local newColor = _flashState[wid] and flashColor
						or (normalCol and color(normalCol) or color(cfg.buttonColor))
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
	if not id or id == "" then
		return nil
	end
	local name = id:match("[^/]+$") or id
	return name
end

local function fmtTokens(n)
	if n >= 1000000 then
		return string.format("%.1fM", n / 1e6)
	end
	if n >= 1000 then
		return string.format("%.1fk", n / 1e3)
	end
	return tostring(n)
end

-- ─────────────────────────────────────────────
-- Claude CLI agents polling
-- ─────────────────────────────────────────────

function obj:fetchClaudeAgentsData()
	if self._claudeAgentsPending then
		return
	end
	self._claudeAgentsPending = true

	hs.task
		.new("/usr/bin/env", function(_, stdout, _)
			self._claudeAgentsPending = false
			local newData = {}
			if stdout and stdout ~= "" then
				local ok, agents = pcall(hs.json.decode, stdout)
				if ok and type(agents) == "table" then
					for _, a in ipairs(agents) do
						if a.cwd then
							newData[a.cwd] = {
								status = a.status,
								waitingFor = a.waitingFor,
							}
						end
					end
				end
			end
			_claudeAgentsData = newData
			if self.sidebarCanvas and self._sidebarEnabled then
				self:buildSidebar()
			end
		end, { "claude", "agents", "--json" })
		:start()
end

function obj:startClaudeAgentsPolling()
	self:fetchClaudeAgentsData()
	if self._claudeAgentsPollTimer then
		self._claudeAgentsPollTimer:stop()
	end
	self._claudeAgentsPollTimer = hs.timer.new(self.config.claudecode.pollInterval, function()
		self:fetchClaudeAgentsData()
	end)
	self._claudeAgentsPollTimer:start()
end

-- ─────────────────────────────────────────────
-- PR helpers
-- ─────────────────────────────────────────────

-- Per-window PR cache, keyed by windowId.
-- Uses hs.task for async gh pr view so buildSidebar never blocks.
local _prCache = {} -- [windowId] = { number, title } or false
local _prBranchCache = {} -- [windowId] = branch string last checked
local _prPending = {} -- [windowId] = true (fetch in flight)

local function getOpenPRForWindow(win)
	if not win then
		return nil
	end
	local winId = win:id()
	_fetchWindowInfo(win)
	local fullPath = _wdCache[winId]
	local branch = fullPath and getGitBranchForPath(fullPath, winId) or nil
	if not branch then
		_prCache[winId] = false
		return nil
	end

	if _prBranchCache[winId] == branch then
		return _prCache[winId] or nil
	end

	if _prPending[winId] then
		return _prCache[winId] or nil
	end
	_prBranchCache[winId] = branch

	if not fullPath then
		_prCache[winId] = false
		return nil
	end

	_prPending[winId] = true
	hs.task
		.new("/bin/sh", function(_, stdout, _)
			_prPending[winId] = nil
			local ok, pr = pcall(hs.json.decode, stdout or "")
			_prCache[winId] = (ok and pr and pr.number) and pr or false
			hs.timer.doAfter(0, function()
				if obj.sidebarCanvas and obj._sidebarEnabled then
					obj:buildSidebar()
				end
			end)
		end, {
			"-c",
			"cd '" .. fullPath .. "' && perl -e 'alarm shift; exec @ARGV' 3 gh pr view --json number,title 2>/dev/null",
		})
		:start()

	return _prCache[winId] or nil
end

function obj:_finalizeOpenCodeData(newData)
	self._opencodeData = newData
	self._opencodePending = false
	if self.sidebarCanvas and self._sidebarEnabled then
		self:buildSidebar()
	end
end

function obj:fetchOpenCodeData()
	if self._opencodePending then
		return
	end
	self._opencodePending = true

	-- Try HTTP API first (opencode serve)
	local curlOk = pcall(function()
		hs.task
			.new("/usr/bin/curl", function(_, stdout, _)
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
										if ok2 and type(parsed) == "table" then
											m = parsed
										end
									end
									newData[s.directory] = {
										title = s.title,
										modelID = m.id,
										provider = m.providerID,
										agent = s.agent,
										tokensIn = s.tokens_input or 0,
										tokensOut = s.tokens_output or 0,
										updated = s.time_updated or 0,
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
				local sql =
					"SELECT title, directory, model, agent, tokens_input, tokens_output, time_updated FROM session ORDER BY time_updated DESC"

				local sqlOk = pcall(function()
					hs.task
						.new("/usr/bin/sqlite3", function(_, dbStdout, _)
							local newData = {}

							if dbStdout and dbStdout ~= "" then
								local ok, sessions = pcall(hs.json.decode, dbStdout)
								if ok and type(sessions) == "table" then
									for _, s in ipairs(sessions) do
										if s.directory and not newData[s.directory] then
											local m = {}
											if s.model then
												local ok2, parsed = pcall(hs.json.decode, s.model)
												if ok2 and type(parsed) == "table" then
													m = parsed
												end
											end
											newData[s.directory] = {
												title = s.title,
												modelID = m.id,
												provider = m.providerID,
												agent = s.agent,
												tokensIn = s.tokens_input or 0,
												tokensOut = s.tokens_output or 0,
												updated = s.time_updated or 0,
											}
										end
									end
								end
							end

							self:_finalizeOpenCodeData(newData)
						end, { "-json", dbPath, sql })
						:start()
				end)
				if not sqlOk then
					self:_finalizeOpenCodeData({})
				end
			end, { "-s", "-m", "2", "http://127.0.0.1:" .. self.config.opencode.port .. "/session" })
			:start()
	end)
	if not curlOk then
		self._opencodePending = false
	end
end

function obj:startOpenCodePolling()
	self:fetchOpenCodeData()
	if self._opencodePollTimer then
		self._opencodePollTimer:stop()
	end
	self._opencodePollTimer = hs.timer.new(self.config.opencode.pollInterval, function()
		self:fetchOpenCodeData()
	end)
	self._opencodePollTimer:start()
end

-- ─────────────────────────────────────────────
-- Layout
-- ─────────────────────────────────────────────

function obj:findWindowScreen(wins)
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

function obj:getScreen()
	if self._currentScreen then
		return self._currentScreen
	end
	local wins = getITermWindows()
	local screen = self:findWindowScreen(wins)
	self._currentScreen = screen
	return screen
end

function obj:layoutFrames(screenFrame, anchorFrame)
	local isLeft = cfg.sidebarSide ~= "right"
	local sw = cfg.sidebarWidth
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

function obj:getSidebarAnchor()
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

-- ─────────────────────────────────────────────
-- Sidebar
-- ─────────────────────────────────────────────

local function ocSnippet(data, fullPath)
	if not data or not fullPath or not data[fullPath] then
		return ""
	end
	local d = data[fullPath]
	return tostring(d.tokensIn or 0) .. "/" .. tostring(d.tokensOut or 0)
end

local function sidebarStateSnapshot(wins, activeId, opencodeData)
	local parts = {}
	for _, win in ipairs(wins) do
		local id = win:id()
		local fullPath = _wdCache[id] or ""
		local claudeAgent = fullPath and _claudeAgentsData[fullPath]
		local ti = _tabInfoCache[id]
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
				tostring(_flashState[id] or false),
				tostring(claudeState(win) or ""),
				tostring(fullPath),
				tostring(_gitBranchCache[id] or ""),
				tostring(_gitWsNameCache[id] or ""),
				ocSnippet(opencodeData, fullPath),
				tostring(claudeAgent and claudeAgent.status or ""),
				tostring(claudeAgent and claudeAgent.waitingFor or ""),
			}, "\t")
		)
	end
	return table.concat(parts, "|")
end

local function sidebarStructureSnapshot(wins, sbW, sbH)
	return #wins .. ":" .. sbW .. "x" .. sbH
end

-- Returns { text, color } for Line 3 based on workspace priority.
-- Priority: PR number → worktree name → plain branch
local function line3Display(wd)
	if wd.prFromTitle then
		return {
			text = "⎇ PR #" .. wd.prFromTitle,
			color = cfg.prColor,
		}
	elseif wd.wsName then
		return {
			text = "⎇ ws:" .. wd.wsName,
			color = { red = 0.9, green = 0.75, blue = 0.4, alpha = 0.9 },
		}
	elseif wd.branch then
		return {
			text = "⎇ " .. wd.branch,
			color = { red = 0.5, green = 0.75, blue = 0.5, alpha = 0.9 },
		}
	end
	return nil
end

local function makeTabLabel(tabInfo)
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

local function buildTextRows(wd)
	local dfs = cfg.defaultFontSize
	local rows = {}
	table.insert(rows, { text = wd.label, fs = dfs + 1, color = cfg.textColor })
	if wd.hostname and wd.hostname ~= wd.label then
		table.insert(rows, { text = wd.hostname, fs = dfs, color = DETAIL_COLOR })
	end
	if wd.basename then
		table.insert(rows, { text = wd.basename, fs = dfs, color = DETAIL_COLOR })
	end
	local l3 = line3Display(wd)
	if l3 then
		table.insert(rows, { text = l3.text, fs = dfs, color = l3.color })
	end
	if wd.ocData then
		table.insert(rows, { text = "opencode", fs = dfs - 1, color = HEADER_COLOR })
		local modelStr = shortModelName(wd.ocData.modelID)
		if modelStr then
			table.insert(rows, { text = modelStr, fs = dfs - 1, color = DETAIL_COLOR })
		end
		if wd.ocData.agent and wd.ocData.agent ~= "" then
			table.insert(rows, { text = wd.ocData.agent, fs = dfs - 1, color = DETAIL_COLOR })
		end
		if wd.ocData.tokensIn and wd.ocData.tokensIn > 0 then
			local tokStr = fmtTokens(wd.ocData.tokensIn) .. " in"
			if wd.ocData.tokensOut and wd.ocData.tokensOut > 0 then
				tokStr = tokStr .. " · " .. fmtTokens(wd.ocData.tokensOut) .. " out"
			end
			table.insert(rows, { text = tokStr, fs = dfs - 1, color = DETAIL_COLOR })
		end
	end
	if wd.claudeAgent then
		table.insert(rows, { text = "claude", fs = dfs - 1, color = HEADER_COLOR })
		if wd.claudeAgent.waitingFor then
			table.insert(
				rows,
				{ text = "⏳ " .. wd.claudeAgent.waitingFor, fs = dfs - 1, color = cfg.waitingFlashColor }
			)
		end
		if wd.claudeAgent.status and wd.claudeAgent.status ~= "waiting" then
			table.insert(rows, { text = wd.claudeAgent.status, fs = dfs - 1, color = DETAIL_COLOR })
		end
	end
	return rows
end

function obj:buildSidebar()
	-- Phase 3 fix #4: debounce rapid back-to-back calls (e.g. multiple async
	-- callbacks firing in the same event loop tick).
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

-- ─────────────────────────────────────────────
-- Sidebar helpers
-- ─────────────────────────────────────────────

function obj:_closeMenus()
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

function obj:_orderedWindows(wins)
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

function obj:_gatherWindowData(orderedWins)
	local winData = {}
	for i, win in ipairs(orderedWins) do
		local winId = win:id()
		local isActive = (winId == self.activeWindowId)
		local rawTitle = win:title() or ""
		local parts = parseTitleComponents(rawTitle)
		_fetchWindowInfo(win)
		local fullPath = _wdCache[winId]
		local claudeAgent = fullPath and _claudeAgentsData[fullPath]
		-- Prefer claude agents --json status over title heuristic.
		-- Bell state is kept from title only (not in agents data).
		local state = claudeState(win)
		if claudeAgent and claudeAgent.status and claudeAgent.status ~= "idle" then
			if claudeAgent.status == "waiting" then
				state = "waiting"
			elseif claudeAgent.status == "busy" then
				state = "busy"
			end
		end
		local btnColor
		local focusedWin = hs.window.focusedWindow()
		local isFocused = focusedWin and focusedWin:id() == winId
		local isDragHover = self._dragActive and (winId == self._lastDragHoverId)

		if isDragHover then
			btnColor = cfg.dragHighlightColor
		elseif state == "waiting" and _flashState[winId] and not isFocused then
			btnColor = cfg.waitingFlashColor
		elseif state == "bell" and _flashState[winId] and not isFocused then
			btnColor = cfg.bell.flashColor
		elseif state == "busy" then
			btnColor = cfg.busyColor
		elseif isActive then
			btnColor = cfg.activeButtonColor
		else
			btnColor = cfg.buttonColor
		end
		local prFromTitle = parsePRFromTitle(rawTitle)
		if prFromTitle and prFromTitle <= 0 then
			prFromTitle = nil
		end
		local basename = fullPath and fullPath:match("([^/]+)%s*$") or parts.basename
		local branch = fullPath and getGitBranchForPath(fullPath, winId) or nil
		local wsName = _gitWsNameCache[winId] or nil
		local hostname = _hostnameCache[winId] or parts.host
		local tabInfo = _tabInfoCache[winId]
		local tabName = tabInfo and tabInfo.tabName
		local dottedLabel = tabInfo and makeTabLabel(tabInfo)
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
			textRows = buildTextRows({
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

local function computeTextArea(textW, rows)
	local areas = {}
	local y = PAD_TOP
	for _, row in ipairs(rows) do
		local rh = row.fs + 4
		table.insert(areas, { x = 6, y = y, w = textW, h = rh })
		y = y + rh + GAP
	end
	return areas
end

function obj:_renderFullSidebar(sb, winData, structureSnap, btnH)
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
		fillColor = color(cfg.sidebarColor),
		strokeWidth = 0,
	})

	self.sidebarCanvas:appendElements({
		type = "rectangle",
		frame = { x = sb.w - 1, y = 0, w = 1, h = sb.h },
		fillColor = { red = 0.3, green = 0.3, blue = 0.35, alpha = 0.5 },
		strokeWidth = 0,
	})

	local textW = sb.w - cfg.padding * 2 - 12
	local elemIdx = 3
	local y = 6

	self._btnBgElements = {}
	self._buttonFrames = {}

	for i, wd in ipairs(winData) do
		local winId = wd.winId
		local rows = wd.textRows
		local areas = computeTextArea(textW, rows)

		self.sidebarCanvas:appendElements({
			type = "rectangle",
			frame = { x = cfg.padding, y = y, w = sb.w - cfg.padding * 2, h = btnH },
			fillColor = color(wd.btnColor),
			strokeWidth = 0,
			roundedRectRadii = { xRadius = 4, yRadius = 4 },
		})
		local bgElemIdx = elemIdx
		elemIdx = elemIdx + 1

		for ri, row in ipairs(rows) do
			local a = areas[ri]
			self.sidebarCanvas:appendElements({
				type = "text",
				frame = { x = cfg.padding + 6, y = y + a.y, w = a.w, h = a.h },
				text = row.text,
				textColor = color(row.color),
				textSize = row.fs,
				textAlignment = "left",
			})
			elemIdx = elemIdx + 1
		end

		self._btnBgElements[winId] = bgElemIdx

		self._buttonFrames[i] = {
			x = cfg.padding,
			y = y,
			w = sb.w - cfg.padding * 2,
			h = btnH,
			windowId = winId,
		}
		y = y + btnH + 4
	end

	self._pendingSidebarFrame = nil
end

function obj:_doBuildSidebar()
	if not self._sidebarVisible then
		self._buildPending = false
		return
	end
	if self._buildPending then
		return
	end
	self._buildPending = true

	self:_closeMenus()

	local wins = getITermWindows()

	if #wins == 0 then
		if self.sidebarCanvas then
			self.sidebarCanvas:hide()
			self._sidebarVisible = false
		end
		self._buildPending = false
		return
	end

	local snap = sidebarStateSnapshot(wins, self.activeWindowId, self._opencodeData)
	if snap == self._lastSidebarSnapshot then
		self._buildPending = false
		return
	end
	self._lastSidebarSnapshot = snap

	local sb = self:layoutFrames(self:getScreen():frame(), self:getSidebarAnchor()).sidebar

	local structureSnap = sidebarStructureSnapshot(wins, sb.w, sb.h)
	local needsFullRebuild = (self.sidebarCanvas == nil) or (structureSnap ~= self._lastStructureSnapshot)

	local orderedWins = self:_orderedWindows(wins)
	local winData = self:_gatherWindowData(orderedWins)
	local maxNumRows = 1
	for _, wd in ipairs(winData) do
		if #wd.textRows > maxNumRows then
			maxNumRows = #wd.textRows
		end
	end
	local btnH = computeBtnHeight(maxNumRows, cfg.defaultFontSize)

	self:_renderFullSidebar(sb, winData, structureSnap, btnH)

	self._buildPending = false
	self:syncCanvasLevel()
	if needsFullRebuild and self._sidebarEnabled then
		self.sidebarCanvas:show()
		self._sidebarVisible = true
		if not self._skipTileOnThisBuild then
			self:tileITermWindows(sb)
		end
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
end

-- ─────────────────────────────────────────────
-- Window Management
-- ─────────────────────────────────────────────

function obj:tileITermWindows(sb)
	if not self._sidebarEnabled then
		return
	end
	local screenFrame = self:getScreen():frame()
	local newFrame
	if self._sidebarVisible then
		local anchor = sb or self:getSidebarAnchor()
		newFrame = self:layoutFrames(screenFrame, anchor).content
	else
		newFrame = screenFrame
	end
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
		local f = anchorWin:frame()
		local sf = anchorWin:screen():frame()
		self._pendingSidebarFrame = self:layoutFrames(sf, f).sidebar
		self._currentScreen = anchorWin:screen()
		self._lastStructureSnapshot = nil
	end
	self._skipTileOnThisBuild = false
	self:buildSidebar()
	self:syncCanvasLevel()
end

function obj:toggleSidebar()
	if self.sidebarCanvas and self._sidebarVisible then
		local sbf = self.sidebarCanvas:frame()
		self.sidebarCanvas:hide()
		self._sidebarVisible = false
		self:tileITermWindows()
		self._toggleLock = true
		hs.timer.doAfter(0.5, function()
			self._toggleLock = false
		end)
		hs.alert.show(ACTION_LABELS.toggle .. " Completed")
	else
		local wins = getITermWindows()
		if #wins > 0 and self.sidebarCanvas then
			local sbf = self.sidebarCanvas:frame()
			self._pendingSidebarFrame = {
				x = sbf.x,
				y = sbf.y,
				w = self.config.sidebarWidth,
				h = sbf.h,
			}
			self._currentScreen = wins[1]:screen()
		end
		self._sidebarVisible = true
		self._lastStructureSnapshot = nil
		self._lastSidebarSnapshot = nil
		self:refreshLayout()
		self:syncCanvasLevel()
		hs.timer.doAfter(0.5, function()
			self._toggleLock = false
		end)
		hs.alert.show(ACTION_LABELS.toggle .. " Completed")
	end
end

function obj:toggleSide()
	self._swapInProgress = true
	self.config.sidebarSide = (self.config.sidebarSide ~= "right") and "right" or "left"
	self._pendingSidebarFrame = nil
	self._lastStructureSnapshot = nil
	self:refreshLayout()
end

function obj:bringWindowToFront(windowId)
	local win = hs.window.get(windowId)
	if not win then
		return
	end
	stopFlashing(windowId)
	self.activeWindowId = windowId

	if self.sidebarCanvas and self._btnBgElements then
		for wid, bgIdx in pairs(self._btnBgElements) do
			local c = (wid == windowId) and self.config.activeButtonColor or self.config.buttonColor
			self.sidebarCanvas:elementAttribute(bgIdx, "fillColor", color(c))
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

function obj:syncCanvasLevel()
	if not self.sidebarCanvas then
		return
	end
	if not self._sidebarEnabled then
		return
	end

	self.sidebarCanvas:level(hs.canvas.windowLevels.normal)
	-- ^ resets ordering to bottom of normal level

	local frontApp = hs.application.frontmostApplication()
	if frontApp and frontApp:bundleID() == ITERM_BID then
		self.sidebarCanvas:orderAbove(nil)
		-- ^ brings canvas to front of normal level, above iTerm windows
	end
	-- when iTerm is not frontmost, canvas stays at bottom of normal level
	-- other apps naturally go above it
end

-- ─────────────────────────────────────────────
-- Mouse Handling
-- ─────────────────────────────────────────────

local function isSidebarClickAllowed()
	local front = hs.application.frontmostApplication()
	if not front then
		return false
	end
	local bid = front:bundleID()
	return bid == ITERM_BID or bid == HAMMERSPOON_BID
end

function obj:handleSidebarClick(x, y, rightClick)
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
			stopFlashing(btn.windowId)
			if self._btnBgElements then
				for wid, bgIdx in pairs(self._btnBgElements) do
					local c = (wid == btn.windowId) and self.config.activeButtonColor or self.config.buttonColor
					self.sidebarCanvas:elementAttribute(bgIdx, "fillColor", color(c))
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

function obj:showWindowMenu(windowId)
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
				self:refreshLayout()
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

function obj:_renderPopupMenu(items)
	local ROW_H = 22
	local PAD_X = 10
	local PAD_Y = 4
	local MENU_W = 210
	local MENU_H = #items * ROW_H + PAD_Y * 2

	local mouse = hs.mouse.absolutePosition()
	local screen = hs.screen.mainScreen():frame()

	local mx = math.min(mouse.x, screen.x + screen.w - MENU_W - 4)
	local my = math.min(mouse.y, screen.y + screen.h - MENU_H - 4)

	local canvas = hs.canvas.new({ x = mx, y = my, w = MENU_W, h = MENU_H })
	canvas:level(hs.canvas.windowLevels.popUpMenu)
	canvas:behavior(hs.canvas.windowBehaviors.canJoinAllSpaces)

	canvas:appendElements({
		type = "rectangle",
		frame = { x = 0, y = 0, w = MENU_W, h = MENU_H },
		fillColor = { red = 0.15, green = 0.15, blue = 0.17, alpha = 0.97 },
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
			local pos = e:location()
			local lx = pos.x - mx
			local ly = pos.y - my
			local kind = e:getType()

			if kind == hs.eventtap.event.types.mouseMoved then
				local row = rowAtY(ly)
				if row then
					local rowY = PAD_Y + (row - 1) * ROW_H
					canvas:elementAttribute(HIGHLIGHT_IDX, "frame", { x = 3, y = rowY, w = MENU_W - 6, h = ROW_H })
					canvas:elementAttribute(
						HIGHLIGHT_IDX,
						"fillColor",
						{ red = 0.25, green = 0.4, blue = 0.6, alpha = 0.85 }
					)
				else
					canvas:elementAttribute(
						HIGHLIGHT_IDX,
						"fillColor",
						{ red = 0.25, green = 0.4, blue = 0.6, alpha = 0 }
					)
				end
				return false
			elseif kind == hs.eventtap.event.types.leftMouseDown then
				local row = rowAtY(ly)
				if row and lx >= 0 and lx <= MENU_W then
					local action = items[row].action
					closeMenu()
					action()
				else
					closeMenu()
				end
				return true
			end

			return false
		end
	)
	self._menuEventTap:start()

	self._menuKeyTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
		if e:getKeyCode() == hs.keycodes.map["escape"] then
			closeMenu()
			return true
		end
		return false
	end)
	self._menuKeyTap:start()
end

function obj:showGlobalMenu()
	self:_closeMenus()

	local items = {
		{
			label = ACTION_LABELS.refresh,
			shortcut = self._hotkeyLabels.refresh,
			action = function()
				self:refreshLayout()
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

function obj:moveWindowById(windowId, direction)
	if not self._orderedWindowIds then
		self._orderedWindowIds = {}
	end
	local wins = getITermWindows()
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
	if #self._orderedWindowIds < 2 then
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

function obj:moveWindowToExtent(windowId, extent)
	if not self._orderedWindowIds then
		self._orderedWindowIds = {}
	end
	local wins = getITermWindows()
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
	if #self._orderedWindowIds < 2 then
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

function obj:focusNextWindow(direction)
	local wins = getITermWindows()
	if #wins < 2 then
		return
	end

	if not self._orderedWindowIds then
		self._orderedWindowIds = {}
	end
	if #self._orderedWindowIds == 0 then
		for _, win in ipairs(wins) do
			table.insert(self._orderedWindowIds, win:id())
		end
	else
		local liveIds = {}
		for _, win in ipairs(wins) do
			liveIds[win:id()] = true
		end
		local filtered = {}
		for _, id in ipairs(self._orderedWindowIds) do
			if liveIds[id] then
				table.insert(filtered, id)
			end
		end
		local filteredSet = {}
		for _, id in ipairs(filtered) do
			filteredSet[id] = true
		end
		for _, win in ipairs(wins) do
			if not filteredSet[win:id()] then
				table.insert(filtered, win:id())
			end
		end
		self._orderedWindowIds = filtered
	end

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

-- ─────────────────────────────────────────────
-- Per-Window UIElement Watcher (for resize events)
-- ─────────────────────────────────────────────

function obj:watchWindow(win)
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

-- ─────────────────────────────────────────────
-- Window Move/Resize Handler (debounced)
-- ─────────────────────────────────────────────

function obj:handleWindowMoveOrResize()
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

		local wins = getITermWindows()
		if #wins == 0 then
			return
		end

		local focusedWin = hs.window.focusedWindow()
		local anchorWin
		if focusedWin and isITerm(focusedWin) then
			anchorWin = focusedWin
		else
			anchorWin = wins[1]
		end

		local newScreen = anchorWin:screen()
		local screenChanged = (newScreen ~= self._currentScreen)

		if screenChanged then
			for _, win in ipairs(wins) do
				local id = win:id()
				_wdCache[id] = nil
				_tabInfoCache[id] = nil
				_tabInfoPending[id] = nil
				_hostnameCache[id] = nil
				_gitBranchCache[id] = nil
				_gitWsNameCache[id] = nil
				_prCache[id] = nil
				_prBranchCache[id] = nil
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
			expectedEdge = currentAnchor.x -- sidebar left edge
			edgeFn = function(f)
				return f.x + f.w
			end -- window right edge
		else
			expectedEdge = currentAnchor.x + cfg.sidebarWidth -- sidebar right edge
			edgeFn = function(f)
				return f.x
			end -- window left edge
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
			local sidebarW = cfg.sidebarWidth

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
			for _, w in ipairs(wins) do
				w:setFrame(newFrame)
			end

			self._skipTileOnThisBuild = true
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
---  * mapping - A table with keys: toggle, newWindow, refresh,
---    moveUp, moveDown, moveToTop, moveToBottom, focusUp, focusDown
---    Each value is a table: { modifiers, key }
function obj:bindHotkeys(mapping)
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

	self._hotkeyLabels.toggle = formatHotkeyLabel(toggleMods, toggleKey)
	self._hotkeyLabels.refresh = formatHotkeyLabel(refreshMods, refreshKey)
	self._hotkeyLabels.moveUp = formatHotkeyLabel(moveUpMods, moveUpKey)
	self._hotkeyLabels.moveDown = formatHotkeyLabel(moveDownMods, moveDownKey)
	self._hotkeyLabels.moveToTop = formatHotkeyLabel(moveTopMods, moveTopKey)
	self._hotkeyLabels.moveToBottom = formatHotkeyLabel(moveBottomMods, moveBottomKey)
	self._hotkeyLabels.swapSide = formatHotkeyLabel(swapSideMods, swapSideKey)

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
		self:refreshLayout()
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
end

-- ─────────────────────────────────────────────
-- Spoon API: start / stop
-- ─────────────────────────────────────────────

function obj:_setupSidebarClickTap()
	if self._clickTap then
		self._clickTap:stop()
	end
	self._clickTap = hs.eventtap.new({
		hs.eventtap.event.types.leftMouseDown,
		hs.eventtap.event.types.rightMouseDown,
	}, function(e)
		if not self._sidebarVisible then
			return false
		end
		local sf = self.sidebarCanvas and self.sidebarCanvas:frame()
		if not sf then
			return false
		end
		local mouse = e:location()
		if rectContains(sf, mouse.x, mouse.y) then
			if not isSidebarClickAllowed() then
				return false
			end
			local isRight = e:getType() == hs.eventtap.event.types.rightMouseDown
			self:handleSidebarClick(mouse.x - sf.x, mouse.y - sf.y, isRight)
			return false
		end
		return false
	end)
	self._clickTap:start()
end

function obj:_rebuildSidebar()
	if self.sidebarCanvas and self._sidebarVisible then
		self._lastSidebarSnapshot = nil
		self:buildSidebar()
	end
end

function obj:_setupDragTap()
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

		if rectContains(sf, mouse.x, mouse.y) then
			if not isSidebarClickAllowed() then
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

-- ─────────────────────────────────────────────
-- Watcher Setup (extracted from start())
-- ─────────────────────────────────────────────

function obj:_rebuildAfterSettle(tileWhenHidden)
	hs.timer.doAfter(self.config.settleDelay, function()
		self._lastStructureSnapshot = nil
		self:buildSidebar()
		if tileWhenHidden and not self._sidebarVisible then
			self:tileITermWindows()
		end
	end)
end

function obj:_setupWindowWatcher()
	self._winWatcher:subscribe("windowCreated", function(win)
		if win then
			self:watchWindow(win)
		end
		_iTermWindowsCache = nil
		self:_rebuildAfterSettle(true)
	end)
	self._winWatcher:subscribe("windowDestroyed", function(win)
		local id = win and win:id()
		if id then
			if self._windowWatchers[id] then
				self._windowWatchers[id]:stop()
				self._windowWatchers[id] = nil
			end
			_gitBranchCache[id] = nil
			_gitBranchPending[id] = nil
			_gitWsNameCache[id] = nil
			_prCache[id] = nil
			_prBranchCache[id] = nil
			_prPending[id] = nil
			_wdCache[id] = nil
			_tabInfoCache[id] = nil
			_tabInfoPending[id] = nil
			_hostnameCache[id] = nil
			stopFlashing(id)
		end
		_iTermWindowsCache = nil
		self:_rebuildAfterSettle(true)
	end)
	self._winWatcher:subscribe("windowMinimized", function()
		_iTermWindowsCache = nil
		self:_rebuildAfterSettle()
	end)
	self._winWatcher:subscribe("windowUnminimized", function(win)
		if win then
			self:watchWindow(win)
		end
		_iTermWindowsCache = nil
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
				_wdCache[id] = nil
				_tabInfoCache[id] = nil
				_tabInfoPending[id] = nil
				_hostnameCache[id] = nil
				_gitBranchCache[id] = nil
				_gitWsNameCache[id] = nil
			end
			local focusedWin = hs.window.focusedWindow()
			local isFocused = focusedWin and focusedWin:id() == id
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
			hs.timer.doAfter(self.config.settleDelay, function()
				self:buildSidebar()
			end)
		end
	end)
	self._winWatcher:subscribe("windowMoved", function()
		self:handleWindowMoveOrResize()
	end)
	self._winWatcher:subscribe("windowFocused", function(win)
		if win and isITerm(win) then
			local winId = win:id()
			self.activeWindowId = winId
			stopFlashing(winId)
			if self.sidebarCanvas and self._btnBgElements then
				for wid, bgIdx in pairs(self._btnBgElements) do
					local c = (wid == winId) and self.config.activeButtonColor or self.config.buttonColor
					self.sidebarCanvas:elementAttribute(bgIdx, "fillColor", color(c))
				end
			end
			-- Refresh tab info on focus to catch tab switches that don't fire titleChanged
			_tabInfoCache[winId] = nil
			_tabInfoPending[winId] = nil
			_hostnameCache[winId] = nil
			_fetchWindowInfo(win)
			hs.timer.doAfter(0.05, function()
				self:syncCanvasLevel()
			end)
		end
	end)
end

function obj:_restartWindowWatcher()
	if self._winWatcher then
		self._winWatcher:stop()
	end
	self._winWatcher = hs.window.filter.new("iTerm2")
	self:_setupWindowWatcher()
end

function obj:_setupAppWatcher()
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

function obj:_restorePersistedState()
	for _, win in ipairs(getITermWindows()) do
		self:watchWindow(win)
		_fetchWindowInfo(win)
	end

	local savedOrder = hs.settings.get(SETTINGS_KEY_ORDER)

	if savedOrder then
		local liveWins = getITermWindows()
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

function obj:_setupScreenWatcher()
	if self._screenWatcher then
		self._screenWatcher:stop()
	end
	self._screenWatcher = hs.screen.watcher.new(function()
		hs.timer.doAfter(self.config.settleDelay, function()
			self._pendingSidebarFrame = nil
			self._currentScreen = nil
			if self.sidebarCanvas then
				self.sidebarCanvas:delete()
				self.sidebarCanvas = nil
			end
			self._lastStructureSnapshot = nil
			self._sidebarVisible = true
			self:buildSidebar()
		end)
	end)
	self._screenWatcher:start()
end

function obj:_setupSpaceWatcher()
	if self._spaceWatcher then
		self._spaceWatcher:stop()
	end
	self._spaceWatcher = hs.spaces.watcher.new(function()
		hs.timer.doAfter(self.config.settleDelay, function()
			self:syncCanvasLevel()
			if self.sidebarCanvas and self._sidebarEnabled then
				self:buildSidebar()
			end
		end)
	end)
	self._spaceWatcher:start()
end

function obj:start()
	self:_setupSidebarClickTap()
	self:_setupDragTap()
	self:_restartWindowWatcher()
	self:_setupAppWatcher()
	self:_restorePersistedState()
	self:_setupScreenWatcher()
	self:_setupSpaceWatcher()

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

function obj:stop()
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
	_iTermWindowsCache = nil
	_iTermWindowsCacheTime = 0
	_gitBranchCache = {}
	_gitBranchPending = {}
	_gitWsNameCache = {}
	_prCache = {}
	_prBranchCache = {}
	_prPending = {}
	_wdCache = {}
	_tabInfoCache = {}
	_tabInfoPending = {}
	_hostnameCache = {}
	if _sharedFlashTimer then
		_sharedFlashTimer:stop()
		_sharedFlashTimer = nil
	end
	_flashingWindows = {}
	_flashState = {}
	_flashNormalColor = {}
	_flashType = {}
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
	_claudeAgentsData = {}
	self._lastSidebarSnapshot = nil
	self._lastStructureSnapshot = nil
	return self
end

function obj:init()
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
	_iTermWindowsCache = nil
	_iTermWindowsCacheTime = 0
	_gitBranchCache = {}
	_gitBranchPending = {}
	_gitWsNameCache = {}
	_prCache = {}
	_prBranchCache = {}
	_prPending = {}
	_wdCache = {}
	_tabInfoCache = {}
	_tabInfoPending = {}
	_hostnameCache = {}
	_sharedFlashTimer = nil
	_flashingWindows = {}
	_flashState = {}
	_flashNormalColor = {}
	_flashType = {}
	self._dragWatchTap = nil
	self._dragActive = false
	self._lastDragHoverId = nil
	return self
end

return obj
