--CareerMP (SERVER)
--Created by Dudekahedron
--Thanks to Bouboule, and Lion and Luuk from BeamPaint, for http request examples
--
--This file touches no game Lua -- it is pure BeamMP API (MP.*, Util.*, FS.*) -- so it
--does not depend on the BeamNG.drive version. The drag relay carries BeamNG's own
--multiplayer drag protocol between clients without interpreting it.

-- Identifies which CareerMP line these files belong to. The updater refuses any remote
-- version file that does not carry this exact value, so another repository's
-- higher-numbered releases are never pulled over this one. Keep it in sync with the
-- `lineage` field in versions/client.json and versions/server.json.
local LINEAGE = "norto22/CareerMP"

local HARD_CLIENT_VERSION = {major = 0, minor = 1, revision = 0, lineage = LINEAGE}
local HARD_SERVER_VERSION = {major = 0, minor = 1, revision = 0, lineage = LINEAGE}

local RAW = "https://raw.githubusercontent.com/"
local GITHUB_REPO = "norto22/CareerMP/"
local BRANCH = "main/"
local CLIENT_PATH = "Resources/Client/"
local CLIENT_FILE = "CareerMP.zip"
local SERVER_PATH = "Resources/Server/CareerMP/"
local SERVER_FILE = "careerMP.lua"
local CLIENT_VERSION_FILE = "versions/client.json"
local SERVER_VERSION_FILE = "versions/server.json"
local CLIENT_URL = RAW .. GITHUB_REPO .. BRANCH .. CLIENT_PATH .. CLIENT_FILE
local SERVER_URL = RAW .. GITHUB_REPO .. BRANCH .. SERVER_PATH .. SERVER_FILE
local CLIENT_UPDATE_URL = RAW .. GITHUB_REPO .. BRANCH .. SERVER_PATH .. CLIENT_VERSION_FILE
local SERVER_UPDATE_URL = RAW .. GITHUB_REPO .. BRANCH .. SERVER_PATH .. SERVER_VERSION_FILE

local configPath = "Resources/Server/CareerMP/config/"

local willExit = false

local defaultConfig = {
	server = {
		autoUpdate = true,
		autoExit = true,
		longWindowMax = 10000,
		shortWindowMax = 1000,
		longWindowSeconds = 300,
		shortWindowSeconds = 30,
		allowTransactions = true,
		sessionSendingMax = 100000,
		sessionReceiveMax = 200000,
	},
	client = {
		localUnicycleGhost = false,
		remoteUnicycleGhost = true,
		remoteVehicleGhost = false,
		serverSaveName = "",
		serverSaveSuffix = "",
		serverSaveNameEnabled = false,
		-- Traffic each player spawns, shared with every other player: a server with two
		-- players has twice these amounts on the map. 0 to 50 of each kind.
		roadTrafficAmount = 6,
		parkedTrafficAmount = 8,
		roadTrafficEnabled = true,
		parkedTrafficEnabled = true,
		worldEditorEnabled = false,
		consoleEnabled = false,
		simplifyRemoteVehicles = false,
		spawnVehicleIgnitionLevel = 0,
		skipOtherPlayersVehicles = false,
		trafficSmartSelections = true,
		trafficSimpleVehicles = true,
		trafficAllowMods = false,
		-- Head-to-head drag racing. On by default.
		--
		-- This un-stubs BeamNG 0.39's own multiplayer drag racing
		-- (gameplay/drag/core.lua getDragGamemode, which ships hard-wired to nil), so
		-- staging, the tree, timers and the result screen are the game's, driven over
		-- BeamMP. Two players drive to a strip, stage, and race on one synchronised tree.
		--
		-- Verified with two players at one strip on west_coast_usa, including solo runs,
		-- false starts and leaving AI drag missions alone. NOT verified with more than
		-- two, so treat a busy strip as untested.
		--
		-- Set false to go back to stock behaviour: drag racing still works exactly as it
		-- does in single player, just not synchronised between players. Worth doing if a
		-- BeamNG update breaks it - the client logs why on join, and falls back on its
		-- own rather than failing hard.
		nativeDragSyncEnabled = true
	}
}

-- Settings earlier versions wrote that are no longer read. prepareConfig removes them
-- from a config like any unknown setting, with this reason instead of "is invalid".
local retiredConfig = {
	client = {
		extraTrafficAmount = "extra traffic was never used by the game",
		extraTrafficEnabled = "extra traffic was never used by the game",
	},
}

-- Players whose career has not started yet, by player id. A player is dropped with
-- "CareerMP failed to load!" when no settings request arrives within activationThreshold
-- seconds of joining, or, for a client that confirms its career start, when the client
-- reports a failure or no confirmation arrives within startConfirmThreshold seconds of
-- the settings request. A client that does not confirm (an older client mod) counts as
-- started at its settings request.
local pendingActivation = {}
local activationThreshold = 90
local startConfirmThreshold = 60
local START_REASON_MAX_LENGTH = 200
local vehicleStates = {}
local loadedPrefabs = {}

local signalTimer = MP.CreateTimer()

-- Every connected player hears rxCareerMPAlive this often, in ticks of one second. A
-- client that hears nothing for ten seconds tells its player the server is gone.
local ALIVE_EVERY_TICKS = 2
local ticksSinceAlive = 0

local ledger = {
	send = {},
	receive = {}
}

local trapNames = {
	[1] = "Riverway Plaza",
	[2] = "Plaza Northbound",
	[3] = "Plaza Southbound",
	[4] = "Beach",
	[5] = "Lighthouse",
	[6] = "Island Port Northbound",
	[7] = "Island Port Southbound"
}

-- Runs the platform's downloader. Returns true only when the command reports success.
local function fetchTo(url, path)
	local result
	if MP.GetOSName() == "Windows" then
		result = os.execute('powershell -Command "Invoke-WebRequest -Uri ' .. url .. ' -OutFile ' .. path .. '"')
	else
		result = os.execute("wget -q -O " .. path .. " " .. url)
	end
	return result == true or result == 0
end

local function fileSize(path)
	local file = io.open(path, "rb")
	if not file then return 0 end
	local size = file:seek("end")
	file:close()
	return size or 0
end

local function downloadVersionFile(url, path)
	if not fetchTo(url, path) then
		return nil
	end
	local file = io.open(path, "r")
	if not file then
		return nil
	end
	local data = file:read("*all")
	file:close()
	return data
end

-- Downloads url over path without ever leaving path broken. The download lands in a
-- temporary file; only once that is complete and non-empty is the installed file moved
-- aside and the new one swapped in, and a failed swap puts the old file back.
-- Returns true only when the new file is in place.
local function downloadFile(url, path)
	local tempPath = path .. ".download"
	local backupPath = path .. ".bak"
	os.remove(tempPath)

	if not fetchTo(url, tempPath) or fileSize(tempPath) == 0 then
		os.remove(tempPath)
		print("[CareerMP] ---------- CareerMP Update Download failed: " .. url)
		return false
	end

	local hadInstalled = FS.Exists(path)
	if hadInstalled then
		os.remove(backupPath)
		if not os.rename(path, backupPath) then
			os.remove(tempPath)
			print("[CareerMP] ---------- CareerMP Update Could not move " .. path .. " aside, nothing was changed")
			return false
		end
	end

	if not os.rename(tempPath, path) then
		if hadInstalled then
			os.rename(backupPath, path)
		end
		os.remove(tempPath)
		print("[CareerMP] ---------- CareerMP Update Could not replace " .. path .. ", the installed file was kept")
		return false
	end

	if hadInstalled then
		os.remove(backupPath)
	end
	return true
end

local function needsUpdate(installedVersion, latest)
    local components = { "major", "minor", "revision" }
    -- ipairs, not pairs: this must compare major before minor before revision, and
    -- pairs does not guarantee order. Compared revision-first, 0.9.9 -> 1.0.0 would
    -- see 0 < 9, return "no update", and servers would silently never pick it up.
    for _, key in ipairs(components) do
        local i, l = installedVersion[key] or 0, latest[key] or 0
        if l > i then
            return true
        end
        if l < i then
            return false
        end
    end
    return false
end

-- Fetches a remote version file to a scratch path, never over the installed version
-- record: that record is the only evidence of what is actually installed, so it is
-- written only after an update really lands.
local function fetchRemoteVersion(url)
	local tempPath = SERVER_PATH .. "versions/.remote.json"
	local data = downloadVersionFile(url, tempPath)
	if not data then return nil end
	return Util.JsonDecode(data)
end

-- Refuses content from a different lineage.
--
-- Version numbers alone cannot tell "a newer release of this repository" from "an
-- unrelated codebase with a higher number". Without this check, an update source with
-- higher numbers would be pulled over this install and, with autoExit on, shut the
-- server down afterwards.
local function lineageMatches(remote)
	return remote.lineage == LINEAGE
end

local function describeVersion(v)
	if not v then return "unknown" end
	return string.format("%s.%s.%s", tostring(v.major), tostring(v.minor), tostring(v.revision))
end

-- Shared by the client and server updaters, which were duplicates of each other.
local function runUpdate(opts)
	local installedVersion = ReadJson(SERVER_PATH .. opts.versionFile)

	if not FS.Exists(opts.filePath) then
		print("[CareerMP] ---------- CareerMP Update " .. opts.label .. " not installed, downloading...")
		if not downloadFile(opts.fileUrl, opts.filePath) then
			print("[CareerMP] ---------- CareerMP Update " .. opts.label .. " could not be downloaded!")
			return false
		end
	end

	if not installedVersion then
		print("[CareerMP] ---------- CareerMP Update Applying self version!")
		installedVersion = opts.hardVersion
		WriteJson(SERVER_PATH .. opts.versionFile, opts.hardVersion)
	end

	local latest = fetchRemoteVersion(opts.updateUrl)
	if not latest then
		print("[CareerMP] ---------- CareerMP Update Failed to fetch latest " .. opts.label:lower() .. " version!")
		return false
	end

	if not lineageMatches(latest) then
		print("[CareerMP] ---------- CareerMP Update REFUSED for " .. opts.label .. ": remote is a different lineage")
		print("[CareerMP] ----------   expected lineage: " .. LINEAGE)
		print("[CareerMP] ----------   remote lineage:   " .. tostring(latest.lineage or "none (upstream CareerMP?)"))
		print("[CareerMP] ----------   Nothing was changed. Check that the update repository is correct,")
		print("[CareerMP] ----------   or set server.autoUpdate to false while testing local changes.")
		return false
	end

	print("[CareerMP] ---------- CareerMP Update " .. opts.label .. " installed: " .. describeVersion(installedVersion))
	print("[CareerMP] ---------- CareerMP Update " .. opts.label .. " latest: " .. describeVersion(latest))

	if needsUpdate(installedVersion, latest) then
		print("[CareerMP] ---------- CareerMP Update Updating " .. opts.label:lower() .. "...")
		if not downloadFile(opts.fileUrl, opts.filePath) then
			print("[CareerMP] ---------- CareerMP Update " .. opts.label .. " update failed, staying on " .. describeVersion(installedVersion))
			return false
		end
		-- Record the new version only now that the file behind it is actually in place.
		WriteJson(SERVER_PATH .. opts.versionFile, latest)
		print("[CareerMP] ---------- CareerMP Update " .. opts.label .. " updated to " .. describeVersion(latest) .. "! Restart the server to apply the update!")
		return true
	end

	-- Same lineage but older: a rollback on the remote, or a stale branch. Never applied
	-- silently, because that would overwrite a working install with an older one.
	if needsUpdate(latest, installedVersion) then
		print("[CareerMP] ---------- CareerMP Update " .. opts.label .. " remote is OLDER than installed - refusing to downgrade")
		return false
	end

	print("[CareerMP] ---------- CareerMP Update " .. opts.label .. " up to date!")
	return false
end

local function updateClient()
	return runUpdate({
		label = "Client",
		versionFile = CLIENT_VERSION_FILE,
		filePath = CLIENT_PATH .. CLIENT_FILE,
		fileUrl = CLIENT_URL,
		updateUrl = CLIENT_UPDATE_URL,
		hardVersion = HARD_CLIENT_VERSION,
	})
end

local function updateServer()
	return runUpdate({
		label = "Server",
		versionFile = SERVER_VERSION_FILE,
		filePath = SERVER_PATH .. SERVER_FILE,
		fileUrl = SERVER_URL,
		updateUrl = SERVER_UPDATE_URL,
		hardVersion = HARD_SERVER_VERSION,
	})
end

-- Checks both parts. Either one updating is enough to restart, when autoExit allows it.
local function checkForUpdates()
	if not FS.IsDirectory(SERVER_PATH .. "/versions") then
		FS.CreateDirectory(SERVER_PATH .. "/versions")
	end
	local clientUpdated = updateClient()
	local serverUpdated = updateServer()
	if (clientUpdated or serverUpdated) and Config.server.autoExit then
		willExit = true
	end
end

local function parseQuotedString(input, startIndex)
	local closingQuoteIndex = input:find('"', startIndex + 1)
	if closingQuoteIndex then
		local value = input:sub(startIndex + 1, closingQuoteIndex - 1)
		return value, closingQuoteIndex + 2
	else
		local value = input:sub(startIndex + 1)
		return value, nil
	end
end

local function parseWord(input, startIndex)
	local nextSpaceIndex = input:find(' ', startIndex)
	if nextSpaceIndex then
		local value = input:sub(startIndex, nextSpaceIndex - 1)
		return value, nextSpaceIndex + 1
	else
		return input:sub(startIndex), nil
	end
end

local function parseCommand(message, separator)
	local arguments = {}
	local command = nil
	if separator then
		command = message:sub(1, separator - 1)
		local argumentsString = message:sub(separator + 1)
		local currentIndex = 1
		while currentIndex <= #argumentsString do
			local currentChar = argumentsString:sub(currentIndex, currentIndex)
			if currentChar == '"' then
				local value, nextIndex = parseQuotedString(argumentsString, currentIndex)
				table.insert(arguments, value)
				if not nextIndex then
					break
				end
				currentIndex = nextIndex
			elseif currentChar ~= ' ' then
				local value, nextIndex = parseWord(argumentsString, currentIndex)
				table.insert(arguments, value)
				if not nextIndex then
					break
				end
				currentIndex = nextIndex
			else
				currentIndex = currentIndex + 1
			end
		end
	end
	return command, arguments
end

local function prepareConfig()
	print("[CareerMP] ---------- CareerMP Config Loading...")
	Config = ReadJson(configPath .. "config.json")
	if not Config then
		print("[CareerMP] ---------- CareerMP Config Initializing...")
		Config = defaultConfig
		for section, fields in pairs(defaultConfig) do
			for field, value in pairs(fields) do
				print("[CareerMP] ---------- CareerMP Config " .. section .. " " .. field .. " set to " .. tostring(value))
			end
		end
		WriteJson(configPath .. "config.json", Config)
	else
		local updateFound
		for section, fields in pairs(defaultConfig) do
			print("[CareerMP] ---------- CareerMP Config Checking " .. section)
			if Config[section] == nil then
				updateFound = true
				print("[CareerMP] ---------- CareerMP Config Adding: " .. section)
				Config[section] = {}
				for field, value in pairs(fields) do
					print("[CareerMP] ---------- CareerMP Config " .. section .. " " .. field .. " set to " .. tostring(value))
					Config[section][field] = value
				end
			else
				for field, value in pairs(fields) do
					if Config[section][field] == nil then
						print("[CareerMP] ---------- CareerMP Config " .. section .. " " .. field .. " not found")
						print("[CareerMP] ---------- CareerMP Config " .. section .. " " .. field .. " set to " .. tostring(value))
						updateFound = true
						Config[section][field] = value
					end
				end
			end
		end
		for _, section in pairs({"client", "server"}) do
			if Config[section] then
				for field in pairs(Config[section]) do
					if defaultConfig[section][field] == nil then
						local retired = retiredConfig[section] and retiredConfig[section][field]
						if retired then
							print("[CareerMP] ---------- CareerMP Config " .. section .. " " .. field .. " removed: " .. retired)
						else
							print("[CareerMP] ---------- CareerMP Config " .. section .. " " .. field .. " is invalid, removing")
						end
						updateFound = true
						Config[section][field] = nil
					end
				end
			end
		end
		if updateFound then
			print("[CareerMP] ---------- CareerMP Config Updated!")
			WriteJson(configPath .. "config.json", Config)
		end
	end
	print("[CareerMP] ---------- CareerMP Config Loaded!")
end

function onInit()

	print("[CareerMP] ---------- CareerMP Loading...")

	MP.RegisterEvent("perPartPainting","perPartPaintingHandler")
	MP.RegisterEvent("requestPartPaints","requestPartPaintsHandler")

	MP.RegisterEvent("payPlayer","payPlayer")

	MP.RegisterEvent("careerPrefabSync","careerPrefabSync")
	MP.RegisterEvent("careerSyncRequested","careerSyncRequested")
	MP.RegisterEvent("careerStartResult","careerStartResult")
	MP.RegisterEvent("prefabSyncRequested","prefabSyncRequested")
	MP.RegisterEvent("careerVehSyncRequested","careerVehSyncRequested")
	MP.RegisterEvent("careerVehicleActiveHandler","careerVehicleActiveHandler")
	MP.RegisterEvent("careerVehicleTrafficMarks","careerVehicleTrafficMarks")

	-- Drag racing. One enveloped relay carries BeamNG 0.39's own multiplayer drag
	-- protocol; the server routes and elects the host but never interprets a message.
	MP.RegisterEvent("dragMP", "dragMP")
	MP.RegisterEvent("dragAuthorityRequest", "dragAuthorityRequest")

	MP.RegisterEvent("speedTrap", "speedTrap")
	MP.RegisterEvent("redLight", "redLight")
	MP.RegisterEvent("trafficLightTimer","trafficLightTimer")
	MP.CreateEventTimer("trafficLightTimer", 10000)

	MP.RegisterEvent("onPlayerJoin","onPlayerJoinHandler")
	MP.RegisterEvent("onVehicleSpawn","onVehicleSpawnHandler")
	MP.RegisterEvent("onVehicleEdited","onVehicleEditedHandler")
	MP.RegisterEvent("onVehicleDeleted","onVehicleDeletedHandler")
	MP.RegisterEvent("onPlayerDisconnect","onPlayerDisconnectHandler")

	MP.RegisterEvent("onConsoleInput","onConsoleInputHandler")

	MP.RegisterEvent("GetConfig","GetConfig")
	MP.RegisterEvent("SetConfig","SetConfig")
	MP.RegisterEvent("Update","Update")
	MP.RegisterEvent("Help","Help")

	MP.RegisterEvent("tick","tick")
	MP.CreateEventTimer("tick", 1000)

	prepareConfig()

	if Config.server.autoUpdate then
		checkForUpdates()
	end

	print("[CareerMP] ---------- CareerMP Loaded!")
end

function perPartPaintingHandler(player_id, data)
	local paintData = Util.JsonDecode(data)
	if not paintData.originID then
		for id in pairs(MP.GetPlayers()) do
			if player_id ~= id then
				MP.TriggerClientEvent(id, "rxRemotePartPaint", data)
			end
		end
	else
		MP.TriggerClientEvent(paintData.originID, "rxRemotePartPaint", data)
	end
end

function requestPartPaintsHandler(player_id, data)
	local requestData = Util.JsonDecode(data)
	local targetID = tonumber(requestData.serverVehicleID:sub(1,1))
	requestData.originID = player_id
	MP.TriggerClientEventJson(targetID, "rxRequestPartPaints", requestData)
end

local function getOrCreate(ledger, player_id)
	if not ledger[player_id] then
		ledger[player_id] = {
			session_total = 0,
			short_transactions = {},
			long_transactions = {}
		}
	end
	return ledger[player_id]
end

local function getWindowTotal(transactions, now, windowSeconds)
	local window_total = 0
	local cutoff = now - windowSeconds
	local kept = {}
	for _, transaction in ipairs(transactions) do
		if transaction.timestamp > cutoff then
			table.insert(kept, transaction)
			window_total = window_total + transaction.amount
		end
	end
	for i = #transactions, 1, -1 do
		transactions[i] = nil
		end
	for _, t in ipairs(kept) do
		table.insert(transactions, t)
	end
	return window_total
end

local function attemptTransaction(sender_id, receiver_id, amount, now)
	local sender = getOrCreate(ledger.send, sender_id)
	local receiver = getOrCreate(ledger.receive, receiver_id)
	local short_total = getWindowTotal(sender.short_transactions, now, Config.server.shortWindowSeconds)
	local long_total = getWindowTotal(sender.long_transactions, now, Config.server.longWindowSeconds)
	if sender.session_total + amount > Config.server.sessionSendingMax then
		return false
	end
	if short_total > 0 and short_total + amount > Config.server.shortWindowMax then
		return false
	end
	if long_total > 0 and long_total + amount > Config.server.longWindowMax then
		return false
	end
	if receiver.session_total + amount > Config.server.sessionReceiveMax then
		return false
	end
	sender.session_total = sender.session_total + amount
	receiver.session_total = receiver.session_total + amount
	if amount <= Config.server.shortWindowMax then
		table.insert(sender.short_transactions, { amount = amount, timestamp = now })
	end
	if amount <= Config.server.longWindowMax then
		table.insert(sender.long_transactions, { amount = amount, timestamp = now })
	end
	return true
end

-- The client is not trusted with the amount or the target: only a whole number of
-- dollars above zero, no more than a sender may send in a session, going to another
-- connected player, is ever relayed.
local function isValidPayment(sender_id, paymentData)
	local amount = paymentData.money
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 or amount % 1 ~= 0 then
		return false
	end
	if amount > Config.server.sessionSendingMax then
		return false
	end
	local target = paymentData.target_player_id
	return type(target) == "number" and target ~= sender_id and MP.IsPlayerConnected(target) == true
end

function payPlayer(player_id, data)
	local paymentData = Util.JsonDecode(data)
	if type(paymentData) ~= "table" then return end
	paymentData.sender = MP.GetPlayerName(player_id)
	if Config.server.allowTransactions then
		if isValidPayment(player_id, paymentData) then
			if attemptTransaction(player_id, paymentData.target_player_id, paymentData.money, signalTimer:GetCurrent()) then
				MP.TriggerClientEventJson(paymentData.target_player_id, "rxPayment", paymentData)
				MP.TriggerClientEventJson(player_id, "rxConfirmation", paymentData)
			else
				MP.TriggerClientEventJson(player_id, "rxBounce", paymentData)
			end
		else
			MP.TriggerClientEventJson(player_id, "rxBounce", paymentData)
		end
	else
		MP.TriggerClientEventJson(player_id, "rxDeny", paymentData)
	end
end

--== Drag racing relay =======================================================
-- BeamNG 0.39 ships a complete multiplayer drag protocol (16 message types, see
-- gameplay/drag/mpDragHandlers.lua) but no transport. This carries it.
--
-- The server deliberately does not understand any of it: every message is an opaque
-- envelope { msg, to, data } that gets routed and forwarded. That keeps the protocol
-- entirely client-side, so a BeamNG update that changes it needs no server change.
--
-- Routing targets:
--   "all"   every player except the sender
--   "host"  the player holding the strip the message concerns
--   {ids}   a specific set of player ids (bridge.sendToClientIds)

-- Drag authority, elected per strip rather than per session.
--
-- Election lives here rather than on the clients: working out who arrived first needs
-- everyone's presence, which only a neutral party has, and the server is what notices
-- disconnects. Doing it client-side would mean every client agreeing independently, and
-- re-agreeing whenever anyone joins or leaves.
--
-- The first design made one player -- lowest connected id -- authoritative for all drag
-- racing. That is wrong in a way that stops racing outright: the authority decides when
-- everyone is staged by reading its OWN local drag state, so a player who is off doing
-- deliveries has no drag data and the countdown never fires for anybody.
--
-- The authority must therefore be someone standing at the strip. It is elected here
-- rather than by the clients because working out who arrived first needs everyone's
-- presence, which only a neutral party has, and because the server notices disconnects.
--
-- dragPresence[stripId][playerId] = arrival sequence number
local dragPresence = {}
local dragAuthority = {}
local dragArrivalSeq = 0

local function electAuthority(stripId)
	local best, bestSeq = nil, nil
	for playerId, seq in pairs(dragPresence[stripId] or {}) do
		if MP.IsPlayerConnected(playerId) and (bestSeq == nil or seq < bestSeq) then
			best, bestSeq = playerId, seq
		end
	end
	return best
end

local function updateAuthority(stripId)
	local elected = electAuthority(stripId)
	if elected ~= dragAuthority[stripId] then
		dragAuthority[stripId] = elected
		if elected then
			print("[CareerMP] ---------- Drag authority for '" .. stripId .. "' is player " .. tostring(elected))
		else
			print("[CareerMP] ---------- Drag strip '" .. stripId .. "' is empty")
		end
		MP.TriggerClientEventJson(-1, "rxDragAuthority", { stripId = stripId, playerId = elected })
	end
end

local function noteArrival(playerId, stripId)
	if not stripId then return end
	dragPresence[stripId] = dragPresence[stripId] or {}
	if not dragPresence[stripId][playerId] then
		dragArrivalSeq = dragArrivalSeq + 1
		dragPresence[stripId][playerId] = dragArrivalSeq
		updateAuthority(stripId)
	end
end

local function noteDeparture(playerId, stripId)
	if stripId then
		if dragPresence[stripId] then
			dragPresence[stripId][playerId] = nil
			updateAuthority(stripId)
		end
		return
	end
	-- No strip given: the player is gone entirely, so drop them everywhere.
	for id, players in pairs(dragPresence) do
		if players[playerId] then
			players[playerId] = nil
			updateAuthority(id)
		end
	end
end

--- Called when a player leaves the server.
function releaseDragPresence(player_id)
	noteDeparture(player_id, nil)
end

--- Which player should a "to host" message go to?
---
--- Most messages name their strip. Finish times do not: phaseHandlers.lua:875 sends
--- dragRaceFinishTime with nothing but a raceId, and that is the one message that must
--- not be misrouted, because the authority attributes the win from it.
---
--- Race ids are built as "<stripId>-<number>" by the lobby, so the strip is recoverable
--- from the id itself. Matching the longest one guards against a strip whose id is a
--- prefix of another's.
local function resolveAuthorityFor(d)
	if not d then return nil end

	local named = d.stripId or d.lobbyId
	if named and dragAuthority[named] then return dragAuthority[named] end

	local raceId = d.raceId
	if type(raceId) == "string" then
		local best
		for stripId, holder in pairs(dragAuthority) do
			if holder and raceId:sub(1, #stripId + 1) == stripId .. "-" then
				if not best or #stripId > #best then best = stripId end
			end
		end
		if best then return dragAuthority[best] end
	end

	-- Nothing matched. If exactly one strip is in play the answer is unambiguous anyway;
	-- with several, guessing would hand a finish time to the wrong race, so send nothing.
	local only, count = nil, 0
	for _, holder in pairs(dragAuthority) do
		if holder then only, count = holder, count + 1 end
	end
	if count == 1 then return only end
	return nil
end

--- A client asking who holds a strip (on join, or after reconnecting).
function dragAuthorityRequest(player_id, data)
	local req = Util.JsonDecode(data)
	local stripId = req and req.stripId
	if stripId then
		MP.TriggerClientEventJson(player_id, "rxDragAuthority",
			{ stripId = stripId, playerId = dragAuthority[stripId] })
		return
	end
	for id, holder in pairs(dragAuthority) do
		MP.TriggerClientEventJson(player_id, "rxDragAuthority", { stripId = id, playerId = holder })
	end
end

function dragMP(player_id, data)
	local envelope = Util.JsonDecode(data)
	if not envelope or not envelope.msg then return end

	-- Stamp the sender server-side; a client must not be able to claim to be someone
	-- else, since finish times are attributed by sender id.
	envelope.from = player_id

	local to = envelope.to
	local payload = Util.JsonEncode(envelope)

	-- Our own lobby messages carry strip presence; the server reads those (and only
	-- those) so it can elect the per-strip authority. BeamNG's protocol stays opaque.
	local d = envelope.data
	if envelope.msg == "careerMPDragJoin" and d then
		noteArrival(player_id, d.stripId)
	elseif envelope.msg == "careerMPDragLeave" and d then
		noteDeparture(player_id, d.stripId)
	end

	if to == "host" then
		-- To whoever holds the strip this message concerns.
		local target = resolveAuthorityFor(d)
		if target and MP.IsPlayerConnected(target) then
			MP.TriggerClientEvent(target, "rxDragMP", payload)
		end
		return
	end

	if type(to) == "table" then
		for _, id in pairs(to) do
			local pid = tonumber(id)
			if pid and pid ~= player_id and MP.IsPlayerConnected(pid) then
				MP.TriggerClientEvent(pid, "rxDragMP", payload)
			end
		end
		return
	end

	-- default: everyone but the sender
	for id in pairs(MP.GetPlayers()) do
		if id ~= player_id then
			MP.TriggerClientEvent(id, "rxDragMP", payload)
		end
	end
end

function speedTrap(player_id, data)
	local speedTrapData = Util.JsonDecode(data)
	local triggerName = speedTrapData.triggerName
	local triggerNumber = tonumber(string.match(triggerName, "%d+"))
	local triggerPlace = trapNames[triggerNumber] or "Unknown"
	local player_name = MP.GetPlayerName(player_id)
	MP.SendNotification(-1, "Speed Violation by " .. player_name .. "!", "survellianceCamera", "survellianceCamera")
	MP.SendNotification(-1, "Speed: " .. string.format( "%.1f", speedTrapData.playerSpeed * 2.23694 ) .. " in " .. string.format( "%.0f", speedTrapData.speedLimit * 2.23694 ) .. " MPH Zone", "powerGauge05", "powerGauge05")
	MP.SendNotification(-1, "Location: " .. triggerPlace, "location1", "location1")
	MP.SendNotification(-1, "Vehicle: " .. speedTrapData.vehicleModel, "car", "car")
	MP.SendNotification(-1, "Plate: " .. speedTrapData.licensePlate, "code", "code")
end

function redLight(player_id, data)
	local redLightData = Util.JsonDecode(data)
	local triggerName = redLightData.triggerName
	local triggerNumber = tonumber(string.match(triggerName, "%d+"))
	local triggerPlace = trapNames[triggerNumber] or "Unknown"
	local player_name = MP.GetPlayerName(player_id)
	MP.SendNotification(-1, "Failure to stop at Red Light by " .. player_name .. "!", "trafficLight", "trafficLight")
	MP.SendNotification(-1, "Speed: " .. string.format( "%.1f", redLightData.playerSpeed * 2.23694 ) .. " MPH", "powerGauge05", "powerGauge05")
	MP.SendNotification(-1, "Location: " .. triggerPlace, "location1", "location1")
	MP.SendNotification(-1, "Vehicle: " .. redLightData.vehicleModel, "car", "car")
	MP.SendNotification(-1, "Plate: " .. redLightData.licensePlate, "code", "code")
end

function trafficLightTimer()
	for id in pairs(MP.GetPlayers()) do
		if MP.IsPlayerConnected(id) then
			MP.TriggerClientEvent(id, "rxTrafficSignalTimer", tostring(signalTimer:GetCurrent()))
		end
	end
end

function careerVehSyncRequested(player_id)
	MP.TriggerClientEventJson(player_id, "rxCareerVehSync", vehicleStates)
end

function careerPrefabSync(player_id, data)
	local prefab = Util.JsonDecode(data)
	if not prefab then return end
	-- Guard: a player disconnecting mid-sync clears their loadedPrefabs entry.
	loadedPrefabs[player_id] = loadedPrefabs[player_id] or {}
	if prefab.pLoad == true then
		loadedPrefabs[player_id][prefab.pName] = prefab
	elseif prefab.pLoad == false then
		loadedPrefabs[player_id][prefab.pName] = nil
	end
	for id in pairs(MP.GetPlayers()) do
		if player_id ~= id then
			MP.TriggerClientEvent(id, "rxPrefabSync", data)
		end
	end
end

local function decodeTable(data)
	if type(data) ~= "string" or data == "" then return nil end
	local ok, decoded = pcall(Util.JsonDecode, data)
	if ok and type(decoded) == "table" then return decoded end
	return nil
end

-- true when serverVehicleID ("<player_id>-<vehicle_id>") names one of player_id's own
-- vehicles. A player's game may only change its own cars.
local function ownsVehicle(player_id, serverVehicleID)
	if type(serverVehicleID) ~= "string" then return false end
	local owner = serverVehicleID:match("^(%d+)%-%d+$")
	return owner ~= nil and tonumber(owner) == tonumber(player_id)
end

-- Sends every player the state of one vehicle; the full map goes only to a player who
-- asks for it (careerVehSyncRequested).
local function sendVehicleState(serverVehicleID)
	MP.TriggerClientEventJson(-1, "rxCareerVehSync", {[serverVehicleID] = vehicleStates[serverVehicleID]})
end

-- Console-safe text from a client: control characters removed, length capped.
local function consoleText(text)
	return (tostring(text):gsub("%c", " "):sub(1, START_REASON_MAX_LENGTH))
end

local function describePlayer(player_id)
	return string.format("%s (%s)", consoleText(MP.GetPlayerName(player_id) or "?"), tostring(player_id))
end

local function dropUnstartedPlayer(player_id, why)
	local entry = pendingActivation[player_id]
	if not entry or entry.dropped then return end
	entry.dropped = true
	print("[CareerMP] Dropping " .. describePlayer(player_id) .. ": " .. why)
	MP.DropPlayer(player_id, "CareerMP failed to load!")
end

function careerSyncRequested(player_id, data)
	MP.TriggerClientEventJson(player_id, "rxCareerSync", Config.client)
	-- Guard: the entry is gone if the player disconnected between join and sync.
	local entry = pendingActivation[player_id]
	if not entry or entry.careerActive then return end
	local request = decodeTable(data)
	if request and request.confirmsStart == true then
		entry.confirmsStart = true
		entry.settingsRequestedAt = signalTimer:GetCurrent()
	else
		entry.careerActive = true
	end
end

-- The client's own report of its career start: {"started": true} or
-- {"started": false, "reason": "..."}. Only accepted from a client that said it
-- confirms its start, after its settings request; the reason is printed, never used.
function careerStartResult(player_id, data)
	local entry = pendingActivation[player_id]
	if not entry or not entry.confirmsStart or entry.careerActive or entry.dropped then return end
	local result = decodeTable(data)
	if not result then return end
	if result.started == true then
		entry.careerActive = true
		print("[CareerMP] " .. describePlayer(player_id) .. " started their career")
	elseif result.started == false then
		dropUnstartedPlayer(player_id, "career start failed: " .. consoleText(result.reason or "no reason given"))
	end
end

function prefabSyncRequested(player_id)
	for id in pairs(MP.GetPlayers()) do
		if player_id ~= id then
			if loadedPrefabs[id] then
				for k,v in pairs(loadedPrefabs[id]) do
					MP.TriggerClientEventJson(player_id, "rxPrefabSync", loadedPrefabs[id][k])
				end
			end
		end
	end
end

-- A player's game hid or showed one of its own cars: {"serverVehicleID", "active"}.
function careerVehicleActiveHandler(player_id, data)
	local vehicleData = decodeTable(data)
	if not vehicleData or type(vehicleData.active) ~= "boolean" then return end
	local serverVehicleID = vehicleData.serverVehicleID
	if not ownsVehicle(player_id, serverVehicleID) then return end
	local state = vehicleStates[serverVehicleID] or {}
	state.active = vehicleData.active
	vehicleStates[serverVehicleID] = state
	sendVehicleState(serverVehicleID)
end

-- The owner's game marks which of its cars are traffic or parked:
-- {"<player_id>-<vehicle_id>": true | false, ...}. Other games hide the nametag on a
-- marked car. Marks for another player's car, an unknown car or a non-boolean are ignored.
function careerVehicleTrafficMarks(player_id, data)
	local marks = decodeTable(data)
	if not marks then return end
	-- Marks that changed together go out together, holding only those cars.
	local changed, any = {}, false
	for serverVehicleID, mark in pairs(marks) do
		local state = vehicleStates[serverVehicleID]
		if type(mark) == "boolean" and state and ownsVehicle(player_id, serverVehicleID) then
			state.traffic = mark
			changed[serverVehicleID] = state
			any = true
		end
	end
	if any then MP.TriggerClientEventJson(-1, "rxCareerVehSync", changed) end
end

function validateCareerMPActivation()
	local now = signalTimer:GetCurrent()
	for id in pairs(MP.GetPlayers()) do
		local entry = pendingActivation[id]
		if entry and not entry.careerActive and not entry.dropped and MP.IsPlayerConnected(id) then
			if entry.settingsRequestedAt then
				if now - entry.settingsRequestedAt >= startConfirmThreshold then
					dropUnstartedPlayer(id, string.format("no career start confirmed within %d s of the settings request",
						startConfirmThreshold))
				end
			elseif entry.joinTimestamp and now - entry.joinTimestamp >= activationThreshold then
				dropUnstartedPlayer(id, string.format("no settings request within %d s of joining", activationThreshold))
			end
		end
	end
end

local function sendAlive()
	for id in pairs(MP.GetPlayers()) do
		if MP.IsPlayerConnected(id) then
			MP.TriggerClientEvent(id, "rxCareerMPAlive", "")
		end
	end
end

function tick()
	if willExit then
		exit()
	end
	validateCareerMPActivation()
	ticksSinceAlive = ticksSinceAlive + 1
	if ticksSinceAlive >= ALIVE_EVERY_TICKS then
		ticksSinceAlive = 0
		sendAlive()
	end
end

function onPlayerJoinHandler(player_id)
	loadedPrefabs[player_id] = {}
	pendingActivation[player_id] = {
		joinTimestamp = signalTimer:GetCurrent(),
		careerActive = false
	}
end

function onVehicleSpawnHandler(player_id, vehicle_id,  data)
	local serverVehicleID = player_id .. "-" .. vehicle_id
	vehicleStates[serverVehicleID] = {active = true}
	sendVehicleState(serverVehicleID)
end

function onVehicleEditedHandler(player_id, vehicle_id,  data)
	if vehicleStates[player_id .. "-" .. vehicle_id] then
		vehicleStates[player_id .. "-" .. vehicle_id].active = true
	else
		vehicleStates[player_id .. "-" .. vehicle_id] = {}
		vehicleStates[player_id .. "-" .. vehicle_id].active = true
	end
end

function onVehicleDeletedHandler(player_id, vehicle_id)
	if vehicleStates[player_id .. "-" .. vehicle_id] then
		vehicleStates[player_id .. "-" .. vehicle_id] = nil
	end
end

function onPlayerDisconnectHandler(player_id)
	-- Release their strip presence first: if they held a strip, someone still standing
	-- there has to inherit it or an in-progress race loses its authority.
	releaseDragPresence(player_id)
	loadedPrefabs[player_id] = nil
	ledger.send[player_id] = nil
	ledger.receive[player_id] = nil
	pendingActivation[player_id] = nil
end

function onConsoleInputHandler(message)
	local space = message:find(" ")
	if not space then
		return ""
	end
	local commandPrefix = message:sub(1, space)
	-- Compare against each prefix: `== "CareerMP " or "CMP "` would always be truthy and
	-- treat every console line containing a space as a CareerMP command.
	if commandPrefix == "CareerMP " or commandPrefix == "CMP " then
		local prefixLen = commandPrefix:len()
		message = message:sub(prefixLen + 1)
		local command = message
		local arguments = {}
		local separator = message:find(' ')
		if separator then
			command, arguments = parseCommand(message, separator)
		end
		MP.TriggerLocalEvent(command, arguments)
	end
	return ""
end

local function checkValue(value)
	if tonumber(value) then
		return tonumber(value)
	elseif value == "true" then
		return true
	elseif value == "false" then
		return false
	end
	return value
end

function GetConfig(arguments)
	Config = ReadJson(configPath .. "config.json")
	if #arguments == 0 then
		print(Config)
	elseif #arguments == 1 then
		print(Config[arguments[1]])
	else
		print(Config[arguments[1]][arguments[2]])
	end
end

function SetConfig(arguments)
	if #arguments < 3 then
		print("Usage: CareerMP SetConfig <section> <key> <value>")
		return
	end
	Config = ReadJson(configPath .. "config.json")
	local section = arguments[1]
	local key = arguments[2]
	local value = arguments[3]
	if not Config[section] then
		print("[CareerMP] ---------- Unknown section: " .. section)
		return
	end
	if Config[section][key] == nil then
		print("[CareerMP] ---------- Unknown key: " .. section .. " " .. key)
		return
	end
	Config[section][key] = checkValue(value)
	print("[CareerMP] ---------- Config:    " .. section .. " " .. tostring(key) .. " set to " .. tostring(Config[section][key]))
	WriteJson(configPath .. "config.json", Config)
	MP.TriggerClientEventJson(-1, "rxClientConfigUpdate", Config.client)
end

function Update(arguments)
	checkForUpdates()
end

function Help(arguments)
	print("CareerMP GetConfig <section> <key>            - Displays Config, or section, or key")
	print("CareerMP SetConfig <section*> <key*> <value*> - Sets Config section key to value, * = REQUIRED")
	print("CareerMP Update                               - Checks for CareerMP update")
	print("CareerMP Help                                 - Displays Commands Usage")
end

function ReadJson(path)
	if not path then
		print("[CareerMP] ---------- ReadJson:  path is nil!")
		return
	end
	if not FS.Exists(path) then
		print("[CareerMP] ---------- ReadJson:  " .. path .. " does not exist!")
		return
	end
	local jsonFile, err = io.open(path, "r")
	if not jsonFile then
		print("[CareerMP] ---------- ReadJson:  failed to open " .. path .. ": " .. tostring(err))
		return
	end
	local jsonText = jsonFile:read("*a")
	jsonFile:close()
	if not jsonText or jsonText == "" then
		print("[CareerMP] ---------- ReadJson:  " .. path .. " is empty!")
		return
	end
	local data = Util.JsonDecode(jsonText)
	if data == nil then
		print("[CareerMP] ---------- ReadJson:  failed to decode " .. path)
		return
	end
	return data
end

function WriteJson(path, data)
	if not path then
		print("[CareerMP] ---------- WriteJson: path is nil!")
		return
	end
	if data == nil then
		print("[CareerMP] ---------- WriteJson: data is nil, aborting!")
		return
	end
	local checkDirectory = path:match("(.+)/[^/]+$")
	if checkDirectory and not FS.Exists(checkDirectory) then
		FS.CreateDirectory(checkDirectory)
		print("[CareerMP] ---------- WriteJson: created directory " .. checkDirectory)
	end
	local encoded = Util.JsonEncode(data)
	if not encoded then
		print("[CareerMP] ---------- WriteJson: failed to encode data!")
		return
	end
	local jsonFile, err = io.open(path, "w")
	if not jsonFile then
		print("[CareerMP] ---------- WriteJson: failed to open " .. path .. ": " .. tostring(err))
		return
	end
	print("[CareerMP] ---------- WriteJson: writing " .. path)
	jsonFile:write(Util.JsonPrettify(encoded))
	jsonFile:close()
	return true
end
