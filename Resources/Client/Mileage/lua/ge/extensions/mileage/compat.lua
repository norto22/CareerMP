--Mileage :: compat layer
--
-- Single point of contact for game APIs that BeamNG renames between versions.
-- Every call site in Mileage goes through here instead of calling the game
-- directly, so a future rename is a one-file fix rather than a hunt.
--
-- Target: BeamNG.drive 0.40.4.0. The game APIs used here took their current names in
-- 0.39; each entry also names the 0.38.6 API it replaces.

local M = {}

M.targetGameVersion = "0.40.4.0"

-- Picks the first field that exists on a module, so one call site can serve
-- several game versions. Returns the function plus the name that matched,
-- which is what makes the missing-API report below useful.
local function pick(module, ...)
	if type(module) ~= "table" then return nil, nil end
	for _, name in ipairs({...}) do
		if type(module[name]) == "function" then
			return module[name], name
		end
	end
	return nil, nil
end

local function callPick(module, names, ...)
	local fn, matched = pick(module, unpack(names))
	if not fn then
		log("E", "mileage.compat", "none of {" .. table.concat(names, ", ") .. "} exist on target module")
		return nil
	end
	return fn(...), matched
end

--== save system =============================================================
-- 0.39 renamed every "saveSlot" symbol to "profile" and split profile/save
-- folder. backwardsCompVersion stayed 36, so 0.38.x saves still load.

-- 0.39 getCurrentProfile / 0.38 getCurrentSaveSlot -> (name, path)
function M.getCurrentProfile()
	return callPick(career_saveSystem, {"getCurrentProfile", "getCurrentSaveSlot"})
end

-- The folder of the save the career runs on, or nil. getCurrentProfile above keeps only
-- the profile name, the first of the two values the game returns.
function M.getSavePath()
	local fn = pick(career_saveSystem, "getCurrentProfile", "getCurrentSaveSlot")
	if not fn then return nil end
	local _, path = fn()
	if type(path) ~= "string" or path == "" then return nil end
	return path
end

-- 0.39 getAllProfiles / 0.38 getAllSaveSlots
function M.getAllProfiles()
	return callPick(career_saveSystem, {"getAllProfiles", "getAllSaveSlots"}) or {}
end

-- 0.39 setProfile(profile, specificSaveFolder) / 0.38 setSaveSlot(name, autosave)
function M.setProfile(name, specificSaveFolder)
	return callPick(career_saveSystem, {"setProfile", "setSaveSlot"}, name, specificSaveFolder)
end

-- 0.39 getAllSaveFolders(profile) / 0.38 getAllAutosaves(slot)
function M.getAllSaveFolders(profile)
	return callPick(career_saveSystem, {"getAllSaveFolders", "getAllAutosaves"}, profile) or {}
end

-- 0.39 getNewestSave(path) / 0.38 getAutosave(path, oldest)
function M.getNewestSave(path)
	local fn = pick(career_saveSystem, "getNewestSave")
	if fn then return fn(path) end
	local legacy = pick(career_saveSystem, "getAutosave")
	if legacy then return legacy(path, false) end
	return nil
end

-- 0.39 only: display name is kept separate from the sanitised folder name.
function M.getCurrentDisplayName()
	local fn = pick(career_saveSystem, "getCurrentDisplayName")
	if fn then return fn() end
	return (M.getCurrentProfile())
end

--== profile naming ==========================================================
-- 0.39 saveSystem.getSanitizedProfileName lowercases and strips every
-- non-alphanumeric, then de-duplicates against profiles already on THIS client
-- (name, name1, name2...). That de-dup makes the mapping machine-dependent, so
-- we sanitise the nickname ourselves and pass a name the game will accept
-- verbatim. Deterministic across clients is the whole point: a player's save
-- must resolve to the same folder on every Mileage server.
function M.sanitizeProfileName(name)
	local sanitized = string.gsub(string.lower(name or ""), "[^a-z0-9]", "")
	if sanitized == "" then sanitized = "profile" end
	return sanitized
end

--== career activation =======================================================
-- 0.38: createOrLoadCareerAndStart(name, specificAutosave, tutorial:boolean)
-- 0.39: createOrLoadCareerAndStart(name, specificAutosave, startingOptions:table)
--
-- Passing a boolean to 0.39 does not error (non-table -> {}) but leaves
-- startMode unset, so no starting mode ever initialises the profile.
-- "freshStart" ("Open World") is the multiplayer-correct default: it matches
-- Mileage's old behaviour of skipping onboarding, and avoids running a
-- scripted single-player tutorial inside a shared world.
M.defaultStartMode = "freshStart"

function M.createOrLoadCareerAndStart(name, specificSaveFolder, startMode)
	local career = career_career
	if not career or type(career.createOrLoadCareerAndStart) ~= "function" then
		log("E", "mileage.compat", "career_career.createOrLoadCareerAndStart missing")
		return false
	end
	if M.usesStartingOptions() then
		return career.createOrLoadCareerAndStart(name, specificSaveFolder, {
			startMode = startMode or M.defaultStartMode,
		})
	end
	-- 0.38 and older: third arg was the tutorial flag; never enable it in MP.
	return career.createOrLoadCareerAndStart(name, specificSaveFolder, false)
end

-- 0.39 exposes career_career.startingOptions; 0.38 had career_career.tutorialEnabled
-- and no starting modes at all.
function M.usesStartingOptions()
	return career_career ~= nil and type(career_career.startingOptions) == "table"
end

-- The join path calls these on every frame, so a missing one is logged once, by name.
local warnedMissing = {}

local function pickOrWarn(module, moduleName, name, consequence)
	local fn = pick(module, name)
	if not fn and not warnedMissing[moduleName .. "." .. name] then
		warnedMissing[moduleName .. "." .. name] = true
		log("E", "mileage.compat", moduleName .. "." .. name .. " missing - " .. consequence)
	end
	return fn
end

-- true or false, or nil when the game has no way to tell.
function M.isCareerActive()
	local fn = pickOrWarn(career_career, "career_career", "isActive",
		"a career start that returned is taken as active")
	if not fn then return nil end
	return fn() == true
end

--== loading screen ==========================================================
-- core_gamestate counts loading-screen requests by tag: the screen shows on the first
-- request and hides once every tag is released. Tags used on a join: 'serverConnection'
-- and 'worldReadyState' (the map load), 'careerActivate' (career.lua activateCareer)
-- and 'careerVehicles' (the game's career playerDriving traffic setup).

local function gamestateFunction(name)
	return pickOrWarn(core_gamestate, "core_gamestate", name, "loading screen not managed")
end

function M.getLoadingStatus(tag)
	local fn = gamestateFunction("getLoadingStatus")
	return fn ~= nil and fn(tag) == true
end

function M.requestEnterLoadingScreen(tag)
	local fn = gamestateFunction("requestEnterLoadingScreen")
	if not fn then return false end
	fn(tag)
	return true
end

function M.requestExitLoadingScreen(tag)
	local fn = gamestateFunction("requestExitLoadingScreen")
	if not fn then return false end
	fn(tag)
	return true
end

-- The game's own traffic ready handler (career playerDriving onTrafficOrParkingReady)
-- releases 'careerVehicles' and, only while that tag is held, switches the special
-- triggers off. Releasing the tag through it keeps that clean-up when traffic never
-- reports ready; the bare release is the fallback when the handler is missing.
function M.releaseCareerTrafficScreen()
	local fn = pickOrWarn(career_modules_playerDriving, "career_modules_playerDriving", "onTrafficOrParkingReady",
		"releasing 'careerVehicles' without its clean-up")
	if fn then
		local ok, err = xpcall(fn, debug.traceback)
		if not ok then log("E", "mileage.compat", "onTrafficOrParkingReady failed: " .. tostring(err)) end
	end
	if M.getLoadingStatus("careerVehicles") then M.requestExitLoadingScreen("careerVehicles") end
end

-- The step BeamMP takes when its loading screen clears (MPCoreNetwork onWorldReadyState):
-- 0.39 resolves the screen behind the loading screen through the UI router.
function M.navigateToPlay()
	local router = extensions and extensions.ui_router
	local fn = pickOrWarn(router, "ui_router", "navigate", "interface not moved to the in-game screen")
	if not fn then return false end
	fn("play")
	return true
end

--== BeamMP session ==========================================================

function M.isMPSession()
	local fn = pickOrWarn(MPCoreNetwork, "MPCoreNetwork", "isMPSession", "loading screen not held on join")
	return fn ~= nil and fn() == true
end

--== tutorial ================================================================
-- 0.39 deleted career_modules_linearTutorial (and isLinearTutorialActive) and
-- replaced it with career_modules_tutorial + a 9-step tutorial/ directory.
-- Mileage always starts in freshStart, so this should be false in practice;
-- it is still queried to keep menu-button parity with single player.
function M.isTutorialActive()
	local tutorial = career_modules_tutorial
	if tutorial then
		local fn = pick(tutorial, "isTutorialActive", "isActive", "isLinearTutorialActive")
		if fn then return fn() and true or false end
	end
	local legacy = career_modules_linearTutorial
	if legacy then
		local fn = pick(legacy, "isLinearTutorialActive")
		if fn then return fn() and true or false end
	end
	-- 0.39 derives tutorialEnabled from startingOptions.startMode.
	if career_career and career_career.tutorialEnabled ~= nil then
		return career_career.tutorialEnabled and true or false
	end
	return false
end

--== UI app layouts ==========================================================
-- 0.39 removed ui_apps.requestUIAppsData. Layout mutation moved to
-- ui_appLayouts and visibility to ui_appContainers; the layout *files* under
-- settings/ui_apps/originalLayouts/{default,mission} kept their location and
-- schema, and 0.39 additionally watches them and auto-refreshes (debounced).
function M.notifyLayoutsChanged()
	local apps = ui_apps
	if apps then
		local fn = pick(apps, "notifyLayoutsChanged", "requestUIAppsData")
		if fn then return fn() end
	end
	-- Last resort: the guihook that 0.39's notifyLayoutsChanged fires.
	if guihooks then guihooks.trigger("UiAppLayoutsChanged") end
end

--== top bar / menus =========================================================
-- ui_topBar and ui/topBar/ were deleted outright in 0.39's UI overhaul, along
-- with gameplayAppContainers / messagesTasksAppContainers / vehicleVicinityApp.
-- The replacement stack is menuManager + router + uiStateManager + pause/.
-- There is no drop-in equivalent for removeEntry/updateEntries/updateVisibleItems:
-- the entry list now lives behind the router / pause-V2 layer. Callers must
-- check this before attempting the old path.
function M.hasLegacyTopBar()
	return ui_topBar ~= nil and type(ui_topBar.getEntries) == "function"
end

function M.hasMenuManager()
	return ui_menuManager ~= nil
end

--== races between players ===================================================
-- A street race finishes where the challenger's big-map route ends, moves the challenged
-- car with the game's safe teleport and holds both cars with the vehicle controller's
-- freeze (as the game's own drag racing does). Each returns nil when the game lacks it,
-- and the race says so instead of starting.

-- The end of the route set on the big map, as a vec3, or nil when no route is set.
function M.getNavigationTarget()
	local fn = pickOrWarn(core_groundMarkers, "core_groundMarkers", "getTargetPos", "races cannot read the map route")
	if not fn then return nil end
	local ok, target = pcall(fn)
	if ok and target then return target end
	return nil
end

-- Moves veh to pos facing rot, clear of anything in the way. Returns true when it ran.
function M.safeTeleport(veh, pos, rot)
	local fn = pickOrWarn(spawn, "spawn", "safeTeleport", "a race cannot move a car to the start")
	if not fn then return false end
	local ok, err = pcall(fn, veh, pos, rot, nil, nil, nil, nil, true)
	if not ok then log("E", "mileage.compat", "safeTeleport failed: " .. tostring(err)) end
	return ok
end

-- The mission running in the foreground, or nil.
function M.getForegroundMissionId()
	local manager = gameplay_missions_missionManager
	local fn = pick(manager, "getForegroundMissionId")
	if not fn then return nil end
	return fn()
end

function M.hasRaceFunctions()
	return pick(core_groundMarkers, "getTargetPos") ~= nil and pick(spawn, "safeTeleport") ~= nil
end

--== self check ==============================================================
-- Logs which mapped APIs resolved and which did not. Called once at load so a
-- future game update surfaces as a clear list instead of a runtime nil call.
function M.report()
	local checks = {
		{"career_saveSystem.getCurrentProfile/getCurrentSaveSlot", career_saveSystem, {"getCurrentProfile", "getCurrentSaveSlot"}},
		{"career_saveSystem.getAllProfiles/getAllSaveSlots",       career_saveSystem, {"getAllProfiles", "getAllSaveSlots"}},
		{"career_saveSystem.setProfile/setSaveSlot",               career_saveSystem, {"setProfile", "setSaveSlot"}},
		{"career_saveSystem.getAllSaveFolders/getAllAutosaves",    career_saveSystem, {"getAllSaveFolders", "getAllAutosaves"}},
		{"career_saveSystem.getNewestSave/getAutosave",            career_saveSystem, {"getNewestSave", "getAutosave"}},
		{"ui_apps.notifyLayoutsChanged/requestUIAppsData",         ui_apps,           {"notifyLayoutsChanged", "requestUIAppsData"}},
		{"core_gamestate.getLoadingStatus",                        core_gamestate,    {"getLoadingStatus"}},
		{"core_gamestate.requestEnterLoadingScreen",               core_gamestate,    {"requestEnterLoadingScreen"}},
		{"core_gamestate.requestExitLoadingScreen",                core_gamestate,    {"requestExitLoadingScreen"}},
		{"core_groundMarkers.getTargetPos",                        core_groundMarkers, {"getTargetPos"}},
		{"spawn.safeTeleport",                                     spawn,             {"safeTeleport"}},
	}

	local missing = {}
	for _, check in ipairs(checks) do
		local label, module, names = check[1], check[2], check[3]
		local _, matched = pick(module, unpack(names))
		if matched then
			log("D", "mileage.compat", string.format("%s -> %s", label, matched))
		else
			table.insert(missing, label)
		end
	end

	if #missing > 0 then
		log("E", "mileage.compat", "UNRESOLVED game APIs (game version drift?):")
		for _, label in ipairs(missing) do
			log("E", "mileage.compat", "  " .. label)
		end
	end

	if not M.hasLegacyTopBar() then
		log("W", "mileage.compat", "ui_topBar absent (expected on 0.39+) - top bar patching is disabled")
	end

	return #missing == 0
end

M.pick = pick
M.pickOrWarn = pickOrWarn

return M
