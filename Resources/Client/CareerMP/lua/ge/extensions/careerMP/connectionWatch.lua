--CareerMP :: lost server connection
--
-- When the server stops, BeamMP's launcher only tells the game if the connection is
-- actually closed, and even then the only warning is BeamMP's own popup. A player in
-- their career could carry on for minutes on a server that no longer exists.
--
-- The server sends every player rxCareerMPAlive every two seconds. While the player's
-- career runs on a server, this extension counts the time since it last heard one. After
-- ten seconds of silence, or as soon as BeamMP opens its disconnect dialog (a kick or a
-- closed connection), it saves the career, logs it, flashes the message and tells the
-- player list (careerMPConnectionLost), which shows it with a Return to menu button.
--
-- A quiet spell that ends before the player leaves clears the message again; a closed
-- connection or a kick never does.

local M = {}

local logTag = "careerMP.connection"

local SILENCE_SECONDS = 10
local MAX_FRAME_SECONDS = 1        -- one long frame (a load, a hitch) counts as this much
local FLASH_SECONDS = 10
local LOST_MESSAGE = "Lost connection to the server"
local SESSION_BAR_TEXT = "Disconnected"
-- BeamMP's quitMP opens its disconnect dialog with this okLua; nothing else does.
local DISCONNECT_OK_LUA = "MPCoreNetwork.leaveServer(true)"

-- True while the player's career runs on a server.
local watching = false
-- Seconds since the server was last heard, each frame counting at most MAX_FRAME_SECONDS.
local silence = 0
-- Set once the connection is lost: {kicked, reason, closed (BeamMP reported it), saved}.
local lost = nil
-- BeamMP's dialog function while wrapped: {ui, original, wrapper}.
local hooked = nil
local missingHookWarned = false

local function isMPSession()
	local compat = extensions.careerMP_compat
	return type(compat) == "table" and compat.isMPSession() == true
end

local function message()
	if lost and lost.kicked then return "Kicked from the server: " .. lost.reason end
	return LOST_MESSAGE
end

local function publishLost()
	guihooks.trigger("careerMPConnectionLost", {
		kicked = lost.kicked, reason = lost.reason, saved = lost.saved, message = message(),
	})
end

local function publishRestored()
	guihooks.trigger("careerMPConnectionRestored")
end

local function announce()
	guihooks.trigger("TopCenterAppsFlashMessage", {msg = message(), ttl = FLASH_SECONDS, big = false})
	guihooks.trigger("onBeamMPSetServerName", SESSION_BAR_TEXT)
	publishLost()
end

-- True only when the game's save returned without an error.
local function save()
	local ok, err = pcall(function() career_saveSystem.saveCurrent() end)
	if not ok then log("E", logTag, "career save failed: " .. tostring(err)) end
	return ok
end

-- kicked: BeamMP gave a reason. closed: BeamMP itself reported the disconnect.
local function declareLost(kicked, reason, closed)
	if lost then
		lost.closed = lost.closed or closed
		if kicked and not lost.kicked then
			lost.kicked, lost.reason = true, reason
			log("W", logTag, "kicked from the server: " .. reason)
			announce()
		end
		return
	end
	lost = {kicked = kicked, reason = reason, closed = closed}
	lost.saved = save()
	if kicked then
		log("W", logTag, "kicked from the server: " .. reason)
	else
		log("W", logTag, "lost connection to the server" .. (closed and "" or string.format(" (nothing heard for %d s)", SILENCE_SECONDS)))
	end
	announce()
end

local function clearLost()
	lost = nil
	silence = 0
	publishRestored()
end

--== the server's alive message ==============================================

local function rxCareerMPAlive()
	silence = 0
	if lost and not lost.closed then
		log("I", logTag, "server heard again")
		clearLost()
		if type(UI) == "table" and type(UI.setServerName) == "function" then
			pcall(UI.setServerName)
		end
	end
end

--== BeamMP's disconnect dialog ==============================================

local function onDialog(options)
	if not watching or type(options) ~= "table" or options.okLua ~= DISCONNECT_OK_LUA then return end
	local text = type(options.text) == "string" and options.text or ""
	local reason = text:match("^Reason:%s*(.-)%s*$") or text
	if reason == "" then
		declareLost(false, nil, true)
	else
		declareLost(true, reason, true)
	end
end

-- BeamMP reloads its own extensions now and then, so this is checked again on each
-- career start and wraps whatever UI table is current.
local function hookDialog()
	if hooked and hooked.ui == UI and UI.showMdDialog == hooked.wrapper then return end
	hooked = nil
	if type(UI) ~= "table" or type(UI.showMdDialog) ~= "function" then
		if not missingHookWarned then
			missingHookWarned = true
			log("W", logTag, "UI.showMdDialog missing - a lost connection is noticed only through the server's silence")
		end
		return
	end
	local ui, original = UI, UI.showMdDialog
	local function wrapper(options, ...)
		local ok, err = pcall(onDialog, options)
		if not ok then log("E", logTag, "disconnect check failed: " .. tostring(err)) end
		return original(options, ...)
	end
	hooked = {ui = ui, original = original, wrapper = wrapper}
	ui.showMdDialog = wrapper
end

local function unhookDialog()
	if not hooked then return end
	if hooked.ui.showMdDialog == hooked.wrapper then hooked.ui.showMdDialog = hooked.original end
	hooked = nil
end

--== public ==================================================================

--- Saves the career again after a failed save, and tells the player list the result.
function M.retrySave()
	if not lost or lost.saved then return end
	lost.saved = save()
	publishLost()
end

--- Sends the current state to the player list, which asks when it loads.
function M.sendState()
	if lost then publishLost() else publishRestored() end
end

--== hooks ===================================================================

function M.onCareerActive(active)
	if active and isMPSession() then
		watching = true
		silence = 0
		hookDialog()
	elseif not active then
		watching = false
		silence = 0
	end
end

function M.onUpdate(dtReal)
	if not watching or lost then return end
	local dt = tonumber(dtReal) or 0
	silence = silence + math.max(0, math.min(MAX_FRAME_SECONDS, dt))
	if silence >= SILENCE_SECONDS then declareLost(false, nil, false) end
end

function M.onBeamMPServerLeave()
	watching = false
	if lost then clearLost() end
	silence = 0
end

function M.onExtensionLoaded()
	if type(AddEventHandler) == "function" then
		AddEventHandler("rxCareerMPAlive", rxCareerMPAlive)
	else
		log("E", logTag, "AddEventHandler unavailable - BeamMP not loaded")
	end
	hookDialog()
	log("I", logTag, "CareerMP connection watch LOADED")
end

function M.onExtensionUnloaded()
	watching = false
	unhookDialog()
	log("I", logTag, "CareerMP connection watch UNLOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
