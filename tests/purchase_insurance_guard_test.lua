-- The purchase insurance guard as the game reaches it: careerMP/patches installs it on
-- career_modules_vehicleShopping, the mod script loads careerMP/purchaseInsurance, and the
-- insurance pick holds at its boundaries (a policy id of 0, a policy with no id, an
-- insurance class with no id, a game without the listing lookup, an error that is not text).

local PATCHES = "Resources/Client/CareerMP/lua/ge/extensions/careerMP/patches.lua"
local PURCHASE = "Resources/Client/CareerMP/lua/ge/extensions/careerMP/purchaseInsurance.lua"
local MOD_SCRIPT = "Resources/Client/CareerMP/scripts/CareerMP/modScript.lua"

local SHOP_ID = 7

local logs, calls, game

-- A fresh game with a private listing for SHOP_ID. o.policies: loaded policies per class.
-- o.listing: the listing (overrides the default). o.noListingLookup: the shop module has no
-- getVehicleInfoByShopId. o.noSendData: the shop module has no sendPurchaseDataToUi.
local function setupGame(o)
	o = o or {}
	logs, calls = {}, {}
	game = {reloads = 0, lookups = 0, policies = o.policies or {}}

	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. tostring(msg)) end
	function setExtensionUnloadMode() end
	deepcopy = deepcopy or function(t)
		local r = {}
		for k, v in pairs(t) do r[k] = v end
		return r
	end

	local listing = o.listing
	if listing == nil then
		listing = {shopId = SHOP_ID, Brand = "Gavril", Name = "D-Series", insuranceClass = {id = "dailyDriver"}}
	end

	career_modules_vehicleShopping = {
		openPurchaseMenu = function(purchaseType, shopId, insuranceId)
			table.insert(calls, {purchaseType = purchaseType, shopId = shopId, insuranceId = insuranceId})
			return "opened"
		end,
	}
	if not o.noListingLookup then
		career_modules_vehicleShopping.getVehicleInfoByShopId = function(shopId)
			game.lookups = game.lookups + 1
			if shopId == SHOP_ID then return listing end
			return nil
		end
	end
	if not o.noSendData then
		career_modules_vehicleShopping.sendPurchaseDataToUi = function() return "sent" end
	end
	career_modules_insurance_insurance = {
		getDefaultInsuranceForClassId = function(classId) return game.policies[classId] end,
	}
	extensions = {
		careerMP_insuranceRestore = {
			ensureLoaded = function()
				game.reloads = game.reloads + 1
				return {loaded = true}
			end,
		},
	}
end

local function original(purchaseType, shopId, insuranceId)
	table.insert(calls, {purchaseType = purchaseType, shopId = shopId, insuranceId = insuranceId})
	return "opened"
end

--== patches installs the guard ================================================

test("patches routes the game's purchase menu through the purchase insurance extension", function()
	setupGame()
	local patches = dofile(PATCHES)
	patches.apply()
	extensions.careerMP_purchaseInsurance = dofile(PURCHASE)
	local result = career_modules_vehicleShopping.openPurchaseMenu("inspect", SHOP_ID)
	same(result, "opened", "the game's purchase menu result")
	same(#calls, 1, "the game's purchase menu was opened")
	same(calls[1].insuranceId, -1, "insurance choice with no policies loaded")
	same(game.reloads, 1, "reloads")
	same(countLines(logs, "W careerMP.purchase:"), 1, "one warning")
end)

test("with the purchase insurance extension not loaded the game's purchase menu is called untouched", function()
	setupGame()
	local patches = dofile(PATCHES)
	patches.apply()
	local result = career_modules_vehicleShopping.openPurchaseMenu("inspect", SHOP_ID)
	same(result, "opened", "the game's purchase menu result")
	same(calls[1].insuranceId, nil, "insurance choice left to the game")
	same(game.lookups, 0, "listing lookups")
	same(career_modules_vehicleShopping.sendPurchaseDataToUi(), "sent", "the game's purchase data result")
end)

test("a game without sendPurchaseDataToUi is reported in the patch failure list", function()
	setupGame({noSendData = true})
	local patches = dofile(PATCHES)
	same(patches.apply(), false, "patches applied")
	local listed = false
	for _, name in ipairs(patches.getFailures()) do
		if name == "career_modules_vehicleShopping.sendPurchaseDataToUi" then listed = true end
	end
	expect(listed, "career_modules_vehicleShopping.sendPurchaseDataToUi is in the failure list")
	same(countLines(logs, "cannot replace career_modules_vehicleShopping.sendPurchaseDataToUi (missing)"), 1,
		"the missing target is logged")
end)

--== the mod script loads it ===================================================

test("the mod loads purchaseInsurance after insuranceRestore and keeps it across level switches", function()
	local loaded, modes = {}, {}
	local realLoad = load
	load = function(path) table.insert(loaded, path) end
	setExtensionUnloadMode = function(path, mode) modes[path] = mode end
	local ok, err = pcall(dofile, MOD_SCRIPT)
	load = realLoad
	expect(ok, tostring(err))
	local at = {}
	for i, path in ipairs(loaded) do at[path] = i end
	expect(at["careerMP/purchaseInsurance"] ~= nil, "careerMP/purchaseInsurance is loaded")
	expect(at["careerMP/purchaseInsurance"] > at["careerMP/insuranceRestore"], "loaded after insuranceRestore")
	same(modes["careerMP/purchaseInsurance"], "manual", "unload mode")
end)

--== the insurance pick at its boundaries =====================================

test("an explicit policy id of 0 is passed through without a lookup", function()
	setupGame()
	local purchase = dofile(PURCHASE)
	purchase.openPurchaseMenu(original, "dealership", SHOP_ID, 0)
	same(calls[1].insuranceId, 0, "chosen policy")
	same(game.lookups, 0, "listing lookups")
	same(#logs, 0, "log lines")
end)

test("a default policy with no id counts as missing and opens with no insurance", function()
	setupGame({policies = {dailyDriver = {name = "Basic"}}})
	local purchase = dofile(PURCHASE)
	purchase.openPurchaseMenu(original, "inspect", SHOP_ID)
	same(calls[1].insuranceId, -1, "insurance choice")
	same(game.reloads, 1, "reloads")
	same(countLines(logs, "W careerMP.purchase:"), 1, "one warning")
end)

test("an insurance class with no id opens with no insurance and no reload", function()
	setupGame({listing = {shopId = SHOP_ID, Brand = "Ibishu", Name = "Pigeon", insuranceClass = {}}})
	local purchase = dofile(PURCHASE)
	purchase.openPurchaseMenu(original, "inspect", SHOP_ID)
	same(calls[1].insuranceId, -1, "insurance choice")
	same(game.reloads, 0, "reloads")
	same(countLines(logs, "no insurance class"), 1, "the warning says why")
end)

test("a game without the listing lookup leaves the choice to the game with a warning", function()
	setupGame({noListingLookup = true})
	local purchase = dofile(PURCHASE)
	purchase.openPurchaseMenu(original, "inspect", SHOP_ID)
	same(calls[1].insuranceId, nil, "insurance choice left to the game")
	same(countLines(logs, "W careerMP.purchase: missing career_modules_vehicleShopping.getVehicleInfoByShopId"),
		1, "the warning names the function")
	same(countLines(logs, "E careerMP.purchase:"), 0, "no error line")
end)

test("the purchase data wrapper raises a non-text error again unchanged", function()
	setupGame()
	local purchase = dofile(PURCHASE)
	local failure = {code = "nil-policy"}
	local ok, err = pcall(purchase.sendPurchaseDataToUi, function() error(failure) end)
	same(ok, false, "the failure is raised again")
	same(err, failure, "the same error object")
	same(countLines(logs, "E careerMP.purchase: purchase screen data failed:"), 1, "the failure is logged")
end)

--== the installed guard across the patch lifecycle ===========================

test("a failure filling the purchase screen through the installed guard is logged once and raised again, after the retry applies twice", function()
	setupGame()
	career_modules_vehicleShopping.sendPurchaseDataToUi = function()
		error("vehicleShopping.lua:793: attempt to index a nil value\nstack traceback: ...", 0)
	end
	local patches = dofile(PATCHES)
	patches.apply()
	patches.apply() -- the retry loop calls apply() again while other targets are missing
	extensions.careerMP_purchaseInsurance = dofile(PURCHASE)
	local ok, err = pcall(career_modules_vehicleShopping.sendPurchaseDataToUi)
	same(ok, false, "the failure is raised again")
	expect(tostring(err):find("vehicleShopping.lua:793", 1, true) ~= nil, "the game's error: " .. tostring(err))
	same(countLines(logs, "E careerMP.purchase: purchase screen data failed: vehicleShopping.lua:793: attempt to index a nil value"),
		1, "one failure line")
	same(countLines(logs, "stack traceback"), 0, "no stack line in the log")
end)

test("patches.revert() puts the game's own purchase menu and purchase data functions back", function()
	setupGame()
	local openOriginal = career_modules_vehicleShopping.openPurchaseMenu
	local sendOriginal = career_modules_vehicleShopping.sendPurchaseDataToUi
	local patches = dofile(PATCHES)
	patches.apply()
	expect(career_modules_vehicleShopping.openPurchaseMenu ~= openOriginal, "openPurchaseMenu is guarded")
	expect(career_modules_vehicleShopping.sendPurchaseDataToUi ~= sendOriginal, "sendPurchaseDataToUi is guarded")
	patches.revert()
	same(career_modules_vehicleShopping.openPurchaseMenu, openOriginal, "openPurchaseMenu after revert")
	same(career_modules_vehicleShopping.sendPurchaseDataToUi, sendOriginal, "sendPurchaseDataToUi after revert")
end)

test("a career start that reloads the shop module gets the guard on the new module", function()
	setupGame()
	local patches = dofile(PATCHES)
	patches.apply()
	extensions.careerMP_purchaseInsurance = dofile(PURCHASE)
	-- The career start loads the career modules again: a fresh shop module table.
	local fresh = {}
	for k, v in pairs(career_modules_vehicleShopping) do fresh[k] = v end
	fresh.openPurchaseMenu = function(purchaseType, shopId, insuranceId)
		table.insert(calls, {purchaseType = purchaseType, shopId = shopId, insuranceId = insuranceId, fresh = true})
		return "opened"
	end
	career_modules_vehicleShopping = fresh
	patches.onCareerActive(true)
	career_modules_vehicleShopping.openPurchaseMenu("inspect", SHOP_ID)
	same(#calls, 1, "the game's purchase menu was opened once")
	same(calls[1].fresh, true, "the new module's purchase menu ran")
	same(calls[1].insuranceId, -1, "insurance choice with no policies loaded")
	same(game.reloads, 1, "reloads")
end)
