-- mileage/positionRate.lua: Mileage's check around BeamMP's send of each own car's
-- position (positionGE.sendVehiclePosRot). A parked car standing still sends once a
-- second, driving traffic more than 500 m from every other player's car twice a second,
-- a hidden car never; every other send goes through untouched.

local SOURCE = "Resources/Client/Mileage/lua/ge/extensions/mileage/positionRate.lua"
local COMPAT = "Resources/Client/Mileage/lua/ge/extensions/mileage/compat.lua"

local FRAME = 0.02 -- BeamMP's position tick rate

local logs, game

local function vec(x, y, z)
	local v = {x = x, y = y, z = z}
	function v:length() return math.sqrt(self.x * self.x + self.y * self.y + self.z * self.z) end
	return v
end

-- A car on the stand-in game. kind: "player", "own", "traffic", "parked", "remote".
local function addCar(gid, kind, pos, fields)
	local veh = {id = gid, pos = pos or vec(0, 0, 0), vel = vec(0, 0, 0), active = true, own = kind ~= "remote",
		kind = kind, positionReads = 0}
	for k, v in pairs(fields or {}) do veh[k] = v end
	if kind == "traffic" then veh.isTraffic = "true" end
	if kind == "parked" then veh.isParked = "true" end
	function veh:getActive() return self.active end
	function veh:getPosition() self.positionReads = self.positionReads + 1; return self.pos end
	function veh:getVelocity() return self.vel end
	game.objects[gid] = veh
	game.vehicles[(veh.own and "0-" or "1-") .. gid] = {gameVehicleID = gid}
	if kind == "player" then game.playerVehicle = gid end
	return veh
end

local function setup(opts)
	opts = opts or {}
	logs = {}
	game = {objects = {}, vehicles = {}, playerVehicle = -1, forwarded = {}, remoteTraffic = {}}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	MPCoreNetwork = {isMPSession = function() return opts.mp ~= false end}
	extensions = {mileage_compat = dofile(COMPAT)}
	MPVehicleGE = {
		getVehicles = function() return game.vehicles end,
		isOwn = function(gid) local v = game.objects[gid]; return v ~= nil and v.own end,
	}
	be = {
		getObjectByID = function(_, gid) return game.objects[gid] end,
		getPlayerVehicleID = function() return game.playerVehicle end,
	}
	mileageEnabler = {
		isTrafficCar = function(gid, veh)
			if gid == game.playerVehicle then return false end
			return veh.isTraffic == "true" or veh.isParked == "true"
		end,
		isRemoteTraffic = function(sid) return game.remoteTraffic[sid] == true end,
	}
	game.original = function(data, gid)
		game.forwarded[gid] = (game.forwarded[gid] or 0) + 1
		game.lastData = data
	end
	positionGE = nil
	if opts.positionGE ~= false then positionGE = {} end
	if positionGE and not opts.noSend then positionGE.sendVehiclePosRot = game.original end
	return dofile(SOURCE)
end

-- Runs `seconds` of frames: the module's update, then BeamMP's send for every own car.
local function run(module, seconds)
	for _ = 1, math.floor(seconds / FRAME + 0.5) do
		module.onUpdate(FRAME)
		for gid, veh in pairs(game.objects) do
			if veh.own then positionGE.sendVehiclePosRot('{"pos":[0,0,0]}', gid) end
		end
	end
end

local function forwarded(gid) return game.forwarded[gid] or 0 end

-- One player's game: the car they drive, own cars, near and far traffic, still and
-- moving parked cars and hidden cars; another player's car at the origin and another
-- player's traffic car far away.
local function busyGame()
	local module = setup()
	addCar(1, "player", vec(10, 0, 0))
	addCar(500, "remote", vec(0, 0, 0))
	addCar(501, "remote", vec(5000, 5000, 0))
	game.remoteTraffic["1-501"] = true
	for i = 0, 3 do addCar(10 + i, "own", vec(20, i, 0)) end
	for i = 0, 4 do addCar(20 + i, "traffic", vec(100 + i, 0, 0)) end
	for i = 0, 4 do addCar(30 + i, "traffic", vec(800 + i * 10, 0, 0)) end
	-- far from the other player, near the other player's traffic only
	addCar(35, "traffic", vec(5000, 5010, 0))
	for i = 0, 7 do addCar(40 + i, "parked", vec(2000, i * 5, 0)) end
	for i = 0, 3 do addCar(50 + i, "parked", vec(50, i * 5, 0), {vel = vec(2, 0, 0)}) end
	for i = 0, 2 do addCar(60 + i, "traffic", vec(30, i, 0), {active = false}) end
	module.onCareerActive(true)
	return module
end

--== the rules ===============================================================

test("over 10 seconds each car's positions reach BeamMP at the rate of its rule", function()
	local module = busyGame()
	run(module, 10)
	local sends = math.floor(10 / FRAME + 0.5)
	same(forwarded(1), sends, "the car the player drives")
	for i = 0, 3 do same(forwarded(10 + i), sends, "own car " .. (10 + i) .. " that is not traffic") end
	for i = 0, 4 do same(forwarded(20 + i), sends, "traffic within 500 m of another player's car " .. (20 + i)) end
	for i = 0, 4 do
		local n = forwarded(30 + i)
		expect(n >= 19 and n <= 21, "far traffic " .. (30 + i) .. ": " .. n)
	end
	local nearTheirTraffic = forwarded(35)
	expect(nearTheirTraffic >= 19 and nearTheirTraffic <= 21,
		"far traffic next to another player's traffic only: " .. nearTheirTraffic)
	for i = 0, 7 do
		local n = forwarded(40 + i)
		expect(n >= 9 and n <= 11, "still parked car " .. (40 + i) .. ": " .. n)
	end
	for i = 0, 3 do same(forwarded(50 + i), sends, "moving parked car " .. (50 + i)) end
	for i = 0, 2 do same(forwarded(60 + i), 0, "hidden car " .. (60 + i)) end
end)

test("a forwarded send is BeamMP's own, unchanged", function()
	local module = busyGame()
	run(module, 0.1)
	same(game.lastData, '{"pos":[0,0,0]}', "data passed on")
end)

test("cars are read once a second, not on every send", function()
	local module = busyGame()
	run(module, 10)
	local reads = 0
	for _, veh in pairs(game.objects) do reads = reads + veh.positionReads end
	expect(reads <= 11 * 40, "position reads in 10 seconds: " .. reads)
end)

test("a still parked car that gets hit sends every position within a quarter of a second", function()
	local module = busyGame()
	run(module, 2)
	-- The other player drives into it.
	game.objects[500].pos = vec(2000, 5, 0)
	game.objects[40].vel = vec(4, 0, 0)
	run(module, 0.26)
	local before = forwarded(40)
	run(module, 1)
	same(forwarded(40) - before, 50, "sends in the second after the hit")
end)

test("a hidden car shown again sends every position within a quarter of a second", function()
	local module = busyGame()
	run(module, 2)
	game.objects[60].active = true
	run(module, 0.26)
	local before = forwarded(60)
	run(module, 0.5)
	same(forwarded(60) - before, 25, "sends in the half second after it was shown")
end)

test("traffic that comes within 500 m of another player's car sends every position from the next second", function()
	local module = busyGame()
	run(module, 2)
	game.objects[30].pos = vec(300, 0, 0)
	run(module, 1)
	local before = forwarded(30)
	run(module, 1)
	same(forwarded(30) - before, 50, "sends in the next second")
end)

test("a car the player climbs into sends every position from the next second", function()
	local module = busyGame()
	run(module, 2)
	game.playerVehicle = 40
	run(module, 1)
	local before = forwarded(40)
	run(module, 1)
	same(forwarded(40) - before, 50, "sends in the next second")
end)

test("a car spawned since the last check sends every position until it is checked", function()
	local module = busyGame()
	run(module, 1.5)
	addCar(70, "parked", vec(3000, 0, 0))
	run(module, 0.4)
	same(forwarded(70), 20, "sends before its first check")
end)

--== stepping aside ==========================================================

test("with no positionGE the check logs one warning naming the function and sends stay BeamMP's", function()
	local module = setup({positionGE = false})
	addCar(1, "player")
	local ok, err = pcall(module.onCareerActive, true)
	expect(ok, "did not raise: " .. tostring(err))
	module.onCareerActive(true)
	pcall(module.onUpdate, FRAME)
	same(countLines(logs, "positionGE.sendVehiclePosRot missing"), 1, "warnings")
	same(countLines(logs, "position check active"), 0, "active lines")
end)

test("with positionGE but no sendVehiclePosRot the check warns once and wraps nothing", function()
	local module = setup({noSend = true})
	module.onCareerActive(true)
	module.onCareerActive(true)
	same(positionGE.sendVehiclePosRot, nil, "positionGE.sendVehiclePosRot")
	same(countLines(logs, "positionGE.sendVehiclePosRot missing"), 1, "warnings")
end)

test("the log says once that the check is active", function()
	local module = busyGame()
	module.onCareerActive(true)
	same(countLines(logs, "position check active"), 1, "active lines")
end)

test("a check that fails reading the cars forwards every send and logs it once", function()
	local module = busyGame()
	run(module, 2)
	be.getObjectByID = function() error("lookup broke") end
	local ok, err = pcall(run, module, 2)
	expect(ok, "did not raise: " .. tostring(err))
	local before = forwarded(40)
	pcall(run, module, 1)
	same(forwarded(40) - before, 50, "a still parked car's sends once the check failed")
	same(countLines(logs, "position check failed"), 1, "error lines")
end)

test("leaving the server and unloading put BeamMP's function back", function()
	local module = busyGame()
	expect(positionGE.sendVehiclePosRot ~= game.original, "wrapped while on the server")
	module.onBeamMPServerLeave()
	same(positionGE.sendVehiclePosRot, game.original, "after leaving")
	module.onCareerActive(true)
	expect(positionGE.sendVehiclePosRot ~= game.original, "wrapped again on the next career start")
	module.onExtensionUnloaded()
	same(positionGE.sendVehiclePosRot, game.original, "after unloading")
end)

test("a reloaded positionGE is wrapped again on the next career start, the old one left alone", function()
	local module = busyGame()
	local old = positionGE
	local wrappedOld = old.sendVehiclePosRot
	local reloadedSends = 0
	positionGE = {sendVehiclePosRot = function() reloadedSends = reloadedSends + 1 end}
	local reloadedOriginal = positionGE.sendVehiclePosRot
	module.onCareerActive(true)
	expect(positionGE.sendVehiclePosRot ~= reloadedOriginal, "the reloaded module is wrapped")
	same(old.sendVehiclePosRot, wrappedOld, "the old module is not touched")
	module.onBeamMPServerLeave()
	same(positionGE.sendVehiclePosRot, reloadedOriginal, "the reloaded module's function back after leaving")
end)

test("off a server nothing is wrapped", function()
	local module = setup({mp = false})
	module.onCareerActive(true)
	same(positionGE.sendVehiclePosRot, game.original, "positionGE.sendVehiclePosRot")
end)

test("a career that is no longer active puts BeamMP's function back", function()
	local module = busyGame()
	module.onCareerActive(false)
	same(positionGE.sendVehiclePosRot, game.original, "positionGE.sendVehiclePosRot")
end)

test("traffic exactly 500 m from another player's car sends every position, traffic just past it twice a second", function()
	local module = setup()
	addCar(1, "player", vec(0, 0, 0))
	addCar(500, "remote", vec(0, 0, 0))
	addCar(20, "traffic", vec(500, 0, 0))
	addCar(21, "traffic", vec(0, 501, 0))
	module.onCareerActive(true)
	run(module, 10)
	same(forwarded(20), 500, "traffic at 500 m")
	local n = forwarded(21)
	expect(n >= 19 and n <= 21, "traffic at 501 m: " .. n)
end)

test("a moving parked car far from every other player sends every position, as it is not driving traffic", function()
	local module = setup()
	addCar(1, "player", vec(0, 0, 0))
	addCar(500, "remote", vec(0, 0, 0))
	addCar(40, "parked", vec(2000, 0, 0), {vel = vec(3, 0, 0)})
	module.onCareerActive(true)
	run(module, 2)
	same(forwarded(40), 100, "positions of a moving parked car 2 km away")
end)

test("a parked car moving at half a metre a second sends every position, one just slower once a second", function()
	local module = setup()
	addCar(1, "player", vec(0, 0, 0))
	addCar(500, "remote", vec(0, 0, 0))
	addCar(40, "parked", vec(50, 0, 0), {vel = vec(0.5, 0, 0)})
	addCar(41, "parked", vec(50, 5, 0), {vel = vec(0.49, 0, 0)})
	module.onCareerActive(true)
	run(module, 10)
	same(forwarded(40), 500, "parked car at 0.5 m/s")
	local n = forwarded(41)
	expect(n >= 9 and n <= 11, "parked car at 0.49 m/s: " .. n)
end)
