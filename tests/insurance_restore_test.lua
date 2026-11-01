-- careerMP/insuranceRestore.lua: after a join, insurance records that never loaded are
-- loaded through the game's own insurance load, an empty saved insurance file is reset
-- only after a verified backup, and owned cars without a record are added as uninsured.

local SOURCE = "Resources/Client/CareerMP/lua/ge/extensions/careerMP/insuranceRestore.lua"

local SAVE = "/settings/cloud/saves/player/autosave1"
local FILE = SAVE .. "/career/insurance.json"
local BACKUP = SAVE .. "/career/insurance.careermp-backup.json"

local DEFAULT_INSURERS = {[1] = {id = 1, name = "Default insurer"}}

local logs, files, writes, ins, vehicles, opts

local function copy(value)
	if type(value) ~= "table" then return value end
	local out = {}
	for k, v in pairs(value) do out[k] = copy(v) end
	return out
end

local function isEmpty(t) return type(t) ~= "table" or next(t) == nil end

-- A fresh game. opts.loaded: the insurance records already loaded. opts.file: the saved
-- insurance.json. opts.vehicles: the inventory. opts.loadFails, opts.writeFails (path),
-- opts.writeChanges (path): the game's load or a file write goes wrong.
local function setup(o)
	opts = o or {}
	logs, files, writes = {}, {}, {}
	if opts.file then files[FILE] = copy(opts.file) end
	vehicles = opts.vehicles or {[1] = {owned = true}}

	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end
	function jsonReadFile(path) return copy(files[path]) end

	career_saveSystem = {
		getCurrentProfile = function() return "player", SAVE end,
		jsonWriteFileSafe = function(path, data, compact)
			table.insert(writes, path)
			if opts.writeFails == path then error("disk full") end
			if opts.writeChanges == path then files[path] = {} return true end
			files[path] = copy(data)
			return true
		end,
	}

	career_modules_inventory = {getVehicles = function() return vehicles end}

	-- What the game's insurance load does: read the save, keep its insurer data when the
	-- file has any (even empty), otherwise build the defaults; set the driver score.
	ins = {loads = 0, added = {}, readOnLoad = nil, driverScore = nil, invVehs = {}, insurers = nil}
	if opts.loaded then
		ins.driverScore, ins.insurers = 100, copy(DEFAULT_INSURERS)
		ins.invVehs = copy(opts.records or {})
	end
	career_modules_insurance_insurance = {
		getDriverScore = function() return ins.driverScore end,
		getInvVehs = function() return ins.invVehs end,
		onCareerActive = function(active)
			ins.loads = ins.loads + 1
			if opts.loadFails then error("insurance.lua:682: attempt to compare nil with number") end
			local data = jsonReadFile(FILE)
			ins.readOnLoad = copy(data)
			data = data or {}
			ins.insurers = data.plInsurancesData or copy(DEFAULT_INSURERS)
			ins.invVehs = data.invVehs or {}
			ins.driverScore = data.driverScore or 100
		end,
		onVehicleAddedToInventory = function(data)
			table.insert(ins.added, data.inventoryId)
			ins.invVehs[data.inventoryId] = {insuranceId = -1}
		end,
	}

	return dofile(SOURCE)
end

local function contains(list, value)
	for _, v in ipairs(list) do if v == value then return true end end
	return false
end

--== records already loaded ==================================================

test("records already loaded with every owned car insured are left alone", function()
	local restore = setup({loaded = true, records = {[1] = {insuranceId = 2}}})
	local summary = restore.ensureLoaded()
	same(ins.loads, 0, "game loads")
	same(#writes, 0, "file writes")
	same(#ins.added, 0, "cars added")
	same(summary.loaded, true, "loaded")
	same(summary.reloaded, false, "reloaded")
	same(summary.added, 0, "added")
	same(countLines(logs, "I careerMP.insurance: loaded=true reloaded=false backedUp=false added=0"), 1, "summary line")
end)

--== records missing =========================================================

test("missing records are loaded once through the game's own load", function()
	local restore = setup()
	local summary = restore.ensureLoaded()
	same(ins.loads, 1, "game loads")
	same(summary.loaded, true, "loaded")
	same(summary.reloaded, true, "reloaded")
	expect(not isEmpty(ins.insurers), "insurers listed after the load")
	same(#writes, 0, "no file to reset, nothing written")
end)

test("a second call changes nothing", function()
	local restore = setup()
	restore.ensureLoaded()
	local summary = restore.ensureLoaded()
	same(ins.loads, 1, "game loads")
	same(#ins.added, 1, "cars added over both calls")
	same(summary.reloaded, false, "second call reloaded")
	same(summary.added, 0, "second call added")
end)

test("an empty saved insurance file is backed up, read back and only then replaced before loading", function()
	local saved = {invVehs = {}, plInsurancesData = {}, driverScore = 100}
	local restore = setup({file = saved})
	local summary = restore.ensureLoaded()
	same(writes[1], BACKUP, "first write")
	same(writes[2], FILE, "second write")
	same(#writes, 2, "writes")
	same(files[BACKUP].driverScore, 100, "backup keeps the original content")
	expect(type(files[BACKUP].invVehs) == "table" and type(files[BACKUP].plInsurancesData) == "table",
		"backup keeps the original tables")
	expect(ins.readOnLoad ~= nil and next(ins.readOnLoad) == nil, "the game's load read a blank file")
	expect(not isEmpty(ins.insurers), "insurers listed after the load")
	same(summary.backedUp, true, "backedUp")
	same(summary.loaded, true, "loaded")
	same(countLines(logs, BACKUP), 1, "log names the backup")
end)

test("a backup that fails to write leaves insurance.json untouched", function()
	local saved = {invVehs = {}, plInsurancesData = {}, driverScore = 100}
	local restore = setup({file = saved, writeFails = BACKUP})
	local summary = restore.ensureLoaded()
	expect(not contains(writes, FILE), "insurance.json written")
	same(files[FILE].driverScore, 100, "insurance.json content")
	same(summary.backedUp, false, "backedUp")
	same(ins.loads, 1, "the game's load still runs")
	expect(countLines(logs, "E careerMP.insurance:") >= 1, "error logged")
end)

test("a backup that reads back different leaves insurance.json untouched", function()
	local saved = {invVehs = {}, plInsurancesData = {}, driverScore = 100}
	local restore = setup({file = saved, writeChanges = BACKUP})
	local summary = restore.ensureLoaded()
	expect(not contains(writes, FILE), "insurance.json written")
	same(files[FILE].driverScore, 100, "insurance.json content")
	same(summary.backedUp, false, "backedUp")
	expect(countLines(logs, "E careerMP.insurance:") >= 1, "error logged")
end)

test("a file with car records but no insurers is never blanked", function()
	local saved = {invVehs = {[1] = {insuranceId = 2}}, plInsurancesData = {}}
	local restore = setup({file = saved})
	restore.ensureLoaded()
	same(#writes, 0, "file writes")
	same(files[FILE].invVehs[1].insuranceId, 2, "car record kept")
	same(countLines(logs, "W careerMP.insurance:"), 1, "warning")
	same(countLines(logs, FILE), 1, "warning names the file")
end)

test("a file with insurers is never blanked", function()
	local saved = {invVehs = {}, plInsurancesData = {[1] = {id = 1}}}
	local restore = setup({file = saved})
	restore.ensureLoaded()
	same(#writes, 0, "file writes")
end)

--== uninsured cars ==========================================================

test("owned cars without a record are added as uninsured, loaned cars are not", function()
	local restore = setup({loaded = true, records = {[2] = {insuranceId = 3}},
		vehicles = {[1] = {owned = true}, [2] = {owned = true}, [3] = {owned = false}}})
	local summary = restore.ensureLoaded()
	same(#ins.added, 1, "cars added")
	same(ins.added[1], 1, "the owned car with no record")
	same(ins.invVehs[1].insuranceId, -1, "registered uninsured")
	same(ins.invVehs[2].insuranceId, 3, "existing record kept")
	same(summary.added, 1, "added")
end)

test("a car the game fails to register is logged and the others still go through", function()
	local restore = setup({loaded = true, vehicles = {[1] = {owned = true}, [2] = {owned = true}}})
	local add = career_modules_insurance_insurance.onVehicleAddedToInventory
	career_modules_insurance_insurance.onVehicleAddedToInventory = function(data)
		if data.inventoryId == 1 then error("bad vehicle") end
		return add(data)
	end
	local summary = restore.ensureLoaded()
	same(summary.added, 1, "added")
	expect(countLines(logs, "E careerMP.insurance:") >= 1, "error logged")
end)

--== failures ================================================================

test("a failing game load is logged and the check still returns", function()
	local restore = setup({loadFails = true})
	local ok, summary = pcall(restore.ensureLoaded)
	expect(ok, "ensureLoaded raised: " .. tostring(summary))
	same(summary.loaded, false, "loaded")
	same(#ins.added, 0, "cars added")
	expect(summary.error ~= nil, "summary carries the error")
	same(countLines(logs, "attempt to compare nil with number"), 1, "error's first line logged once")
end)

test("missing game functions are named and nothing is called", function()
	local restore = setup()
	career_modules_insurance_insurance.onVehicleAddedToInventory = nil
	career_modules_insurance_insurance.getInvVehs = nil
	local summary = restore.ensureLoaded()
	same(ins.loads, 0, "game loads")
	same(summary.loaded, false, "loaded")
	same(countLines(logs, "W careerMP.insurance: missing getInvVehs, onVehicleAddedToInventory"), 1, "warning")
end)

test("a missing insurance module is reported", function()
	local restore = setup()
	career_modules_insurance_insurance = nil
	local summary = restore.ensureLoaded()
	same(summary.loaded, false, "loaded")
	same(countLines(logs, "W careerMP.insurance: missing career_modules_insurance_insurance"), 1, "warning")
end)
