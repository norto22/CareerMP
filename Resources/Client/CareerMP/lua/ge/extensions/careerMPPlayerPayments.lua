--CareerMP :: player payments (CLIENT)
--
-- Career money is per-save and entirely client-side, so there is no way to hand
-- another player cash. This adds one: the sender deducts locally only after the
-- server confirms, and the receiver credits on the server's say-so. The server
-- holds the rate-limit ledger (short/long window plus session caps) and is the
-- only thing that can authorise a transfer -- see Resources/Server.
--
-- Game APIs used: playerAttributes get/addAttributes, saveSystem.saveCurrent and
-- the toastrMsg guihook.
--
-- Called from the player list UI app: careerMPPlayerPayments.payPlayer(name, amount)

local M = {}

local logTag = "careerMP.payments"

local nickname = nil

-- Local cooldown so the UI cannot spam the server; the server rate-limits too.
local paymentAllowed = false
local paymentTimer = 0
local paymentTimerThreshold = 2.125
local paymentID = 1

local function toast(kind, title, msg)
	guihooks.trigger('toastrMsg', {
		type = kind,
		title = title,
		msg = msg,
		config = { timeOut = 2000 },
	})
end

local function payPlayer(player_name, amount)
	if not paymentAllowed then return end

	amount = tonumber(amount)
	if not amount then
		toast("error", "Invalid transaction!", "That is not a valid amount.")
		return
	end
	amount = math.abs(amount)

	if not player_name or player_name == nickname then
		toast("error", "Invalid transaction!", "You cannot pay yourself!")
		return
	end

	local money = career_modules_playerAttributes.getAttribute("money")
	if not money or not money.value then
		toast("error", "Invalid transaction!", "Player attribute not found!")
		return
	end

	if money.value - amount < 0 then
		toast("error", "Invalid transaction!", "You do not have enough money to pay " .. player_name .. "!")
		return
	end

	local players = MPVehicleGE.getPlayers()
	for _, playerData in pairs(players) do
		if playerData.name == player_name then
			-- Consume the cooldown only once we know we are actually sending.
			paymentTimer = 0
			paymentAllowed = false
			TriggerServerEvent("payPlayer", jsonEncode({
				money = amount,
				tags = {"gameplay"},
				label = "Paid player: " .. player_name,
				target_player_id = playerData.playerID,
				target_player_name = player_name,
			}))
			return
		end
	end

	toast("error", "Invalid transaction!", player_name .. " is not in this session.")
end

local function rxPayment(data)
	local paymentData = jsonDecode(data)
	if not paymentData then return end
	career_modules_playerAttributes.addAttributes(
		{money = paymentData.money},
		{tags = paymentData.tags, label = "Payment from player: " .. tostring(paymentData.sender)}
	)
	-- Save immediately: an unsaved transfer that is lost to a crash would be
	-- money created or destroyed from the other player's point of view.
	career_saveSystem.saveCurrent()
	toast("info", "Transaction #" .. paymentID,
		tostring(paymentData.sender) .. " paid you $" .. tostring(paymentData.money))
	paymentID = paymentID + 1
end

-- The sender's deduction happens here, not at send time, so a rejected or
-- rate-limited payment never costs anything.
local function rxConfirmation(data)
	local paymentData = jsonDecode(data)
	if not paymentData then return end
	career_modules_playerAttributes.addAttributes(
		{money = -paymentData.money},
		{tags = paymentData.tags, label = paymentData.label}
	)
	career_saveSystem.saveCurrent()
	toast("info", "Transaction #" .. paymentID,
		"You paid " .. tostring(paymentData.target_player_name) .. " $" .. tostring(paymentData.money))
	paymentID = paymentID + 1
end

local function rxBounce(data)
	local paymentData = jsonDecode(data)
	if not paymentData then return end
	toast("error", "Payment returned!",
		"You are being ratelimited! Your payment of $" .. tostring(paymentData.money) ..
		" to " .. tostring(paymentData.target_player_name) .. " was returned.")
end

local function rxDeny(data)
	local paymentData = jsonDecode(data)
	if not paymentData then return end
	toast("error", "Payments disabled!",
		"This server has disabled the player payment system! Your payment of $" ..
		tostring(paymentData.money) .. " to " .. tostring(paymentData.target_player_name) .. " was returned.")
end

local function onWorldReadyState(state)
	if state == 2 then
		nickname = MPConfig.getNickname()
	end
end

local function onUpdate(dtReal)
	if worldReadyState ~= 2 then return end
	if paymentAllowed then return end
	paymentTimer = paymentTimer + dtReal
	if paymentTimer > paymentTimerThreshold then
		paymentAllowed = true
	end
end

local function onExtensionLoaded()
	nickname = MPConfig.getNickname()
	AddEventHandler("rxPayment", rxPayment)
	AddEventHandler("rxBounce", rxBounce)
	AddEventHandler("rxConfirmation", rxConfirmation)
	AddEventHandler("rxDeny", rxDeny)
	log("I", logTag, "CareerMP Player Payments LOADED")
end

local function onExtensionUnloaded()
	log("I", logTag, "CareerMP Player Payments UNLOADED")
end

M.payPlayer = payPlayer

M.onWorldReadyState = onWorldReadyState
M.onUpdate = onUpdate

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
