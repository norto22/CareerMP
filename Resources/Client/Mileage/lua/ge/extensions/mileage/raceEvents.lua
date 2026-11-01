--Mileage :: race events the server owner runs (CLIENT)
--
-- The owner schedules a race event (see the Events section of the server plugin). The
-- server tells every game ahead of time (rxMileageEvent "announce"); the player joins or
-- leaves from the prompts app (join, leave). At the start the server gives each joined
-- game a grid pose: this moves the car there with the game's safe teleport and hands the
-- race to mileage/streetRace.lua, which counts down, times it from its own green and
-- reports the finish. For a random finish the server asks one joined game for a point on
-- the game's road map 1.5 to 4 km from the start ("pickFinish"). The prompts app shows
-- every phase (guihook MileageEvent).

local M = {}

local logTag = "mileage.raceEvents"

-- The last event message, for the prompts app after a UI reload.
local current = nil

local function compat()
	local c = extensions.mileage_compat
	if type(c) == "table" then return c end
	return nil
end

local function streetRace()
	local race = extensions.mileage_streetRace
	if type(race) == "table" then return race end
	return nil
end

local function isPoint(p)
	return type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number"
end

local function report(fields)
	TriggerServerEvent("mileageRaceReport", jsonEncode(fields))
end

-- A random road node between min and max metres from start, sent to the server.
local function pickFinish(message)
	local c = compat()
	local nodes = c and c.getMapNodes()
	if type(nodes) ~= "table" or not isPoint(message.start) then return end
	local low, high = tonumber(message.min) or 1500, tonumber(message.max) or 4000
	local candidates = {}
	for _, node in pairs(nodes) do
		local pos = type(node) == "table" and node.pos
		if isPoint(pos) then
			local dx, dy = pos.x - message.start.x, pos.y - message.start.y
			local metres = math.sqrt(dx * dx + dy * dy)
			if metres >= low and metres <= high then table.insert(candidates, pos) end
		end
	end
	if #candidates == 0 then
		log("W", logTag, "no road point within the event's distance; the server uses its own finish")
		return
	end
	local pos = candidates[math.random(#candidates)]
	report({race = message.id, finish = {x = pos.x, y = pos.y, z = pos.z}})
end

-- Moves this car to its place on the grid and starts the race here.
local function startAtGrid(message)
	local pose = message.pose
	local c, race = compat(), streetRace()
	if type(pose) ~= "table" or not isPoint(pose.pos) or not isPoint(pose.dir) or not isPoint(pose.up) then return end
	local id = be:getPlayerVehicleID(0)
	local veh = id and id >= 0 and be:getObjectByID(id) or nil
	if not veh or not c or not race then
		log("W", logTag, "not in a car at the event's start; the race runs without this player")
		return
	end
	local rot = quatFromDir(vec3(pose.dir.x, pose.dir.y, pose.dir.z), vec3(pose.up.x, pose.up.y, pose.up.z))
	if not c.safeTeleport(veh, vec3(pose.pos.x, pose.pos.y, pose.pos.z), rot) then return end
	race.startEventRace({id = message.id, finish = message.finish, radius = message.radius,
		seconds = message.seconds})
end

local function rxMileageEvent(data)
	local message = jsonDecode(data)
	if type(message) ~= "table" or type(message.id) ~= "string" then return end
	local phase = message.phase
	if phase == "pickFinish" then
		pickFinish(message)
		return
	end
	if phase == "start" then
		startAtGrid(message)
	elseif phase == "result" or phase == "over" or phase == "cancelled" then
		local race = streetRace()
		if race then race.stopRace(message.id) end
	end
	current = message
	guihooks.trigger("MileageEvent", message)
end

--- Joins the announced event.
function M.join(id)
	if type(id) ~= "string" then return false end
	TriggerServerEvent("mileageOfferAnswer", jsonEncode({id = id, accept = true}))
	return true
end

--- Leaves the announced event, or turns its invitation down.
function M.leave(id)
	if type(id) ~= "string" then return false end
	TriggerServerEvent("mileageOfferAnswer", jsonEncode({id = id, accept = false}))
	return true
end

function M.sendState()
	if current then guihooks.trigger("MileageEvent", current) end
end

function M.onBeamMPServerLeave()
	current = nil
end

function M.onExtensionLoaded()
	if type(AddEventHandler) ~= "function" then
		log("E", logTag, "AddEventHandler unavailable - BeamMP not loaded")
		return
	end
	AddEventHandler("rxMileageEvent", rxMileageEvent)
	log("I", logTag, "Mileage race events LOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
