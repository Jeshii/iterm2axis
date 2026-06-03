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
local SETTINGS_KEY_NAMES_BY_PATH = "iTerm2Axis.customNamesByPath"

obj.config = {
	debug = false,
	sidebarWidth = 200,
	sidebarSide = "left",
	startHidden = false,
	sidebarColor = { red = 0.12, green = 0.12, blue = 0.14, alpha = 0.95 },
	buttonColor = { red = 0.2, green = 0.2, blue = 0.22, alpha = 1 },
	activeButtonColor = { red = 0.25, green = 0.4, blue = 0.6, alpha = 1 },
	textColor = { red = 0.9, green = 0.9, blue = 0.9, alpha = 1 },
	dragHighlightColor = { red = 0.3, green = 0.7, blue = 0.4, alpha = 0.9 },

	windowButtonHeight = 90, -- tall enough for 5 lines (opencode + claudecode)
	padding = 8,

	opencode = {
		enabled = true,
		port = 4096,
		pollInterval = 5,
	},

	claudecode = {
		enabled = true,
		pollInterval = 5,
		flashInterval = 2.0,
		projectsDir = os.getenv("HOME") .. "/.claude/projects",
	},

	bell = {
		enabled = true,
		flashInterval = 2.0,
		flashColor = { red = 0.95, green = 0.85, blue = 0.4, alpha = 0.85 },
	},
}

-- ─────────────────────────────────────────────
-- Helpers
-- ─────────────────────────────────────────────

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
	return bid == "com.googlecode.iterm2"
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

local BAR_H = 18
local BAR_BOTTOM_MARGIN = 6
local MAX_RENAME_LEN = 40

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
local _wdFlight = {} -- [windowId] = true (fetch in flight)

local function getWindowWorkingDir(win)
	if not win then
		return nil
	end
	local winId = win:id()

	if _wdCache[winId] ~= nil then
		return _wdCache[winId] or nil
	end

	if _wdFlight[winId] then
		return _wdCache[winId] or nil
	end
	_wdFlight[winId] = true

	local script = string.format(
		[[
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
    ]],
		winId
	)

	hs.task
		.new("/usr/bin/osascript", function(exitCode, stdout, stderr)
			_wdFlight[winId] = nil
			local path = stdout and stdout:gsub("%s+$", "")
			_wdCache[winId] = (path and path ~= "") and path or false
			if _wdCache[winId] and obj._customNamesByPath then
				local resolvedPath = _wdCache[winId]
				if resolvedPath then
					if obj._customNamesByPath[resolvedPath] and not obj._customNames[winId] then
						obj._customNames[winId] = obj._customNamesByPath[resolvedPath]
					end
					if obj._pendingPathNames and obj._pendingPathNames[winId] ~= nil then
						local pending = obj._pendingPathNames[winId]
						obj._customNamesByPath[resolvedPath] = pending or nil -- false sentinel → nil (clear)
						hs.settings.set(SETTINGS_KEY_NAMES_BY_PATH, obj._customNamesByPath)
						obj._pendingPathNames[winId] = nil
					end
				end
			end
			if obj.sidebarCanvas and obj._sidebarEnabled then
				obj:buildSidebar()
			end
		end, { "-e", script })
		:start()

	return _wdCache[winId] or nil
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

-- Per-window Claude Code data cache, keyed by windowId.
-- Uses hs.task for async .jsonl reads so buildSidebar never blocks.
local _ccCache = {} -- [winId] = { model, tokensIn, tokensOut } or false
local _ccPending = {} -- [winId] = true (fetch in flight)
local _ccPathKey = {} -- [winId] = fullPath last fetched (invalidation key)

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
					local flashColor = (_flashType[wid] == "bell") and obj.config.bell.flashColor
						or { red = 0.9, green = 0.6, blue = 0.4, alpha = 0.85 }
					local newColor = _flashState[wid] and flashColor
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
local _prCache = {} -- [windowId] = { number, title } or false
local _prBranchCache = {} -- [windowId] = branch string last checked
local _prPending = {} -- [windowId] = true (fetch in flight)

local function getOpenPRForWindow(win)
	if not win then
		return nil
	end
	local winId = win:id()
	local fullPath = getWindowWorkingDir(win)
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

local function fetchClaudeCodeForWindow(win, fullPath, callback)
	local winId = win:id()

	-- Already have fresh data for this path
	if _ccPathKey[winId] == fullPath and _ccCache[winId] ~= nil then
		if callback then
			callback()
		end
		return
	end

	-- Fetch already in flight
	if _ccPending[winId] then
		if callback then
			callback()
		end
		return
	end
	_ccPending[winId] = true

	local projectDir = claudeProjectDir(fullPath)

	-- Step 1: find the latest .jsonl file (async)
	hs.task
		.new("/bin/sh", function(_, latestFile, _)
			latestFile = latestFile and latestFile:gsub("%s+$", "") or ""
			if latestFile == "" then
				_ccPending[winId] = nil
				_ccCache[winId] = false
				_ccPathKey[winId] = fullPath
				if callback then
					callback()
				end
				return
			end

			-- Step 2: tail the file (async, chained)
			hs.task
				.new("/bin/sh", function(_, content, _)
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
								tokensIn = tokensIn + (u.input_tokens or 0)
								tokensOut = tokensOut + (u.output_tokens or 0)
							end
						end
					end
					_ccCache[winId] = (model or tokensIn > 0)
							and { model = model, tokensIn = tokensIn, tokensOut = tokensOut }
						or false
					_ccPathKey[winId] = fullPath
					if callback then
						callback()
					end
				end, { "-c", "tail -50 '" .. latestFile .. "' 2>/dev/null" })
				:start()
		end, { "-c", "ls -t '" .. projectDir .. "'/*.jsonl 2>/dev/null | head -1" })
		:start()
end

function obj:fetchClaudeCodeData()
	local wins = getITermWindows()
	if #wins == 0 then
		return
	end

	local pending = #wins
	if pending == 0 then
		return
	end

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
			if self.sidebarCanvas and self._sidebarEnabled then
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
	if self._claudeCodePollTimer then
		self._claudeCodePollTimer:stop()
	end
	self._claudeCodePollTimer = hs.timer.new(self.config.claudecode.pollInterval, function()
		self:fetchClaudeCodeData()
	end)
	self._claudeCodePollTimer:start()
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
	local cfg = self.config
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

-- Phase 3 fix #3: snapshot reads _ccCache[id] directly per-window so it
-- reflects the latest async fetch rather than the batched _claudeCodeData table.
local function ccSnippet(winId)
	local d = _ccCache[winId]
	if not d then
		return ""
	end
	return tostring(d.tokensIn or 0) .. "/" .. tostring(d.tokensOut or 0)
end

local function sidebarStateSnapshot(wins, activeId, opencodeData)
	local parts = {}
	for _, win in ipairs(wins) do
		local id = win:id()
		local fullPath = _wdCache[id] or ""
		table.insert(
			parts,
			table.concat({
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
			}, "\t")
		)
	end
	return table.concat(parts, "|")
end

local function sidebarStructureSnapshot(wins, sbW, sbH)
	return #wins .. ":" .. sbW .. "x" .. sbH
end

local function buttonStructureKey(basename, branch, prFromTitle, wsName, ocData, ccData)
	return (basename and "1" or "0")
		.. (branch and "1" or "0")
		.. (prFromTitle and "1" or "0")
		.. (wsName and "1" or "0")
		.. (ocData and "1" or "0")
		.. (ccData and "1" or "0")
end

-- Returns { text, color } for Line 3 based on workspace priority.
-- Priority: PR number → worktree name → plain branch
local function line3Display(wd)
	if wd.prFromTitle then
		return {
			text = "⎇ PR #" .. wd.prFromTitle,
			color = { red = 0.85, green = 0.6, blue = 0.9, alpha = 0.95 },
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

function obj:_doBuildSidebar()
	if not self._sidebarVisible then
		self._buildPending = false
		return
	end
	if self._buildPending then
		return
	end
	self._buildPending = true

	-- Close any open context menu before rebuilding canvas
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
	local cfg = self.config

	local structureSnap = sidebarStructureSnapshot(wins, sb.w, sb.h)
	local needsFullRebuild = (self.sidebarCanvas == nil) or (structureSnap ~= self._lastStructureSnapshot)

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
		local winId = win:id()
		local isActive = (winId == self.activeWindowId)
		local state = claudeState(win)
		local btnColor
		local focusedWin = hs.window.focusedWindow()
		local isFocused = focusedWin and focusedWin:id() == winId
		local isDragHover = self._dragActive and (winId == self._lastDragHoverId)

		if isDragHover then
			btnColor = cfg.dragHighlightColor
		elseif state == "waiting" and _flashState[winId] and not isFocused then
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
		local parts = parseTitleComponents(rawTitle)
		local prFromTitle = parsePRFromTitle(rawTitle)
		if prFromTitle and prFromTitle <= 0 then
			prFromTitle = nil
		end -- 0 is truthy in Lua, guard explicit
		local fullPath = getWindowWorkingDir(win)
		local basename = fullPath and fullPath:match("([^/]+)%s*$") or parts.basename
		local branch = fullPath and getGitBranchForPath(fullPath, winId) or nil
		local wsName = _gitWsNameCache[winId] or nil
		local label = self._customNames[winId] or parts.host or basename or ("Window " .. i)

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
			win = win,
			winId = winId,
			btnColor = btnColor,
			label = label,
			basename = basename,
			branch = branch,
			wsName = wsName,
			prFromTitle = prFromTitle,
			ocData = ocData,
			ccData = ccData,
			bKey = bKey,
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
			self.sidebarCanvas:clickActivating(false)
			local function noop() end
			self.sidebarCanvas:mouseCallback(noop)
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

			local textW = sb.w - cfg.padding * 2 - 12
			local textX = cfg.padding + 6
			local elemIdx = 3
			local y = 6

			self._btnBgElements = {}
			self._buttonFrames = {}

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
					type = "text",
					frame = { x = textX, y = y + 5, w = textW, h = 15 },
					text = wd.label,
					textColor = color(cfg.textColor),
					textSize = 11,
					textAlignment = "left",
				})
				map.line1 = elemIdx
				elemIdx = elemIdx + 1

				-- ── Line 2: PWD basename ──
				if wd.basename then
					self.sidebarCanvas:appendElements({
						type = "text",
						frame = { x = textX, y = y + 22, w = textW, h = 13 },
						text = wd.basename,
						textColor = { red = 0.75, green = 0.75, blue = 0.8, alpha = 0.85 },
						textSize = 10,
						textAlignment = "left",
					})
					map.line2 = elemIdx
					elemIdx = elemIdx + 1
				end

				-- ── Line 3: git branch / workspace / PR ──
				local l3 = line3Display(wd)
				if l3 then
					self.sidebarCanvas:appendElements({
						type = "text",
						frame = { x = textX, y = y + 38, w = textW, h = 13 },
						text = l3.text,
						textColor = l3.color,
						textSize = 10,
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
					if modelStr ~= "" then
						table.insert(segments, modelStr)
					end
					if agentStr ~= "" then
						table.insert(segments, agentStr)
					end
					if tokStr ~= "" then
						table.insert(segments, tokStr)
					end
					local ocText = table.concat(segments, "  ")
					self.sidebarCanvas:appendElements({
						type = "text",
						frame = { x = textX, y = y + 53, w = textW, h = 12 },
						text = ocText,
						textColor = { red = 0.6, green = 0.6, blue = 0.9, alpha = 0.85 },
						textSize = 9,
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
					if modelShort ~= "" then
						table.insert(segments, "cc:" .. modelShort)
					end
					if tokStr ~= "" then
						table.insert(segments, tokStr)
					end
					if prStr ~= "" then
						table.insert(segments, prStr)
					end
					local ccText = table.concat(segments, "  ")
					self.sidebarCanvas:appendElements({
						type = "text",
						frame = { x = textX, y = y + 68, w = textW, h = 12 },
						text = ccText,
						textColor = { red = 0.9, green = 0.6, blue = 0.4, alpha = 0.85 },
						textSize = 9,
						textAlignment = "left",
					})
					map.line5 = elemIdx
					elemIdx = elemIdx + 1
				end

				self._elementMap[winId] = map
				self._btnStructureKeys[winId] = wd.bKey
				self._btnBgElements[winId] = map.bg

				if self.config.debug then
					hs.printf(
						"elementMap[%d]: bg=%s l1=%s l2=%s l3=%s l4=%s l5=%s",
						winId,
						tostring(map.bg),
						tostring(map.line1),
						tostring(map.line2),
						tostring(map.line3),
						tostring(map.line4),
						tostring(map.line5)
					)
				end

				self._buttonFrames[i] = {
					x = cfg.padding,
					y = y,
					w = sb.w - cfg.padding * 2,
					h = cfg.windowButtonHeight,
					windowId = winId,
				}
				y = y + cfg.windowButtonHeight + 4
			end

			-- Append rename bar elements (hidden by default)
			local barY = sb.h - BAR_H - BAR_BOTTOM_MARGIN
			self.sidebarCanvas:appendElements({
				type = "rectangle",
				fillColor = { red = 0.1, green = 0.1, blue = 0.18, alpha = 0 },
				frame = { x = 0, y = barY, w = sb.w, h = BAR_H },
			})
			self._renameBarIdx = self.sidebarCanvas:elementCount()
			self.sidebarCanvas:appendElements({
				type = "text",
				text = "",
				textColor = { red = 1, green = 1, blue = 1, alpha = 0 },
				textSize = 12,
				frame = { x = 6, y = barY + 2, w = sb.w - 12, h = BAR_H - 4 },
			})
			self._renameTextIdx = self.sidebarCanvas:elementCount()

			-- Restore rename bar state after rebuild if mode is active
			if self._renameMode then
				self:_updateRenameBar()
				self.sidebarCanvas:elementAttribute(
					self._renameBarIdx,
					"fillColor",
					{ red = 0.1, green = 0.1, blue = 0.18, alpha = 0.92 }
				)
				self.sidebarCanvas:elementAttribute(
					self._renameTextIdx,
					"textColor",
					{ red = 1, green = 1, blue = 1, alpha = 1 }
				)
			end

			self._pendingSidebarFrame = nil
		else
			-- ── In-place update path: elementAttribute calls only ──
			self._buttonFrames = {}
			local y = 6
			for i, wd in ipairs(winData) do
				local winId = wd.winId
				local map = self._elementMap[winId]
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
							if modelStr ~= "" then
								table.insert(segments, modelStr)
							end
							if agentStr ~= "" then
								table.insert(segments, agentStr)
							end
							if tokStr ~= "" then
								table.insert(segments, tokStr)
							end
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
								tokStr = fmtTokens(wd.ccData.tokensIn)
									.. "▲ "
									.. fmtTokens(wd.ccData.tokensOut)
									.. "▼"
							end
							local win = hs.window.get(winId)
							local pr = wd.prFromTitle and { number = wd.prFromTitle, title = "" }
								or (win and self._ghAvailable and getOpenPRForWindow(win) or nil)
							local prStr = pr and ("#" .. pr.number) or ""
							local segments = {}
							if modelShort ~= "" then
								table.insert(segments, "cc:" .. modelShort)
							end
							if tokStr ~= "" then
								table.insert(segments, tokStr)
							end
							if prStr ~= "" then
								table.insert(segments, prStr)
							end
							ccText = table.concat(segments, "  ")
						end
						self.sidebarCanvas:elementAttribute(map.line5, "text", ccText)
					end
				end

				self._btnStructureKeys[winId] = wd.bKey

				self._buttonFrames[i] = {
					x = cfg.padding,
					y = y,
					w = sb.w - cfg.padding * 2,
					h = cfg.windowButtonHeight,
					windowId = winId,
				}
				y = y + cfg.windowButtonHeight + 4
			end
			self._pendingSidebarFrame = nil
		end
	end)

	self._buildPending = false
	self:syncCanvasLevel()

	-- Show canvas AFTER level is set so it renders on top of iTerm windows
	if needsFullRebuild and self._sidebarEnabled then
		self.sidebarCanvas:show()
		self._sidebarVisible = true
	end

	if not ok then
		hs.printf("buildSidebar crashed: %s", tostring(err))
	end
end

-- ─────────────────────────────────────────────
-- Window Management
-- ─────────────────────────────────────────────

function obj:tileITermWindows()
	if not self._sidebarVisible then
		return
	end
	if not self.sidebarCanvas then
		return
	end
	if not self._sidebarEnabled then
		return
	end
	local sf = self.sidebarCanvas:frame()
	local screen = self:getScreen()
	local screenFrame = screen:frame()
	local newFrame = self:layoutFrames(screenFrame, sf).content
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
	self:buildSidebar()
	self:tileITermWindows()
	self:syncCanvasLevel()
end

function obj:toggleSidebar()
	if self.sidebarCanvas and self._sidebarVisible then
		local sbf = self.sidebarCanvas:frame()
		self.sidebarCanvas:hide()
		self._sidebarVisible = false
		for _, win in ipairs(getITermWindows()) do
			local f = win:frame()
			local restoreX = (self.config.sidebarSide ~= "left") and f.x or sbf.x
			win:setFrame({ x = restoreX, y = f.y, w = f.w + self.config.sidebarWidth, h = f.h })
		end
		self._toggleLock = true
		hs.timer.doAfter(0.5, function()
			self._toggleLock = false
		end)
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
		self:tileITermWindows()
		self:syncCanvasLevel()
		hs.timer.doAfter(0.5, function()
			self._toggleLock = false
		end)
	end
end

function obj:toggleSide()
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
		local app = hs.application.get("com.googlecode.iterm2")
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
	if frontApp and frontApp:bundleID() == "com.googlecode.iterm2" then
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
	return bid == "com.googlecode.iterm2" or bid == "org.hammerspoon.Hammerspoon"
end

function obj:handleSidebarClick(x, y, rightClick)
	local app = hs.application.get("com.googlecode.iterm2")
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

function obj:renameWindow(windowId)
	self:startRenameMode(windowId)
end

function obj:_saveCustomName(windowId, name)
	local win = hs.window.get(windowId)
	if name and name ~= "" then
		self._customNames[windowId] = name
		local fullPath = _wdCache[windowId]
		if fullPath then
			self._customNamesByPath[fullPath] = name
			hs.settings.set(SETTINGS_KEY_NAMES_BY_PATH, self._customNamesByPath)
		else
			self._pendingPathNames[windowId] = name
			if win then
				getWindowWorkingDir(win)
			end
		end
	else
		self._customNames[windowId] = nil
		local fullPath = _wdCache[windowId]
		if fullPath then
			self._customNamesByPath[fullPath] = nil
			hs.settings.set(SETTINGS_KEY_NAMES_BY_PATH, self._customNamesByPath)
		else
			self._pendingPathNames[windowId] = false
			if win then
				getWindowWorkingDir(win)
			end
		end
	end
	hs.timer.doAfter(0.05, function()
		self._lastSidebarSnapshot = nil
		self:buildSidebar()
	end)
end

function obj:startRenameMode(windowId)
	if not self.sidebarCanvas then
		return
	end
	if self._renameMode then
		self:cancelRenameMode()
	end

	self._renameWindowId = windowId
	self._renameBuffer = self._customNames[windowId] or ""
	self._renameMode = true
	self._cursorVisible = true

	self:_updateRenameBar()
	if self._renameBarIdx then
		self.sidebarCanvas:elementAttribute(
			self._renameBarIdx,
			"fillColor",
			{ red = 0.1, green = 0.1, blue = 0.18, alpha = 0.92 }
		)
	end
	if self._renameTextIdx then
		self.sidebarCanvas:elementAttribute(
			self._renameTextIdx,
			"textColor",
			{ red = 1, green = 1, blue = 1, alpha = 1 }
		)
	end

	self.sidebarCanvas:level(hs.canvas.windowLevels.floating)

	self._renameEventTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
		return self:_handleRenameKey(e)
	end)
	self._renameEventTap:start()

	if self._renameBlink then
		self._renameBlink:stop()
	end
	self._renameBlink = hs.timer.new(0.5, function()
		if not self._renameMode then
			return
		end
		self._cursorVisible = not self._cursorVisible
		self:_updateRenameBar()
	end)
	self._renameBlink:start()
end

function obj:_updateRenameBar()
	if not self._renameTextIdx or not self.sidebarCanvas then
		return
	end
	local cursor = self._cursorVisible and "▏" or " "
	local atLimit = #self._renameBuffer >= MAX_RENAME_LEN
	local prefix = atLimit and "Rename [max]: " or "Rename: "
	local display = prefix .. self._renameBuffer .. cursor
	self.sidebarCanvas:elementAttribute(self._renameTextIdx, "text", display)
end

function obj:_handleRenameKey(event)
	if not self._renameMode then
		return false
	end

	local code = event:getKeyCode()
	local flags = event:getFlags()
	local char = event:getCharacters(true) or ""

	if code == hs.keycodes.map["return"] then
		self:commitRename()
		return true
	elseif code == hs.keycodes.map["escape"] then
		self:cancelRenameMode()
		return true
	elseif code == hs.keycodes.map["delete"] then
		if #self._renameBuffer > 0 then
			self._renameBuffer = self._renameBuffer:sub(1, -2)
			self._cursorVisible = true
			self:_updateRenameBar()
		end
		return true
	elseif code == hs.keycodes.map["forwarddelete"] then
		self._renameBuffer = ""
		self._cursorVisible = true
		self:_updateRenameBar()
		return true
	elseif flags.cmd and code == hs.keycodes.map["v"] then
		local paste = (hs.pasteboard.getContents() or ""):gsub("\n.*", "")
		local combined = self._renameBuffer .. paste
		self._renameBuffer = combined:sub(1, MAX_RENAME_LEN)
		self._cursorVisible = true
		self:_updateRenameBar()
		return true
	elseif flags.cmd or flags.ctrl then
		return false
	elseif not flags.alt and char ~= "" then
		if #self._renameBuffer < MAX_RENAME_LEN then
			self._renameBuffer = self._renameBuffer .. char
			self._cursorVisible = true
			self:_updateRenameBar()
		end
		return true
	end

	return false
end

function obj:commitRename()
	local windowId = self._renameWindowId
	local name = self._renameBuffer
	self:cancelRenameMode()
	self:_saveCustomName(windowId, name)
end

function obj:cancelRenameMode()
	self._renameMode = false
	self._renameBuffer = ""
	self._renameWindowId = nil

	if self._renameEventTap then
		self._renameEventTap:stop()
		self._renameEventTap = nil
	end
	if self._renameBlink then
		self._renameBlink:stop()
		self._renameBlink = nil
	end

	if self._renameBarIdx and self.sidebarCanvas then
		self.sidebarCanvas:elementAttribute(
			self._renameBarIdx,
			"fillColor",
			{ red = 0.1, green = 0.1, blue = 0.18, alpha = 0 }
		)
	end
	if self._renameTextIdx and self.sidebarCanvas then
		self.sidebarCanvas:elementAttribute(
			self._renameTextIdx,
			"textColor",
			{ red = 1, green = 1, blue = 1, alpha = 0 }
		)
	end

	self:syncCanvasLevel()
end

function obj:showWindowMenu(windowId)
	-- Close any existing menu
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

	local items = {
		{
			label = "Rename",
			shortcut = "\xE2\x8C\x98\xE2\x87\xA7E",
			action = function()
				self:renameWindow(windowId)
			end,
		},
		{
			label = "Move Up",
			shortcut = "\xE2\x8C\x98\xE2\x87\xA7\xE2\x86\x91",
			action = function()
				self:moveWindowById(windowId, -1)
			end,
		},
		{
			label = "Move Down",
			shortcut = "\xE2\x8C\x98\xE2\x87\xA7\xE2\x86\x93",
			action = function()
				self:moveWindowById(windowId, 1)
			end,
		},
		{
			label = "Move to Top",
			shortcut = "\xE2\x8C\x98\xE2\x87\xA7\xE2\x8C\xA5\xE2\x86\x91",
			action = function()
				self:moveWindowToExtent(windowId, "top")
			end,
		},
		{
			label = "Move to Bottom",
			shortcut = "\xE2\x8C\x98\xE2\x87\xA7\xE2\x8C\xA5\xE2\x86\x93",
			action = function()
				self:moveWindowToExtent(windowId, "bottom")
			end,
		},
		{
			label = "Refresh Layout",
			shortcut = "\xE2\x8C\x98\xE2\x87\xA7R",
			action = function()
				self:refreshLayout()
			end,
		},
		{
			label = "Show/Hide Axis",
			shortcut = "\xE2\x8C\x98\xE2\x87\xA7B",
			action = function()
				self:toggleSidebar()
			end,
		},
		{
			label = "Swap Side",
			shortcut = "\xE2\x8C\x98\xE2\x87\xA7S",
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

	local items = {
		{
			label = "Refresh Layout",
			shortcut = "\xE2\x8C\x98\xE2\x87\xA7R",
			action = function()
				self:refreshLayout()
			end,
		},
		{
			label = "Show/Hide Axis",
			shortcut = "\xE2\x8C\x98\xE2\x87\xA7B",
			action = function()
				self:toggleSidebar()
			end,
		},
		{
			label = "Swap Side",
			shortcut = "\xE2\x8C\x98\xE2\x87\xA7S",
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
	self._resizeDebounceTimer = hs.timer.doAfter(0.3, function()
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
			if self._renameMode then
				self:cancelRenameMode()
			end
			for _, win in ipairs(wins) do
				local id = win:id()
				_wdCache[id] = nil
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
			self:tileITermWindows()
			return
		end

		local cfg = self.config
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

	local toggleMods, toggleKey = table.unpack(map.toggle or { { "cmd", "shift" }, "B" })
	local newWinMods, newWinKey = table.unpack(map.newWindow or { { "cmd", "shift" }, "N" })
	local refreshMods, refreshKey = table.unpack(map.refresh or { { "cmd", "shift" }, "R" })
	local renameMods, renameKey = table.unpack(map.renameWindow or { { "cmd", "shift" }, "E" })
	local moveUpMods, moveUpKey = table.unpack(map.moveUp or { { "cmd", "shift" }, "up" })
	local moveDownMods, moveDownKey = table.unpack(map.moveDown or { { "cmd", "shift" }, "down" })
	local moveTopMods, moveTopKey = table.unpack(map.moveToTop or { { "cmd", "shift", "alt" }, "up" })
	local moveBottomMods, moveBottomKey = table.unpack(map.moveToBottom or { { "cmd", "shift", "alt" }, "down" })
	local focusUpMods, focusUpKey = table.unpack(map.focusUp or { { "alt", "cmd" }, "up" })
	local focusDownMods, focusDownKey = table.unpack(map.focusDown or { { "alt", "cmd" }, "down" })
	local swapSideMods, swapSideKey = table.unpack(map.swapSide or { { "cmd", "shift" }, "S" })

	hs.hotkey.bind(toggleMods, toggleKey, function()
		self:toggleSidebar()
	end)
	hs.hotkey.bind(swapSideMods, swapSideKey, function()
		self:toggleSide()
	end)

	hs.hotkey.bind(newWinMods, newWinKey, function()
		local iterm = hs.application.get("com.googlecode.iterm2")
		if iterm then
			iterm:activate()
			hs.timer.doAfter(0.15, function()
				hs.eventtap.keyStroke({ "cmd" }, "n")
				hs.timer.doAfter(0.5, function()
					self._lastStructureSnapshot = nil
					self:buildSidebar()
					self:tileITermWindows()
				end)
			end)
		else
			hs.application.open("com.googlecode.iterm2")
			hs.timer.doAfter(1.0, function()
				self._lastStructureSnapshot = nil
				self:buildSidebar()
				self:tileITermWindows()
			end)
		end
	end)

	hs.hotkey.bind(refreshMods, refreshKey, function()
		self:refreshLayout()
	end)

	hs.hotkey.bind(renameMods, renameKey, function()
		if self.activeWindowId then
			self:renameWindow(self.activeWindowId)
		end
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

	hs.hotkey.bind({ "cmd", "shift", "ctrl" }, "D", function()
		local all = hs.window.allWindows()
		for _, w in ipairs(all) do
			local app = w:application()
			if app and app:bundleID() == "com.googlecode.iterm2" then
				hs.printf("iTerm win %d: title=%q isStandard=%s", w:id(), w:title() or "", tostring(w:isStandard()))
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

function obj:_setupSidebarClickTap()
	if self._clickTap then
		self._clickTap:stop()
	end
	self._clickTap = hs.eventtap.new({
		hs.eventtap.event.types.leftMouseDown,
		hs.eventtap.event.types.rightMouseDown,
	}, function(e)
		if self._renameMode then
			self:cancelRenameMode()
		end
		if not self._sidebarVisible then
			return false
		end
		local sf = self.sidebarCanvas and self.sidebarCanvas:frame()
		if not sf then
			return false
		end
		local mouse = e:location()
		if rectContains(sf, mouse.x, mouse.y) then
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

function obj:start()
	self:_setupSidebarClickTap()
	self:_setupDragTap()

	if self._winWatcher then
		self._winWatcher:stop()
	end
	self._winWatcher = hs.window.filter.new("iTerm2")
	self._winWatcher:subscribe("windowCreated", function(win)
		if win then
			self:watchWindow(win)
		end
		_iTermWindowsCache = nil
		hs.timer.doAfter(0.3, function()
			self._lastStructureSnapshot = nil
			self:buildSidebar()
			self:tileITermWindows()
		end)
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
			_wdFlight[id] = nil
			_ccCache[id] = nil
			_ccPending[id] = nil
			_ccPathKey[id] = nil
			stopFlashing(id)
		end
		_iTermWindowsCache = nil
		hs.timer.doAfter(0.3, function()
			self._lastStructureSnapshot = nil
			self:buildSidebar()
		end)
	end)
	self._winWatcher:subscribe("windowMinimized", function()
		_iTermWindowsCache = nil
		hs.timer.doAfter(0.3, function()
			self._lastStructureSnapshot = nil
			self:buildSidebar()
		end)
	end)
	self._winWatcher:subscribe("windowUnminimized", function(win)
		if win then
			self:watchWindow(win)
		end
		_iTermWindowsCache = nil
		hs.timer.doAfter(0.3, function()
			self._lastStructureSnapshot = nil
			self:buildSidebar()
			self:tileITermWindows()
		end)
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
				_ccCache[id] = nil
				_ccPathKey[id] = nil
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
			hs.timer.doAfter(0.1, function()
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
			hs.timer.doAfter(0.05, function()
				self:syncCanvasLevel()
			end)
		end
	end)

	-- Application focus watcher: cancel rename mode when iTerm2 loses focus
	if self._appWatcher then
		self._appWatcher:stop()
	end
	self._appWatcher = hs.application.watcher.new(function(appName, event, appObj)
		if event == hs.application.watcher.deactivated then
			local bid = appObj and appObj:bundleID()
			if bid == "com.googlecode.iterm2" then
				if self._renameMode then
					self:cancelRenameMode()
				end
				self:syncCanvasLevel() -- single source of truth
			end
		elseif event == hs.application.watcher.activated then
			local bid = appObj and appObj:bundleID()
			if bid == "com.googlecode.iterm2" and self._sidebarVisible then
				self:syncCanvasLevel() -- single source of truth
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
		if not savedNamesByPath then
			return
		end
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
		if needsRebuild and self.sidebarCanvas and self._sidebarEnabled then
			self._lastSidebarSnapshot = nil
			self:buildSidebar()
		end
	end
	hs.timer.doAfter(10, reapplyPathNames)
	hs.timer.doAfter(30, reapplyPathNames)

	if self._screenWatcher then
		self._screenWatcher:stop()
	end
	self._screenWatcher = hs.screen.watcher.new(function()
		hs.timer.doAfter(0.3, function()
			if self._renameMode then
				self:cancelRenameMode()
			end
			self._pendingSidebarFrame = nil
			self._currentScreen = nil
			if self.sidebarCanvas then
				self.sidebarCanvas:delete()
				self.sidebarCanvas = nil
			end
			self._lastStructureSnapshot = nil
			self._sidebarVisible = true
			self:buildSidebar()
			self:tileITermWindows()
		end)
	end)
	self._screenWatcher:start()

	if self._spaceWatcher then
		self._spaceWatcher:stop()
	end
	self._spaceWatcher = hs.spaces.watcher.new(function()
		hs.timer.doAfter(0.15, function()
			self:syncCanvasLevel()
			if self.sidebarCanvas and self._sidebarEnabled then
				self:buildSidebar()
				self:tileITermWindows()
			end
		end)
	end)
	self._spaceWatcher:start()

	self._sidebarVisible = not self.config.startHidden
	self:buildSidebar()
	self:tileITermWindows()

	hs.task
		.new("/usr/bin/which", function(exitCode, stdout, _)
			self._ghAvailable = (exitCode == 0 and stdout and stdout:gsub("%s+$", "") ~= "")
		end, { "gh" })
		:start()

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
	if self._renameMode then
		self:cancelRenameMode()
	end
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
	_wdFlight = {}
	if _sharedFlashTimer then
		_sharedFlashTimer:stop()
		_sharedFlashTimer = nil
	end
	_flashingWindows = {}
	_flashState = {}
	_flashNormalColor = {}
	_flashType = {}
	_ccCache = {}
	_ccPending = {}
	_ccPathKey = {}
	self._opencodePending = false
	if self._opencodePollTimer then
		self._opencodePollTimer:stop()
		self._opencodePollTimer = nil
	end
	if self._claudeCodePollTimer then
		self._claudeCodePollTimer:stop()
		self._claudeCodePollTimer = nil
	end
	self._elementMap = {}
	self._btnStructureKeys = {}
	self._pendingPathNames = {}
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
	self._toggleLock = false
	self._windowWatchers = {}
	self._menuCanvas = nil
	self._menuEventTap = nil
	self._menuKeyTap = nil
	self._customNames = {}
	self._customNamesByPath = {}
	self._pendingPathNames = {}
	self._orderedWindowIds = {}
	self._opencodeData = {}
	self._opencodePending = false
	self._opencodePollTimer = nil
	self._claudeCodeData = {}
	self._claudeCodePollTimer = nil
	self._ghAvailable = false
	self._btnBgElements = {}
	self._elementMap = {}
	self._btnStructureKeys = {}
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
	_wdFlight = {}
	_sharedFlashTimer = nil
	_flashingWindows = {}
	_flashState = {}
	_flashNormalColor = {}
	_flashType = {}
	_ccCache = {}
	_ccPending = {}
	_ccPathKey = {}
	self._renameMode = false
	self._renameBuffer = ""
	self._renameWindowId = nil
	self._renameEventTap = nil
	self._renameBarIdx = nil
	self._renameTextIdx = nil
	self._renameBlink = nil
	self._cursorVisible = true
	self._dragWatchTap = nil
	self._dragActive = false
	self._lastDragHoverId = nil
	return self
end

return obj
