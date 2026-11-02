-- #82: the client files run on a Lua with no global unpack (Lua 5.2 and later), as they do
-- on the game's LuaJIT. Each file keeps its own `local unpack = table.unpack or unpack`.

local EXT = "Resources/Client/Mileage/lua/ge/extensions/"

local logs

-- Runs fn on a Lua where unpack lives only in table, the way Lua 5.2 and later have it.
-- A LuaJIT built without 5.2 compatibility has no table.unpack, so it is put there.
local function withoutUnpack(fn)
	local saved, savedTable = rawget(_G, "unpack"), table.unpack
	table.unpack = savedTable or saved
	unpack = nil
	local ok, result = pcall(fn)
	unpack, table.unpack = saved, savedTable
	if not ok then error(result, 0) end
	return result
end

-- Loads a client file on such a Lua.
local function loadWithoutUnpack(path)
	return withoutUnpack(function() return dofile(path) end)
end

local function setup()
	logs = {}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. tostring(msg)) end
	function setExtensionUnloadMode() end
	os.clockhp = os.clockhp or function() return 0 end
end

test("#82: the compat self check runs with no global unpack", function()
	setup()
	career_saveSystem, ui_apps, core_gamestate, core_groundMarkers, spawn, ui_topBar = nil, nil, nil, nil, nil, nil
	local compat = loadWithoutUnpack(EXT .. "mileage/compat.lua")
	withoutUnpack(function()
		same(compat.report(), false, "report with nothing present")
	end)
end)

test("#82: the purchase data wrapper passes results through with no global unpack", function()
	setup()
	local purchase = loadWithoutUnpack(EXT .. "mileage/purchaseInsurance.lua")
	withoutUnpack(function()
		local a, b = purchase.sendPurchaseDataToUi(function(x) return x, "second" end, "first")
		same(a, "first", "first result")
		same(b, "second", "second result")
	end)
end)

test("#82: the career patches' protected call passes results through with no global unpack", function()
	setup()
	MPVehicleGE, gameplay_traffic, core_vehicles = nil, nil, nil
	local patches = loadWithoutUnpack(EXT .. "mileage/careerPatches.lua")
	withoutUnpack(function()
		local ok, a, b = patches.withRemoteVehiclesProtected(function(x, y) return x + y, "done" end, 2, 3)
		same(ok, true, "protected call succeeded")
		same(a, 5, "first result")
		same(b, "done", "second result")
	end)
end)

-- Every client file that calls unpack declares its own before the first call, so a file
-- added later cannot rely on the global by accident.
test("#82: every client Lua file that calls unpack declares it locally first", function()
	local listing = io.popen('find Resources/Client/Mileage/lua -name "*.lua"')
	expect(listing, "could not list the client files")
	local checked = 0
	for path in listing:lines() do
		local file = assert(io.open(path, "r"))
		local text = file:read("*a")
		file:close()
		-- The first bare call: not table.unpack(...) and not part of a longer name.
		local firstCall
		for at in text:gmatch("()unpack%(") do
			local before = at > 1 and text:sub(at - 1, at - 1) or ""
			if not before:match("[%w_%.:]") then firstCall = at break end
		end
		if firstCall then
			checked = checked + 1
			local guard = text:find("local unpack = table.unpack or unpack", 1, true)
			expect(guard and guard < firstCall, path .. " calls unpack before declaring it locally")
		end
	end
	listing:close()
	expect(checked >= 5, "only " .. checked .. " files call unpack")
end)
