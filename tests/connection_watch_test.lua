-- careerMP/connectionWatch.lua: a player in a server career is told, and the career
-- saved, when the server goes quiet or BeamMP reports a disconnect or kick; nothing
-- else raises it.

local SOURCE = "Resources/Client/CareerMP/lua/ge/extensions/careerMP/connectionWatch.lua"
local COMPAT = "Resources/Client/CareerMP/lua/ge/extensions/careerMP/compat.lua"

local DISCONNECT_TITLE = "You have been disconnected from the server"
local LEAVE_LUA = "MPCoreNetwork.leaveServer(true)"

local logs, triggers, saves, dialogs, handlers, mp, saveFails, originalDialog

-- A fresh game on a server and a fresh watch (its state lives in module locals).
local function setup(opts)
	opts = opts or {}
	logs, triggers, saves, dialogs, handlers = {}, {}, 0, {}, {}
	mp, saveFails = opts.mp ~= false, false

	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	function AddEventHandler(name, fn) handlers[name] = fn end
	MPCoreNetwork = {isMPSession = function() return mp end}
	extensions = {careerMP_compat = dofile(COMPAT)}
	career_saveSystem = {saveCurrent = function()
		saves = saves + 1
		if saveFails then error("disk full") end
	end}
	guihooks = {trigger = function(name, data) table.insert(triggers, {name = name, data = data}) end}
	UI = {
		showMdDialog = function(options) table.insert(dialogs, options) end,
		setServerName = function() table.insert(triggers, {name = "onBeamMPSetServerName", data = "My Server"}) end,
	}

	originalDialog = UI.showMdDialog

	local watch = dofile(SOURCE)
	watch.onExtensionLoaded()
	return watch
end

local function frames(watch, count, dt)
	for _ = 1, count do watch.onUpdate(dt or 1) end
end

local function alive()
	handlers.rxCareerMPAlive("")
end

local function triggered(name)
	local found = {}
	for _, t in ipairs(triggers) do
		if t.name == name then table.insert(found, t.data) end
	end
	return found
end

local function lastLost()
	local lost = triggered("careerMPConnectionLost")
	return lost[#lost], #lost
end

local function disconnectDialog(text)
	UI.showMdDialog({dialogtype = "alert", title = DISCONNECT_TITLE, text = text or "",
		okText = "Return to menu", okLua = LEAVE_LUA})
end

--== silence =================================================================

test("silence from the career start, with no alive message ever, raises the alarm", function()
	local watch = setup()
	watch.onCareerActive(true)
	frames(watch, 9)
	same(lastLost(), nil, "alarm after 9 s")
	frames(watch, 2)
	local lost, count = lastLost()
	same(count, 1, "careerMPConnectionLost events")
	same(lost.kicked, false, "kicked")
	same(lost.saved, true, "saved")
	same(lost.message, "Lost connection to the server", "message")
	same(saves, 1, "saves")
	same(countLines(logs, "careerMP.connection: lost connection to the server"), 1, "log line")
	local flash = triggered("TopCenterAppsFlashMessage")
	same(#flash, 1, "flash messages")
	same(flash[1].msg, "Lost connection to the server", "flash text")
	local names = triggered("onBeamMPSetServerName")
	same(names[#names], "Disconnected", "session bar")
end)

test("the alarm is raised once, however long the silence lasts", function()
	local watch = setup()
	watch.onCareerActive(true)
	frames(watch, 60)
	local _, count = lastLost()
	same(count, 1, "events")
	same(saves, 1, "saves")
end)

test("silence after the last alive message raises the alarm", function()
	local watch = setup()
	watch.onCareerActive(true)
	for _ = 1, 5 do frames(watch, 2); alive() end
	frames(watch, 11)
	local _, count = lastLost()
	same(count, 1, "events")
end)

--== no false alarms =========================================================

test("no alarm before the career is active", function()
	local watch = setup()
	frames(watch, 30)
	same(lastLost(), nil, "alarm")
	same(saves, 0, "saves")
end)

test("no alarm in a career off a server", function()
	local watch = setup({mp = false})
	watch.onCareerActive(true)
	frames(watch, 30)
	same(lastLost(), nil, "alarm")
end)

test("no alarm while the server is heard every two seconds", function()
	local watch = setup()
	watch.onCareerActive(true)
	for _ = 1, 60 do frames(watch, 2); alive() end
	same(lastLost(), nil, "alarm")
end)

test("an alive message resets the clock", function()
	local watch = setup()
	watch.onCareerActive(true)
	frames(watch, 9)
	alive()
	frames(watch, 9)
	same(lastLost(), nil, "alarm")
end)

test("a single long frame counts as one second", function()
	local watch = setup()
	watch.onCareerActive(true)
	watch.onUpdate(45)
	frames(watch, 8)
	same(lastLost(), nil, "alarm after a 45 s frame and 8 s")
	frames(watch, 2)
	local _, count = lastLost()
	same(count, 1, "alarm once the real silence passes 10 s")
end)

test("no alarm after leaving the server on purpose", function()
	local watch = setup()
	watch.onCareerActive(true)
	frames(watch, 5)
	watch.onBeamMPServerLeave()
	frames(watch, 30)
	same(lastLost(), nil, "alarm")
end)

test("no alarm after the career ends", function()
	local watch = setup()
	watch.onCareerActive(true)
	frames(watch, 5)
	watch.onCareerActive(false)
	frames(watch, 30)
	same(lastLost(), nil, "alarm")
end)

--== saving ==================================================================

test("a failed save is logged and never reported as saved", function()
	local watch = setup()
	saveFails = true
	watch.onCareerActive(true)
	frames(watch, 11)
	local lost = lastLost()
	same(lost.saved, false, "saved")
	expect(countLines(logs, "E careerMP.connection: career save failed") == 1, "save error logged")
end)

test("trying the save again reports saved once it works", function()
	local watch = setup()
	saveFails = true
	watch.onCareerActive(true)
	frames(watch, 11)
	saveFails = false
	watch.retrySave()
	local lost, count = lastLost()
	same(count, 2, "events")
	same(lost.saved, true, "saved after retry")
	same(saves, 2, "saves")
end)

test("trying the save again when nothing is lost does nothing", function()
	local watch = setup()
	watch.onCareerActive(true)
	watch.retrySave()
	same(saves, 0, "saves")
end)

--== BeamMP's disconnect =====================================================

test("BeamMP's disconnect raises the alarm at once and its own dialog still opens", function()
	local watch = setup()
	watch.onCareerActive(true)
	disconnectDialog("")
	local lost, count = lastLost()
	same(count, 1, "events")
	same(lost.kicked, false, "kicked")
	same(lost.message, "Lost connection to the server", "message")
	same(saves, 1, "saves")
	same(#dialogs, 1, "BeamMP's dialog")
	same(dialogs[1].title, DISCONNECT_TITLE, "dialog title")
end)

test("a kick carries its reason", function()
	local watch = setup()
	watch.onCareerActive(true)
	disconnectDialog("Reason: Too fast")
	local lost = lastLost()
	same(lost.kicked, true, "kicked")
	same(lost.reason, "Too fast", "reason")
	same(lost.message, "Kicked from the server: Too fast", "message")
end)

test("a kick after a plain disconnect switches the wording; the save is not repeated", function()
	local watch = setup()
	watch.onCareerActive(true)
	disconnectDialog("")
	disconnectDialog("Reason: Banned")
	disconnectDialog("")
	local lost, count = lastLost()
	same(count, 2, "events")
	same(lost.message, "Kicked from the server: Banned", "message")
	same(saves, 1, "saves")
end)

test("another dialog through the same function raises nothing", function()
	local watch = setup()
	watch.onCareerActive(true)
	UI.showMdDialog({title = "Server rules", text = "Be nice", okLua = "print('ok')"})
	same(lastLost(), nil, "alarm")
	same(#dialogs, 1, "the dialog still opens")
end)

test("BeamMP's disconnect outside a server career raises nothing", function()
	setup()
	disconnectDialog("")
	same(lastLost(), nil, "alarm")
	same(#dialogs, 1, "the dialog still opens")
end)

test("unloading puts BeamMP's function back", function()
	local watch = setup()
	expect(UI.showMdDialog ~= originalDialog, "wrapped while loaded")
	watch.onExtensionUnloaded()
	same(UI.showMdDialog, originalDialog, "BeamMP's function after unloading")
end)

test("without BeamMP's dialog function the silence check still works", function()
	setup().onExtensionUnloaded()
	UI = nil
	local watch = dofile(SOURCE)
	watch.onExtensionLoaded()
	same(countLines(logs, "W careerMP.connection: UI.showMdDialog missing"), 1, "missing hook logged")
	watch.onCareerActive(true)
	frames(watch, 11)
	local _, count = lastLost()
	same(count, 1, "alarm from silence")
end)

--== recovering and rejoining ================================================

test("being heard again after a quiet spell clears the message", function()
	local watch = setup()
	watch.onCareerActive(true)
	frames(watch, 11)
	alive()
	same(#triggered("careerMPConnectionRestored"), 1, "restored events")
	local names = triggered("onBeamMPSetServerName")
	same(names[#names], "My Server", "session bar shows the server again")
	frames(watch, 11)
	local _, count = lastLost()
	same(count, 2, "a second silence alarms again")
end)

test("BeamMP's disconnect is never cleared by a late alive message", function()
	local watch = setup()
	watch.onCareerActive(true)
	disconnectDialog("")
	alive()
	same(#triggered("careerMPConnectionRestored"), 0, "restored events")
end)

test("after leaving and rejoining, the next career is watched again", function()
	local watch = setup()
	watch.onCareerActive(true)
	frames(watch, 11)
	watch.onBeamMPServerLeave()
	same(#triggered("careerMPConnectionRestored"), 1, "the message is cleared on leaving")
	watch.onCareerActive(true)
	frames(watch, 9)
	local _, count = lastLost()
	same(count, 1, "no alarm early in the new career")
	frames(watch, 2)
	_, count = lastLost()
	same(count, 2, "alarm in the new career")
end)

test("the player list can ask for the current state", function()
	local watch = setup()
	watch.onCareerActive(true)
	watch.sendState()
	same(#triggered("careerMPConnectionRestored"), 1, "connected state sent")
	frames(watch, 11)
	watch.sendState()
	local lost, count = lastLost()
	same(count, 2, "lost state sent again")
	same(lost.message, "Lost connection to the server", "message")
end)
