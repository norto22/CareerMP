-- careerMP/purchaseInsurance.lua: a purchase screen opened without an insurance choice gets
-- the game's default policy when one exists, reloads the insurance records once when none
-- does, and otherwise opens with "no insurance" (-1) and a warning instead of failing.

local SOURCE = "Resources/Client/CareerMP/lua/ge/extensions/careerMP/purchaseInsurance.lua"

local SHOP_ID = 7

local logs, calls, game, opts

-- A fresh game. opts.policies: the policies loaded per class id ({[class] = policy}).
-- opts.reloadFills: the reload fills these policies. opts.reloadFails: the reload raises.
-- opts.listing: the listing for SHOP_ID (false: none). opts.noRestore: the insurance
-- restore extension is not loaded. opts.noDefaultLookup: the game has no
-- getDefaultInsuranceForClassId. opts.lookupFails: reading the listing raises.
local function setup(o)
	opts = o or {}
	logs, calls = {}, {}
	game = {reloads = 0, lookups = 0, policies = opts.policies or {}}

	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function setExtensionUnloadMode() end

	local listing = opts.listing
	if listing == nil then
		listing = {shopId = SHOP_ID, Brand = "Gavril", Name = "D-Series", insuranceClass = {id = "dailyDriver"}}
	end

	career_modules_vehicleShopping = {
		getVehicleInfoByShopId = function(shopId)
			game.lookups = game.lookups + 1
			if opts.lookupFails then error("vehicleShopping.lua:186: bad shop list\nstack") end
			if shopId == SHOP_ID and listing then return listing end
			return nil
		end,
	}
	career_modules_insurance_insurance = {}
	if not opts.noDefaultLookup then
		career_modules_insurance_insurance.getDefaultInsuranceForClassId = function(classId)
			return game.policies[classId]
		end
	end
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

--== an insurance choice was passed ==========================================

test("an explicit insurance choice is passed through without a lookup or reload", function()
	local purchase = setup()
	purchase.openPurchaseMenu(original, "dealership", SHOP_ID, 3)
	purchase.openPurchaseMenu(original, "dealership", SHOP_ID, -1)
	same(calls[1].insuranceId, 3, "chosen policy")
	same(calls[2].insuranceId, -1, "no insurance chosen")
	same(game.lookups, 0, "listing lookups")
	same(game.reloads, 0, "reloads")
	same(#logs, 0, "log lines")
end)

--== no insurance choice =====================================================

test("with policies loaded the game's own default is kept and nothing is reloaded", function()
	local purchase = setup({policies = {dailyDriver = {id = 1}}})
	purchase.openPurchaseMenu(original, "inspect", SHOP_ID)
	same(calls[1].insuranceId, nil, "insurance choice left to the game")
	same(game.reloads, 0, "reloads")
	same(#logs, 0, "log lines")
end)

test("missing policies are reloaded once, and the game picks the default when that helps", function()
	local purchase = setup({reloadFills = {dailyDriver = {id = 1}}})
	local picked, reason = purchase.pickInsurance(SHOP_ID, nil)
	same(picked, nil, "insurance choice left to the game")
	same(reason, nil, "reason")
	same(game.reloads, 1, "reloads")
	same(countLines(logs, "W careerMP.purchase:"), 0, "warnings")
end)

test("policies still missing after one reload give no insurance and say why", function()
	local purchase = setup()
	local picked, reason = purchase.pickInsurance(SHOP_ID, nil)
	same(picked, -1, "insurance choice")
	same(game.reloads, 1, "reloads")
	expect(reason and reason:find("Gavril D%-Series"), "the reason names the car: " .. tostring(reason))
	expect(reason:find("dailyDriver", 1, true) and reason:find("reload", 1, true),
		"the reason names the class and the reload: " .. reason)
end)

test("a listing with no insurance class opens with no insurance and no reload", function()
	local purchase = setup({listing = {shopId = SHOP_ID, Brand = "Ibishu", Name = "Pigeon"}})
	purchase.openPurchaseMenu(original, "inspect", SHOP_ID)
	same(calls[1].insuranceId, -1, "insurance choice")
	same(game.reloads, 0, "reloads")
	same(countLines(logs, "W careerMP.purchase:"), 1, "one warning")
	same(countLines(logs, "no insurance class"), 1, "the warning says why")
end)

test("a missing insurance restore extension gives no insurance and says so", function()
	local purchase = setup({noRestore = true})
	purchase.openPurchaseMenu(original, "inspect", SHOP_ID)
	same(calls[1].insuranceId, -1, "insurance choice")
	same(countLines(logs, "careerMP_insuranceRestore"), 1, "the warning names the missing extension")
end)

test("a reload that raises gives no insurance with the error's first line logged", function()
	local purchase = setup({reloadFails = true})
	purchase.openPurchaseMenu(original, "inspect", SHOP_ID)
	same(calls[1].insuranceId, -1, "insurance choice")
	same(game.reloads, 1, "reloads")
	same(countLines(logs, "insurance.lua:682: attempt to compare nil with number"), 1, "the error is logged")
	same(countLines(logs, "stack"), 0, "only the first line")
end)

--== the game is not as expected: leave the choice to the game =================

test("a missing listing leaves the choice to the game with a warning", function()
	local purchase = setup({listing = false})
	purchase.openPurchaseMenu(original, "inspect", SHOP_ID)
	same(calls[1].insuranceId, nil, "insurance choice left to the game")
	same(game.reloads, 0, "reloads")
	same(countLines(logs, "W careerMP.purchase:"), 1, "one warning")
	same(countLines(logs, "no listing for shop " .. SHOP_ID), 1, "the warning says why")
end)

test("a missing game function leaves the choice to the game with a warning", function()
	local purchase = setup({noDefaultLookup = true})
	purchase.openPurchaseMenu(original, "inspect", SHOP_ID)
	same(calls[1].insuranceId, nil, "insurance choice left to the game")
	same(countLines(logs, "W careerMP.purchase: missing career_modules_insurance_insurance.getDefaultInsuranceForClassId"),
		1, "the warning names the function")
end)

test("a pick that raises falls back to the caller's arguments with an error line", function()
	local purchase = setup({lookupFails = true})
	local result = purchase.openPurchaseMenu(original, "inspect", SHOP_ID)
	same(result, "opened", "the game's purchase menu result")
	same(calls[1].purchaseType, "inspect", "purchase type")
	same(calls[1].shopId, SHOP_ID, "shop id")
	same(calls[1].insuranceId, nil, "insurance choice left to the game")
	same(countLines(logs, "E careerMP.purchase:"), 1, "one error line")
	same(countLines(logs, "bad shop list"), 1, "the error is logged")
end)

--== filling the purchase screen =============================================

test("the purchase data wrapper passes the game's arguments and results through", function()
	local purchase = setup()
	local a, b = purchase.sendPurchaseDataToUi(function(x) return x, "second" end, "first")
	same(a, "first", "first result")
	same(b, "second", "second result")
	same(#logs, 0, "log lines")
end)

test("the purchase data wrapper logs a failure and raises it again", function()
	local purchase = setup()
	local failure = "vehicleShopping.lua:793: attempt to index a nil value\nstack"
	local ok, err = pcall(purchase.sendPurchaseDataToUi, function() error(failure, 0) end)
	same(ok, false, "the failure is raised again")
	same(err, failure, "the same error")
	same(countLines(logs, "E careerMP.purchase: purchase screen data failed: vehicleShopping.lua:793: attempt to index a nil value"),
		1, "the failure is logged")
	same(countLines(logs, "stack"), 0, "only the first line")
end)
