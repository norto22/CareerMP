-- careerMP/purchaseInsurance.lua: a purchase screen opened without an insurance choice gets
-- the game's default policy when one exists, reloads the insurance records once when none
-- does, and otherwise opens with "no insurance" (-1) and a warning instead of failing.

local SOURCE = "Resources/Client/CareerMP/lua/ge/extensions/careerMP/purchaseInsurance.lua"

local SHOP_ID = 7

local logs, calls, game, opts

-- A fresh game. opts.policies: the policies loaded per class id ({[class] = policy}).
-- opts.reloadFills: the reload fills these policies. opts.reloadFails: the reload raises.
-- opts.listing: the listing for SHOP_ID (false: none). opts.noRestore: the insurance
-- restore extension is not loaded.
local function setup(o)
	opts = o or {}
	logs, calls = {}, {}
	game = {reloads = 0, policies = opts.policies or {}}

	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end

	local listing = opts.listing
	if listing == nil then listing = {shopId = SHOP_ID, insuranceClass = {id = "dailyDriver"}} end

	career_modules_vehicleShopping = {
		getVehicleInfoByShopId = function(shopId)
			if shopId == SHOP_ID and listing then return listing end
			return nil
		end,
	}
	career_modules_insurance_insurance = {
		getDefaultInsuranceForClassId = function(classId) return game.policies[classId] end,
	}
	extensions = {}
	if not opts.noRestore then
		extensions.careerMP_insuranceRestore = {
			ensureLoaded = function()
				game.reloads = game.reloads + 1
				if opts.reloadFails then error("insurance.lua:682: attempt to compare nil with number\nstack") end
				if opts.reloadFills then game.policies = opts.reloadFills end
				return {loaded = true}
			end,
		}
	end

	return dofile(SOURCE)
end

-- The game's openPurchaseMenu, recording what it was called with.
local function original(purchaseType, shopId, insuranceId)
	table.insert(calls, {purchaseType = purchaseType, shopId = shopId, insuranceId = insuranceId})
	return "opened"
end

--== reproduction ============================================================

test("a private listing with no policies loaded opens with no insurance and a warning", function()
	local purchase = setup()
	local result = purchase.openPurchaseMenu(original, "inspect", SHOP_ID)
	same(result, "opened", "the game's purchase menu result")
	same(#calls, 1, "the game's purchase menu was opened")
	same(calls[1].purchaseType, "inspect", "purchase type")
	same(calls[1].shopId, SHOP_ID, "shop id")
	same(calls[1].insuranceId, -1, "insurance choice")
	same(countLines(logs, "W careerMP.purchase:"), 1, "one warning")
	same(countLines(logs, "shop " .. SHOP_ID), 1, "the warning names the car")
end)
