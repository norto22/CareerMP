--CareerMP :: insurance choice on the purchase screen
--
-- The private seller's "See Purchase Information" button opens the purchase screen without
-- an insurance choice (career/modules/inspectVehicle.lua), so the game's vehicle shopping
-- module picks the default policy for the car's insurance class when it fills the screen
-- (sendPurchaseDataToUi). When the insurance records did not load on a CareerMP join, no
-- default policy exists, the game reads ".id" from nothing, and the screen never gets its
-- data: the prompt goes away and nothing appears.
--
-- Before a purchase screen opens without an insurance choice, pickInsurance() looks the
-- default up itself. When it exists the call is left untouched. When it is missing, the
-- insurance records are loaded again once (careerMP_insuranceRestore.ensureLoaded); if that
-- does not help, or the listing has no insurance class, the screen opens with "no insurance"
-- (the game's own -1) and a warning says why. The player can add insurance later at the
-- garage computer.
--
-- careerMP/patches installs the two wrappers below on career_modules_vehicleShopping.

local M = {}

local logTag = "careerMP.purchase"

-- The game's "no insurance picked" value.
local NO_INSURANCE = -1

local function firstLine(text)
	return tostring(text):match("^[^\n]*") or ""
end

local function pack(...)
	return {n = select("#", ...), ...}
end

local function describe(shopId, listing)
	local name = {}
	if listing.Brand then table.insert(name, tostring(listing.Brand)) end
	if listing.Name then table.insert(name, tostring(listing.Name)) end
	if #name == 0 then return "shop " .. tostring(shopId) end
	return string.format("shop %s (%s)", tostring(shopId), table.concat(name, " "))
end

local function hasDefault(ins, classId)
	local policy = ins.getDefaultInsuranceForClassId(classId)
	return type(policy) == "table" and policy.id ~= nil
end

-- Returns the insurance choice to open the purchase screen with:
--   insuranceId unchanged when the caller passed one, or when the game is not as expected;
--   nil when the game's own default policy exists (stock behaviour);
--   -1 ("no insurance") when no default policy exists after one reload, or the listing has
--   no insurance class.
-- The second value is a short reason for the log, nil when nothing was changed.
function M.pickInsurance(shopId, insuranceId)
	if insuranceId ~= nil then return insuranceId end

	local shop = career_modules_vehicleShopping
	if type(shop) ~= "table" or type(shop.getVehicleInfoByShopId) ~= "function" then
		log("W", logTag, "missing career_modules_vehicleShopping.getVehicleInfoByShopId - insurance choice left to the game")
		return insuranceId
	end
	local ins = career_modules_insurance_insurance
	if type(ins) ~= "table" or type(ins.getDefaultInsuranceForClassId) ~= "function" then
		log("W", logTag, "missing career_modules_insurance_insurance.getDefaultInsuranceForClassId - insurance choice left to the game")
		return insuranceId
	end

	local listing = shop.getVehicleInfoByShopId(shopId)
	if type(listing) ~= "table" then
		log("W", logTag, "no listing for shop " .. tostring(shopId) .. " - insurance choice left to the game")
		return insuranceId
	end
	local car = describe(shopId, listing)

	local classId = type(listing.insuranceClass) == "table" and listing.insuranceClass.id or nil
	if classId == nil then
		return NO_INSURANCE, car .. ": the listing has no insurance class"
	end
	if hasDefault(ins, classId) then return nil end

	local restore = extensions and extensions.careerMP_insuranceRestore
	if type(restore) ~= "table" or type(restore.ensureLoaded) ~= "function" then
		return NO_INSURANCE, string.format(
			"%s: no insurance policy for class %s, and careerMP_insuranceRestore is not loaded to reload them",
			car, tostring(classId))
	end
	local ok, err = pcall(restore.ensureLoaded)
	if not ok then
		return NO_INSURANCE, string.format("%s: no insurance policy for class %s, and reloading the insurance records failed: %s",
			car, tostring(classId), firstLine(err))
	end
	if hasDefault(ins, classId) then
		log("I", logTag, car .. ": insurance records reloaded, the default policy is now available")
		return nil
	end
	return NO_INSURANCE, string.format("%s: no insurance policy for class %s, even after reloading the insurance records",
		car, tostring(classId))
end

-- Wraps career_modules_vehicleShopping.openPurchaseMenu(purchaseType, shopId, insuranceId).
function M.openPurchaseMenu(original, purchaseType, shopId, insuranceId, ...)
	local ok, picked, reason = pcall(M.pickInsurance, shopId, insuranceId)
	if not ok then
		log("E", logTag, string.format("could not pick the insurance for shop %s: %s - insurance choice left to the game",
			tostring(shopId), firstLine(picked)))
		picked = insuranceId
	elseif reason then
		log("W", logTag, reason .. " - the purchase screen opens with no insurance")
	end
	return original(purchaseType, shopId, picked, ...)
end

-- Wraps career_modules_vehicleShopping.sendPurchaseDataToUi(...): a failure while the purchase
-- screen is filled is logged under CareerMP's name, then raised again for the game to handle.
function M.sendPurchaseDataToUi(original, ...)
	local results = pack(pcall(original, ...))
	if not results[1] then
		log("E", logTag, "purchase screen data failed: " .. firstLine(results[2]))
		error(results[2], 0)
	end
	return unpack(results, 2, results.n)
end

function M.onExtensionLoaded()
	log("I", logTag, "CareerMP purchase insurance LOADED")
end

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
