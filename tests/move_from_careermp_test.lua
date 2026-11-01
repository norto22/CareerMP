-- Resources/Server/Mileage/mileage.lua: moving a server from CareerMP, the mod's name
-- before Mileage. The handoff copies the settings through a checked temporary file, makes
-- sure Mileage's client mod is ready, and only then removes CareerMP. A failed step leaves
-- every CareerMP file as it was and starts nothing, so CareerMP keeps serving players and
-- the next start tries again.

local SOURCE = "Resources/Server/Mileage/mileage.lua"

local OLD_PLUGIN = "Resources/Server/CareerMP/careerMP.lua"
local OLD_CONFIG = "Resources/Server/CareerMP/config/config.json"
local OLD_CLIENT_VERSION = "Resources/Server/CareerMP/versions/client.json"
local OLD_SERVER_VERSION = "Resources/Server/CareerMP/versions/server.json"
local OLD_CLIENT = "Resources/Client/CareerMP.zip"
local NEW_CONFIG = "Resources/Server/Mileage/config/config.json"
local NEW_CONFIG_TMP = NEW_CONFIG .. ".tmp"
local NEW_CLIENT = "Resources/Client/Mileage.zip"
local HELD_CLIENT = "Resources/Server/Mileage/Mileage.zip"
local SET_ASIDE = "Resources/Server/Mileage/CareerMP.zip.removed"
local CLIENT_URL = "https://raw.githubusercontent.com/norto22/Mileage/main/Resources/Client/Mileage.zip"

local SETTINGS = '{"server":{"autoExit":false,"autoUpdate":false}}'

local function upvalue(fn, name)
	local i = 1
	while true do
		local n, v = debug.getupvalue(fn, i)
		if n == nil then return nil end
		if n == name then return v end
		i = i + 1
	end
end

local realPrint, realOpen, realRemove, realRename, realExecute =
	print, io.open, os.remove, os.rename, os.execute

-- An in-memory file system behind FS, io.open, os.remove, os.rename and os.execute (wget).
--   locked:      paths that refuse removal and renaming away
--   refused:     paths that refuse to open for writing
--   garbled:     paths whose written content reads back changed
--   served:      url -> content for wget; a missing url fails like wget
local files, dirs, locked, refused, garbled, served, fetched, printed, registered

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
	if refused[path] or (dir and not dirs[dir]) then return nil, path .. ": Permission denied" end
	local parts = {}
	local handle = {}
	handle.write = function(_, text) table.insert(parts, text); return handle end
	handle.close = function()
		local data = table.concat(parts)
		if garbled[path] then data = data:sub(1, #data - 1) end
		files[path] = data
		return true
	end
	return handle
end

local function fakeRemove(path)
	if files[path] == nil or locked[path] then return nil, path .. ": cannot remove" end
	files[path] = nil
	return true
end

local function fakeRename(from, to)
	if files[from] == nil or locked[from] or refused[to] then return nil, from .. ": cannot rename" end
	files[to], files[from] = files[from], nil
	return true
end

local function fakeExecute(command)
	local path, url = command:match("^wget %-q %-O (%S+) (%S+)$")
	assert(path, "unexpected command: " .. command)
	table.insert(fetched, url)
	local dir = path:match("(.+)/[^/]+$")
	if served[url] == nil or (dir and not dirs[dir]) then return 8 end
	files[path] = served[url]
	return 0
end

local function loadPlugin(existing)
	files, dirs, locked, refused, garbled, fetched, printed, registered = {}, {}, {}, {}, {}, {}, {}, {}
	served = {[CLIENT_URL] = "mileage zip"}
	for path, data in pairs(existing or {}) do
		files[path] = data
		addDirs(path)
	end
	dirs["Resources/Server/Mileage"] = true
	dirs["Resources/Client"] = true
	Util = {JsonEncode = function() return "{}" end, JsonPrettify = function(s) return s end}
	FS = {
		Exists = function(path) return files[path] ~= nil or dirs[path] == true end,
		IsDirectory = function(path) return dirs[path] == true end,
		CreateDirectory = function(path) dirs[path] = true; addDirs(path .. "/x") end,
	}
	MP = {
		GetOSName = function() return "Linux" end,
		CreateTimer = function() return {GetCurrent = function() return 0 end, Start = function() end} end,
		GetPlayers = function() return {} end,
		RegisterEvent = function(event) table.insert(registered, event) end,
		CreateEventTimer = function() end,
		TriggerClientEvent = function() end,
	}
	dofile(SOURCE)
	print = function(line) table.insert(printed, tostring(line)) end
	io.open, os.remove, os.rename, os.execute = fakeOpen, fakeRemove, fakeRename, fakeExecute
	local move = upvalue(onInit, "moveFromCareerMP")
	assert(type(move) == "function", "moveFromCareerMP not found in onInit")
	return move
end

local function run(fn)
	local ok, err = pcall(fn)
	print, io.open, os.remove, os.rename, os.execute =
		realPrint, realOpen, realRemove, realRename, realExecute
	if not ok then error(err, 0) end
end

local function oldInstall()
	return {
		[OLD_PLUGIN] = "-- CareerMP",
		[OLD_CONFIG] = SETTINGS,
		[OLD_CLIENT_VERSION] = "{}",
		[OLD_SERVER_VERSION] = "{}",
		[OLD_CLIENT] = "careermp zip",
	}
end

-- What the last CareerMP plugin leaves: CareerMP's files plus Mileage's held client mod.
local function bridgedInstall()
	local existing = oldInstall()
	existing[HELD_CLIENT] = "held zip"
	return existing
end

local function careerMPKept(what)
	same(files[OLD_CLIENT], "careermp zip", what .. ": CareerMP client mod")
	same(files[OLD_PLUGIN], "-- CareerMP", what .. ": CareerMP plugin")
	same(files[NEW_CLIENT], nil, what .. ": no Mileage client mod offered")
end

local function registeredEvent(name)
	for _, event in ipairs(registered) do
		if event == name then return true end
	end
	return false
end

--== the full handoff ========================================================

test("a server moving from CareerMP keeps its settings, gets the held client mod and loses CareerMP", function()
	run(function()
		local move = loadPlugin(bridgedInstall())
		same(move(), "done", "result")
		same(files[NEW_CONFIG], SETTINGS, "settings copied byte for byte")
		same(files[NEW_CONFIG_TMP], nil, "no temporary settings left")
		same(files[OLD_CONFIG], SETTINGS, "old settings left for the owner")
		same(files[NEW_CLIENT], "held zip", "held client mod in place")
		same(files[HELD_CLIENT], nil, "no held copy left")
		same(files[SET_ASIDE], nil, "no set-aside CareerMP zip left")
		same(files[OLD_CLIENT], nil, "old client mod")
		same(files[OLD_PLUGIN], nil, "old plugin")
		same(files[OLD_CLIENT_VERSION], nil, "old client version")
		same(files[OLD_SERVER_VERSION], nil, "old server version")
		same(#fetched, 0, "nothing downloaded")
		same(countLines(printed, "copied the settings in " .. OLD_CONFIG), 1, "copy logged")
		same(countLines(printed, "removed the old client mod " .. OLD_CLIENT), 1, "client removal logged")
		same(countLines(printed, "the old settings stay in " .. OLD_CONFIG), 1, "leftover settings named")
	end)
end)

test("with no held client mod the handoff downloads Mileage's before removing CareerMP", function()
	run(function()
		local move = loadPlugin(oldInstall())
		same(move(), "done", "result")
		same(fetched[1], CLIENT_URL, "client mod downloaded")
		same(files[NEW_CLIENT], "mileage zip", "downloaded client mod in place")
		same(files[OLD_CLIENT], nil, "old client mod")
	end)
end)

test("an empty held client mod is downloaded again", function()
	run(function()
		local existing = bridgedInstall()
		existing[HELD_CLIENT] = ""
		local move = loadPlugin(existing)
		same(move(), "done", "result")
		same(#fetched, 1, "downloads")
		same(files[NEW_CLIENT], "mileage zip", "downloaded client mod in place")
	end)
end)

test("a Mileage client mod already in place is kept and the held copy dropped", function()
	run(function()
		local existing = bridgedInstall()
		existing[NEW_CLIENT] = "unpacked zip"
		local move = loadPlugin(existing)
		same(move(), "done", "result")
		same(files[NEW_CLIENT], "unpacked zip", "client mod in place kept")
		same(files[HELD_CLIENT], nil, "held copy dropped")
		same(#fetched, 0, "nothing downloaded")
	end)
end)

test("settings Mileage already has are never replaced by CareerMP's", function()
	run(function()
		local existing = bridgedInstall()
		existing[NEW_CONFIG] = '{"mine":true}'
		local move = loadPlugin(existing)
		same(move(), "done", "result")
		same(files[NEW_CONFIG], '{"mine":true}', "Mileage settings")
		same(countLines(printed, "copied the settings"), 0, "no copy")
	end)
end)

test("a server that never ran CareerMP changes nothing", function()
	run(function()
		local move = loadPlugin({[NEW_CONFIG] = "{}"})
		same(move(), "none", "result")
		same(#printed, 0, "nothing logged")
	end)
end)

test("only the old settings left behind are copied, with no restart", function()
	run(function()
		local move = loadPlugin({[OLD_CONFIG] = "{}"})
		same(move(), "none", "result")
		same(files[NEW_CONFIG], "{}", "settings copied")
	end)
end)

--== a failed settings copy ==================================================

test("a refused settings write stops the handoff with CareerMP as it was", function()
	run(function()
		local move = loadPlugin(bridgedInstall())
		refused[NEW_CONFIG_TMP] = true
		same(move(), "failed", "result")
		same(files[NEW_CONFIG], nil, "no Mileage settings")
		same(files[NEW_CONFIG_TMP], nil, "no temporary settings")
		careerMPKept("refused write")
		same(files[HELD_CLIENT], "held zip", "held client mod kept for the next start")
		same(countLines(printed, "could not copy the settings"), 1, "step logged")
	end)
end)

test("settings that read back changed are not kept, and CareerMP stays as it was", function()
	run(function()
		local move = loadPlugin(bridgedInstall())
		garbled[NEW_CONFIG_TMP] = true
		same(move(), "failed", "result")
		same(files[NEW_CONFIG], nil, "no Mileage settings")
		same(files[NEW_CONFIG_TMP], nil, "no temporary settings")
		careerMPKept("garbled copy")
		same(countLines(printed, "did not read back the same"), 1, "reason logged")
	end)
end)

test("a refused rename of the checked settings stops the handoff", function()
	run(function()
		local move = loadPlugin(bridgedInstall())
		refused[NEW_CONFIG] = true
		same(move(), "failed", "result")
		same(files[NEW_CONFIG], nil, "no Mileage settings")
		same(files[NEW_CONFIG_TMP], nil, "no temporary settings")
		careerMPKept("refused rename")
	end)
end)

--== a missing client mod and a failed removal ===============================

test("a failed client mod download removes nothing", function()
	run(function()
		local move = loadPlugin(oldInstall())
		served[CLIENT_URL] = nil
		same(move(), "failed", "result")
		careerMPKept("failed download")
		same(files[NEW_CONFIG], SETTINGS, "settings copied, so the next start keeps them")
		same(countLines(printed, "could not download Mileage's client mod"), 1, "step logged")
	end)
end)

test("a CareerMP client mod that cannot be moved stops the handoff", function()
	run(function()
		local move = loadPlugin(bridgedInstall())
		locked[OLD_CLIENT] = true
		same(move(), "failed", "result")
		careerMPKept("locked client mod")
		same(files[HELD_CLIENT], "held zip", "held client mod kept")
		same(countLines(printed, "could not remove " .. OLD_CLIENT), 1, "path logged")
	end)
end)

test("a CareerMP plugin that cannot be removed puts CareerMP.zip back and stops the handoff", function()
	run(function()
		local move = loadPlugin(bridgedInstall())
		locked[OLD_PLUGIN] = true
		same(move(), "failed", "result")
		careerMPKept("locked plugin")
		same(files[SET_ASIDE], nil, "no set-aside zip left")
		same(files[HELD_CLIENT], "held zip", "held client mod kept")
		same(countLines(printed, "could not remove " .. OLD_PLUGIN), 1, "path logged")
	end)
end)

--== leftovers once CareerMP.zip is gone =====================================

test("leftover CareerMP files with CareerMP.zip gone are cleaned up", function()
	run(function()
		local move = loadPlugin({
			[OLD_CLIENT_VERSION] = "{}",
			[SET_ASIDE] = "careermp zip",
			[NEW_CLIENT] = "mileage zip",
			[NEW_CONFIG] = "{}",
		})
		same(move(), "none", "result")
		same(files[OLD_CLIENT_VERSION], nil, "old client version")
		same(files[SET_ASIDE], nil, "set-aside zip")
		same(files[NEW_CLIENT], "mileage zip", "client mod kept")
	end)
end)

test("a held client mod left over is put in place when none is", function()
	run(function()
		local move = loadPlugin({[HELD_CLIENT] = "held zip", [NEW_CONFIG] = "{}"})
		same(move(), "none", "result")
		same(files[NEW_CLIENT], "held zip", "client mod in place")
	end)
end)

test("a leftover CareerMP plugin with CareerMP.zip gone is removed and asks for one restart", function()
	run(function()
		local move = loadPlugin({[OLD_PLUGIN] = "-- CareerMP", [NEW_CLIENT] = "mileage zip", [NEW_CONFIG] = "{}"})
		same(move(), "done", "result")
		same(files[OLD_PLUGIN], nil, "old plugin")
	end)
end)

test("a leftover CareerMP plugin that cannot be removed is reported and Mileage starts", function()
	run(function()
		local move = loadPlugin({[OLD_PLUGIN] = "-- CareerMP", [NEW_CLIENT] = "mileage zip", [NEW_CONFIG] = "{}"})
		locked[OLD_PLUGIN] = true
		same(move(), "none", "result")
		same(countLines(printed, "could not remove " .. OLD_PLUGIN), 1, "path logged")
	end)
end)

--== what onInit starts =====================================================

-- onInit with the settings file the handoff leaves (or a stored one): autoUpdate off so
-- no update check downloads anything.
local function init(existing, autoExit)
	loadPlugin(existing)
	ReadJson = function(path)
		if path == NEW_CONFIG and files[NEW_CONFIG] then
			return {client = {}, server = {autoUpdate = false, autoExit = autoExit}}
		end
	end
	local writes = 0
	WriteJson = function() writes = writes + 1; return true end
	onInit()
	return upvalue(tick, "willExit"), writes
end

test("after the handoff the server restarts once when autoExit is on, and starts nothing else", function()
	run(function()
		local willExit, writes = init(bridgedInstall(), true)
		same(willExit, true, "willExit")
		same(registeredEvent("onPlayerJoin"), false, "players left to CareerMP this start")
		expect(registeredEvent("tick"), "tick registered, so the restart happens")
		same(writes, 0, "settings written")
		same(countLines(printed, "restarting to finish the move"), 1, "restart logged")
	end)
end)

test("after the handoff the owner is asked to restart when autoExit is off", function()
	run(function()
		local willExit = init(bridgedInstall(), false)
		same(willExit, false, "willExit")
		same(#registered, 0, "events registered")
		same(countLines(printed, "restart the server to finish the move"), 1, "restart asked")
	end)
end)

test("with no settings at all the handoff restarts by default", function()
	run(function()
		local existing = bridgedInstall()
		existing[OLD_CONFIG] = nil
		loadPlugin(existing)
		ReadJson = function() end
		WriteJson = function() error("no settings may be written in a handoff start") end
		onInit()
		same(upvalue(tick, "willExit"), true, "willExit")
	end)
end)

test("a failed handoff starts nothing, writes no settings and never restarts", function()
	run(function()
		local existing = oldInstall()
		existing[OLD_CONFIG] = nil
		loadPlugin(existing)
		served[CLIENT_URL] = nil
		ReadJson = function() end
		local writes = 0
		WriteJson = function() writes = writes + 1; return true end
		onInit()
		same(upvalue(tick, "willExit"), false, "willExit")
		same(#registered, 0, "events registered")
		same(writes, 0, "settings written")
		same(files[NEW_CONFIG], nil, "no default settings")
		careerMPKept("failed handoff")
		same(countLines(printed, "CareerMP keeps serving players"), 1, "logged")
	end)
end)

test("a server with nothing from CareerMP starts normally without restarting", function()
	run(function()
		local willExit = init({[NEW_CONFIG] = "{}"}, true)
		same(willExit, false, "willExit")
		expect(registeredEvent("onPlayerJoin"), "Mileage handles players")
		same(countLines(printed, "Moving from CareerMP"), 0, "nothing logged")
	end)
end)
