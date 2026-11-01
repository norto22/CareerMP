--CareerMP :: damage between players (CLIENT)
--
-- BeamMP sends where another player's car is but never its dents, so each game used to
-- simulate its own damage on its copy of that car. The car's own game now decides:
--
--   * Once a second each car gets a role in its vehicle Lua (careerMPDamage): "owner"
--     for this player's own cars that are not traffic or parked (after two checks in a
--     row, because the game flags new traffic a moment after it spawns), "copy" for
--     another player's car. The walking unicycle gets neither.
--   * An owner's vehicle Lua hands its changed beams to onLocalDamage; they go to the
--     server ("careerDamage") at most SENDS_PER_SECOND a second, queued.
--   * A copy asks the owner for the car's full damage once ("careerDamageRequest"), and
--     each damage message from the server ("rxCareerDamage") is checked and handed to the
--     copy's vehicle Lua.
--
-- Only numbers this module has checked and formatted itself reach a vehicle command; no
-- text from another player's message is ever pasted into one.

local M = {}

local logTag = "careerMP.damageSync"

local ROLES_EVERY_SECONDS = 1
local OWNER_CHECKS = 2
local SENDS_PER_SECOND = 3
local MAX_QUEUE = 30
local MAX_MESSAGE_BYTES = 32768
local MAX_BEAMS = 400
local MAX_NODES = 500

local roles = {}          -- game vehicle id -> "owner" | "copy"
local ownerChecks = {}    -- game vehicle id -> checks in a row as an own player car
local outbox = {}         -- messages waiting for the server
local sinceRoles = 0
local sinceSend = 0
local warned = {}

local function warnOnce(key, msg)
	if warned[key] then return end
	warned[key] = true
	log("W", logTag, msg)
end

-- A server vehicle id exactly as the server writes it: "<player>-<vehicle>".
local function isServerVehicleID(sid)
	return type(sid) == "string" and sid:match("^%d+%-%d+$") ~= nil
end

local function isAiTraffic(gameVehicleID)
	if not gameplay_traffic or type(gameplay_traffic.getTrafficData) ~= "function" then return false end
	local entry = (gameplay_traffic.getTrafficData() or {})[gameVehicleID]
	return type(entry) == "table" and entry.isAi == true
end

-- The car the player is in is theirs, even one taken from traffic.
local function isTrafficCar(gameVehicleID, veh)
	if gameVehicleID == be:getPlayerVehicleID(0) then return false end
	if veh.isTraffic == "true" or veh.isParked == "true" then return true end
	return isAiTraffic(gameVehicleID)
end

local function requestFull(serverVehicleID)
	TriggerServerEvent("careerDamageRequest", '{"v":"' .. serverVehicleID .. '"}')
end

local function forget(gameVehicleID)
	roles[gameVehicleID] = nil
	ownerChecks[gameVehicleID] = nil
end

local function assignRoles()
	local seen = {}
	for serverVehicleID, entry in pairs(MPVehicleGE.getVehicles()) do
		local gameVehicleID = entry.gameVehicleID
		local veh = gameVehicleID and gameVehicleID ~= -1 and be:getObjectByID(gameVehicleID)
		if veh and isServerVehicleID(serverVehicleID) then
			seen[gameVehicleID] = true
			local wanted = nil
			if veh.JBeam ~= "unicycle" then
				if MPVehicleGE.isOwn(gameVehicleID) then
					if isTrafficCar(gameVehicleID, veh) then
						ownerChecks[gameVehicleID] = 0
					else
						ownerChecks[gameVehicleID] = (ownerChecks[gameVehicleID] or 0) + 1
					end
					if ownerChecks[gameVehicleID] >= OWNER_CHECKS then wanted = "owner" end
				else
					wanted = "copy"
				end
			end
			if roles[gameVehicleID] ~= wanted then
				roles[gameVehicleID] = wanted
				veh:queueLuaCommand(string.format("careerMPDamage.setRole(%q)", wanted or "none"))
				if wanted == "copy" then requestFull(serverVehicleID) end
			end
		end
	end
	for gameVehicleID in pairs(roles) do
		if not seen[gameVehicleID] then forget(gameVehicleID) end
	end
end

--== outgoing ================================================================

-- From an owner car's vehicle Lua: one message of its changed beams, without the car id.
local function onLocalDamage(gameVehicleID, message)
	if roles[gameVehicleID] ~= "owner" or type(message) ~= "string" or message:sub(1, 1) ~= "{" then return end
	local serverVehicleID = MPVehicleGE.getServerVehicleID(gameVehicleID)
	if not isServerVehicleID(serverVehicleID) then return end
	local full = '{"v":"' .. serverVehicleID .. '",' .. message:sub(2)
	if #full > MAX_MESSAGE_BYTES then
		warnOnce("size", string.format("a damage message of %d bytes was not sent (limit %d)", #full, MAX_MESSAGE_BYTES))
		return
	end
	if #outbox >= MAX_QUEUE then
		warnOnce("queue", "damage messages queued faster than they can be sent - some were dropped")
		outbox = {}
	end
	table.insert(outbox, full)
end

local function sendQueued(dt)
	sinceSend = math.min(sinceSend + dt, 1 / SENDS_PER_SECOND)
	if #outbox == 0 or sinceSend < 1 / SENDS_PER_SECOND then return end
	sinceSend = 0
	TriggerServerEvent("careerDamage", table.remove(outbox, 1))
end

--== incoming ================================================================

local function isNumber(x)
	return type(x) == "number" and x == x and x > -math.huge and x < math.huge
end

-- A flat list of rows of four numbers, the first of each row an id, formatted as Lua
-- number text; nil when anything else is in it.
local function numberRows(list, maxRows)
	if type(list) ~= "table" or #list % 4 ~= 0 or #list / 4 > maxRows then return nil end
	local parts = {}
	for i = 1, #list do
		local x = list[i]
		if not isNumber(x) then return nil end
		if i % 4 == 1 then
			if x < 0 or x > 2147483647 or x ~= math.floor(x) then return nil end
			parts[i] = string.format("%d", x)
		else
			parts[i] = string.format("%.4f", x)
		end
	end
	return table.concat(parts, ",")
end

local function rxCareerDamage(data)
	if type(data) ~= "string" or #data > MAX_MESSAGE_BYTES then return end
	-- Text from another player's game: the game's decoder may raise on a bad one.
	local ok, message = pcall(jsonDecode, data)
	if not ok or type(message) ~= "table" or not isServerVehicleID(message.v) then return end
	local gameVehicleID = MPVehicleGE.getGameVehicleID(message.v)
	if not gameVehicleID or gameVehicleID == -1 or MPVehicleGE.isOwn(gameVehicleID) then return end
	if roles[gameVehicleID] ~= "copy" then return end
	local veh = be:getObjectByID(gameVehicleID)
	if not veh then return end
	local beams, nodes = numberRows(message.b, MAX_BEAMS), numberRows(message.n, MAX_NODES)
	if not beams or not nodes then
		warnOnce("malformed", "a damage message for " .. message.v .. " was not in the expected form")
		return
	end
	local cleared = message.c == 1 and 1 or 0
	veh:queueLuaCommand(string.format("careerMPDamage.applyDamage(%d,{%s},{%s})", cleared, beams, nodes))
end

--== hooks ===================================================================

local function onUpdate(dtReal)
	local dt = tonumber(dtReal) or 0
	if dt < 0 then dt = 0 end
	sinceRoles = sinceRoles + dt
	if sinceRoles >= ROLES_EVERY_SECONDS then
		sinceRoles = 0
		assignRoles()
	end
	sendQueued(dt)
end

-- A respawned car has a fresh vehicle Lua: it gets its role (and a copy its damage)
-- again on the next check.
local function onVehicleSpawned(gameVehicleID)
	forget(gameVehicleID)
end

local function onBeamMPServerLeave()
	roles, ownerChecks, outbox = {}, {}, {}
	sinceRoles, sinceSend = 0, 0
end

local function onExtensionLoaded()
	if type(AddEventHandler) ~= "function" then
		log("E", logTag, "AddEventHandler unavailable - BeamMP not loaded, damage is not shared")
		return
	end
	AddEventHandler("rxCareerDamage", rxCareerDamage)
	log("I", logTag, "CareerMP damage sync LOADED")
end

M.onLocalDamage = onLocalDamage
M.onUpdate = onUpdate
M.onVehicleSpawned = onVehicleSpawned
M.onVehicleDestroyed = forget
M.onBeamMPServerLeave = onBeamMPServerLeave
M.onExtensionLoaded = onExtensionLoaded

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
