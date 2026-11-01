--Mileage :: career traffic meter
--
-- The game's own career module (career/modules/playerDriving.lua) spawns career
-- traffic. It takes its road and parked amounts from the player's own settings and
-- hands them over in one place:
--
--   gameplay_traffic.setupTrafficHelper(trafficAmount, trafficOptions, parkingAmount, nil)
--   gameplay_traffic.setActiveAmount(trafficAmount)
--   gameplay_parking.setActiveAmount(parkingAmount)
--
-- On a server every player's traffic is shared with everyone, so the server decides
-- the amounts: this player's share of the server's traffic total, which shrinks as the
-- server fills (see "share changes"). For one career start this extension replaces those three functions so
-- the server's amounts go through instead, and each puts the game's function back after
-- its one call. Everything else (police, pursuits, fines, parking, tutorial handling)
-- stays the game's own code for whatever version the player runs.
--
-- If the career ever stops handing its amounts over this way, traffic still spawns at
-- the player's own setting and the log says the server's amounts were not applied.
--
-- For the whole server session it also hides the player's traffic around a mission
-- instead of letting the game delete and respawn it (see "mission hide").

local M = {}

local logTag = "mileage.traffic"

local MAX_AMOUNT = 50          -- the game's own upper limit for career traffic
local METER_MAX_SECONDS = 60   -- matches the join's limit from settings request to career start

-- Game functions replaced for the current career start, by "<module>.<function>":
-- {module = <table>, name = <function name>, original = <function>}.
local replaced = {}

-- The current career start, from onBeforeCareerActivate until traffic is ready:
-- {armedAt, applied = {road, parked} once the setup went through the meter}.
local start = nil

-- The tutorial restore replacement, kept for the whole server session.
local tutorial = nil

-- Settings already warned about in this join, so a bad value is reported once.
local warned = {}

--== replacing game functions ================================================

local function replace(module, moduleName, fnName, makeReplacement)
	if type(module) ~= "table" or type(module[fnName]) ~= "function" then return false end
	local key = moduleName .. "." .. fnName
	if replaced[key] then return true end
	local original = module[fnName]
	replaced[key] = {module = module, name = fnName, original = original}
	module[fnName] = makeReplacement(original, key)
	return true
end

local function restore(key)
	local entry = replaced[key]
	if not entry then return end
	entry.module[entry.name] = entry.original
	replaced[key] = nil
end

local function restoreAll(why)
	if not next(replaced) then return end
	for key in pairs(replaced) do restore(key) end
	log("D", logTag, "game traffic functions restored (" .. why .. ")")
end

--== server amounts ==========================================================

local function warnOnce(setting, value, used)
	if warned[setting] then return end
	warned[setting] = true
	log("W", logTag, string.format("%s = %s is out of range, using %d", setting, tostring(value), used))
end

local function amountFor(config, enabledKey, amountKey)
	if config[enabledKey] ~= true then return 0 end
	local raw = config[amountKey]
	local amount = tonumber(raw)
	if amount == nil or amount ~= amount then
		warnOnce(amountKey, raw, 0)
		return 0
	end
	local used = math.floor(math.max(0, math.min(MAX_AMOUNT, amount)))
	if used ~= amount then warnOnce(amountKey, raw, used) end
	return used
end

-- This player's share of the server's traffic total, when the server sent one.
local function shareFor(config, enabledKey, kind)
	if config[enabledKey] ~= true then return 0 end
	local raw = config.trafficShare[kind]
	local amount = tonumber(raw)
	if amount == nil or amount ~= amount then
		warnOnce("trafficShare." .. kind, raw, 0)
		return 0
	end
	local used = math.floor(math.max(0, math.min(MAX_AMOUNT, amount)))
	if used ~= amount then warnOnce("trafficShare." .. kind, raw, used) end
	return used
end

--- The road and parked amounts this player spawns: 0 for a switched-off kind, otherwise
--- the player's share of the server's traffic total (config.trafficShare) when the server
--- sent one, else the per-player amount, held to whole numbers from 0 to 50.
function M.serverAmounts(config)
	if type(config) ~= "table" then return 0, 0 end
	if type(config.trafficShare) == "table" then
		return shareFor(config, "roadTrafficEnabled", "road"), shareFor(config, "parkedTrafficEnabled", "parked")
	end
	return amountFor(config, "roadTrafficEnabled", "roadTrafficAmount"),
		amountFor(config, "parkedTrafficEnabled", "parkedTrafficAmount")
end

-- The server's client config while on a server, otherwise nil.
local function serverConfig()
	local compat = extensions.mileage_compat
	if type(compat) ~= "table" or not compat.isMPSession() then return nil end
	local enabler = mileageEnabler
	if type(enabler) ~= "table" or type(enabler.getClientConfig) ~= "function" then return nil end
	local config = enabler.getClientConfig()
	if type(config) ~= "table" then return nil end
	return config
end

local function onOff(enabled)
	return enabled == true and "on" or "off"
end

local function pack(...)
	return {n = select("#", ...), ...}
end

--== the career start ========================================================

-- The next call of <module>.setActiveAmount passes the server's amount instead of its
-- own, then the game's function is back.
local function setActiveAmountOnce(module, moduleName, amount)
	replace(module, moduleName, "setActiveAmount", function(original, key)
		return function(_, ...)
			restore(key)
			return original(amount, ...)
		end
	end)
end

-- Works out what to hand the game: the server's amounts and a copy of the options that
-- asks for police when there is road traffic. Arms the two active-amount calls.
local function prepareSetup(config, trafficOptions)
	local road, parked = M.serverAmounts(config)
	log("I", logTag, string.format("applying server traffic - road %d (%s), parked %d (%s)",
		road, onOff(config.roadTrafficEnabled), parked, onOff(config.parkedTrafficEnabled)))

	local options = {}
	if type(trafficOptions) == "table" then
		for k, v in pairs(trafficOptions) do options[k] = v end
	end
	-- The game's police provider adds police only when asked: about a quarter of the
	-- road cars, once there are at least 3.
	if road > 0 then options.police = true end

	setActiveAmountOnce(gameplay_traffic, "gameplay_traffic", road)
	setActiveAmountOnce(gameplay_parking, "gameplay_parking", parked)
	if start then start.applied = {road = road, parked = parked} end
	return road, options, parked
end

local function meterSetupTrafficHelper(config)
	return replace(gameplay_traffic, "gameplay_traffic", "setupTrafficHelper", function(original, key)
		return function(trafficAmount, trafficOptions, parkingAmount, parkingOptions, ...)
			-- One call only: the next setup (free roam, a mission) keeps its own amounts.
			restore(key)
			local prepared = pack(xpcall(prepareSetup, debug.traceback, config, trafficOptions))
			if not prepared[1] then
				log("E", logTag, "server traffic amounts not applied: " .. tostring(prepared[2]))
				return original(trafficAmount, trafficOptions, parkingAmount, parkingOptions, ...)
			end
			return original(prepared[2], prepared[3], prepared[4], parkingOptions, ...)
		end
	end)
end

local function arm()
	if start then return end
	local config = serverConfig()
	if not config then return end
	-- Anything left from an earlier start is put back before arming again.
	restoreAll("new career start")
	if not meterSetupTrafficHelper(config) then
		log("W", logTag, "gameplay_traffic.setupTrafficHelper missing - server traffic amounts not applied")
		return
	end
	start = {armedAt = os.clockhp(), applied = nil}
	log("D", logTag, "armed for the career start")
end

local function warnNotApplied()
	log("W", logTag, "the career set up traffic without Mileage - server traffic amounts not applied")
end

--== tutorial restore ========================================================
-- At the end of a tutorial phase the game puts traffic back from the player's own
-- settings and switches road traffic on even when none was spawned, which turns every
-- untagged vehicle into traffic. On a server the restore uses the server's amounts and
-- leaves road traffic off when the server has it off.

local function serverRestoreTrafficAfterTutorialPhase(module)
	local ok, err = xpcall(function()
		local road, parked = M.serverAmounts(serverConfig() or {})
		if road > 0 and gameplay_traffic.getState() == "off" then
			gameplay_traffic.toggle(true)
		end
		gameplay_traffic.setActiveAmount(road)
		gameplay_parking.setActiveAmount(parked)
		module.setTrafficAfterTutorial()
	end, debug.traceback)
	if not ok then log("E", logTag, "tutorial traffic restore failed: " .. tostring(err)) end
end

-- The game loads its career modules afresh on a career start, so this is checked on
-- each one and installed on the module table that is current.
local function installTutorialRestore()
	local module = career_modules_playerDriving
	if tutorial and tutorial.module == module then return end
	-- A missing function is reported once, by name, through compat like every other
	-- game function Mileage relies on.
	local compat = extensions.mileage_compat
	local consequence = "the tutorial traffic restore keeps the player's own amounts"
	local restoreFn = compat.pickOrWarn(module, "career_modules_playerDriving", "restoreTrafficAfterTutorialPhase", consequence)
	local afterFn = compat.pickOrWarn(module, "career_modules_playerDriving", "setTrafficAfterTutorial", consequence)
	if not restoreFn or not afterFn then return end
	tutorial = {module = module, original = module.restoreTrafficAfterTutorialPhase}
	module.restoreTrafficAfterTutorialPhase = function()
		serverRestoreTrafficAfterTutorialPhase(module)
	end
end

local function removeTutorialRestore()
	if not tutorial then return end
	tutorial.module.restoreTrafficAfterTutorialPhase = tutorial.original
	tutorial = nil
end

--== mission hide ============================================================
-- On a mission start the game's mission manager stashes traffic with
--
--   gameplay_traffic.freezeState({despawnVehicles = true, exceptVehicleId = <player's car>})
--
-- which deletes every traffic, police and parked car except the one the player drives,
-- and spawns them all again at the end with unfreezeState(..., {respawnVehicles = true}).
-- On a server each of those is a new vehicle on every other player's game, announced
-- and queued by BeamMP and then built at once, which stalls their game. On a server the
-- cars are hidden for the mission instead, which Mileage's hide/show sync carries to
-- everyone, and shown again at the end. Any other freeze is left to the game.

local unpack = table.unpack or unpack

-- {module, freeze, unfreeze} while the replacement is installed on that module table.
local mission = nil

-- Cars hidden by a mission start and not yet shown again.
local hiddenForMission = nil

local passThroughLogged = false

local function copyWith(options, key, value)
	local copy = {}
	if type(options) == "table" then
		for k, v in pairs(options) do copy[k] = v end
	end
	copy[key] = value
	return copy
end

local function callOr(module, fnName, fallback)
	if type(module) ~= "table" or type(module[fnName]) ~= "function" then return fallback end
	local ok, value = pcall(module[fnName])
	if ok and type(value) == "table" then return value end
	return fallback
end

-- The cars the game's freeze would delete (AI or isTraffic road traffic and parked
-- cars, except exceptId) that are showing now. Pooled cars are already hidden and the
-- game's traffic pool puts them back itself.
local function missionCars(exceptId)
	local ids, seen = {}, {}
	local function add(id)
		if id == exceptId or seen[id] then return end
		local obj = be:getObjectByID(id)
		if obj and obj:getActive() then
			seen[id] = true
			table.insert(ids, id)
		end
	end
	local trafficIds = {}
	for id, entry in pairs(callOr(gameplay_traffic, "getTrafficData", {})) do
		if type(entry) == "table" then
			local obj = be:getObjectByID(id)
			if entry.isAi == true or (obj and obj.isTraffic == "true") then table.insert(trafficIds, id) end
		end
	end
	table.sort(trafficIds)
	for _, id in ipairs(trafficIds) do add(id) end
	for _, id in ipairs(callOr(gameplay_parking, "getParkedCarsList", {})) do add(id) end
	return ids
end

local function makeMissionFreeze(original)
	return function(options, ...)
		if type(options) ~= "table" or options.despawnVehicles ~= true then
			if not passThroughLogged then
				passThroughLogged = true
				log("I", logTag, "the game froze traffic without asking to delete it - left to the game")
			end
			return original(options, ...)
		end
		local found, ids = xpcall(missionCars, debug.traceback, options.exceptVehicleId)
		if not found then
			log("E", logTag, "mission hide failed, traffic left to the game: " .. tostring(ids))
			return original(options, ...)
		end
		local results = pack(original(copyWith(options, "despawnVehicles", false), ...))
		hiddenForMission = hiddenForMission or {}
		local hidden = 0
		for _, id in ipairs(ids) do
			local obj = be:getObjectByID(id)
			if obj then
				obj:setActive(0)
				table.insert(hiddenForMission, id)
				hidden = hidden + 1
			end
		end
		log("I", logTag, string.format("mission start: %d traffic and parked cars hidden instead of deleted", hidden))
		return unpack(results, 1, results.n)
	end
end

-- Shows the cars a mission start hid that still exist; returns how many.
local function showMissionCars()
	local ids = hiddenForMission
	hiddenForMission = nil
	if not ids then return nil, 0 end
	local shown = 0
	for _, id in ipairs(ids) do
		local obj = be:getObjectByID(id)
		if obj then
			obj:setActive(1)
			shown = shown + 1
		end
	end
	return shown, #ids
end

local function makeMissionUnfreeze(original)
	return function(trafficData, policeData, parkingData, options, ...)
		local shown, total = showMissionCars()
		if not shown then return original(trafficData, policeData, parkingData, options, ...) end
		log("I", logTag, string.format("mission end: %d of %d hidden traffic and parked cars shown again", shown, total))
		return original(trafficData, policeData, parkingData, copyWith(options, "respawnVehicles", false), ...)
	end
end

-- Installed on the game's traffic module that is current at each career start.
local function installMissionHide()
	local module = gameplay_traffic
	if mission and mission.module == module then return end
	local compat = extensions.mileage_compat
	local consequence = "a mission start deletes and respawns traffic for every player"
	local freezeFn = compat.pickOrWarn(module, "gameplay_traffic", "freezeState", consequence)
	local unfreezeFn = compat.pickOrWarn(module, "gameplay_traffic", "unfreezeState", consequence)
	if not freezeFn or not unfreezeFn then return end
	mission = {module = module, freeze = freezeFn, unfreeze = unfreezeFn}
	module.freezeState = makeMissionFreeze(freezeFn)
	module.unfreezeState = makeMissionUnfreeze(unfreezeFn)
end

-- Cars still hidden for a mission are shown again: the game's own unfreeze has no
-- copies to spawn them from.
local function removeMissionHide()
	local shown, total = showMissionCars()
	if shown then
		log("I", logTag, string.format("mission hide removed: %d of %d hidden cars shown again", shown, total))
	end
	passThroughLogged = false
	if not mission then return end
	mission.module.freezeState = mission.freeze
	mission.module.unfreezeState = mission.unfreeze
	mission = nil
end

--== share changes ===========================================================
-- When a player joins or leaves a full server, the server sends everyone already in a new
-- share of its traffic total (the enabler keeps it with the client config). During a
-- career the share is applied through the game's active amounts, which hide or show
-- traffic cars; a career start reads it in its own setup, and one that arrives while the
-- start is setting up traffic is applied once traffic is ready.

local careerActive = false
local shareWaiting = false

local function applyShare()
	local config = serverConfig()
	if not config then return end
	-- No career start is under way, so a replacement still armed is stale.
	restoreAll("traffic share changed")
	local road, parked = M.serverAmounts(config)
	local compat = extensions.mileage_compat
	local consequence = "a new traffic share waits for the next career start"
	local setRoad = compat.pickOrWarn(gameplay_traffic, "gameplay_traffic", "setActiveAmount", consequence)
	local setParked = compat.pickOrWarn(gameplay_parking, "gameplay_parking", "setActiveAmount", consequence)
	if setRoad then setRoad(road) end
	if setParked then setParked(parked) end
	log("I", logTag, string.format("traffic share changed - road %d, parked %d", road, parked))
end

--- The enabler received a new share from the server.
function M.onTrafficShare()
	if not serverConfig() then return end
	if start then
		shareWaiting = true
	elseif careerActive then
		applyShare()
	end
end

local function applyWaitingShare()
	if not shareWaiting then return end
	shareWaiting = false
	if careerActive then applyShare() end
end

--== hooks ===================================================================

--- Fired by the game's career.lua at the top of activateCareer, before its modules set
--- up traffic.
function M.onBeforeCareerActivate()
	arm()
end

function M.onCareerActive(active)
	careerActive = active == true and serverConfig() ~= nil
	if careerActive then
		installTutorialRestore()
		installMissionHide()
	end
end

local function count(module, fnName)
	local fn = type(module) == "table" and module[fnName]
	if type(fn) ~= "function" then return "?" end
	local ok, value = pcall(fn)
	return ok and tostring(value) or "?"
end

--- Fired by the game's traffic system once road and parked cars are spawned. With both
--- amounts at 0 it fires inside setupTrafficHelper itself.
function M.onTrafficOrParkingReady()
	if not start then return end
	local applied = start.applied
	start = nil
	if not applied then
		warnNotApplied()
		restoreAll("traffic ready without the meter")
	else
		log("I", logTag, string.format("traffic ready - %s road, %s parked",
			count(gameplay_traffic, "getTrafficAmount"), count(gameplay_parking, "getParkingAmount")))
	end
	applyWaitingShare()
end

-- Safety net: a career start that never sets up traffic, or never calls the active
-- amounts, must not leave the game's functions replaced.
local replacedSince = nil

function M.onUpdate()
	if not next(replaced) and not start then
		replacedSince = nil
		return
	end
	replacedSince = replacedSince or os.clockhp()
	if (os.clockhp() - replacedSince) <= METER_MAX_SECONDS then return end
	if start and not start.applied then
		warnNotApplied()
	elseif start then
		log("W", logTag, string.format("traffic not ready %ds after the career start - asked for road %d, parked %d",
			METER_MAX_SECONDS, start.applied.road, start.applied.parked))
	end
	start = nil
	restoreAll("timed out")
	replacedSince = nil
	applyWaitingShare()
end

function M.onBeamMPServerLeave()
	start = nil
	careerActive, shareWaiting = false, false
	restoreAll("left the server")
	removeTutorialRestore()
	removeMissionHide()
	warned = {}
end

function M.onExtensionLoaded()
	log("I", logTag, "Mileage traffic meter LOADED")
end

function M.onExtensionUnloaded()
	start = nil
	careerActive, shareWaiting = false, false
	restoreAll("unloaded")
	removeTutorialRestore()
	removeMissionHide()
	log("I", logTag, "Mileage traffic meter UNLOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
