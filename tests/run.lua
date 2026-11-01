-- Runs every CareerMP test file against the real sources, with the game and the
-- BeamMP server replaced by small stand-ins. Plain Lua 5.1 or later, no libraries.
--
--   lua tests/run.lua          (from the repository root)
--
-- Each test file calls test(name, fn); fn fails by raising an error (expect, same).

local files = {
	"tests/traffic_meter_test.lua",
	"tests/server_config_test.lua",
	"tests/announcements_test.lua",
	"tests/insurance_restore_test.lua",
}

local passed, failed = 0, 0
local current = nil

function test(name, fn)
	local ok, err = pcall(fn)
	if ok then
		passed = passed + 1
		print("ok   " .. current .. ": " .. name)
	else
		failed = failed + 1
		print("FAIL " .. current .. ": " .. name .. "\n     " .. tostring(err))
	end
end

function expect(cond, what)
	if not cond then error(what or "expectation failed", 2) end
end

function same(actual, wanted, what)
	if actual ~= wanted then
		error(string.format("%s: got %s, wanted %s", what or "value", tostring(actual), tostring(wanted)), 2)
	end
end

-- Lines in a captured log that contain text (plain match).
function countLines(lines, text)
	local n = 0
	for _, line in ipairs(lines) do
		if string.find(line, text, 1, true) then n = n + 1 end
	end
	return n
end

for _, file in ipairs(files) do
	current = file
	local chunk, err = loadfile(file)
	if not chunk then
		failed = failed + 1
		print("FAIL " .. file .. ": does not load\n     " .. tostring(err))
	else
		local ok, runErr = pcall(chunk)
		if not ok then
			failed = failed + 1
			print("FAIL " .. file .. ": stopped\n     " .. tostring(runErr))
		end
	end
end

print(string.format("%d passed, %d failed", passed, failed))
if failed > 0 then error("tests failed", 0) end
