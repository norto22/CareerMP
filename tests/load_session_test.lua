-- The scripted 8-player session (tests/load_session.lua) on the working tree, against
-- the same session played on the base commit of the optimisation pass.

local runSession = dofile("tests/load_session.lua")

-- `luajit tests/load_session.lua <checkout of 483daa5>`: Mileage before the pass. The
-- damage bytes follow the order LuaJIT walks the game's tables in, which changes from run
-- to run; `bytes` is the lowest of the first 11 runs (3,484,015 to 3,639,890), and later
-- runs have sent a little less. The new code sends about a sixth of either, far inside
-- the half. Positions and traffic do not change.
local BEFORE = {commit = "483daa5", positions = 494925, bytes = 3484015, road = 48, parked = 64}
local TOTAL = {road = 18, parked = 24}

local now = runSession(".")

test("the session passes at most half as many positions to BeamMP as before the pass", function()
	expect(now.positions * 2 <= BEFORE.positions,
		string.format("positions: %d now, %d at %s", now.positions, BEFORE.positions, BEFORE.commit))
end)

test("the server sends at most half as many of Mileage's own bytes as before the pass", function()
	expect(now.bytes * 2 <= BEFORE.bytes,
		string.format("bytes: %d now, %d at %s", now.bytes, BEFORE.bytes, BEFORE.commit))
end)

test("the games are never asked for more traffic than the server-wide total", function()
	expect(now.maxRoad <= TOTAL.road, string.format("driving traffic asked at once: %d", now.maxRoad))
	expect(now.maxParked <= TOTAL.parked, string.format("parked traffic asked at once: %d", now.maxParked))
end)

test("the game files log no error through the session", function()
	same(now.errors, 0, "errors")
end)
