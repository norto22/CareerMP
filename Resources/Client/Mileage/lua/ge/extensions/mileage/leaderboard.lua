--Mileage :: the server leaderboard (CLIENT)
--
-- The server keeps race wins and every player's best drag run per strip (see the
-- Leaderboard section of the server plugin). This game reports its own player's drag
-- runs: when the game's drag racing fires dragRaceEndLineReached for the car the player
-- drives, at a strip Mileage's drag lobby knows, and the run is not disqualified, it sends
-- the strip, the elapsed time and the trap speed (mileageDragTime). The player list's
-- Leaderboard button asks for the top lists (request), which the prompts app shows
-- (guihook MileageLeaderboard).

local M = {}

local logTag = "mileage.leaderboard"

-- The same run is reported once, however often the game fires the hook for it.
local lastReport = nil

local function timerValue(timers, id)
	local timer = type(timers) == "table" and timers[id]
	if type(timer) == "table" and timer.isSet ~= false and type(timer.value) == "number" then return timer.value end
	return nil
end

--- The game's drag racing: a racer's car crossed the end line.
function M.dragRaceEndLineReached(vehId)
	local compat = extensions.mileage_compat
	if type(compat) ~= "table" or not compat.isMPSession() then return end
	if vehId == nil or vehId ~= be:getPlayerVehicleID(0) then return end
	if MPVehicleGE and type(MPVehicleGE.isOwn) == "function" and not MPVehicleGE.isOwn(vehId) then return end
	local lobby = extensions.mileage_dragLobby
	local strip = type(lobby) == "table" and type(lobby.getLocalStripId) == "function" and lobby.getLocalStripId()
	if type(strip) ~= "string" then return end
	local core = gameplay_drag_core
	local data = type(core) == "table" and type(core.getData) == "function" and core.getData()
	local racer = type(data) == "table" and type(data.racers) == "table" and data.racers[vehId]
	if type(racer) ~= "table" or racer.isDisqualified or racer.isDesqualified then return end
	local et = timerValue(racer.timers, data.importantTimerId or "time_1_4")
	if not et or et <= 0 then return end
	local trap = timerValue(racer.timers, "velAt_1_4") or 0
	local key = strip .. ":" .. string.format("%.4f", et)
	if lastReport == key then return end
	lastReport = key
	TriggerServerEvent("mileageDragTime", jsonEncode({strip = strip, et = et, trap = trap}))
end

--- Asks the server for the leaderboard; the prompts app shows the answer.
function M.request()
	TriggerServerEvent("mileageLeaderboard", "")
end

local function rxMileageLeaderboard(data)
	local top = jsonDecode(data)
	if type(top) ~= "table" then return end
	guihooks.trigger("MileageLeaderboard", top)
end

function M.onExtensionLoaded()
	if type(AddEventHandler) ~= "function" then
		log("E", logTag, "AddEventHandler unavailable - BeamMP not loaded")
		return
	end
	AddEventHandler("rxMileageLeaderboard", rxMileageLeaderboard)
	log("I", logTag, "Mileage leaderboard LOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
