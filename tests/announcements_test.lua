-- careerMPEnabler.lua: speed-trap and red-light announcements go out for cars players
-- drive and never for a player's AI traffic, which BeamMP counts as their own.

local SOURCE = "Resources/Client/CareerMP/lua/ge/extensions/careerMPEnabler.lua"

local sent

-- Vehicles 1 to 4 are this player's own: 1 driven by the player (the career inserts it
-- into traffic data without AI), 2 an AI traffic car, 3 not in traffic data at all,
-- 4 a traffic entry whose AI is switched off. Vehicle 9 belongs to another player.
local function loadEnabler(trafficData)
	sent = {}
	function log() end
	function TriggerServerEvent(name, data) table.insert(sent, name) end
	function jsonEncode() return "{}" end
	MPVehicleGE = {isOwn = function(id) return id >= 1 and id <= 4 end}
	be = {getObjectByID = function() return {JBeam = "pickup", getDynDataFieldbyName = function() return "ABC 123" end} end}
	core_vehicles = {getModel = function() return {model = {Name = "Pickup"}} end}
	gameplay_speedTrapLeaderboards = {addRecord = function() return false, {} end}
	if trafficData == false then
		gameplay_traffic = nil
	else
		gameplay_traffic = {getTrafficData = function() return trafficData end}
	end
	return dofile(SOURCE)
end

local function defaultTraffic()
	return {[1] = {isAi = false}, [2] = {isAi = true}, [4] = {isAi = false}, [9] = {isAi = true}}
end

local function speedTrap(enabler, id)
	sent = {}
	enabler.onSpeedTrapTriggered({subjectID = id}, 30, 10)
	return #sent
end

local function redLight(enabler, id)
	sent = {}
	enabler.onRedLightCamTriggered({subjectID = id}, 20)
	return #sent
end

test("a car the player drives is still announced by both cameras", function()
	local enabler = loadEnabler(defaultTraffic())
	same(speedTrap(enabler, 1), 1, "speed trap events")
	same(redLight(enabler, 1), 1, "red light events")
end)

test("the player's AI traffic is announced by neither camera", function()
	local enabler = loadEnabler(defaultTraffic())
	same(speedTrap(enabler, 2), 0, "speed trap events")
	same(redLight(enabler, 2), 0, "red light events")
end)

test("an own car outside traffic data, or with its AI off, is announced", function()
	local enabler = loadEnabler(defaultTraffic())
	same(speedTrap(enabler, 3), 1, "no traffic entry")
	same(redLight(enabler, 4), 1, "AI off")
end)

test("another player's car is never announced from this client", function()
	local enabler = loadEnabler(defaultTraffic())
	same(speedTrap(enabler, 9), 0, "speed trap events")
	same(redLight(enabler, 9), 0, "red light events")
end)

test("without the traffic system, or with no traffic data, announcements are as before", function()
	local enabler = loadEnabler(false)
	same(speedTrap(enabler, 2), 1, "no gameplay_traffic")
	enabler = loadEnabler(nil)
	same(redLight(enabler, 2), 1, "getTrafficData returns nil")
end)
