-- Parking challenges on a server: another player's traffic and parked cars come from
-- their own game, which knows nothing about my challenge, so while my parking challenge
-- runs they are hidden on my game only (careerMP/parkingChallenge.lua and the vehicle
-- sync in careerMPEnabler.lua), and come back as their owner has them when it ends.
--
-- Two stand-in games run the real enabler against the real server plugin; messages
-- between them queue until pump() delivers them. The game's mission manager is played
-- by firing its hooks on every extension each game has loaded.

local ENABLER = "Resources/Client/CareerMP/lua/ge/extensions/careerMPEnabler.lua"
local PARKING = "Resources/Client/CareerMP/lua/ge/extensions/careerMP/parkingChallenge.lua"
local SERVER = "Resources/Server/CareerMP/careerMP.lua"

--== two stand-in games and the server =======================================

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

local world, logs

-- Runs fn with the globals of player p's game.
local function as(p, fn, ...)
	MPVehicleGE, be, gameplay_traffic = p.MPVehicleGE, p.be, p.traffic
	extensions, careerMPEnabler, FS = p.extensions, p.enabler, p.FS
	worldReadyState = 2
	function TriggerServerEvent(name, data)
		table.insert(world.toServer, {from = p.id, name = name, data = data})
	end
	function AddEventHandler(name, fn) p.handlers[name] = fn end
	return fn(...)
end

local function newWorld()
	world = {players = {}, toServer = {}, toClients = {}}
	logs = {}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	os.clockhp = function() return 0 end
	jsonEncode, jsonDecode = encode, tryDecode
	settings = {getValue = function() return nil end, setValue = function() end}
	MPConfig = {getNickname = function() return "player" end}
	Util = {JsonDecode = decode, JsonEncode = encode}
	world.now = 0
	MP = {
		CreateTimer = function() return {GetCurrent = function() return world.now end, Start = function() end} end,
		GetPlayers = function()
			local names = {}
			for id, p in pairs(world.players) do names[id] = p.name end
			return names
		end,
		IsPlayerConnected = function(id) return world.players[id] ~= nil end,
		GetPlayerName = function(id) return world.players[id] and world.players[id].name end,
		TriggerClientEvent = function(target, event, data)
			table.insert(world.toClients, {target = target, event = event, data = data})
		end,
	}
	local realPrint = print
	print = function() end
	dofile(SERVER)
	print = realPrint
end

-- The parking challenge extension, when the mod ships it.
local function loadParking()
	local file = io.open(PARKING, "r")
	if not file then return nil end
	file:close()
	return dofile(PARKING)
end

local function addPlayer(id, name)
	local p = {id = id, name = name, vehicles = {}, objects = {}, trafficData = {}, handlers = {},
		playerVehicle = -1, serverRequests = {}, files = {}}
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
	p.FS = {fileExists = function(_, path) return p.files[path] == true end}
	p.extensions = {
		careerMP_compat = {report = function() end, targetGameVersion = "test", isMPSession = function() return true end},
		core_input_actionFilter = {setGroup = function() end, addAction = function() end},
	}
	world.players[id] = p
	as(p, function()
		p.enabler = dofile(ENABLER)
		p.extensions.careerMPEnabler = p.enabler
		p.parking = loadParking()
		p.extensions.careerMP_parkingChallenge = p.parking
	end)
	as(p, function()
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
		function veh:setDynDataFieldbyName(name, _, value) self[name] = value end
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

-- Runs a player's frame update for the given seconds, in half-second frames.
local function frames(p, seconds)
	for _ = 1, math.floor(seconds * 2 + 0.5) do as(p, p.enabler.onUpdate, 0.5, 0.5, 0.5) end
	pump()
end

-- Fires a game hook on every extension player p's game has loaded, as the game does.
local function hook(p, name, ...)
	local args = {...}
	as(p, function()
		for _, ext in pairs(p.extensions) do
			local fn = type(ext) == "table" and rawget(ext, name)
			if type(fn) == "function" then fn((table.unpack or unpack)(args)) end
		end
	end)
	pump()
end

local function active(p, owner, vid) return p.objects[gameId(owner, vid)].active end

local function count(list, value)
	local n = 0
	for _, v in ipairs(list) do if v == value then n = n + 1 end end
	return n
end

local function listRequests(p) return count(p.serverRequests, "careerVehSyncRequested") end

-- Me (player 0) and my friend (player 1), who drives car 1-0 and has a police car (1-1)
-- in road traffic and a parked car (1-2). My friend's game has sent its traffic marks.
local function twoPlayers()
	newWorld()
	local me, friend = addPlayer(0, "Me"), addPlayer(1, "Friend")
	me.playerVehicle = spawn(0, 0)
	friend.playerVehicle = spawn(1, 0)
	spawn(1, 1, {JBeam = "fullsize", isTraffic = "true", ai = true})
	spawn(1, 2, {JBeam = "covet", isParked = "true"})
	frames(friend, 1)
	me.serverRequests, friend.serverRequests = {}, {}
	return me, friend
end

local PARKING_MISSION = {id = "west_coast_usa/parking/001", missionType = "parking",
	missionFolder = "/gameplay/missions/west_coast_usa/parking/001"}

--== the reported defect =====================================================

test("my friend's parked and police cars are hidden on my game when I start a parking challenge", function()
	local me, friend = twoPlayers()
	same(active(me, 1, 2), true, "my friend's parked car before the challenge")
	hook(me, "onAnyMissionChanged", "started", PARKING_MISSION, {})
	same(active(me, 1, 2), false, "my friend's parked car active")
	same(active(me, 1, 1), false, "my friend's police car active")
	same(active(me, 1, 0), true, "the car my friend drives")
	same(active(friend, 1, 1), true, "my friend's police car on their own game")
	same(active(friend, 1, 2), true, "my friend's parked car on their own game")
end)
