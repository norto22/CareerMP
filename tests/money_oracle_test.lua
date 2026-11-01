-- The Plan's oracle, run as one session of three players on the real server and client
-- files: with the server prize off, a $1,000-stake race between two of them ends with the
-- winner exactly $1,000 up, the loser $1,000 down and the third player unchanged, the
-- total across all three saves unchanged, and the win on the leaderboard after a server
-- restart; and the same when the loser's game disconnects mid-race and rejoins later.
-- Then several races, payments and requests at once between four players, which must not
-- mix.

local World = dofile("tests/money_world.lua")

local FINISH = {x = 0, y = 2400, z = 0}

local function players(world, names)
	local list = {}
	for i, name in ipairs(names) do
		list[i] = world:join(name, 10000)
		list[i].car.pos = {x = i * 200, y = 0, z = 0}
	end
	return (table.unpack or unpack)(list)
end

local function shownOffer(world, p)
	local closed = {}
	for _, c in ipairs(world:ui(p, "MileageOfferClosed")) do closed[c.id] = true end
	local last = nil
	for _, offer in ipairs(world:ui(p, "MileageOffer")) do
		if not closed[offer.id] then last = offer end
	end
	return last
end

-- a challenges b to FINISH (from a's own position) for stake; b accepts.
local function race(world, a, b, stake)
	a.route = {x = a.car.pos.x, y = a.car.pos.y + 2400, z = 0}
	world:as(a, function() assert(mileage_offers.race(b.name, stake), "challenge not sent") end)
	world:pump()
	local offer = assert(shownOffer(world, b), "challenge not shown")
	world:as(b, function() mileage_offers.answer(offer.id, true) end)
	world:pump()
	return a.route
end

local function arrive(world, p, finish)
	assert(world:drive(p, finish.x, finish.y), p.name .. " still frozen")
end

local function winsFor(world, p, name)
	world:as(p, function() mileage_leaderboard.request() end)
	world:pump()
	local boards = world:ui(p, "MileageLeaderboard")
	for _, entry in ipairs(boards[#boards].wins) do
		if entry.name == name then return entry.wins end
	end
	return 0
end

World.test("oracle: a $1,000 race between two of three players, checked after a restart", function(world)
	local ann, bob, cat = players(world, {"Ann", "Bob", "Cat"})
	local finish = race(world, ann, bob, 1000)
	same(bob.teleports[1].pos.x, ann.car.pos.x + 4, "Bob moved beside Ann")
	world:advance(3)
	world:advance(90)
	arrive(world, ann, finish)
	world:advance(4)
	arrive(world, bob, finish)
	world:advance(6)
	world:restart()
	world:advance(2)
	same(ann.savedMoney, 11000, "Ann exactly $1,000 up")
	same(bob.savedMoney, 9000, "Bob exactly $1,000 down")
	same(cat.savedMoney, 10000, "Cat unchanged")
	same(world:savedTotal(), 30000, "total across the three saves")
	same(winsFor(world, cat, "Ann"), 1, "Ann's win on the leaderboard after the restart")
end)

World.test("oracle: the same when the loser's game disconnects mid-race and rejoins later", function(world)
	local ann, bob, cat = players(world, {"Ann", "Bob", "Cat"})
	race(world, ann, bob, 1000)
	world:advance(3)
	world:advance(40)
	world:leave(bob, {crash = true})
	world:advance(30)
	same(ann.savedMoney, 11000, "Ann paid while Bob is away")
	world:advance(600)
	world:rejoin(bob)
	world:advance(12)
	world:restart()
	world:advance(2)
	same(ann.savedMoney, 11000, "Ann exactly $1,000 up")
	same(bob.savedMoney, 9000, "Bob exactly $1,000 down")
	same(cat.savedMoney, 10000, "Cat unchanged")
	same(world:savedTotal(), 30000, "total across the three saves")
	same(winsFor(world, cat, "Ann"), 1, "Ann's win on the leaderboard after the restart")
end)

World.test("several races, payments and requests at once between four players do not mix", function(world)
	local ann, bob, cat, dan = players(world, {"Ann", "Bob", "Cat", "Dan"})
	local finishAB = race(world, ann, bob, 1000)
	local finishCD = race(world, cat, dan, 300)
	-- While both races line up: Dan pays Bob, Cat asks Ann for money and Ann pays.
	world:as(dan, function() mileagePlayerPayments.onUpdate(3); mileagePlayerPayments.payPlayer("Bob", 50) end)
	world:as(cat, function() mileage_offers.request("Ann", 200) end)
	world:pump()
	local request = assert(shownOffer(world, ann), "request shown to Ann")
	world:as(ann, function() mileage_offers.answer(request.id, true) end)
	world:pump()
	world:advance(3)
	world:advance(60)
	arrive(world, bob, finishAB)
	arrive(world, cat, finishCD)
	world:advance(2)
	arrive(world, ann, finishAB)
	arrive(world, dan, finishCD)
	world:advance(10)
	same(ann.money, 10000 - 1000 - 200, "Ann lost her race and paid Cat's request")
	same(bob.money, 10000 + 1000 + 50, "Bob won and was paid by Dan")
	same(cat.money, 10000 + 300 + 200, "Cat won her race and got Ann's payment")
	same(dan.money, 10000 - 300 - 50, "Dan lost his race and paid Bob")
	same(world:savedTotal(), 40000, "total across the four saves")
	local data = world:dataFile("transfers.json")
	same(next(data.transfers), nil, "nothing left waiting")
	same(next(world:dataFile("races.json").races), nil, "no race left holding stakes")
end)
