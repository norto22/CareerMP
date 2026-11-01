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
	return m
end

local function newGame(opts)
	opts = opts or {}
	game = {
		order = {},
		modules = newModules(),
		cache = {},
		counts = {core = 0, times = 0, traffic = 0, parking = 0, police = 0},
		frameErrors = {},
		timesFails = opts.timesFails ~= false,
		syncEnabled = opts.syncEnabled == true,
		files = opts.files or {},
		hookUpdates = 0,
	}
	logs = {}

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
		table.insert(game.order, name)
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
		if name ~= "mileage_dragSync" and not (opts.skip and opts.skip[name]) then addLoaded(name) end
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
