-- Resources/Server/CareerMP/careerMP.lua: the server-wide traffic total. Each player
-- keeps the per-player amounts until the players together would pass the server's
-- total, then the total is split between them (one spare car each to the lowest ids).
-- A joiner's share travels in its own settings; players already in get theirs 3 seconds
-- after the last join or leave.

local SOURCE = "Resources/Server/CareerMP/careerMP.lua"

local function encode(v)
	if type(v) == "table" then
		local parts = {}
		for k, val in pairs(v) do table.insert(parts, "[" .. encode(k) .. "]=" .. encode(val)) end
		table.sort(parts)
		return "{" .. table.concat(parts, ",") .. "}"
	elseif type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

local function decode(text)
	local chunk = (loadstring or load)("return " .. tostring(text))
	if not chunk then error("does not decode") end
	return chunk()
end

local server

local function newServer(opts)
	opts = opts or {}
	server = {now = 0, sent = {}, players = {}}
	Util = {JsonEncode = encode, JsonDecode = decode}
	MP = {
		CreateTimer = function() return {GetCurrent = function() return server.now end, Start = function() end} end,
		GetPlayers = function()
			local copy = {}
			for id, name in pairs(server.players) do copy[id] = name end
			return copy
		end,
		IsPlayerConnected = function(id) return server.players[id] ~= nil end,
		GetPlayerName = function(id) return server.players[id] end,
		TriggerClientEvent = function(target, event, data)
			table.insert(server.sent, {target = target, event = event, data = data})
		end,
		DropPlayer = function() end,
	}
	local realPrint = print
	print = function() end
	dofile(SOURCE)
	print = realPrint
	Config = {
		server = {roadTrafficTotal = opts.roadTotal or 18, parkedTrafficTotal = opts.parkedTotal or 24},
		client = {roadTrafficEnabled = opts.roadEnabled ~= false, roadTrafficAmount = opts.road or 6,
			parkedTrafficEnabled = opts.parkedEnabled ~= false, parkedTrafficAmount = opts.parked or 8,
			consoleEnabled = false},
	}
	-- SetConfig reads the file again and writes it back.
	ReadJson = function() return Config end
	WriteJson = function() return true end
	return server
end

-- A player joins and asks for the settings, as the game does at world-ready.
local function join(id)
	server.players[id] = "player" .. id
	onPlayerJoinHandler(id)
	careerSyncRequested(id, encode({confirmsStart = true}))
end

local function leave(id)
	server.players[id] = nil
	onPlayerDisconnectHandler(id)
end

local function sentOf(event, target)
	local list = {}
	for _, m in ipairs(server.sent) do
		if m.event == event and (target == nil or m.target == target) then table.insert(list, m) end
	end
	return list
end

-- The share player id has now: the last share sent to it, in its settings or on its own.
local function shareOf(id)
	local share
	for _, m in ipairs(server.sent) do
		if m.target == id then
			if m.event == "rxCareerSync" then share = decode(m.data).trafficShare end
			if m.event == "rxCareerTrafficShare" then share = decode(m.data) end
		end
	end
	return share
end

-- Lets `seconds` pass in one-second ticks.
local function wait(seconds)
	for _ = 1, seconds do
		server.now = server.now + 1
		tick()
	end
end

local function expectedSplit(perPlayer, total, n, index)
	if total == 0 or perPlayer * n <= total then return perPlayer end
	local each = math.floor(total / n)
	return each + ((index <= total - each * n) and 1 or 0)
end

--== the rule ================================================================

test("shares for 1 to 10 players keep today's amounts until the total, then split it", function()
	for n = 1, 10 do
		newServer()
		for id = 0, n - 1 do join(id) end
		wait(5)
		local road, parked = 0, 0
		for id = 0, n - 1 do
			local share = shareOf(id)
			same(share.road, expectedSplit(6, 18, n, id + 1), n .. " players, road for player " .. id)
			same(share.parked, expectedSplit(8, 24, n, id + 1), n .. " players, parked for player " .. id)
			road, parked = road + share.road, parked + share.parked
		end
		expect(road <= math.max(18, 6 * math.min(n, 3)), n .. " players: road cars " .. road)
		expect(parked <= 24, n .. " players: parked cars " .. parked)
	end
end)

test("a joiner's settings carry its share, worked out with the joiner counted", function()
	newServer()
	join(0)
	join(1)
	join(2)
	local third = decode(sentOf("rxCareerSync", 2)[1].data)
	same(third.trafficShare.road, 6, "third player's road share")
	same(third.trafficShare.parked, 8, "third player's parked share")
	join(3)
	local fourth = decode(sentOf("rxCareerSync", 3)[1].data)
	same(fourth.trafficShare.road, 4, "fourth player's road share")
	same(fourth.trafficShare.parked, 6, "fourth player's parked share")
	same(fourth.roadTrafficAmount, 6, "the per-player amount is still in the settings")
	same(Config.client.trafficShare, nil, "the server's own client settings keep no share")
end)

--== joins and leaves ========================================================

-- The traffic all players have now: each one's last share added up.
local function totalShares()
	local road, parked = 0, 0
	for id in pairs(server.players) do
		local share = shareOf(id)
		if share then road, parked = road + share.road, parked + share.parked end
	end
	return road, parked
end

test("players already in get their smaller share at once when someone joins, so the total is never passed", function()
	newServer()
	for id = 0, 2 do join(id) end
	wait(5)
	server.sent = {}
	join(3)
	local road, parked = totalShares()
	expect(road <= 18 and parked <= 24, string.format("traffic right after the fourth join: %d, %d", road, parked))
	same(shareOf(0).road, 5, "player 0's road share right after the fourth join")
	same(shareOf(2).road, 4, "player 2's road share right after the fourth join")
	server.now = server.now + 0.5
	join(4)
	road, parked = totalShares()
	expect(road <= 18 and parked <= 24, string.format("traffic right after the fifth join: %d, %d", road, parked))
	local sent = #sentOf("rxCareerTrafficShare")
	wait(10)
	same(#sentOf("rxCareerTrafficShare"), sent, "shares sent later, when nothing grew")
	same(#sentOf("rxCareerTrafficShare", 4), 0, "shares to player 4, who got its share with its settings")
end)

test("a share that grows waits 3 seconds after the last join or leave", function()
	newServer()
	for id = 0, 3 do join(id) end
	wait(5)
	server.sent = {}
	leave(3)
	wait(2)
	same(#sentOf("rxCareerTrafficShare"), 0, "shares sent within 3 seconds of the leave")
	wait(2)
	same(#sentOf("rxCareerTrafficShare"), 3, "shares sent once, to each player left")
end)

test("a player who leaves gives the others their share back within 5 seconds", function()
	newServer()
	for id = 0, 3 do join(id) end
	wait(5)
	same(shareOf(0).road, 5, "player 0's road share with four players")
	leave(3)
	wait(4)
	same(shareOf(0).road, 6, "player 0's road share after one left")
	same(shareOf(2).parked, 8, "player 2's parked share after one left")
	same(#sentOf("rxCareerTrafficShare", 3), 0, "shares to the player who left")
end)

test("a player whose share did not change is sent nothing", function()
	newServer()
	join(0)
	join(1)
	wait(5)
	same(#sentOf("rxCareerTrafficShare"), 0, "shares sent to two players under the total")
end)

test("the shared settings broadcast carries no share", function()
	newServer()
	join(0)
	SetConfig({"client", "consoleEnabled", "true"})
	local update = sentOf("rxClientConfigUpdate")[1]
	expect(update ~= nil, "settings broadcast")
	same(decode(update.data).trafficShare, nil, "share in the broadcast")
end)

test("changing a total with SetConfig sends the new shares", function()
	newServer()
	for id = 0, 2 do join(id) end
	wait(5)
	SetConfig({"server", "roadTrafficTotal", "9"})
	wait(4)
	same(shareOf(0).road, 3, "player 0's road share with a total of 9")
end)

--== settings ================================================================

test("a total of 0 means no limit", function()
	newServer({roadTotal = 0, parkedTotal = 0})
	for id = 0, 7 do join(id) end
	wait(5)
	same(shareOf(7).road, 6, "eighth player's road share")
	same(shareOf(0).parked, 8, "first player's parked share")
end)

test("a switched-off kind shares 0, and amounts and totals are held to their ranges", function()
	newServer({roadEnabled = false, parked = 80, parkedTotal = 1000})
	join(0)
	same(shareOf(0).road, 0, "road share with road traffic off")
	same(shareOf(0).parked, 50, "parked share of an amount above 50")
	newServer({road = -3, roadTotal = -5, parked = "x"})
	join(0)
	same(shareOf(0).road, 0, "road share of a negative amount")
	same(shareOf(0).parked, 0, "parked share of an amount that is not a number")
end)

test("Stats shows the totals and each player's share", function()
	newServer()
	for id = 0, 3 do join(id) end
	local printed = {}
	local realPrint = print
	print = function(line) table.insert(printed, tostring(line)) end
	Stats({})
	print = realPrint
	same(countLines(printed, "Traffic total: 18 driving, 24 parked"), 1, "totals line")
	same(countLines(printed, "player3 (3): 0 cars (0 shown), 0 traffic or parked (0 shown), share 4 driving 6 parked"), 1,
		"player 3's line")
end)

test("the spare cars of a split go to the lowest player numbers, two-digit ids counted as numbers", function()
	newServer({roadTotal = 10, parkedTotal = 10})
	join(11)
	join(5)
	join(2)
	wait(5)
	same(shareOf(2).road, 4, "road share of player 2")
	same(shareOf(5).road, 3, "road share of player 5")
	same(shareOf(11).road, 3, "road share of player 11")
	same(shareOf(2).parked, 4, "parked share of player 2")
	same(shareOf(11).parked, 3, "parked share of player 11")
end)
