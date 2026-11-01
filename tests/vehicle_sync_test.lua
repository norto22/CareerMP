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

--== two players and the server ==============================================
-- Each player runs the real enabler on their own stand-in game, the server runs the
-- real plugin, and messages between them queue until pump() delivers them.

local ENABLER = "Resources/Client/CareerMP/lua/ge/extensions/careerMPEnabler.lua"
local SERVER = "Resources/Server/CareerMP/careerMP.lua"

-- Payloads travel as text, like BeamMP's JSON: Lua table syntax read back with load.
local function encode(v)
	if type(v) == "table" then
		local parts = {}
		for k, val in pairs(v) do table.insert(parts, "[" .. encode(k) .. "]=" .. encode(val)) end
		table.sort(parts)
		return "{" .. table.concat(parts, ",") .. "}"
	elseif type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

local function decode(text)
	if type(text) ~= "string" then error("not text") end
	local chunk = (loadstring or load)("return " .. text)
	if not chunk then error("does not decode") end
	return chunk()
end

local function tryDecode(text)
	local ok, value = pcall(decode, text)
	if ok then return value end
	return nil
end

local world

-- Runs fn with the globals of player p's game.
local function as(p, fn, ...)
	MPVehicleGE, be, gameplay_traffic = p.MPVehicleGE, p.be, p.traffic
	worldReadyState = 2
	function TriggerServerEvent(name, data)
		table.insert(world.toServer, {from = p.id, name = name, data = data})
	end
	function AddEventHandler(name, fn) p.handlers[name] = fn end
	return fn(...)
end

local function newWorld()
	world = {players = {}, toServer = {}, toClients = {}, broadcasts = {}}
	logs = {}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	os.clockhp = function() return 0 end
	jsonEncode, jsonDecode = encode, tryDecode
	settings = {getValue = function() return nil end, setValue = function() end}
	extensions = {
		careerMP_compat = {report = function() end, targetGameVersion = "test", isMPSession = function() return true end},
		core_input_actionFilter = {setGroup = function() end, addAction = function() end},
	}
	MPConfig = {getNickname = function() return "player" end}
	Util = {JsonDecode = decode}
	MP = {
		CreateTimer = function() return {GetCurrent = function() return 0 end, Start = function() end} end,
		GetPlayers = function()
			local names = {}
			for id, p in pairs(world.players) do names[id] = p.name end
			return names
		end,
		IsPlayerConnected = function() return true end,
		GetPlayerName = function(id) return world.players[id] and world.players[id].name end,
		TriggerClientEventJson = function(target, event, data)
			local message = {target = target, event = event, data = encode(data), table = data}
			table.insert(world.toClients, message)
			if event == "rxCareerVehSync" then table.insert(world.broadcasts, message) end
		end,
		TriggerClientEvent = function(target, event, data)
			table.insert(world.toClients, {target = target, event = event, data = data})
		end,
	}
	local realPrint = print
	print = function() end
	dofile(SERVER)
	print = realPrint
	return world
end

local function addPlayer(id, name)
	local p = {id = id, name = name, vehicles = {}, objects = {}, trafficData = {}, handlers = {},
		playerVehicle = -1, serverRequests = {}}
	p.MPVehicleGE = {
		getVehicles = function() return p.vehicles end,
		isOwn = function(gid) local o = p.objects[gid]; return o ~= nil and o.owner == id end,
		getServerVehicleID = function(gid) local o = p.objects[gid]; return o and o.serverVehicleID end,
	}
	p.be = {
		getObjectByID = function(_, gid) return p.objects[gid] end,
		getPlayerVehicleID = function() return p.playerVehicle end,
	}
	p.traffic = {getTrafficData = function() return p.trafficData end}
	world.players[id] = p
	as(p, function()
		p.enabler = dofile(ENABLER)
		p.enabler.onExtensionLoaded()
		p.handlers.rxClientConfigUpdate(encode({remoteVehicleGhost = false, remoteUnicycleGhost = true,
			localUnicycleGhost = false, consoleEnabled = true, worldEditorEnabled = true}))
	end)
	return p
end

-- Delivers queued messages both ways until none are left.
local function pump()
	for _ = 1, 200 do
		if #world.toServer == 0 and #world.toClients == 0 then return end
		local toServer, toClients = world.toServer, world.toClients
		world.toServer, world.toClients = {}, {}
		for _, m in ipairs(toServer) do
			table.insert(world.players[m.from].serverRequests, m.name)
			local handler = _G[m.name]
			if handler then handler(m.from, m.data) end
		end
		for _, m in ipairs(toClients) do
			for id, p in pairs(world.players) do
				if m.target == -1 or m.target == id then
					local handler = p.handlers[m.event]
					if handler then as(p, handler, m.data) end
				end
			end
		end
	end
	error("messages never stopped")
end

-- A vehicle game id: the same number on every game, which keeps the tests readable.
local function gameId(owner, vid) return owner * 100 + vid + 1 end

-- Spawns owner's vehicle vid on every game, through the server's spawn event and each
-- game's spawn and ready hooks. fields: JBeam, isTraffic, isParked, ai (traffic data).
local function spawn(owner, vid, fields)
	fields = fields or {}
	local sid = owner .. "-" .. vid
	local gid = gameId(owner, vid)
	for id, p in pairs(world.players) do
		local veh = {owner = owner, serverVehicleID = sid, JBeam = fields.JBeam or "pickup", active = true}
		if id == owner then
			veh.isTraffic, veh.isParked = fields.isTraffic, fields.isParked
			if fields.ai ~= nil then p.trafficData[gid] = {isAi = fields.ai} end
		end
		function veh:setActive(on)
			local now = on == 1
			if now == self.active then return end
			self.active = now
			as(p, p.enabler.onVehicleActiveChanged, gid, now)
		end
		function veh:getActive() return self.active end
		function veh:queueLuaCommand() end
		function veh:setField() end
		p.objects[gid] = veh
		p.vehicles[sid] = {gameVehicleID = gid, jbeam = veh.JBeam, isLocal = id == owner}
	end
	onVehicleSpawnHandler(owner, vid, "")
	for _, p in pairs(world.players) do
		as(p, p.enabler.onVehicleSpawned, gid)
		as(p, p.enabler.onVehicleReady, gid)
	end
	pump()
	return gid
end

-- Runs each player's frame update for the given seconds, in half-second frames.
local function frames(p, seconds)
	for _ = 1, math.floor(seconds * 2 + 0.5) do as(p, p.enabler.onUpdate, 0.5, 0.5, 0.5) end
	pump()
end

local function nametag(p, sid) return p.vehicles[sid].hideNametag end

-- Me (player 0) and my friend (player 1), who drives car 1-0 and has a police car
-- (1-1) in road traffic and a parked car (1-2).
local function twoPlayers()
	newWorld()
	local me, friend = addPlayer(0, "Me"), addPlayer(1, "Friend")
	me.playerVehicle = spawn(0, 0)
	friend.playerVehicle = spawn(1, 0)
	spawn(1, 1, {JBeam = "fullsize", isTraffic = "true", ai = true})
	spawn(1, 2, {JBeam = "covet", isParked = "true"})
	return me, friend
end

--== traffic nametags ========================================================

test("my friend's police and parked cars carry no nametag on my game, the car they drive does", function()
	local me, friend = twoPlayers()
	frames(friend, 1.5)
	same(nametag(me, "1-0"), false, "the car my friend drives")
	same(nametag(me, "1-1"), true, "my friend's police car")
	same(nametag(me, "1-2"), true, "my friend's parked car")
end)
