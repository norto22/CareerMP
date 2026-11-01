-- Resources/Server/Mileage/mileage.lua: moving a server from CareerMP, the mod's name
-- before Mileage. The old settings come across, the old client mod and plugin go, and the
-- server restarts once when it removed something.

local SOURCE = "Resources/Server/Mileage/mileage.lua"

local OLD_PLUGIN = "Resources/Server/CareerMP/careerMP.lua"
local OLD_CONFIG = "Resources/Server/CareerMP/config/config.json"
local OLD_CLIENT_VERSION = "Resources/Server/CareerMP/versions/client.json"
local OLD_SERVER_VERSION = "Resources/Server/CareerMP/versions/server.json"
local OLD_CLIENT = "Resources/Client/CareerMP.zip"
local NEW_CONFIG = "Resources/Server/Mileage/config/config.json"

local function upvalue(fn, name)
	local i = 1
	while true do
		local n, v = debug.getupvalue(fn, i)
		if n == nil then return nil end
		if n == name then return v end
		i = i + 1
	end
end

local realPrint, realOpen, realRemove = print, io.open, os.remove

-- An in-memory file system behind FS, io.open and os.remove. locked paths refuse removal.
local files, dirs, locked, printed

local function fakeOpen(path, mode)
	if mode:sub(1, 1) == "r" then
		if files[path] == nil then return nil, path .. ": No such file or directory" end
		local data = files[path]
		return {read = function() return data end, close = function() end}
	end
	local dir = path:match("(.+)/[^/]+$")
	if dir and not dirs[dir] then return nil, path .. ": No such file or directory" end
	local parts = {}
	return {
		write = function(_, text) table.insert(parts, text) end,
		close = function() files[path] = table.concat(parts) end,
	}
end

local function fakeRemove(path)
	if files[path] == nil or locked[path] then return nil, path .. ": cannot remove" end
	files[path] = nil
	return true
end

local function loadPlugin(existing)
	files, dirs, locked, printed = {}, {}, {}, {}
	for path, data in pairs(existing or {}) do
		files[path] = data
		local dir = path:match("(.+)/[^/]+$")
		while dir do
			dirs[dir] = true
			dir = dir:match("(.+)/[^/]+$")
		end
	end
	Util = {JsonEncode = function() return "{}" end}
	FS = {
		Exists = function(path) return files[path] ~= nil or dirs[path] == true end,
		IsDirectory = function(path) return dirs[path] == true end,
		CreateDirectory = function(path) dirs[path] = true end,
	}
	MP = {
		CreateTimer = function() return {GetCurrent = function() return 0 end, Start = function() end} end,
		GetPlayers = function() return {} end,
		RegisterEvent = function() end,
		CreateEventTimer = function() end,
		TriggerClientEvent = function() end,
	}
	dofile(SOURCE)
	print = function(line) table.insert(printed, tostring(line)) end
	io.open, os.remove = fakeOpen, fakeRemove
	local move = upvalue(onInit, "moveFromCareerMP")
	assert(type(move) == "function", "moveFromCareerMP not found in onInit")
	return move
end

local function run(fn)
	local ok, err = pcall(fn)
	print, io.open, os.remove = realPrint, realOpen, realRemove
	if not ok then error(err, 0) end
end

local function oldInstall()
	return {
		[OLD_PLUGIN] = "-- CareerMP",
		[OLD_CONFIG] = '{"server":{"autoExit":false}}',
		[OLD_CLIENT_VERSION] = "{}",
		[OLD_SERVER_VERSION] = "{}",
		[OLD_CLIENT] = "zip",
	}
end

test("a server moving from CareerMP keeps its settings and loses the old mod and plugin", function()
	run(function()
		local move = loadPlugin(oldInstall())
		same(move(), true, "restart needed")
		same(files[NEW_CONFIG], '{"server":{"autoExit":false}}', "settings copied")
		same(files[OLD_CONFIG], '{"server":{"autoExit":false}}', "old settings left for the owner")
		same(files[OLD_CLIENT], nil, "old client mod")
		same(files[OLD_PLUGIN], nil, "old plugin")
		same(files[OLD_CLIENT_VERSION], nil, "old client version")
		same(files[OLD_SERVER_VERSION], nil, "old server version")
		same(countLines(printed, "copied the settings in " .. OLD_CONFIG), 1, "copy logged")
		same(countLines(printed, "removed the old client mod " .. OLD_CLIENT), 1, "client removal logged")
		same(countLines(printed, "the old settings stay in " .. OLD_CONFIG), 1, "leftover settings named")
	end)
end)

test("settings Mileage already has are never replaced by CareerMP's", function()
	run(function()
		local existing = oldInstall()
		existing[NEW_CONFIG] = '{"mine":true}'
		local move = loadPlugin(existing)
		move()
		same(files[NEW_CONFIG], '{"mine":true}', "Mileage settings")
		same(countLines(printed, "copied the settings"), 0, "no copy")
	end)
end)

test("a server that never ran CareerMP changes nothing and does not restart", function()
	run(function()
		local move = loadPlugin({[NEW_CONFIG] = "{}"})
		same(move(), false, "restart needed")
		same(#printed, 0, "nothing logged")
	end)
end)

test("only the old settings left behind need no restart", function()
	run(function()
		local move = loadPlugin({[OLD_CONFIG] = "{}"})
		same(move(), false, "restart needed")
		same(files[NEW_CONFIG], "{}", "settings copied")
	end)
end)

test("an old client mod that cannot be removed is reported, and the plugin is still removed", function()
	run(function()
		local move = loadPlugin(oldInstall())
		locked[OLD_CLIENT] = true
		same(move(), true, "restart needed for the removed plugin")
		same(files[OLD_CLIENT], "zip", "old client mod kept")
		same(files[OLD_PLUGIN], nil, "old plugin")
		same(countLines(printed, "could not remove " .. OLD_CLIENT), 1, "failure logged")
	end)
end)

test("the old client mod alone is removed and asks for a restart", function()
	run(function()
		local move = loadPlugin({[OLD_CLIENT] = "zip"})
		same(move(), true, "restart needed")
		same(files[OLD_CLIENT], nil, "old client mod")
	end)
end)

-- onInit with a stored config: autoUpdate off so no download is attempted.
local function init(existing, autoExit)
	loadPlugin(existing)
	ReadJson = function(path)
		if path == NEW_CONFIG then
			return {client = {}, server = {autoUpdate = false, autoExit = autoExit}}
		end
	end
	WriteJson = function() return true end
	onInit()
	return upvalue(onInit, "willExit")
end

test("after removing CareerMP the server restarts when autoExit is on", function()
	run(function()
		same(init(oldInstall(), true), true, "willExit")
		same(countLines(printed, "restarting to finish the move"), 1, "restart logged")
	end)
end)

test("after removing CareerMP the owner is asked to restart when autoExit is off", function()
	run(function()
		same(init(oldInstall(), false), false, "willExit")
		same(countLines(printed, "restart the server to finish the move"), 1, "restart asked")
	end)
end)

test("a server with nothing from CareerMP starts without restarting", function()
	run(function()
		same(init({[NEW_CONFIG] = "{}"}, true), false, "willExit")
		same(countLines(printed, "Moving from CareerMP"), 0, "nothing logged")
	end)
end)
