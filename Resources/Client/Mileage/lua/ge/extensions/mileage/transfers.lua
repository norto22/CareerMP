--Mileage :: money transfers between careers (CLIENT)
--
-- The server moves money between players' careers as transfers: it asks the payer's
-- game to take an amount (rxMileageTake), then the receiver's game to give it
-- (rxMileageGive). This game applies each step once, writes the transfer's id into
-- career/mileage_receipts.json in the same save as the money, and sends its receipt
-- (mileageReceipt) only once the game reports that save finished (onSaveFinished, which
-- the save system fires solely for a completed save). The server resends a step until it
-- has the receipt, so an id this game already applied is answered again, never applied
-- twice. An id is forgotten only when the server says the transfer is settled
-- (rxMileageSettled).
--
-- Ids are "committed" (in a finished save, or read from the save on career start) or
-- "pending" (applied in memory, waiting for a save to finish). A crash or failed save
-- loses a pending change together with its id, so the server's resend applies it again.
--
-- A take this career cannot afford is refused; the refusal is kept like an applied id,
-- so a resend that crosses it is refused again rather than taken.

local M = {}

local logTag = "mileage.transfers"

local RECEIPTS_FILE = "/career/mileage_receipts.json"
local SAVE_WAIT_SECONDS = 10

local committed = {}   -- id -> "taken" | "given" | "refused"
local pending = {}     -- id -> "taken" | "given"
local saving = nil     -- ids whose save is under way: {id = done}
local savingFor = 0    -- seconds that save has been under way
local saveWanted = false
local careerActive = false

local function sendReceipt(id, done)
	TriggerServerEvent("mileageReceipt", jsonEncode({id = id, done = done}))
end

local function toast(kind, title, msg)
	guihooks.trigger("toastrMsg", {type = kind, title = title, msg = msg, config = {timeOut = 4000}})
end

local function savePath()
	local compat = extensions.mileage_compat
	if type(compat) ~= "table" or type(compat.getSavePath) ~= "function" then return nil end
	return compat.getSavePath()
end

local function readReceipts()
	committed, pending, saving, saveWanted = {}, {}, nil, false
	local path = savePath()
	if not path then return end
	local ok, data = pcall(jsonReadFile, path .. RECEIPTS_FILE)
	if not ok then
		log("E", logTag, "could not read the receipts: " .. tostring(data))
		return
	end
	if type(data) == "table" and type(data.applied) == "table" then
		for id, done in pairs(data.applied) do
			if type(id) == "string" and (done == "taken" or done == "given" or done == "refused") then
				committed[id] = done
			end
		end
	end
end

-- Starts a save, or asks for one after the save under way.
local function save()
	if saving then
		saveWanted = true
		return
	end
	local ok, err = pcall(function() career_saveSystem.saveCurrent() end)
	if not ok then log("E", logTag, "career save failed: " .. tostring(err)) end
end

local function money()
	local attribute = career_modules_playerAttributes.getAttribute("money")
	return attribute and tonumber(attribute.value) or nil
end

local function validStep(step)
	return type(step) == "table" and type(step.id) == "string" and type(step.amount) == "number"
		and step.amount > 0 and step.amount % 1 == 0
end

-- A step of a transfer: sign -1 takes, +1 gives.
local function applyStep(data, sign)
	if not careerActive then return end
	local step = jsonDecode(data)
	if not validStep(step) then return end
	local done = sign < 0 and "taken" or "given"
	local known = committed[step.id]
	if known then
		sendReceipt(step.id, known)
		return
	end
	if pending[step.id] then
		-- Applied, not yet in a finished save: the receipt follows that save.
		save()
		return
	end
	if sign < 0 then
		local current = money()
		if not current or current < step.amount then
			committed[step.id] = "refused"
			sendReceipt(step.id, "refused")
			return
		end
	end
	local label = type(step.label) == "string" and step.label or ""
	career_modules_playerAttributes.addAttributes({money = sign * step.amount},
		{tags = type(step.tags) == "table" and step.tags or {"gameplay"}, label = label})
	pending[step.id] = done
	if label ~= "" then
		toast("info", label, (sign < 0 and "-$" or "+$") .. tostring(step.amount))
	end
	save()
end

local function rxMileageTake(data) applyStep(data, -1) end
local function rxMileageGive(data) applyStep(data, 1) end

local function rxMileageSettled(data)
	local settled = jsonDecode(data)
	if type(settled) ~= "table" or type(settled.ids) ~= "table" then return end
	for _, id in ipairs(settled.ids) do
		if type(id) == "string" then committed[id] = nil end
	end
end

--== the game's save hooks ===================================================

-- Writes every id this career has applied, pending ones included, into the save the game
-- is writing now, beside the money they changed.
function M.onSaveCurrentProfile(currentSavePath)
	if not careerActive or type(currentSavePath) ~= "string" then return end
	local applied = {}
	for id, done in pairs(committed) do applied[id] = done end
	saving = {}
	for id, done in pairs(pending) do
		applied[id] = done
		saving[id] = done
	end
	savingFor = 0
	career_saveSystem.jsonWriteFileSafe(currentSavePath .. RECEIPTS_FILE, {applied = applied}, true)
end

-- The save finished: what it held is committed, and its receipts go to the server.
function M.onSaveFinished()
	local finished = saving
	saving = nil
	if finished then
		for id, done in pairs(finished) do
			if pending[id] == done then
				pending[id] = nil
				committed[id] = done
				sendReceipt(id, done)
			end
		end
	end
	if saveWanted or next(pending) then
		saveWanted = false
		if next(pending) then save() end
	end
end

-- The game never reports a failed save, it only leaves out onSaveFinished. After
-- SAVE_WAIT_SECONDS the save counts as failed: its ids stay pending, unacknowledged, and
-- the server's next resend starts another save.
function M.onUpdate(dtReal)
	if not saving then return end
	savingFor = savingFor + math.max(0, math.min(1, tonumber(dtReal) or 0))
	if savingFor >= SAVE_WAIT_SECONDS then
		log("W", logTag, string.format("the career save did not finish within %d s; receipts wait for the next save",
			SAVE_WAIT_SECONDS))
		saving, saveWanted = nil, false
	end
end

function M.onCareerActive(active)
	careerActive = active == true
	if careerActive then
		readReceipts()
	else
		committed, pending, saving, saveWanted = {}, {}, nil, false
	end
end

function M.onExtensionLoaded()
	if type(AddEventHandler) ~= "function" then
		log("E", logTag, "AddEventHandler unavailable - BeamMP not loaded")
		return
	end
	AddEventHandler("rxMileageTake", rxMileageTake)
	AddEventHandler("rxMileageGive", rxMileageGive)
	AddEventHandler("rxMileageSettled", rxMileageSettled)
	log("I", logTag, "Mileage transfers LOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
