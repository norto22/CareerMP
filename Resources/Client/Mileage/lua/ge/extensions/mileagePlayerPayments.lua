--Mileage :: player payments (CLIENT)
--
-- Career money is per-save and entirely client-side. A payment asks the server, which
-- checks the amount, the target and the sender's limits (short/long windows plus
-- session caps) and then moves the money as a transfer (mileage/transfers.lua): taken
-- from the sender's career first, then given to the receiver's, each confirmed by a
-- receipt from a finished save. A payment the server turns down comes back as rxBounce
-- or rxDeny and costs nothing.
--
-- Game APIs used: playerAttributes getAttribute and the toastrMsg guihook.
--
-- Called from the player list UI app: mileagePlayerPayments.payPlayer(name, amount)

local M = {}

local logTag = "mileage.payments"

local nickname = nil

-- Local cooldown so the UI cannot spam the server; the server rate-limits too.
local paymentAllowed = false
local paymentTimer = 0
local paymentTimerThreshold = 2.125

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
	if not amount or amount ~= amount or amount <= 0 or amount % 1 ~= 0 then
		toast("error", "Invalid transaction!", "Enter a whole number of dollars above $0.")
		return
	end

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
				target_player_id = playerData.playerID,
				target_player_name = player_name,
			}))
			return
		end
	end

	toast("error", "Invalid transaction!", player_name .. " is not in this session.")
end

-- why "money": the career did not have the money when the server asked for it.
local function rxBounce(data)
	local paymentData = jsonDecode(data)
	if not paymentData then return end
	if paymentData.why == "money" then
		toast("error", "Payment returned!",
			"You no longer had the money for your payment of $" .. tostring(paymentData.money) ..
			" to " .. tostring(paymentData.target_player_name) .. ", so nothing was paid.")
		return
	end
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
	AddEventHandler("rxBounce", rxBounce)
	AddEventHandler("rxDeny", rxDeny)
	log("I", logTag, "Mileage Player Payments LOADED")
end

local function onExtensionUnloaded()
	log("I", logTag, "Mileage Player Payments UNLOADED")
end

M.payPlayer = payPlayer

M.onWorldReadyState = onWorldReadyState
M.onUpdate = onUpdate

M.onExtensionLoaded = onExtensionLoaded
M.onExtensionUnloaded = onExtensionUnloaded

M.onInit = function() setExtensionUnloadMode(M, 'manual') end

return M
