-- careerMPEnabler.lua: what this game does to other players' cars. They carry the game's
-- "not traffic" flag, spectating one keeps this player's traffic on their own car, and
-- their active and ghost settings are sent only when they change.

local SOURCE = "Resources/Client/CareerMP/lua/ge/extensions/careerMPEnabler.lua"
local COMPAT = "Resources/Client/CareerMP/lua/ge/extensions/careerMP/compat.lua"

local logs, focusCalls

-- A car in the stand-in game: dynamic fields, setActive and queued vehicle commands are
-- recorded on it.
local function newVehicle(objects, id, jbeam)
	local veh = {id = id, JBeam = jbeam or "pickup", active = true, activeCalls = 0, queued = {}, fields = {}}
	function veh:setDynDataFieldbyName(name, index, value) self.fields[name] = value; self[name] = value end
	function veh:setField() end
	function veh:setActive(on) self.active = on == 1; self.activeCalls = self.activeCalls + 1 end
	function veh:getActive() return self.active end
	function veh:queueLuaCommand(cmd) table.insert(self.queued, cmd) end
	objects[id] = veh
	return veh
end

-- Cars 1 and 2 are this player's own (2 their traffic); 9 and 10 belong to player 1.
-- opts.noTraffic removes gameplay_traffic, opts.noSetFocus only its setFocus.
local function setup(opts)
	opts = opts or {}
	logs, focusCalls = {}, {}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	function TriggerServerEvent() end
	function jsonEncode() return "{}" end
	function jsonDecode(s) return loadstring and loadstring("return " .. s)() or load("return " .. s)() end
	local objects = {}
	newVehicle(objects, 1)
	newVehicle(objects, 2, "covet")
	newVehicle(objects, 9)
	newVehicle(objects, 10, "etk800")
	local ids = {[1] = "0-0", [2] = "0-1", [9] = "1-0", [10] = "1-1"}
	local vehicles = {}
	for gameId, serverId in pairs(ids) do
		vehicles[serverId] = {gameVehicleID = gameId, jbeam = objects[gameId].JBeam}
	end
	MPVehicleGE = {
		isOwn = function(id) return id == 1 or id == 2 end,
		getServerVehicleID = function(id) return ids[id] end,
		getVehicles = function() return vehicles end,
	}
	be = {
		getObjectByID = function(_, id) return objects[id] end,
		getPlayerVehicleID = function() return 1 end,
	}
	if opts.noTraffic then
		gameplay_traffic = nil
	else
		gameplay_traffic = {getTrafficData = function() return {[2] = {isAi = true}} end}
		if not opts.noSetFocus then
			gameplay_traffic.setFocus = function(mode, data) table.insert(focusCalls, {mode = mode, data = data}) end
		end
	end
	extensions = {careerMP_compat = dofile(COMPAT)}
	worldReadyState = 2
	local enabler = dofile(SOURCE)
	return enabler, objects, vehicles
end

--== the "not traffic" flag ==================================================

test("another player's car is flagged so this game's traffic and police leave it alone", function()
	local enabler, objects = setup()
	enabler.onVehicleReady(9)
	same(objects[9].fields.ignoreTraffic, "true", "ignoreTraffic on car 9")
	same(objects[9].ignoreTraffic, "true", "read back as obj.ignoreTraffic")
end)

test("this player's own cars and traffic never get the flag", function()
	local enabler, objects = setup()
	enabler.onVehicleReady(1)
	enabler.onVehicleReady(2)
	same(objects[1].fields.ignoreTraffic, nil, "own car")
	same(objects[2].fields.ignoreTraffic, nil, "own traffic car")
end)

--== traffic focus while spectating ==========================================

test("spectating another player pins this player's traffic on the car they left", function()
	local enabler = setup()
	enabler.onVehicleSwitched(1, 9)
	same(#focusCalls, 1, "setFocus calls")
	same(focusCalls[1].mode, "vehicle", "mode")
	same(focusCalls[1].data and focusCalls[1].data.vehId, 1, "focus vehicle")
	same(focusCalls[1].data and focusCalls[1].data.auto, false, "automatic switching off")
end)

test("returning to an own car hands traffic focus back to the game", function()
	local enabler = setup()
	enabler.onVehicleSwitched(1, 9)
	enabler.onVehicleSwitched(9, 1)
	same(#focusCalls, 2, "setFocus calls")
	same(focusCalls[2].mode, nil, "back to the game's automatic focus")
	same(focusCalls[2].data, nil, "no focus data")
end)

test("moving the camera between two other players' cars keeps the focus pinned", function()
	local enabler = setup()
	enabler.onVehicleSwitched(1, 9)
	enabler.onVehicleSwitched(9, 10)
	same(#focusCalls, 1, "setFocus calls")
end)

test("switching between own cars leaves traffic focus to the game", function()
	local enabler = setup()
	enabler.onVehicleSwitched(2, 1)
	same(#focusCalls, 0, "setFocus calls")
end)

test("without the traffic system or its setFocus the switch is logged once and goes on", function()
	for _, opts in ipairs({{noTraffic = true}, {noSetFocus = true}}) do
		local enabler = setup(opts)
		enabler.onVehicleSwitched(1, 9)
		enabler.onVehicleSwitched(9, 1)
		same(countLines(logs, "setFocus missing"), 1, "warnings")
		same(countLines(logs, "onVehicleSwitched failed"), 0, "switch errors")
	end
end)
