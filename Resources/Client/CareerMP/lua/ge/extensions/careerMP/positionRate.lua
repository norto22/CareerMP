--CareerMP :: position rate (CLIENT)
--
-- BeamMP sends the position of every car this game owns up to 50 times a second, traffic
-- and parked cars included, and the server passes each one to every other player. Most
-- of those cars are traffic nobody else is near and parked cars standing still, where a
-- late update cannot be seen. While the career runs on a server, CareerMP's check sits in
-- front of BeamMP's send (positionGE.sendVehiclePosRot, which BeamMP's vehicle Lua calls
-- by name for each position):
--
--   * a parked car moving under PARKED_STILL_SPEED sends at most once a second;
--   * driving traffic more than FAR_DISTANCE from every other player's car (their
--     traffic not counted) sends at most twice a second;
--   * a hidden car sends nothing;
--   * everything else - the car the player drives, the player's other cars, traffic near
--     another player, a parked car that is moving - sends every position, as before.
--
-- Each car's rule is worked out once a second (a still parked car's speed four times a
-- second, so a car that is hit is sent at once), never on each send. If BeamMP's function
-- is missing the log says so once and BeamMP sends as it always does; if the check fails
-- every position goes through. BeamMP's own files are not changed.

local M = {}

local logTag = "careerMP.positionRate"

local PARKED_STILL_SPEED = 0.5   -- metres a second
local PARKED_EVERY = 1           -- seconds between positions of a still parked car
local FAR_DISTANCE = 500         -- metres from every other player's car
local FAR_EVERY = 0.5            -- seconds between positions of far traffic
local CLASSIFY_EVERY = 1         -- seconds between working out each car's rule
local PARKED_CHECK_EVERY = 0.25  -- seconds between speed checks of still parked cars

-- {module, original, check} while BeamMP's send is wrapped.
local wrapped = nil

-- Own cars under a rule, by game vehicle id: {kind = "parked" | "far" | "hidden", last = time
-- of the last position let through}. A car not listed sends every position.
local limited = {}

local clock = 0
local sinceClassify = CLASSIFY_EVERY
local sinceParkedCheck = 0
local failureLogged = false

local function isTraffic(gameVehicleID, veh)
	local enabler = careerMPEnabler
	return type(enabler) == "table" and type(enabler.isTrafficCar) == "function"
		and enabler.isTrafficCar(gameVehicleID, veh) == true
end

local function isRemoteTraffic(serverVehicleID)
	local enabler = careerMPEnabler
	return type(enabler) == "table" and type(enabler.isRemoteTraffic) == "function"
		and enabler.isRemoteTraffic(serverVehicleID) == true
end

local function farFromAll(pos, others)
	for _, other in ipairs(others) do
		local dx, dy, dz = pos.x - other.x, pos.y - other.y, pos.z - other.z
		if dx * dx + dy * dy + dz * dz <= FAR_DISTANCE * FAR_DISTANCE then return false end
	end
	return true
end

local function isStill(veh)
	return veh:getVelocity():length() < PARKED_STILL_SPEED
end

-- Works out the rule of every own car.
local function classify()
	local vehicles = MPVehicleGE.getVehicles()
	local playerVehicle = be:getPlayerVehicleID(0)
	local others, own = {}, {}
	for serverVehicleID, entry in pairs(vehicles) do
		local gameVehicleID = entry.gameVehicleID
		local veh = gameVehicleID and gameVehicleID ~= -1 and be:getObjectByID(gameVehicleID)
		if veh then
			if MPVehicleGE.isOwn(gameVehicleID) then
				if gameVehicleID ~= playerVehicle then own[gameVehicleID] = veh end
			elseif veh:getActive() and not isRemoteTraffic(serverVehicleID) then
				table.insert(others, veh:getPosition())
			end
		end
	end
	local rules = {}
	for gameVehicleID, veh in pairs(own) do
		local kind = nil
		if not veh:getActive() then
			kind = "hidden"
		elseif veh.isParked == "true" and isStill(veh) then
			kind = "parked"
		elseif isTraffic(gameVehicleID, veh) and farFromAll(veh:getPosition(), others) then
			kind = "far"
		end
		if kind then
			local previous = limited[gameVehicleID]
			rules[gameVehicleID] = {kind = kind, last = previous and previous.last}
		end
	end
	limited = rules
end

-- A still parked car that starts moving (it was hit) or a hidden car shown again sends
-- every position until the next full check gives it its rule.
local function checkParked()
	for gameVehicleID, rule in pairs(limited) do
		if rule.kind ~= "far" then
			local veh = be:getObjectByID(gameVehicleID)
			if not veh or (rule.kind == "parked" and not isStill(veh)) or (rule.kind == "hidden" and veh:getActive()) then
				limited[gameVehicleID] = nil
			end
		end
	end
end

local function letThrough(gameVehicleID)
	local rule = limited[gameVehicleID]
	if not rule then return true end
	if rule.kind == "hidden" then return false end
	local every = rule.kind == "parked" and PARKED_EVERY or FAR_EVERY
	if rule.last and clock - rule.last < every - 1e-6 then return false end
	rule.last = clock
	return true
end

local function makeCheck(original)
	return function(data, gameVehicleID, ...)
		local ok, through = pcall(letThrough, gameVehicleID)
		if not ok or through then return original(data, gameVehicleID, ...) end
	end
end

local function unwrap(why)
	if not wrapped then return end
	if wrapped.module.sendVehiclePosRot == wrapped.check then
		wrapped.module.sendVehiclePosRot = wrapped.original
	end
	wrapped = nil
	limited = {}
	log("D", logTag, "position check removed (" .. why .. ")")
end

local function wrap()
	local module = positionGE
	if wrapped and wrapped.module == module and module.sendVehiclePosRot == wrapped.check then return end
	-- BeamMP reloaded its module: the old table is no longer used and is left as it is.
	wrapped, limited = nil, {}
	local compat = extensions.careerMP_compat
	local original = compat and compat.pickOrWarn(module, "positionGE", "sendVehiclePosRot",
		"every car's position is sent at BeamMP's own rate")
	if not original then return end
	local check = makeCheck(original)
	wrapped = {module = module, original = original, check = check}
	module.sendVehiclePosRot = check
	sinceClassify, sinceParkedCheck, failureLogged = CLASSIFY_EVERY, 0, false
	log("I", logTag, string.format("position check active - still parked cars send once a second, " ..
		"traffic over %d m from other players twice a second", FAR_DISTANCE))
end

local function failed(err)
	limited = {}
	if failureLogged then return end
	failureLogged = true
	log("E", logTag, "position check failed, every position is sent: " .. tostring(err))
end

--== hooks ===================================================================

function M.onCareerActive(active)
	local compat = extensions.careerMP_compat
	if active and compat and compat.isMPSession() then
		wrap()
	else
		unwrap("career not active")
	end
end

function M.onUpdate(dtReal)
	if not wrapped then return end
	local dt = tonumber(dtReal)
	if not dt or dt < 0 then dt = 0 end
	clock = clock + dt
	sinceClassify = sinceClassify + dt
	sinceParkedCheck = sinceParkedCheck + dt
	if sinceClassify >= CLASSIFY_EVERY then
		sinceClassify, sinceParkedCheck = 0, 0
		local ok, err = pcall(classify)
		if not ok then failed(err) end
	elseif sinceParkedCheck >= PARKED_CHECK_EVERY then
		sinceParkedCheck = 0
		local ok, err = pcall(checkParked)
		if not ok then failed(err) end
	end
end

function M.onBeamMPServerLeave()
	unwrap("left the server")
end

function M.onExtensionLoaded()
	log("I", logTag, "CareerMP position rate LOADED")
end

function M.onExtensionUnloaded()
	unwrap("unloaded")
	log("I", logTag, "CareerMP position rate UNLOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
