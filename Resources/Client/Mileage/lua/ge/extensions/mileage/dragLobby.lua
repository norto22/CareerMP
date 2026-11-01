--Mileage :: drag lobby
--
-- The one part of multiplayer drag racing BeamNG did not write.
--
-- 0.39 ships the protocol, the state application, the phase machine, the UI and the
-- timeslip -- but all of it assumes a race already exists, with a `players` map and a
-- `queue` of heats. Deciding who is racing whom, in which lane, in what order is left
-- to the (unreleased) session layer. This is that decision-maker.
--
-- Design notes:
--
--  * No lobby UI. Driving up to a lane is the join signal: players drive up, stage and
--    race, which is what people expect on a freeroam server.
--
--    We work out where we are ourselves (scanForStrip) rather than waiting for poi.lua to
--    tell us. It looks like the obvious source -- it already calls the gamemode's
--    setContext when you drive into a lane trigger -- but it is a one-way door: see the
--    note on scanForStrip.
--
--  * One player at each strip decides everything for that strip: it builds the queue,
--    starts races and advances heats, so there is exactly one answer to "who is racing"
--    and "who won". Everyone else just reports where they are.
--
--    That authority is per strip, not per session, and is held only while the holder is
--    standing there. A session-wide host cannot work: every decision here is made by
--    reading the holder's OWN local drag state (core.getData()), so a host who is off
--    doing deliveries has no drag data and nobody at any strip can ever race.
--
--  * Presence expires, three ways. A player who drives away, disconnects or crashes out
--    must not hold a lane for ever, so joins carry a heartbeat and are dropped when
--    stale; presence also ends as soon as they leave the staging area, so an idle car can
--    simply be shoved aside; and a racer who will not stage is dropped from the heat after
--    STAGE_TIMEOUT, because the countdown waits for everyone and one AFK player would
--    otherwise close the strip to the whole server.

local M = {}

local logTag = "mileage.dragLobby"

-- How long a join stays valid without being refreshed.
local PRESENCE_TIMEOUT = 20
-- How often a client re-announces that it is still at the strip.
local PRESENCE_HEARTBEAT = 5
-- Grace period after a race finishes before the next heat is started.
local NEXT_HEAT_DELAY = 6
-- Longest we will wait for the result screen before tearing the race down anyway.
local FINALIZE_CAP = 18
-- How long the result screen stays up before the race winds itself up.
--
-- The panel auto-dismisses itself at about 7.8 s (dragRace/app.vue SLIDE_IN_MS + DRAIN_MS)
-- unless the player clicks it, so this is a little longer than that. Ending the race on a
-- timer rather than on the drive back means it finishes by itself, which is what it does
-- against AI.
local RESULT_LINGER = 12
-- How far from the stage line a player can be and still count as "at the strip".
--
-- Presence cannot be driven by the trigger alone. poi.lua's invisibleTrigger has only an
-- onInside -- there is no exit callback -- and it stops firing altogether once a race has
-- started (poi.lua:58 returns early on getDragIsStarted(), which in MP stays true after
-- the race ends). A player who simply drove off would therefore keep announcing presence
-- for ever: holding a lane, and, if they arrived first, holding the strip's authority.
--
-- Set above the distance at which the trigger actually fires in game (measured at roughly
-- 20-30 m, larger than the radius=6 in poi.lua suggests), so nobody genuinely sitting on
-- the line is ever dropped. Keeping it this tight is what makes shoving an idle car out
-- of the way work: clear the radius and their presence goes with them.
local STAGE_LANE_RADIUS = 40
-- How close to a stage line counts as arriving.
--
-- Deliberately smaller than STAGE_LANE_RADIUS: the two form a hysteresis band, so a car
-- idling near the boundary does not flicker in and out of the roster.
local JOIN_RADIUS = 25
-- How often we look around for a strip. A handful of distance checks, but no reason to do
-- it every frame.
local SCAN_INTERVAL = 0.5
-- How long the authority waits for everyone in a heat to stage before giving up on them.
--
-- The countdown only fires when phaseHandlers.areAllRacersStaged is true, so one player
-- who drives up and then wanders off keeps the tree from ever going and blocks the strip
-- for everybody else. Long enough to fix a bad approach and roll back onto the line.
local STAGE_TIMEOUT = 60
-- How long to wait for a second player before falling back to a solo run.
--
-- 8 seconds was far too short: two people driving to the strip separately arrive well
-- over that apart, so the first player's solo race started and locked the second one
-- out entirely. Long enough that anyone heading over together gets a real race, short
-- enough that a lone player is not left waiting.
local SOLO_GRACE = 45

--- Authority-side only: who is currently at which strip and lane.
--- presence[stripId][playerId] = { lane, vehicleId, persona, lastSeen }
local presence = {}

--- Authority-side: the race we have created per strip, so we do not create two.
local activeRaceByStrip = {}

--- Authority-side: when a lone player started waiting at a strip, for the solo fallback.
local soloWaitStartedAt = {}

--- Authority-side: players dropped for not staging, and where they were when dropped.
--- stageBlocked[stripId][playerId] = vec3
---
--- Without this, dropping an idle player achieves nothing: their client is still at the
--- strip and still heart-beating, so they rejoin within PRESENCE_HEARTBEAT seconds, the
--- race re-forms around them and blocks again -- a loop that never lets anyone race.
---
--- The block lifts when they *move*, not after a timer. That is the actual question being
--- asked ("are you still parked there?"), it re-admits a player the moment they come back
--- and drive, and it means ramming an idle car aside both frees the lane and clears the
--- block in one go.
local stageBlocked = {}
-- How far a blocked player must move to be let back in.
local STAGE_UNBLOCK_DISTANCE = 5

--- Strip definitions are NEVER sent over the wire.
---
--- The first attempt embedded the whole definition -- every lane zone vertex included --
--- in the join and in the race snapshot. That is ~15 KB, which BeamMP's event transport
--- truncates, so the server rejected it outright:
---
---     [LUA ERROR] string given to JsonDecode is not valid json: {"to":"host", ...
---
--- and no client ever learned a race existed. Every machine already has every strip on
--- disk, so an identifier is enough: gameplay_drag_core.getDragDataForLevel() returns
--- them all, each tagged with _fnWithoutExt and id.
local stripCache = {}

local function resolveStripData(stripId)
	if stripCache[stripId] then return stripCache[stripId] end
	local core = gameplay_drag_core
	if not core or not core.getDragDataForLevel then return nil end
	local levelId = getCurrentLevelIdentifier and getCurrentLevelIdentifier()
	if not levelId then return nil end
	local list = core.getDragDataForLevel(levelId)
	if not list then return nil end
	for _, data in pairs(list) do
		local key = data.id or data._fnWithoutExt
		if key then stripCache[key] = data end
	end
	return stripCache[stripId]
end

M.resolveStripData = resolveStripData

--- Every strip on the current level, as a list we can walk.
local stripList = nil
local stripListLevel = nil

local function allStrips()
	local levelId = getCurrentLevelIdentifier and getCurrentLevelIdentifier()
	if not levelId then return {} end
	if stripList and stripListLevel == levelId then return stripList end

	local core = gameplay_drag_core
	if not core or not core.getDragDataForLevel then return {} end
	local list = core.getDragDataForLevel(levelId)
	if not list then return {} end

	-- Build into a local and only cache a non-empty result. Caching an empty list would
	-- pin it for the rest of the level: this can be called before the level's drag data
	-- exists, and every later scan would then find no strips at all.
	local built = {}
	for _, data in pairs(list) do
		local key = data.id or data._fnWithoutExt
		if key then
			stripCache[key] = data
			table.insert(built, data)
		end
	end
	if #built == 0 then return {} end

	stripList, stripListLevel = built, levelId
	return stripList
end

--- Client-side: the strip/lane we are currently standing in, if any.
local localContext = nil
local lastHeartbeat = 0
local lastScan = 0

local function transport() return mileage_dragTransport end
local function gamemode() return multiplayer_gamemodes_drag_drag end

--- Also false while a career drag mission is running.
---
--- The lobby must not touch a strip that a mission owns. Without this, driving to the line
--- for a BMRA event put us in the roster, SOLO_GRACE expired, and we started a multiplayer
--- race over the top of the mission's own AI race.
local function isEnabled()
	local gm = gamemode()
	if gm == nil or not gm.isEnabled() then return false end
	if gm.isMultiplayer and not gm.isMultiplayer() then return false end
	return true
end

--- Do we hold the strip? Only the holder acts on presence for it.
local function isAuthorityFor(stripId)
	local t = transport()
	return stripId ~= nil and t ~= nil and t.isAuthorityFor(stripId)
end

local function localPlayerId()
	local t = transport()
	return t and t.bridge.getLocalPlayerId() or nil
end

local function now()
	return os.clockhp()
end

--== client side: announcing presence =========================================

local function stagePositionOf(stripData, laneIndex)
	local lanes = stripData and stripData.strip and stripData.strip.lanes
	local lane = lanes and lanes[laneIndex]
	local stage = lane and lane.waypoints and lane.waypoints.stage
	local pos = stage and stage.transform and stage.transform.position
	return pos and vec3(pos) or nil
end

--- Called from the gamemode when poi.lua reports we are inside a lane trigger.
---
--- This fires every frame we sit in the trigger, not once on entry, so it must stay
--- cheap and must not re-announce on every call.
function M.setLocalContext(stripData, laneIndex)
	if not isEnabled() then return end
	local stripId = stripData and (stripData.id or stripData._fnWithoutExt)
	if not stripId or not laneIndex then return end

	if localContext and localContext.stripId == stripId and localContext.lane == laneIndex then
		return
	end

	-- Refuse a context whose stage position we cannot resolve. hasLeftStrip returns false
	-- unconditionally when stagePos is nil, so such a context could never be released --
	-- we would hold the lane, and possibly the strip's authority, for the whole session.
	local stagePos = stagePositionOf(stripData, laneIndex)
	if not stagePos then
		log("W", logTag, string.format(
			"cannot resolve the stage position for '%s' lane %d - not claiming the strip",
			stripId, laneIndex))
		return
	end

	-- Check the distance HERE, not only in scanForStrip.
	--
	-- This is a public function and it claims the strip on the wire immediately, so the
	-- distance rule has to be an invariant of the claim rather than a property of one
	-- caller. In the 31/07 session the laptop claimed alderStrip 0.07 ms after its car
	-- spawned, while the logged spawn transform was 1161 m away -- impossible for
	-- scanForStrip, whose gate is 25 m. Some other path reached this function, and the
	-- result was a client a kilometre away holding that strip's authority for 20 seconds.
	--
	-- Refusing the claim costs nothing when the caller is honest (scanForStrip is already
	-- inside 25 m, and the legitimate poi.lua path only fires inside a 6 m trigger), and
	-- the warning names the next occurrence instead of leaving it to inference.
	local vehicleId = be:getPlayerVehicleID(0)
	local veh = vehicleId and vehicleId ~= -1 and be:getObjectByID(vehicleId)
	if not veh then return end

	local dist = stagePos:distance(veh:getPosition())
	if dist > STAGE_LANE_RADIUS then
		log("W", logTag, string.format(
			"refusing to claim '%s' lane %d from %.1f m away (limit %d) - the caller is not scanForStrip",
			stripId, laneIndex, dist, STAGE_LANE_RADIUS))
		return
	end

	localContext = {
		stripId = stripId,
		lane = laneIndex,
		stripData = stripData,
		stagePos = stagePos,
	}

	log("I", logTag, string.format("at strip '%s' lane %d (%.1f m from the stage line)",
		stripId, laneIndex, dist))

	-- Coming back to the lane is what clears the last result, exactly as in single player.
	--
	-- poi.lua:52-56 does this on the way back in, but its branch is gated on NOT being
	-- multiplayer, so on the MP path nothing ever cleared it and the finished race stayed
	-- on screen. Doing it here keeps the result up for as long as the driver wants to read
	-- it, and leaves the strip clean by the time they line up again.
	local c = gameplay_drag_core
	local data = c and c.getData and c.getData()
	if data and data.racers and next(data.racers) then
		local gm = gamemode()
		-- isCompleted is cleared by the reset and can never come back (core.lua:1181 sets
		-- it false, and headsUpRace.lua:92-93 clears hasActivityStarted in the same block
		-- so :62 returns early for ever after). allRacersFinished is structurally false in
		-- MP, because the remote stub is created isFinished = false and headsUpRace.lua:76
		-- skips remote racers before any phase function could set it. The mod's own
		-- finalise latch is the only one of the three that can actually fire; the other two
		-- are kept because they are correct when they do hold.
		local finished = data.isCompleted
			or (gm and gm.isRaceFinalized and gm.isRaceFinalized())
			or (c.allRacersFinished and c.allRacersFinished(data))
		if finished and gm and gm.tearDownRaceUI then gm.tearDownRaceUI() end
	end
	M.announcePresence(true)
end

--- The strip we are standing at, if any. The transport asks this to decide whether we
--- are the authority, since a player is only ever at one strip.
function M.getLocalStripId()
	return localContext and localContext.stripId or nil
end

function M.clearLocalContext()
	if localContext then
		-- Say how far, and in which vehicle. On 01/08 a car parked 1.5 m from the line was
		-- dropped 29 s later with no vehicle event in the log: either it rolled past
		-- STAGE_LANE_RADIUS or be:getPlayerVehicleID(0) started answering with a different
		-- object. "left the strip" alone cannot tell those apart.
		local vehicleId = be:getPlayerVehicleID(0)
		local veh = vehicleId and vehicleId ~= -1 and be:getObjectByID(vehicleId)
		local dist = (veh and localContext.stagePos)
			and localContext.stagePos:distance(veh:getPosition()) or -1
		log("I", logTag, string.format("left the strip (%.1f m from the stage line, vehicle %s)",
			dist, tostring(vehicleId)))
		local t = transport()
		if t then
			t.send("mileageDragLeave", "host", { stripId = localContext.stripId })
		end

		-- Driving away clears the strip's leftovers, the way it does in single player.
		--
		-- poi.lua:52 and core.lua:1322 both do this on the way out, and both are gated on
		-- NOT being multiplayer, so on the MP path nothing did -- the finished race just
		-- stayed on screen until a timer got round to it.
		local c = gameplay_drag_core
		local data = c and c.getData and c.getData()
		if data and data.racers and next(data.racers) then
			local gm = gamemode()
			if gm and gm.isRaceOver and gm.isRaceOver() and gm.tearDownRaceUI then
				gm.tearDownRaceUI()
			end
		end
	end
	localContext = nil
end

--- Is *our* run actually under way? While it is, the car is legitimately far from the
--- stage line, so distance says nothing about whether we are still taking part.
---
--- It takes BOTH tests, and each covers a hole the other has.
---
--- core.getDragIsStarted() alone is too early: headsUpRace.startActivity sets
--- dragData.isStarted the moment the race object is created, well before anyone stages, so
--- keying off it would suspend the distance check during exactly the window in which
--- shoving an idle car aside has to register.
---
--- The per-racer test alone never ends: onDragRaceReset clears isStarted and isCompleted
--- (core.lua:622) and touches nothing else, so treeStarted and currentPhase keep their
--- end-of-race values for the rest of the session. That left the guard suspended for ever
--- and let two finished players re-claim the strip from 419 m away.
---
--- Together they bracket it properly: the race object exists AND the tree has gone for us.
--- The window runs from the tree going to the race being reset -- deliberately including
--- the part after we cross the line.
---
--- Ending it at isFinished would drop our context the instant we finished, 400 m from the
--- line, while the game is still asking the strip's authority to work out results
--- (core.lua:953, :1028, :1260 all gate on isServerHost). The race is not over when the
--- first car finishes; it is over when it is reset, which is when treeStarted and
--- currentPhase go back to their staging values on every client.
local function inLiveRace()
	-- Finished or written off: not racing, whatever the racer state still says.
	local gm = gamemode()
	if gm and gm.isRaceOver and gm.isRaceOver() then return false end

	local core = gameplay_drag_core
	-- dragData.isStarted is the only part of the racer state a reset actually clears
	-- (core.lua:622, via onDragRaceReset). racer.treeStarted and racer.currentPhase are
	-- left exactly as the race ended, so keying only off those made this function true for
	-- the rest of the session: the distance guard stayed permanently suspended, and both
	-- players re-joined the roster from 419 m down the strip 2.8 s after finishing --
	-- forming a new race neither of them could stage for.
	if not core or not core.getDragIsStarted or not core.getDragIsStarted() then return false end
	local data = core.getData and core.getData()
	if not data or not data.racers then return false end

	local vehicleId = be:getPlayerVehicleID(0)
	local racer = vehicleId and vehicleId ~= -1 and data.racers[vehicleId]
	if not racer then return false end

	return racer.treeStarted == true or (racer.currentPhase or 1) > 1
end

function M.announcePresence(force)
	if not isEnabled() or not localContext then return end
	local t = transport()
	if not t then return end

	local vehicleId = be:getPlayerVehicleID(0)
	if not vehicleId or vehicleId == -1 then return end

	-- Never claim a lane from outside the staging area -- unless a run is under way.
	--
	-- The heartbeat is not just a keep-alive; onJoin re-adds us to the roster from it. So
	-- after a run, when the authority has taken the finishers off the roster, its own next
	-- heartbeat would put it straight back on while sitting 430 m down the strip. The
	-- authority-change handler re-announces unconditionally too, which is how a car 321 m
	-- away came to claim the strip in the 01/08 log.
	--
	-- The inLiveRace() exemption is not optional, and leaving it out cost a whole test
	-- round: during a run the car is legitimately a quarter mile away, so the guard stopped
	-- the heartbeat, PRESENCE_TIMEOUT pruned BOTH racers 24 s in -- the authority included
	-- -- and pruneStalePresence discarded the race mid-run. It got as far as
	-- "player 1 timed out at strip 'alderStrip'" with the cars still rolling.
	local veh = be:getObjectByID(vehicleId)
	if not veh then return end
	if not inLiveRace() and localContext.stagePos
		and localContext.stagePos:distance(veh:getPosition()) > STAGE_LANE_RADIUS then
		return
	end

	local payload = {
		stripId = localContext.stripId,
		lane = localContext.lane,
		vehicleId = vehicleId,
		persona = MPConfig and MPConfig.getNickname and MPConfig.getNickname() or nil,
	}

	-- Where we are, so the authority can tell a player who came back and moved from one
	-- who is still parked in the same spot. Three floats; the payload stays tiny.
	local pos = veh:getPosition()
	payload.pos = { pos.x, pos.y, pos.z }
	t.send("mileageDragJoin", "host", payload)
	lastHeartbeat = now()
end


local function hasLeftStrip()
	if not localContext or not localContext.stagePos then return false end
	if inLiveRace() then return false end

	-- No resolvable vehicle is NOT the same as "left the strip". It happens routinely --
	-- career respawn, the vehicle shop, insurance, walking mode -- and answering "left"
	-- here would tear down presence and hand the strip's authority away over a one-frame
	-- gap. Say nothing instead: announcePresence bails on the same condition, so the
	-- heartbeat stops on its own and the authority drops us via PRESENCE_TIMEOUT if we
	-- really are gone. That is the slower answer, and the correct one.
	local vehicleId = be:getPlayerVehicleID(0)
	if not vehicleId or vehicleId == -1 then return false end
	local veh = be:getObjectByID(vehicleId)
	if not veh then return false end

	return localContext.stagePos:distance(veh:getPosition()) > STAGE_LANE_RADIUS
end

--- Work out for ourselves whether we are standing at a strip.
---
--- poi.lua cannot be trusted with this, which is what broke every two-player test so far.
--- Its invisibleTrigger.onInside returns early on core.getDragIsStarted() (poi.lua:58),
--- and the only thing in the whole game that clears dragData.isStarted is onDragRaceReset
--- (core.lua:622). So the moment a client has taken part in one race and then leaves
--- before a reset reaches it -- driving away, handing over the authority, disconnecting
--- mid-race -- setContext is never called on that client again for the rest of the
--- session. It cannot rejoin any strip, and the authority reports "no players waiting"
--- for ever.
---
--- We do not need to be told: every machine has every strip on disk. This is a few
--- distance checks twice a second, and it depends on nothing that a race can leave in a
--- bad state.
local function scanForStrip()
	local vehicleId = be:getPlayerVehicleID(0)
	if not vehicleId or vehicleId == -1 then return end
	local veh = be:getObjectByID(vehicleId)
	if not veh then return end

	local pos = veh:getPosition()
	local bestData, bestLane, bestDist

	for _, data in ipairs(allStrips()) do
		local lanes = data.strip and data.strip.lanes
		for laneIndex = 1, (lanes and #lanes or 0) do
			local stagePos = stagePositionOf(data, laneIndex)
			if stagePos then
				local dist = stagePos:distance(pos)
				if dist <= JOIN_RADIUS and (not bestDist or dist < bestDist) then
					bestData, bestLane, bestDist = data, laneIndex, dist
				end
			end
		end
	end

	if bestData then M.setLocalContext(bestData, bestLane) end
end

--== host side: presence bookkeeping ==========================================

local function pruneStalePresence()
	local cutoff = now() - PRESENCE_TIMEOUT
	for stripId, players in pairs(presence) do
		for playerId, entry in pairs(players) do
			if entry.lastSeen < cutoff then
				log("I", logTag, string.format("player %s timed out at strip '%s'",
					tostring(playerId), stripId))
				players[playerId] = nil
			end
		end
		if not next(players) then
			-- Drop the strip's race with it. Leaving activeRaceByStrip set would strand a
			-- finished race on a strip nobody is at, and the next arrival would be met with
			-- tryAdvanceHeat running against it instead of a race of their own.
			--
			-- stageBlocked deliberately survives: the player who emptied the strip by not
			-- staging is usually still parked on it, and clearing their block here would
			-- re-admit them on their very next heartbeat.
			presence[stripId] = nil
			activeRaceByStrip[stripId] = nil
			soloWaitStartedAt[stripId] = nil
		end
	end
end

--- Has a player we dropped for idling moved since we dropped them?
local function clearsStageBlock(stripId, playerId, data)
	local blocked = stageBlocked[stripId] and stageBlocked[stripId][playerId]
	if not blocked then return true end

	local p = data.pos
	if not p or not p[1] then
		-- No position reported: an older client, or no vehicle. Nothing to judge them on,
		-- so let them back in rather than blocking them for ever.
		stageBlocked[stripId][playerId] = nil
		return true
	end

	if blocked:distance(vec3(p[1], p[2], p[3])) < STAGE_UNBLOCK_DISTANCE then
		return false
	end

	log("I", logTag, string.format("player %s moved - allowing them back at strip '%s'",
		tostring(playerId), stripId))
	stageBlocked[stripId][playerId] = nil
	return true
end

local function onJoin(playerId, data)
	if not data or not isAuthorityFor(data.stripId) then return end
	if not clearsStageBlock(data.stripId, playerId, data) then return end
	presence[data.stripId] = presence[data.stripId] or {}
	local existing = presence[data.stripId][playerId]
	presence[data.stripId][playerId] = {
		lane = data.lane,
		-- Diagnostic only. This is the sender's own scenetree id and means nothing on this
		-- machine; the racer key is racerKeyFor(playerId). See the note there.
		vehicleId = data.vehicleId,
		persona = data.persona,
		pos = data.pos and vec3(data.pos[1], data.pos[2], data.pos[3]) or nil,
		-- joinedAt is when they first arrived and fixes their place in the queue;
		-- lastSeen is refreshed by every heartbeat and only decides staleness. Bumping
		-- joinedAt on each heartbeat would keep re-shuffling the running order.
		joinedAt = existing and existing.joinedAt or now(),
		lastSeen = now(),
	}
	if not existing then
		log("I", logTag, string.format("player %s joined strip '%s' in lane %s",
			tostring(playerId), data.stripId, tostring(data.lane)))
	end
end

local function onLeave(playerId, data)
	if not data or not isAuthorityFor(data.stripId) then return end
	local players = presence[data.stripId]
	if players then players[playerId] = nil end
end

--== host side: building a race ===============================================

--- Turns the players present at a strip into a queue of heats.
---
--- One heat per pair of lanes, in lane order, so two players standing in lanes 1 and 2
--- race each other. Extra players queue behind them and the UI shows them as a waiting
--- list (dragBridge builds that from exactly this structure).
local function buildQueue(players, laneCount)
	laneCount = math.max(laneCount or 2, 2)

	-- Order by arrival, NOT by lane.
	--
	-- Sorting by lane groups every lane-1 player together and every lane-2 player after
	-- them, so with three players you get heat 1 = [p1 vs nobody] and heat 2 = [p3 vs p2]
	-- -- the wrong opponents, and a pointless solo heat first. Arrival order pairs the
	-- people who actually rolled up together, which is what they expect.
	local ordered = {}
	for playerId, entry in pairs(players) do
		table.insert(ordered, {
			playerId = playerId,
			lane = entry.lane,
			joinedAt = entry.joinedAt or entry.lastSeen,
		})
	end
	table.sort(ordered, function(a, b)
		if a.joinedAt ~= b.joinedAt then return a.joinedAt < b.joinedAt end
		return tostring(a.playerId) < tostring(b.playerId) -- stable for equal timestamps
	end)

	-- Each heat is a dense array of { lane, playerId }, for the same serialisation reason
	-- buildPlayersTable is: a lane-keyed heat holding only lane 2 encodes as the object
	-- {"2":pid} and slot[2] misses on every remote. normalizeIncoming rebuilds the
	-- lane-keyed form the handlers read.
	local queue = {}
	local heat = {}
	local usedLanes = {}
	for _, item in ipairs(ordered) do
		local lane = item.lane
		-- If this lane is already taken in the current heat, the player waits for the next.
		if lane and usedLanes[lane] then
			table.insert(queue, heat)
			heat, usedLanes = {}, {}
		end
		if lane then
			table.insert(heat, { lane = lane, playerId = item.playerId })
			usedLanes[lane] = true
		end
		if #heat >= laneCount then
			table.insert(queue, heat)
			heat, usedLanes = {}, {}
		end
	end
	if #heat > 0 then table.insert(queue, heat) end
	return queue
end

--- The key a player's racer has in dragData.racers, on every machine.
---
--- NOT the vehicle id they reported. A vehicle id is a scenetree id, local to the machine
--- that produced it: it means nothing on anyone else's, and two players can easily both be
--- driving id 12345. core.lua:1113 does setupRacer(pd.vehicleId, lane) straight from the
--- snapshot, so two colliding ids would collapse into a single racer and the heat would
--- register one car instead of two.
---
--- So the snapshot carries a synthetic id derived from the player id -- identical on every
--- machine, and negative, which is what the shipped code already looks for when it decides
--- whether a racer is a remote stub (phaseHandlers.lua:419). core.lua:1126-1140 then swaps
--- the local player's stub for their real vehicle, which is exactly what it was written to
--- do. Offset by 2 because -1 is BeamNG's "vehicle id unknown" sentinel.
local function racerKeyFor(playerId)
	return -(playerId + 2)
end

--- The racer key for a player *on this machine*, where our own car is real, not a stub.
local function localRacerKeyFor(playerId)
	if playerId == localPlayerId() then
		local vehicleId = be:getPlayerVehicleID(0)
		if vehicleId and vehicleId ~= -1 then return vehicleId end
	end
	return racerKeyFor(playerId)
end

--- The race snapshot's player list.
---
--- A dense ARRAY, not a map keyed by player id, and every record carries its own
--- playerId. This is forced by how the payload is serialised: jsonEncode_rec
--- (lua/common/utils.lua) only emits a JSON array when the table's first key is 1 and
--- the keys run 1..#t. Player ids are 0,1,2..., so an id-keyed map takes the object
--- branch and every key is written as a STRING. On the receiving client
--- `players[localPlayerId]` is then a number lookup against string keys and always
--- misses -- mpDragHandlers.lua:33 skips setLocalClientActiveRace, core.lua:1114 skips
--- the per-lane setup, and control falls through to the core.lua:1120 fallback that
--- registers every racer in lane 1. Two cars, same lane, two solo heats.
---
--- `lane` is equally load-bearing and was missing entirely. core.lua:1135 gates the ONE
--- path that swaps the local player's synthetic stub for their real vehicle on
--- `if pd and pd.lane then`. Without it every racer stays a stub with no vehObj, so no
--- stage beam is ever read, phases[1].completed is never set, areAllRacersStaged can
--- never return true, and the countdown never fires -- the strip just sits there until
--- the stage timeout drops everyone. That was the whole failure.
---
--- mileage_dragTransport.normalizeIncoming turns this back into the id-keyed map the
--- shipped handlers expect, on the wire path and the local-apply path alike.
local function buildPlayersTable(players)
	local out = {}
	for playerId, entry in pairs(players) do
		table.insert(out, {
			playerId = playerId,
			lane = entry.lane,
			vehicleId = racerKeyFor(playerId),
			persona = entry.persona or ("Player " .. tostring(playerId)),
		})
	end
	table.sort(out, function(a, b) return tostring(a.playerId) < tostring(b.playerId) end)
	return out
end

--- Who is at the strip, and in which lane, as one comparable string.
---
--- The rebuild used to trigger on player COUNT alone, which misses the case that
--- actually happened: two cars both reported lane 1 from the approach road, the queue
--- became two solo heats, and when one of them rolled into lane 2 the count was still 2
--- so the queue was never rebuilt. They stayed in separate heats at an empty strip.
local function rosterFingerprint(players)
	local parts = {}
	for playerId, entry in pairs(players) do
		table.insert(parts, tostring(playerId) .. ":" .. tostring(entry.lane))
	end
	table.sort(parts)
	return table.concat(parts, ",")
end

local function countPlayers(players)
	local n = 0
	for _ in pairs(players) do n = n + 1 end
	return n
end

--- Everyone standing at this strip, except us.
---
--- Race messages used to go to "all". That meant every player on the server received
--- state for a race they were not in, and the shipped handlers rightly refused it --
--- "onDragRaceStarted: raceState nil for raceId=..." in the log of anyone doing
--- deliveries at the other end of the map. Only the people at the strip need it.
local function recipientsFor(stripId)
	local ids = {}
	local own = localPlayerId()
	for playerId in pairs(presence[stripId] or {}) do
		if playerId ~= own then table.insert(ids, playerId) end
	end
	return ids
end

--- Send to everyone at the strip, then apply the same message to ourselves.
---
--- The authority is a racer too, and applying locally means it walks the identical code
--- path as every other client -- one flow to reason about instead of two. The send comes
--- first because applying mutates the payload (hydrateStripData attaches the 15 KB strip
--- definition, which must never go on the wire).
local function broadcast(stripId, msgName, payload)
	local t = transport()
	if not t then return end
	local ids = recipientsFor(stripId)
	if #ids > 0 then t.send(msgName, ids, payload) end
	M.applyLocally(msgName, payload)
end

--- Creates the race and tells everyone about it.
---
--- dragSessionStarted carries the full snapshot (the handler uses it to build local race
--- state and load the strip), then dragRaceStarted flips it live.
local function startRace(stripId, players)
	if not transport() then return end

	local stripData = resolveStripData(stripId)
	if not stripData then
		log("W", logTag, string.format("cannot resolve strip '%s' locally - not starting", stripId))
		return
	end

	local laneCount = 2
	if stripData and stripData.strip and stripData.strip.lanes then
		laneCount = #stripData.strip.lanes
	end

	local raceId = string.format("%s-%d", stripId, math.floor(now() * 1000) % 1000000)
	local queue = buildQueue(players, laneCount)
	local playersTable = buildPlayersTable(players)

	activeRaceByStrip[stripId] = {
		raceId = raceId,
		startedAt = now(),
		playerCount = countPlayers(players),
		roster = rosterFingerprint(players),
	}

	local snapshot = {
		id = raceId,
		poiKey = stripId,
		lobbyId = stripId,
		creatorId = localPlayerId(),
		players = playersTable,
		queue = queue,
		currentPairIndex = 1,
		isStarted = false,
		treeType = (stripData and stripData.prefabs and stripData.prefabs.christmasTree
			and stripData.prefabs.christmasTree.treeType) or ".500",
		-- poiData is deliberately absent: each client hydrates it from poiKey locally.
	}

	log("I", logTag, string.format("starting race '%s' at '%s' with %d player(s), %d heat(s)",
		raceId, stripId, countPlayers(players), #queue))

	broadcast(stripId, "dragSessionStarted", {
		raceId = raceId,
		lobbyId = stripId,
		creatorId = snapshot.creatorId,
		race = snapshot,
	})
	broadcast(stripId, "dragRaceStarted", { raceId = raceId })

	-- Dump what the game built from that snapshot.
	--
	-- The 01/08 session formed a correct race -- "2 player(s), 1 heat(s)" -- and then
	-- registered exactly one racer, so the countdown fired a second later and the
	-- authority ran alone. Every failure path in core.onDragRaceStarted logs an error and
	-- none appeared, so the loss is silent and none of the existing lines can see it.
	-- Print the roster we sent and the racers that came back, side by side.
	local dragData = gameplay_drag_core and gameplay_drag_core.getData()
	local racers = dragData and dragData.racers or {}
	local laneCount = dragData and dragData.strip and dragData.strip.lanes
		and #dragData.strip.lanes or -1
	local desc = {}
	for vehId, racer in pairs(racers) do
		table.insert(desc, string.format("[%s]=lane %s isLocal=%s phase=%s",
			tostring(vehId), tostring(racer.lane), tostring(racer.isLocalRacer),
			tostring(racer.currentPhase)))
	end
	table.sort(desc)
	log("I", logTag, string.format("race '%s': sent %d player(s) in %d heat(s); strip has %d lane(s); %d racer(s) registered: %s",
		raceId, countPlayers(players), #queue, laneCount, #desc,
		#desc > 0 and table.concat(desc, "  ") or "NONE"))
	for _, item in ipairs(queue[1] or {}) do
		log("I", logTag, string.format("  heat 1 slot: lane %s -> player %s (racer key %s)",
			tostring(item.lane), tostring(item.playerId), tostring(racerKeyFor(item.playerId))))
	end

	-- And the id types, which is the one question the audit could not settle from logs.
	--
	-- core.lua:1134 does `players[drag.getLocalPlayerId()]`, and that is the only gate on
	-- creating a real (non-stub) racer for our own car. A number key against a string id --
	-- or the reverse -- misses silently and leaves us as a stub that can never stage.
	-- Printing both sides makes the mismatch, if there is one, impossible to miss.
	local raceState = gameplay_drag_core and gameplay_drag_core.getRaceState
		and gameplay_drag_core.getRaceState(raceId)
	local keys = {}
	for k in pairs(raceState and raceState.players or {}) do
		table.insert(keys, string.format("%s(%s)", tostring(k), type(k)))
	end
	table.sort(keys)
	local own = localPlayerId()
	log("I", logTag, string.format("  raceState.players keys: %s | localPlayerId = %s(%s)",
		#keys > 0 and table.concat(keys, ", ") or "NONE", tostring(own), type(own)))
end

--- Feeds a message into the shipped handlers as though it had arrived over the wire.
function M.applyLocally(msgName, data)
	local t = transport()
	if not t then return end
	local handlers = gameplay_drag_mpDragHandlers
	if not handlers or not handlers.handle then return end
	-- Exactly what the remote path does: rebuild the wire shape into the maps the shipped
	-- handlers read, and resolve the strip. The authority must take the identical path.
	if t.normalizeIncoming then t.normalizeIncoming(msgName, data) end
	local ok, err = pcall(handlers.handle, msgName, t.getState(), t.bridge,
		{ id = localPlayerId() }, localPlayerId(), nil, data)
	if not ok then
		log("E", logTag, string.format("local apply of %s failed: %s", msgName, tostring(err)))
	end
end

--== host side: starting the countdown ========================================

--- The strip's authority owns the countdown, because everyone must see the same tree.
---
--- Each client reports its own staging to the authority, which marks the lane staged
--- after the same one-second hold single player uses (phaseHandlers.setRemoteStagingState).
--- Once every racer in the heat is staged, the authority picks the start time *and* the
--- random amber delay and ships both -- the shared randValue is what stops each client
--- randomising its own tree and diverging.
--- Who in this heat has not staged? Keyed by player, so it can be acted on.
---
--- Players in `presence` who are not in the current heat have no racer entry and are
--- skipped -- waiting your turn is not the same as refusing to stage.
local function unstagedPlayers(stripId)
	local core = gameplay_drag_core
	local dragData = core and core.getData and core.getData()
	if not dragData or not dragData.racers then return {} end

	local out = {}
	for playerId in pairs(presence[stripId] or {}) do
		local racer = dragData.racers[localRacerKeyFor(playerId)]
		if racer and not racer.isFinished then
			local staged = racer.currentPhase == 1
				and racer.phases and racer.phases[1] and racer.phases[1].completed
			if not staged then out[playerId] = true end
		end
	end
	return out
end

--- Nobody has staged in STAGE_TIMEOUT seconds: drop whoever is holding it up.
---
--- They are removed from presence, which the roster check in authorityUpdate then sees as
--- a change and rebuilds the race without them, and blocked until they move so they
--- cannot immediately rejoin and block the next one too.
local function dropUnstagedPlayers(stripId)
	local players = presence[stripId]
	if not players then return end

	stageBlocked[stripId] = stageBlocked[stripId] or {}
	local own = localPlayerId()
	for playerId in pairs(unstagedPlayers(stripId)) do
		log("I", logTag, string.format("player %s has not staged at '%s' in %ds - dropping them",
			tostring(playerId), stripId, STAGE_TIMEOUT))

		-- Drop, but never block ourselves. We are the strip's authority, and a block is
		-- only lifted by moving 5 m: blocking our own heartbeat would leave us holding a
		-- strip we are refusing to join, silently, until we happened to drive off. That
		-- is exactly what happened at 1104.27915 in the logged session. Dropping alone is
		-- enough -- the race rebuilds without us and our next heartbeat re-adds us.
		if playerId ~= own then
			stageBlocked[stripId][playerId] = players[playerId] and players[playerId].pos or vec3(0, 0, 0)
		end
		players[playerId] = nil
	end
end

local function tryStartCountdown(stripId, race)
	if race.countdownSent then return end

	local ph = gameplay_drag_phaseHandlers
	local core = gameplay_drag_core
	if not ph or not ph.areAllRacersStaged or not core then return end

	local dragData = core.getData()
	if not dragData or not dragData.racers or not next(dragData.racers) then return end

	local allStaged, stagedCount, totalCount = ph.areAllRacersStaged(dragData)
	if not allStaged or (totalCount or 0) < 1 then
		race.stagingSince = race.stagingSince or now()
		if (now() - race.stagingSince) >= STAGE_TIMEOUT then
			race.stagingSince = nil
			dropUnstagedPlayers(stripId)
		end
		return
	end

	race.countdownSent = true

	local payload = {
		type = "countdownStart",
		raceId = race.raceId,
		startTime = now(),
		-- Matches the range display.lua uses for its own tree delay.
		randValue = 0.6 + math.random() * 0.6,
	}

	log("I", logTag, string.format("all %d of %d racer(s) staged - starting countdown for '%s'",
		stagedCount or 0, totalCount or 0, race.raceId))

	-- Leave staging BEFORE the message is applied to us.
	--
	-- broadcast() sends and then applies locally, synchronously, and applying runs
	-- core.onDragRaceCountdownStart -- which on the authority advances nothing and then
	-- unconditionally burns racer.phases[2].started. If we are still in phase 1 at that
	-- moment, display.startDragCountdown discards the call and the tree never starts, for
	-- us or for anyone watching us. Advancing here makes the host's local ordering
	-- identical to every client's: advance, then apply.
	--
	-- Purely local state, so doing it before the send costs nothing on the wire.
	local gm = gamemode()
	if gm and gm.advanceOutOfStaging and gm.advanceOutOfStaging() then
		log("I", logTag, "advanced out of staging before the countdown (authority)")
	end

	broadcast(stripId, "dragRaceCountdownStart", payload)
end

--== host side: advancing to the next heat ====================================

--- Moves the queue on once everyone in the current heat has finished.
---
--- The sequence matters. dragRaceReset clears the finish times and timer values and,
--- via core.onDragRaceReset, clears lastStartedRaceId -- the guard that otherwise makes
--- a repeated dragRaceStarted a no-op. Only then does re-sending dragRaceStarted cause
--- core.onDragRaceStarted to read queue[currentPairIndex] and register the next pair.
--- The comment in core.lua is explicit about this: "Allow the same raceId to trigger
--- onDragRaceStarted again (next heat)".
local function tryAdvanceHeat(stripId, race)
	local core = gameplay_drag_core
	if not core then return end

	local dragData = core.getData()
	if not dragData or not dragData.racers or not next(dragData.racers) then return end

	local finished = dragData.isCompleted
		or (core.allRacersFinished and core.allRacersFinished(dragData))
	if not finished then
		race.finishedAt = nil
		return
	end

	-- Let the timeslip be read before wiping it.
	race.finishedAt = race.finishedAt or now()
	if (now() - race.finishedAt) < NEXT_HEAT_DELAY then return end

	-- And do not tear anything down until the result screen has actually been built.
	--
	-- The reset clears finishTimes and timerValues (mpDragHandlers.lua:251-252), the only
	-- source of the opponent's numbers. If it lands first, drag.lua clears timeslipPending
	-- and the finalise then returns early for ever -- no result at all, silently.
	-- NEXT_HEAT_DELAY alone is not enough, because cars are often still rolling to a stop
	-- when it expires. The cap stops a client that never finalises from pinning the strip.
	local gm = gamemode()
	if not (gm and gm.isRaceFinalized and gm.isRaceFinalized())
		and (now() - race.finishedAt) < FINALIZE_CAP then
		return
	end

	local raceState = core.getRaceState and core.getRaceState(race.raceId)

	-- Whoever just raced is at the FAR END of the strip, ~430 m from the stage line, so
	-- take them off the roster before anything is rebuilt from it.
	--
	-- Without this the authority completes the race and, on the very same tick, forms a
	-- brand new one around two cars that physically cannot stage -- they are a quarter
	-- mile away with their backs to the tree. That is what "stuck in a drag race" was:
	--
	--   271.41596  race 'alderStrip-217406' complete - all 1 heat(s) done
	--   271.42269  starting race 'alderStrip-271431' ... with 2 player(s), 1 heat(s)
	--   271.43130  left the strip (431.7 m from the stage line, vehicle 74748)
	--
	-- The distance check would have dropped them a tick later, but the new race had
	-- already formed. Drop them here, where we know for a fact that they finished: they
	-- drive back round and roll up again, exactly like single player.
	local racedSlot = raceState and raceState.queue
		and raceState.queue[raceState.currentPairIndex or 1]
	if racedSlot and presence[stripId] then
		for _, playerId in pairs(racedSlot) do
			if presence[stripId][playerId] then
				log("I", logTag, string.format(
					"player %s finished and is down the strip - off the roster until they come back",
					tostring(playerId)))
				presence[stripId][playerId] = nil
			end
		end
	end

	-- Rebuild from who is at the strip *now*, rather than reusing the queue this race
	-- started with. Anyone who turned up mid-race is then racing in the next heat
	-- instead of waiting for the whole race to end, and anyone who left stops holding
	-- a lane.
	local players = presence[stripId] or {}
	local stripData = resolveStripData(stripId)
	local laneCount = 2
	if stripData and stripData.strip and stripData.strip.lanes then
		laneCount = #stripData.strip.lanes
	end
	local queue = buildQueue(players, laneCount)
	local playersTable = buildPlayersTable(players)

	local nextIndex = (raceState and raceState.currentPairIndex or 1) + 1

	if nextIndex > #queue then
		-- Everyone has raced. Drop the race so a fresh one forms from whoever is still
		-- standing at the strip, rather than leaving a finished race pinned forever.
		log("I", logTag, string.format("race '%s' complete - all %d heat(s) done", race.raceId, #queue))

		-- Reset first, and only then forget it. Without this the racers stay in their
		-- finished state on every client for ever: treeStarted never goes back to false,
		-- so inLiveRace() stays true, so nobody's presence ever expires again and the
		-- strip fills up with people who left hours ago.
		--
		-- Deliberately no queue and no currentPairIndex. core.setRaceState is a plain merge
		-- over pairs(updates) (core.lua:842-844), so omitting a key leaves the stored value
		-- alone -- which is the whole point. Sending the freshly rebuilt queue shipped an
		-- EMPTY one (the finishers are off the roster by this line, hence "all 0 heat(s)
		-- done"), and dragBridge resolves every MP racer name through
		-- queue[currentPairIndex] (dragBridge.lua:593-603). With the slot gone it fell back
		-- to its single-player default and labelled the opponent "Bot" (dragBridge.lua:616).
		-- isStarted = false still fires, which is all this reset is actually needed for.
		broadcast(stripId, "dragRaceReset", {
			type = "dragRaceReset",
			raceId = race.raceId,
		})

		-- The UI is deliberately NOT torn down here.
		--
		-- This point is NEXT_HEAT_DELAY after the finish line, and the cars are usually
		-- still rolling to a stop. dragBridge.reset() clears the race state, the racers,
		-- the timeslip and the tree light staging, so doing it here destroyed the state
		-- the result screen is built from and put the staging lights back on screen
		-- instead. Each driver clears it by returning to the lane; see setLocalContext.
		activeRaceByStrip[stripId] = nil
		return
	end

	log("I", logTag, string.format("advancing '%s' to heat %d of %d",
		race.raceId, nextIndex, #queue))

	-- Push the refreshed roster first, so the reset's queue and the players map agree.
	local joinPayload = {
		type = "dragRacePlayerJoined",
		raceId = race.raceId,
		players = playersTable,
		queue = queue,
	}
	broadcast(stripId, "dragRacePlayerJoined", joinPayload)

	local resetPayload = {
		type = "dragRaceReset",
		raceId = race.raceId,
		queue = queue,
		currentPairIndex = nextIndex,
	}
	broadcast(stripId, "dragRaceReset", resetPayload)

	-- Re-arm: racers for the new heat are registered by onDragRaceStarted.
	broadcast(stripId, "dragRaceStarted", { raceId = race.raceId })

	race.countdownSent = false
	race.finishedAt = nil
	race.stagingSince = nil
end

--== authority side: the tick =================================================

local function forgetStrip(stripId)
	presence[stripId] = nil
	activeRaceByStrip[stripId] = nil
	soloWaitStartedAt[stripId] = nil
	stageBlocked[stripId] = nil
end

local function authorityUpdate()
	pruneStalePresence()

	for stripId, players in pairs(presence) do
		if not isAuthorityFor(stripId) then
			-- Not ours (any more). Forget the strip rather than acting on a roster we are
			-- no longer told about; whoever holds it now is hearing the heartbeats.
			forgetStrip(stripId)
			goto continue
		end

		local active = activeRaceByStrip[stripId]

		if not active then
			local count = countPlayers(players)
			if count >= 2 then
				-- Someone to race. Cancel any pending solo timer and start for real.
				soloWaitStartedAt[stripId] = nil
				startRace(stripId, players)

			elseif count == 1 then
				-- Alone at the strip.
				--
				-- This matters more than it looks. With MP drag active, poi.lua stops
				-- taking its singleplayer branch (shouldSyncState is true), so driving
				-- into a lane no longer starts a local race -- a lone player would just
				-- sit there. On a live server that is the common case, so the feature
				-- would make drag racing worse for almost everyone.
				--
				-- After a short grace period (long enough for a second player who is
				-- pulling in alongside), start a one-car race so solo practice works
				-- exactly as it does in single player. If someone arrives later, the
				-- race ends and a two-car one forms from the queue.
				soloWaitStartedAt[stripId] = soloWaitStartedAt[stripId] or now()
				if (now() - soloWaitStartedAt[stripId]) >= SOLO_GRACE then
					soloWaitStartedAt[stripId] = nil
					log("I", logTag, string.format("alone at strip '%s' - starting a solo run", stripId))
					startRace(stripId, players)
				end
			else
				soloWaitStartedAt[stripId] = nil
			end
		else
			-- The roster changed while we were still waiting to stage. Nothing has
			-- happened yet, so rebuild the race around whoever is there now.
			--
			-- Both directions matter. Somebody who pulled up should not have to sit out a
			-- run they could have been in; and somebody who left -- or was dropped for not
			-- staging, or shoved off the line -- must be taken out of the heat, because
			-- areAllRacersStaged counts a racer outside the lane boundary as not staged
			-- (phaseHandlers.lua:418) and would block the tree for everyone else forever.
			--
			-- Once the countdown has fired it is too late; changes wait for the next heat.
			local count = countPlayers(players)
			local roster = rosterFingerprint(players)
			if not active.countdownSent and roster ~= active.roster then
				log("I", logTag, string.format(
					"roster at '%s' changed to %d player(s) [%s] before staging - rebuilding",
					stripId, count, roster))
				activeRaceByStrip[stripId] = nil
				soloWaitStartedAt[stripId] = nil
				if count > 0 then startRace(stripId, players) end
			else
				tryStartCountdown(stripId, active)
				tryAdvanceHeat(stripId, active)
			end
		end

		::continue::
	end
end

--== lifecycle ================================================================

local function onUpdate(dtReal)
	if not isEnabled() then return end

	if (now() - lastScan) >= SCAN_INTERVAL then
		lastScan = now()
		scanForStrip()
	end

	-- A mission took over the strip while we were standing on it. Let go of it quietly
	-- rather than holding a lane the mission is trying to use.
	local gm = gamemode()
	if localContext and gm and gm.inSoloDragActivity and gm.inSoloDragActivity() then
		log("I", logTag, "a mission or performance test owns the strip now - releasing it")
		M.clearLocalContext()
		return
	end

	if localContext then
		if hasLeftStrip() then
			M.clearLocalContext()
		elseif (now() - lastHeartbeat) >= PRESENCE_HEARTBEAT then
			-- Keep the strip's authority informed that we are still here.
			M.announcePresence()
		end
	end

	-- Wind the race up once the result has had its time on screen.
	local gm = gamemode()
	local finalizedAt = gm and gm.getFinalizedAt and gm.getFinalizedAt()
	if finalizedAt and (now() - finalizedAt) >= RESULT_LINGER then
		if gm.tearDownRaceUI then gm.tearDownRaceUI() end
	end

	-- Self-guarded per strip: a player who holds nothing has nothing to iterate.
	authorityUpdate()
end

function M.reset()
	presence = {}
	activeRaceByStrip = {}
	soloWaitStartedAt = {}
	stageBlocked = {}
	stripCache = {}
	stripList = nil
	stripListLevel = nil
	localContext = nil
	lastScan = 0
end

--- Lobby messages ride the same relay as the BeamNG protocol; the transport routes
--- anything namespaced mileage* here instead of into the game's handlers.
function M.onMileageDragMessage(msgName, fromPlayerId, data)
	if msgName == "mileageDragJoin" then
		onJoin(fromPlayerId, data)
	elseif msgName == "mileageDragLeave" then
		onLeave(fromPlayerId, data)
	end
end

--- The server moved a strip's authority. Only two cases matter: it came to us, or it
--- left us.
function M.onMileageDragAuthorityChanged(stripId, playerId, weHoldIt)
	if not stripId then return end

	forgetStrip(stripId)
	if not weHoldIt then return end

	presence[stripId] = {}
	log("I", logTag, string.format("took over strip '%s' - rebuilding the roster", stripId))

	-- A race the previous holder was running is not inherited. Its state -- staging, finish
	-- times, queue position -- lived in that client's memory and was never replicated, so
	-- continuing it would mean guessing. Everyone still at the strip re-announces within
	-- PRESENCE_HEARTBEAT seconds and a fresh race forms from that, costing one run.
	if localContext and localContext.stripId == stripId then
		M.announcePresence(true)
	end
end

local function onExtensionLoaded()
	log("I", logTag, "Mileage drag lobby LOADED")
end

local function onExtensionUnloaded()
	M.reset()
	log("I", logTag, "Mileage drag lobby UNLOADED")
end

local function onBeamMPServerLeave()
	M.reset()
end

M.onUpdate = onUpdate
M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded
M.onBeamMPServerLeave = onBeamMPServerLeave

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
