CACHE._claudeAgentsData = {}

function _fetchWindowInfo(win)
	if not win then
		return nil
	end
	local winId = win:id()

	if CACHE.wc(winId).tabInfo and CACHE.wc(winId).wd then
		return CACHE.wc(winId).tabInfo
	end

	if CACHE.wc(winId).tabPending then
		return CACHE.wc(winId).tabInfo or nil
	end
	CACHE.wc(winId).tabPending = true

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
			CACHE.wc(winId).tabPending = nil
			local path, hostname

			if stdout and stdout ~= "" then
				local tabCount, focusedIdx, tabName, tPath, tHost =
					stdout:match("^([^\x1e]+)\x1e([^\x1e]+)\x1e([^\x1e]+)\x1e([^\x1e]*)\x1e([^\x1e]*)$")
				if tabCount then
					CACHE.wc(winId).tabInfo = {
						tabCount = tonumber(tabCount),
						focusedIdx = tonumber(focusedIdx),
						tabName = tabName,
					}
					path = tPath
					hostname = tHost
				end
			end

			if not CACHE.wc(winId).tabInfo then
				CACHE.wc(winId).tabInfo = false
			end
			CACHE.wc(winId).wd = (path and path ~= "") and path or false
			CACHE.wc(winId).hostname = (hostname and hostname ~= "") and hostname or false

			if OBJ.sidebarCanvas and OBJ._sidebarEnabled then
				OBJ:buildSidebar()
			end
		end, { "-e", script })
		:start()

	return CACHE.wc(winId).tabInfo or nil
end

function GET_GIT_BRANCH_FOR_PATH(path, winId)
	if not path or not winId then
		return nil
	end

	if CACHE.wc(winId).branch ~= nil and CACHE.wc(winId).wd == path then
		return CACHE.wc(winId).branch or nil
	end

	if CACHE.wc(winId).brPending then
		return CACHE.wc(winId).branch or nil
	end
	CACHE.wc(winId).brPending = true

	hs.task
		.new("/usr/bin/git", function(_, stdout, _)
			local branch = stdout and stdout:gsub("%s+$", "")
			if not branch or branch == "" or branch == "HEAD" then
				hs.task
					.new("/bin/sh", function(_, out, _)
						CACHE.wc(winId).brPending = nil
						local b, ws
						if out and out ~= "" then
							b, ws = out:match("^([^\t]+)\t?(.*)$")
							b = b and b:gsub("%s+$", "")
							ws = ws and ws:gsub("%s+$", "")
							if ws == "" then
								ws = nil
							end
						end
						CACHE.wc(winId).branch = (b and b ~= "") and b or false
						local wsLeaf = ws and ws:match("([^/]+)%s*$")
						CACHE.wc(winId).wsName = (wsLeaf and wsLeaf ~= "") and wsLeaf or false
						hs.timer.doAfter(0, function()
							if OBJ.sidebarCanvas and OBJ._sidebarEnabled then
								OBJ:buildSidebar()
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
			CACHE.wc(winId).brPending = nil
			CACHE.wc(winId).branch = (branch and branch ~= "") and branch or false
			CACHE.wc(winId).wsName = false
			hs.timer.doAfter(0, function()
				if OBJ.sidebarCanvas and OBJ._sidebarEnabled then
					OBJ:buildSidebar()
				end
			end)
		end, { "-C", path, "rev-parse", "--abbrev-ref", "HEAD" })
		:start()

	return CACHE.wc(winId).branch or nil
end

function SHORT_MODEL_NAME(id)
	if not id or id == "" then
		return nil
	end
	local name = id:match("[^/]+$") or id
	return name
end

function FMT_TOKENS(n)
	if n >= 1000000 then
		return string.format("%.1fM", n / 1e6)
	end
	if n >= 1000 then
		return string.format("%.1fk", n / 1e3)
	end
	return tostring(n)
end

function OBJ:fetchClaudeAgentsData()
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
			CACHE._claudeAgentsData = newData
			if self.sidebarCanvas and self._sidebarEnabled then
				self:buildSidebar()
			end
		end, { "claude", "agents", "--json" })
		:start()
end

function OBJ:startClaudeAgentsPolling()
	self:fetchClaudeAgentsData()
	if self._claudeAgentsPollTimer then
		self._claudeAgentsPollTimer:stop()
	end
	self._claudeAgentsPollTimer = hs.timer.new(self.config.claudecode.pollInterval, function()
		self:fetchClaudeAgentsData()
	end)
	self._claudeAgentsPollTimer:start()
end

function OBJ:_finalizeOpenCodeData(newData)
	self._opencodeData = newData
	self._opencodePending = false
	if self.sidebarCanvas and self._sidebarEnabled then
		self:buildSidebar()
	end
end

function NORMALIZE_OC_SESSION(s)
	if not s.directory then
		return nil
	end
	local m = {}
	if s.model then
		local ok, parsed = pcall(hs.json.decode, s.model)
		if ok and type(parsed) == "table" then
			m = parsed
		end
	end
	return {
		title = s.title,
		modelID = m.id,
		provider = m.providerID,
		agent = s.agent,
		tokensIn = s.tokens_input or 0,
		tokensOut = s.tokens_output or 0,
		updated = s.time_updated or 0,
	}
end

function OBJ:fetchOpenCodeData()
	if self._opencodePending then
		return
	end
	self._opencodePending = true

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
								local record = NORMALIZE_OC_SESSION(s)
								if record then
									local existing = newData[s.directory]
									if not existing or (s.time_updated or 0) > existing.updated then
										newData[s.directory] = record
									end
								end
							end
						end
					end
				end

				if next(newData) or hadResponse then
					self:_finalizeOpenCodeData(newData)
					return
				end

				local dbPath = os.getenv("HOME") .. "/.local/share/opencode/opencode.db"
				local sql =
					"SELECT title, directory, model, agent, tokens_input, tokens_output, time_updated FROM session ORDER BY time_updated DESC LIMIT 50"

				self._opencodePending = false
				local sqlOk = pcall(function()
					hs.task
						.new("/usr/bin/sqlite3", function(_, dbStdout, _)
							local newData = {}

							if dbStdout and dbStdout ~= "" then
								local ok, sessions = pcall(hs.json.decode, dbStdout)
								if ok and type(sessions) == "table" then
									for _, s in ipairs(sessions) do
										if s.directory and not newData[s.directory] then
											local record = NORMALIZE_OC_SESSION(s)
											if record then
												newData[s.directory] = record
											end
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

function OBJ:startOpenCodePolling()
	self:fetchOpenCodeData()
	if self._opencodePollTimer then
		self._opencodePollTimer:stop()
	end
	self._opencodePollTimer = hs.timer.new(self.config.opencode.pollInterval, function()
		self:fetchOpenCodeData()
	end)
	self._opencodePollTimer:start()
end
