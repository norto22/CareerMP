--Mileage :: multiplayer_sessionManager shim
--
-- BeamNG 0.39's gameplay code calls a `multiplayer_sessionManager` extension that the
-- game does not ship -- it belongs to their unreleased official multiplayer. Five
-- functions are referenced across the whole game:
--
--   getCurrentSession      general.lua, navigationContext.lua, system.lua, taxi.lua
--   getSessionPlayers      display.lua, vehicleTabInteractions.lua
--   isSessionHost          multiplayer.lua
--   sendSessionHost        gameplay/drag/phaseHandlers.lua:875  (the finish time)
--   leaveCurrentSession    mpOptions.lua
--
-- Providing them lets the shipped drag code send its own finish times, which is the
-- one sender BeamNG already wrote.
--
-- This is a shim over BeamMP, not an implementation of BeamNG's session service. It
-- reports the BeamMP session in the shape the game expects and nothing more.

local M = {}

local logTag = "mileage.sessionManager"

local function transport()
	return mileage_dragTransport
end

--- Always nil. This is deliberate and load-bearing.
---
--- "Session" here does not mean "a multiplayer session" in general -- it means
--- specifically a BeamNG *official* multiplayer session, and the game uses a non-nil
--- return to switch whole subsystems over to a UI backend that does not ship:
---
---   ui/router/services/navigationContext.lua:35
---       isMultiplayerActive = bool(... getCurrentSession() ~= nil)
---   gameplay/taxi.lua:216
---       if getCurrentSession() then return false end        -- disables taxis
---   gameplay/drift/general.lua:201
---       ... getCurrentSession() and multiplayerEnabled
---
--- Returning a session replaced the career pause menu with the official multiplayer
--- one, which then tried to index multiplayer_uiBackend_playerListProvider (nil) and
--- threw -- so career saves could not be loaded at all. It also silently turned taxis
--- off.
---
--- Nothing in gameplay/drag/ calls this; the drag code only needs sendSessionHost. So
--- the honest answer is nil: we are in a BeamMP session, not a BeamNG one, and no
--- BeamNG multiplayer UI exists to back the claim.
function M.getCurrentSession()
	return nil
end

--- playerId -> { persona }. persona is the display name the drag UI shows for a racer.
function M.getSessionPlayers()
	local t = transport()
	if t and t.bridge and t.bridge.getSessionPlayers then
		return t.bridge.getSessionPlayers()
	end
	return {}
end

--- Always false, for the same reason getCurrentSession is always nil: there is no
--- BeamNG session, so there is no BeamNG session host.
---
--- Reporting our drag-host election here would leak drag-specific state into unrelated
--- systems. gameplay/crawl/display.lua:41 is the live example:
---
---     if not multiplayer_sessionManager or not multiplayer_sessionManager.isSessionHost() then
---       ui_message(... penalty points ...)
---
--- Answering true there would stop whichever player happens to be the drag host from
--- seeing crawl penalty messages -- a baffling, unrelated symptom. False reproduces
--- exactly the behaviour of the module not existing at all, which is what every caller
--- was written against.
---
--- The drag code does not use this: it asks mileage_dragTransport whether we hold the
--- strip we are standing at, through its own bridge.
function M.isSessionHost()
	return false
end

--- Used by gameplay/drag/phaseHandlers.lua to report a finish time to the authority.
function M.sendSessionHost(msgName, data)
	local t = transport()
	if not t then
		log("E", logTag, "drag transport unavailable - dropping " .. tostring(msgName))
		return
	end
	t.sendToHost(msgName, data)
end

--- BeamMP owns connection lifecycle; disconnecting is the launcher's job, not ours.
function M.leaveCurrentSession()
	log("W", logTag, "leaveCurrentSession() ignored - use the BeamMP UI to disconnect")
	return false
end

local function onExtensionLoaded()
	log("I", logTag, "Mileage session manager shim LOADED")
end

M.onExtensionLoaded = onExtensionLoaded

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
