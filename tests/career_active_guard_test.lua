-- mileage/careerPatches.lua: during a career start every onCareerActive handler runs,
-- even when one of them raises an error, and the game's hook is put back afterwards.

local SOURCE = "Resources/Client/Mileage/lua/ge/extensions/mileage/careerPatches.lua"

local logs, clock, calls, ext, patches, gameHook

-- The game's extension system as lua/common/extensions.lua runs it: hook calls each
-- loaded extension's handler in load order with no protection, and caches the list it
-- built on the first call until hookUpdate or a load clears it.
local function newExtensions()
	local e, order, cache = {}, {}, {}
	function e.getLoadedExtensionsNames()
		local names = {}
		for i, name in ipairs(order) do names[i] = name end
		table.sort(names)
		return names
	end
	function e.hookUpdate(funcName) cache[funcName] = nil end
	function e.hook(funcName, ...)
		local list = cache[funcName]
		if not list then
			list = {}
			cache[funcName] = list
			for _, name in ipairs(order) do
				local fn = rawget(e, name)[funcName]
				if type(fn) == "function" then
					table.insert(list, fn)
					fn(...)
				end
			end
		else
			for _, fn in ipairs(list) do fn(...) end
		end
	end
	function e.add(name, m)
		rawset(e, name, m)
		table.insert(order, name)
		for k in pairs(cache) do cache[k] = nil end
	end
	return e
end

-- A career module that records its onCareerActive calls; fails = true makes it raise.
local function module(name, fails)
	local m = {}
	m.onCareerActive = function(...)
		table.insert(calls, {name, ...})
		if fails then error(name .. " broke on 0.40") end
	end
	return m
end

local function ran(name)
	local n = 0
	for _, c in ipairs(calls) do if c[1] == name then n = n + 1 end end
	return n
end

local function setup(opts)
	opts = opts or {}
	logs, clock, calls = {}, 0, {}
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	os.clockhp = function() return clock end
	MPVehicleGE, gameplay_traffic, core_vehicles = nil, nil, nil

	ext = newExtensions()
	extensions = ext
	gameHook = ext.hook
	patches = dofile(SOURCE)
	ext.add("mileage_careerPatches", patches)
	ext.add("mileageUIApps", module("mileageUIApps", opts.uiFails))
	return patches
end

-- What career.lua's activateCareer does: the before hook, then the career modules load,
-- then the career-active hook.
local function startCareer(opts)
	opts = opts or {}
	ext.hook("onBeforeCareerActivate")
	ext.add("career_modules_insurance_insurance", module("career_modules_insurance_insurance", opts.insuranceFails))
	ext.add("career_modules_inventory", module("career_modules_inventory"))
	return pcall(ext.hook, "onCareerActive", true, false)
end

--== one failing handler =====================================================

test("a failing handler no longer skips the handlers after it", function()
	setup({uiFails = true})
	local ok, err = startCareer()
	expect(ok, "the career start raised: " .. tostring(err))
	same(ran("mileageUIApps"), 1, "failing handler ran")
	same(ran("career_modules_insurance_insurance"), 1, "insurance ran")
	same(ran("career_modules_inventory"), 1, "inventory ran")
end)

test("the failing handler is named in the log with its traceback", function()
	setup({uiFails = true})
	startCareer()
	same(countLines(logs, "E mileage.careerPatches: career start: mileageUIApps.onCareerActive failed"), 1, "failure line")
	same(countLines(logs, "mileageUIApps broke on 0.40"), 1, "error message")
	same(countLines(logs, "stack traceback"), 1, "traceback")
	same(countLines(logs, "onCareerActive(true) failed in mileageUIApps; every other handler ran"), 1, "summary line")
	local failures = patches.getCareerActiveFailures()
	same(#failures, 1, "failures")
	same(failures[1], "mileageUIApps", "failure name")
end)

test("several failing handlers are all named and the rest still run", function()
	setup({uiFails = true})
	startCareer({insuranceFails = true})
	same(ran("career_modules_inventory"), 1, "inventory ran")
	same(countLines(logs, "failed in mileageUIApps, career_modules_insurance_insurance"), 1, "summary line")
end)

test("handlers get the hook's arguments", function()
	setup()
	startCareer()
	for _, c in ipairs(calls) do
		same(c[2], true, c[1] .. " active")
		same(c[3], false, c[1] .. " newSave")
	end
end)

--== putting things back =====================================================

test("after the career is active the game's hook and handlers are put back", function()
	setup()
	local insurance
	ext.hook("onBeforeCareerActivate")
	expect(ext.hook ~= gameHook, "hook guarded during the career start")
	insurance = module("career_modules_insurance_insurance")
	local original = insurance.onCareerActive
	ext.add("career_modules_insurance_insurance", insurance)
	ext.hook("onCareerActive", true, false)
	expect(ext.hook == gameHook, "the game's hook is back")
	expect(insurance.onCareerActive == original, "the handler is back")
	same(countLines(logs, "every onCareerActive(true) handler ran"), 1, "summary line")
end)

test("a later career start is guarded again", function()
	setup({uiFails = true})
	startCareer()
	-- unguarded outside a career start, so the failing handler raises as the game's would
	expect(not pcall(ext.hook, "onCareerActive", false), "unguarded deactivation raised")
	calls = {}
	local ok = pcall(function()
		ext.hook("onBeforeCareerActivate")
		ext.hook("onCareerActive", true, false)
	end)
	expect(ok, "second career start raised")
	same(ran("career_modules_insurance_insurance"), 1, "insurance ran on the second start")
end)

test("a deactivation inside the window is protected and the guard stays for the activation", function()
	setup({uiFails = true})
	ext.hook("onBeforeCareerActivate")
	ext.add("career_modules_insurance_insurance", module("career_modules_insurance_insurance"))
	local ok = pcall(ext.hook, "onCareerActive", false)
	expect(ok, "deactivation raised")
	same(ran("career_modules_insurance_insurance"), 1, "insurance ran on deactivation")
	expect(ext.hook ~= gameHook, "still guarded")
	ok = pcall(ext.hook, "onCareerActive", true, false)
	expect(ok, "activation raised")
	expect(ext.hook == gameHook, "the game's hook is back")
end)

test("other hooks pass straight through while the guard is on", function()
	setup()
	local got
	ext.add("someMod", {onUpdate = function(dt, extra) got = {dt, extra} end})
	ext.hook("onBeforeCareerActivate")
	ext.hook("onUpdate", 0.1, "x")
	same(got[1], 0.1, "first argument")
	same(got[2], "x", "second argument")
end)

test("a career start that never fires onCareerActive releases the guard after 120 s", function()
	setup()
	ext.hook("onBeforeCareerActivate")
	clock = 119
	patches.onUpdate()
	expect(ext.hook ~= gameHook, "still guarded at 119 s")
	clock = 121
	patches.onUpdate()
	expect(ext.hook == gameHook, "the game's hook is back")
	same(countLines(logs, "W mileage.careerPatches: career start: onCareerActive did not fire within 120s"), 1, "warning")
end)

test("a hook replaced by someone else during the start is left in place", function()
	setup()
	ext.hook("onBeforeCareerActivate")
	local guarded = ext.hook
	local theirs = function(...) return guarded(...) end
	ext.hook = theirs
	ext.hook("onCareerActive", true, false)
	expect(ext.hook == theirs, "their hook kept")
	same(countLines(logs, "extensions.hook was replaced by someone else"), 1, "warning")
end)

test("unloading Mileage puts the game's hook back", function()
	setup()
	ext.hook("onBeforeCareerActivate")
	patches.onExtensionUnloaded()
	expect(ext.hook == gameHook, "the game's hook is back")
end)

--== a game without what the guard needs =====================================

test("a game missing hookUpdate keeps its own hook and the log says so", function()
	setup({uiFails = true})
	ext.hookUpdate = nil
	ext.hook("onBeforeCareerActivate")
	expect(ext.hook == gameHook, "hook unchanged")
	same(countLines(logs, "W mileage.careerPatches: career start: missing extensions.hookUpdate"), 1, "warning")
end)
