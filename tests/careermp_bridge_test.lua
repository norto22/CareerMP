-- Resources/Server/CareerMP/careerMP.lua: the last CareerMP plugin, which CareerMP 0.2.0
-- servers update to. It installs the Mileage plugin and restarts into it, keeps running
-- as CareerMP when that fails, and stays off once Mileage is installed.

local SOURCE = "Resources/Server/CareerMP/careerMP.lua"

local RAW = "https://raw.githubusercontent.com/norto22/Mileage/main/"
local PLUGIN_URL = RAW .. "Resources/Server/Mileage/mileage.lua"
local VERSION_URL = RAW .. "Resources/Server/Mileage/versions/server.json"
local PLUGIN = "Resources/Server/Mileage/mileage.lua"
local SERVER_VERSION = "Resources/Server/Mileage/versions/server.json"
local OLD_CONFIG = "Resources/Server/CareerMP/config/config.json"

local function upvalue(fn, name)
	local i = 1
	while true do
		local n, v = debug.getupvalue(fn, i)
		if n == nil then return nil end
		if n == name then return v end
		i = i + 1
	end
end

-- Version files travel as Lua table text, decoded by the stand-in Util.JsonDecode.
local function decode(text)
	local chunk = (loadstring or load)("return " .. tostring(text))
	if not chunk then return nil end
	local ok, value = pcall(chunk)
	if ok then return value end
end

local realPrint, realOpen, realRemove, realRename, realExecute =
	print, io.open, os.remove, os.rename, os.execute

local files, dirs, remote, fetched, registered, printed, writtenJson

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
	local parts = {}
	return {
		write = function(_, text) table.insert(parts, text) end,
		close = function() files[path] = table.concat(parts) end,
	}
end

local function fakeRemove(path)
	if files[path] == nil then return nil, path .. ": No such file or directory" end
	files[path] = nil
	return true
end

local function fakeRename(from, to)
	if files[from] == nil then return nil, from .. ": No such file or directory" end
	files[to], files[from] = files[from], nil
	return true
end

-- wget -q -O <path> <url>: serves remote[url], or fails like wget on a missing file.
local function fakeExecute(command)
	local path, url = command:match("^wget %-q %-O (%S+) (%S+)$")
	assert(path, "unexpected command: " .. command)
	table.insert(fetched, url)
	local dir = path:match("(.+)/[^/]+$")
	if remote[url] == nil or (dir and not dirs[dir]) then return 8 end
	files[path] = remote[url]
	return 0
end

local function start(existing, config, served)
	files, dirs, remote, fetched, registered, printed, writtenJson = {}, {}, served or {}, {}, {}, {}, {}
	for path, data in pairs(existing or {}) do files[path] = data end
	for _, dir in ipairs({"Resources/Server/CareerMP", "Resources/Server/CareerMP/versions",
		"Resources/Server/CareerMP/config", "Resources/Client"}) do
		dirs[dir] = true
	end
	Util = {
		JsonEncode = function() return "{}" end,
		JsonDecode = decode,
	}
	FS = {
		Exists = function(path) return files[path] ~= nil or dirs[path] == true end,
		IsDirectory = function(path) return dirs[path] == true end,
		CreateDirectory = function(path) dirs[path] = true end,
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
	ReadJson = function(path)
		if path == OLD_CONFIG then return config end
	end
	WriteJson = function(path, data) writtenJson[path] = data; return true end
	onInit()
	-- tick is what exits the server when willExit is set.
	return upvalue(tick, "willExit")
end

local function run(fn)
	local ok, err = pcall(fn)
	print, io.open, os.remove, os.rename, os.execute =
		realPrint, realOpen, realRemove, realRename, realExecute
	if not ok then error(err, 0) end
end

local function config(autoUpdate, autoExit)
	return {client = {}, server = {autoUpdate = autoUpdate, autoExit = autoExit}}
end

local function mileageServed(lineage)
	return {
		[VERSION_URL] = string.format('{major = 0, minor = 3, revision = 0, lineage = %q}', lineage or "norto22/Mileage"),
		[PLUGIN_URL] = "-- Mileage",
	}
end

local function registeredEvent(name)
	for _, event in ipairs(registered) do
		if event == name then return true end
	end
	return false
end

test("a CareerMP server installs the Mileage plugin and restarts into it", function()
	run(function()
		same(start(nil, config(true, true), mileageServed()), true, "willExit")
		same(files[PLUGIN], "-- Mileage", "Mileage plugin")
		expect(writtenJson[SERVER_VERSION], "Mileage server version written")
		same(writtenJson[SERVER_VERSION].lineage, "norto22/Mileage", "version lineage")
		same(files["Resources/Server/Mileage/mileage.lua.download"], nil, "no download left behind")
		same(files["Resources/Server/CareerMP/versions/.remote.json"], nil, "no version scratch left behind")
		same(countLines(printed, "installed Mileage 0.3.0 in Resources/Server/Mileage/"), 1, "install logged")
		same(countLines(printed, "restarting into Mileage"), 1, "restart logged")
	end)
end)

test("the move fetches nothing but Mileage's version and plugin", function()
	run(function()
		start(nil, config(true, true), mileageServed())
		same(#fetched, 2, "downloads")
		same(fetched[1], VERSION_URL, "version first")
		same(fetched[2], PLUGIN_URL, "then the plugin")
	end)
end)

test("with autoExit off the owner is asked to restart", function()
	run(function()
		same(start(nil, config(true, false), mileageServed()), false, "willExit")
		same(files[PLUGIN], "-- Mileage", "Mileage plugin")
		same(countLines(printed, "restart the server to finish the move"), 1, "restart asked")
	end)
end)

test("when Mileage's version cannot be fetched the server keeps running as CareerMP", function()
	run(function()
		same(start(nil, config(true, true), {}), false, "willExit")
		same(files[PLUGIN], nil, "no Mileage plugin")
		expect(registeredEvent("onPlayerJoin"), "CareerMP still handles players")
		same(countLines(printed, "staying on CareerMP until the next start"), 1, "failure logged")
	end)
end)

test("when the plugin download fails nothing is installed and CareerMP keeps running", function()
	run(function()
		local served = mileageServed()
		served[PLUGIN_URL] = nil
		same(start(nil, config(true, true), served), false, "willExit")
		same(files[PLUGIN], nil, "no Mileage plugin")
		same(writtenJson[SERVER_VERSION], nil, "no Mileage version")
		same(files["Resources/Server/Mileage/mileage.lua.download"], nil, "no download left behind")
		expect(registeredEvent("onPlayerJoin"), "CareerMP still handles players")
	end)
end)

test("an empty plugin download is not installed", function()
	run(function()
		local served = mileageServed()
		served[PLUGIN_URL] = ""
		same(start(nil, config(true, true), served), false, "willExit")
		same(files[PLUGIN], nil, "no Mileage plugin")
	end)
end)

test("a Mileage version from another lineage is refused", function()
	run(function()
		same(start(nil, config(true, true), mileageServed("someone/Else")), false, "willExit")
		same(files[PLUGIN], nil, "no Mileage plugin")
		same(#fetched, 1, "plugin never fetched")
		same(countLines(printed, "Moving to Mileage REFUSED"), 1, "refusal logged")
	end)
end)

test("with autoUpdate off nothing is fetched", function()
	run(function()
		same(start(nil, config(false, true), mileageServed()), false, "willExit")
		same(#fetched, 0, "downloads")
		same(files[PLUGIN], nil, "no Mileage plugin")
	end)
end)

test("once Mileage is installed this plugin stays off", function()
	run(function()
		same(start({[PLUGIN] = "-- Mileage"}, config(true, true), mileageServed()), false, "willExit")
		same(#registered, 0, "events registered")
		same(#fetched, 0, "downloads")
		same(countLines(printed, "this old plugin stays off"), 1, "logged")
	end)
end)
