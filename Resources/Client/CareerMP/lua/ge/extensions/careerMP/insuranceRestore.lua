--CareerMP :: insurance records after a join
--
-- The game's insurance module (career/modules/insurance/insurance.lua) loads its records
-- only when the career starts. On a CareerMP join that load does not always finish, and
-- the records stay empty: the Insurances page lists no insurers, and the repair screen
-- crashes looking up the car's insurance record ("attempt to index a nil value" in
-- getRepairData), so Repair at the garage computer never opens.
--
-- Once the join's career start has settled, ensureLoaded() checks the records and, when
-- they never loaded, runs the insurance module's own career-start load. If the player's
-- server save already holds the empty insurance file the missing records leave behind
-- (no insurers and no cars), that file is copied to insurance.careermp-backup.json, the
-- copy is read back, and only then is the file blanked so the game builds fresh
-- defaults. Owned cars that still have no record are then registered through the game's
-- own "vehicle added to inventory" step, which records them as uninsured.
--
-- Records that loaded normally are never reloaded: that would throw away the player's
-- unsaved insurance changes.

local M = {}

local logTag = "careerMP.insurance"

local REQUIRED = {"getDriverScore", "onCareerActive", "getInvVehs", "onVehicleAddedToInventory"}

local function firstLine(text)
	return tostring(text):match("^[^\n]*") or ""
end

local function isEmpty(t)
	return type(t) ~= "table" or next(t) == nil
end

local function sameKeys(a, b)
	for k in pairs(a) do if b[k] == nil then return false end end
	for k in pairs(b) do if a[k] == nil then return false end end
	return true
end

-- The save folder, read the way the game's insurance load reads it. careerMP_compat's
-- getCurrentProfile keeps only the first return value (the name), so it is not used here.
local function savePath()
	local saveSystem = career_saveSystem
	if type(saveSystem) ~= "table" then return nil end
	local current = saveSystem.getCurrentProfile or saveSystem.getCurrentSaveSlot
	if type(current) ~= "function" then return nil end
	local _, path = current()
	return path
end

local function writeFile(file, data)
	return pcall(career_saveSystem.jsonWriteFileSafe, file, data, true)
end

-- Resets the saved insurance file when it has the empty shape the missing records write,
-- after a backup that reads back the same. Returns true when the file was reset.
local function resetEmptySave(path)
	local file = path .. "/career/insurance.json"
	local data = jsonReadFile(file)
	if type(data) ~= "table" or type(data.invVehs) ~= "table" or not isEmpty(data.plInsurancesData) then
		return false
	end
	if not isEmpty(data.invVehs) then
		log("W", logTag, "no insurers saved but car records remain in " .. file .. " - left unchanged")
		return false
	end

	local backup = path .. "/career/insurance.careermp-backup.json"
	local ok, err = writeFile(backup, data)
	if not ok then
		log("E", logTag, "could not write " .. backup .. " (" .. firstLine(err) .. ") - " .. file .. " left unchanged")
		return false
	end
	local copy = jsonReadFile(backup)
	if type(copy) ~= "table" or not sameKeys(copy, data)
			or isEmpty(copy.invVehs) ~= isEmpty(data.invVehs)
			or isEmpty(copy.plInsurancesData) ~= isEmpty(data.plInsurancesData) then
		log("E", logTag, backup .. " does not read back as written - " .. file .. " left unchanged")
		return false
	end

	ok, err = writeFile(file, {})
	if not ok then
		log("E", logTag, "could not reset " .. file .. " (" .. firstLine(err) .. ")")
		return false
	end
	log("I", logTag, "empty insurance save " .. file .. " reset, original kept in " .. backup)
	return true
end

-- Registers owned cars with no insurance record as uninsured. Returns how many went through.
local function addUninsuredCars(ins)
	local inventory = career_modules_inventory
	if type(inventory) ~= "table" or type(inventory.getVehicles) ~= "function" then
		log("W", logTag, "missing career_modules_inventory.getVehicles - cars without a record not checked")
		return 0
	end
	local records = ins.getInvVehs() or {}
	local added, ids = 0, {}
	for inventoryId, veh in pairs(inventory.getVehicles() or {}) do
		if type(veh) == "table" and veh.owned and not records[inventoryId] then
			local ok, err = xpcall(ins.onVehicleAddedToInventory, debug.traceback, {inventoryId = inventoryId})
			if ok then
				added = added + 1
				table.insert(ids, tostring(inventoryId))
			else
				log("E", logTag, "could not register car " .. tostring(inventoryId) .. ": " .. firstLine(err))
			end
		end
	end
	if added > 0 then
		log("I", logTag, "registered as uninsured: car " .. table.concat(ids, ", car "))
	end
	return added
end

--- Loads the insurance records if they never loaded and registers owned cars that have no
--- record. Returns {loaded, reloaded (the game's load was run), backedUp, added, error}.
function M.ensureLoaded()
	local summary = {loaded = false, reloaded = false, backedUp = false, added = 0, error = nil}

	local ins = career_modules_insurance_insurance
	if type(ins) ~= "table" then
		summary.error = "missing career_modules_insurance_insurance"
		log("W", logTag, summary.error)
		return summary
	end
	local missing = {}
	for _, name in ipairs(REQUIRED) do
		if type(ins[name]) ~= "function" then table.insert(missing, name) end
	end
	if #missing > 0 then
		summary.error = "missing " .. table.concat(missing, ", ")
		log("W", logTag, summary.error .. " on career_modules_insurance_insurance")
		return summary
	end

	summary.loaded = ins.getDriverScore() ~= nil
	if not summary.loaded then
		log("I", logTag, "insurance records were not loaded by the career start - loading them")
		local path = savePath()
		if path then summary.backedUp = resetEmptySave(path) end

		summary.reloaded = true
		local ok, err = xpcall(ins.onCareerActive, debug.traceback, true)
		summary.loaded = ins.getDriverScore() ~= nil
		if not ok then
			summary.error = firstLine(err)
			log("E", logTag, "the game's insurance load failed: " .. summary.error)
		elseif not summary.loaded then
			summary.error = "records still empty after the game's insurance load"
			log("E", logTag, summary.error)
		end
	end

	if summary.loaded then summary.added = addUninsuredCars(ins) end

	log("I", logTag, string.format("loaded=%s reloaded=%s backedUp=%s added=%d",
		tostring(summary.loaded), tostring(summary.reloaded), tostring(summary.backedUp), summary.added))
	return summary
end

function M.onExtensionLoaded()
	log("I", logTag, "CareerMP insurance restore LOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
