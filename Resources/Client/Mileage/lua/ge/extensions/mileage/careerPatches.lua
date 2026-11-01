--Mileage :: career.lua patches
--
-- Three changes to the game's career.lua, made as runtime wrappers so the game's
-- own career logic stays live:
--   1. activateCareer: drop the `removeVehicles == nil -> true` default
--   2. activateCareer: drop the `else removeNonTrafficVehicles()` branch
--   3. createOrLoadCareerAndStart: call activateCareer(false)
--
-- Why any of this matters: career activation assumes a single-player world and
-- clears the level of vehicles it does not recognise. In multiplayer that means
-- deleting every other player's car.
--
-- It also keeps one failing career-start handler from leaving the rest of the career
-- unset (see "career-active handlers" below).

local M = {}

local logTag = "mileage.careerPatches"

local applied = false
local originals = {}

--== career-active handlers ==================================================
-- The career starts every module by firing the onCareerActive hook. The game's hook
-- (lua/common/extensions.lua, hookFast) calls each extension's handler in turn with no
-- protection, so the first handler that raises an error skips every handler after it:
-- insurance, for one, then runs without its saved data. The hook also caches the list
-- it built while running, so the skipped handlers stay skipped for later calls too.
--
-- From onBeforeCareerActivate until the career-active hook has run, extensions.hook is
-- replaced. When it is asked for onCareerActive, every loaded extension's handler is
-- swapped for one that runs it under xpcall, the hook's cache is dropped, and the game's
-- own hook runs them in its own order. A failure is logged with its traceback and the
-- next handler still runs. Afterwards the handlers and the hook are put back.
local GUARD_MAX_SECONDS = 120 -- longer than any career start, level change included

-- {originalHook, guardedHook, installedAt, wrapped = {[module] = {original, wrapper}}}
local guard = nil

-- Handlers that failed in the last guarded onCareerActive, as extension names.
local careerActiveFailures = {}

local GUARD_NEEDS = {"hook", "hookUpdate", "getLoadedExtensionsNames"}

local function wrapCareerActiveHandlers(ext)
	for _, name in ipairs(ext.getLoadedExtensionsNames() or {}) do
		-- rawget: a plain lookup on extensions loads a missing extension.
		local m = rawget(ext, name) or rawget(_G, name)
		local original = type(m) == "table" and rawget(m, "onCareerActive")
		if type(original) == "function" and not guard.wrapped[m] then
			local wrapper = function(...)
				local ok, err = xpcall(original, debug.traceback, ...)
				if not ok then
					table.insert(careerActiveFailures, name)
					log("E", logTag, "career start: " .. name .. ".onCareerActive failed, the other handlers " ..
						"still run: " .. tostring(err))
				end
			end
			guard.wrapped[m] = {original = original, wrapper = wrapper}
			m.onCareerActive = wrapper
		end
	end
	ext.hookUpdate("onCareerActive")
end

local function unwrapCareerActiveHandlers(ext)
	for m, entry in pairs(guard.wrapped) do
		if rawget(m, "onCareerActive") == entry.wrapper then m.onCareerActive = entry.original end
	end
	guard.wrapped = {}
	ext.hookUpdate("onCareerActive")
end

local function removeGuard(why)
	if not guard then return end
	local ext = extensions
	unwrapCareerActiveHandlers(ext)
	if ext.hook == guard.guardedHook then
		ext.hook = guard.originalHook
	else
		log("W", logTag, "career start: extensions.hook was replaced by someone else - left as it is")
	end
	guard = nil
	log("D", logTag, "career-active handler guard removed (" .. why .. ")")
end

local function installGuard()
	if guard then return end
	local ext = extensions
	local missing = {}
	for _, name in ipairs(GUARD_NEEDS) do
		if type(ext) ~= "table" or type(ext[name]) ~= "function" then table.insert(missing, "extensions." .. name) end
	end
	if #missing > 0 then
		log("W", logTag, "career start: missing " .. table.concat(missing, ", ") ..
			" - a failing onCareerActive handler will skip the ones after it")
		return
	end

	guard = {originalHook = ext.hook, installedAt = os.clockhp(), wrapped = {}}
	local current = guard
	guard.guardedHook = function(funcName, ...)
		if funcName ~= "onCareerActive" or guard ~= current then return current.originalHook(funcName, ...) end
		careerActiveFailures = {}
		wrapCareerActiveHandlers(ext)
		local ok, err = pcall(current.originalHook, funcName, ...)
		local active = ...
		if #careerActiveFailures > 0 then
			log("E", logTag, "career start: onCareerActive(" .. tostring(active) .. ") failed in " ..
				table.concat(careerActiveFailures, ", ") .. "; every other handler ran")
		else
			log("I", logTag, "career start: every onCareerActive(" .. tostring(active) .. ") handler ran")
		end
		if active then removeGuard("career active") else unwrapCareerActiveHandlers(ext) end
		if not ok then error(err, 0) end
	end
	ext.hook = guard.guardedHook
end

--- Extension names whose onCareerActive failed in the last guarded career start.
function M.getCareerActiveFailures()
	local list = {}
	for i, name in ipairs(careerActiveFailures) do list[i] = name end
	return list
end

--== protecting remote vehicles ==============================================
-- 0.39 career.lua:
--
--   local function removeNonTrafficVehicles()
--     local safeIds = gameplay_traffic.getTrafficList(true)
--     safeIds = arrayConcat(safeIds, gameplay_parking.getParkedCarsList(true))
--     for i = be:getObjectCount()-1, 0, -1 do
--       local objId = be:getObject(i):getID()
--       if not tableContains(safeIds, objId) then
--         be:getObject(i):delete()
--       end
--     end
--   end
--
-- It is a file-local, so it cannot be replaced directly. Instead we widen what
-- it considers safe for the duration of the call: getTrafficList is wrapped to
-- return the traffic ids PLUS every vehicle we do not own. Anything of ours it
-- still removes, which is what career wants.
--
-- Note we return a fresh table rather than appending to the game's. 0.39's
-- getTrafficList returns the live trafficAiVehsList by reference, and
-- removeNonTrafficVehicles then arrayConcats parked ids into it -- so the game
-- is already mutating its own traffic list here. Copying keeps us out of that.
local function collectRemoteVehicleIds()
	local remote = {}
	if not MPVehicleGE or not MPVehicleGE.getVehicles then return remote end
	for _, vehicle in pairs(MPVehicleGE.getVehicles() or {}) do
		local id = vehicle.gameVehicleID
		if id and id ~= -1 and not MPVehicleGE.isOwn(id) then
			remote[id] = true
		end
	end
	return remote
end

--- Protection against career activation deleting other players' cars.
---
--- activateCareer clears the level of vehicles it does not recognise, which in
--- multiplayer means every other player's car. It has two ways of doing it and BOTH
--- have to be covered:
---
---   core_vehicles.removeAll()       when removeVehicles is true (the default)
---   removeNonTrafficVehicles()      when it is false
---
--- removeNonTrafficVehicles is a file-local, but it decides what to spare via
--- gameplay_traffic.getTrafficList, so widening that list protects remote cars.
--- removeAll is a module function and is replaced with one that removes only our own.
---
--- Installed from the onBeforeCareerActivate hook rather than by wrapping
--- activateCareer. That is deliberate: createOrLoadCareerAndStart calls its *local*
--- activateCareer(), so a wrapper on career_career.activateCareer never sees it -- and
--- neither does it see a career loaded from the ESC menu, which is a different path
--- again. The hook fires inside activateCareer before either removal runs, so it covers
--- every route in.
local protection = nil

local function installProtection()
	if protection then return end

	local remote = collectRemoteVehicleIds()
	protection = { remote = remote, installedAt = os.clockhp() }

	local traffic = gameplay_traffic
	if traffic and traffic.getTrafficList then
		protection.originalGetTrafficList = traffic.getTrafficList
		traffic.getTrafficList = function(...)
			local list = protection.originalGetTrafficList(...)
			-- A fresh table: 0.39 returns the live trafficAiVehsList by reference and
			-- removeNonTrafficVehicles arrayConcats into it, so appending here would
			-- quietly corrupt the game's own traffic list.
			local safe = {}
			if type(list) == "table" then
				for _, id in ipairs(list) do table.insert(safe, id) end
			end
			for id in pairs(remote) do table.insert(safe, id) end
			return safe
		end
	end

	if core_vehicles and core_vehicles.removeAll then
		protection.originalRemoveAll = core_vehicles.removeAll
		core_vehicles.removeAll = function()
			local spared = 0
			for i = be:getObjectCount() - 1, 0, -1 do
				local obj = be:getObject(i)
				local id = obj and obj:getID()
				if id then
					if remote[id] then spared = spared + 1 else obj:delete() end
				end
			end
			if spared > 0 then
				log("I", logTag, string.format("career activation spared %d remote vehicle(s)", spared))
			end
		end
	end

	local count = 0
	for _ in pairs(remote) do count = count + 1 end
	log("D", logTag, string.format("vehicle protection installed (%d remote vehicle(s))", count))
end

local function removeProtection()
	if not protection then return end
	if protection.originalGetTrafficList and gameplay_traffic then
		gameplay_traffic.getTrafficList = protection.originalGetTrafficList
	end
	if protection.originalRemoveAll and core_vehicles then
		core_vehicles.removeAll = protection.originalRemoveAll
	end
	protection = nil
	log("D", logTag, "vehicle protection removed")
end

--- Fired by career.lua at the top of activateCareer, before either removal path.
function M.onBeforeCareerActivate()
	installProtection()
	installGuard()
end

--- Fired once the career is up. On the level-change path this is deferred, so onUpdate
--- also drops the protection after a few seconds as a safety net -- leaving removeAll
--- replaced indefinitely would break legitimate uses of it.
function M.onCareerActive(active)
	removeProtection()
end

local function pack(...)
	return {n = select("#", ...), ...}
end

--- Runs fn with remote vehicles protected. Returns true and fn's results, or false and
--- the error with its stack traceback, so the caller can report where it failed.
local function withRemoteVehiclesProtected(fn, ...)
	installProtection()
	local args = pack(...)
	local results = pack(xpcall(function() return fn(unpack(args, 1, args.n)) end, debug.traceback))
	removeProtection()
	if not results[1] then
		log("E", logTag, "protected call failed: " .. tostring(results[2]))
		return false, tostring(results[2])
	end
	return unpack(results, 1, results.n)
end

M.withRemoteVehiclesProtected = withRemoteVehiclesProtected

--== readiness ===============================================================

local warnedUnavailable = false

function M.apply()
	if applied then return true end

	-- career_career may not be loaded yet when the mod script runs, so this is
	-- retried (see ensure/onUpdate) rather than failed once and forgotten.
	if not career_career then
		if not warnedUnavailable then
			log("D", logTag, "career_career not loaded yet - will retry")
			warnedUnavailable = true
		end
		return false
	end

	-- Nothing to install: protection is driven by the onBeforeCareerActivate hook, so
	-- it covers every path into activateCareer -- including a career loaded from the
	-- ESC menu, which does not go through anything Mileage calls. All that is needed
	-- here is confirmation that career_career exists to fire the hook.
	applied = true
	log("I", logTag, "career vehicle protection armed (hook-driven)")
	return true
end

-- Idempotent; call before anything that could activate a career.
function M.ensure()
	if applied then return true end
	return M.apply()
end

function M.revert()
	removeProtection()
	removeGuard("reverted")
	applied = false
end

function M.isApplied() return applied end

-- Cheap retry until career_career shows up. Stops touching anything once applied.
local PROTECTION_MAX_SECONDS = 30

local function onUpdate()
	if not applied then M.apply() end
	-- Safety net: onCareerActive is deferred on the level-change path, and on a failed
	-- activation it may never arrive at all.
	if protection and (os.clockhp() - protection.installedAt) > PROTECTION_MAX_SECONDS then
		log("W", logTag, "vehicle protection timed out - releasing")
		removeProtection()
	end
	if guard and (os.clockhp() - guard.installedAt) > GUARD_MAX_SECONDS then
		log("W", logTag, string.format("career start: onCareerActive did not fire within %ds - " ..
			"handler guard removed", GUARD_MAX_SECONDS))
		removeGuard("timed out")
	end
end

local function onExtensionLoaded()
	M.apply() -- may be too early; onUpdate/ensure() will retry
	log("I", logTag, "Mileage career patches LOADED")
end

local function onExtensionUnloaded()
	M.revert()
	log("I", logTag, "Mileage career patches UNLOADED")
end

M.onUpdate = onUpdate

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
