-- Vehicle sync between players: a mission start hides the starter's traffic instead of
-- deleting it (careerMP/traffic.lua), traffic and parked cars carry no nametag, and a
-- hide, show or spawn sends one small update (careerMPEnabler.lua and the server plugin).

local TRAFFIC = "Resources/Client/CareerMP/lua/ge/extensions/careerMP/traffic.lua"
local COMPAT = "Resources/Client/CareerMP/lua/ge/extensions/careerMP/compat.lua"

--== a stand-in game =========================================================

local logs

-- A vehicle the stand-in game holds: setActive and delete are recorded on it.
local function newVehicle(objects, id, fields)
	local veh = {id = id, JBeam = "pickup", active = true, deleted = false}
	for k, v in pairs(fields or {}) do veh[k] = v end
	function veh:setActive(on) self.active = on == 1 end
	function veh:getActive() return self.active end
	function veh:delete() self.deleted = true; objects[self.id] = nil end
	objects[id] = veh
	return veh
end

-- The starter's game: car 1 driven by the player, 2 and 3 AI road traffic (3 a police
-- car), 4 and 5 parked cars, 6 a car of the player's own that is not traffic. The
-- game's freeze and unfreeze do what 0.39.4.0's mission manager relies on: with
-- despawnVehicles they delete every traffic and parked car except exceptVehicleId, and
-- with respawnVehicles they spawn those again as new vehicles.
local function newGame()
	local game = {objects = {}, nextId = 100, calls = {}}
	local objects = game.objects
	newVehicle(objects, 1)
	newVehicle(objects, 2, {JBeam = "covet", isTraffic = "true"})
	newVehicle(objects, 3, {JBeam = "fullsize", isTraffic = "true"})
	newVehicle(objects, 4, {JBeam = "vivace", isParked = "true"})
	newVehicle(objects, 5, {JBeam = "etk800", isParked = "true"})
	newVehicle(objects, 6, {JBeam = "bastion"})
	game.trafficData = {[1] = {isAi = false}, [2] = {isAi = true}, [3] = {isAi = true}}
	game.parked = {4, 5}

	be = {getObjectByID = function(_, id) return objects[id] end}

	local traffic, parking = {}, {}
	function traffic.getTrafficData() return game.trafficData end
	function parking.getParkedCarsList() return game.parked end

	function traffic.freezeState(options)
		table.insert(game.calls, {"freeze", options})
		options = options or {}
		local stash = {}
		for id, entry in pairs(game.trafficData) do
			local obj = objects[id]
			if obj and id ~= options.exceptVehicleId and (entry.isAi or obj.isTraffic == "true") then
				table.insert(stash, id)
			end
		end
		for _, id in ipairs(game.parked) do
			if objects[id] and id ~= options.exceptVehicleId then table.insert(stash, id) end
		end
		local data = {ids = stash}
		-- The game stops traffic and parking: its own lists are cleared.
		game.trafficData, game.parked = {}, {}
		if options.despawnVehicles then
			for _, id in ipairs(stash) do objects[id]:delete() end
		end
		return data, {police = true}, {parking = true}
	end

	function traffic.unfreezeState(trafficData, policeData, parkingData, options)
		table.insert(game.calls, {"unfreeze", options})
		options = options or {}
		game.respawned = 0
		if options.respawnVehicles and trafficData then
			for _ in ipairs(trafficData.ids) do
				game.nextId = game.nextId + 1
				newVehicle(objects, game.nextId)
				game.respawned = game.respawned + 1
			end
		end
	end

	gameplay_traffic, gameplay_parking = traffic, parking
	return game
end

-- A fresh traffic module on a fresh stand-in game, on a server unless opts.mp is false.
local function setupTraffic(opts)
	opts = opts or {}
	logs = {}
	local mp = opts.mp ~= false
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	os.clockhp = function() return 0 end
	MPCoreNetwork = {isMPSession = function() return mp end}
	extensions = {careerMP_compat = dofile(COMPAT)}
	careerMPEnabler = {getClientConfig = function() return {roadTrafficEnabled = true, roadTrafficAmount = 6,
		parkedTrafficEnabled = true, parkedTrafficAmount = 8} end}
	career_modules_playerDriving = {
		restoreTrafficAfterTutorialPhase = function() end,
		setTrafficAfterTutorial = function() end,
	}
	local game = newGame()
	local module = dofile(TRAFFIC)
	return module, game
end

-- What the game's mission manager does on a mission start and end.
local function missionStart()
	local t, p, k = gameplay_traffic.freezeState({despawnVehicles = true, exceptVehicleId = 1})
	return {t, p, k}
end

local function missionEnd(stashed)
	gameplay_traffic.unfreezeState(stashed[1], stashed[2], stashed[3], {respawnVehicles = true})
end

--== a mission start on a server =============================================

test("a mission start on a server hides the starter's traffic and parked cars instead of deleting them", function()
	local module, game = setupTraffic()
	module.onCareerActive(true)
	missionStart()
	for id = 2, 5 do
		local veh = game.objects[id]
		expect(veh ~= nil, "car " .. id .. " deleted")
		same(veh.active, false, "car " .. id .. " active")
	end
	same(game.objects[1].active, true, "the car the player drives")
	same(game.objects[6].active, true, "the player's own car that is not traffic")
end)

test("a mission end on a server shows the hidden cars again and spawns none", function()
	local module, game = setupTraffic()
	module.onCareerActive(true)
	local stashed = missionStart()
	missionEnd(stashed)
	for id = 2, 5 do
		local veh = game.objects[id]
		expect(veh ~= nil, "car " .. id .. " deleted")
		same(veh.active, true, "car " .. id .. " active")
	end
	same(game.respawned, 0, "cars spawned again")
end)

test("the game's freeze and unfreeze are told to keep the cars, with the mission's other options", function()
	local module, game = setupTraffic()
	module.onCareerActive(true)
	missionEnd(missionStart())
	local freeze, unfreeze = game.calls[1], game.calls[2]
	same(freeze[1], "freeze", "first call")
	same(freeze[2].despawnVehicles, false, "despawnVehicles passed to the game")
	same(freeze[2].exceptVehicleId, 1, "exceptVehicleId passed to the game")
	same(unfreeze[1], "unfreeze", "second call")
	same(unfreeze[2].respawnVehicles, false, "respawnVehicles passed to the game")
end)

test("the log says how many cars a mission start hid and its end showed again", function()
	local module = setupTraffic()
	module.onCareerActive(true)
	missionEnd(missionStart())
	same(countLines(logs, "mission start: 4 traffic and parked cars hidden instead of deleted"), 1, "hide line")
	same(countLines(logs, "mission end: 4 of 4 hidden traffic and parked cars shown again"), 1, "restore line")
end)

test("a hidden car deleted during the mission is skipped at its end", function()
	local module, game = setupTraffic()
	module.onCareerActive(true)
	local stashed = missionStart()
	game.objects[4]:delete()
	missionEnd(stashed)
	same(game.objects[5].active, true, "car 5 shown")
	same(countLines(logs, "mission end: 3 of 4 hidden traffic and parked cars shown again"), 1, "restore line")
end)

test("a car pooled away before the mission stays hidden after it", function()
	local module, game = setupTraffic()
	game.objects[2].active = false
	module.onCareerActive(true)
	missionEnd(missionStart())
	same(game.objects[2].active, false, "pooled car 2")
	same(game.objects[3].active, true, "car 3")
end)

test("a freeze that does not ask to delete traffic is left to the game, logged once", function()
	local module, game = setupTraffic()
	module.onCareerActive(true)
	gameplay_traffic.freezeState({exceptVehicleId = 1})
	gameplay_traffic.freezeState()
	same(game.calls[1][2].despawnVehicles, nil, "options passed unchanged")
	same(game.calls[2][2], nil, "no options passed unchanged")
	for id = 2, 5 do same(game.objects[id].active, true, "car " .. id .. " left showing") end
	same(countLines(logs, "the game froze traffic without asking to delete it"), 1, "log lines")
	gameplay_traffic.unfreezeState({ids = {}}, nil, nil, {respawnVehicles = true})
	same(game.calls[3][2].respawnVehicles, true, "an unfreeze with nothing hidden is the game's own")
end)

test("off a server the game's freeze and unfreeze are never replaced", function()
	local module, game = setupTraffic({mp = false})
	local freeze, unfreeze = gameplay_traffic.freezeState, gameplay_traffic.unfreezeState
	module.onCareerActive(true)
	same(gameplay_traffic.freezeState, freeze, "freezeState")
	same(gameplay_traffic.unfreezeState, unfreeze, "unfreezeState")
	missionStart()
	same(game.objects[2], nil, "the game deletes traffic as before")
end)

test("a missing freeze or unfreeze is warned about once and the game is left alone", function()
	local module = setupTraffic()
	gameplay_traffic.unfreezeState = nil
	local freeze = gameplay_traffic.freezeState
	module.onCareerActive(true)
	module.onCareerActive(true)
	same(gameplay_traffic.freezeState, freeze, "freezeState left alone")
	same(countLines(logs, "gameplay_traffic.unfreezeState missing"), 1, "warnings")
end)

test("leaving the server or unloading puts the game's functions back", function()
	for _, hook in ipairs({"onBeamMPServerLeave", "onExtensionUnloaded"}) do
		local module = setupTraffic()
		local freeze, unfreeze = gameplay_traffic.freezeState, gameplay_traffic.unfreezeState
		module.onCareerActive(true)
		expect(gameplay_traffic.freezeState ~= freeze, hook .. ": installed")
		module[hook]()
		same(gameplay_traffic.freezeState, freeze, hook .. ": freezeState")
		same(gameplay_traffic.unfreezeState, unfreeze, hook .. ": unfreezeState")
	end
end)

test("leaving mid-mission shows the hidden cars again", function()
	local module, game = setupTraffic()
	module.onCareerActive(true)
	missionStart()
	module.onBeamMPServerLeave()
	for id = 2, 5 do same(game.objects[id].active, true, "car " .. id) end
end)

test("a second career start installs once, and a reloaded traffic module gets it again", function()
	local module, game = setupTraffic()
	module.onCareerActive(true)
	module.onCareerActive(true)
	missionEnd(missionStart())
	same(#game.calls, 2, "game calls through a single replacement")
	newGame()
	module.onCareerActive(true)
	missionStart()
	same(countLines(logs, "mission start: 4 traffic and parked cars hidden"), 2, "hidden on the reloaded module")
end)
