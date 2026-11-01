-- Race events the server owner runs: `Mileage Event <minutes> <prize> <route|random>`,
-- announcements 10, 5 and 1 minutes ahead, joining from the prompts app, the grid start,
-- a random finish picked from the road map, the prize paid to the winner, and every way
-- a command or an event is refused or ends.

local World = dofile("tests/money_world.lua")

local function three(world)
	return world:join("Ann", 1000), world:join("Bob", 1000), world:join("Cat", 1000)
end

local function chatLines(world, text)
	local n = 0
	for _, line in ipairs(world.chat or {}) do
		if line.text:find(text, 1, true) then n = n + 1 end
	end
	return n
end

local function lastEvent(world, p, phase)
	local found = nil
	for _, m in ipairs(world:ui(p, "MileageEvent")) do
		if not phase or m.phase == phase then found = m end
	end
	return found
end

local function join(world, p)
	local e = assert(lastEvent(world, p), "no event shown to " .. p.name)
	world:as(p, function() mileage_raceEvents.join(e.id) end)
	world:pump()
end

-- Each racer drives to the event's finish after the given seconds of racing.
local function raceTo(world, finish, order)
	world:advance(5)
	for _, step in ipairs(order) do
		world:advance(step.after)
		assert(world:drive(step.p, finish.x, finish.y, finish.z), step.p.name .. " is frozen")
	end
	world:advance(7)
end

World.test("a scheduled event is announced at 10, 5 and 1 minutes in chat and in the prompts app", function(world)
	local ann = three(world)
	local lines = world:console("Mileage Event 10 25000 service-dragway")
	same(countLines(lines, "in 10 min: Service station garage to Alder Dragway, $25000 prize"), 1, "confirmed")
	same(chatLines(world, "Race event in 10 minutes"), 1, "10 minutes")
	world:advance(300)
	same(chatLines(world, "Race event in 5 minutes"), 1, "5 minutes")
	world:advance(240)
	same(chatLines(world, "Race event in 1 minute:"), 1, "1 minute")
	same(#world:received(ann, "rxMileageEvent"), 3, "three announcements to each player")
	local shown = lastEvent(world, ann, "announce")
	same(shown.route, "Service station garage to Alder Dragway", "route shown")
	same(shown.prize, 25000, "prize shown")
end)

World.test("an event scheduled 3 minutes ahead is announced now and at 1 minute only", function(world)
	three(world)
	world:console("Mileage Event 3 100 1")
	world:advance(170)
	same(#(world.chat or {}), 2, "two announcements")
	same(chatLines(world, "Race event in 3 minutes"), 1, "at scheduling")
	same(chatLines(world, "Race event in 1 minute"), 1, "at 1 minute")
end)

World.test("joined players line up on distinct grid places, and the fastest wins the prize", function(world)
	local ann, bob, cat = three(world)
	world:console("Mileage Event 1 25000 service-dragway")
	join(world, ann)
	join(world, bob)
	same(lastEvent(world, bob, "joined").joined, 2, "two joined")
	world:advance(60)
	same(#ann.teleports, 1, "Ann moved to the grid")
	same(#bob.teleports, 1, "Bob moved to the grid")
	same(#cat.teleports, 0, "Cat did not join")
	local a, b = ann.teleports[1].pos, bob.teleports[1].pos
	expect(math.abs(a.x - b.x) + math.abs(a.y - b.y) >= 3.9, "distinct grid places")
	same(ann.car.frozen, true, "held for the countdown")
	local finish = {x = -203.27, y = -203.98, z = 118.82}
	raceTo(world, finish, {{p = bob, after = 60}, {p = ann, after = 3}})
	same(bob.money, 26000, "Bob won the prize")
	same(ann.money, 1000, "Ann")
	same(cat.money, 1000, "Cat")
	local result = lastEvent(world, ann, "result")
	same(result.winner, "Bob", "result names the winner")
	same(result.places[1].name, "Bob", "first place")
	same(result.places[2].name, "Ann", "second place")
	same(bob.history[#bob.history].label, "Race event prize", "money history")
end)

World.test("nobody joining ends the event quietly", function(world)
	local ann = three(world)
	world:console("Mileage Event 1 500 2")
	world:advance(61)
	same(#ann.teleports, 0, "nobody moved")
	same(chatLines(world, "nobody joined"), 1, "said in chat")
	same(world:dataFile("events.json").id, nil, "schedule cleared")
end)

World.test("a random finish is a road point 1.5 to 4 km from the start, picked by a joined game", function(world)
	local ann, bob = three(world)
	world.roadNodes = {}
	-- Road points around every route's start: too near, in range and too far.
	for _, d in ipairs({500, 2500, 6000}) do
		for i = 1, 8 do
			world.roadNodes["n" .. d .. "_" .. i] = {pos = {x = 0, y = 0, z = 0}}
		end
	end
	local starts = {{904.49, -546.27}, {-284.25, -69.43}, {-68.03, 2.58}, {-393.43, 178.1}, {-820.68, 905.03},
		{-698.6, 808.69}, {836.36, -535.39}}
	local k = 0
	for _, s in ipairs(starts) do
		for _, d in ipairs({500, 2500, 6000}) do
			k = k + 1
			world.roadNodes["r" .. k] = {pos = {x = s[1] + d, y = s[2], z = 100}}
		end
	end
	world:console("Mileage Event 1 1000 random")
	join(world, ann)
	join(world, bob)
	world:advance(61)
	local picked = nil
	for _, m in ipairs(world.serverLog) do
		if m.name == "mileageRaceReport" and m.data:find("finish", 1, true) then picked = World.decode(m.data).finish end
	end
	expect(picked, "a finish was picked")
	same(picked.z, 100, "a road point")
	local start = ann.teleports[1] and ann.teleports[1].pos
	expect(start, "Ann moved to the start")
	local metres = math.sqrt((picked.x - start.x) ^ 2 + (picked.y - start.y) ^ 2)
	expect(metres >= 1490 and metres <= 4010, "finish 1.5 to 4 km from the start: " .. metres)
end)

World.test("with no random finish in 10 s the next route's finish is used", function(world)
	local ann = three(world)
	world.roadNodes = {}
	world:console("Mileage Event 1 1000 random")
	join(world, ann)
	world:advance(60)
	same(#ann.teleports, 0, "waiting for a finish")
	world:advance(11)
	same(#ann.teleports, 1, "started with the fallback finish")
end)

World.test("nobody finishing in time pays nobody", function(world)
	local ann = three(world)
	world:setConfig("server", "raceTimeLimitMinutes", "1")
	world:console("Mileage Event 1 500 1")
	join(world, ann)
	world:advance(60 + 5 + 61)
	same(lastEvent(world, ann, "result").why, "timeout", "ended at the limit")
	same(ann.money, 1000, "no prize")
end)

World.test("a joined player who leaves is dropped from the event", function(world)
	local ann, bob = three(world)
	world:console("Mileage Event 1 500 1")
	join(world, ann)
	join(world, bob)
	world:leave(bob)
	same(world:dataFile("events.json").joined.Bob, nil, "Bob dropped")
	world:advance(61)
	same(#ann.teleports, 1, "Ann still raced")
end)

World.test("leaving the event from the prompts app takes the player off it", function(world)
	local ann = three(world)
	world:console("Mileage Event 2 500 1")
	join(world, ann)
	local e = lastEvent(world, ann, "joined")
	world:as(ann, function() mileage_raceEvents.leave(e.id) end)
	world:pump()
	same(lastEvent(world, ann, "left").youJoined, false, "left")
	world:advance(121)
	same(#ann.teleports, 0, "not lined up")
end)

World.test("bad minutes, prize or route, a second event, or events switched off schedule nothing", function(world)
	three(world)
	local function says(line, text)
		return countLines(world:console(line), text)
	end
	same(says("Mileage Event 0 100 1", "Minutes must be a whole number from 1 to 120"), 1, "0 minutes")
	same(says("Mileage Event 121 100 1", "Minutes must be"), 1, "121 minutes")
	same(says("Mileage Event 5 -1 1", "The prize must be"), 1, "negative prize")
	same(says("Mileage Event 5 1000001 1", "The prize must be"), 1, "prize too big")
	same(says("Mileage Event 5 100 nowhere", "Unknown route nowhere"), 1, "unknown route")
	same(says("Mileage Event 5 100", "Usage: Mileage Event"), 1, "missing route")
	same(world:dataFile("events.json"), nil, "nothing scheduled")
	world:console("Mileage Event 5 100 1")
	same(says("Mileage Event 5 100 2", "already scheduled"), 1, "second event")
	world:console("Mileage Event cancel")
	world:setConfig("server", "allowEvents", "false")
	same(says("Mileage Event 5 1000 random", "Race events are switched off"), 1, "switched off")
end)

World.test("list prints every route; cancel ends the event and tells the players", function(world)
	local ann = three(world)
	local lines = world:console("Mileage Event list")
	same(countLines(lines, ". "), 8, "eight routes")
	same(countLines(lines, "1. service-dragway: Service station garage to Alder Dragway"), 1, "first route")
	same(countLines(lines, "random:"), 1, "random")
	world:console("Mileage Event 5 100 1")
	same(countLines(world:console("CareerMP Event cancel"), "cancelled"), 1, "cancelled, old prefix too")
	same(lastEvent(world, ann, "cancelled") ~= nil, true, "players told")
	world:advance(301)
	same(#ann.teleports, 0, "nothing started")
end)

World.test("switching events off cancels the scheduled event", function(world)
	local ann = three(world)
	world:console("Mileage Event 5 100 1")
	world:setConfig("server", "allowEvents", "false")
	world:advance(1)
	expect(lastEvent(world, ann, "cancelled"), "cancelled")
	same(world:dataFile("events.json").id, nil, "schedule cleared")
end)

World.test("the schedule and who joined survive a restart", function(world)
	local ann = three(world)
	world:console("Mileage Event 2 700 1")
	join(world, ann)
	world:restart()
	world:advance(121)
	same(#ann.teleports, 1, "Ann lined up after the restart")
end)
