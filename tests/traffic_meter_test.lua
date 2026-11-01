-- mileage/traffic.lua: the server's traffic amounts replace the career's own for one
-- career start, and the tutorial restore uses them for the whole server session.

local SOURCE = "Resources/Client/Mileage/lua/ge/extensions/mileage/traffic.lua"
local COMPAT = "Resources/Client/Mileage/lua/ge/extensions/mileage/compat.lua"

local logs, calls, clock, mp, config

-- A fresh game, a fresh meter (its state lives in module locals) and default server
-- traffic of road 6 and parked 8.
local function setup(opts)
	opts = opts or {}
	logs, calls, clock, mp = {}, {}, 0, opts.mp ~= false
	config = opts.config or {roadTrafficEnabled = true, roadTrafficAmount = 6,
		parkedTrafficEnabled = true, parkedTrafficAmount = 8}

	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	os.clockhp = function() return clock end
	MPCoreNetwork = {isMPSession = function() return mp end}
	extensions = {mileage_compat = dofile(COMPAT)}
	mileageEnabler = {getClientConfig = function() return config end}

	local meter
	local traffic, parking = {state = "off", spawned = 0}, {spawned = 0}
	function traffic.setupTrafficHelper(road, options, parked, parkingOptions)
		table.insert(calls, {"helper", road, options, parked, parkingOptions})
		traffic.spawned, parking.spawned = road, parked
		-- the game fires ready inside the helper when there is nothing to spawn
		if (road or 0) == 0 and (parked or 0) == 0 then meter.onTrafficOrParkingReady() end
	end
	function traffic.setActiveAmount(n) table.insert(calls, {"trafficActive", n}) end
	function parking.setActiveAmount(n) table.insert(calls, {"parkingActive", n}) end
	function traffic.getTrafficAmount() return traffic.spawned end
	function parking.getParkingAmount() return parking.spawned end
	function traffic.getState() return traffic.state end
	function traffic.toggle(on) table.insert(calls, {"toggle", on}); traffic.state = on and "on" or "off" end
	gameplay_traffic, gameplay_parking = traffic, parking

	local driving = {}
	function driving.restoreTrafficAfterTutorialPhase() table.insert(calls, {"gameRestore"}) end
	function driving.setTrafficAfterTutorial() table.insert(calls, {"afterTutorial"}) end
	career_modules_playerDriving = driving

	meter = dofile(SOURCE)
	return meter, traffic, parking, driving
end

-- What the game's career does in setupTraffic, with the player's own amounts.
local function careerSetup(road, parked, options)
	gameplay_traffic.setupTrafficHelper(road, options or {simpleVehs = true, autoLoadFromFile = true}, parked, nil)
	gameplay_traffic.setActiveAmount(road)
	gameplay_parking.setActiveAmount(parked)
end

local function find(kind, nth)
	local seen = 0
	for _, c in ipairs(calls) do
		if c[1] == kind then
			seen = seen + 1
			if seen == (nth or 1) then return c end
		end
	end
	return nil
end

--== server amounts ==========================================================

-- A ceiling on the player's setting (the old rule) would pass 2 here.
test("a player asking for fewer cars than the server still gets the server's amount", function()
	local meter = setup()
	meter.onBeforeCareerActivate()
	careerSetup(2, 2)
	local h = find("helper")
	same(h[2], 6, "road passed to the game")
	same(h[4], 8, "parked passed to the game")
end)

test("a player asking for more cars than the server gets the server's amount", function()
	local meter = setup()
	meter.onBeforeCareerActivate()
	careerSetup(40, 40)
	same(find("helper")[2], 6, "road")
	same(find("helper")[4], 8, "parked")
end)

test("the boundaries 0 and 50 pass through without a warning", function()
	local meter = setup()
	local road, parked = meter.serverAmounts({roadTrafficEnabled = true, roadTrafficAmount = 50,
		parkedTrafficEnabled = true, parkedTrafficAmount = 0})
	same(road, 50, "road 50")
	same(parked, 0, "parked 0")
	same(countLines(logs, "out of range"), 0, "warnings")
end)

test("just outside the range is held to 0 or 50 with a warning naming the setting", function()
	local meter = setup()
	local road, parked = meter.serverAmounts({roadTrafficEnabled = true, roadTrafficAmount = 51,
		parkedTrafficEnabled = true, parkedTrafficAmount = -1})
	same(road, 50, "road 51")
	same(parked, 0, "parked -1")
	same(countLines(logs, "W mileage.traffic: roadTrafficAmount = 51 is out of range, using 50"), 1, "road warning")
	same(countLines(logs, "W mileage.traffic: parkedTrafficAmount = -1 is out of range, using 0"), 1, "parked warning")
end)

test("a missing, empty or non-number amount gives 0 and a warning", function()
	local meter = setup()
	for _, raw in ipairs({"abc", ""}) do
		local road = meter.serverAmounts({roadTrafficEnabled = true, roadTrafficAmount = raw})
		same(road, 0, "road for " .. string.format("%q", raw))
	end
	local _, parked = meter.serverAmounts({parkedTrafficEnabled = true})
	same(parked, 0, "parked with no amount")
	expect(countLines(logs, "parkedTrafficAmount = nil is out of range, using 0") == 1, "warning for a missing amount")
end)

test("a fractional amount is cut to a whole number", function()
	local meter = setup()
	local road = meter.serverAmounts({roadTrafficEnabled = true, roadTrafficAmount = 6.7})
	same(road, 6, "road 6.7")
end)

test("a numeric string from the config is accepted", function()
	local meter = setup()
	local road = meter.serverAmounts({roadTrafficEnabled = true, roadTrafficAmount = "12"})
	same(road, 12, "road \"12\"")
	same(countLines(logs, "out of range"), 0, "warnings")
end)

-- Only the boolean true switches a kind on; a truthy check would spawn here.
test("a kind is on only when its switch is exactly true", function()
	local meter = setup()
	for _, switch in ipairs({false, "true", "false", 1}) do
		local road = meter.serverAmounts({roadTrafficEnabled = switch, roadTrafficAmount = 6})
		same(road, 0, "road with switch " .. tostring(switch))
	end
	same(meter.serverAmounts(nil), 0, "no config")
end)

test("a bad value is warned about once per join and again after rejoining", function()
	local meter = setup({config = {roadTrafficEnabled = true, roadTrafficAmount = 80,
		parkedTrafficEnabled = true, parkedTrafficAmount = 8}})
	meter.serverAmounts(config)
	meter.serverAmounts(config)
	same(countLines(logs, "roadTrafficAmount = 80 is out of range"), 1, "warnings in one join")
	meter.onBeamMPServerLeave()
	meter.serverAmounts(config)
	same(countLines(logs, "roadTrafficAmount = 80 is out of range"), 2, "warnings after rejoining")
end)

--== the career start ========================================================

test("a switched-off kind passes 0 and the log says off", function()
	local meter = setup({config = {roadTrafficEnabled = false, roadTrafficAmount = 6,
		parkedTrafficEnabled = true, parkedTrafficAmount = 8}})
	meter.onBeforeCareerActivate()
	careerSetup(20, 20)
	same(find("helper")[2], 0, "road")
	same(find("trafficActive")[2], 0, "active road")
	same(countLines(logs, "I mileage.traffic: applying server traffic - road 0 (off), parked 8 (on)"), 1, "applying line")
end)

test("police are asked for on a copy of the options whenever road traffic is above 0", function()
	local meter = setup({config = {roadTrafficEnabled = true, roadTrafficAmount = 1,
		parkedTrafficEnabled = false, parkedTrafficAmount = 0}})
	meter.onBeforeCareerActivate()
	local options = {simpleVehs = true, autoLoadFromFile = true}
	careerSetup(10, 10, options)
	local passed = find("helper")[3]
	same(passed.police, true, "police")
	same(passed.simpleVehs, true, "the game's own option kept")
	same(passed.extraAmount, nil, "extraAmount")
	same(options.police, nil, "the career's own table")
	expect(passed ~= options, "options are a copy")
end)

test("no police are asked for when road traffic is 0", function()
	local meter = setup({config = {roadTrafficEnabled = true, roadTrafficAmount = 0,
		parkedTrafficEnabled = true, parkedTrafficAmount = 8}})
	meter.onBeforeCareerActivate()
	careerSetup(10, 10)
	same(find("helper")[3].police, nil, "police")
end)

test("missing options from the career still reach the game as a table", function()
	local meter = setup()
	meter.onBeforeCareerActivate()
	gameplay_traffic.setupTrafficHelper(10, nil, 10, nil)
	same(type(find("helper")[3]), "table", "options type")
	same(find("helper")[3].police, true, "police")
end)

-- A replacement left in place would force the server's amounts on free roam and missions.
test("only the first setup and the next active-amount calls are changed", function()
	local meter = setup()
	meter.onBeforeCareerActivate()
	careerSetup(20, 20)
	gameplay_traffic.setupTrafficHelper(3, {}, 4, nil)
	gameplay_traffic.setActiveAmount(3)
	gameplay_parking.setActiveAmount(4)
	same(find("helper", 2)[2], 3, "second setup road")
	same(find("helper", 2)[4], 4, "second setup parked")
	same(find("trafficActive", 2)[2], 3, "second traffic active")
	same(find("parkingActive", 2)[2], 4, "second parking active")
end)

test("arming twice in one start replaces nothing twice", function()
	local meter, traffic = setup()
	local original = traffic.setupTrafficHelper
	meter.onBeforeCareerActivate()
	meter.onBeforeCareerActivate()
	careerSetup(20, 20)
	expect(traffic.setupTrafficHelper == original, "the game's setup is back after one call")
	same(#calls, 3, "game calls")
end)

test("off a server or without a server config nothing is replaced", function()
	local meter, traffic, parking = setup({mp = false})
	local helper, active = traffic.setupTrafficHelper, parking.setActiveAmount
	meter.onBeforeCareerActivate()
	expect(traffic.setupTrafficHelper == helper and parking.setActiveAmount == active, "untouched off a server")
	meter, traffic = setup()
	config = nil
	helper = traffic.setupTrafficHelper
	meter.onBeforeCareerActivate()
	careerSetup(20, 20)
	expect(traffic.setupTrafficHelper == helper, "untouched without a config")
	same(find("helper")[2], 20, "the player's own amount")
end)

test("a game without setupTrafficHelper is reported and nothing is armed", function()
	local meter, traffic = setup()
	traffic.setupTrafficHelper = nil
	meter.onBeforeCareerActivate()
	same(countLines(logs, "setupTrafficHelper missing - server traffic amounts not applied"), 1, "warning")
	meter.onTrafficOrParkingReady()
	same(countLines(logs, "set up traffic without Mileage"), 0, "no ready warning for an unarmed start")
end)

test("an error while working out the amounts still spawns the game's own amounts", function()
	local meter, traffic, parking = setup()
	local helper, tActive, pActive = traffic.setupTrafficHelper, traffic.setActiveAmount, parking.setActiveAmount
	config = setmetatable({}, {__index = function() error("broken config") end})
	meter.onBeforeCareerActivate()
	careerSetup(20, 15)
	local h = find("helper")
	same(h[2], 20, "road")
	same(h[4], 15, "parked")
	same(h[3].police, nil, "options untouched")
	same(find("trafficActive")[2], 20, "active road")
	same(countLines(logs, "E mileage.traffic: server traffic amounts not applied"), 1, "error logged")
	expect(countLines(logs, "stack traceback") == 1, "traceback logged")
	expect(traffic.setupTrafficHelper == helper and traffic.setActiveAmount == tActive
		and parking.setActiveAmount == pActive, "every game function is back")
end)

--== ready, leaving and the safety net =======================================

test("ready logs the counts the game reports", function()
	local meter = setup()
	meter.onBeforeCareerActivate()
	careerSetup(20, 20)
	meter.onTrafficOrParkingReady()
	same(countLines(logs, "I mileage.traffic: traffic ready - 6 road, 8 parked"), 1, "ready line")
	meter.onTrafficOrParkingReady()
	same(countLines(logs, "traffic ready"), 1, "a later ready is not logged again")
end)

test("ready fired inside the setup with nothing to spawn still sets the active amounts to 0", function()
	local meter, traffic, parking = setup({config = {roadTrafficEnabled = false, parkedTrafficEnabled = false}})
	local tActive, pActive = traffic.setActiveAmount, parking.setActiveAmount
	meter.onBeforeCareerActivate()
	careerSetup(20, 20)
	same(countLines(logs, "traffic ready - 0 road, 0 parked"), 1, "ready line")
	same(find("trafficActive")[2], 0, "active road")
	same(find("parkingActive")[2], 0, "active parked")
	expect(traffic.setActiveAmount == tActive and parking.setActiveAmount == pActive, "both back after their call")
end)

test("a count the game cannot give is logged as ?", function()
	local meter, _, parking = setup()
	parking.getParkingAmount = nil
	meter.onBeforeCareerActivate()
	careerSetup(20, 20)
	meter.onTrafficOrParkingReady()
	same(countLines(logs, "traffic ready - 6 road, ? parked"), 1, "ready line")
end)

test("ready before the setup went through the meter warns and restores", function()
	local meter, traffic = setup()
	local helper = traffic.setupTrafficHelper
	meter.onBeforeCareerActivate()
	meter.onTrafficOrParkingReady()
	same(countLines(logs, "W mileage.traffic: the career set up traffic without Mileage - server traffic amounts not applied"), 1, "warning")
	expect(traffic.setupTrafficHelper == helper, "setup restored")
end)

test("the safety net restores after 60 seconds, not before", function()
	local meter, traffic = setup()
	local helper = traffic.setupTrafficHelper
	meter.onBeforeCareerActivate()
	meter.onUpdate()
	clock = 60
	meter.onUpdate()
	expect(traffic.setupTrafficHelper ~= helper, "still armed at 60 s")
	clock = 60.5
	meter.onUpdate()
	expect(traffic.setupTrafficHelper == helper, "restored after 60 s")
	same(countLines(logs, "set up traffic without Mileage"), 1, "warning")
	meter.onBeforeCareerActivate()
	expect(traffic.setupTrafficHelper ~= helper, "a later career start arms again")
end)

test("traffic that is not ready after 60 seconds is reported with the amounts asked for", function()
	local meter, traffic = setup()
	meter.onBeforeCareerActivate()
	gameplay_traffic.setupTrafficHelper(20, {}, 20, nil)
	gameplay_traffic.setActiveAmount(20)
	gameplay_parking.setActiveAmount(20)
	meter.onUpdate()
	clock = 60.5
	meter.onUpdate()
	same(countLines(logs, "W mileage.traffic: traffic not ready 60s after the career start - asked for road 6, parked 8"), 1, "warning")
	same(countLines(logs, "set up traffic without Mileage"), 0, "not the missed-meter warning")
	meter.onTrafficOrParkingReady()
	same(countLines(logs, "traffic ready -"), 0, "a late ready is not logged as this start's")
end)

-- A safety net that kept the start after warning would repeat the line every frame; a
-- ready that did not clear the start would warn after a normal join.
test("the not-ready warning is logged once, and never after a ready in time", function()
	local meter = setup()
	meter.onBeforeCareerActivate()
	careerSetup(20, 20)
	meter.onUpdate()
	clock = 61
	meter.onUpdate()
	clock = 200
	meter.onUpdate()
	same(countLines(logs, "traffic not ready"), 1, "one warning after many frames")
	meter = setup()
	meter.onBeforeCareerActivate()
	careerSetup(20, 20)
	meter.onUpdate()
	meter.onTrafficOrParkingReady()
	clock = 120
	meter.onUpdate()
	same(countLines(logs, "traffic ready - 6 road, 8 parked"), 1, "ready line")
	same(countLines(logs, "traffic not ready"), 0, "no warning after a ready in time")
end)

test("leaving the server and unloading put the game's functions back", function()
	local meter, traffic, parking = setup()
	local helper, pActive = traffic.setupTrafficHelper, parking.setActiveAmount
	meter.onBeforeCareerActivate()
	meter.onBeamMPServerLeave()
	expect(traffic.setupTrafficHelper == helper, "leave restores the setup")
	meter.onBeforeCareerActivate()
	gameplay_traffic.setupTrafficHelper(20, {}, 20, nil)
	meter.onExtensionUnloaded()
	expect(parking.setActiveAmount == pActive, "unload restores a pending active amount")
end)

--== tutorial restore ========================================================

test("the tutorial restore leaves road traffic off when the server has it off", function()
	local meter, _, _, driving = setup({config = {roadTrafficEnabled = false, parkedTrafficEnabled = true,
		parkedTrafficAmount = 8}})
	meter.onCareerActive(true)
	driving.restoreTrafficAfterTutorialPhase()
	same(find("toggle"), nil, "toggle")
	same(find("gameRestore"), nil, "the game's restore")
	same(find("trafficActive")[2], 0, "active road")
	same(find("parkingActive")[2], 8, "active parked")
	expect(find("afterTutorial") ~= nil, "setTrafficAfterTutorial called")
end)

test("the tutorial restore switches traffic on only when it is off and road is above 0", function()
	local meter, traffic, _, driving = setup()
	meter.onCareerActive(true)
	driving.restoreTrafficAfterTutorialPhase()
	same(find("toggle")[2], true, "toggled on")
	same(find("trafficActive")[2], 6, "active road")
	calls = {}
	traffic.state = "on"
	driving.restoreTrafficAfterTutorialPhase()
	same(find("toggle"), nil, "no toggle when already on")
end)

test("the tutorial restore is not installed off a server or when the career stops", function()
	local meter, _, _, driving = setup({mp = false})
	local original = driving.restoreTrafficAfterTutorialPhase
	meter.onCareerActive(true)
	expect(driving.restoreTrafficAfterTutorialPhase == original, "off a server")
	meter, _, _, driving = setup()
	original = driving.restoreTrafficAfterTutorialPhase
	meter.onCareerActive(false)
	expect(driving.restoreTrafficAfterTutorialPhase == original, "career stopping")
end)

test("an error in the tutorial restore is logged, not raised", function()
	local meter, traffic, _, driving = setup()
	traffic.getState = function() error("no state") end
	meter.onCareerActive(true)
	local ok = pcall(driving.restoreTrafficAfterTutorialPhase)
	expect(ok, "did not raise")
	same(countLines(logs, "E mileage.traffic: tutorial traffic restore failed"), 1, "error logged")
end)

test("a career module without the restore is reported once and left alone", function()
	local meter, _, _, driving = setup()
	driving.setTrafficAfterTutorial = nil
	local original = driving.restoreTrafficAfterTutorialPhase
	meter.onCareerActive(true)
	meter.onCareerActive(true)
	expect(driving.restoreTrafficAfterTutorialPhase == original, "untouched")
	same(countLines(logs, "E mileage.compat: career_modules_playerDriving.setTrafficAfterTutorial missing - " ..
		"the tutorial traffic restore keeps the player's own amounts"), 1, "one warning, through compat")
end)

-- Reading the module's functions before checking the module exists would raise inside
-- the career start; logging under mileage.traffic would hide it from the compat filter.
test("a game without the career traffic module is reported through compat, not raised", function()
	local meter = setup()
	career_modules_playerDriving = nil
	local ok, err = pcall(meter.onCareerActive, true)
	expect(ok, "did not raise: " .. tostring(err))
	same(countLines(logs, "E mileage.compat: career_modules_playerDriving.restoreTrafficAfterTutorialPhase missing - " ..
		"the tutorial traffic restore keeps the player's own amounts"), 1, "reported through compat")
	same(countLines(logs, "mileage.traffic: career_modules_playerDriving"), 0, "not under the meter's own tag")
	meter.onBeamMPServerLeave()
end)

test("the restore follows a reloaded career module and leaving puts the game's back", function()
	local meter, _, _, driving = setup()
	meter.onCareerActive(true)
	local reloaded = {}
	function reloaded.restoreTrafficAfterTutorialPhase() table.insert(calls, {"gameRestore"}) end
	function reloaded.setTrafficAfterTutorial() table.insert(calls, {"afterTutorial"}) end
	local original = reloaded.restoreTrafficAfterTutorialPhase
	career_modules_playerDriving = reloaded
	meter.onCareerActive(true)
	expect(reloaded.restoreTrafficAfterTutorialPhase ~= original, "installed on the reloaded module")
	meter.onBeamMPServerLeave()
	expect(reloaded.restoreTrafficAfterTutorialPhase == original, "leaving restores the game's restore")
end)

--== the server's traffic share ==============================================

local function withShare(road, parked)
	return {roadTrafficEnabled = true, roadTrafficAmount = 6, parkedTrafficEnabled = true, parkedTrafficAmount = 8,
		trafficShare = {road = road, parked = parked}}
end

test("a career start spawns the server's share of its traffic total", function()
	local meter = setup({config = withShare(2, 3)})
	meter.onBeforeCareerActivate()
	careerSetup(6, 8)
	same(find("helper")[2], 2, "road passed to the game")
	same(find("helper")[4], 3, "parked passed to the game")
	same(find("trafficActive")[2], 2, "active road")
	same(find("parkingActive")[2], 3, "active parked")
end)

test("without a share the per-player amounts are used", function()
	local meter = setup()
	same(select(1, meter.serverAmounts(config)), 6, "road")
	same(select(2, meter.serverAmounts(config)), 8, "parked")
end)

test("a share is held to 0 to 50 and to the server's switches", function()
	local meter = setup()
	local road, parked = meter.serverAmounts(withShare(70, -2))
	same(road, 50, "road share of 70")
	same(parked, 0, "parked share of -2")
	local off = withShare(4, 4)
	off.parkedTrafficEnabled = false
	same(select(2, meter.serverAmounts(off)), 0, "parked share with parked traffic off")
	same(select(1, meter.serverAmounts({roadTrafficEnabled = true, roadTrafficAmount = 6, trafficShare = "x"})), 6,
		"a share that is not a table")
end)

test("a new share during an active career sets the active driving and parked amounts", function()
	local meter = setup({config = withShare(6, 8)})
	meter.onBeforeCareerActivate()
	careerSetup(6, 8)
	meter.onTrafficOrParkingReady()
	meter.onCareerActive(true)
	calls = {}
	config.trafficShare = {road = 4, parked = 5}
	meter.onTrafficShare()
	same(find("trafficActive")[2], 4, "active road")
	same(find("parkingActive")[2], 5, "active parked")
	same(#calls, 2, "calls to the game")
end)

test("a share that arrives before the career is active is used at the career start, not applied at once", function()
	local meter = setup({config = withShare(6, 8)})
	config.trafficShare = {road = 3, parked = 4}
	meter.onTrafficShare()
	same(#calls, 0, "calls to the game before the career start")
	meter.onBeforeCareerActivate()
	careerSetup(6, 8)
	same(find("helper")[2], 3, "road passed to the game")
	same(find("helper")[4], 4, "parked passed to the game")
end)

test("a share that arrives while the career start sets up traffic is applied once traffic is ready", function()
	local meter = setup({config = withShare(6, 8)})
	meter.onBeforeCareerActivate()
	meter.onCareerActive(true)
	gameplay_traffic.setupTrafficHelper(6, {}, 8, nil)
	config.trafficShare = {road = 2, parked = 2}
	meter.onTrafficShare()
	gameplay_traffic.setActiveAmount(6)
	gameplay_parking.setActiveAmount(8)
	same(find("trafficActive")[2], 6, "the career start's own active road")
	meter.onTrafficOrParkingReady()
	same(find("trafficActive", 2)[2], 2, "active road once traffic is ready")
	same(find("parkingActive", 2)[2], 2, "active parked once traffic is ready")
end)

test("a game without setActiveAmount reports it once and nothing else changes", function()
	local meter = setup({config = withShare(6, 8)})
	meter.onCareerActive(true)
	gameplay_traffic.setActiveAmount = nil
	config.trafficShare = {road = 4, parked = 5}
	local ok, err = pcall(meter.onTrafficShare)
	expect(ok, "did not raise: " .. tostring(err))
	meter.onTrafficShare()
	same(countLines(logs, "E mileage.compat: gameplay_traffic.setActiveAmount missing"), 1, "reported once")
	same(find("parkingActive")[2], 5, "the parked amount still set")
end)

test("off a server a share does nothing", function()
	local meter = setup({mp = false, config = withShare(6, 8)})
	meter.onCareerActive(true)
	meter.onTrafficShare()
	same(#calls, 0, "calls to the game")
end)

--== the enabler keeps the share =============================================

local ENABLER = "Resources/Client/Mileage/lua/ge/extensions/mileageEnabler.lua"

-- The real enabler with the settings handlers it registers.
local function enablerWithHandlers()
	local handlers = {}
	function AddEventHandler(name, fn) handlers[name] = fn end
	local function luaText(v)
		if type(v) == "table" then
			local parts = {}
			for k, val in pairs(v) do table.insert(parts, "[" .. luaText(k) .. "]=" .. luaText(val)) end
			return "{" .. table.concat(parts, ",") .. "}"
		elseif type(v) == "string" then
			return string.format("%q", v)
		end
		return tostring(v)
	end
	jsonEncode = luaText
	jsonDecode = function(text) return (loadstring or load)("return " .. text)() end
	settings = {getValue = function() return nil end, setValue = function() end}
	extensions = {
		mileage_compat = {report = function() end, targetGameVersion = "test", isMPSession = function() return true end},
		core_input_actionFilter = {setGroup = function() end, addAction = function() end},
	}
	MPConfig = {getNickname = function() return "player" end}
	local enabler = dofile(ENABLER)
	enabler.onExtensionLoaded()
	return enabler, handlers, luaText
end

test("the enabler keeps the share with the settings, through a settings update, and hands a new share on", function()
	local enabler, handlers, luaText = enablerWithHandlers()
	local applied = 0
	extensions.mileage_traffic = {onTrafficShare = function() applied = applied + 1 end}
	handlers.rxClientConfigUpdate(luaText({consoleEnabled = true, trafficShare = {road = 3, parked = 4}}))
	same(enabler.getClientConfig().trafficShare.road, 3, "share kept with the settings")
	handlers.rxClientConfigUpdate(luaText({consoleEnabled = true}))
	same(enabler.getClientConfig().trafficShare.road, 3, "share kept through an update without one")
	local before = enabler.getClientConfig()
	handlers.rxCareerTrafficShare(luaText({road = 1, parked = 2}))
	same(enabler.getClientConfig().trafficShare.parked, 2, "the new share")
	expect(enabler.getClientConfig() == before, "the settings table the career start holds sees the new share")
	same(applied, 1, "share handed to the traffic meter")
	handlers.rxCareerTrafficShare("{broken")
	handlers.rxCareerTrafficShare(luaText({road = "x"}))
	same(enabler.getClientConfig().trafficShare.parked, 2, "a bad share changes nothing")
end)
