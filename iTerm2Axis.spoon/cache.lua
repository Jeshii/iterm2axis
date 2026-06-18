CACHE = {}
CACHE.iTermWindowsCache = nil
CACHE.iTermWindowsCacheTime = 0
ITERM_CACHE_TTL = 0.1

function CACHE.getITermWindows()
	local now = hs.timer.secondsSinceEpoch()
	if CACHE.iTermWindowsCache and (now - CACHE.iTermWindowsCacheTime) < ITERM_CACHE_TTL then
		return CACHE.iTermWindowsCache
	end
	local all = hs.window.allWindows()
	local result = {}
	for _, w in ipairs(all) do
		if IS_ITERM(w) and w:isStandard() and not w:isMinimized() then
			table.insert(result, w)
		end
	end
	table.sort(result, function(a, b)
		return a:id() < b:id()
	end)
	CACHE.iTermWindowsCache = result
	CACHE.iTermWindowsCacheTime = now
	return result
end

function PARSE_TITLE_COMPONENTS(title)
	if not title or title == "" then
		return {}
	end
	title = title:gsub("%s+[—–-]%s+%d+✕%d+%s*$", "")
	local home = os.getenv("HOME") or ""

	local host, pathPart

	local h, p = title:match("^[^@]+@([^:]+):%s*(~?/.+)$")
	if h and p then
		host = h
		pathPart = p
	else
		local h2 = title:match("^[^@]+@([^:%s]+)%s*$")
		if h2 then
			host = h2
		else
			pathPart = title:match("^(~?/[^%s].*)$") or title:match("%s(~?/[^%s]+)%s*$")
		end
	end

	local fullPath = pathPart and pathPart:gsub("^~", home):gsub("%s+$", "")
	local basename = fullPath and fullPath:match("([^/]+)%s*$")

	if not basename or basename == "" then
		basename = title:match("([^%s/:]+)%s*$")
	end

	return {
		host = host,
		fullPath = fullPath,
		basename = basename,
	}
end

function PARSE_PR_FROM_TITLE(title)
	if not title or title == "" then
		return nil
	end
	local n = title:match("PR%s*#(%d+)")
	return n and tonumber(n) or nil
end

function RECT_CONTAINS(rect, x, y)
	return rect and x >= rect.x and x <= rect.x + rect.w and y >= rect.y and y <= rect.y + rect.h
end

-- Sentinel: nil = not yet fetched; MISSING (false) = fetched but absent
CACHE.MISSING = false

CACHE.winCache = {}

function CACHE.wc(winId)
	CACHE.winCache[winId] = CACHE.winCache[winId] or {}
	return CACHE.winCache[winId]
end

function CACHE.invalidateWindow(id, fields)
	if not CACHE.winCache[id] then
		return
	end
	local c = CACHE.winCache[id]
	for _, f in ipairs(fields) do
		c[f] = nil
	end
end
