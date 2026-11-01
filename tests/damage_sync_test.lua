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

local vecMeta = {}
function vec3(x, y, z)
	if type(x) == "table" then x, y, z = x.x, x.y, x.z end
	return setmetatable({x = x or 0, y = y or 0, z = z or 0}, vecMeta)
end
vecMeta.__unm = function(a) return vec3(-a.x, -a.y, -a.z) end

-- Rotations only travel from the car to its reset here, so a stand-in quaternion is
-- enough: products and quatFromDir keep their parts.
local quatMeta = {}
function quat(x, y, z, w) return setmetatable({x = x, y = y, z = z, w = w}, quatMeta) end
quatMeta.__mul = function(a, b) return quat(a.x + b.x, a.y + b.y, a.z + b.z, a.w * b.w) end
function quatFromDir(dir, up) return quat(dir.x, dir.y, up.z, 1) end

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

-- The enabler's traffic test, from the real enabler (loaded once per world).
local ENABLER = "Resources/Client/CareerMP/lua/ge/extensions/careerMPEnabler.lua"
local enabler

-- Runs fn with the globals of a game's game-engine Lua.
local function as(game, fn, ...)
	MPVehicleGE, be, gameplay_traffic = game.MPVehicleGE, game.be, game.traffic
	careerMP_damageSync, careerMPEnabler = game.ge, enabler
	function TriggerServerEvent(name, data)
		table.insert(world.toServer, {from = game.id, name = name, data = data})
	end
	function AddEventHandler(name, fn) game.handlers[name] = fn end
	return fn(...)
end

local function newWorld()
	world = {games = {}, toServer = {}, toClients = {}, serverSent = {}, received = {}}
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
	enabler = dofile(ENABLER)
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
		-- opts.separate gives every beam two points of its own.
		if opts.separate then
			beams[cid] = {cid = cid, id1 = (2 * cid) % nodeCount, id2 = (2 * cid + 1) % nodeCount}
		else
			beams[cid] = {cid = cid, id1 = cid % nodeCount, id2 = (cid + 1) % nodeCount}
		end
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
	function veh:getDirectionVector() return vec3(car.fwd) end
	function veh:getDirectionVectorUp() return vec3(car.up) end
	function veh:setPositionRotation(x, y, z, rx, ry, rz, rw)
		for _, n in ipairs({x, y, z, rx, ry, rz, rw}) do assert(type(n) == "number", "setPositionRotation takes numbers") end
		same(x, self.pos.x, "reset in place: x")
		same(y, self.pos.y, "reset in place: y")
		self.resets = self.resets + 1
		car.reset()
	end
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
			table.insert(world.received, m)
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

--== the vehicle side on its own ============================================

-- A car on a game with no game-engine module: what its vehicle Lua queues stays in
-- game.geQueue.
local function soloCar(opts)
	newWorld()
	local game = {id = 0, cars = {}, objects = {}, vehicles = {}, geQueue = {}}
	world.games[0] = game
	return addCar(game, 0, 0, opts), game
end

-- The damage messages a car's vehicle Lua queued for the game-engine Lua, decoded.
local function takeMessages(car)
	local messages = {}
	local queue = car.game.geQueue
	car.game.geQueue = {}
	for _, cmd in ipairs(queue) do
		careerMP_damageSync = {onLocalDamage = function(id, json)
			same(id, car.gid, "vehicle id in the command")
			table.insert(messages, jsonToLua(json))
		end}
		assert(compile(cmd))()
	end
	return messages
end

local function tick(car, seconds)
	for _ = 1, math.floor((seconds or 0.5) / 0.25 + 0.5) do inVehicle(car, car.ext.updateGFX, 0.25) end
end

local function beamIds(message)
	local ids = {}
	for i = 1, #message.b, 4 do table.insert(ids, message.b[i]) end
	return ids
end

local function ownerCar(opts)
	local car = soloCar(opts)
	inVehicle(car, car.ext.setRole, "owner")
	return car
end

local function copyCar(opts)
	local car = soloCar(opts)
	inVehicle(car, car.ext.setRole, "copy")
	return car
end

test("a new owner announces itself once, then sends nothing while its damage does not move", function()
	local car = ownerCar()
	tick(car)
	local first = takeMessages(car)
	same(#first, 1, "announcements")
	same(#first[1].b, 0, "beams in an undamaged car's announcement")
	same(first[1].c, 0, "not cleared")
	tick(car, 2)
	same(#takeMessages(car), 0, "messages afterwards")
end)

test("each message carries only the beams changed since the one before", function()
	local car = ownerCar()
	dent(car, 7, 0.8)
	dent(car, 9, 0.9)
	tick(car)
	local first = takeMessages(car)
	same(#first, 1, "first messages")
	same(table.concat(beamIds(first[1]), ","), "7,9", "beams in the first message")
	same(first[1].b[2], 0.8, "beam 7 rest length")
	same(first[1].b[3], 0, "beam 7 not broken")
	same(first[1].b[4], 0.3, "beam 7 deformation")
	same(first[1].c, 0, "not cleared")
	dent(car, 12, 0.7)
	tick(car)
	local second = takeMessages(car)
	same(table.concat(beamIds(second[1]), ","), "12", "beams in the second message")
end)

test("a broken beam is sent as broken", function()
	local car = ownerCar()
	car.broken[5] = true
	car.beamstate.damage = 50
	tick(car)
	local m = takeMessages(car)[1]
	same(table.concat(beamIds(m), ","), "5", "beams")
	same(m.b[3], 1, "broken")
end)

test("a car with no role, or a copy, never sends its damage", function()
	for _, role in ipairs({"none", "copy"}) do
		local car = soloCar()
		inVehicle(car, car.ext.setRole, role)
		dent(car, 7, 0.8)
		tick(car, 2)
		same(#takeMessages(car), 0, role .. ": messages")
	end
end)

test("a wreck of 1000 beams goes out as 400, 400 and 200 over three ticks", function()
	local car = ownerCar({beams = 1000})
	car.beamstate.damage = 1000
	for cid = 0, 999 do car.restLen[cid] = 0.9 end
	local counts = {}
	for _ = 1, 4 do
		tick(car)
		for _, m in ipairs(takeMessages(car)) do table.insert(counts, math.floor(#m.b / 4)) end
	end
	same(table.concat(counts, ","), "400,400,200", "beams per message")
end)

test("a message holds at most 500 points", function()
	local car = ownerCar({beams = 300, nodes = 600, separate = true})
	car.beamstate.damage = 1000
	for cid = 0, 299 do car.restLen[cid] = 0.9 end
	tick(car)
	local m = takeMessages(car)[1]
	same(math.floor(#m.n / 4), 500, "points in the message")
	same(math.floor(#m.b / 4), 250, "beams, cut short by the point limit")
	tick(car)
	same(math.floor(#takeMessages(car)[1].b / 4), 50, "beams in the next message")
end)

test("a dent applied to a copy facing another way lands in the same place on the car", function()
	local owner = ownerCar()
	dent(owner, 7, 0.8, {0.05, -0.12, 0.03})
	tick(owner)
	local m = takeMessages(owner)[1]
	local copy = copyCar({fwd = {x = 1, y = 0, z = 0}})
	inVehicle(copy, copy.ext.applyDamage, 0, m.b, m.n)
	local node = owner.v.data.beams[7].id1
	local ox, oy, oz = toCarFrame(owner, owner.nodePos[node])
	local cx, cy, cz = toCarFrame(copy, copy.nodePos[node])
	expect(math.abs(ox - cx) < 0.002 and math.abs(oy - cy) < 0.002 and math.abs(oz - cz) < 0.002,
		string.format("point %d: owner (%.3f, %.3f, %.3f), copy (%.3f, %.3f, %.3f)", node, ox, oy, oz, cx, cy, cz))
	expect(math.abs(copy.nodePos[node].x - owner.nodePos[node].x) > 0.1, "the copy's frame was used")
	same(copy.restLen[7], 0.8, "rest length")
	same(copy.beamstate.deformedBeams[7], 0.3, "deformation recorded")
end)

test("a copy refuses unknown beams and points and values out of range, and applies the rest", function()
	local copy = copyCar()
	local before = vec3(copy.nodePos[3])
	inVehicle(copy, copy.ext.applyDamage, 0,
		{7, 0.8, 0, 0.2,      -- applied
		 999, 0.8, 0, 0.2,    -- unknown beam
		 8, 150, 0, 0.2,      -- rest length out of range
		 9, -1, 0, 0.2,       -- negative rest length
		 10, 0.9, 2, 0.2,     -- broken flag not 0 or 1
		 11, 0.9, 0, 50,      -- deformation out of range
		 12, 0.5, 1, 1},      -- applied, broken
		{3, 25, 0, 0,         -- offset out of range
		 999, 0, 0, 0,        -- unknown point
		 4, 0.1, 0.2, 0.3})   -- applied
	same(copy.restLen[7], 0.8, "beam 7")
	same(copy.restLen[8], 1, "beam 8")
	same(copy.restLen[9], 1, "beam 9")
	same(copy.restLen[10], 1, "beam 10")
	same(copy.restLen[11], 1, "beam 11")
	same(copy.restLen[12], 0.5, "beam 12")
	same(copy.broken[12], true, "beam 12 broken")
	same(copy.nodePos[3].x, before.x, "point 3 left alone")
	local x, y, z = toCarFrame(copy, copy.nodePos[4])
	expect(math.abs(x - 0.1) < 1e-6 and math.abs(y - 0.2) < 1e-6 and math.abs(z - 0.3) < 1e-6, "point 4 placed")
	same(countLines(logs, "refused part of another player's damage message"), 1, "logged once")
end)

test("a copy refuses text where numbers belong", function()
	local copy = copyCar()
	inVehicle(copy, copy.ext.applyDamage, 0, {"7", 0.8, 0, 0.2, 8, "0.8", 0, 0.2}, {"3", 0, 0, 0})
	same(copy.restLen[7], 1, "beam 7")
	same(copy.restLen[8], 1, "beam 8")
end)

test("a beam already deformed or broken on the copy is not deformed or broken again", function()
	local copy = copyCar()
	inVehicle(copy, copy.ext.applyDamage, 0, {7, 0.8, 1, 0.3}, {})
	inVehicle(copy, copy.ext.applyDamage, 0, {7, 0.8, 1, 0.3}, {})
	same(copy.breakCalls, 1, "breakBeam calls")
	inVehicle(copy, copy.ext.applyDamage, 0, {9, 0.8, 0, 0.3}, {})
	inVehicle(copy, copy.ext.applyDamage, 0, {9, 0.7, 0, 0.4}, {})
	same(copy.deformCalls, 1, "onBeamDeformed calls")
	same(copy.restLen[9], 0.7, "the newer rest length")
end)

test("an owner car ignores damage messages meant for copies", function()
	local car = ownerCar()
	inVehicle(car, car.ext.applyDamage, 0, {7, 0.5, 0, 0.3}, {})
	same(car.restLen[7], 1, "beam 7")
end)

--== roles ===================================================================

local function roleCommands(car)
	local roles = {}
	for _, cmd in ipairs(car.roleLog or {}) do table.insert(roles, cmd) end
	return roles
end

-- Records every role a car's vehicle Lua is given.
local function watchRoles(car)
	car.roleLog = {}
	local setRole = car.ext.setRole
	car.ext.setRole = function(role)
		table.insert(car.roleLog, role)
		return setRole(role)
	end
end

local function sentToServer(name, from)
	local list = {}
	for _, m in ipairs(world.received) do
		if m.name == name and (from == nil or m.from == from) then table.insert(list, m) end
	end
	return list
end

test("an own car becomes the owner only after two checks as a car the player drives", function()
	newWorld()
	local game = addGame(0)
	local car = addCar(game, 0, 0)
	watchRoles(car)
	step(1)
	same(#roleCommands(car), 0, "roles after one check")
	step(1)
	same(table.concat(roleCommands(car), ","), "owner", "roles after two checks")
	step(3)
	same(#roleCommands(car), 1, "role sent once")
end)

test("traffic, parked cars and the walking unicycle never send damage", function()
	newWorld()
	local game = addGame(0)
	local traffic = addCar(game, 0, 1, {isTraffic = "true"})
	local parked = addCar(game, 0, 2, {isParked = "true"})
	local ai = addCar(game, 0, 3)
	game.trafficData[ai.gid] = {isAi = true}
	local walker = addCar(game, 0, 4, {jbeam = "unicycle"})
	local other = addGame(1)
	addCar(other, 0, 4, {jbeam = "unicycle"})
	for _, car in ipairs({traffic, parked, ai, walker}) do watchRoles(car) end
	step(5)
	for _, car in ipairs({traffic, parked, ai, walker}) do
		same(#roleCommands(car), 0, "roles for car " .. car.sid)
	end
	same(#sentToServer("careerDamageRequest"), 0, "full-damage requests for a unicycle")
end)

test("without the enabler's traffic test no car sends damage, and that is logged once", function()
	newWorld()
	local game = addGame(0)
	local car = addCar(game, 0, 0)
	game.playerVehicle = car.gid
	watchRoles(car)
	enabler = nil
	step(3)
	same(#roleCommands(car), 0, "roles")
	same(countLines(logs, "careerMPEnabler.isTrafficCar missing"), 1, "warnings")
end)

test("the car the player drives sends its damage even when it came from traffic", function()
	newWorld()
	local game = addGame(0)
	local car = addCar(game, 0, 0, {isTraffic = "true"})
	game.playerVehicle = car.gid
	watchRoles(car)
	step(2)
	same(table.concat(roleCommands(car), ","), "owner", "roles")
end)

test("another player's car becomes a copy at once and asks its owner for full damage once", function()
	local owner, copy, owners, copies = twoGames()
	step(4)
	local requests = sentToServer("careerDamageRequest", 1)
	same(#requests, 1, "requests from the copy's game")
	same(requests[1].data, '{"v":"0-0"}', "request")
	same(#sentToServer("careerDamageRequest", 0), 0, "requests from the owner's game")
end)

--== the game-engine module ==================================================

test("a game sends at most 3 damage messages to the server a second", function()
	local owner, copy, owners = twoGames()
	step(2)
	for _ = 1, 10 do
		as(owners, owners.ge.onLocalDamage, owner.gid, '{"c":0,"b":[],"n":[]}')
	end
	local before = #sentToServer("careerDamage", 0)
	for _ = 1, 20 do
		as(owners, owners.ge.onUpdate, 0.05)
		pump()
	end
	local sent = #sentToServer("careerDamage", 0) - before
	expect(sent >= 2 and sent <= 3, "messages in one second: " .. sent)
end)

test("a message from a car that is not this game's owner car is not sent", function()
	local owner, copy, owners, copies = twoGames()
	step(3)
	local before = #sentToServer("careerDamage")
	as(copies, copies.ge.onLocalDamage, copy.gid, '{"c":0,"b":[],"n":[]}')
	as(owners, owners.ge.onLocalDamage, 999, '{"c":0,"b":[],"n":[]}')
	step(1)
	same(#sentToServer("careerDamage") - before, 0, "messages sent")
end)

local function deliver(game, text)
	as(game, game.handlers.rxCareerDamage, text)
	pump()
end

test("a received message for this game's own car, an unknown car or a malformed id is dropped", function()
	local owner, copy, owners, copies = twoGames()
	step(2)
	deliver(owners, '{"v":"0-0","c":0,"b":[7,0.5,0,0.3],"n":[]}')
	same(owner.restLen[7], 1, "own car")
	deliver(copies, '{"v":"0-9","c":0,"b":[7,0.5,0,0.3],"n":[]}')
	deliver(copies, '{"v":"0-0x","c":0,"b":[7,0.5,0,0.3],"n":[]}')
	deliver(copies, '{"v":0,"c":0,"b":[7,0.5,0,0.3],"n":[]}')
	same(copy.restLen[7], 1, "copy")
	deliver(copies, '{"v":"0-0","c":0,"b":[7,0.5,0,0.3],"n":[]}')
	same(copy.restLen[7], 0.5, "a well-formed message still applies")
end)

test("text in a received message never reaches a vehicle command", function()
	local owner, copy, owners, copies = twoGames()
	step(2)
	local ran = false
	_G.injected = function() ran = true end
	deliver(copies, '{"v":"0-0","c":0,"b":[7,"1});injected();({",0,0.3],"n":[]}')
	deliver(copies, '{"v":"0-0","c":0,"b":[7,0.5,0,0.3],"n":["3);injected();(",0,0,0]}')
	deliver(copies, '{"v":"0-0","c":"1);injected();(","b":[],"n":[]}')
	_G.injected = nil
	same(ran, false, "injected code ran")
	same(copy.restLen[7], 1, "nothing applied from a malformed message")
	same(#copy.vehicleQueue, 0, "vehicle commands left")
end)

test("a received message the game cannot decode is dropped without an error", function()
	local owner, copy, owners, copies = twoGames()
	step(2)
	local decode = jsonDecode
	jsonDecode = function() error("bad json") end
	deliver(copies, '{"v":"0-0",')
	jsonDecode = decode
	same(copy.restLen[7], 1, "copy")
end)

test("a received message with a wrong row length or too many rows is dropped", function()
	local owner, copy, owners, copies = twoGames()
	step(2)
	deliver(copies, '{"v":"0-0","c":0,"b":[7,0.5,0],"n":[]}')
	same(copy.restLen[7], 1, "three numbers in a row")
	local rows = {}
	for cid = 0, 400 do table.insert(rows, cid .. ",0.5,0,0.3") end
	deliver(copies, '{"v":"0-0","c":0,"b":[' .. table.concat(rows, ",") .. '],"n":[]}')
	same(copy.restLen[7], 1, "401 beams")
end)

--== the server relay ========================================================

local function serverSends(event)
	local list = {}
	for _, m in ipairs(world.serverSent) do
		if m.event == event then table.insert(list, m) end
	end
	return list
end

local function threeGames()
	newWorld()
	local games = {addGame(0), addGame(1), addGame(2)}
	world.serverSent = {}
	return games
end

test("the server passes a damage message from the car's owner to every other player, unchanged", function()
	threeGames()
	local text = '{"v":"0-3","c":0,"b":[7,0.5,0,0.3],"n":[]}'
	careerDamage(0, text)
	local sends = serverSends("rxCareerDamage")
	same(#sends, 2, "messages sent")
	local to = {}
	for _, s in ipairs(sends) do
		to[s.target] = true
		same(s.data, text, "message")
	end
	expect(to[1] and to[2] and not to[0], "sent to players 1 and 2 only")
end)

test("the server drops damage for a car the sender does not own", function()
	threeGames()
	careerDamage(1, '{"v":"0-3","c":0,"b":[],"n":[]}')
	careerDamage(1, '{"v":"10-3","c":0,"b":[],"n":[]}')
	careerDamage(1, '{"v":"1-3x","c":0,"b":[],"n":[]}')
	careerDamage(1, '{"c":0,"b":[],"n":[]}')
	same(#serverSends("rxCareerDamage"), 0, "messages sent")
end)

test("the server drops an oversize message and one that does not decode", function()
	threeGames()
	careerDamage(0, '{"v":"0-3","c":0,"b":[' .. string.rep("1,", 17000) .. '1],"n":[]}')
	careerDamage(0, '{"v":"0-3",')
	careerDamage(0, nil)
	same(#serverSends("rxCareerDamage"), 0, "messages sent")
end)

test("the server passes at most 4 damage messages a second from one player", function()
	threeGames()
	for _ = 1, 6 do careerDamage(0, '{"v":"0-3","c":0,"b":[],"n":[]}') end
	same(#serverSends("rxCareerDamage"), 8, "messages sent to two players")
	careerDamage(1, '{"v":"1-0","c":0,"b":[],"n":[]}')
	same(#serverSends("rxCareerDamage"), 10, "another player has their own limit")
	world.now = (world.now or 0) + 1
	careerDamage(0, '{"v":"0-3","c":0,"b":[],"n":[]}')
	same(#serverSends("rxCareerDamage"), 12, "a second later")
end)

test("a full-damage request reaches the car's owner only", function()
	threeGames()
	careerDamageRequest(1, '{"v":"2-5"}')
	local sends = serverSends("rxCareerDamageRequest")
	same(#sends, 1, "requests passed on")
	same(sends[1].target, 2, "to the owner")
	same(sends[1].data, '{"v":"2-5"}', "request")
	careerDamageRequest(2, '{"v":"2-5"}')
	careerDamageRequest(1, '{"v":"7-5"}')
	careerDamageRequest(1, '{"v":"2-5);x"}')
	careerDamageRequest(1, '{"v":5}')
	same(#serverSends("rxCareerDamageRequest"), 1, "requests passed on after bad ones")
end)

--== phantom damage, resets and late joiners ================================

-- Two games where the copy has heard from its owner: the owner dented beam 7.
local function syncedGames()
	local owner, copy, owners, copies = twoGames()
	step(2.5)
	dent(owner, 7, 0.8)
	step(1.5)
	same(copy.restLen[7], 0.8, "the owner's dent on the copy")
	return owner, copy, owners, copies
end

-- Damage only the copy's game simulated: n beams from `first` broken on the copy.
local function phantomBreaks(copy, first, n)
	for cid = first, first + n - 1 do
		copy.broken[cid] = true
		copy.beamstate.deformedBeams[cid] = 1
	end
	copy.beamstate.damage = copy.beamstate.damage + 1000
end

test("a copy with 25 beams of damage its owner never reported is reset and given the owner's damage", function()
	local owner, copy, owners, copies = syncedGames()
	local requestsBefore = #sentToServer("careerDamageRequest", 1)
	phantomBreaks(copy, 20, 25)
	step(4)
	expect(copy.veh.resets >= 1, "the copy was reset in place")
	same(#sentToServer("careerDamageRequest", 1) - requestsBefore, 1, "full-damage requests")
	same(copy.broken[30], nil, "a phantom break undone")
	same(copy.restLen[7], 0.8, "the owner's dent applied again")
end)

test("an owner's reset clears the dents and breaks on every copy", function()
	local owner, copy = syncedGames()
	owner.broken[9] = true
	owner.beamstate.damage = owner.beamstate.damage + 100
	step(1.5)
	same(copy.broken[9], true, "the owner's break on the copy")
	owner.reset()
	step(1.5)
	same(copy.restLen[7], 1, "the copy's beam 7")
	same(copy.broken[9], nil, "the copy's beam 9 whole again")
end)

test("a player who joins after a crash sees the car's dents", function()
	local owner, copy, owners, copies = syncedGames()
	local late = addGame(2)
	local lateCopy = addCar(late, 0, 0, {fwd = {x = 0, y = -1, z = 0}})
	step(3)
	same(lateCopy.restLen[7], 0.8, "the late joiner's beam 7")
end)

--== owner wins, on the copy's vehicle side =================================

-- The resets a copy's vehicle Lua asked for: {resync = n, cleared = n}.
local function resetRequests(car)
	local counts = {resync = 0, cleared = 0}
	for _, cmd in ipairs(car.game.geQueue) do
		local id, wantFull = cmd:match("^careerMP_damageSync%.resetCopy%((%d+),(%d)%)$")
		if id then
			same(tonumber(id), car.gid, "car in the reset request")
			if wantFull == "1" then counts.resync = counts.resync + 1 else counts.cleared = counts.cleared + 1 end
		end
	end
	return counts
end

-- A copy that has heard from its owner: beams 0 to n-1 reported dented to 0.9.
local function heardCopy(n)
	local copy = copyCar({beams = 100})
	local rows = {}
	for cid = 0, (n or 30) - 1 do
		for _, x in ipairs({cid, 0.9, 0, 0.2}) do table.insert(rows, x) end
	end
	inVehicle(copy, copy.ext.applyDamage, 0, rows, {})
	return copy
end

test("applying the owner's own dents never starts a resync", function()
	local copy = heardCopy(30)
	tick(copy, 5)
	same(resetRequests(copy).resync, 0, "resyncs")
end)

test("21 beams broken on the copy while reported whole start a resync after two checks", function()
	local copy = heardCopy(30)
	for cid = 0, 20 do copy.broken[cid] = true end
	tick(copy, 1)
	same(resetRequests(copy).resync, 0, "resyncs after one check")
	tick(copy, 1)
	same(resetRequests(copy).resync, 1, "resyncs after two checks")
end)

test("21 beams more than 2 cm off the owner's rest length start a resync", function()
	local copy = heardCopy(30)
	for cid = 0, 20 do copy.restLen[cid] = 0.9 - 0.025 end
	tick(copy, 2)
	same(resetRequests(copy).resync, 1, "resyncs")
end)

test("lengths within 2 cm, or only 20 disagreeing beams, start no resync", function()
	local copy = heardCopy(30)
	for cid = 0, 29 do copy.restLen[cid] = 0.9 - 0.015 end
	for cid = 50, 69 do copy.beamstate.deformedBeams[cid] = 0.5 end
	tick(copy, 5)
	same(resetRequests(copy).resync, 0, "resyncs")
end)

test("damage that settles within one check starts no resync", function()
	local copy = heardCopy(30)
	for cid = 50, 74 do copy.beamstate.deformedBeams[cid] = 0.5 end
	tick(copy, 1)
	inVehicle(copy, copy.ext.applyDamage, 0, (function()
		local rows = {}
		for cid = 50, 74 do for _, x in ipairs({cid, 1, 0, 0.5}) do table.insert(rows, x) end end
		return rows
	end)(), {})
	tick(copy, 3)
	same(resetRequests(copy).resync, 0, "resyncs once the owner reported the same damage")
end)

test("a second resync for the same car waits 10 seconds", function()
	local copy = heardCopy(30)
	for cid = 50, 74 do copy.beamstate.deformedBeams[cid] = 0.5 end
	tick(copy, 2)
	same(resetRequests(copy).resync, 1, "first resync")
	tick(copy, 9.5)
	same(resetRequests(copy).resync, 1, "resyncs within 10 seconds of the first")
	tick(copy, 0.5)
	same(resetRequests(copy).resync, 2, "resyncs 10 seconds after the first")
end)

test("a copy that never heard from its owner never resyncs", function()
	local copy = copyCar({beams = 100})
	for cid = 50, 99 do copy.beamstate.deformedBeams[cid] = 1 end
	tick(copy, 5)
	same(resetRequests(copy).resync, 0, "resyncs")
end)

test("a cleared message resets a damaged copy and forgets its reports, and leaves an undamaged one alone", function()
	local copy = heardCopy(30)
	inVehicle(copy, copy.ext.applyDamage, 1, {}, {})
	same(resetRequests(copy).cleared, 1, "resets for a damaged copy")
	copy.game.geQueue = {}
	copy.reset()
	tick(copy, 3)
	same(resetRequests(copy).resync, 0, "resyncs once the reports are forgotten")
	inVehicle(copy, copy.ext.applyDamage, 1, {}, {})
	same(resetRequests(copy).cleared, 0, "resets for an undamaged copy")
end)

--== the owner's full damage ================================================

test("a full-damage answer covers every beam changed since the car was built, 400 a message", function()
	local car = ownerCar({beams = 1000})
	tick(car)
	takeMessages(car)
	for cid = 0, 999 do car.restLen[cid] = 0.9 end
	car.beamstate.damage = 1000
	for _ = 1, 3 do tick(car) end
	takeMessages(car)
	inVehicle(car, car.ext.sendFull)
	local counts = {}
	for _ = 1, 4 do
		tick(car)
		for _, m in ipairs(takeMessages(car)) do table.insert(counts, math.floor(#m.b / 4)) end
	end
	same(table.concat(counts, ","), "400,400,200", "beams per message")
end)

test("a repair that empties the damage total sends a cleared message", function()
	local car = ownerCar()
	tick(car)
	takeMessages(car)
	dent(car, 7, 0.8)
	tick(car)
	takeMessages(car)
	car.restLen[7] = 1
	car.beamstate.damage = 0
	tick(car)
	local m = takeMessages(car)
	same(#m, 1, "messages")
	same(m[1].c, 1, "cleared")
end)

test("a copy only answers requests for this game's own owner cars", function()
	local owner, copy, owners, copies = twoGames()
	step(3)
	local before = #sentToServer("careerDamage", 1)
	as(copies, copies.handlers.rxCareerDamageRequest, '{"v":"0-0"}')
	step(1)
	same(#sentToServer("careerDamage", 1) - before, 0, "messages from the copy's game")
end)
