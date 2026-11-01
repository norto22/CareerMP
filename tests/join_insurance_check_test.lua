-- mileageEnabler.lua: a join whose career start settles runs the insurance check
-- (mileage_insuranceRestore.ensureLoaded) before the server is told the career started,
-- and a failing or missing check never stops the join.

local SOURCE = "Resources/Client/Mileage/lua/ge/extensions/mileageEnabler.lua"
local COMPAT = "Resources/Client/Mileage/lua/ge/extensions/mileage/compat.lua"

local logs, events, handlers, checks

-- A fresh game and BeamMP client, the real compat layer and the real enabler. restore is
-- what stands in for mileage_insuranceRestore (nil: the extension is not loaded).
local function setup(restore)
	logs, events, handlers, checks = {}, {}, {}, 0

	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	function jsonEncode(t)
		return t.started == true and '{"started":true}' or '{"started":false}'
	end
	function jsonDecode() return {consoleEnabled = true, worldEditorEnabled = true} end
	function AddEventHandler(name, fn) handlers[name] = fn end
	function TriggerServerEvent(name, data) table.insert(events, name .. " " .. tostring(data)) end
	function getCurrentLevelIdentifier() return "west_coast_usa" end
	os.clockhp = function() return 0 end
	settings = {getValue = function() return nil end, setValue = function() end}
	MPConfig = {getNickname = function() return "Player" end}
	MPCoreNetwork = {isMPSession = function() return true end}
	core_gamestate = {
		getLoadingStatus = function() return false end,
		requestEnterLoadingScreen = function() end,
		requestExitLoadingScreen = function() end,
	}
	local active = false
	career_career = {
		startingOptions = {},
		isActive = function() return active end,
		createOrLoadCareerAndStart = function() active = true return true end,
	}
	worldReadyState = 0

	extensions = {
		mileage_compat = dofile(COMPAT),
		mileage_careerPatches = {
			ensure = function() return true end,
			withRemoteVehiclesProtected = function(fn) return true, fn() end,
		},
		core_input_actionFilter = {setGroup = function() end, addAction = function() end},
		ui_router = {navigate = function() end},
		mileage_insuranceRestore = restore,
	}

	local enabler = dofile(SOURCE)
	enabler.onExtensionLoaded()
	return enabler
end

local function restoreThat(fn)
	return {ensureLoaded = function()
		checks = checks + 1
		table.insert(events, "insurance check")
		return fn and fn()
	end}
end

local function indexOf(list, value)
	for i, v in ipairs(list) do if v == value then return i end end
	return nil
end

local STARTED = 'careerStartResult {"started":true}'

test("a settled career start runs the insurance check before confirming the start", function()
	setup(restoreThat())
	handlers.rxCareerSync("{}")
	local check, report = indexOf(events, "insurance check"), indexOf(events, STARTED)
	expect(check ~= nil, "insurance check not run")
	expect(report ~= nil, "career start not confirmed")
	expect(check < report, "insurance check ran after the server was told")
end)

test("the check runs once per join, not on every frame", function()
	local enabler = setup(restoreThat())
	handlers.rxCareerSync("{}")
	for _ = 1, 5 do enabler.onUpdate(0.016, 0.016, 0.016) end
	same(checks, 1, "insurance checks")
end)

test("a check that raises is logged under mileage and the join still reports success", function()
	setup(restoreThat(function() error("insuranceRestore.lua:1: boom", 0) end))
	local ok, err = pcall(handlers.rxCareerSync, "{}")
	expect(ok, "join raised: " .. tostring(err))
	expect(indexOf(events, STARTED) ~= nil, "career start not confirmed")
	same(countLines(logs, "E mileage: join: insurance check failed: insuranceRestore.lua:1: boom"), 1, "error logged")
end)

test("a missing insurance extension is logged under mileage and the join still reports success", function()
	setup(nil)
	local ok, err = pcall(handlers.rxCareerSync, "{}")
	expect(ok, "join raised: " .. tostring(err))
	expect(indexOf(events, STARTED) ~= nil, "career start not confirmed")
	same(countLines(logs, "E mileage: join: mileage_insuranceRestore is not loaded"), 1, "error logged")
end)
