--CareerMP :: parking challenges
--
-- On a mission start the game clears and reserves a parking challenge's spaces, but only
-- for the cars this game spawned. Another player's traffic and parked cars come from
-- their own game, which knows nothing about this challenge, so one of their parked cars
-- can sit in a space and the challenge cannot be finished.
--
-- While a parking challenge runs here, this extension holds a mode that careerMPEnabler
-- reads: every car the server marks as another player's traffic or parked car is kept
-- hidden on this game only. The cars other players drive stay as they are, and other
-- players' games are not touched. When the challenge stops for any reason, or the
-- player leaves the server, each car takes its owner's state again.
--
-- A mission counts as a parking challenge when its type names parking, or its folder
-- ships the parking-lot clutter layout parking challenges use. Every mission start logs
-- the type and the verdict, so a wrong guess shows in the game log.

local M = {}

local logTag = "careerMP.parkingChallenge"

local active = false

local function hasClutterLayout(folder)
	if type(folder) ~= "string" or type(FS) ~= "table" then return false end
	local base = folder .. "/parkingLotClutter"
	return FS:fileExists(base .. ".prefab.json") or FS:fileExists(base .. ".prefab") or false
end

local function isParkingChallenge(mission)
	local missionType = mission.missionType
	if type(missionType) == "string" and string.find(string.lower(missionType), "park", 1, true) then
		return true
	end
	return hasClutterLayout(mission.missionFolder) and true or false
end

local function setActive(on)
	if active == on then return end
	active = on
	log("I", logTag, on and "hiding other players' traffic and parked cars for the challenge"
		or "showing other players' traffic and parked cars again")
	if type(careerMPEnabler) == "table" and type(careerMPEnabler.reapplyRemoteStates) == "function" then
		careerMPEnabler.reapplyRemoteStates()
	end
end

--- true while a parking challenge runs on this game.
function M.isActive()
	return active
end

--- The game's mission manager: "started" with the mission, "stopped" when it ends.
function M.onAnyMissionChanged(state, mission)
	if state == "started" then
		if type(mission) ~= "table" then return end
		local parking = isParkingChallenge(mission)
		log("I", logTag, string.format("mission start: type=%s parking=%s", tostring(mission.missionType), tostring(parking)))
		setActive(parking)
	elseif state == "stopped" then
		setActive(false)
	end
end

local function stop()
	setActive(false)
end

M.onMissionStopped = stop
M.onMissionAbandoned = stop
M.onBeamMPServerLeave = stop
M.onExtensionUnloaded = stop

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
