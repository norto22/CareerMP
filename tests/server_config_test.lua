-- Resources/Server/CareerMP/careerMP.lua: the config a new server writes, what an
-- existing config keeps, and the retired extra-traffic settings.

local SOURCE = "Resources/Server/CareerMP/careerMP.lua"

local printed, stored, written, sentToClients

-- prepareConfig is local to the plugin; onInit calls it, so it is one of onInit's
-- upvalues.
local function upvalue(fn, name)
	local i = 1
	while true do
		local n, v = debug.getupvalue(fn, i)
		if n == nil then return nil end
		if n == name then return v end
		i = i + 1
	end
end

-- Loads the real plugin with a stand-in BeamMP server.
local function loadPlugin()
	printed, written, sentToClients = {}, nil, nil
	MP = {
		CreateTimer = function() return {GetCurrent = function() return 0 end, Start = function() end} end,
		TriggerClientEventJson = function(player, event, data) sentToClients = {event = event, data = data} end,
	}
	dofile(SOURCE)
	local prepareConfig = upvalue(onInit, "prepareConfig")
	assert(type(prepareConfig) == "function", "prepareConfig not found in onInit")
	print = function(line) table.insert(printed, tostring(line)) end
	ReadJson = function() return stored end
	WriteJson = function(_, data) written = data; return true end
	return prepareConfig
end

local realPrint = print

local function run(fn)
	local ok, err = pcall(fn)
	print = realPrint
	if not ok then error(err, 0) end
end

-- The settings an existing server has today (the owner's file from this task's Discuss).
local function ownersConfig()
	return {
		client = {consoleEnabled = false, extraTrafficAmount = 80, extraTrafficEnabled = true,
			localUnicycleGhost = false, nativeDragSyncEnabled = true, parkedTrafficAmount = 20,
			parkedTrafficEnabled = true, remoteUnicycleGhost = true, remoteVehicleGhost = false,
			roadTrafficAmount = 0, roadTrafficEnabled = false, serverSaveName = "",
			serverSaveNameEnabled = false, serverSaveSuffix = "", simplifyRemoteVehicles = false,
			skipOtherPlayersVehicles = false, spawnVehicleIgnitionLevel = 0, trafficAllowMods = false,
			trafficSimpleVehicles = true, trafficSmartSelections = true, worldEditorEnabled = false},
		server = {allowTransactions = true, autoExit = true, autoUpdate = true, longWindowMax = 10000,
			longWindowSeconds = 300, sessionReceiveMax = 200000, sessionSendingMax = 100000,
			shortWindowMax = 1000, shortWindowSeconds = 30},
	}
end

test("a fresh install writes road traffic on at 6 and parked on at 8, without extra traffic", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = nil
		prepareConfig()
		expect(written ~= nil, "config written")
		same(written.client.roadTrafficEnabled, true, "roadTrafficEnabled")
		same(written.client.roadTrafficAmount, 6, "roadTrafficAmount")
		same(written.client.parkedTrafficEnabled, true, "parkedTrafficEnabled")
		same(written.client.parkedTrafficAmount, 8, "parkedTrafficAmount")
		same(written.client.extraTrafficAmount, nil, "extraTrafficAmount")
		same(written.client.extraTrafficEnabled, nil, "extraTrafficEnabled")
	end)
end)

test("the new defaults are within the 0 to 50 range the client accepts", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = nil
		prepareConfig()
		for _, key in ipairs({"roadTrafficAmount", "parkedTrafficAmount"}) do
			local v = written.client[key]
			expect(type(v) == "number" and v >= 0 and v <= 50 and v == math.floor(v), key .. " in range")
		end
	end)
end)

test("an existing config keeps the owner's traffic values and loses only extra traffic", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = ownersConfig()
		prepareConfig()
		expect(written ~= nil, "file rewritten")
		same(written.client.roadTrafficEnabled, false, "roadTrafficEnabled")
		same(written.client.roadTrafficAmount, 0, "roadTrafficAmount")
		same(written.client.parkedTrafficAmount, 20, "parkedTrafficAmount")
		same(written.client.extraTrafficAmount, nil, "extraTrafficAmount")
		same(written.client.extraTrafficEnabled, nil, "extraTrafficEnabled")
		same(countLines(printed, "[CareerMP] ---------- CareerMP Config client extraTrafficAmount removed: extra traffic was never used by the game"), 1, "removal line for the amount")
		same(countLines(printed, "[CareerMP] ---------- CareerMP Config client extraTrafficEnabled removed: extra traffic was never used by the game"), 1, "removal line for the switch")
		same(countLines(printed, "extraTraffic"), 2, "no other line names extra traffic")
	end)
end)

test("a config missing only the traffic settings gets the new defaults for them", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = ownersConfig()
		for _, key in ipairs({"roadTrafficEnabled", "roadTrafficAmount", "parkedTrafficEnabled", "parkedTrafficAmount"}) do
			stored.client[key] = nil
		end
		prepareConfig()
		same(written.client.roadTrafficEnabled, true, "roadTrafficEnabled")
		same(written.client.roadTrafficAmount, 6, "roadTrafficAmount")
		same(written.client.parkedTrafficEnabled, true, "parkedTrafficEnabled")
		same(written.client.parkedTrafficAmount, 8, "parkedTrafficAmount")
	end)
end)

test("an unknown setting in the server section is still called invalid", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = ownersConfig()
		stored.server.extraTrafficAmount = 5
		stored.client.somethingElse = 1
		prepareConfig()
		same(countLines(printed, "CareerMP Config server extraTrafficAmount is invalid, removing"), 1, "server section line")
		same(countLines(printed, "CareerMP Config client somethingElse is invalid, removing"), 1, "client section line")
		same(written.server.extraTrafficAmount, nil, "removed from server")
	end)
end)

test("a cleaned config is not rewritten on the next start", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = ownersConfig()
		prepareConfig()
		stored, written, printed = written, nil, {}
		prepareConfig()
		same(written, nil, "file written")
		same(countLines(printed, "removed:"), 0, "removal lines")
	end)
end)

test("SetConfig refuses the removed extra-traffic settings and still sets road traffic", function()
	run(function()
		local prepareConfig = loadPlugin()
		stored = ownersConfig()
		prepareConfig()
		stored, written, printed = written, nil, {}
		SetConfig({"client", "extraTrafficAmount", "10"})
		same(countLines(printed, "[CareerMP] ---------- Unknown key: client extraTrafficAmount"), 1, "unknown key line")
		same(written, nil, "file written for a refused key")
		SetConfig({"client", "roadTrafficEnabled", "true"})
		expect(written ~= nil, "file written")
		same(written.client.roadTrafficEnabled, true, "roadTrafficEnabled")
		same(sentToClients and sentToClients.event, "rxClientConfigUpdate", "players told")
	end)
end)

--== alive message ==========================================================

test("every second tick sends each connected player one alive message", function()
	run(function()
		loadPlugin()
		local sent = {}
		MP.GetPlayers = function() return {[0] = "Ann", [1] = "Bob", [2] = "Cy"} end
		MP.IsPlayerConnected = function(id) return id ~= 2 end
		MP.TriggerClientEvent = function(id, event, data) table.insert(sent, {id = id, event = event, data = data}) end
		tick()
		tick()
		local to = {}
		for _, s in ipairs(sent) do
			same(s.event, "rxCareerMPAlive", "event")
			same(s.data, "", "alive content")
			to[s.id] = (to[s.id] or 0) + 1
		end
		same(#sent, 2, "alive messages in two ticks")
		same(to[0], 1, "to player 0")
		same(to[1], 1, "to player 1")
		same(to[2], nil, "to the player who is not connected")
		tick()
		tick()
		same(#sent, 4, "messages after four ticks")
	end)
end)
