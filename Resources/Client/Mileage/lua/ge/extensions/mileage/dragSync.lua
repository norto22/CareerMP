--Mileage :: drag multiplayer activation
--
-- Small by design. Its job is to decide *whether* native multiplayer drag racing is
-- switched on, to un-stub the one getter that gates it, and to keep a failing drag update
-- from stopping the rest of the game's frame (the frame guard, below).
--
-- The work is split three ways:
--   mileage/dragTransport   messages on and off the wire, the bridge, the handlers
--   multiplayer/gamemodes/drag/drag   the network adapter the game calls into
--   this file                 activation, the getDragGamemode patch and the frame guard
--
-- gameplay/drag/core.lua ships getDragGamemode() hard-wired to nil, with a comment
-- saying to restore it "once multiplayer drag is ready to ship". Pointing it at our
-- gamemode is what turns on every multiplayer path inside gameplay/drag/.

local M = {}

local logTag = "mileage.dragSync"

local patched = false
local active = false

local function gamemode()
	if multiplayer_gamemodes_drag_drag then return multiplayer_gamemodes_drag_drag end
	extensions.load("multiplayer/gamemodes/drag/drag")
	return multiplayer_gamemodes_drag_drag
end

--== the frame guard =========================================================

-- The game runs every extension's per-frame update in one loop with no error protection
-- (hookFast in lua/common/extensions.lua), and the drag modules come before traffic,
-- parking and police in it. One drag update raising an error ends that frame's update
-- for everything after it, so an error that repeats every frame stops traffic where it
-- is while the player's own car and the rest of the game keep running.
--
-- From each career start on a server, synced drag on or off, every loaded drag module's
-- per-frame updates run under xpcall. The first error from each one is logged with its
-- traceback; repeats are counted, not logged every frame. The game caches each hook's list
-- of functions, so the cache is dropped after wrapping and after putting the originals
-- back, or the game would go on calling the old ones.

local GUARDED_HOOKS = {"onUpdate", "onPreRender", "onGuiUpdate", "onDrawDebug"}

-- Our own wrappers, recognised so a function is never wrapped twice.
local guardWrappers = setmetatable({}, {__mode = "k"})

-- "extension.hook" -> {module, hook, original, wrapper}
local guarded = {}

-- "extension.hook" -> failures since the guard went on
local guardFailures = {}

local guardOn = false

local traceback = (type(debug) == "table" and type(debug.traceback) == "function") and debug.traceback
	or function(msg) return msg end

local function isDragExtension(name)
	return name == "multiplayer_gamemodes_drag_drag" or name:find("^gameplay_drag_") ~= nil
end

local function finishGuarded(ok, ...)
	if ok then return ... end
end

local function guardFunction(name, module, hook)
	local original = rawget(module, hook)
	if type(original) ~= "function" or guardWrappers[original] then return false end

	local key = name .. "." .. hook
	-- Made once per function, so a guarded frame allocates nothing.
	local function onError(err)
		local count = (guardFailures[key] or 0) + 1
		guardFailures[key] = count
		if count == 1 then
			log("E", logTag, string.format(
				"%s failed; it is stopped there so traffic and the rest of the game keep updating, " ..
				"and later failures of it are counted, not logged: %s",
				key, tostring(traceback(tostring(err), 2))))
		end
		return err
	end
	local function wrapper(...)
		return finishGuarded(xpcall(original, onError, ...))
	end

	guardWrappers[wrapper] = true
	guarded[key] = {module = module, hook = hook, original = original, wrapper = wrapper}
	module[hook] = wrapper
	return true
end

-- Wraps what is not wrapped yet; returns how many functions it wrapped.
local function guardLoadedDragModules()
	local ext = extensions
	if type(ext) ~= "table" or type(ext.getLoadedExtensionsNames) ~= "function" then return 0 end
	local count = 0
	for _, name in ipairs(ext.getLoadedExtensionsNames() or {}) do
		-- rawget: a plain lookup of a missing extension's global can load it.
		local module = type(name) == "string" and isDragExtension(name) and rawget(_G, name)
		if type(module) == "table" then
			for _, hook in ipairs(GUARDED_HOOKS) do
				if guardFunction(name, module, hook) then count = count + 1 end
			end
		end
	end
	return count
end

local function refreshHookCache()
	local ext = extensions
	if type(ext) ~= "table" or type(ext.hookUpdate) ~= "function" then return end
	for _, hook in ipairs(GUARDED_HOOKS) do pcall(ext.hookUpdate, hook) end
end

-- Wraps what is not wrapped yet, and drops the cache only when something was.
local function guardDragModules()
	local ok, wrapped = pcall(guardLoadedDragModules)
	if not ok then
		log("E", logTag, "could not guard the drag modules' updates: " .. tostring(wrapped))
		return 0
	end
	if wrapped > 0 then refreshHookCache() end
	return wrapped
end

-- Several drag modules load only when a race starts, and the game announces no load, so
-- extensions.load is wrapped to guard them before their first frame. A check run in a
-- later frame could be cut off by the very error it is there to catch.
-- {original, wrapper}, kept while the wrapper is anywhere in the loader chain.
local loader = nil

local function afterLoad(...)
	if guardOn then guardDragModules() end
	return ...
end

local function wrapLoader()
	-- Still in place, or under another mod's loader: already covered.
	if loader then return end
	local ext = extensions
	if type(ext) ~= "table" or type(ext.load) ~= "function" or guardWrappers[ext.load] then return end
	local original = ext.load
	local function wrapper(...)
		-- No pcall: a failing load raises its own error to its caller, as before.
		return afterLoad(original(...))
	end
	guardWrappers[wrapper] = true
	loader = {original = original, wrapper = wrapper}
	ext.load = wrapper
end

local function unwrapLoader()
	local ext = extensions
	if not loader or type(ext) ~= "table" then return end
	-- Under another mod's loader it stays, doing nothing while the guard is off.
	if ext.load == loader.wrapper then
		ext.load = loader.original
		loader = nil
	end
end

-- Safe to call again: only what is new is wrapped.
local function installFrameGuard()
	guardOn = true
	wrapLoader()
	local wrapped = guardDragModules()
	if wrapped > 0 then
		log("I", logTag, string.format("guarding %d drag update(s) so a drag error cannot stop traffic", wrapped))
	end
end

local function removeFrameGuard()
	if not guardOn then return end
	guardOn = false
	unwrapLoader()
	-- Only what is still ours goes back; a function another mod put in place stays.
	for _, entry in pairs(guarded) do
		if rawget(entry.module, entry.hook) == entry.wrapper then
			entry.module[entry.hook] = entry.original
		end
	end
	guarded = {}
	guardFailures = {}
	refreshHookCache()
end

--== the un-stub =============================================================

-- The path we re-read and re-load. Deliberately BeamNG's own file, never a copy of it.
local CORE_PATH = "/lua/ge/extensions/gameplay/drag/core.lua"

--- Everything gameplay/drag/core.lua asks for when it wants the MP gamemode.
---
--- Set while drag sync is active, nil otherwise. Keeping the gate here rather than in the
--- patched source means switching drag sync off is one assignment and restores the stock
--- behaviour exactly -- getDragGamemode() goes back to returning nil.
local PROVIDER_GLOBAL = "mileage_dragGamemodeProvider"

--- The stub, and what BeamNG intended it to be.
---
--- 0.39.2 ships this:
---
---   local function getDragGamemode()
---     -- Restore the two lines below once multiplayer drag is ready to ship.
---     -- local ext = _G[DRAG_MP_GAMEMODE_EXT]
---     -- if type(ext) ~= "table" then return nil end
---     -- return ext
---     return nil
---   end
---
--- That single `return nil` is what kept multiplayer drag racing dormant. It cannot be
--- reached from outside: it is a `local function` called as an upvalue from ~20 places in
--- core.lua, `M.getDragGamemode` merely exports a copy of the reference, and BeamNG's Lua
--- sandbox refuses debug.getupvalue ("function not allowed by sandbox"). Patching only the
--- module field is what produced months of confusing behaviour -- poi.lua saw our gamemode
--- and let players join, while every decision inside core.lua still read nil and ran the
--- single-player path, so each client registered only its own car and raced alone.
---
--- `.-` spans newlines in Lua patterns, and core.lua indents with two spaces, so `\nend\n`
--- can only match this function's own terminator.
--- Deliberately stops at the terminator without requiring the newline after it.
--- The two files disagree on line endings -- core.lua ships LF, display.lua ships
--- CRLF -- and readFile opens in text mode, so whether that byte is one character or
--- two depends on the platform. `.-` is non-greedy and both files indent with spaces,
--- so the first column-zero `end` is the function's own.
local STUB_PATTERN = "local function getDragGamemode%(%).-\nend"

local REPLACEMENT = [==[
local function getDragGamemode()
  -- Restored by Mileage. Equivalent to the two lines BeamNG commented out, except the
  -- lookup goes through a provider Mileage owns, so drag sync can be switched off
  -- without reloading this file.
  local provider = rawget(_G, "]==] .. PROVIDER_GLOBAL .. [==[")
  if type(provider) ~= "function" then return nil end
  local ext = provider()
  if type(ext) ~= "table" then return nil end
  return ext
end]==]

--- Re-load core.lua from BeamNG's own source with that one function restored.
---
--- Nothing is forked on disk. We read the file the game shipped, change the four lines
--- that gate multiplayer, and copy the resulting functions over the live module table --
--- in place, so the extension registry, the hook dispatcher and every module holding a
--- `gameplay_drag_core` reference all follow along. A BeamNG update to core.lua is picked
--- up automatically, and the day they uncomment those lines themselves this becomes a
--- no-op that still works.
---
--- Every step is guarded. A failure here must leave drag racing exactly as the base game
--- has it -- working single-player races -- and must never be able to take career mode
--- down with it, which is what an unguarded version of this did.
local function reloadCoreWithGamemode()
	local core = gameplay_drag_core
	if not core then return false, "gameplay_drag_core not loaded" end

	local ok, src = pcall(readFile, CORE_PATH)
	if not ok or type(src) ~= "string" or #src == 0 then
		return false, "cannot read " .. CORE_PATH
	end

	local patchedSrc, count = src:gsub(STUB_PATTERN, REPLACEMENT, 1)
	if count ~= 1 then
		return false, string.format(
			"getDragGamemode not found in %s (matched %d times) - BeamNG may have changed it",
			CORE_PATH, count)
	end

	local chunk, err = loadstring(patchedSrc, "@" .. CORE_PATH .. " [Mileage]")
	if not chunk then return false, "compile failed: " .. tostring(err) end

	local built, module = pcall(chunk)
	if not built or type(module) ~= "table" then
		return false, "running the patched chunk failed: " .. tostring(module)
	end

	-- Sanity-check before committing: the rebuilt module must actually resolve a gamemode
	-- through the provider. If it does not, the edit compiled but did not do its job, and
	-- swapping it in would be strictly worse than leaving the stock module alone.
	if type(module.getDragGamemode) ~= "function" then
		return false, "the rebuilt module has no getDragGamemode"
	end
	rawset(_G, PROVIDER_GLOBAL, function() return gamemode() end)
	if module.getDragGamemode() == nil then
		rawset(_G, PROVIDER_GLOBAL, nil)
		return false, "the rebuilt getDragGamemode still returns nil"
	end

	-- Commit. Mutate the existing table rather than replacing the global: hooks are
	-- dispatched against the table the extension registry holds, and other modules
	-- captured that same reference at load time.
	local replaced = 0
	for k, v in pairs(module) do
		core[k] = v
		replaced = replaced + 1
	end

	return true, replaced
end

--- The duplicate on-screen messages.
---
--- display.stoppingVehicleDrag flashes for any racer with isPlayable, and it is raised once
--- per racer by the phase machine (phaseHandlers.lua:976). On this machine dragData.racers
--- holds the local car AND the remote player's stub, both playable, so "Stop the vehicle!"
--- was drawn twice, overlapping.
---
--- isPlayable cannot simply be turned off on the stub: it gates about forty sites including
--- the phase machine, staging and the tree. The discriminator that already exists for
--- exactly this is isLocalRacer, which core.lua:1147 sets false on remote racers and which
--- times.lua and phaseHandlers already use to tell them apart. dragBridge's message sites
--- are the outlier that never consults it.
---
--- Same source-rewrite approach as core.lua, and entirely cosmetic: if the pattern stops
--- matching after a game update this logs and moves on, and the only consequence is that
--- the message goes back to appearing twice.
local DISPLAY_PATH = "/lua/ge/extensions/gameplay/drag/display.lua"

--- Every on-screen drag message, drawn twice.
---
--- display.flashMessage fires TWO hooks for one message:
---
---   guihooks.trigger('TopCenterAppsFlashMessage', ...)   -- rendered by topCenterApps
---   guihooks.trigger('ScenarioFlashMessage', ...)        -- rendered by raceCountdown
---
--- and the career and freeroam layouts both contain BOTH apps, so "Pre-stage", "Stage",
--- "False start", "Go!" and the rest were each drawn by two of them, overlapping. This is
--- not multiplayer-specific -- it is just far more visible once races actually run.
---
--- Dropping the ScenarioFlashMessage line leaves exactly one renderer. topCenterApps is
--- the one kept because it is present in the layouts Mileage maintains, and it is the
--- 0.39 replacement for the older messages app.
local FLASH_PATTERN = "local function flashMessage%(msg, duration%).-\nend"

local FLASH_REPLACEMENT = [==[
local function flashMessage(msg, duration)
  duration = duration or flashTime

  ui_appContainers.showApp('topCenter', 'flashMessage')
  -- Mileage: the ScenarioFlashMessage trigger that used to follow this line was removed.
  -- Both it and TopCenterAppsFlashMessage are rendered, by raceCountdown and topCenterApps
  -- respectively, and both apps ship in the career and freeroam layouts -- so every drag
  -- message appeared twice.
  guihooks.trigger('TopCenterAppsFlashMessage', { msg = msg, ttl = duration, big = false })
end]==]

local STOPPING_PATTERN = "local function stoppingVehicleDrag%(vehId%).-\nend"

local STOPPING_REPLACEMENT = [==[
local function stoppingVehicleDrag(vehId)
  local dragData = gameplay_drag_core.getData()
  local racer = dragData and dragData.racers and dragData.racers[vehId]
  -- Mileage: also require the racer to be ours. A remote player's stub is playable on
  -- this machine too, so the stock test fired once per racer and drew the message twice.
  if racer and racer.isPlayable and racer.isLocalRacer ~= false then
    flashMessage("Stop the vehicle!", 5)
  end
end]==]

local function patchDisplayMessages()
	-- Load it if it is not up yet, rather than giving up.
	--
	-- This is the whole reason the fix never took: activation happens when the server
	-- enables drag sync, which is long before anyone drives to a strip, and
	-- gameplay_drag_display is loaded lazily by the drag code on demand. Both clients
	-- logged "could not de-duplicate drag messages: gameplay_drag_display not loaded" every
	-- single time, so the patch was written, shipped, tested -- and never once applied.
	--
	-- Loading it here is safe: the drag extensions are loaded by name the same way
	-- mileage/dragTransport loads mpDragHandlers, and doing it early only means the module
	-- exists sooner than it otherwise would.
	if not gameplay_drag_display then
		pcall(extensions.load, "gameplay/drag/display")
	end
	local display = gameplay_drag_display
	if not display then return false, "gameplay_drag_display could not be loaded" end

	local ok, src = pcall(readFile, DISPLAY_PATH)
	if not ok or type(src) ~= "string" or #src == 0 then
		return false, "cannot read " .. DISPLAY_PATH
	end

	local patchedSrc, count = src:gsub(STOPPING_PATTERN, STOPPING_REPLACEMENT, 1)
	if count ~= 1 then
		return false, "stoppingVehicleDrag not found (matched " .. count .. " times)"
	end

	local flashCount
	patchedSrc, flashCount = patchedSrc:gsub(FLASH_PATTERN, FLASH_REPLACEMENT, 1)
	if flashCount ~= 1 then
		return false, "flashMessage not found (matched " .. flashCount .. " times)"
	end

	local chunk, err = loadstring(patchedSrc, "@" .. DISPLAY_PATH .. " [Mileage]")
	if not chunk then return false, "compile failed: " .. tostring(err) end

	local built, module = pcall(chunk)
	if not built or type(module) ~= "table" then
		return false, "running the patched chunk failed: " .. tostring(module)
	end

	local replaced = 0
	for k, v in pairs(module) do
		display[k] = v
		replaced = replaced + 1
	end
	return true, replaced
end

local function patchDragCore()
	if patched then return true end
	local core = gameplay_drag_core
	if not core then
		log("W", logTag, "gameplay_drag_core not loaded yet - deferring patch")
		return false
	end

	-- The gate the patched source reads. Set before the reload so its self-check passes.
	rawset(_G, PROVIDER_GLOBAL, function()
		if not active then return nil end
		return gamemode()
	end)

	local ok, result = reloadCoreWithGamemode()
	if not ok then
		rawset(_G, PROVIDER_GLOBAL, nil)
		log("E", logTag, "could not enable native MP drag: " .. tostring(result))
		log("E", logTag, "drag racing stays single-player, which is the base game's " ..
			"behaviour - solo runs still work")
		return false
	end

	patched = true
	log("I", logTag, string.format(
		"gameplay_drag_core rebuilt from source with getDragGamemode restored (%d function(s)) - native MP drag enabled",
		result))

	-- Cosmetic, and deliberately not fatal.
	local msgOk, msgResult = patchDisplayMessages()
	if msgOk then
		log("I", logTag, string.format(
			"gameplay_drag_display rebuilt so on-screen messages only fire for our own car (%d function(s))",
			msgResult))
	else
		log("W", logTag, "could not de-duplicate drag messages: " .. tostring(msgResult))
	end

	-- The rebuilds copied unguarded functions over the live tables, and the game's hook
	-- cache can still hold the stock ones, which would keep running with their own state.
	if guardOn then guardDragModules() end
	refreshHookCache()

	return true
end

local function unpatchDragCore()
	if not patched then return end
	-- One assignment. With no provider the restored getDragGamemode returns nil, which is
	-- precisely what the shipped stub does, so core.lua is back to stock behaviour.
	rawset(_G, PROVIDER_GLOBAL, nil)
	patched = false
	log("I", logTag, "native MP drag disabled - gameplay_drag_core back to single-player")
end

--== activation ==============================================================

function M.setActive(state)
	local gm = gamemode()
	if not gm then
		log("E", logTag, "drag gamemode extension unavailable - cannot activate")
		return false
	end

	if state then
		local t = mileage_dragTransport
		if not t or not t.ensureHandlersLoaded() then
			log("E", logTag, "drag transport or protocol handlers unavailable - not activating")
			return false
		end
		if not patchDragCore() then return false end
		active = true
		gm.setEnabled(true)
	else
		active = false
		gm.setEnabled(false)
		unpatchDragCore()
	end
	return true
end

function M.isActive() return active end
function M.isPatched() return patched end

-- On by default, and still a server switch.
--
-- Un-stubbing getDragGamemode makes gameplay/drag/* take its multiplayer paths, and those
-- expect a populated race state: staging, the tree and the timers all consult
-- drag.getRaceState(), and remote racers' UI updates are suppressed on the assumption
-- their own client drives them. mileage/dragLobby.lua supplies that state, so this is now
-- a working feature rather than a work in progress.
--
-- It remains a switch because it rewrites two of the game's own files at runtime and has
-- only been proven with two players at one strip. Turned off, drag racing runs the stock
-- single-player logic -- fully working, just not synchronised between players.
local function isEnabledByServer()
	local enabler = mileageEnabler
	local config = enabler and enabler.getClientConfig and enabler.getClientConfig()
	return config ~= nil and config.nativeDragSyncEnabled == true
end

function M.onCareerActive(careerIsActive)
	if not careerIsActive then
		M.setActive(false)
		removeFrameGuard()
		return
	end

	-- Before the switch is read: the stock single-player drag code runs in the same
	-- unprotected frame loop, so synced drag off keeps the guard.
	installFrameGuard()

	if not isEnabledByServer() then
		log("I", logTag, "native MP drag sync is disabled (server client.nativeDragSyncEnabled " ..
			"is not true) - drag racing will use the stock single-player logic")
		M.setActive(false)
		return
	end

	log("I", logTag, "native MP drag sync is ENABLED - head-to-head drag racing is on. " ..
		"Verified with two players; set client.nativeDragSyncEnabled = false to go back " ..
		"to stock single-player drag racing")
	M.setActive(true)
end

--== lifecycle ===============================================================

local function onExtensionLoaded()
	log("I", logTag, "Mileage drag sync LOADED")
end

local function onExtensionUnloaded()
	M.setActive(false)
	removeFrameGuard()
	log("I", logTag, "Mileage drag sync UNLOADED")
end

local function onBeamMPServerLeave()
	M.setActive(false)
	removeFrameGuard()
end

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onBeamMPServerLeave = onBeamMPServerLeave

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
