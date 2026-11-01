-- Damage between players: each player's game sends the dents of the cars it owns
-- (lua/vehicle/extensions/auto/careerMPDamage.lua and careerMP/damageSync.lua), the
-- server relays them from the car's owner only (careerMP.lua), and every other game
-- applies them to its copy of the car.
--
-- Two stand-in games and the real server plugin. Commands one side of a game queues for
-- the other (queueGameEngineLua, queueLuaCommand) run as Lua text, as the game runs them.

local VEHICLE = "Resources/Client/CareerMP/lua/vehicle/extensions/auto/careerMPDamage.lua"
local GE = "Resources/Client/CareerMP/lua/ge/extensions/careerMP/damageSync.lua"
local SERVER = "Resources/Server/CareerMP/careerMP.lua"

--== text, vectors and JSON ==================================================

local compile = loadstring or load

-- The JSON this feature sends is flat: string keys, numbers, strings and arrays.
local function jsonToLua(text)
	if type(text) ~= "string" then return nil end
	local luaText = text:gsub("%[", "{"):gsub("%]", "}"):gsub('"([%w_]+)"%s*:', '["%1"]=')
	local chunk = compile("return " .. luaText)
	if not chunk then return nil end
	local ok, value = pcall(chunk)
	if ok and type(value) == "table" then return value end
	return nil
end

local function luaToJson(value)
	if type(value) == "table" then
		local parts = {}
		if #value > 0 then
			for _, item in ipairs(value) do table.insert(parts, luaToJson(item)) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		for k, item in pairs(value) do table.insert(parts, '"' .. tostring(k) .. '":' .. luaToJson(item)) end
		return "{" .. table.concat(parts, ",") .. "}"
	elseif type(value) == "string" then
		return '"' .. value .. '"'
	end
	return tostring(value)
end

function vec3(x, y, z)
	if type(x) == "table" then return {x = x.x, y = x.y, z = x.z} end
	return {x = x or 0, y = y or 0, z = z or 0}
end

local function cross(a, b)
	return {x = a.y * b.z - a.z * b.y, y = a.z * b.x - a.x * b.z, z = a.x * b.y - a.y * b.x}
end

-- A point given in the car's own frame (right, forward, up from node 0), as a position
-- relative to the car in world directions, which is what obj:getNodePosition returns.
local function fromCarFrame(car, lx, ly, lz)
	local f, u = car.fwd, car.up
	local r = cross(f, u)
	local o = car.nodePos[0]
	return {x = o.x + r.x * lx + f.x * ly + u.x * lz, y = o.y + r.y * lx + f.y * ly + u.y * lz,
		z = o.z + r.z * lx + f.z * ly + u.z * lz}
end

local function toCarFrame(car, p)
	local f, u = car.fwd, car.up
	local r = cross(f, u)
	local o = car.nodePos[0]
	local d = {x = p.x - o.x, y = p.y - o.y, z = p.z - o.z}
	return d.x * r.x + d.y * r.y + d.z * r.z, d.x * f.x + d.y * f.y + d.z * f.z, d.x * u.x + d.y * u.y + d.z * u.z
end

--== a stand-in world ========================================================

local world, logs

-- Runs fn inside a car's vehicle Lua: obj, v, beamstate and the extension are its own.
local function inVehicle(car, fn, ...)
	obj, v, beamstate, careerMPDamage = car.obj, car.v, car.beamstate, car.ext
	return fn(...)
end

-- Runs fn with the globals of a game's game-engine Lua.
local function as(game, fn, ...)
	MPVehicleGE, be, gameplay_traffic = game.MPVehicleGE, game.be, game.traffic
	careerMP_damageSync = game.ge
	function TriggerServerEvent(name, data)
		table.insert(world.toServer, {from = game.id, name = name, data = data})
	end
	function AddEventHandler(name, fn) game.handlers[name] = fn end
	return fn(...)
end

local function newWorld()
	world = {games = {}, toServer = {}, toClients = {}, serverSent = {}}
	logs = {}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	jsonEncode, jsonDecode = luaToJson, jsonToLua
	Util = {JsonDecode = function(text)
		local value = jsonToLua(text)
		if value == nil then error("does not decode") end
		return value
	end, JsonEncode = luaToJson}
	MP = {
		CreateTimer = function() return {GetCurrent = function() return world.now or 0 end, Start = function() end} end,
		GetPlayers = function()
			local names = {}
			for id, g in pairs(world.games) do names[id] = "player" .. id end
			return names
		end,
		IsPlayerConnected = function() return true end,
		GetPlayerName = function(id) return "player" .. id end,
		TriggerClientEvent = function(target, event, data)
			table.insert(world.toClients, {target = target, event = event, data = data})
			table.insert(world.serverSent, {target = target, event = event, data = data})
		end,
		TriggerClientEventJson = function(target, event, data)
			table.insert(world.toClients, {target = target, event = event, data = luaToJson(data)})
		end,
	}
	local realPrint = print
	print = function() end
	dofile(SERVER)
	print = realPrint
	return world
end

local function addGame(id)
	local game = {id = id, cars = {}, objects = {}, vehicles = {}, handlers = {}, trafficData = {},
		geQueue = {}, playerVehicle = -1}
	game.MPVehicleGE = {
		getVehicles = function() return game.vehicles end,
		isOwn = function(gid) local c = game.cars[gid]; return c ~= nil and c.owner == id end,
		getServerVehicleID = function(gid) local c = game.cars[gid]; return c and c.sid end,
		getGameVehicleID = function(sid)
			for gid, c in pairs(game.cars) do if c.sid == sid then return gid end end
			return nil
		end,
	}
	game.be = {
		getObjectByID = function(_, gid) return game.objects[gid] end,
		getPlayerVehicleID = function() return game.playerVehicle end,
	}
	game.traffic = {getTrafficData = function() return game.trafficData end}
	world.games[id] = game
	as(game, function()
		game.ge = dofile(GE)
		careerMP_damageSync = game.ge
		if game.ge.onExtensionLoaded then game.ge.onExtensionLoaded() end
	end)
	return game
end

-- A car of `owner` ("<owner>-<vid>") on game: opts.beams beams between opts.nodes nodes,
-- every rest length 1, facing opts.fwd (default +y) with up +z.
local function addCar(game, owner, vid, opts)
	opts = opts or {}
	local gid = owner * 100 + vid + 1
	local nodeCount, beamCount = opts.nodes or 50, opts.beams or 60
	local car = {game = game, gid = gid, owner = owner, sid = owner .. "-" .. vid,
		restLen = {}, broken = {}, nodePos = {}, breakCalls = 0, deformCalls = 0, vehicleQueue = {},
		fwd = opts.fwd or {x = 0, y = 1, z = 0}, up = {x = 0, y = 0, z = 1}}
	local nodes, beams = {}, {}
	car.nodePos[0] = {x = 0.3, y = -0.2, z = 0.4}
	for cid = 0, nodeCount - 1 do
		nodes[cid] = {cid = cid}
		if cid > 0 then
			car.nodePos[cid] = fromCarFrame(car, (cid % 5) * 0.4 - 0.8, math.floor(cid / 5) * 0.4 - 2, (cid % 3) * 0.3)
		end
	end
	for cid = 0, beamCount - 1 do
		beams[cid] = {cid = cid, id1 = cid % nodeCount, id2 = (cid + 1) % nodeCount}
		car.restLen[cid] = 1
	end
	car.v = {data = {beams = beams, nodes = nodes, refNodes = {[0] = {ref = 0}}}}
	car.beamstate = {damage = 0, deformedBeams = {}}
	function car.beamstate.onBeamDeformed(cid, ratio)
		car.deformCalls = car.deformCalls + 1
		car.beamstate.deformedBeams[cid] = ratio
	end
	car.obj = {}
	function car.obj:getID() return gid end
	function car.obj:getBeamRestLength(cid) return car.restLen[cid] end
	function car.obj:setBeamLength(cid, len) car.restLen[cid] = len end
	function car.obj:beamIsBroken(cid) return car.broken[cid] == true end
	function car.obj:breakBeam(cid)
		car.breakCalls = car.breakCalls + 1
		car.broken[cid] = true
		car.beamstate.deformedBeams[cid] = 1
	end
	function car.obj:getNodePosition(cid) return vec3(car.nodePos[cid]) end
	function car.obj:setNodePosition(cid, p) car.nodePos[cid] = vec3(p) end
	function car.obj:getDirectionVector() return vec3(car.fwd) end
	function car.obj:getDirectionVectorUp() return vec3(car.up) end
	function car.obj:queueGameEngineLua(cmd) table.insert(game.geQueue, cmd) end

	-- The game-engine side of the same car.
	local veh = {JBeam = opts.jbeam or "pickup", isTraffic = opts.isTraffic, isParked = opts.isParked,
		resets = 0, pos = {x = 10, y = 20, z = 0.5}}
	function veh:queueLuaCommand(cmd) table.insert(car.vehicleQueue, cmd) end
	function veh:getID() return gid end
	function veh:getPosition() return vec3(self.pos) end
	function veh:getRotation() return {x = 0, y = 0, z = 0, w = 1} end
	function veh:setPositionRotation(...) self.resets = self.resets + 1; car.reset() end
	function veh:resetBrokenFlexMesh() end
	car.veh = veh

	-- What the game does to the car on a reset: pristine beams, no damage.
	function car.reset()
		for cid in pairs(car.restLen) do car.restLen[cid] = 1 end
		car.broken = {}
		car.beamstate.damage = 0
		car.beamstate.deformedBeams = {}
		if car.ext and car.ext.onReset then inVehicle(car, car.ext.onReset) end
	end

	game.cars[gid], game.objects[gid] = car, veh
	game.vehicles[car.sid] = {gameVehicleID = gid, jbeam = veh.JBeam, ownerID = owner}
	car.ext = inVehicle(car, dofile, VEHICLE)
	inVehicle(car, function()
		if car.ext.onExtensionLoaded then car.ext.onExtensionLoaded() end
	end)
	return car
end

-- Delivers everything queued: vehicle Lua to game-engine Lua, game to server, server to
-- games, game-engine Lua to vehicle Lua, until nothing is left.
local function pump()
	for _ = 1, 500 do
		local busy = false
		for _, game in pairs(world.games) do
			local queue = game.geQueue
			game.geQueue = {}
			for _, cmd in ipairs(queue) do
				busy = true
				as(game, function() assert(compile(cmd))() end)
			end
			for _, car in pairs(game.cars) do
				local vq = car.vehicleQueue
				car.vehicleQueue = {}
				for _, cmd in ipairs(vq) do
					busy = true
					inVehicle(car, function() assert(compile(cmd))() end)
				end
			end
		end
		local toServer, toClients = world.toServer, world.toClients
		world.toServer, world.toClients = {}, {}
		for _, m in ipairs(toServer) do
			busy = true
			local handler = _G[m.name]
			if handler then handler(m.from, m.data) end
		end
		for _, m in ipairs(toClients) do
			busy = true
			for id, game in pairs(world.games) do
				if m.target == -1 or m.target == id then
					local handler = game.handlers[m.event]
					if handler then as(game, handler, m.data) end
				end
			end
		end
		if not busy then return end
	end
	error("messages never stopped")
end

-- Runs every game and car for `seconds`, in quarter-second frames.
local function step(seconds)
	local frames = math.floor(seconds / 0.25 + 0.5)
	for _ = 1, frames do
		world.now = (world.now or 0) + 0.25
		for _, game in pairs(world.games) do
			if game.ge.onUpdate then as(game, game.ge.onUpdate, 0.25, 0.25, 0.25) end
			for _, car in pairs(game.cars) do
				if car.ext.updateGFX then inVehicle(car, car.ext.updateGFX, 0.25) end
			end
		end
		pump()
	end
end

-- Player 0 owns car "0-0"; player 1's game has its copy, facing another way.
local function twoGames(opts)
	opts = opts or {}
	newWorld()
	local owners, copies = addGame(0), addGame(1)
	local owner = addCar(owners, 0, 0, opts)
	local copy = addCar(copies, 0, 0, {nodes = opts.nodes, beams = opts.beams, fwd = {x = 1, y = 0, z = 0}})
	owners.playerVehicle = owner.gid
	return owner, copy, owners, copies
end

-- A dent on the owner's car: beam cid shortened to len, its first node moved by `shift`
-- in the car's own frame, and the game's damage total raised.
local function dent(car, cid, len, shift)
	car.restLen[cid] = len
	car.beamstate.deformedBeams[cid] = 0.3
	car.beamstate.damage = car.beamstate.damage + 100
	if shift then
		local node = car.v.data.beams[cid].id1
		local lx, ly, lz = toCarFrame(car, car.nodePos[node])
		car.nodePos[node] = fromCarFrame(car, lx + shift[1], ly + shift[2], lz + shift[3])
	end
end

--== a dent reaches the copy ================================================

test("a dent on the owner's car reaches the other player's copy", function()
	local owner, copy = twoGames()
	step(2.5)
	dent(owner, 7, 0.8)
	step(1.5)
	same(copy.restLen[7], 0.8, "the copy's beam 7")
end)
