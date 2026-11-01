-- The edges of the money, race, leaderboard and event messages: values exactly at each
-- server limit are accepted, malformed messages from a game change nothing and stop
-- nothing, a game never applies a step whose amount is not a whole number above zero, and
-- an event's racer who finished keeps the prize after leaving. Every case runs the real
-- server and client files in the money test world.

local World = dofile("tests/money_world.lua")

local function shownOffer(world, p)
	local closed = {}
	for _, c in ipairs(world:ui(p, "MileageOfferClosed")) do closed[c.id] = true end
	local last = nil
	for _, offer in ipairs(world:ui(p, "MileageOffer")) do
		if not closed[offer.id] then last = offer end
	end
	return last
end

local function lastClosed(world, p)
	local closed = world:received(p, "rxMileageOfferClosed")
	return closed[#closed]
end

local function receipts(world, p)
	local n = 0
	for _, m in ipairs(world.serverLog) do
		if m.name == "mileageReceipt" and m.from == p.id then n = n + 1 end
	end
	return n
end

--== limits are inclusive ======================================================

-- Rejects a check written as >= (or <) where the setting is the largest allowed value.
World.test("a challenge staking exactly raceStakeMax to a finish exactly raceMinDistance away is shown",
		function(world)
	local ann, bob = world:join("Ann", 20000), world:join("Bob", 20000)
	world:serverOutput(function()
		mileageOffer(ann.id, World.encode({kind = "race", to = bob.id, amount = 10000,
			start = {x = 0, y = 0, z = 0}, finish = {x = 0, y = 500, z = 0}}))
	end)
	world:pump()
	same(lastClosed(world, ann), nil, "not refused")
	local offer = shownOffer(world, bob)
	expect(offer, "challenge shown to Bob")
	same(offer.amount, 10000, "stake")
	same(offer.distance, 500, "distance")
end)

-- Rejects a request check written as >= sessionSendingMax.
World.test("a request for exactly the session sending limit is shown and, accepted, paid", function(world)
	local ann, bob = world:join("Ann", 0), world:join("Bob", 150000)
	world:as(ann, function() expect(mileage_offers.request("Bob", 100000), "request sent") end)
	world:pump()
	local offer = shownOffer(world, bob)
	expect(offer, "request shown to Bob")
	world:as(bob, function() mileage_offers.answer(offer.id, true) end)
	world:pump()
	world:advance(2)
	same(ann.money, 100000, "Ann")
	same(bob.money, 50000, "Bob")
	same(world:savedTotal(), 150000, "total across saves")
end)

-- Rejects a range check written with < 3 or > 60 replaced by <= or >=.
World.test("drag times of exactly 3 s and 60 s are kept", function(world)
	local ann, bob = world:join("Ann", 0), world:join("Bob", 0)
	world:serverOutput(function()
		mileageDragTime(ann.id, World.encode({strip = "alder_dragway", et = 3, trap = 90}))
		mileageDragTime(bob.id, World.encode({strip = "alder_dragway", et = 60, trap = 20}))
		mileageDragTime(bob.id, World.encode({strip = "alder_dragway", et = 60.001, trap = 20}))
	end)
	local kept = world:dataFile("leaderboard.json").drag.alder_dragway
	same(kept.Ann.et, 3, "3 s kept")
	same(kept.Bob.et, 60, "60 s kept, 60.001 s ignored")
end)

-- Rejects a bad trap speed being kept as given, or the whole run being dropped for it.
World.test("a drag run with a trap speed outside 0 to 200 m/s keeps its time with no speed", function(world)
	local ann = world:join("Ann", 0)
	world:serverOutput(function()
		mileageDragTime(ann.id, World.encode({strip = "alder_dragway", et = 11.2, trap = 900}))
	end)
	local run = world:dataFile("leaderboard.json").drag.alder_dragway.Ann
	same(run.et, 11.2, "time kept")
	same(run.trap, 0, "speed dropped")
end)

-- Rejects bounds written as exclusive at 120 minutes or a $1,000,000 prize.
World.test("an event 120 minutes ahead with a $1,000,000 prize is scheduled; 1.5 minutes is refused",
		function(world)
	world:join("Ann", 0)
	same(countLines(world:console("Mileage Event 1.5 100 1"), "Minutes must be a whole number"), 1,
		"fractional minutes")
	same(world:dataFile("events.json"), nil, "nothing scheduled")
	world:console("Mileage Event 120 1000000 service-dragway")
	local e = world:dataFile("events.json")
	same(e.prize, 1000000, "prize")
	same(e.route, "service-dragway", "route")
end)

--== malformed messages ========================================================

-- Rejects a handler that indexes a message before checking it is a table with the
-- fields it needs: each of these would raise inside the server.
World.test("malformed messages from a game raise nothing and change nothing", function(world)
	local ann, bob = world:join("Ann", 5000), world:join("Bob", 5000)
	local bad = {"", "not json", "[]", "42", World.encode({id = 7}), World.encode({race = {}, finished = "fast"}),
		World.encode({kind = "race", to = "1", amount = 1e300}), World.encode({kind = "request", to = bob.id}),
		World.encode({id = "o999", accept = true}), World.encode({strip = 5, et = 10}),
		World.encode({race = "r1", pose = {pos = {x = 1}}})}
	world:serverOutput(function()
		for _, data in ipairs(bad) do
			for _, handler in ipairs({mileageOffer, mileageOfferAnswer, mileageReceipt, mileageRaceReport,
					mileageDragTime, payPlayer}) do
				handler(ann.id, data)
			end
		end
	end)
	world:pump()
	world:advance(2)
	same(ann.money, 5000, "Ann")
	same(bob.money, 5000, "Bob")
	same(#world:ui(bob, "MileageOffer"), 0, "nothing shown to Bob")
	same(world:dataFile("races.json"), nil, "no race")
	local transfers = world:dataFile("transfers.json")
	same(transfers and next(transfers.transfers) or nil, nil, "no transfer")
end)

--== a game's own checks on a step ===============================================

-- Rejects a game that applies a give of -500 as a take, or rounds 2.5 to a whole amount.
World.test("a step whose amount is not a whole number above zero is not applied nor answered", function(world)
	local ann = world:join("Ann", 1000)
	for _, step in ipairs({{id = "x1", amount = -500}, {id = "x2", amount = 2.5}, {id = "x3", amount = 0},
			{id = "x4", amount = "100"}, {amount = 100}}) do
		world:as(ann, function() ann.handlers.rxMileageGive(World.encode(step)) end)
		world:as(ann, function() ann.handlers.rxMileageTake(World.encode(step)) end)
	end
	world:pump()
	same(ann.money, 1000, "money unchanged")
	same(receipts(world, ann), 0, "no receipt sent")
end)

-- Rejects a balance check written as <= (refusing a take of exactly what the player has).
World.test("a take of exactly the career's money is taken, leaving $0", function(world)
	local ann, bob = world:join("Ann", 750), world:join("Bob", 0)
	-- Past the game's own two-second cooldown between payments.
	world:as(ann, function() mileagePlayerPayments.onUpdate(3) end)
	world:as(ann, function() mileagePlayerPayments.payPlayer("Bob", 750) end)
	world:pump()
	same(ann.money, 0, "Ann")
	same(bob.money, 750, "Bob")
	same(world:savedTotal(), 750, "total across saves")
end)

--== events ======================================================================

-- Rejects an event that pays a $0 transfer, or counts no win, when the owner set no prize.
World.test("an event with no prize pays nothing and still counts the win", function(world)
	local ann = world:join("Ann", 1000)
	world:console("Mileage Event 1 0 service-dragway")
	local e = world:ui(ann, "MileageEvent")
	world:as(ann, function() mileage_raceEvents.join(e[#e].id) end)
	world:pump()
	world:advance(60 + 5 + 60)
	assert(world:drive(ann, -203.27, -203.98, 118.82), "Ann frozen")
	world:advance(8)
	same(ann.money, 1000, "no money moved")
	local transfers = world:dataFile("transfers.json")
	same(transfers and next(transfers.transfers) or nil, nil, "no transfer made")
	same(world:dataFile("leaderboard.json").wins.Ann, 1, "win counted")
end)

-- Rejects an event that drops the reports of a racer who leaves after finishing.
World.test("an event racer who finished first and then leaves is paid the prize when back", function(world)
	local ann, bob = world:join("Ann", 1000), world:join("Bob", 1000)
	world:console("Mileage Event 1 2500 service-dragway")
	for _, p in ipairs({ann, bob}) do
		local e = world:ui(p, "MileageEvent")
		world:as(p, function() mileage_raceEvents.join(e[#e].id) end)
		world:pump()
	end
	world:advance(60 + 5 + 60)
	assert(world:drive(ann, -203.27, -203.98, 118.82), "Ann frozen")
	world:advance(1)
	world:leave(ann)
	world:advance(10)
	world:rejoin(ann)
	world:advance(3)
	same(ann.money, 3500, "Ann paid the prize once back")
	same(bob.money, 1000, "Bob")
end)
