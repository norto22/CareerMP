--CareerMP 0.39 :: runtime patches
--
-- Replaces the shadow-fork approach of CareerMP 0.0.37.
--
-- The old mod shipped whole copies of career modules at the game's own paths so
-- its copy would win. Across 10 files and ~6,600 lines its actual intent was
-- ~136 changed lines, and most of those just added an argument to an
-- extensions.hook call so CareerMP could tell WHICH vehicle an event was about.
-- With no markers in the forked files, every game update meant re-forking blind.
--
-- Here we do the opposite: leave the game's files alone, and recover the missing
-- context ourselves.
--
--   * The stock hook still provides the TIMING (it fires where it always did).
--   * A thin wrapper on the module's entry point records the WHICH.
--
-- So callers get an enriched hook without the game being modified, and if a
-- wrap target ever disappears it is reported at load instead of silently
-- reverting to stock behaviour.
--
-- Hooks published here (consumed by careerMPEnabler and friends):
--   onCareerTuningStartedMP(vehId, inventoryId)
--   onPartShoppingStartedMP(vehId, inventoryId)
--   onVehiclePaintingUiOpenedMP(vehId, inventoryId)
--   onPartShoppingPartInstalledMP({part=, inventoryId=})
--   onPartShoppingTransactionCompleteMP(inventoryId)
--   onInventorySpawnVehicleMP(inventoryId, vehId)
--   onPerformanceTestStartedMP(vehId, inventoryId)
--
-- See docs/0.39-PORTING-RESEARCH.md.

-- Walking avatar config. Career spawns the unicycle as
-- vehicles/unicycle/without_mesh.pc -- invisible, which is fine in single player
-- where nobody has to see you walking around. In multiplayer everyone else needs
-- a visible avatar, so BeamMP ships a config with a mesh.
--
-- CareerMP 0.0.37 forked all 440 lines of gameplay/walk.lua to change this one
-- string (plus an MPVehicleGE.isOwn() guard that 0.39 made unnecessary: the old
-- code scanned every vehicle for any inactive unicycle and could grab another
-- player's, whereas 0.39 tracks its own unicycleId). Wrapping the spawn call
-- gets the same result without the fork.
local CAREER_UNICYCLE_CONFIG = "vehicles/unicycle/without_mesh.pc"
local MP_UNICYCLE_CONFIG = "vehicles/unicycle/beammp_default.pc"

local M = {}

local applied = false
local originals = {}
local failures = {}

-- Last inventoryId handed to each menu entry point. The stock hooks carry no
-- arguments, so this is how we know what they refer to when they fire.
local pending = {
	tuning = nil,
	partShopping = nil,
	painting = nil,
}

local function resolveVehId(inventoryId)
	local inventory = career_modules_inventory
	if not inventory or not inventoryId then return nil end
	return inventory.getVehicleIdFromInventoryId(inventoryId)
end

-- Falls back the same way the career modules do when a menu was opened by a path we
-- did not wrap. getCurrentVehicle alone is not enough: it is nil while the player is
-- walking, which is the normal state at the garage computer.
local function resolveInventoryId(recorded)
	if recorded then return recorded end
	local inventory = career_modules_inventory
	if not inventory then return nil end
	local current = inventory.getCurrentVehicle and inventory.getCurrentVehicle()
	if current then return current end
	if type(inventory.getInventoryIdsInClosestGarage) == "function" then
		return inventory.getInventoryIdsInClosestGarage(true)
	end
	return nil
end

-- Registry of every wrapper this module has installed.
--
-- Bookkeeping in `originals` alone is not enough to prevent double-wrapping, because
-- revert() clears it. When a game extension is reloaded (career does this on every
-- level change) the module table is replaced: revert restores the stale table while
-- the *live* one keeps our wrapper, `originals` ends up empty, and the next apply
-- wraps our own wrapper as if it were the original. That nests a layer per cycle --
-- observed live at 11 layers on core_vehicles.spawnNewVehicle, which is deep enough
-- that spawning the walking unicycle overflowed the stack and walking mode stopped
-- working entirely.
--
-- Recognising our own functions makes the guard independent of that bookkeeping.
-- Weak keys so collected wrappers do not pin memory.
local ourWrappers = setmetatable({}, {__mode = "k"})

local function isOurs(fn)
	return type(fn) == "function" and ourWrappers[fn] == true
end

-- Shared preamble: validates the target and reports whether it still needs wrapping.
local function prepare(moduleName, fnName, verb)
	local module = _G[moduleName]
	if type(module) ~= "table" or type(module[fnName]) ~= "function" then
		table.insert(failures, moduleName .. "." .. fnName)
		log("E", "careerMP.patches", string.format("cannot %s %s.%s (missing)", verb, moduleName, fnName))
		return nil
	end
	-- Already ours: nothing to do, and re-wrapping would nest.
	if isOurs(module[fnName]) then return nil, true end
	return module
end

local function register(moduleName, fnName, module, original, wrapper, verb)
	ourWrappers[wrapper] = true
	originals[moduleName .. "." .. fnName] = {
		moduleName = moduleName, module = module, fnName = fnName, fn = original,
	}
	module[fnName] = wrapper
	log("D", "careerMP.patches", verb .. " " .. moduleName .. "." .. fnName)
end

-- Wraps module[fnName], keeping the original for unpatching. `after` runs once
-- the original has returned and receives (returnValues, args).
local function wrap(moduleName, fnName, after)
	local module, alreadyOurs = prepare(moduleName, fnName, "wrap")
	if not module then return alreadyOurs == true end

	local key = moduleName .. "." .. fnName
	local original = module[fnName]

	register(moduleName, fnName, module, original, function(...)
		local args = {...}
		local results = {original(...)}
		local ok, err = pcall(after, results, args)
		if not ok then
			log("E", "careerMP.patches", string.format("post-hook for %s failed: %s", key, tostring(err)))
		end
		return unpack(results)
	end, "wrapped")
	return true
end

-- Full replacement, for cases where arguments must be altered before the call.
-- `replacement` is invoked as replacement(original, ...).
local function replace(moduleName, fnName, replacement)
	local module, alreadyOurs = prepare(moduleName, fnName, "replace")
	if not module then return alreadyOurs == true end

	local original = module[fnName]

	register(moduleName, fnName, module, original, function(...)
		return replacement(original, ...)
	end, "replaced")
	return true
end

--== recorders ===============================================================
-- These only remember which vehicle a menu is for. The enriched hook is fired
-- from the stock-hook handlers below so the timing stays identical to stock.

-- The garage computer opens these menus with a nil inventoryId and lets the module
-- work out which vehicle is meant. Each module has its own fallback chain, and the
-- ones that end at getInventoryIdsInClosestGarage are exactly the case that matters
-- here: the player is walking, so there is no "current vehicle" at all. Mirroring
-- the module's own resolution is what lets us name the right vehicle.
local function resolveClosestGarageVehicle()
	local inventory = career_modules_inventory
	if not inventory or type(inventory.getInventoryIdsInClosestGarage) ~= "function" then return nil end
	return inventory.getInventoryIdsInClosestGarage(true)
end

-- tuning.start / painting.start:
--   inventoryId = _inventoryId or getInventoryIdsInClosestGarage(true)
local function resolveMenuVehicle(passedId)
	return passedId or resolveClosestGarageVehicle()
end

-- partShopping.startShopping:
--   currentVehicle = inventoryId or getCurrentVehicle()
--   if not currentVehicle then currentVehicle = getInventoryIdsInClosestGarage(true) end
local function resolveShoppingVehicle(passedId)
	if passedId then return passedId end
	local inventory = career_modules_inventory
	local current = inventory and inventory.getCurrentVehicle and inventory.getCurrentVehicle()
	if current then return current end
	return resolveClosestGarageVehicle()
end

-- These must record BEFORE the original runs, not after.
--
-- start/startShopping call startActual straight through (or from the repair
-- callback), and startActual is what fires the stock hook. A post-call wrapper
-- therefore records the vehicle only after the hook it was meant to inform has
-- already fired, so the handler saw a stale value - which is why opening part
-- customisation while walking stopped seating the player in their car.
local function applyRecorders()
	-- tuning.start(inventoryId, originComputerId)
	replace("career_modules_tuning", "start", function(original, ...)
		local args = {...}
		pending.tuning = resolveMenuVehicle(args[1])
		return original(...)
	end)

	-- partShopping.startShopping(inventoryId, originComputerId)
	replace("career_modules_partShopping", "startShopping", function(original, ...)
		local args = {...}
		pending.partShopping = resolveShoppingVehicle(args[1])
		return original(...)
	end)

	-- painting.start(inventoryId, originComputerId)
	replace("career_modules_painting", "start", function(original, ...)
		local args = {...}
		pending.painting = resolveMenuVehicle(args[1])
		return original(...)
	end)
end

--== direct enrichments ======================================================
-- These have no stock hook we can piggyback on for the data we need, so the
-- wrapper fires the MP hook itself.

local function applyEnrichments()
	-- CareerMP invented onInventorySpawnVehicle: the per-part paint sync needs to
	-- know when an inventory vehicle gains a game vehicle id. spawnVehicle
	-- returns the vehicle object (or nil when a modded vehicle is missing).
	wrap("career_modules_inventory", "spawnVehicle", function(results, args)
		local vehObj = results[1]
		if vehObj and vehObj.getId then
			extensions.hook("onInventorySpawnVehicleMP", args[1], vehObj:getId())
		end
	end)

	-- Stock fires onPartShoppingPartInstalled with {part = part} only.
	wrap("career_modules_partShopping", "installPart", function(_, args)
		local inventoryId = resolveInventoryId(pending.partShopping)
		extensions.hook("onPartShoppingPartInstalledMP", { part = args[1], inventoryId = inventoryId })
	end)

	-- Stock fires onPartShoppingTransactionComplete with no arguments.
	wrap("career_modules_partShopping", "applyShopping", function()
		local inventoryId = resolveInventoryId(pending.partShopping)
		extensions.hook("onPartShoppingTransactionCompleteMP", inventoryId)
		pending.partShopping = nil
	end)

	-- vehiclePerformance never fires a start hook in 0.38.6 or 0.39, so
	-- CareerMP 0.0.37's onPerformanceTestStarted binding was always dead and the
	-- certification menu never pulled the player into the car. startDragTest is
	-- exported, so wrapping it makes that case work for the first time.
	wrap("career_modules_vehiclePerformance", "startDragTest", function()
		local inventoryId = resolveInventoryId(nil)
		extensions.hook("onPerformanceTestStartedMP", resolveVehId(inventoryId), inventoryId)
	end)
end

--== walking avatar: getInVehicle crash guard ================================
-- gameplay/walk.lua:86 (0.39):
--
--     local function getInVehicle(vehicle)
--       local unicycle = getCurrentUnicycle()
--       be:enterVehicle(0, vehicle)          -- <-- switch happens here
--       if unicycle then
--         unicycleId = unicycle:getId()      -- line 90
--         setUnicycleInactive(unicycle)
--
-- The unicycle reference is captured before the switch and used after it. If
-- anything destroys the unicycle in response to the switch, line 90 raises
-- "Attempted to call a function on an object that no longer exists" -- a *fatal*
-- Lua error, not a caught one.
--
-- Single player never destroys it there, so this is latent. In multiplayer the
-- walking avatar is a synced vehicle and can be despawned as part of entering a
-- car, which makes the race reachable. Seen live when buying a vehicle:
-- career/modules/vehicleShopping.lua:591 seats the player via getInVehicle
-- immediately after the purchase.
--
-- By the time it throws, be:enterVehicle has already run, so the player is in the
-- vehicle and the only work skipped is bookkeeping for a unicycle that no longer
-- exists. walk.lua's own onVehicleDestroyed already clears unicycleId in that case.
-- So catching it loses nothing and turns a session-ending error into a log line.
--
-- Stock bug, worth reporting upstream: capturing the id before the switch, or
-- re-resolving after it, would fix it properly.
--
-- Guarding M.getInVehicle alone is not enough. walk.lua also calls it as a *local*
-- from setWalkingMode (line 149, the `vehicleInFront` branch), and a local call never
-- goes through the module table, so the wrapper is bypassed -- the traceback says
-- "Lua upvalue 'getInVehicle'" rather than "Lua field". That is the path taken when the
-- player simply walks up to a car and presses enter.
--
-- There is exactly one such internal call site, so guarding the three module entry
-- points that can reach it gives full coverage without forking walk.lua:
--
--   M.getInVehicle        - external callers (vehicleShopping, testDrive, tutorial)
--   M.setWalkingMode      - direct callers passing false
--   M.toggleWalkingMode   - the input binding; calls the local setWalkingMode
-- Same message every frame is noise that buries the first occurrence, which is the
-- one that matters. Log a given failure once, then only again if it changes.
local lastWalkFailure = {}

-- Depth counter per guarded function.
--
-- walk.lua is legitimately re-entrant: setWalkingMode fires
-- onBeforeWalkingModeToggled, career_modules_inventory answers it by calling
-- enterVehicle -> enterVehicleActual, and that calls gameplay_walk.setWalkingMode
-- straight back through the module table -- i.e. through this wrapper. A couple of
-- levels of that is normal and must be allowed through.
--
-- What is not normal is unbounded growth, and the wrapper needs to know the
-- difference. Past this depth the call is refused rather than recursed into, which
-- turns an eventual stack overflow into one logged line naming the function.
local walkDepth = {}
local MAX_WALK_DEPTH = 8

local function guardWalkFn(fnName, describe)
	replace("gameplay_walk", fnName, function(original, ...)
		local depth = (walkDepth[fnName] or 0) + 1
		walkDepth[fnName] = depth

		if depth > MAX_WALK_DEPTH then
			walkDepth[fnName] = depth - 1
			if lastWalkFailure[fnName] ~= "depth" then
				lastWalkFailure[fnName] = "depth"
				log("E", "careerMP.patches", string.format(
					"gameplay_walk.%s re-entered more than %d deep - refusing to recurse further",
					fnName, MAX_WALK_DEPTH))
				log("E", "careerMP.patches", debug.traceback("", 2))
			end
			return describe and describe(...) or nil
		end

		-- xpcall, not pcall: pcall discards the stack, and the stack is the only thing
		-- that identifies where a recursion actually goes.
		local traceback
		local results = {xpcall(function(...) return original(...) end,
			function(err) traceback = debug.traceback(tostring(err), 2) return err end, ...)}
		local ok = table.remove(results, 1)

		walkDepth[fnName] = depth - 1

		if ok then
			lastWalkFailure[fnName] = nil
			return unpack(results)
		end

		local err = tostring(results[1])
		if lastWalkFailure[fnName] ~= err then
			lastWalkFailure[fnName] = err
			log("W", "careerMP.patches", string.format("gameplay_walk.%s failed: %s", fnName, err))
			log("W", "careerMP.patches", traceback or "(no traceback captured)")
		end

		return describe and describe(...) or nil
	end)
end

local function applyWalkGuard()
	guardWalkFn("getInVehicle", function(vehicle)
		-- be:enterVehicle already ran inside the original before it threw, so the
		-- player is seated; this only covers it having thrown earlier than that.
		if vehicle then
			local alive = pcall(function() return vehicle:getId() end)
			if alive then pcall(function() be:enterVehicle(0, vehicle) end) end
		end
	end)

	-- setWalkingMode returns (succeeded, unicycleId). Reporting "not walking" with no
	-- unicycle is the truthful answer once the unicycle has been destroyed.
	guardWalkFn("setWalkingMode", function(enabled)
		return not enabled, nil
	end)

	-- NOT toggleWalkingMode. BeamMP owns that one.
	--
	-- beammp/multiplayer.lua installs its own modifiedToggleWalkingMode (it deletes
	-- the unicycle after entering a vehicle, so the avatar disappears for everyone
	-- else) and re-asserts it from its onUpdate every frame:
	--
	--     if gameplay_walk.toggleWalkingMode ~= modifiedToggleWalkingMode then
	--       originalToggleWalkingMode = gameplay_walk.toggleWalkingMode
	--       gameplay_walk.toggleWalkingMode = modifiedToggleWalkingMode
	--     end
	--
	-- Wrapping it therefore cannot work: we capture BeamMP's function as our
	-- "original", and on the very next frame BeamMP captures ours as *its* original
	-- and reinstalls itself. The two wrappers then call each other until the stack
	-- runs out, which is what stopped walking mode working entirely -- the traceback
	-- alternated between beammp/multiplayer.lua:42 and this file forever.
	--
	-- Anything BeamMP re-asserts per frame has to be left alone. As of its 0.39
	-- release that is: gameplay_walk.toggleWalkingMode, gameplay_walk.onVehicleSwitched,
	-- core_camera.getDriverData, and onInstabilityDetected.
end

--== walking avatar ==========================================================

local function applyUnicyclePatch()
	-- The config has to be rewritten before the call, so this one replaces the
	-- function outright rather than appending a post-hook.
	replace("core_vehicles", "spawnNewVehicle", function(original, modelName, opt)
		if modelName == "unicycle" and type(opt) == "table"
			and opt.config == CAREER_UNICYCLE_CONFIG
			and FS:fileExists(MP_UNICYCLE_CONFIG) then
			opt = deepcopy(opt)
			opt.config = MP_UNICYCLE_CONFIG
		end
		return original(modelName, opt)
	end)
end

--== stock hook handlers =====================================================
-- Re-broadcast the stock hooks with the vehicle context attached.

function M.onCareerTuningStarted()
	local inventoryId = resolveInventoryId(pending.tuning)
	extensions.hook("onCareerTuningStartedMP", resolveVehId(inventoryId), inventoryId)
end

function M.onPartShoppingStarted()
	local inventoryId = resolveInventoryId(pending.partShopping)
	extensions.hook("onPartShoppingStartedMP", resolveVehId(inventoryId), inventoryId)
end

function M.onVehiclePaintingUiOpened()
	local inventoryId = resolveInventoryId(pending.painting)
	extensions.hook("onVehiclePaintingUiOpenedMP", resolveVehId(inventoryId), inventoryId)
end

-- 0.39 renamed the computer hook: onComputerMenuOpened -> onComputerOpened.
-- CareerMP's fork existed partly to rename it; listening to both costs nothing.
function M.onComputerOpened()
	extensions.hook("onComputerOpenedMP")
end

function M.onComputerMenuOpened()
	extensions.hook("onComputerOpenedMP")
end

-- Menus closing invalidates the recorded ids.
function M.onPartShoppingCancelled()
	pending.partShopping = nil
end

--== lifecycle ===============================================================

-- Set once the failure list has been reported, so a target that is missing for good
-- does not log on every frame of the retry loop.
local reportedFailures = false

function M.apply()
	if applied then return true end
	failures = {}

	applyRecorders()
	applyEnrichments()
	applyUnicyclePatch()
	applyWalkGuard()

	-- Only count as applied when everything landed. Marking it applied regardless
	-- would let a call made before the career modules exist stick, and the retry
	-- would never run again -- which is exactly how the wrappers ended up never
	-- being installed at all.
	applied = (#failures == 0)

	if not applied then
		if not reportedFailures then
			reportedFailures = true
			log("W", "careerMP.patches", "patch targets not available yet, will retry:")
			for _, name in ipairs(failures) do
				log("W", "careerMP.patches", "  " .. name)
			end
		end
		return false
	end

	reportedFailures = false
	log("I", "careerMP.patches", "all runtime patches applied")
	return true
end

function M.revert()
	for key, entry in pairs(originals) do
		-- Restore against the LIVE module, not the one captured at wrap time: if the
		-- extension was reloaded since, the captured table is stale and writing to it
		-- leaves our wrapper in place on the table everything actually calls.
		local module = _G[entry.moduleName] or entry.module
		if isOurs(module[entry.fnName]) then
			module[entry.fnName] = entry.fn
			log("D", "careerMP.patches", "unwrapped " .. key)
		else
			-- Reloaded out from under us, or someone else wrapped on top. Either way
			-- the current function is not ours to restore, and overwriting it would
			-- clobber whatever legitimately replaced it.
			log("D", "careerMP.patches", "skipped unwrap of " .. key .. " (no longer ours)")
		end
	end
	originals = {}
	applied = false
	pending.tuning, pending.partShopping, pending.painting = nil, nil, nil
end

function M.isApplied() return applied end
function M.getFailures() return deepcopy(failures) end

-- Career modules are loaded/unloaded when career activates, so wrappers must be
-- (re)installed each time rather than once at extension load.
function M.onCareerActive(active)
	if active then
		M.revert()
		M.apply()
	else
		M.revert()
	end
end

-- Relying on onCareerActive alone was not enough: the wrappers silently never got
-- installed, and because nothing here logged at load there was no sign of it. The
-- retry below makes the module self-starting, and the load/apply messages make a
-- repeat of this visible in the log instead of showing up as a feature quietly
-- doing nothing.
-- Retry is throttled rather than per-frame. If a target is legitimately absent (a
-- career module that is simply not loaded), `applied` never becomes true and an
-- unthrottled retry would call apply() every frame forever.
local retryAccumulator = 0
local RETRY_INTERVAL = 2 -- seconds

local function onUpdate(dtReal)
	if applied then return end

	retryAccumulator = retryAccumulator + (dtReal or 0)
	if retryAccumulator < RETRY_INTERVAL then return end
	retryAccumulator = 0

	-- Cheap guard: only worth trying once the career modules actually exist.
	if career_modules_partShopping or career_modules_tuning or career_modules_painting then
		M.apply()
	end
end

local function onExtensionLoaded()
	log("I", "careerMP.patches", "CareerMP patches LOADED")
	-- Career modules may not exist yet; onUpdate/onCareerActive retry.
	M.apply()
end

local function onExtensionUnloaded()
	M.revert()
	log("I", "careerMP.patches", "CareerMP patches UNLOADED")
end

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
