-- mileageEnabler.lua and mileage/compat.lua on a join:
--
-- #11: when the server's settings arrive before the game's career module, the career start
-- waits for the career protection and starts once it is ready, inside the same 60 seconds
-- the server allows from the settings to a confirmed start.
--
-- #63: each part of the join first logs, once, every game function it calls that is
-- missing: when the settings arrive, just before the career call, and once the career is
-- active.

local SOURCE = "Resources/Client/Mileage/lua/ge/extensions/mileageEnabler.lua"
local COMPAT = "Resources/Client/Mileage/lua/ge/extensions/mileage/compat.lua"

local logs, events, handlers, game

local STARTED = 'careerStartResult {"started":true}'
local FAILED = 'careerStartResult {"started":false}'

-- A fresh game and BeamMP client with the real compat layer and the real enabler. The
-- career protection is ready once game.protectionReady is true; the career finishes
-- loading once game.careerLoads is true.
local function setup(opts)
	opts = opts or {}
	logs, events, handlers = {}, {}, {}
	game = {now = 0, protectionReady = opts.protectionReady ~= false, careerLoads = opts.careerLoads ~= false,
		careerCalls = 0, active = false}

	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	function jsonEncode(t)
		return t.started == true and '{"started":true}' or '{"started":false}'
	end
	function jsonDecode() return {consoleEnabled = true, worldEditorEnabled = true} end
	function AddEventHandler(name, fn) handlers[name] = fn end
	function TriggerServerEvent(name, data) table.insert(events, name .. " " .. tostring(data)) end
	function getCurrentLevelIdentifier() return "west_coast_usa" end
	os.clockhp = function() return game.now end
	settings = {getValue = function() return nil end, setValue = function() end}
	MPConfig = {getNickname = function() return "Player" end}
	MPCoreNetwork = {isMPSession = function() return true end}
	MPVehicleGE = {getVehicles = function() return {} end, isOwn = function() return true end}
	local screens = {}
	core_gamestate = {
		getLoadingStatus = function(tag) return screens[tag] == true end,
		requestEnterLoadingScreen = function(tag) screens[tag] = true end,
		requestExitLoadingScreen = function(tag) screens[tag] = nil end,
	}
	career_career = {
		startingOptions = {},
		isActive = function() return game.active end,
		createOrLoadCareerAndStart = function()
			game.careerCalls = game.careerCalls + 1
			if game.careerLoads then game.active = true else screens.careerActivate = true end
			-- The game's traffic setup holds its own screen until traffic reports ready.
			if game.trafficHangs then screens.careerVehicles = true end
			return true
		end,
	}
	gameplay_traffic = {getTrafficList = function() return {} end}
	core_vehicles = {removeAll = function() end}
	career_saveSystem = {getCurrentProfile = function() return "player", "/saves/player" end,
		jsonWriteFileSafe = function() end}
	career_modules_playerDriving = {onTrafficOrParkingReady = function() end}
	career_modules_inventory = {getVehicles = function() return {} end}
	career_modules_insurance_insurance = {}
	ui_apps = {notifyLayoutsChanged = function() end}
	core_groundMarkers = {getTargetPos = function() end}
	spawn = {safeTeleport = function() end}
	worldReadyState = 0

	extensions = {
		mileage_compat = dofile(COMPAT),
		mileage_careerPatches = {
			ensure = function() return game.protectionReady end,
			withRemoteVehiclesProtected = function(fn) return true, fn() end,
		},
		core_input_actionFilter = {setGroup = function() end, addAction = function() end},
		ui_router = {navigate = function() end},
		mileage_insuranceRestore = {ensureLoaded = function() end},
		hook = function() end,
		hookUpdate = function() end,
		getLoadedExtensionsNames = function() return {} end,
	}
	for _, name in ipairs(opts.missing or {}) do
		local module, field = name:match("^(.+)%.([^.]+)$")
		local target = _G
		for part in module:gmatch("[^.]+") do target = target[part] end
		target[field] = nil
	end

	local enabler = dofile(SOURCE)
	enabler.onExtensionLoaded()
	return enabler
end

-- Runs frames at 60 per second up to the given time.
local function runUntil(enabler, seconds)
	while game.now < seconds do
		game.now = game.now + 1 / 60
		enabler.onUpdate(1 / 60, 1 / 60, 1 / 60)
	end
end

local function count(list, value)
	local n = 0
	for _, v in ipairs(list) do if v == value then n = n + 1 end end
	return n
end

--== #11: the career start waits for the career protection ===================

test("#11: settings before the career module: the career starts once the protection is ready", function()
	local enabler = setup({protectionReady = false})
	handlers.rxCareerSync("{}")
	runUntil(enabler, 5)
	same(game.careerCalls, 0, "career starts while the protection is missing")
	same(count(events, FAILED), 0, "failure reports while waiting")
	game.protectionReady = true
	runUntil(enabler, 10)
	same(game.careerCalls, 1, "career starts")
	same(count(events, STARTED), 1, "success reports")
	same(count(events, FAILED), 0, "failure reports")
	same(countLines(logs, "join: career protection not ready, waiting"), 1, "waiting lines")
end)

test("#11: the protection never ready: one failure report at 60 seconds, none before", function()
	local enabler = setup({protectionReady = false})
	handlers.rxCareerSync("{}")
	runUntil(enabler, 59.9)
	same(#events, 0, "reports before the limit")
	runUntil(enabler, 61)
	same(count(events, FAILED), 1, "failure reports")
	same(game.careerCalls, 0, "career starts")
	same(countLines(logs, "career vehicle protection not available"), 1, "the reason is logged")
	runUntil(enabler, 120)
	same(#events, 1, "reports after the limit")
end)

test("#11: protection ready at 40 s and the career never loads: it fails 60 s after the settings, not 100 s", function()
	local enabler = setup({protectionReady = false, careerLoads = false})
	handlers.rxCareerSync("{}")
	runUntil(enabler, 40)
	game.protectionReady = true
	runUntil(enabler, 59.9)
	same(game.careerCalls, 1, "career starts")
	same(count(events, FAILED), 0, "failure reports before 60 s")
	runUntil(enabler, 61)
	same(count(events, FAILED), 1, "failure reports at 60 s")
	same(countLines(logs, "career start did not finish within 60s"), 1, "the reason is logged")
end)

test("#11: settings sent again while waiting start the career only once", function()
	local enabler = setup({protectionReady = false})
	handlers.rxCareerSync("{}")
	runUntil(enabler, 2)
	handlers.rxCareerSync("{}")
	game.protectionReady = true
	runUntil(enabler, 5)
	handlers.rxCareerSync("{}")
	runUntil(enabler, 8)
	same(game.careerCalls, 1, "career starts")
	same(count(events, STARTED), 1, "success reports")
end)

test("#11: leaving the server while waiting drops the wait", function()
	local enabler = setup({protectionReady = false})
	handlers.rxCareerSync("{}")
	runUntil(enabler, 2)
	enabler.onBeamMPServerLeave()
	game.protectionReady = true
	runUntil(enabler, 70)
	same(game.careerCalls, 0, "career starts after leaving")
	same(#events, 0, "reports after leaving")
end)

test("#11: protection ready when the settings arrive: the career starts at once, as before", function()
	setup()
	handlers.rxCareerSync("{}")
	same(game.careerCalls, 1, "career starts")
	same(count(events, STARTED), 1, "success reports")
	same(countLines(logs, "waiting"), 0, "waiting lines")
end)

--== #63: the join report ====================================================

test("#63: the settings report names every missing function before the join calls any of them", function()
	local enabler = setup({missing = {"extensions.ui_router.navigate", "MPCoreNetwork.isMPSession"}})
	logs = {}
	MPConfig.getNickname = function()
		table.insert(logs, "nickname read")
		return "Player"
	end
	handlers.rxCareerSync("{}")
	local line, nicknameAt
	for i, l in ipairs(logs) do
		if not line and l:find("join compat (settings): missing", 1, true) then line = i end
		if not nicknameAt and l == "nickname read" then nicknameAt = i end
	end
	expect(line, "no settings report line")
	expect(nicknameAt and line < nicknameAt, "the report came after the nickname was read")
	expect(logs[line]:find("ui_router.navigate", 1, true), "ui_router.navigate not named: " .. logs[line])
	expect(logs[line]:find("MPCoreNetwork.isMPSession", 1, true), "isMPSession not named: " .. logs[line])
	same(logs[line]:sub(1, 2), "E ", "log level")
	runUntil(enabler, 3)
	same(countLines(logs, "join compat (settings)"), 1, "settings report lines")
end)

test("#63: the career report runs once the protection is ready and names missing career functions", function()
	local enabler = setup({protectionReady = false, missing = {"career_career.isActive", "core_vehicles.removeAll"}})
	handlers.rxCareerSync("{}")
	runUntil(enabler, 2)
	same(countLines(logs, "join compat (career)"), 0, "career report before the protection is ready")
	game.protectionReady = true
	runUntil(enabler, 4)
	same(countLines(logs, "join compat (career): missing"), 1, "career report lines")
	same(countLines(logs, "career_career.isActive"), 2, "isActive named in the report and at its first call")
	same(countLines(logs, "core_vehicles.removeAll"), 1, "removeAll named")
	same(game.careerCalls, 1, "the join still starts the career")
end)

test("#63: the active report names the career modules the join uses once the career is active", function()
	local enabler = setup({missing = {"career_modules_playerDriving.onTrafficOrParkingReady",
		"career_modules_inventory.getVehicles"}})
	handlers.rxCareerSync("{}")
	runUntil(enabler, 2)
	same(countLines(logs, "join compat (active): missing"), 1, "active report lines")
	same(countLines(logs, "career_modules_playerDriving.onTrafficOrParkingReady"), 1, "playerDriving named")
	same(countLines(logs, "career_modules_inventory.getVehicles"), 1, "inventory named")
	same(count(events, STARTED), 1, "the join still reports success")
end)

test("#63: with every function present each report logs only at debug level", function()
	local enabler = setup()
	handlers.rxCareerSync("{}")
	runUntil(enabler, 2)
	same(countLines(logs, "join compat ("), 3, "report lines")
	for _, l in ipairs(logs) do
		if l:find("join compat (", 1, true) then
			same(l:sub(1, 2), "D ", "level of " .. l)
			expect(l:find("present", 1, true), "not an all-present line: " .. l)
		end
	end
end)

test("#63: a missing career module is not called broken at load time", function()
	setup()
	career_saveSystem = nil
	logs = {}
	extensions.mileage_compat.report()
	same(countLines(logs, "UNRESOLVED"), 0, "unresolved lines")
	same(countLines(logs, "career_saveSystem"), 1, "one line saying it is checked later")
end)

test("#63: a missing game function at load time is still reported", function()
	setup()
	core_gamestate.getLoadingStatus = nil
	logs = {}
	same(extensions.mileage_compat.report(), false, "report result")
	same(countLines(logs, "UNRESOLVED"), 1, "unresolved header")
	same(countLines(logs, "core_gamestate.getLoadingStatus"), 1, "the function is named")
end)

--== edges of the career start wait and the join report ======================

test("#11: no career protection extension at all: the start fails at once, it does not wait", function()
	setup()
	extensions.mileage_careerPatches = nil
	handlers.rxCareerSync("{}")
	same(count(events, FAILED), 1, "failure reports at once")
	same(game.careerCalls, 0, "career starts")
	same(countLines(logs, "waiting"), 0, "waiting lines")
end)

test("#63: a rejoin after leaving the server logs the settings report again", function()
	local enabler = setup()
	handlers.rxCareerSync("{}")
	runUntil(enabler, 2)
	enabler.onBeamMPServerLeave()
	handlers.rxCareerSync("{}")
	same(countLines(logs, "join compat (settings)"), 2, "settings report lines over two joins")
end)

test("#63: a module that is missing, or is not a table, has every function named and nothing raises", function()
	setup()
	MPConfig = nil
	settings = "not a module"
	extensions.ui_router = nil
	logs = {}
	same(extensions.mileage_compat.reportJoin("settings"), false, "report result")
	same(countLines(logs, "join compat (settings): missing"), 1, "report lines")
	for _, name in ipairs({"MPConfig.getNickname", "settings.getValue", "settings.setValue", "ui_router.navigate"}) do
		same(countLines(logs, name), 1, name .. " named")
	end
	same(countLines(logs, "extensions.ui_router"), 0, "the extensions. prefix is left out")
end)

test("#63: a game field that is there but is not a function is reported missing", function()
	setup()
	career_career.isActive = true
	logs = {}
	same(extensions.mileage_compat.reportJoin("career"), false, "report result")
	same(countLines(logs, "career_career.isActive"), 1, "isActive named")
end)

test("#63: a career module checked whole is named when it is absent", function()
	setup()
	career_modules_insurance_insurance = nil
	logs = {}
	same(extensions.mileage_compat.reportJoin("active"), false, "report result")
	same(countLines(logs, "missing career_modules_insurance_insurance"), 1, "module named")
end)

test("#63: an unknown stage reports nothing and returns true", function()
	setup()
	logs = {}
	same(extensions.mileage_compat.reportJoin("nonsense"), true, "report result")
	same(countLines(logs, "join compat"), 0, "report lines")
end)

test("#11: after a 40 s wait the traffic screen still gets its own 30 s from the career start", function()
	local enabler = setup({protectionReady = false})
	game.trafficHangs = true
	handlers.rxCareerSync("{}")
	runUntil(enabler, 40)
	game.protectionReady = true
	runUntil(enabler, 41)
	same(game.careerCalls, 1, "career starts")
	same(countLines(logs, "released loading screen 'careerVehicles'"), 0, "traffic screen released on the first frames")
	same(count(events, STARTED), 0, "success reported before traffic is ready")
	runUntil(enabler, 61)
	same(count(events, FAILED), 1, "the join still ends at 60 s after the settings")
end)

test("#11: protection that becomes ready only after the 60 s limit does not start the career", function()
	local enabler = setup({protectionReady = false})
	handlers.rxCareerSync("{}")
	runUntil(enabler, 30)
	-- A long frame: the next one comes at 61 s, with the protection ready by then.
	game.now = 61
	game.protectionReady = true
	enabler.onUpdate(31, 31, 31)
	same(game.careerCalls, 0, "career starts after the limit")
	same(count(events, FAILED), 1, "failure reports")
	same(count(events, STARTED), 0, "success reports")
end)

--== the join's two clocks: 60 s from the settings, 30 s for traffic from the start ======

test("#11: after a 10 s wait the traffic screen is released 30 s after the career start, not 30 s after the settings", function()
	local enabler = setup({protectionReady = false})
	game.trafficHangs = true
	handlers.rxCareerSync("{}")
	runUntil(enabler, 10)
	game.protectionReady = true
	runUntil(enabler, 39)
	same(game.careerCalls, 1, "career starts")
	same(countLines(logs, "released loading screen 'careerVehicles'"), 0, "traffic screen released 29 s after the start")
	runUntil(enabler, 41)
	same(countLines(logs, "released loading screen 'careerVehicles'"), 1, "traffic screen released 30 s after the start")
	same(count(events, STARTED), 1, "success reports once the traffic screen is released")
	same(count(events, FAILED), 0, "failure reports")
end)

test("#11: protection that becomes ready on the frame at exactly 60 s does not start the career", function()
	local enabler = setup({protectionReady = false})
	handlers.rxCareerSync("{}")
	runUntil(enabler, 30)
	game.now = 60
	game.protectionReady = true
	enabler.onUpdate(30, 30, 30)
	same(game.careerCalls, 0, "career starts at the limit")
	same(count(events, FAILED), 1, "failure reports")
	same(countLines(logs, "career vehicle protection not available"), 1, "the reason is logged")
end)

test("#11: settings at 5 s, protection ready, a career that never loads: it fails at 65 s, none before", function()
	local enabler = setup({careerLoads = false})
	game.now = 5
	handlers.rxCareerSync("{}")
	same(game.careerCalls, 1, "career starts")
	runUntil(enabler, 64.9)
	same(count(events, FAILED), 0, "failure reports before 60 s from the settings")
	runUntil(enabler, 66)
	same(count(events, FAILED), 1, "failure reports at 60 s from the settings")
	same(countLines(logs, "career start did not finish within 60s"), 1, "the reason is logged")
end)
