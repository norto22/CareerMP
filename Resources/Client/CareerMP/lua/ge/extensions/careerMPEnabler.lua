--CareerMP 0.39 :: enabler (CLIENT)
--
-- Port of CareerMP 0.0.37's careerMPEnabler for BeamNG.drive 0.39.
-- Original by Dudekahedron, 2026.
--
-- Differences from 0.0.37:
--   * Renamed game APIs go through careerMP_compat (0.39 renamed every
--     "saveSlot" symbol to "profile", among others).
--   * Career start passes a startingOptions table with startMode = "freshStart"
--     ("Open World"). 0.39 changed the third parameter of
--     createOrLoadCareerAndStart from a tutorial boolean to a table; passing a
--     boolean silently leaves no starting mode applied.
--   * The BeamMP nickname is sanitised locally before use as a profile name.
--     0.39 lowercases and strips non-alphanumerics, then de-duplicates against
--     profiles already on that client -- which would make the nickname -> save
--     mapping machine-dependent.
--   * patchTopBar is gated: ui_topBar was deleted in 0.39's UI overhaul.
--   * Menu hooks come from careerMP_patches (runtime wrappers) rather than from
--     forked copies of the career modules.
--
-- See docs/0.39-PORTING-RESEARCH.md.

local M = {}

local logTag = "careerMP"

local compat = nil
local patches = nil

local nickname = nil

local blockedInputActions = {}
local clientConfig

local careerMPActive = false
local syncRequested = false


local inComputerMenus = false

--Settings

local userTrafficSettings = {}
local careerMPTrafficSettings = {}

local userGameplaySettings = {}
local careerMPGameplaySettings = {}

local function getClientConfig()
	return clientConfig
end

local function getUserTrafficSettings()
	userTrafficSettings.trafficSmartSelections = settings.getValue('trafficSmartSelections')
	userTrafficSettings.trafficSimpleVehicles = settings.getValue('trafficSimpleVehicles')
	userTrafficSettings.trafficAllowMods = settings.getValue('trafficAllowMods')
end

local function setTrafficSettings(trafficSettings)
	for setting, value in pairs(trafficSettings) do
		settings.setValue(setting, value)
	end
end

local function getUserGameplaySettings()
	userGameplaySettings.simplifyRemoteVehicles = settings.getValue("simplifyRemoteVehicles")
	userGameplaySettings.spawnVehicleIgnitionLevel = settings.getValue("spawnVehicleIgnitionLevel")
	userGameplaySettings.skipOtherPlayersVehicles = settings.getValue("skipOtherPlayersVehicles")
end

local function setGameplaySettings(gameplaySettings)
	for setting, value in pairs(gameplaySettings) do
		settings.setValue(setting, value)
	end
end

--Hidden Nametags by Vehicle Model
-- Props, trailers and traffic that would otherwise spam nametags across the map.
local hiddens = {
	anticut = true, ball = true, barrels = true, barrier = true,
	barrier_plastic = true, blockwall = true, bollard = true, boxutility = true,
	boxutility_large = true, cannon = true, caravan = true, cardboard_box = true,
	cargotrailer = true, chair = true, christmas_tree = true, cones = true,
	containerTrailer = true, couch = true, crowdbarrier = true, delineator = true,
	dolly = true, dryvan = true, engine_props = true, flail = true,
	flatbed = true, flipramp = true, frameless_dump = true, fridge = true,
	gate = true, haybale = true, inflated_mat = true, kickplate = true,
	large_angletester = true, large_bridge = true, large_cannon = true,
	large_crusher = true, large_hamster_wheel = true, large_roller = true,
	large_spinner = true, large_tilt = true, large_tire = true,
	log_trailer = true, logs = true, mattress = true, metal_box = true,
	metal_ramp = true, piano = true, porta_potty = true, pressure_ball = true,
	rallyflags = true, rallysigns = true, rallytape = true, roadsigns = true,
	rocks = true, rollover = true, roof_crush_tester = true, sawhorse = true,
	shipping_container = true, simple_traffic = true, spikestrip = true,
	steel_coil = true, streetlight = true, suspensionbridge = true,
	tanker = true, testroller = true, tiltdeck = true, tirestacks = true,
	tirewall = true, trafficbarrel = true, trampoline = true, trashbin = true,
	tsfb = true, tub = true, tube = true, tv = true, wall = true,
	weightpad = true, woodcrate = true, woodplanks = true,
}

--Vehicles and part paints

-- Career constantly hides/shows vehicles (garage, shopping, missions). A vehicle
-- hidden locally must be hidden for everyone, so the server keeps the
-- authoritative active-state map and we apply it to everything we do not own.
local function rxCareerVehSync(data)
	if data == "null" then return end
	local vehicleStates = jsonDecode(data)
	if not vehicleStates then return end
	local vehicles = MPVehicleGE.getVehicles()
	for serverVehicleID, state in pairs(vehicleStates) do
		local entry = vehicles[serverVehicleID]
		if entry then
			local gameVehicleID = entry.gameVehicleID
			if gameVehicleID and gameVehicleID ~= -1 and not MPVehicleGE.isOwn(gameVehicleID) then
				local veh = be:getObjectByID(gameVehicleID)
				if veh then
					if not state.active then
						veh:setActive(0)
						entry.hideNametag = true
					else
						veh:setActive(1)
						entry.hideNametag = hiddens[entry.jbeam] and true or false
					end
				end
			end
		end
	end
end

local function onVehicleActiveChanged(gameVehicleID, active)
	if not gameVehicleID then return end
	if MPVehicleGE.isOwn(gameVehicleID) then
		local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
		if serverVehicleID then
			TriggerServerEvent("careerVehicleActiveHandler", jsonEncode({
				active = active,
				serverVehicleID = serverVehicleID,
			}))
		end
	else
		TriggerServerEvent("careerVehSyncRequested", "")
	end
end

local function onVehicleSpawned(gameVehicleID)
	if not gameVehicleID then return end
	local veh = be:getObjectByID(gameVehicleID)
	if veh then
		veh:queueLuaCommand('careerMPEnabler.onVehicleReady()')
	end
	if not MPVehicleGE.isOwn(gameVehicleID) then
		TriggerServerEvent("careerVehSyncRequested", "")
	end
end

local function onVehicleReady(gameVehicleID)
	local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
	if not serverVehicleID then return end
	local veh = be:getObjectByID(gameVehicleID)
	if not veh then return end

	if not MPVehicleGE.isOwn(gameVehicleID) then
		-- 0.0.37 also queued careerMPEnabler.setUnicycleGhost(clientConfig.unicycleGhost)
		-- and setAllGhost(clientConfig.allGhost) here. Neither function exists on
		-- the vehicle side (only setGhost does) and neither config key exists on
		-- the server, so both calls errored in the vehicle VM and did nothing.
		-- Ghosting is handled in onUpdate against the real config keys instead.
		local vehicles = MPVehicleGE.getVehicles()
		if vehicles[serverVehicleID] then
			vehicles[serverVehicleID].hideNametag = hiddens[veh.JBeam] and true or false
		end
	end
	-- Raised so other players stay visible at big-map distances.
	veh:setField('renderDistance', '', 1610)
end

-- Re-entrancy guard.
--
-- Everything this handler does to correct a bad switch - enterNextVehicle,
-- setWalkingMode, enterVehicle - switches vehicles again, and the engine fires
-- onVehicleSwitched synchronously for each. Without a guard the handler calls
-- itself through the engine: entering a unicycle while inComputerMenus was set
-- recursed until the Lua stack overflowed, which showed up as walking mode simply
-- not working (the overflow surfaced inside gameplay_walk.toggleWalkingMode).
local handlingVehicleSwitch = false

local function handleVehicleSwitch(oldGameVehicleID, newGameVehicleID)
	local newVeh = be:getObjectByID(newGameVehicleID)
	local oldVeh = be:getObjectByID(oldGameVehicleID)
	if not newVeh then return end

	-- Never let the player end up controlling someone else's prop.
	if hiddens[newVeh.JBeam] and not MPVehicleGE.isOwn(newGameVehicleID) then
		be:enterNextVehicle(0, 1)
		return
	end

	-- Career's computer menus act on the vehicle the player occupies, so being
	-- dropped onto the unicycle mid-menu has to be undone. Clear the flag first:
	-- this is a one-shot correction, and leaving it set arms the same branch for
	-- every future switch.
	if newVeh.JBeam == "unicycle" and inComputerMenus then
		inComputerMenus = false
		gameplay_walk.setWalkingMode(false)
		if oldVeh then be:enterVehicle(0, oldVeh) end
	end
end

local function onVehicleSwitched(oldGameVehicleID, newGameVehicleID)
	if handlingVehicleSwitch then return end
	handlingVehicleSwitch = true
	local ok, err = pcall(handleVehicleSwitch, oldGameVehicleID, newGameVehicleID)
	handlingVehicleSwitch = false
	if not ok then
		log("E", logTag, "onVehicleSwitched failed: " .. tostring(err))
	end
end

--Traffic Signals and Cameras

local function onSpeedTrapTriggered(speedTrapData, playerSpeed, overSpeed)
	if not MPVehicleGE.isOwn(speedTrapData.subjectID) then return end
	local veh = be:getObjectByID(speedTrapData.subjectID)
	if not veh then return end
	local highscore, leaderboard = gameplay_speedTrapLeaderboards.addRecord(speedTrapData, playerSpeed, overSpeed, veh)
	speedTrapData.licensePlate = veh:getDynDataFieldbyName("licenseText", 0) or "Illegible"
	speedTrapData.vehicleModel = core_vehicles.getModel(veh.JBeam).model.Name
	speedTrapData.playerSpeed = playerSpeed
	speedTrapData.overSpeed = overSpeed
	speedTrapData.highscore = highscore
	speedTrapData.leaderboard = leaderboard
	TriggerServerEvent("speedTrap", jsonEncode(speedTrapData))
end

local function onRedLightCamTriggered(redLightData, playerSpeed)
	if not MPVehicleGE.isOwn(redLightData.subjectID) then return end
	local veh = be:getObjectByID(redLightData.subjectID)
	if not veh then return end
	redLightData.licensePlate = veh:getDynDataFieldbyName("licenseText", 0) or "Illegible"
	redLightData.vehicleModel = core_vehicles.getModel(veh.JBeam).model.Name
	redLightData.playerSpeed = playerSpeed
	TriggerServerEvent("redLight", jsonEncode(redLightData))
end

local function rxTrafficSignalTimer(data)
	core_trafficSignals.setTimer(tonumber(data))
end

--Garage / Office Computer Handling

-- Career's computer menus act on the vehicle the player occupies. In MP the
-- player is usually walking, so put them in the target vehicle first. Fed by the
-- enriched hooks from careerMP_patches, which carry the vehicle id that the
-- stock hooks omit.
local function computerMenuHandler(targetVehicleID)
	if not targetVehicleID then return end
	local veh = be:getObjectByID(targetVehicleID)
	if not veh or veh.JBeam == "unicycle" then return end
	if gameplay_walk.isWalking() then
		gameplay_walk.getInVehicle(veh)
	else
		be:enterVehicle(0, veh)
	end
	inComputerMenus = true
end

local function onComputerOpenedMP()
	inComputerMenus = false
end

--Patch BeamMP behavior and topBar

-- 0.39 deleted ui/topBar.lua and ui/topBar/ outright. The replacement stack
-- (menuManager + router + uiStateManager + pause/) has no removeEntry
-- equivalent -- the entry list now lives behind the router / pause-V2 layer.
-- Gated rather than removed so the old path still works if BeamNG restores it.
local function patchTopBar()
	if not compat.hasLegacyTopBar() then return end
	ui_topBar.removeEntry("environment")
	ui_topBar.removeEntry("mods")
	ui_topBar.removeEntry("vehicleconfig")
	ui_topBar.removeEntry("vehicles")
	local entries = ui_topBar.getEntries()
	ui_topBar.updateEntries(entries)
	ui_topBar.updateVisibleItems()
end

-- 0.0.37 patched multiplayer_multiplayer.onUpdate here, and from inside that
-- installed its own core_camera.getDriverData to correct the mirrored driver side on
-- remote vehicles (the fragile debug.getinfo(2).name == "getDoorsidePosRot" check).
--
-- All of it is gone, for three reasons:
--
--  1. The extension it patched no longer exists. BeamMP 0.39 ships
--     lua/ge/extensions/beammp/multiplayer.lua (beammp_multiplayer), not
--     multiplayer_multiplayer, so patchBeamMP silently did nothing and the
--     getDriverData override -- installed only from within that patch -- never ran.
--  2. BeamMP now does this itself, with the same getDoorsidePosRot check. Ours would
--     be a duplicate even if it did install.
--  3. It was actively dangerous on the way out. unPatchBeamMP assigned
--     core_camera.getDriverData = originalGetDriverData, which was nil, so leaving a
--     server would have nil'd out the function BeamMP had legitimately installed.
--
-- BeamMP re-asserts getDriverData from its own onUpdate every frame, so wrapping it
-- would produce the same mutual recursion documented in careerMP/patches.lua.
-- Leave it alone.

--Initial Syncs and Updates

local function actionsCheck()
	blockedInputActions = {}
	if not clientConfig.consoleEnabled then
		table.insert(blockedInputActions, "toggleConsoleNG")
	end
	if not clientConfig.worldEditorEnabled then
		table.insert(blockedInputActions, "editorToggle")
		table.insert(blockedInputActions, "editorSafeModeToggle")
		table.insert(blockedInputActions, "objectEditorToggle")
	end
	extensions.core_input_actionFilter.setGroup('careerMP', blockedInputActions)
	extensions.core_input_actionFilter.addAction(0, 'careerMP', #blockedInputActions > 0)
end

local function settingsCheck()
	careerMPTrafficSettings.trafficAllowMods = clientConfig.trafficAllowMods
	careerMPTrafficSettings.trafficSimpleVehicles = clientConfig.trafficSimpleVehicles
	careerMPTrafficSettings.trafficSmartSelections = clientConfig.trafficSmartSelections
	setTrafficSettings(careerMPTrafficSettings)
	careerMPGameplaySettings.simplifyRemoteVehicles = clientConfig.simplifyRemoteVehicles
	careerMPGameplaySettings.spawnVehicleIgnitionLevel = clientConfig.spawnVehicleIgnitionLevel
	careerMPGameplaySettings.skipOtherPlayersVehicles = clientConfig.skipOtherPlayersVehicles
	setGameplaySettings(careerMPGameplaySettings)
end

-- Profile name = sanitised BeamMP nickname (or the server-configured name),
-- plus the server's suffix. Sanitising here keeps the mapping deterministic
-- across clients; see compat.sanitizeProfileName.
local function resolveProfileName()
	local base = MPConfig.getNickname()
	if clientConfig and clientConfig.serverSaveNameEnabled and clientConfig.serverSaveName ~= "" then
		base = clientConfig.serverSaveName
	end
	local suffix = (clientConfig and clientConfig.serverSaveSuffix) or ""
	return compat.sanitizeProfileName(tostring(base) .. tostring(suffix))
end

local function rxCareerSync(data)
	clientConfig = jsonDecode(data)
	if not clientConfig then
		log("E", logTag, "rxCareerSync: could not decode client config")
		return
	end
	nickname = MPConfig.getNickname()
	settingsCheck()
	actionsCheck()

	if careerMPActive then return end

	-- Must be in place before the career activates, or activation deletes every
	-- other player's vehicle.
	local careerPatches = extensions.careerMP_careerPatches
	if not (careerPatches and careerPatches.ensure()) then
		log("E", logTag, "career patches not applied - refusing to start career " ..
			"(would delete other players' vehicles)")
		return
	end

	local profileName = resolveProfileName()
	log("I", logTag, string.format("starting career profile '%s' (nickname '%s', startMode '%s')",
		profileName, tostring(nickname), compat.defaultStartMode))

	-- The shield has to wrap this call, not activateCareer.
	--
	-- career.lua's createOrLoadCareerAndStart invokes its *local* activateCareer() with
	-- no arguments, so removeVehicles defaults to true and it runs
	-- core_vehicles.removeAll() -- wiping every vehicle in the level, including other
	-- players' cars. A wrapper on career_career.activateCareer never sees that call,
	-- because a local call does not go through the module table. Observed live: a second
	-- player joining deleted the first player's car on their own screen the instant
	-- their career activated.
	local started = careerPatches.withRemoteVehiclesProtected(function()
		return compat.createOrLoadCareerAndStart(profileName, false, compat.defaultStartMode)
	end)

	if started then
		careerMPActive = true
	else
		log("E", logTag, "createOrLoadCareerAndStart failed for profile '" .. profileName .. "'")
	end
end

local function rxClientConfigUpdate(data)
	local decoded = jsonDecode(data)
	if not decoded then return end
	clientConfig = decoded
	settingsCheck()
	actionsCheck()
end

-- Career activation spawns the player's own starter vehicle; drop the BeamMP
-- vehicles we already own so we do not end up with duplicates. Never touches
-- vehicles owned by other players.
local function onCareerActive(active)
	if not (active and careerMPActive) then return end
	local vehicles = MPVehicleGE.getVehicles()
	for _, vehicle in pairs(vehicles) do
		if vehicle.isLocal and vehicle.jbeam ~= "unicycle" then
			local veh = be:getObjectByID(vehicle.gameVehicleID)
			if veh then veh:delete() end
		end
	end
end

local function onWorldReadyState(state)
	if state == 2 and not syncRequested then
		TriggerServerEvent("prefabSyncRequested", "")
		TriggerServerEvent("careerSyncRequested", "")
		syncRequested = true
	end
end

local function onClientPostStartMission(levelPath)
	patchTopBar()
end

local function onUpdate(dtReal, dtSim, dtRaw)
	if worldReadyState ~= 2 or not clientConfig then return end
	local vehicles = MPVehicleGE.getVehicles()
	for serverVehicleID in pairs(vehicles) do
		local veh = be:getObjectByID(vehicles[serverVehicleID].gameVehicleID)
		if veh then
			if not MPVehicleGE.isOwn(vehicles[serverVehicleID].gameVehicleID) then
				local ghost = veh.JBeam == "unicycle" and clientConfig.remoteUnicycleGhost or clientConfig.remoteVehicleGhost
				veh:queueLuaCommand(string.format('careerMPEnabler.setGhost(%s)', tostring(ghost)))
			elseif veh.JBeam == "unicycle" then
				veh:queueLuaCommand(string.format('careerMPEnabler.setGhost(%s)', tostring(clientConfig.localUnicycleGhost)))
			end
		end
	end
end

--Loading / Unloading

local function onExtensionLoaded()
	compat = extensions.careerMP_compat
	patches = extensions.careerMP_patches
	if not compat then
		log("E", logTag, "careerMP_compat failed to load - aborting")
		return false
	end

	compat.report()

	nickname = MPConfig.getNickname()
	getUserTrafficSettings()
	getUserGameplaySettings()

	AddEventHandler("rxCareerSync", rxCareerSync)
	AddEventHandler("rxClientConfigUpdate", rxClientConfigUpdate)
	AddEventHandler("rxCareerVehSync", rxCareerVehSync)
	AddEventHandler("rxTrafficSignalTimer", rxTrafficSignalTimer)

	log("I", logTag, "CareerMP Enabler LOADED (target BeamNG " .. compat.targetGameVersion .. ")")
end

local function onExtensionUnloaded()
	log("I", logTag, "CareerMP Enabler UNLOADED")
end

local function onServerLeave()
	blockedInputActions = {}
	extensions.core_input_actionFilter.setGroup('careerMP', blockedInputActions)
	extensions.core_input_actionFilter.addAction(0, 'careerMP', false)
	setTrafficSettings(userTrafficSettings)
	setGameplaySettings(userGameplaySettings)
	careerMPActive = false
	syncRequested = false
end

--Access

M.getClientConfig = getClientConfig

M.onCareerActive = onCareerActive

M.onVehicleActiveChanged = onVehicleActiveChanged
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleReady = onVehicleReady
M.onVehicleSwitched = onVehicleSwitched

M.onSpeedTrapTriggered = onSpeedTrapTriggered
M.onRedLightCamTriggered = onRedLightCamTriggered

M.onComputerOpenedMP = onComputerOpenedMP

-- Enriched hooks published by careerMP_patches. The stock hooks carry no
-- vehicle id, which is the only reason CareerMP 0.0.37 forked these modules.
M.onCareerTuningStartedMP = computerMenuHandler
M.onPartShoppingStartedMP = computerMenuHandler
M.onVehiclePaintingUiOpenedMP = computerMenuHandler
M.onPerformanceTestStartedMP = computerMenuHandler

M.onClientPostStartMission = onClientPostStartMission

M.onWorldReadyState = onWorldReadyState
M.onUpdate = onUpdate

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

M.onServerLeave = onServerLeave

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
