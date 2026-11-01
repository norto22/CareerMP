-- Traffic and drag races on a server: the game runs every extension's per-frame update in
-- one loop with no error protection (hookFast in the game's lua/common/extensions.lua), and
-- its drag modules come before traffic, parking and police in that loop. A drag update that
-- raises an error ends the frame's update for everything after it, so traffic stops where it
-- is while the rest of the game keeps running.
--
-- The stand-in game below keeps the loop's two properties that matter: each hook's list of
-- functions is built once and cached until extensions.hookUpdate or extensions.load clears
-- it, and the list runs with no pcall. The real mileage/dragSync.lua runs on top.

local DRAG_SYNC = "Resources/Client/Mileage/lua/ge/extensions/mileage/dragSync.lua"

local FRAMES = 60

local game, logs

-- The load order of the game's career: drag modules first, then traffic and the rest.
local LOAD_ORDER = {
	"gameplay_drag_core",
	"gameplay_drag_display",
	"gameplay_drag_times",
	"multiplayer_gamemodes_drag_drag",
	"gameplay_traffic",
	"gameplay_parking",
	"gameplay_police",
	"mileage_dragSync",
}

local function extName(path)
	return (path:gsub("^/", ""):gsub("^lua/ge/extensions/", ""):gsub("/", "_"))
end

-- Module tables the stand-in loader hands out, by extension name.
local function newModules()
	local m = {}

	m.gameplay_drag_core = {
		getDragGamemode = function() return nil end,
		getData = function() return {racers = {}} end,
		onUpdate = function() game.counts.core = game.counts.core + 1 end,
	}
	m.gameplay_drag_display = {}
	m.gameplay_drag_times = {
		onUpdate = function()
			if game.timesFails then error("gameplay_drag_times: attempt to index a nil value") end
			game.counts.times = game.counts.times + 1
			return "times ran"
		end,
	}
	m.multiplayer_gamemodes_drag_drag = {
		setEnabled = function(state) game.dragEnabled = state end,
	}
	m.gameplay_traffic = {onUpdate = function() game.counts.traffic = game.counts.traffic + 1 end}
	m.gameplay_parking = {onUpdate = function() game.counts.parking = game.counts.parking + 1 end}
	m.gameplay_police = {onUpdate = function() game.counts.police = game.counts.police + 1 end}
	-- Loaded only when a race starts, and failing from its first frame.
	m.gameplay_drag_late = {
		onUpdate = function() error("gameplay_drag_late: attempt to call a nil value") end,
	}
	return m
end

-- What the drag core rebuild reads from the game's own core.lua: the stub it restores, and
-- a per-frame update that counts its runs and fails when told to.
local CORE_PATH = "/lua/ge/extensions/gameplay/drag/core.lua"
local CORE_SOURCE = [[
local M = {}

local function getDragGamemode()
  -- Restore the two lines below once multiplayer drag is ready to ship.
  return nil
end

M.getDragGamemode = getDragGamemode
M.getData = function() return {racers = {}} end
M.onUpdate = function()
  if dragTestCounts.rebuiltFails then error("rebuilt core: attempt to compare nil with number") end
  dragTestCounts.rebuilt = dragTestCounts.rebuilt + 1
end

return M
]]

local function newGame(opts)
	opts = opts or {}
	game = {
		order = {},
		modules = newModules(),
		cache = {},
		counts = {core = 0, times = 0, traffic = 0, parking = 0, police = 0, rebuilt = 0},
		frameErrors = {},
		timesFails = opts.timesFails ~= false,
		syncEnabled = opts.syncEnabled == true,
		files = opts.files or {},
		hookUpdates = 0,
	}
	logs = {}
	dragTestCounts = game.counts

	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. tostring(msg)) end
	function setExtensionUnloadMode() end
	function readFile(path) return game.files[path] end
	loadstring = loadstring or load
	os.clockhp = function() return 0 end

	mileageEnabler = {
		getClientConfig = function() return {nativeDragSyncEnabled = game.syncEnabled} end,
	}
	mileage_dragTransport = {ensureHandlersLoaded = function() return true end}

	extensions = {}

	local function addLoaded(name)
		local module = game.modules[name]
		if not module then return false end
		rawset(_G, name, module)
		for _, n in ipairs(game.order) do
			if n == name then return true end
		end
		-- A drag module loaded later still runs before traffic, as in the game's career.
		local at = #game.order + 1
		if name:find("^gameplay_drag_") then
			for i, n in ipairs(game.order) do
				if n == "gameplay_traffic" then at = i break end
			end
		end
		table.insert(game.order, at, name)
		return true
	end

	-- extensions.load: loads each named extension and drops every cached hook list.
	function extensions.load(...)
		for _, path in ipairs({...}) do
			local name = extName(path)
			if game.loadFails then error("cannot load " .. name) end
			addLoaded(name)
		end
		game.cache = {}
		return true
	end

	function extensions.hookUpdate(funcName)
		game.hookUpdates = game.hookUpdates + 1
		game.cache[funcName] = nil
	end

	function extensions.getLoadedExtensionsNames()
		local names = {}
		for i, n in ipairs(game.order) do names[i] = n end
		return names
	end

	-- hookFast: the list of functions is built once and cached; it runs with no protection.
	function extensions.hook(funcName, ...)
		local list = game.cache[funcName]
		if not list then
			list = {}
			for _, name in ipairs(game.order) do
				local m = rawget(_G, name)
				if type(m) == "table" and type(m[funcName]) == "function" then
					table.insert(list, m[funcName])
				end
			end
			game.cache[funcName] = list
		end
		for i = 1, #list do list[i](...) end
	end

	for _, name in ipairs(LOAD_ORDER) do
		if name ~= "mileage_dragSync" then addLoaded(name) end
	end

	-- The real dragSync, loaded as the game loads an extension.
	local sync = dofile(DRAG_SYNC)
	game.modules.mileage_dragSync = sync
	addLoaded("mileage_dragSync")
	if sync.onInit then sync.onInit() end
	if sync.onExtensionLoaded then sync.onExtensionLoaded() end
	game.sync = sync
	return game
end

-- The game's main loop: one onUpdate hook per frame; an error ends that frame and is
-- reported, and the next frame runs.
local function runFrames(n)
	for _ = 1, n do
		local ok, err = pcall(extensions.hook, "onUpdate", 0.016)
		if not ok then table.insert(game.frameErrors, tostring(err)) end
	end
end

local function clearGlobals()
	for _, name in ipairs(LOAD_ORDER) do rawset(_G, name, nil) end
	rawset(_G, "gameplay_drag_late", nil)
	rawset(_G, "mileage_dragGamemodeProvider", nil)
end

--== the freeze ==============================================================

test("a drag module failing every frame leaves traffic driving, synced drag off", function()
	clearGlobals()
	newGame({syncEnabled = false})
	game.sync.onCareerActive(true)
	runFrames(FRAMES)
	same(game.counts.traffic, FRAMES, "traffic updates in " .. FRAMES .. " frames (frame error: " ..
		tostring(game.frameErrors[1]) .. ")")
	same(game.counts.parking, FRAMES, "parking updates")
	same(game.counts.police, FRAMES, "police updates")
	same(#game.frameErrors, 0, "frames ended early")
end)

test("the failing drag function is logged once, by module and function, with a traceback", function()
	clearGlobals()
	newGame({syncEnabled = false})
	game.sync.onCareerActive(true)
	runFrames(FRAMES)
	same(countLines(logs, "gameplay_drag_times.onUpdate"), 1, "log lines naming the failing function")
	local line
	for _, l in ipairs(logs) do
		if l:find("gameplay_drag_times.onUpdate", 1, true) then line = l end
	end
	expect(line:sub(1, 2) == "E ", "logged as an error: " .. line)
	expect(line:find("attempt to index a nil value", 1, true), "carries the error: " .. line)
	expect(line:find("stack traceback", 1, true), "carries a traceback: " .. line)
end)

test("a drag update that succeeds runs every frame and returns what it returned", function()
	clearGlobals()
	newGame({syncEnabled = false, timesFails = false})
	game.sync.onCareerActive(true)
	runFrames(FRAMES)
	same(game.counts.times, FRAMES, "drag times updates")
	same(game.counts.core, FRAMES, "drag core updates")
	same(game.counts.traffic, FRAMES, "traffic updates")
	same(gameplay_drag_times.onUpdate(), "times ran", "guarded update's result")
	same(countLines(logs, "failed"), 0, "failure lines logged")
end)

test("a second career start wraps nothing twice, and leaving the server puts the originals back", function()
	clearGlobals()
	newGame({syncEnabled = false})
	local timesOriginal = gameplay_drag_times.onUpdate
	local coreOriginal = gameplay_drag_core.onUpdate
	game.sync.onCareerActive(true)
	expect(gameplay_drag_times.onUpdate ~= timesOriginal, "drag times guarded")
	game.sync.onCareerActive(true)
	runFrames(FRAMES)
	same(game.counts.traffic, FRAMES, "traffic updates after two starts")
	same(countLines(logs, "gameplay_drag_times.onUpdate"), 1, "log lines after two starts")

	game.sync.onBeamMPServerLeave()
	same(gameplay_drag_times.onUpdate, timesOriginal, "drag times after leaving")
	same(gameplay_drag_core.onUpdate, coreOriginal, "drag core after leaving")
	same(game.cache.onUpdate, nil, "cached onUpdate list after leaving")
	same(gameplay_traffic.onUpdate ~= nil, true, "traffic left in place")
end)

test("the career ending and the extension unloading put the originals back", function()
	clearGlobals()
	newGame({syncEnabled = false})
	local timesOriginal = gameplay_drag_times.onUpdate
	game.sync.onCareerActive(true)
	runFrames(1)
	game.sync.onCareerActive(false)
	same(gameplay_drag_times.onUpdate, timesOriginal, "drag times after the career ends")
	same(game.cache.onUpdate, nil, "cached onUpdate list after the career ends")

	game.sync.onCareerActive(true)
	expect(gameplay_drag_times.onUpdate ~= timesOriginal, "guarded again on the next start")
	game.sync.onExtensionUnloaded()
	same(gameplay_drag_times.onUpdate, timesOriginal, "drag times after unloading")
end)

test("a function another mod put in place after the guard is left alone", function()
	clearGlobals()
	newGame({syncEnabled = false})
	game.sync.onCareerActive(true)
	local theirs = function() end
	gameplay_drag_times.onUpdate = theirs
	game.sync.onBeamMPServerLeave()
	same(gameplay_drag_times.onUpdate, theirs, "the other mod's function")
end)

--== drag modules loaded mid-race, and the rebuilt drag core =================

test("a failing drag module loaded mid-race is guarded before its first frame", function()
	clearGlobals()
	newGame({syncEnabled = false, timesFails = false})
	game.sync.onCareerActive(true)
	runFrames(10)
	extensions.load("gameplay/drag/late")
	runFrames(FRAMES)
	same(game.counts.traffic, 10 + FRAMES, "traffic updates (frame error: " .. tostring(game.frameErrors[1]) .. ")")
	same(#game.frameErrors, 0, "frames ended early")
	same(countLines(logs, "gameplay_drag_late.onUpdate"), 1, "log lines naming the late module")
end)

test("the module loader is wrapped once across career starts and put back on leaving", function()
	clearGlobals()
	newGame({syncEnabled = false})
	local load = extensions.load
	game.sync.onCareerActive(true)
	local guardedLoad = extensions.load
	expect(guardedLoad ~= load, "loader wrapped")
	game.sync.onCareerActive(true)
	same(extensions.load, guardedLoad, "loader after a second start")
	game.sync.onBeamMPServerLeave()
	same(extensions.load, load, "loader after leaving")

	-- After leaving, a late drag module is the game's own again: nothing guards it.
	extensions.load("gameplay/drag/late")
	runFrames(1)
	same(#game.frameErrors, 1, "frame errors once the guard is off")
end)

test("a loader another mod wrapped after the guard is left alone, and not wrapped again", function()
	clearGlobals()
	newGame({syncEnabled = false, timesFails = false})
	game.sync.onCareerActive(true)
	local ours = extensions.load
	local theirs = function(...) return ours(...) end
	extensions.load = theirs
	game.sync.onBeamMPServerLeave()
	same(extensions.load, theirs, "the other mod's loader after leaving")
	game.sync.onCareerActive(true)
	same(extensions.load, theirs, "the other mod's loader after the next start")
	extensions.load("gameplay/drag/late")
	runFrames(FRAMES)
	same(game.counts.traffic, FRAMES, "traffic updates with the late module under the other loader")
end)

test("a failing load still raises its own error to the caller", function()
	clearGlobals()
	newGame({syncEnabled = false})
	game.sync.onCareerActive(true)
	game.loadFails = true
	local ok, err = pcall(extensions.load, "gameplay/drag/late")
	same(ok, false, "the failing load's result")
	expect(tostring(err):find("cannot load gameplay_drag_late", 1, true), "its error: " .. tostring(err))
end)

test("with synced drag on, the frame loop runs the rebuilt drag core, guarded", function()
	clearGlobals()
	newGame({syncEnabled = true, timesFails = false, files = {[CORE_PATH] = CORE_SOURCE}})
	game.sync.onCareerActive(true)
	expect(game.sync.isPatched(), "drag core rebuilt")
	game.counts.rebuiltFails = true
	runFrames(FRAMES)
	same(game.counts.traffic, FRAMES, "traffic updates (frame error: " .. tostring(game.frameErrors[1]) .. ")")
	same(countLines(logs, "gameplay_drag_core.onUpdate"), 1, "log lines naming the rebuilt core")
	expect(countLines(logs, "rebuilt core: attempt to compare") == 1, "the rebuilt core's own error is the one logged")
end)

test("turning synced drag on mid-session replaces the cached drag core with the rebuilt one", function()
	clearGlobals()
	newGame({syncEnabled = false, timesFails = false, files = {[CORE_PATH] = CORE_SOURCE}})
	game.sync.onCareerActive(true)
	runFrames(1) -- the game has cached the stock drag core's update
	same(game.counts.core, 1, "stock drag core updates before the rebuild")
	expect(game.sync.setActive(true), "synced drag switched on")
	runFrames(FRAMES)
	same(game.counts.rebuilt, FRAMES, "rebuilt drag core updates")
	same(game.counts.core, 1, "stock drag core updates after the rebuild")
	game.counts.rebuiltFails = true
	runFrames(FRAMES)
	same(game.counts.traffic, 1 + 2 * FRAMES, "traffic updates (frame error: " .. tostring(game.frameErrors[1]) .. ")")
end)

--== Mileage's own per-frame drag functions ==================================

local DRAG_MODE = "Resources/Client/Mileage/lua/ge/extensions/multiplayer/gamemodes/drag/drag.lua"

-- The real drag mode, enabled, as the strip's authority, with a drag core that fails.
local function failingDragMode()
	clearGlobals()
	newGame({syncEnabled = false, timesFails = false})
	mileage_dragTransport = {
		isHost = function() return true end,
		bridge = {getLocalPlayerId = function() return 1 end},
	}
	local drag = dofile(DRAG_MODE)
	drag.setEnabled(true)
	game.getDataCalls = 0
	gameplay_drag_core = {
		getData = function()
			game.getDataCalls = game.getDataCalls + 1
			error("getData: attempt to index a nil value")
		end,
	}
	return drag
end

test("the drag mode's countdown repair returns 0 while its work fails, logged once", function()
	local drag = failingDragMode()
	for _ = 1, FRAMES do
		local ok, result = pcall(drag.checkTimerDrift)
		expect(ok, "checkTimerDrift raised: " .. tostring(result))
		same(result, 0, "checkTimerDrift's result")
	end
	same(countLines(logs, "checkTimerDrift"), 1, "log lines naming checkTimerDrift")
	expect(countLines(logs, "getData: attempt to index a nil value") == 1, "the error is in the log line")
end)

test("the drag mode's result finaliser returns quietly while its work fails, logged once", function()
	local drag = failingDragMode()
	-- A car stopping arms the finaliser; that call fails the same way, outside a frame.
	pcall(drag.onDragMpTimeslipRequested)
	for _ = 1, FRAMES do
		local ok, err = pcall(drag.onUpdate)
		expect(ok, "onUpdate raised: " .. tostring(err))
	end
	same(game.getDataCalls, 1 + FRAMES, "finaliser attempts")
	same(countLines(logs, "multiplayer_gamemodes_drag_drag.onUpdate"), 1, "log lines naming the finaliser")
end)

test("a disabled drag mode returns 0 from its countdown repair without touching the drag core", function()
	local drag = failingDragMode()
	drag.setEnabled(false)
	same(drag.checkTimerDrift(), 0, "checkTimerDrift's result")
	drag.onUpdate()
	same(game.getDataCalls, 0, "drag core calls")
	same(countLines(logs, "failed"), 0, "failure lines logged")
end)

--== the guard's edges =======================================================

-- One frame of any per-frame hook, as the game's loop runs it.
local function runHook(funcName, n)
	for _ = 1, n do
		local ok, err = pcall(extensions.hook, funcName, 0.016)
		if not ok then table.insert(game.frameErrors, tostring(err)) end
	end
end

test("every per-frame hook of a drag module is guarded, not only onUpdate", function()
	clearGlobals()
	newGame({syncEnabled = false, timesFails = false})
	local counts = {onPreRender = 0, onGuiUpdate = 0, onDrawDebug = 0}
	for hook in pairs(counts) do
		gameplay_drag_display[hook] = function() error("gameplay_drag_display: " .. hook .. " failed") end
		gameplay_traffic[hook] = function() counts[hook] = counts[hook] + 1 end
	end
	game.sync.onCareerActive(true)
	for hook in pairs(counts) do
		runHook(hook, FRAMES)
		same(counts[hook], FRAMES, "traffic " .. hook .. " runs (frame error: " .. tostring(game.frameErrors[1]) .. ")")
		same(countLines(logs, "gameplay_drag_display." .. hook), 1, "log lines naming gameplay_drag_display." .. hook)
	end
	same(#game.frameErrors, 0, "frames ended early")
end)

test("Mileage's own drag mode is guarded as a drag module", function()
	clearGlobals()
	newGame({syncEnabled = false, timesFails = false})
	multiplayer_gamemodes_drag_drag.onUpdate = function() error("drag mode: attempt to index a nil value") end
	game.sync.onCareerActive(true)
	runFrames(FRAMES)
	same(game.counts.traffic, FRAMES, "traffic updates (frame error: " .. tostring(game.frameErrors[1]) .. ")")
	same(countLines(logs, "multiplayer_gamemodes_drag_drag.onUpdate"), 1, "log lines naming the drag mode")
end)

test("modules that are not drag modules are left unguarded", function()
	clearGlobals()
	newGame({syncEnabled = false, timesFails = false})
	local trafficOriginal = gameplay_traffic.onUpdate
	gameplay_parking.onUpdate = function() error("parking: attempt to index a nil value") end
	local parkingFailing = gameplay_parking.onUpdate
	game.sync.onCareerActive(true)
	same(gameplay_traffic.onUpdate, trafficOriginal, "traffic's update")
	same(gameplay_parking.onUpdate, parkingFailing, "parking's update")
	runFrames(1)
	same(#game.frameErrors, 1, "a non-drag error still ends the frame, as the game has it")
	same(countLines(logs, "gameplay_parking"), 0, "log lines naming parking")
end)

test("a career starting after the game cached the stock updates still runs the guarded ones", function()
	clearGlobals()
	newGame({syncEnabled = false})
	runFrames(5) -- the game has cached the unguarded, failing drag times update
	same(game.counts.traffic, 0, "traffic updates before the career starts")
	game.sync.onCareerActive(true)
	runFrames(FRAMES)
	same(game.counts.traffic, FRAMES, "traffic updates after the career starts (frame error: " ..
		tostring(game.frameErrors[#game.frameErrors]) .. ")")
end)

test("a guarded update is handed the frame's arguments", function()
	clearGlobals()
	newGame({syncEnabled = false, timesFails = false})
	local seen = {}
	gameplay_drag_times.onUpdate = function(dtReal, dtSim, dtRaw) seen = {dtReal, dtSim, dtRaw} end
	game.sync.onCareerActive(true)
	gameplay_drag_times.onUpdate(0.016, 0.017, 0.018)
	same(seen[1], 0.016, "dtReal")
	same(seen[2], 0.017, "dtSim")
	same(seen[3], 0.018, "dtRaw")
end)

test("after leaving, a loader left under another mod's loader guards nothing", function()
	clearGlobals()
	newGame({syncEnabled = false, timesFails = false})
	game.sync.onCareerActive(true)
	local ours = extensions.load
	extensions.load = function(...) return ours(...) end
	game.sync.onBeamMPServerLeave()
	extensions.load("gameplay/drag/late")
	runFrames(1)
	same(#game.frameErrors, 1, "frame errors from the late module once the guard is off")
	same(countLines(logs, "gameplay_drag_late"), 0, "log lines naming the late module")
end)

--== the drag mode's countdown repair, when nothing fails ====================

-- The real drag mode, enabled, with a drag core holding one racer whose tree was lost.
local function repairingDragMode(isHost)
	local drag = failingDragMode()
	mileage_dragTransport.isHost = function() return isHost end
	local racer = {vehId = 7, currentPhase = 2, treeStarted = false,
		phases = {{}, {started = true, startedOffset = 0.5}}}
	game.getDataCalls = 0
	gameplay_drag_core = {
		getData = function()
			game.getDataCalls = game.getDataCalls + 1
			return {racers = {[7] = racer}}
		end,
	}
	game.countdowns = {}
	gameplay_drag_display = {
		startDragCountdown = function(vehId, offset) table.insert(game.countdowns, {vehId, offset}) end,
	}
	drag.getCountdownStartTime = function() return 0 end
	return drag, racer
end

test("the countdown repair still re-issues a lost tree when nothing fails, and returns 0", function()
	local drag, racer = repairingDragMode(true)
	same(drag.checkTimerDrift(), 0, "checkTimerDrift's result")
	same(#game.countdowns, 1, "countdowns re-issued")
	same(game.countdowns[1][1], 7, "the racer's car")
	same(game.countdowns[1][2], 0, "the countdown offset")
	same(racer.phases[2].timerOffset, 0.5, "the tree's timer offset")
	for _ = 1, 5 do same(drag.checkTimerDrift(), 0, "checkTimerDrift's result") end
	same(#game.countdowns, 3, "countdowns re-issued, at most three times")
	same(countLines(logs, "will not start its tree"), 1, "the give-up line")
	same(countLines(logs, "failed"), 0, "failure lines logged")
end)

test("the countdown repair does nothing on a player who is not the strip's authority", function()
	local drag = repairingDragMode(false)
	same(drag.checkTimerDrift(), 0, "checkTimerDrift's result")
	same(game.getDataCalls, 0, "drag core calls")
	same(#game.countdowns, 0, "countdowns re-issued")
end)

--== failures the guard must still name =====================================

test("two drag functions failing every frame are each logged once, by their own name", function()
	clearGlobals()
	newGame({syncEnabled = false})
	gameplay_drag_display.onUpdate = function() error("gameplay_drag_display: attempt to call a nil value") end
	game.sync.onCareerActive(true)
	runFrames(FRAMES)
	same(game.counts.traffic, FRAMES, "traffic updates (frame error: " .. tostring(game.frameErrors[1]) .. ")")
	same(countLines(logs, "gameplay_drag_times.onUpdate"), 1, "log lines naming the drag timer")
	same(countLines(logs, "gameplay_drag_display.onUpdate"), 1, "log lines naming the drag display")
end)

test("a drag update raising a value that is not a string is still contained and logged once", function()
	clearGlobals()
	newGame({syncEnabled = false, timesFails = false})
	gameplay_drag_times.onUpdate = function() error({code = 7}) end
	game.sync.onCareerActive(true)
	runFrames(FRAMES)
	same(game.counts.traffic, FRAMES, "traffic updates (frame error: " .. tostring(game.frameErrors[1]) .. ")")
	same(#game.frameErrors, 0, "frames ended early")
	same(countLines(logs, "gameplay_drag_times.onUpdate"), 1, "log lines naming the drag timer")
end)

test("the drag mode's countdown repair and result finaliser failing together are each logged once", function()
	local drag = failingDragMode()
	pcall(drag.onDragMpTimeslipRequested)
	for _ = 1, FRAMES do
		local ok, result = pcall(drag.checkTimerDrift)
		expect(ok, "checkTimerDrift raised: " .. tostring(result))
		local ok2, err = pcall(drag.onUpdate)
		expect(ok2, "onUpdate raised: " .. tostring(err))
	end
	same(countLines(logs, "multiplayer_gamemodes_drag_drag.checkTimerDrift"), 1, "log lines naming checkTimerDrift")
	same(countLines(logs, "multiplayer_gamemodes_drag_drag.onUpdate"), 1, "log lines naming the finaliser")
end)
