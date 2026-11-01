--CareerMP (SERVER)
--Created by Dudekahedron
--Thanks to Bouboule, and Lion and Luuk from BeamPaint, for http request examples
--
--CareerMP is now Mileage. This is the last CareerMP plugin: CareerMP 0.2.0 plus
--moveToMileage, which installs the Mileage plugin on a server that updates from here.
--Mileage then carries the settings over and removes CareerMP on its first start. Until
--the move succeeds this plugin keeps running as CareerMP 0.2.0. Fresh installs never
--get this file; the release package ships Mileage only.
--
--This file touches no game Lua -- it is pure BeamMP API (MP.*, Util.*, FS.*) -- so it
--does not depend on the BeamNG.drive version. The drag relay carries BeamNG's own
--multiplayer drag protocol between clients without interpreting it.

-- Identifies which CareerMP line these files belong to. The updater refuses any remote
-- version file that does not carry this exact value, so another repository's
-- higher-numbered releases are never pulled over this one. Keep it in sync with the
-- `lineage` field in versions/client.json and versions/server.json.
local LINEAGE = "norto22/CareerMP"

local HARD_CLIENT_VERSION = {major = 0, minor = 2, revision = 0, lineage = LINEAGE}
local HARD_SERVER_VERSION = {major = 0, minor = 3, revision = 0, lineage = LINEAGE}

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

-- Where Mileage comes from and goes. See moveToMileage.
local MILEAGE_LINEAGE = "norto22/Mileage"
local MILEAGE_RAW = RAW .. "norto22/Mileage/" .. BRANCH
local MILEAGE_DIR = "Resources/Server/Mileage"
local MILEAGE_PATH = MILEAGE_DIR .. "/"
local MILEAGE_PLUGIN = MILEAGE_PATH .. "mileage.lua"
local MILEAGE_SERVER_VERSION = MILEAGE_PATH .. "versions/server.json"
local MILEAGE_PLUGIN_URL = MILEAGE_RAW .. MILEAGE_PLUGIN
local MILEAGE_VERSION_URL = MILEAGE_RAW .. MILEAGE_SERVER_VERSION

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
		-- Traffic across the whole server, 0 to 400 of each kind; 0 means no limit. Each
		-- player spawns client.roadTrafficAmount and parkedTrafficAmount until the players
		-- together would pass these totals, then the totals are split between them.
		roadTrafficTotal = 18,
		parkedTrafficTotal = 24,
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

--== Readout =================================================================
-- Every message the server sends goes through send, sendJson or notify, which count it
-- under one feature; every handler counts what it receives. `CareerMP Stats` prints the
-- counts for the last STATS_SECONDS and since the server started (or the last reset).
-- Positions are BeamMP's own and are not counted here; the car count stands in for them.

local STATS_SECONDS = 60
local STATS_FEATURES = {"damage", "carStates", "trafficMarks", "trafficShare", "paint", "prefabs", "drag",
	"payments", "alive", "trafficLights", "notifications", "config"}

-- totals[feature] and slots[second % STATS_SECONDS].counts[feature]:
-- {received, sent, recipients, bytes}.
local stats = nil

local function resetStats()
	stats = {since = signalTimer:GetCurrent(), totals = {}, slots = {}}
end
resetStats()

local function countsIn(group, feature)
	local counts = group[feature]
	if not counts then
		counts = {received = 0, sent = 0, recipients = 0, bytes = 0}
		group[feature] = counts
	end
	return counts
end

local function currentSlot()
	local second = math.floor(signalTimer:GetCurrent())
	local index = second % STATS_SECONDS
	local slot = stats.slots[index]
	if not slot or slot.second ~= second then
		slot = {second = second, counts = {}}
		stats.slots[index] = slot
	end
	return slot.counts
end

local function count(feature, received, sent, recipients, bytes)
	for _, group in ipairs({stats.totals, currentSlot()}) do
		local counts = countsIn(group, feature)
		counts.received = counts.received + received
		counts.sent = counts.sent + sent
		counts.recipients = counts.recipients + recipients
		counts.bytes = counts.bytes + bytes
	end
end

local function playerCount()
	local n = 0
	for _ in pairs(MP.GetPlayers() or {}) do n = n + 1 end
	return n
end

local function recipientsOf(target)
	if target == -1 then return playerCount() end
	return 1
end

-- A message a handler of `feature` received.
local function received(feature)
	count(feature, 1, 0, 0, 0)
end

local function send(feature, target, event, data)
	data = data or ""
	MP.TriggerClientEvent(target, event, data)
	local recipients = recipientsOf(target)
	count(feature, 0, 1, recipients, #data * recipients)
end

-- Encodes once; the counted bytes are the bytes BeamMP sends.
local function sendJson(feature, target, event, value)
	send(feature, target, event, Util.JsonEncode(value))
end

local function notify(feature, target, text, ...)
	MP.SendNotification(target, text, ...)
	local recipients = recipientsOf(target)
	count(feature, 0, 1, recipients, #tostring(text) * recipients)
end

local function decodeTable(data)
	if type(data) ~= "string" or data == "" then return nil end
	local ok, decoded = pcall(Util.JsonDecode, data)
	if ok and type(decoded) == "table" then return decoded end
	return nil
end

-- true for a car its owner's game marked as traffic or parked. Such a car never answers
-- a request for its damage or paint, so the requests are dropped.
local function isTraffic(serverVehicleID)
	local state = vehicleStates[serverVehicleID]
	return type(state) == "table" and state.traffic == true
end

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

-- Installs the Mileage plugin and restarts into it, when autoExit allows. Only the plugin
-- and its server version are fetched: Mileage downloads its own client mod, copies the
-- CareerMP settings and removes CareerMP's files on its first start. Anything that fails
-- leaves the server as it was, still running CareerMP, and the next start tries again.
local function moveToMileage()
	print("[CareerMP] ---------- CareerMP is now Mileage, installing Mileage...")
	local remote = fetchRemoteVersion(MILEAGE_VERSION_URL)
	os.remove(SERVER_PATH .. "versions/.remote.json")
	if not remote then
		print("[CareerMP] ---------- Moving to Mileage: could not fetch " .. MILEAGE_VERSION_URL .. ", staying on CareerMP until the next start")
		return false
	end
	if remote.lineage ~= MILEAGE_LINEAGE then
		print("[CareerMP] ---------- Moving to Mileage REFUSED: " .. MILEAGE_VERSION_URL .. " has lineage " .. tostring(remote.lineage) .. ", expected " .. MILEAGE_LINEAGE)
		return false
	end
	for _, dir in ipairs({MILEAGE_DIR, MILEAGE_PATH .. "versions"}) do
		if not FS.IsDirectory(dir) then
			FS.CreateDirectory(dir)
		end
	end
	if not downloadFile(MILEAGE_PLUGIN_URL, MILEAGE_PLUGIN) then
		print("[CareerMP] ---------- Moving to Mileage: could not download " .. MILEAGE_PLUGIN_URL .. ", staying on CareerMP until the next start")
		return false
	end
	WriteJson(MILEAGE_SERVER_VERSION, remote)
	print("[CareerMP] ---------- Moving to Mileage: installed Mileage " .. describeVersion(remote) .. " in " .. MILEAGE_PATH)
	if Config.server.autoExit then
		print("[CareerMP] ---------- Moving to Mileage: restarting into Mileage")
		willExit = true
	else
		print("[CareerMP] ---------- Moving to Mileage: restart the server to finish the move")
	end
	return true
end

function onInit()

	-- On the first start with Mileage installed, Mileage removes this file. Until then
	-- this plugin does nothing, so CareerMP never runs beside Mileage.
	if FS.Exists(MILEAGE_PLUGIN) then
		print("[CareerMP] ---------- CareerMP is now Mileage, which is installed; this old plugin stays off and Mileage removes it")
		return
	end

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
	MP.RegisterEvent("careerDamage","careerDamage")
	MP.RegisterEvent("careerDamageRequest","careerDamageRequest")

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
	MP.RegisterEvent("Stats","Stats")

	MP.RegisterEvent("tick","tick")
	MP.CreateEventTimer("tick", 1000)

	prepareConfig()

	-- Updates now come only as Mileage, so the move takes the update check's place.
	if Config.server.autoUpdate then
		moveToMileage()
	end

	print("[CareerMP] ---------- CareerMP Loaded!")
end

function perPartPaintingHandler(player_id, data)
	received("paint")
	local paintData = Util.JsonDecode(data)
	if not paintData.originID then
		for id in pairs(MP.GetPlayers()) do
			if player_id ~= id then
				send("paint", id, "rxRemotePartPaint", data)
			end
		end
	else
		send("paint", paintData.originID, "rxRemotePartPaint", data)
	end
end

-- A game asks the owner of one car for its part paints: {"serverVehicleID"}. The owner
-- is read from the whole player number of the id.
function requestPartPaintsHandler(player_id, data)
	received("paint")
	local requestData = decodeTable(data)
	local serverVehicleID = requestData and requestData.serverVehicleID
	if type(serverVehicleID) ~= "string" or isTraffic(serverVehicleID) then return end
	local owner = tonumber(serverVehicleID:match("^(%d+)%-%d+$"))
	if not owner or not MP.GetPlayers()[owner] then return end
	requestData.originID = player_id
	sendJson("paint", owner, "rxRequestPartPaints", requestData)
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
	received("payments")
	local paymentData = Util.JsonDecode(data)
	if type(paymentData) ~= "table" then return end
	paymentData.sender = MP.GetPlayerName(player_id)
	if Config.server.allowTransactions then
		if isValidPayment(player_id, paymentData) then
			if attemptTransaction(player_id, paymentData.target_player_id, paymentData.money, signalTimer:GetCurrent()) then
				sendJson("payments", paymentData.target_player_id, "rxPayment", paymentData)
				sendJson("payments", player_id, "rxConfirmation", paymentData)
			else
				sendJson("payments", player_id, "rxBounce", paymentData)
			end
		else
			sendJson("payments", player_id, "rxBounce", paymentData)
		end
	else
		sendJson("payments", player_id, "rxDeny", paymentData)
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
		sendJson("drag", -1, "rxDragAuthority", { stripId = stripId, playerId = elected })
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
	received("drag")
	local req = Util.JsonDecode(data)
	local stripId = req and req.stripId
	if stripId then
		sendJson("drag", player_id, "rxDragAuthority",
			{ stripId = stripId, playerId = dragAuthority[stripId] })
		return
	end
	for id, holder in pairs(dragAuthority) do
		sendJson("drag", player_id, "rxDragAuthority", { stripId = id, playerId = holder })
	end
end

function dragMP(player_id, data)
	received("drag")
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
			send("drag", target, "rxDragMP", payload)
		end
		return
	end

	if type(to) == "table" then
		for _, id in pairs(to) do
			local pid = tonumber(id)
			if pid and pid ~= player_id and MP.IsPlayerConnected(pid) then
				send("drag", pid, "rxDragMP", payload)
			end
		end
		return
	end

	-- default: everyone but the sender
	for id in pairs(MP.GetPlayers()) do
		if id ~= player_id then
			send("drag", id, "rxDragMP", payload)
		end
	end
end

function speedTrap(player_id, data)
	received("notifications")
	local speedTrapData = Util.JsonDecode(data)
	local triggerName = speedTrapData.triggerName
	local triggerNumber = tonumber(string.match(triggerName, "%d+"))
	local triggerPlace = trapNames[triggerNumber] or "Unknown"
	local player_name = MP.GetPlayerName(player_id)
	notify("notifications", -1, "Speed Violation by " .. player_name .. "!", "survellianceCamera", "survellianceCamera")
	notify("notifications", -1, "Speed: " .. string.format( "%.1f", speedTrapData.playerSpeed * 2.23694 ) .. " in " .. string.format( "%.0f", speedTrapData.speedLimit * 2.23694 ) .. " MPH Zone", "powerGauge05", "powerGauge05")
	notify("notifications", -1, "Location: " .. triggerPlace, "location1", "location1")
	notify("notifications", -1, "Vehicle: " .. speedTrapData.vehicleModel, "car", "car")
	notify("notifications", -1, "Plate: " .. speedTrapData.licensePlate, "code", "code")
end

function redLight(player_id, data)
	received("notifications")
	local redLightData = Util.JsonDecode(data)
	local triggerName = redLightData.triggerName
	local triggerNumber = tonumber(string.match(triggerName, "%d+"))
	local triggerPlace = trapNames[triggerNumber] or "Unknown"
	local player_name = MP.GetPlayerName(player_id)
	notify("notifications", -1, "Failure to stop at Red Light by " .. player_name .. "!", "trafficLight", "trafficLight")
	notify("notifications", -1, "Speed: " .. string.format( "%.1f", redLightData.playerSpeed * 2.23694 ) .. " MPH", "powerGauge05", "powerGauge05")
	notify("notifications", -1, "Location: " .. triggerPlace, "location1", "location1")
	notify("notifications", -1, "Vehicle: " .. redLightData.vehicleModel, "car", "car")
	notify("notifications", -1, "Plate: " .. redLightData.licensePlate, "code", "code")
end

function trafficLightTimer()
	for id in pairs(MP.GetPlayers()) do
		if MP.IsPlayerConnected(id) then
			send("trafficLights", id, "rxTrafficSignalTimer", tostring(signalTimer:GetCurrent()))
		end
	end
end

-- The whole car-state list goes to a player at most once every LIST_EVERY_SECONDS; a
-- request inside that time is answered once, from the first tick after it.
local LIST_EVERY_SECONDS = 1
local listAnsweredAt = {}
local listWanted = {}

local function sendVehicleList(player_id)
	listAnsweredAt[player_id] = signalTimer:GetCurrent()
	listWanted[player_id] = nil
	sendJson("carStates", player_id, "rxCareerVehSync", vehicleStates)
end

local function sendWantedVehicleLists()
	local now = signalTimer:GetCurrent()
	for player_id in pairs(listWanted) do
		if not MP.IsPlayerConnected(player_id) then
			listWanted[player_id] = nil
		elseif now - (listAnsweredAt[player_id] or -math.huge) >= LIST_EVERY_SECONDS then
			sendVehicleList(player_id)
		end
	end
end

function careerVehSyncRequested(player_id)
	received("carStates")
	local last = listAnsweredAt[player_id]
	if last and signalTimer:GetCurrent() - last < LIST_EVERY_SECONDS then
		listWanted[player_id] = true
		return
	end
	sendVehicleList(player_id)
end

function careerPrefabSync(player_id, data)
	received("prefabs")
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
			send("prefabs", id, "rxPrefabSync", data)
		end
	end
end

-- true when serverVehicleID ("<player_id>-<vehicle_id>") names one of player_id's own
-- vehicles, written exactly as onVehicleSpawnHandler writes it. A player's game may only
-- change its own cars.
local function ownsVehicle(player_id, serverVehicleID)
	if type(serverVehicleID) ~= "string" then return false end
	local owner, vehicle = serverVehicleID:match("^(%d+)%-(%d+)$")
	return owner ~= nil and owner == tostring(tonumber(player_id))
		and vehicle == tostring(tonumber(vehicle))
end

-- Sends every player the state of one vehicle; the full map goes only to a player who
-- asks for it (careerVehSyncRequested).
local function sendVehicleState(serverVehicleID)
	sendJson("carStates", -1, "rxCareerVehSync", {[serverVehicleID] = vehicleStates[serverVehicleID]})
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

--Traffic shares
--
-- Every player's traffic is shared with everyone, so a server-wide total keeps the map
-- from filling as players join. Each player counted (from its settings request, before
-- its career spawns traffic) keeps the per-player amount until the players together
-- would pass server.roadTrafficTotal / parkedTrafficTotal; then the total is split
-- evenly, one spare car each to the lowest player ids. A total of 0 means no limit. A
-- joiner's share goes in its own settings, and players already in get their smaller
-- share (rxCareerTrafficShare) at once, so the total is never passed; a share that grows
-- (a player left) goes SHARE_SETTLE_SECONDS after the last join or leave. Only changed
-- shares are sent.

local SHARE_MAX = 50
local TOTAL_MAX = 400
local SHARE_SETTLE_SECONDS = 3
local sharesSent = {}        -- player_id -> {road, parked}, the share that player has
local sharesChangedAt = nil  -- when players last joined, left or the settings changed

local function wholeIn(value, high)
	local n = tonumber(value)
	if not n or n ~= n then return 0 end
	return math.floor(math.max(0, math.min(high, n)))
end

local function perPlayerAmount(enabledKey, amountKey)
	if Config.client[enabledKey] ~= true then return 0 end
	return wholeIn(Config.client[amountKey], SHARE_MAX)
end

-- perPlayer each for ids (sorted), split from total once they would pass it.
local function split(shares, kind, perPlayer, total, ids)
	local n = #ids
	local each, spare = perPlayer, 0
	if total > 0 and perPlayer * n > total then
		each = math.floor(total / n)
		spare = total - each * n
	end
	for i, id in ipairs(ids) do
		shares[id][kind] = math.min(perPlayer, each + (i <= spare and 1 or 0))
	end
end

-- {[player_id] = {road, parked}} for every player counted.
local function trafficShares()
	local ids = {}
	for id, entry in pairs(pendingActivation) do
		if entry.counted and not entry.dropped then table.insert(ids, id) end
	end
	table.sort(ids)
	local shares = {}
	for _, id in ipairs(ids) do shares[id] = {} end
	split(shares, "road", perPlayerAmount("roadTrafficEnabled", "roadTrafficAmount"),
		wholeIn(Config.server.roadTrafficTotal, TOTAL_MAX), ids)
	split(shares, "parked", perPlayerAmount("parkedTrafficEnabled", "parkedTrafficAmount"),
		wholeIn(Config.server.parkedTrafficTotal, TOTAL_MAX), ids)
	return shares
end

local function sharesChanged()
	sharesChangedAt = signalTimer:GetCurrent()
end

-- Sends each player already in its share when it changed. With onlyDecreases (a join),
-- only shares that went down go now, so the players together never pass the total; the
-- rest wait for sendChangedShares.
local function sendShares(onlyDecreases)
	for id, share in pairs(trafficShares()) do
		local last = sharesSent[id]
		if last and MP.IsPlayerConnected(id) and (last.road ~= share.road or last.parked ~= share.parked)
				and (not onlyDecreases or (share.road <= last.road and share.parked <= last.parked)) then
			sharesSent[id] = share
			sendJson("trafficShare", id, "rxCareerTrafficShare", share)
		end
	end
end

local function sendChangedShares()
	if not sharesChangedAt or signalTimer:GetCurrent() - sharesChangedAt < SHARE_SETTLE_SECONDS then return end
	sharesChangedAt = nil
	sendShares(false)
end

-- The client settings with this player's share added; Config.client itself never gets one.
local function settingsFor(player_id)
	local settings = {}
	for key, value in pairs(Config.client) do settings[key] = value end
	local share = trafficShares()[player_id] or {
		road = perPlayerAmount("roadTrafficEnabled", "roadTrafficAmount"),
		parked = perPlayerAmount("parkedTrafficEnabled", "parkedTrafficAmount"),
	}
	sharesSent[player_id] = share
	settings.trafficShare = share
	return settings
end

function careerSyncRequested(player_id, data)
	received("config")
	local counted = pendingActivation[player_id]
	local joined = counted and not counted.counted
	if joined then counted.counted = true end
	sendJson("config", player_id, "rxCareerSync", settingsFor(player_id))
	if joined then
		sendShares(true)
		sharesChanged()
	end
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
	received("config")
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
	received("prefabs")
	for id in pairs(MP.GetPlayers()) do
		if player_id ~= id then
			if loadedPrefabs[id] then
				for k,v in pairs(loadedPrefabs[id]) do
					sendJson("prefabs", player_id, "rxPrefabSync", loadedPrefabs[id][k])
				end
			end
		end
	end
end

-- A player's game hid or showed one of its own cars: {"serverVehicleID", "active"}.
function careerVehicleActiveHandler(player_id, data)
	received("carStates")
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
	received("trafficMarks")
	local marks = decodeTable(data)
	if not marks then return end
	-- Marks that changed together go out together, holding only those cars.
	local changed = {}
	for serverVehicleID, mark in pairs(marks) do
		local state = vehicleStates[serverVehicleID]
		if type(mark) == "boolean" and state and ownsVehicle(player_id, serverVehicleID) then
			state.traffic = mark
			changed[serverVehicleID] = state
		end
	end
	if next(changed) then sendJson("trafficMarks", -1, "rxCareerVehSync", changed) end
end

--Damage between players
--
-- Each player's game sends the dents of its own cars ({"v": "<player>-<vehicle>", "c",
-- "b", "n"}); the server passes a message on, unchanged, to every other player, but only
-- from the car's owner, under DAMAGE_MAX_BYTES and at most DAMAGE_PER_SECOND a second per
-- player. A game that builds a copy of someone's car asks for its full damage
-- ({"v": ...}), which goes to the owner alone. The owner's answer is flagged ("f":1 right
-- after the car id) and goes only to the players who asked for that car, until no chunk
-- of it has come for FULL_WANTED_SECONDS; with nobody waiting it goes to everyone. The games check every
-- value themselves.
--
-- The server reads the car id from the message's fixed start instead of decoding it, and
-- drops a message that could name a second car to a receiver's decoder (another "v", or
-- any escape), so the id checked here is the only one.

local DAMAGE_MAX_BYTES = 32768
local DAMAGE_PER_SECOND = 4
local DAMAGE_REQUEST_MAX_BYTES = 256
local FULL_WANTED_SECONDS = 5
local damageRate = {send = {}, request = {}}
-- fullWanted[serverVehicleID][player_id] = when that player asked for the car's full damage
local fullWanted = {}

-- The car id of a damage message and whether it is a flagged answer; nil for a message
-- not in the form the games send.
local function readDamageMessage(data)
	local serverVehicleID = data:match('^{"v":"(%d+%-%d+)",')
	if not serverVehicleID or data:sub(-1) ~= "}" then return nil end
	if data:find('"v"', 3, true) or data:find("\\", 1, true) then return nil end
	local after = #serverVehicleID + 9
	return serverVehicleID, data:sub(after, after + 5) == '"f":1,'
end

-- The players still waiting for a car's full damage, or nil when none is.
local function playersWaitingFor(serverVehicleID)
	local askers = fullWanted[serverVehicleID]
	if not askers then return nil end
	local now = signalTimer:GetCurrent()
	for id, at in pairs(askers) do
		if now - at > FULL_WANTED_SECONDS or not MP.IsPlayerConnected(id) then askers[id] = nil end
	end
	if next(askers) then return askers end
	fullWanted[serverVehicleID] = nil
	return nil
end

-- true while player_id is within the per-second limit of this kind of message.
local function withinDamageRate(kind, player_id)
	local now = signalTimer:GetCurrent()
	local rate = damageRate[kind][player_id]
	if not rate or now - rate.since >= 1 then
		rate = {since = now, count = 0}
		damageRate[kind][player_id] = rate
	end
	rate.count = rate.count + 1
	return rate.count <= DAMAGE_PER_SECOND
end

function careerDamage(player_id, data)
	received("damage")
	if type(data) ~= "string" or #data > DAMAGE_MAX_BYTES then return end
	if not withinDamageRate("send", player_id) then return end
	local serverVehicleID, answer = readDamageMessage(data)
	if not serverVehicleID or not ownsVehicle(player_id, serverVehicleID) then return end
	local askers = answer and playersWaitingFor(serverVehicleID)
	if askers then
		-- An answer under way keeps its players: one asked later restarts it, and the
		-- first must still get the chunks it has not had yet.
		local now = signalTimer:GetCurrent()
		for id in pairs(askers) do askers[id] = now end
	end
	local targets = askers or MP.GetPlayers()
	for id in pairs(targets) do
		if id ~= player_id then
			send("damage", id, "rxCareerDamage", data)
		end
	end
end

function careerDamageRequest(player_id, data)
	received("damage")
	if type(data) ~= "string" or #data > DAMAGE_REQUEST_MAX_BYTES then return end
	local request = decodeTable(data)
	local serverVehicleID = request and request.v
	if type(serverVehicleID) ~= "string" or isTraffic(serverVehicleID) then return end
	if not withinDamageRate("request", player_id) then return end
	local owner = serverVehicleID:match("^(%d+)%-%d+$")
	owner = tonumber(owner)
	if not owner or owner == player_id or not MP.GetPlayers()[owner] then return end
	if not ownsVehicle(owner, serverVehicleID) then return end
	fullWanted[serverVehicleID] = fullWanted[serverVehicleID] or {}
	fullWanted[serverVehicleID][player_id] = signalTimer:GetCurrent()
	send("damage", owner, "rxCareerDamageRequest", '{"v":"' .. serverVehicleID .. '"}')
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
			send("alive", id, "rxCareerMPAlive", "")
		end
	end
end

function tick()
	if willExit then
		exit()
	end
	validateCareerMPActivation()
	sendWantedVehicleLists()
	sendChangedShares()
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

-- A rebuilt car is switched on, and every player is told: their copy is rebuilt too and
-- must not take the hidden state they last kept for it.
function onVehicleEditedHandler(player_id, vehicle_id,  data)
	local serverVehicleID = player_id .. "-" .. vehicle_id
	local state = vehicleStates[serverVehicleID] or {}
	state.active = true
	vehicleStates[serverVehicleID] = state
	sendVehicleState(serverVehicleID)
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
	damageRate.send[player_id] = nil
	damageRate.request[player_id] = nil
	listAnsweredAt[player_id] = nil
	listWanted[player_id] = nil
	if sharesSent[player_id] then
		sharesSent[player_id] = nil
		sharesChanged()
	end
	-- BeamMP removes a leaving player's cars; their states go with them.
	local prefix = tostring(player_id) .. "-"
	for serverVehicleID in pairs(vehicleStates) do
		if serverVehicleID:sub(1, #prefix) == prefix then vehicleStates[serverVehicleID] = nil end
	end
	for serverVehicleID, askers in pairs(fullWanted) do
		askers[player_id] = nil
		if serverVehicleID:sub(1, #prefix) == prefix or not next(askers) then fullWanted[serverVehicleID] = nil end
	end
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
	sendJson("config", -1, "rxClientConfigUpdate", Config.client)
	-- An amount, a switch or a total may have changed everyone's share.
	sharesChanged()
end

function Update(arguments)
	checkForUpdates()
end

function Help(arguments)
	print("CareerMP GetConfig <section> <key>            - Displays Config, or section, or key")
	print("CareerMP SetConfig <section*> <key*> <value*> - Sets Config section key to value, * = REQUIRED")
	print("CareerMP Update                               - Checks for CareerMP update")
	print("CareerMP Stats [reset]                        - Shows what each part of CareerMP sends, reset starts it again")
	print("CareerMP Help                                 - Displays Commands Usage")
end

-- The counts of the last STATS_SECONDS, summed from the slots still inside the window.
local function windowCounts()
	local cutoff = math.floor(signalTimer:GetCurrent()) - STATS_SECONDS
	local sums = {}
	for _, slot in pairs(stats.slots) do
		if slot.second > cutoff then
			for feature, counts in pairs(slot.counts) do
				local sum = countsIn(sums, feature)
				for key, n in pairs(counts) do sum[key] = sum[key] + n end
			end
		end
	end
	return sums
end

local function printStats()
	local window = windowCounts()
	print(string.format("[CareerMP] Stats - last %d s | since start (%d s ago)", STATS_SECONDS,
		math.floor(signalTimer:GetCurrent() - stats.since)))
	print(string.format("%-14s %8s %8s %8s %10s | %8s %8s %8s %12s", "feature", "received", "sent", "to",
		"bytes", "received", "sent", "to", "bytes"))
	for _, feature in ipairs(STATS_FEATURES) do
		local w, t = countsIn(window, feature), countsIn(stats.totals, feature)
		print(string.format("%-14s %8d %8d %8d %10d | %8d %8d %8d %12d", feature, w.received, w.sent,
			w.recipients, w.bytes, t.received, t.sent, t.recipients, t.bytes))
	end

	local players, cars = {}, {}
	local function newCarCounts() return {all = 0, shown = 0, traffic = 0, trafficShown = 0} end
	for id in pairs(MP.GetPlayers() or {}) do
		table.insert(players, id)
		cars[id] = newCarCounts()
	end
	table.sort(players)
	-- Hidden cars are counted apart: a player who joined before the server filled keeps
	-- the traffic above its new share, hidden, so the shown count is what the total holds.
	local server = newCarCounts()
	for serverVehicleID, state in pairs(vehicleStates) do
		local owner = tonumber(serverVehicleID:match("^(%d+)%-"))
		for _, counts in ipairs({server, owner and cars[owner] or nil}) do
			counts.all = counts.all + 1
			if state.active ~= false then counts.shown = counts.shown + 1 end
			if state.traffic == true then
				counts.traffic = counts.traffic + 1
				if state.active ~= false then counts.trafficShown = counts.trafficShown + 1 end
			end
		end
	end
	print(string.format("Players: %d", #players))
	print(string.format("Cars: %d (%d shown), %d of them traffic or parked (%d shown)", server.all, server.shown,
		server.traffic, server.trafficShown))
	local function total(key)
		local n = wholeIn(Config.server[key], TOTAL_MAX)
		return n > 0 and tostring(n) or "no limit"
	end
	print(string.format("Traffic total: %s driving, %s parked", total("roadTrafficTotal"), total("parkedTrafficTotal")))
	for _, id in ipairs(players) do
		local c = cars[id]
		local line = string.format("  %s: %d cars (%d shown), %d traffic or parked (%d shown)", describePlayer(id), c.all,
			c.shown, c.traffic, c.trafficShown)
		local share = sharesSent[id]
		if share then line = line .. string.format(", share %d driving %d parked", share.road, share.parked) end
		print(line)
	end
end

function Stats(arguments)
	local argument = arguments and arguments[1]
	if argument == nil then
		printStats()
	elseif argument == "reset" then
		resetStats()
		print("[CareerMP] Stats reset")
	else
		print("Usage: CareerMP Stats [reset]")
	end
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
