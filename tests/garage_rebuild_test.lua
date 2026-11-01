-- Garage rebuilds on a Mileage server: fitting parts, tuning, painting or repairing one car
-- at the garage computer must rebuild that car and nothing else, and the computer must seat
-- the player in the car they clicked.
--
-- Loads the real mileage/patches.lua and a stand-in for the game's own garage computer
-- (tests/game_computer.lua), which Mileage patches at runtime. BeamMP's rebuild is a
-- stand-in that follows MPVehicleGE.replaceRequest line for line: it decides the car from the
-- global getPlayerVehicle(0), ignores the car the caller named, marks that entry as edited and
-- calls the game's rebuild without a car. The game's rebuild (core/vehicles.lua) rebuilds the
-- car it is given, or getPlayerVehicle(0) when given none, in place.

local PATCHES = "Resources/Client/Mileage/lua/ge/extensions/mileage/patches.lua"
local COMPUTER = "tests/game_computer.lua"
local COMPUTER_COPY = "Resources/Client/Mileage/lua/ge/extensions/career/modules/computer.lua"

local CAR_A, CAR_B = 1, 2 -- inventory ids: A is the car the player picks, B their other car

local game, logs, toasts, hooks, patches

local function newObj(jbeam)
	game.nextId = game.nextId + 1
	local o = {id = game.nextId, JBeam = jbeam}
	function o:getID()
		if self.destroyed then error("Attempted to call a function on an object that no longer exists") end
		return self.id
	end
	o.getId = o.getID
	game.objects[o.id] = o
	return o
end

-- The game's rebuild: the named car, or the player's car, rebuilt in place.
local function gameReplaceVehicle(model, opt, otherVeh)
	if game.raiseOnRebuild then error("rebuild broke") end
	local other = otherVeh or getPlayerVehicle(0)
	if not other then return newObj(model) end
	other.JBeam = model
	other.config = opt and opt.config
	table.insert(game.rebuilt, other.id)
	if game.duringRebuild then game.duringRebuild() end
	return other
end

local function gameSpawnNewVehicle(model, opt)
	return newObj(model)
end

-- BeamMP's replaceRequest, as MPVehicleGE.lua has it.
local function installBeamMP(opts)
	opts = opts or {}
	local original_replaceVehicle = core_vehicles.replaceVehicle
	local original_spawnNewVehicle = core_vehicles.spawnNewVehicle
	local function replaceRequest(model, config, colors)
		game.beamMPCalls = game.beamMPCalls + 1
		local currentVehicle
		if opts.decidesByPlayerId then
			-- A future BeamMP that asks the engine instead of the global.
			currentVehicle = game.objects[be:getPlayerVehicleID(0)]
		else
			currentVehicle = getPlayerVehicle(0)
		end
		local gameVehicleID = currentVehicle and currentVehicle:getID() or -1
		local vehicle = MPVehicleGE.getVehicleByGameID(gameVehicleID)
		if currentVehicle and vehicle and vehicle.isLocal then
			vehicle.jbeam = '-'
			if opts.decidesByPlayerId then
				-- ...and hands the car it picked to the game's rebuild.
				return original_replaceVehicle(model, config or {}, currentVehicle)
			end
			return original_replaceVehicle(model, config or {})
		else
			return original_spawnNewVehicle(model, config or {})
		end
	end
	core_vehicles.replaceVehicle = replaceRequest
	game.beamMPReplace = replaceRequest
	return replaceRequest
end

local function setup()
	game = {objects = {}, nextId = 100, rebuilt = {}, beamMPCalls = 0, mp = {}, invToVeh = {}}
	logs, toasts, hooks = {}, {}, {}
	unpack = unpack or table.unpack

	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. tostring(msg)) end
	function setExtensionUnloadMode() end
	function deepcopy(t)
		if type(t) ~= "table" then return t end
		local r = {}
		for k, v in pairs(t) do r[k] = deepcopy(v) end
		return r
	end
	FS = {fileExists = function() return true end}
	guihooks = {trigger = function(name, data)
		if name == "toastrMsg" then table.insert(toasts, data) end
	end}

	game.carA = newObj("pickup")
	game.carB = newObj("sedan")
	game.walker = newObj("unicycle")
	game.player = game.walker
	for _, o in ipairs({game.carA, game.carB, game.walker}) do
		game.mp[o.id] = {isLocal = true, own = true, jbeam = o.JBeam}
	end
	game.invToVeh = {[CAR_A] = game.carA.id, [CAR_B] = game.carB.id}

	game.realGetPlayerVehicle = function(player)
		if player == 0 then return game.player end
		return nil
	end
	rawset(_G, "getPlayerVehicle", game.realGetPlayerVehicle)
	function getObjectByID(id) return game.objects[id] end
	be = {
		getPlayerVehicleID = function(_, player)
			return player == 0 and game.player and game.player.id or -1
		end,
		enterVehicle = function(_, player, veh) game.player = veh end,
	}
	-- BeamMP reports a server session; game.noSession makes it single player.
	MPCoreNetwork = {isMPSession = function() return not game.noSession end}
	MPVehicleGE = {
		isOwn = function(id) local e = game.mp[id] return e ~= nil and e.own == true end,
		getVehicleByGameID = function(id) return game.mp[id] end,
	}
	core_vehicles = {replaceVehicle = gameReplaceVehicle, spawnNewVehicle = gameSpawnNewVehicle}

	-- inventory.lua: the garage lists B first, so its "closest garage" guess is B.
	career_modules_inventory = {
		getCurrentVehicle = function() return nil end,
		getInventoryIdsInClosestGarage = function(onlyFirst)
			if onlyFirst then return CAR_B end
			return {CAR_B, CAR_A}
		end,
		getVehicleIdFromInventoryId = function(inv) return game.invToVeh[inv] end,
		getVehicles = function() return {[CAR_A] = {niceName = "A"}, [CAR_B] = {niceName = "B"}} end,
		getVehicleThumbnail = function() return "" end,
		-- inventory.lua:450-470, replaceOption 2: rebuild the car with that inventory id in place,
		-- then point the inventory at whatever came back.
		spawnVehicle = function(inv, replaceOption)
			local old = game.invToVeh[inv] and game.objects[game.invToVeh[inv]]
			local vehObj = core_vehicles.replaceVehicle("pickup", {config = "repaired"}, old)
			if vehObj then game.invToVeh[inv] = vehObj:getID() end
			return vehObj
		end,
	}
	career_modules_insurance_insurance = {
		inventoryVehNeedsRepair = function() return false end,
		startRepair = function() end,
		startRepairInGarage = function() end,
	}
	career_career = {hasBoughtStarterVehicle = function() return true end, closeAllMenus = function() end}
	-- tether.lua: each start is recorded with its range; a door tether fails when asked to.
	game.tethers = {}
	career_modules_tether = {
		startDoorTether = function(door, range)
			table.insert(game.tethers, {kind = "door", range = range})
			if game.doorTetherFails then return nil end
			return {}
		end,
		startSphereTether = function(pos, range)
			table.insert(game.tethers, {kind = "sphere", range = range})
			return {}
		end,
	}
	career_modules_partShopping = {startShopping = function() end, installPart = function() end,
		applyShopping = function() end}
	career_modules_tuning = {start = function() end}
	career_modules_painting = {start = function() end}
	career_modules_vehiclePerformance = {startDragTest = function() end}
	career_modules_vehicleShopping = {openPurchaseMenu = function() end, sendPurchaseDataToUi = function() end}
	gameplay_walk = {getInVehicle = function() end, setWalkingMode = function() end}

	-- The stock buttons: each runs the module's LOCAL start with the clicked car, which never
	-- passes through the module table, then fires the stock hook with no arguments.
	local stockHooks = {
		partShopping = "onPartShoppingStarted",
		tuning = "onCareerTuningStarted",
		painting = "onVehiclePaintingUiOpened",
	}
	extensions = {
		ui_router = {navigate = function() end},
		hook = function(name, ...)
			table.insert(hooks, {name = name, args = {...}})
			if name == "onComputerAddFunctions" then
				local _, computerFunctions = ...
				for inv, buttons in pairs(computerFunctions.vehicleSpecific) do
					for button, hook in pairs(stockHooks) do
						buttons[button] = {callback = function()
							game.startedFor = inv
							patches[hook]()
						end}
					end
					buttons.repair = {callback = function() end}
				end
				computerFunctions.general.sell = {callback = function() end}
			end
		end,
	}

	career_modules_computer = dofile(COMPUTER)
	patches = dofile(PATCHES)
	extensions.mileage_patches = patches
	return patches
end

local function announced(name)
	local last
	for _, h in ipairs(hooks) do if h.name == name then last = h end end
	return last and last.args
end

local function pickups()
	local n = 0
	for _, o in pairs(game.objects) do if o.JBeam == "pickup" then n = n + 1 end end
	return n
end

local function rebuiltOnly(id)
	for _, r in ipairs(game.rebuilt) do
		if r ~= id then return false end
	end
	return #game.rebuilt > 0
end

local COMPUTER_FACILITY = {id = "garageComputer", name = "Garage", doors = {{}}}

-- Car A has no entry in BeamMP's list of this player's cars.
local function unlink(obj) game.mp[obj.id] = nil end

local function lastToast() return toasts[#toasts] end

--== rebuilds go to the car the game named ===================================

test("seated in another car, fitting a part to car A rebuilds only car A", function()
	setup()
	installBeamMP()
	patches.apply()
	game.player = game.carB
	local back = core_vehicles.replaceVehicle("pickup", {config = "A with new part"}, game.carA)
	same(back, game.carA, "the car that came back")
	expect(rebuiltOnly(game.carA.id), "only car A was rebuilt")
	same(game.carB.JBeam, "sedan", "car B")
	same(game.walker.JBeam, "unicycle", "the walking avatar")
	same(pickups(), 1, "copies of car A")
	same(game.mp[game.carA.id].jbeam, "-", "car A sent to other players as an edit")
	same(game.mp[game.carB.id].jbeam, "sedan", "car B's entry")
	same(getPlayerVehicle(0), game.carB, "the player's car after the rebuild")
	same(game.player, game.carB, "the player is still seated in car B")
end)

test("on foot, fitting a part to car A rebuilds only car A, not the walking avatar", function()
	setup()
	installBeamMP()
	patches.apply()
	local back = core_vehicles.replaceVehicle("pickup", {config = "A with new part"}, game.carA)
	same(back, game.carA, "the car that came back")
	expect(rebuiltOnly(game.carA.id), "only car A was rebuilt")
	same(game.walker.JBeam, "unicycle", "the walking avatar")
	same(game.mp[game.walker.id].jbeam, "unicycle", "the avatar's entry")
	same(pickups(), 1, "copies of car A")
	same(getPlayerVehicle(0), game.walker, "the player's car after the rebuild")
end)

test("seated in car A, fitting a part to car A rebuilds car A in place", function()
	setup()
	installBeamMP()
	patches.apply()
	game.player = game.carA
	local back = core_vehicles.replaceVehicle("pickup", {config = "A with new part"}, game.carA)
	same(back, game.carA, "the car that came back")
	expect(rebuiltOnly(game.carA.id), "only car A was rebuilt")
	same(pickups(), 1, "copies of car A")
end)

test("the quick repair before Parts, on foot, keeps the garage pointing at car A", function()
	setup()
	installBeamMP()
	patches.apply()
	career_modules_inventory.spawnVehicle(CAR_A, 2)
	same(game.invToVeh[CAR_A], game.carA.id, "the garage's game vehicle for car A")
	same(game.walker.JBeam, "unicycle", "the walking avatar")
	same(pickups(), 1, "copies of car A")
end)

--== the temporary answer never outlives the call ============================

test("a rebuild that raises restores the player's car and the error reaches the caller", function()
	setup()
	installBeamMP()
	patches.apply()
	game.player = game.carB
	game.raiseOnRebuild = true
	local ok, err = pcall(core_vehicles.replaceVehicle, "pickup", {}, game.carA)
	expect(not ok, "the rebuild raised")
	expect(string.find(tostring(err), "rebuild broke", 1, true), "the caller sees the error: " .. tostring(err))
	same(rawget(_G, "getPlayerVehicle"), game.realGetPlayerVehicle, "the game's getPlayerVehicle is back")
	same(getPlayerVehicle(0), game.carB, "the player's car")
end)

test("a rebuild that raises is logged with the line it came from", function()
	setup()
	installBeamMP()
	patches.apply()
	game.player = game.carB
	game.raiseOnRebuild = true
	pcall(core_vehicles.replaceVehicle, "pickup", {}, game.carA)
	local logged
	for _, line in ipairs(logs) do
		if string.find(line, "E mileage.patches:", 1, true) and string.find(line, "rebuild broke", 1, true) then
			logged = line
		end
	end
	expect(logged, "the failed rebuild is logged as an error")
	expect(string.find(logged, "stack traceback", 1, true), "the log line carries a traceback: " .. logged)
	expect(string.find(logged, "garage_rebuild_test.lua", 1, true), "the traceback names where it came from: " .. logged)
end)

test("a rebuild that raises hands the caller the very error it raised, not the logged traceback", function()
	setup()
	installBeamMP()
	patches.apply()
	game.player = game.carB
	game.duringRebuild = function() error("rebuild broke", 0) end
	local ok, err = pcall(core_vehicles.replaceVehicle, "pickup", {}, game.carA)
	expect(not ok, "the rebuild raised")
	same(err, "rebuild broke", "the error the caller sees")

	local errObj = {reason = "rebuild broke"}
	game.duringRebuild = function() error(errObj) end
	ok, err = pcall(core_vehicles.replaceVehicle, "pickup", {}, game.carA)
	expect(not ok, "the rebuild raised an error object")
	same(err, errObj, "the error object the caller sees")
	local logged
	for _, line in ipairs(logs) do
		if string.find(line, "E mileage.patches: garage rebuild of vehicle " .. game.carA.id .. " failed", 1, true)
			and string.find(line, "stack traceback", 1, true) then
			logged = (logged or 0) + 1
		end
	end
	same(logged, 2, "failed rebuilds logged with car A's id and a traceback")
end)

test("the logged traceback is taken where the rebuild failed, not after it returned", function()
	setup()
	installBeamMP()
	patches.apply()
	game.player = game.carB
	local raiseLine
	game.duringRebuild = function() raiseLine = debug.getinfo(1, "l").currentline; error("deep failure", 0) end
	pcall(core_vehicles.replaceVehicle, "pickup", {}, game.carA)
	local logged
	for _, line in ipairs(logs) do
		if string.find(line, "deep failure", 1, true) then logged = line end
	end
	expect(logged, "the failed rebuild is logged")
	expect(string.find(logged, "garage_rebuild_test.lua:" .. raiseLine .. ": in ", 1, true),
		"the traceback has the frame that raised (line " .. tostring(raiseLine) .. "): " .. logged)
	expect(not string.find(logged, "vehicle " .. game.carB.id .. " ", 1, true), "the log names car A, not the player's car")
end)

test("a nested rebuild while one is running passes straight through", function()
	setup()
	installBeamMP()
	patches.apply()
	game.player = game.carB
	local nested = false
	game.duringRebuild = function()
		if nested then return end
		nested = true
		core_vehicles.replaceVehicle("pickup", {}, game.carA)
	end
	core_vehicles.replaceVehicle("pickup", {}, game.carA)
	same(game.beamMPCalls, 2, "BeamMP's rebuild calls")
	same(game.carB.JBeam, "sedan", "car B")
	same(rawget(_G, "getPlayerVehicle"), game.realGetPlayerVehicle, "the game's getPlayerVehicle is back")
end)

test("a BeamMP that picks the car another way is logged as an error and shown", function()
	setup()
	installBeamMP({decidesByPlayerId = true})
	patches.apply()
	game.player = game.carB
	local back = core_vehicles.replaceVehicle("pickup", {}, game.carA)
	same(back, game.carB, "what the rebuild returned is passed back unchanged")
	same(countLines(logs, "E mileage.patches: "), 1, "error lines")
	same(#toasts, 1, "messages shown")
	same(toasts[1].type, "error", "message type")
	same(getPlayerVehicle(0), game.carB, "the player's car")
end)

--== a car BeamMP does not list as this player's is never rebuilt ============

local function refusesUnlinkedCarA(name, prepare)
	test(name, function()
		setup()
		installBeamMP()
		patches.apply()
		unlink(game.carA)
		if prepare then prepare() end
		local back = core_vehicles.replaceVehicle("pickup", {config = "A with new part"}, game.carA)
		same(pickups(), 1, "copies of car A")
		same(back, nil, "what the rebuild returned")
		same(#game.rebuilt, 0, "cars rebuilt")
		same(game.beamMPCalls, 0, "BeamMP's rebuild calls")
		same(game.carB.JBeam, "sedan", "car B")
		same(game.walker.JBeam, "unicycle", "the walking avatar")
		same(#toasts, 1, "messages shown")
		same(toasts[1].type, "warning", "message type")
		same(toasts[1].title, "Mileage", "message title")
		expect(string.find(toasts[1].msg, "not linked to you on the server", 1, true), "message: " .. tostring(toasts[1].msg))
		same(countLines(logs, "W mileage.patches: "), 1, "warning lines")
		same(getPlayerVehicle(0), game.player, "the player's car after the refusal")
	end)
end

refusesUnlinkedCarA("on foot, fitting a part to an unlinked car A rebuilds nothing and says so")
refusesUnlinkedCarA("seated in car B, fitting a part to an unlinked car A rebuilds nothing and says so", function()
	game.player = game.carB
end)
refusesUnlinkedCarA("with car A and the walking avatar unlinked, nothing is rebuilt or spawned", function()
	unlink(game.walker)
end)

test("the quick repair on an unlinked car A, on foot, leaves the garage pointing at car A", function()
	setup()
	installBeamMP()
	patches.apply()
	unlink(game.carA)
	career_modules_inventory.spawnVehicle(CAR_A, 2)
	same(game.invToVeh[CAR_A], game.carA.id, "the garage's game vehicle for car A")
	same(game.walker.JBeam, "unicycle", "the walking avatar")
	same(pickups(), 1, "copies of car A")
	same(#game.rebuilt, 0, "cars rebuilt")
end)

--== everything else keeps BeamMP's behaviour ================================

local function keepsBeamMP(name, named, prepare)
	test(name, function()
		setup()
		installBeamMP()
		patches.apply()
		game.player = game.carB
		local seen
		local realReplace = game.beamMPReplace
		if prepare then prepare() end
		named = type(named) == "function" and named() or named
		game.duringRebuild = function() seen = rawget(_G, "getPlayerVehicle") end
		core_vehicles.replaceVehicle("pickup", {}, named)
		same(game.beamMPCalls, 1, "BeamMP's rebuild calls")
		same(seen, game.realGetPlayerVehicle, "the game's getPlayerVehicle during the rebuild")
		expect(rebuiltOnly(game.carB.id), "BeamMP rebuilt the car the player is in")
		same(#toasts, 0, "messages shown")
	end)
end

keepsBeamMP("a rebuild that names no car keeps BeamMP's behaviour", nil)
keepsBeamMP("a rebuild of another player's car keeps BeamMP's behaviour", function()
	local remote = newObj("van")
	game.mp[remote.id] = {isLocal = false, own = false}
	return remote
end)
keepsBeamMP("a rebuild naming a destroyed car keeps BeamMP's behaviour", function()
	game.carA.destroyed = true
	return game.carA
end)

--== staying on top of BeamMP ================================================

test("BeamMP installed over the wrapper is wrapped again once, with no nesting", function()
	setup()
	patches.apply()
	installBeamMP()
	patches.onUpdate(3)
	patches.onUpdate(3)
	game.player = game.carB
	local back = core_vehicles.replaceVehicle("pickup", {}, game.carA)
	same(back, game.carA, "the car that came back")
	expect(rebuiltOnly(game.carA.id), "only car A was rebuilt")
	same(game.beamMPCalls, 1, "BeamMP's rebuild calls")
	same(game.carB.JBeam, "sedan", "car B")
end)

test("revert leaves BeamMP's rebuild in place", function()
	setup()
	installBeamMP()
	patches.apply()
	patches.revert()
	same(core_vehicles.replaceVehicle, game.beamMPReplace, "core_vehicles.replaceVehicle")
end)

--== the garage computer seats the player in the clicked car =================

local function clickAt(button, inv)
	career_modules_computer.openMenu(COMPUTER_FACILITY)
	career_modules_computer.computerButtonCallback(button, inv)
end

for button, hookName in pairs({
	partShopping = "onPartShoppingStartedMP",
	tuning = "onCareerTuningStartedMP",
	painting = "onVehiclePaintingUiOpenedMP",
}) do
	test("a click on car A for " .. button .. " announces car A with car B listed first", function()
		setup()
		patches.apply()
		clickAt(button, CAR_A)
		local args = announced(hookName)
		expect(args, hookName .. " was announced")
		same(args[2], CAR_A, "inventory id")
		same(args[1], game.carA.id, "game vehicle id")
	end)
end

test("a menu opened with no click keeps the old guess", function()
	setup()
	patches.apply()
	patches.onCareerTuningStarted()
	same(announced("onCareerTuningStartedMP")[2], CAR_B, "inventory id")
end)

test("a menu opened with an explicit car keeps that car", function()
	setup()
	patches.apply()
	career_modules_tuning.start(CAR_A)
	patches.onCareerTuningStarted()
	same(announced("onCareerTuningStartedMP")[2], CAR_A, "inventory id")
end)

test("the click is used once: a later menu opened elsewhere guesses again", function()
	setup()
	patches.apply()
	clickAt("partShopping", CAR_A)
	patches.onCareerTuningStarted()
	same(announced("onCareerTuningStartedMP")[2], CAR_B, "inventory id")
end)

test("a click that opened no menu is dropped on revert, a general button and a reopened computer", function()
	for _, drop in ipairs({
		function() patches.revert() patches.apply() end,
		function() career_modules_computer.computerButtonCallback("sell", nil) end,
		function() career_modules_computer.openMenu(COMPUTER_FACILITY) end,
	}) do
		setup()
		patches.apply()
		clickAt("repair", CAR_A)
		drop()
		patches.onCareerTuningStarted()
		same(announced("onCareerTuningStartedMP")[2], CAR_B, "inventory id")
	end
end)

test("parts fitted after a click on car A are announced for car A", function()
	setup()
	patches.apply()
	clickAt("partShopping", CAR_A)
	career_modules_partShopping.installPart("bumper")
	same(announced("onPartShoppingPartInstalledMP")[1].inventoryId, CAR_A, "inventory id")
end)

--== edges of the rebuild wrapper ============================================

test("after a rebuild that raises, the next rebuild naming car A still goes to car A", function()
	setup()
	installBeamMP()
	patches.apply()
	game.player = game.carB
	game.raiseOnRebuild = true
	pcall(core_vehicles.replaceVehicle, "pickup", {}, game.carA)
	game.raiseOnRebuild = false
	local back = core_vehicles.replaceVehicle("pickup", {}, game.carA)
	same(back, game.carA, "the car that came back")
	expect(rebuiltOnly(game.carA.id), "only car A was rebuilt")
	same(game.carB.JBeam, "sedan", "car B")
end)

test("during a rebuild naming car A, the answer for any other player is the real one", function()
	setup()
	local otherPlayersCar = newObj("van")
	game.realGetPlayerVehicle = function(player)
		if player == 0 then return game.player end
		if player == 1 then return otherPlayersCar end
		return nil
	end
	rawset(_G, "getPlayerVehicle", game.realGetPlayerVehicle)
	installBeamMP()
	patches.apply()
	game.player = game.carB
	local seenPlayer1
	game.duringRebuild = function() seenPlayer1 = getPlayerVehicle(1) end
	core_vehicles.replaceVehicle("pickup", {}, game.carA)
	same(seenPlayer1, otherPlayersCar, "player 1's car during the rebuild")
end)

test("a rebuild passes every argument through, the fourth included, on both paths", function()
	setup()
	installBeamMP()
	local beamMP = core_vehicles.replaceVehicle
	local calls = {}
	core_vehicles.replaceVehicle = function(model, opt, other, wholeCollection)
		table.insert(calls, {model = model, opt = opt, other = other, whole = wholeCollection})
		return beamMP(model, opt, other, wholeCollection)
	end
	patches.apply()
	game.player = game.carB
	local opt = {config = "x"}
	local remote = newObj("van")
	game.mp[remote.id] = {isLocal = false, own = false}
	core_vehicles.replaceVehicle("pickup", opt, game.carA, true)
	core_vehicles.replaceVehicle("pickup", opt, remote, true)
	same(#calls, 2, "calls reaching BeamMP")
	for i, named in ipairs({game.carA, remote}) do
		same(calls[i].model, "pickup", "model " .. i)
		same(calls[i].opt, opt, "options table " .. i)
		same(calls[i].other, named, "named car " .. i)
		same(calls[i].whole, true, "replaceWholeCollection " .. i)
	end
end)

test("outside multiplayer a rebuild naming car A goes straight to the game's rebuild", function()
	setup()
	MPVehicleGE = nil
	patches.apply()
	game.player = game.carB
	local seen
	game.duringRebuild = function() seen = rawget(_G, "getPlayerVehicle") end
	local back = core_vehicles.replaceVehicle("pickup", {}, game.carA)
	same(back, game.carA, "the car that came back")
	expect(rebuiltOnly(game.carA.id), "only car A was rebuilt")
	same(seen, game.realGetPlayerVehicle, "the game's getPlayerVehicle during the rebuild")
	same(#toasts, 0, "messages shown")
	same(countLines(logs, "E mileage.patches: "), 0, "error lines")
end)

test("a rebuild that returns nothing is not reported as a wrong car", function()
	setup()
	core_vehicles.replaceVehicle = function() return nil end
	installBeamMP()
	patches.apply()
	game.player = game.carB
	local back = core_vehicles.replaceVehicle("pickup", {}, game.carA)
	same(back, nil, "what the rebuild returned")
	same(#toasts, 0, "messages shown")
	same(countLines(logs, "E mileage.patches: "), 0, "error lines")
	same(getPlayerVehicle(0), game.carB, "the player's car")
end)

--== staying on top of BeamMP, over time ======================================

test("BeamMP installed over the wrapper is wrapped again once over many updates", function()
	setup()
	patches.apply()
	installBeamMP()
	for _ = 1, 6 do patches.onUpdate(3) end
	same(countLines(logs, "wrapped it again"), 1, "times wrapped again")
end)

test("revert after wrapping BeamMP again leaves BeamMP's rebuild in place", function()
	setup()
	patches.apply()
	installBeamMP()
	patches.onUpdate(3)
	patches.revert()
	same(core_vehicles.replaceVehicle, game.beamMPReplace, "core_vehicles.replaceVehicle")
end)

test("career starting again after BeamMP was wrapped again still rebuilds only car A", function()
	setup()
	patches.apply()
	installBeamMP()
	patches.onUpdate(3)
	patches.onCareerActive(true)
	game.player = game.carB
	local back = core_vehicles.replaceVehicle("pickup", {}, game.carA)
	same(back, game.carA, "the car that came back")
	expect(rebuiltOnly(game.carA.id), "only car A was rebuilt")
	same(game.beamMPCalls, 1, "BeamMP's rebuild calls")
	same(game.carB.JBeam, "sedan", "car B")
	same(getPlayerVehicle(0), game.carB, "the player's car after the rebuild")
end)

test("the walking avatar still spawns with BeamMP's visible config beside the rebuild wrapper", function()
	setup()
	local spawned
	core_vehicles.spawnNewVehicle = function(model, opt) spawned = opt return newObj(model) end
	patches.apply()
	installBeamMP()
	patches.onUpdate(3)
	core_vehicles.spawnNewVehicle("unicycle", {config = "vehicles/unicycle/without_mesh.pc"})
	same(spawned and spawned.config, "vehicles/unicycle/beammp_default.pc", "the avatar's config")
end)

--== the garage computer, edges ===============================================

test("Mileage ships no copy of the game's garage computer module", function()
	same(loadfile(COMPUTER_COPY), nil, "a loadable " .. COMPUTER_COPY)
end)

test("the garage computer's menu stays open within 25 m of its door, or of the computer without one", function()
	setup()
	patches.apply()
	career_modules_computer.openMenu(COMPUTER_FACILITY)
	same(#game.tethers, 1, "tethers started")
	same(game.tethers[1].kind, "door", "first tether")
	same(game.tethers[1].range, 25, "door range")
	game.tethers, game.doorTetherFails = {}, true
	career_modules_computer.openMenu(COMPUTER_FACILITY)
	same(game.tethers[2] and game.tethers[2].kind, "sphere", "fallback tether")
	same(game.tethers[2].range, 25, "fallback range")
	career_modules_computer.openMenu({id = "noDoor", name = "Garage", doors = {}})
	same(game.tethers[3] and game.tethers[3].range, 25, "range with no door")
end)

test("a tether started anywhere but the garage computer keeps the game's range", function()
	setup()
	patches.apply()
	career_modules_computer.openMenu(COMPUTER_FACILITY)
	career_modules_tether.startDoorTether({}, 1)
	career_modules_tether.startSphereTether({}, 4)
	same(game.tethers[2].range, 1, "door range")
	same(game.tethers[3].range, 4, "sphere range")
end)

test("the game's tether starts are put back even when the computer fails to open", function()
	setup()
	local door, sphere = career_modules_tether.startDoorTether, career_modules_tether.startSphereTether
	patches.apply()
	career_modules_inventory.getInventoryIdsInClosestGarage = function() error("no garage") end
	local ok = pcall(career_modules_computer.openMenu, COMPUTER_FACILITY)
	same(ok, false, "openMenu succeeded")
	same(career_modules_tether.startDoorTether, door, "startDoorTether")
	same(career_modules_tether.startSphereTether, sphere, "startSphereTether")
end)

test("revert puts the game's garage computer functions back", function()
	setup()
	local open, button = career_modules_computer.openMenu, career_modules_computer.computerButtonCallback
	patches.apply()
	expect(career_modules_computer.computerButtonCallback ~= button, "computerButtonCallback was patched")
	patches.revert()
	same(career_modules_computer.openMenu, open, "openMenu")
	same(career_modules_computer.computerButtonCallback, button, "computerButtonCallback")
end)

test("a game without computerButtonCallback is reported and the patches are tried again", function()
	setup()
	career_modules_computer.computerButtonCallback = nil
	same(patches.apply(), false, "applied")
	local named = false
	for _, name in ipairs(patches.getFailures()) do
		if name == "career_modules_computer.computerButtonCallback" then named = true end
	end
	expect(named, "the missing function was reported")
end)

test("a click on car A wins over a Parts session left recorded for car B", function()
	setup()
	patches.apply()
	career_modules_partShopping.startShopping(CAR_B)
	patches.onPartShoppingStarted()
	clickAt("partShopping", CAR_A)
	same(announced("onPartShoppingStartedMP")[2], CAR_A, "inventory id")
end)
