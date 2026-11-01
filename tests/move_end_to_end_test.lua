-- The whole move from CareerMP to Mileage, start by start. One in-memory server folder
-- starts as a released CareerMP server (tests/fixtures/careerMP-0.2.0.lua or -0.1.0.lua);
-- fake GitHub serves this branch's files at their `main` paths, under both the old
-- norto22/CareerMP address and norto22/Mileage. Each start loads every plugin in the
-- folder in its own environment, as BeamMP gives each plugin its own Lua state, in folder
-- order and in reverse, and runs its onInit.
--
-- After every start the server is either serving (exactly one plugin handles players and
-- the client folder holds exactly that plugin's mod) or switching (Mileage's handoff
-- removed CareerMP this start: at most one plugin handles players, the client folder holds
-- Mileage.zip alone, and a restart is set or asked for). Anything else fails.

local MAX_STARTS = 8

local OLD_PLUGIN = "Resources/Server/CareerMP/careerMP.lua"
local OLD_CONFIG = "Resources/Server/CareerMP/config/config.json"
local OLD_CLIENT_VERSION = "Resources/Server/CareerMP/versions/client.json"
local OLD_SERVER_VERSION = "Resources/Server/CareerMP/versions/server.json"
local OLD_CLIENT = "Resources/Client/CareerMP.zip"
local PLUGIN = "Resources/Server/Mileage/mileage.lua"
local CLIENT_VERSION = "Resources/Server/Mileage/versions/client.json"
local SERVER_VERSION = "Resources/Server/Mileage/versions/server.json"
local CONFIG = "Resources/Server/Mileage/config/config.json"
local CLIENT = "Resources/Client/Mileage.zip"
local HELD_CLIENT = "Resources/Server/Mileage/Mileage.zip"
local SET_ASIDE = "Resources/Server/Mileage/CareerMP.zip.removed"

local RAW = "https://raw.githubusercontent.com/"
local OLD_REPO = RAW .. "norto22/CareerMP/main/"
local REPO = RAW .. "norto22/Mileage/main/"

local MOD_OF = {CareerMP = OLD_CLIENT, Mileage = CLIENT}

--== the branch's files, read before any stand-in is in place ===============

local function readReal(path)
	local file = assert(io.open(path, "rb"), "cannot read " .. path)
	local data = file:read("*a")
	file:close()
	return data
end

local BRANCH = {}
for _, path in ipairs({OLD_PLUGIN, OLD_CLIENT_VERSION, OLD_SERVER_VERSION, PLUGIN, CLIENT_VERSION,
		SERVER_VERSION, CLIENT}) do
	BRANCH[path] = readReal(path)
end
local RELEASED = {
	["0.1.0"] = readReal("tests/fixtures/careerMP-0.1.0.lua"),
	["0.2.0"] = readReal("tests/fixtures/careerMP-0.2.0.lua"),
}

--== JSON, as BeamMP's Util reads and writes it ==============================

local function jsonDecode(text)
	if type(text) ~= "string" then return nil end
	local pos = 1
	local function skip() pos = text:find("%S", pos) or #text + 1 end
	local function char() return text:sub(pos, pos) end
	local value
	local function str()
		local s, e = text:find('^"[^"]*"', pos)
		assert(s, "string expected")
		pos = e + 1
		return text:sub(s + 1, e - 1)
	end
	function value()
		skip()
		local c = char()
		if c == "{" or c == "[" then
			local close, t, i = c == "{" and "}" or "]", {}, 0
			pos = pos + 1
			skip()
			if char() == close then pos = pos + 1; return t end
			while true do
				skip()
				if close == "}" then
					local key = str()
					skip()
					assert(char() == ":", "colon expected")
					pos = pos + 1
					t[key] = value()
				else
					i = i + 1
					t[i] = value()
				end
				skip()
				local d = char()
				pos = pos + 1
				if d == close then return t end
				assert(d == ",", "comma expected")
			end
		elseif c == '"' then
			return str()
		elseif text:find("^true", pos) then pos = pos + 4; return true
		elseif text:find("^false", pos) then pos = pos + 5; return false
		elseif text:find("^null", pos) then pos = pos + 4; return nil
		end
		local s, e = text:find("^-?[%d%.eE+-]+", pos)
		assert(s, "value expected")
		pos = e + 1
		return tonumber(text:sub(s, e))
	end
	local ok, decoded = pcall(value)
	if ok then return decoded end
end

local function jsonEncode(v)
	if type(v) == "table" then
		if #v > 0 then
			local parts = {}
			for _, item in ipairs(v) do table.insert(parts, jsonEncode(item)) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for k in pairs(v) do table.insert(keys, tostring(k)) end
		table.sort(keys)
		local parts = {}
		for _, k in ipairs(keys) do table.insert(parts, jsonEncode(k) .. ":" .. jsonEncode(v[k])) end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif type(v) == "string" then
		return '"' .. v:gsub('[\\"]', "\\%0") .. '"'
	end
	return tostring(v)
end

--== an in-memory server folder ==============================================

local files, dirs, served, failOnce, refuseOnce, fetched, printed

local function addDirs(path)
	local dir = path:match("(.+)/[^/]+$")
	while dir do
		dirs[dir] = true
		dir = dir:match("(.+)/[^/]+$")
	end
end

local function fakeOpen(path, mode)
	if mode:sub(1, 1) == "r" then
		local data = files[path]
		if data == nil then return nil, path .. ": No such file or directory" end
		return {
			read = function() return data end,
			seek = function() return #data end,
			close = function() end,
		}
	end
	local dir = path:match("(.+)/[^/]+$")
	if dir and not dirs[dir] then return nil, path .. ": No such file or directory" end
	if refuseOnce[path] then
		refuseOnce[path] = nil
		return nil, path .. ": Permission denied"
	end
	local parts = {}
	local handle = {}
	handle.write = function(_, text) table.insert(parts, text); return handle end
	handle.close = function() files[path] = table.concat(parts); return true end
	return handle
end

local removeRefusedOnce, windowsRenames

local function fakeRemove(path)
	if files[path] == nil then return nil, path .. ": No such file or directory" end
	if removeRefusedOnce[path] then
		removeRefusedOnce[path] = nil
		return nil, path .. ": Permission denied"
	end
	files[path] = nil
	return true
end

local function fakeRename(from, to)
	if files[from] == nil then return nil, from .. ": No such file or directory" end
	-- os.rename on Windows fails when the target exists, where Linux replaces it.
	if windowsRenames and files[to] ~= nil then return nil, to .. ": File exists" end
	local dir = to:match("(.+)/[^/]+$")
	if dir and not dirs[dir] then return nil, to .. ": No such file or directory" end
	files[to], files[from] = files[from], nil
	return true
end

-- wget -q -O <path> <url>: serves the branch's files, or fails like wget.
local function fakeExecute(command)
	local path, url = command:match("^wget %-q %-O (%S+) (%S+)$")
	assert(path, "unexpected command: " .. command)
	table.insert(fetched, url)
	local dir = path:match("(.+)/[^/]+$")
	if failOnce[url] then
		failOnce[url] = nil
		return 8
	end
	if served[url] == nil or (dir and not dirs[dir]) then return 8 end
	files[path] = served[url]
	return 0
end

local function serveBranch()
	served = {}
	for path, data in pairs(BRANCH) do
		served[OLD_REPO .. path] = data
		served[REPO .. path] = data
	end
end

local function fingerprint()
	local paths = {}
	for path in pairs(files) do table.insert(paths, path) end
	table.sort(paths)
	local parts = {}
	for _, path in ipairs(paths) do table.insert(parts, path .. "=" .. files[path]) end
	return table.concat(parts, "\n")
end

local function upvalue(fn, name)
	local i = 1
	while true do
		local n, v = debug.getupvalue(fn, i)
		if n == nil then return nil end
		if n == name then return v end
		i = i + 1
	end
end

--== one start of the server =================================================

-- The plugin files BeamMP finds at start: one Lua file directly in each folder under
-- Resources/Server/, as {name, path}, in folder-name order.
local function pluginsAtStart()
	local found = {}
	for path in pairs(files) do
		local folder = path:match("^Resources/Server/([^/]+)/[^/]+%.lua$")
		if folder then table.insert(found, {name = folder, path = path}) end
	end
	table.sort(found, function(a, b) return a.name < b.name end)
	return found
end

local function loadPlugin(source, name, env)
	local chunk, err
	if setfenv then
		chunk, err = loadstring(source, name)
		if chunk then setfenv(chunk, env) end
	else
		chunk, err = load(source, name, "t", env)
	end
	assert(chunk, err)
	chunk()
end

-- Runs one start. Returns what each loaded plugin did, and the lines printed.
local function start(order)
	printed = {}
	local list = pluginsAtStart()
	if order == "reverse" then
		local reversed = {}
		for i = #list, 1, -1 do table.insert(reversed, list[i]) end
		list = reversed
	end
	local results = {}
	for _, plugin in ipairs(list) do
		-- A plugin whose file another plugin removed earlier in this start never loads.
		if files[plugin.path] then
			local registered = {}
			local env = setmetatable({
				MP = {
					GetOSName = function() return "Linux" end,
					CreateTimer = function() return {GetCurrent = function() return 0 end, Start = function() end} end,
					GetPlayers = function() return {} end,
					RegisterEvent = function(event) registered[event] = true end,
					CreateEventTimer = function() end,
					TriggerClientEvent = function() end,
					TriggerLocalEvent = function() end,
				},
			}, {__index = _G})
			local before = #printed
			loadPlugin(files[plugin.path], plugin.path, env)
			env.onInit()
			local lines = {}
			for i = before + 1, #printed do table.insert(lines, printed[i]) end
			table.insert(results, {
				name = plugin.name,
				serving = registered.onPlayerJoin == true,
				willExit = upvalue(env.tick, "willExit") == true,
				lines = lines,
			})
		end
	end
	return results
end

local function clientMods()
	local mods = {}
	for path in pairs(files) do
		if path:find("^Resources/Client/[^/]+%.zip$") then table.insert(mods, path) end
	end
	table.sort(mods)
	return mods
end

-- Checks one start against the two states a server may be in; returns its kind.
local function checkStart(results, n)
	local serving, restart, switched = {}, false, false
	for _, r in ipairs(results) do
		if r.serving then table.insert(serving, r.name) end
		if r.willExit then restart = true end
		if r.name == "Mileage" and (countLines(r.lines, "Moving from CareerMP: restarting to finish the move") > 0
				or countLines(r.lines, "Moving from CareerMP: restart the server to finish the move") > 0) then
			switched = true
		end
	end
	local mods = clientMods()
	local where = string.format("start %d: serving {%s}, client folder {%s}", n, table.concat(serving, ", "),
		table.concat(mods, ", "))
	if switched then
		expect(#serving <= 1, where .. ": both plugins handle players while switching")
		expect(#mods == 1 and mods[1] == CLIENT, where .. ": a switch must leave Mileage.zip alone")
		return "switch"
	end
	expect(#serving == 1, where .. ": exactly one plugin must handle players")
	expect(#mods == 1 and mods[1] == MOD_OF[serving[1]], where .. ": the client folder must hold its mod alone")
	return serving[1], restart
end

--== running the move ========================================================

local realPrint, realOpen, realRemove, realRename, realExecute =
	print, io.open, os.remove, os.rename, os.execute

-- Settings every released CareerMP knows, so its own config check keeps them as they are.
local OWNER = {
	server = {autoUpdate = true, autoExit = true, allowTransactions = false, sessionSendingMax = 5000},
	client = {roadTrafficAmount = 3, parkedTrafficAmount = 5, serverSaveSuffix = "_ours"},
}

local function versionJson(major, minor, revision, lineage)
	return jsonEncode({major = major, minor = minor, revision = revision, lineage = lineage})
end

-- A server folder running released CareerMP `version`.
local function careerMPServer(version, autoExit)
	OWNER.server.autoExit = autoExit ~= false
	local minor = version == "0.1.0" and 1 or 2
	return {
		[OLD_PLUGIN] = RELEASED[version],
		[OLD_CLIENT_VERSION] = versionJson(0, minor, 0, "norto22/CareerMP"),
		[OLD_SERVER_VERSION] = versionJson(0, minor, 0, "norto22/CareerMP"),
		[OLD_CONFIG] = jsonEncode(OWNER),
		[OLD_CLIENT] = "careermp " .. version .. " zip",
	}
end

-- Starts the server again and again until it settles on Mileage. Each start must pass
-- checkStart, and every start before the switch must be CareerMP serving.
local function runMove(existing, order, opts)
	opts = opts or {}
	local log = {}
	local ok, err = pcall(function()
		files, dirs, fetched = {}, {}, {}
		failOnce, refuseOnce = opts.failOnce or {}, opts.refuseOnce or {}
		removeRefusedOnce, windowsRenames = opts.removeRefusedOnce or {}, opts.windowsRenames == true
		for path, data in pairs(existing) do
			files[path] = data
			addDirs(path)
		end
		serveBranch()
		Util = {JsonDecode = jsonDecode, JsonEncode = jsonEncode, JsonPrettify = function(s) return s end}
		FS = {
			Exists = function(path) return files[path] ~= nil or dirs[path] == true end,
			IsDirectory = function(path) return dirs[path] == true end,
			CreateDirectory = function(path) dirs[path] = true; addDirs(path .. "/x") end,
		}
		print = function(line) table.insert(printed, tostring(line)); table.insert(log, tostring(line)) end
		io.open, os.remove, os.rename, os.execute = fakeOpen, fakeRemove, fakeRename, fakeExecute

		local switched = false
		for n = 1, MAX_STARTS do
			local before = fingerprint()
			local kind, restart = checkStart(start(order), n)
			if kind == "switch" then
				switched = true
			elseif not switched then
				expect(kind == "CareerMP", string.format("start %d: Mileage served before the switch", n))
				expect(files[OLD_CLIENT] ~= nil, string.format("start %d: CareerMP serving without CareerMP.zip", n))
			end
			if kind == "Mileage" and not restart and fingerprint() == before then
				return
			end
		end
		error(string.format("the server did not settle on Mileage within %d starts", MAX_STARTS), 0)
	end)
	print, io.open, os.remove, os.rename, os.execute =
		realPrint, realOpen, realRemove, realRename, realExecute
	if not ok then error(err, 0) end
	return log
end

local function settledOnMileage(what)
	same(files[PLUGIN], BRANCH[PLUGIN], what .. ": Mileage plugin")
	same(files[CLIENT], BRANCH[CLIENT], what .. ": Mileage client mod")
	local server, client = jsonDecode(files[SERVER_VERSION]), jsonDecode(files[CLIENT_VERSION])
	expect(server and client, what .. ": Mileage version files")
	same(server.lineage, "norto22/Mileage", what .. ": server version lineage")
	same(client.lineage, "norto22/Mileage", what .. ": client version lineage")
	same(string.format("%d.%d.%d", server.major, server.minor, server.revision), "0.3.0", what .. ": server version")
	for _, gone in ipairs({OLD_PLUGIN, OLD_CLIENT, OLD_CLIENT_VERSION, OLD_SERVER_VERSION, HELD_CLIENT, SET_ASIDE}) do
		same(files[gone], nil, what .. ": " .. gone)
	end
	for path in pairs(files) do
		expect(not path:find("%.download$") and not path:find("%.bak$") and not path:find("%.tmp$"),
			what .. ": " .. path .. " left behind")
	end
	local settings = jsonDecode(files[CONFIG])
	expect(settings, what .. ": Mileage settings")
	for section, values in pairs(OWNER) do
		for key, value in pairs(values) do
			same(settings[section][key], value, what .. ": owner's " .. section .. "." .. key)
		end
	end
end

for _, order in ipairs({"folder", "reverse"}) do
	test("a CareerMP 0.2.0 server moves to Mileage and keeps its settings (" .. order .. " order)", function()
		local log = runMove(careerMPServer("0.2.0"), order)
		settledOnMileage(order)
		same(countLines(log, "[CareerMP] ---------- Moving to Mileage: installed Mileage 0.3.0"), 1, "bridge installed Mileage")
		same(countLines(log, "[Mileage] ---------- Moving from CareerMP: copied the settings"), 1, "settings copied once")
	end)
end

test("with autoExit off the server moves when the owner restarts it each time", function()
	local log = runMove(careerMPServer("0.2.0", false), "folder")
	settledOnMileage("autoExit off")
	expect(countLines(log, "restart the server to finish the move") >= 1, "owner asked to restart")
end)

test("a failed client mod download keeps CareerMP serving, and the next start completes the move", function()
	local url = REPO .. CLIENT
	runMove(careerMPServer("0.2.0"), "folder", {failOnce = {[url] = true}})
	settledOnMileage("client download failed once")
	local tries = 0
	for _, fetchedUrl in ipairs(fetched) do
		if fetchedUrl == url then tries = tries + 1 end
	end
	expect(tries >= 2, "the client mod was fetched again after failing")
end)

test("a failed Mileage plugin download keeps CareerMP serving, and the next start completes the move", function()
	local url = REPO .. PLUGIN
	runMove(careerMPServer("0.2.0"), "reverse", {failOnce = {[url] = true}})
	settledOnMileage("plugin download failed once")
end)

test("a refused settings copy keeps CareerMP serving with no Mileage settings, and the next start copies them", function()
	local log = runMove(careerMPServer("0.2.0"), "folder", {refuseOnce = {[CONFIG .. ".tmp"] = true}})
	settledOnMileage("settings copy refused once")
	same(countLines(log, "could not copy the settings"), 1, "failed copy logged")
	same(countLines(log, "Mileage Config Initializing"), 0, "no default Mileage settings written")
end)

test("a CareerMP 0.1.0 server logs one failed old client download and still moves to Mileage", function()
	local log = runMove(careerMPServer("0.1.0"), "folder")
	settledOnMileage("0.1.0")
	same(countLines(log, "Download failed: " .. OLD_REPO .. OLD_CLIENT), 1, "old client download failed once")
end)

for _, order in ipairs({"folder", "reverse"}) do
	test("Mileage unpacked by hand over CareerMP 0.2.0 takes over the same way (" .. order .. " order)", function()
		local existing = careerMPServer("0.2.0")
		for _, path in ipairs({PLUGIN, CLIENT_VERSION, SERVER_VERSION, CLIENT}) do existing[path] = BRANCH[path] end
		runMove(existing, order)
		settledOnMileage("hand install")
	end)
end

test("a failed Mileage version fetch keeps CareerMP serving, and the next start completes the move", function()
	local url = REPO .. SERVER_VERSION
	local log = runMove(careerMPServer("0.2.0"), "folder", {failOnce = {[url] = true}})
	settledOnMileage("version fetch failed once")
	same(countLines(log, "could not fetch " .. url), 1, "failed fetch logged")
end)

for _, order in ipairs({"folder", "reverse"}) do
	test("a CareerMP plugin that refuses removal once keeps CareerMP serving with CareerMP.zip back (" .. order .. " order)", function()
		local log = runMove(careerMPServer("0.2.0"), order, {removeRefusedOnce = {[OLD_PLUGIN] = true}})
		settledOnMileage("plugin removal refused once")
		same(countLines(log, "could not remove " .. OLD_PLUGIN), 1, "failed removal logged")
	end)
end

for _, order in ipairs({"folder", "reverse"}) do
	test("with renames that refuse an existing target, as on Windows, the move completes (" .. order .. " order)", function()
		runMove(careerMPServer("0.2.0"), order, {windowsRenames = true})
		settledOnMileage("Windows renames")
	end)
end
