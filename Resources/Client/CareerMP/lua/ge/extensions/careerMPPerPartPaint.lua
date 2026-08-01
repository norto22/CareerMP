--CareerMP 0.39 :: per-part paint sync (CLIENT)
--
-- Port of CareerMP 0.0.37's careerMPPerPartPaint. Original by Dudekahedron, 2026.
--
-- BeamMP syncs a vehicle's overall paint but not per-part paint, which career
-- tracks in partConditions[*].visualState.paint.originalPaints. Replacement
-- parts therefore show up unpainted (or wrongly painted) on everyone else's
-- screen. This sends each part's paint over the wire and applies it vehicle-side
-- via partCondition.setPartPaints.
--
-- Every game API this uses is unchanged between 0.38.6 and 0.39
-- (validateVehiclePaint, partCondition.ensureConditionsInit/setPartPaints,
-- getInventoryIdFromVehicleId, originalPaints), so the port is behaviour-for-
-- behaviour apart from the hook names and three bug fixes noted inline.

local M = {}

local logTag = "careerMP.paint"

-- inventoryIds whose vehicle had no serverVehicleID yet; retried in onUpdate.
local pendingPaints = {}
-- gameVehicleID -> paintData waiting on the vehicle's partConditions to init.
local pendingRemotePaints = {}
local ensuredPartConditionsByVeh = {}

local function clampHelper(value)
	return clamp(tonumber(value) or 0, 0, 1)
end

local function copyPaint(paint)
	local base = paint.baseColor or {}
	return {
		baseColor = { base[1] or 1, base[2] or 1, base[3] or 1, base[4] or 1 },
		metallic = paint.metallic or 0,
		roughness = paint.roughness or 0.5,
		clearcoat = paint.clearcoat or 0,
		clearcoatRoughness = paint.clearcoatRoughness or 0
	}
end

local function sanitizePaint(paint)
	local sanitized = copyPaint(paint) or {}
	validateVehiclePaint(sanitized)
	local base = sanitized.baseColor or {}
	sanitized.baseColor = {
		clampHelper(base[1]),
		clampHelper(base[2]),
		clampHelper(base[3]),
		clampHelper(base[4] or 1)
	}
	sanitized.metallic = clampHelper(sanitized.metallic)
	sanitized.roughness = clampHelper(sanitized.roughness)
	sanitized.clearcoat = clampHelper(sanitized.clearcoat)
	sanitized.clearcoatRoughness = clampHelper(sanitized.clearcoatRoughness)
	return sanitized
end

-- A vehicle always carries three paint layers; fill missing ones by repeating
-- the last provided layer.
local function sanitizePaints(paints)
	local sanitized = {}
	local lastPaint = nil
	for i = 1, 3 do
		local paint = paints[i] or lastPaint or paints[1]
		if not paint then break end
		local sanitizedPaint = sanitizePaint(paint)
		if not sanitizedPaint then break end
		sanitized[i] = sanitizedPaint
		lastPaint = paint
	end
	if tableIsEmpty(sanitized) then return nil end
	if not sanitized[2] then sanitized[2] = copyPaint(sanitized[1]) end
	if not sanitized[3] then sanitized[3] = copyPaint(sanitized[2] or sanitized[1]) end
	return sanitized
end

-- Paint has to cross into the vehicle Lua VM, and queueLuaCommand takes a
-- string, so the tables are serialised as Lua literals.
local function paintsToLuaLiteral(paints)
	if tableIsEmpty(paints) then
		return '{ {baseColor={1, 1, 1, 1}, metallic = 0, roughness = 0.5 , clearcoat = 0, clearcoatRoughness = 0 } }'
	end
	local segments = {}
	for i = 1, #paints do
		local paint = paints[i] or {}
		local base = paint.baseColor or {}
		segments[#segments + 1] = string.format(
			'{baseColor = {%s, %s, %s, %s}, metallic = %s, roughness = %s, clearcoat = %s, clearcoatRoughness = %s}',
			string.format('%.6f', base[1] or 0),
			string.format('%.6f', base[2] or 0),
			string.format('%.6f', base[3] or 0),
			string.format('%.6f', base[4] or 1),
			string.format('%.6f', paint.metallic or 0),
			string.format('%.6f', paint.roughness or 0),
			string.format('%.6f', paint.clearcoat or 0),
			string.format('%.6f', paint.clearcoatRoughness or 0)
		)
	end
	return '{' .. table.concat(segments, ',') .. '}'
end

local function identifiersToLuaLiteral(identifiers)
	if type(identifiers) ~= "table" or tableIsEmpty(identifiers) then return "{}" end
	local segments = {}
	for i = 1, #identifiers do
		local identifier = identifiers[i]
		if identifier and identifier ~= '' then
			segments[#segments + 1] = string.format('%q', identifier)
		end
	end
	if tableIsEmpty(segments) then return '{}' end
	return '{' .. table.concat(segments, ',') .. '}'
end

-- Part naming differs between the sender's and receiver's part trees, so try
-- several identifiers and let the vehicle side match whichever it knows.
local function buildIdentifiers(partPath, partName, slotPath)
	local ids = {}
	if partPath and partPath ~= "" then ids[#ids + 1] = partPath end
	if partName and partName ~= "" and partName ~= partPath then ids[#ids + 1] = partName end
	if slotPath and slotPath ~= "" then ids[#ids + 1] = slotPath end
	return ids
end

local function ensureVehiclePartConditionInitialized(vehObj, gameVehicleID)
	if not vehObj or not vehObj.queueLuaCommand then return end
	local id = gameVehicleID or (vehObj.getID and vehObj:getID())
	if not id or id == -1 then return end
	if ensuredPartConditionsByVeh[id] then return end
	vehObj:queueLuaCommand([=[if partCondition and partCondition.ensureConditionsInit then
		partCondition.ensureConditionsInit(0, 1, 1)
	end]=])
	ensuredPartConditionsByVeh[id] = true
end

local function queuePartPaintCommands(vehObj, identifiers, paints)
	if not vehObj or not paints or not identifiers or #identifiers == 0 then return end
	vehObj:queueLuaCommand(string.format([[
		local identifiers = %s
		local paints = %s
		if partCondition then
			if partCondition.ensureConditionsInit then
				partCondition.ensureConditionsInit(0, 1, 1)
			end
			if partCondition.setPartPaints then
				for _, identifier in ipairs(identifiers) do
					partCondition.setPartPaints(identifier, paints, 0)
				end
			end
		end
		]],
		identifiersToLuaLiteral(identifiers),
		paintsToLuaLiteral(paints)
	))
end

local function setPartPaintRemote(gameVehicleID, partPath, paints, partName, slotPath)
	if not gameVehicleID or not paints then return end
	local vehObj = be:getObjectByID(gameVehicleID)
	if not vehObj then return end
	paints = sanitizePaints(paints)
	if not paints then return end
	local identifiers = buildIdentifiers(partPath, partName, slotPath)
	if #identifiers == 0 then return end
	ensureVehiclePartConditionInitialized(vehObj, gameVehicleID)
	queuePartPaintCommands(vehObj, identifiers, paints)
end

local function applyPartPaintRemote(data)
	if not data then return end
	setPartPaintRemote(data.gameVehicleID, data.partPath, data.paints, data.partName, data.slotPath)
end

local function sendPartPaints(inventoryId, serverVehicleID, originID)
	local vehicle = career_modules_inventory.getVehicles()[inventoryId]
	if not vehicle or not vehicle.partConditions then return end
	for part, partData in pairs(vehicle.partConditions) do
		if partData.visualState and partData.visualState.paint then
			local data = {}
			data.partPath = part
			data.slotPath, data.partName = string.match(data.partPath, "(.*/)([^/]+)$")
			data.paints = partData.visualState.paint.originalPaints
			data.serverVehicleID = serverVehicleID
			if originID then data.originID = originID end
			TriggerServerEvent("perPartPainting", jsonEncode(data))
		end
	end
end

-- FIX (was a bug in 0.0.37): the original looped every MP vehicle and pushed the
-- inventoryId onto pendingPaints once per NON-matching vehicle, so a single
-- spawn queued N-1 redundant retries and grew pendingPaints without bound.
-- Resolve once, queue at most one retry.
local function onInventorySpawnVehicleMP(inventoryId, gameVehicleID)
	if not inventoryId then return end
	if gameVehicleID then
		local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
		if serverVehicleID then
			sendPartPaints(inventoryId, serverVehicleID)
			return
		end
	end
	table.insert(pendingPaints, inventoryId)
end

local function rxRemotePartPaint(data)
	local paintData = jsonDecode(data)
	if not paintData or not paintData.serverVehicleID then return end
	if MPVehicleGE.getVehicles()[paintData.serverVehicleID] then
		paintData.gameVehicleID = MPVehicleGE.getGameVehicleID(paintData.serverVehicleID)
		applyPartPaintRemote(paintData)
	elseif paintData.gameVehicleID then
		pendingRemotePaints[paintData.gameVehicleID] = paintData
	end
end

local function rxRequestPartPaints(data)
	local requestData = jsonDecode(data)
	if not requestData or not requestData.serverVehicleID then return end
	local gameVehicleID = MPVehicleGE.getGameVehicleID(requestData.serverVehicleID)
	if not gameVehicleID then return end
	local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(gameVehicleID)
	if not inventoryId then return end
	sendPartPaints(inventoryId, requestData.serverVehicleID, requestData.originID)
end

local function onVehicleReady(gameVehicleID)
	local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
	if not serverVehicleID then return end
	if not MPVehicleGE.isOwn(gameVehicleID) then
		-- Someone else's vehicle appeared; ask its owner for the part paints.
		TriggerServerEvent("requestPartPaints", jsonEncode({serverVehicleID = serverVehicleID}))
	else
		local inventoryId = career_modules_inventory.getInventoryIdFromVehicleId(gameVehicleID)
		if inventoryId then sendPartPaints(inventoryId, serverVehicleID) end
	end
end

local function onVehicleDestroyed(vehId)
	ensuredPartConditionsByVeh[vehId] = nil
	pendingRemotePaints[vehId] = nil
end

-- Re-broadcast after anything that can change a part's paint.
local function broadcastForInventoryId(inventoryId)
	if not inventoryId then return end
	local gameVehicleID = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
	if not gameVehicleID then return end
	local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
	if serverVehicleID then sendPartPaints(inventoryId, serverVehicleID) end
end

local function onPartShoppingStartedMP(targetVehicleID, inventoryId)
	broadcastForInventoryId(inventoryId)
end

local function onPartShoppingPartInstalledMP(partData)
	if partData then broadcastForInventoryId(partData.inventoryId) end
end

local function onPartShoppingTransactionCompleteMP(inventoryId)
	broadcastForInventoryId(inventoryId)
end

-- FIX (was a bug in 0.0.37): pendingRemotePaints is keyed by gameVehicleID, so
-- the entry IS the paintData -- the original indexed `.paintData` on it (always
-- nil) and then called table.remove with a key on a non-array table. Both are
-- corrected here.
local function onConditionCheckCallback(gameVehicleID)
	local paintData = pendingRemotePaints[gameVehicleID]
	if not paintData then return end
	applyPartPaintRemote(paintData)
	pendingRemotePaints[gameVehicleID] = nil
end

local function onUpdate()
	if worldReadyState ~= 2 then return end

	for i = #pendingPaints, 1, -1 do
		local inventoryId = pendingPaints[i]
		local gameVehicleID = career_modules_inventory.getVehicleIdFromInventoryId(inventoryId)
		if gameVehicleID then
			local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
			if serverVehicleID then
				sendPartPaints(inventoryId, serverVehicleID)
				table.remove(pendingPaints, i)
			end
		end
	end

	-- Paints that arrived before the vehicle's partConditions existed: poke the
	-- vehicle, and onConditionCheckCallback applies them once it reports ready.
	for gameVehicleID, paintData in pairs(pendingRemotePaints) do
		if not paintData.serverVehicleID then
			paintData.serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
		end
		if paintData.serverVehicleID then
			local veh = be:getObjectByID(gameVehicleID)
			if veh then
				veh:queueLuaCommand('careerMPEnabler.onConditionCheck()')
			else
				pendingRemotePaints[gameVehicleID] = nil
			end
		end
	end
end

local function onExtensionLoaded()
	AddEventHandler("rxRequestPartPaints", rxRequestPartPaints)
	AddEventHandler("rxRemotePartPaint", rxRemotePartPaint)
	log("I", logTag, "CareerMP perPartPaint LOADED")
end

local function onExtensionUnloaded()
	log("I", logTag, "CareerMP perPartPaint UNLOADED")
end

M.onConditionCheckCallback = onConditionCheckCallback

-- Enriched hooks from careerMP_patches (the stock ones carry no vehicle id).
M.onInventorySpawnVehicleMP = onInventorySpawnVehicleMP
M.onPartShoppingStartedMP = onPartShoppingStartedMP
M.onPartShoppingPartInstalledMP = onPartShoppingPartInstalledMP
M.onPartShoppingTransactionCompleteMP = onPartShoppingTransactionCompleteMP

M.onVehicleReady = onVehicleReady
M.onVehicleDestroyed = onVehicleDestroyed

M.onUpdate = onUpdate

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
