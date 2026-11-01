--Mileage (SERVER)
--Based on CareerMP, created by Dudekahedron
--Thanks to Bouboule, and Lion and Luuk from BeamPaint, for http request examples
--
--This file touches no game Lua -- it is pure BeamMP API (MP.*, Util.*, FS.*) -- so it
--does not depend on the BeamNG.drive version. The drag relay carries BeamNG's own
--multiplayer drag protocol between clients without interpreting it.

-- Identifies which Mileage line these files belong to. The updater refuses any remote
-- version file that does not carry this exact value, so another repository's
-- higher-numbered releases are never pulled over this one. Keep it in sync with the
-- `lineage` field in versions/client.json and versions/server.json.
local LINEAGE = "norto22/Mileage"

local HARD_CLIENT_VERSION = {major = 0, minor = 3, revision = 0, lineage = LINEAGE}
local HARD_SERVER_VERSION = {major = 0, minor = 3, revision = 0, lineage = LINEAGE}

local RAW = "https://raw.githubusercontent.com/"
local GITHUB_REPO = "norto22/Mileage/"
local BRANCH = "main/"
local CLIENT_PATH = "Resources/Client/"
local CLIENT_FILE = "Mileage.zip"
local SERVER_PATH = "Resources/Server/Mileage/"
local SERVER_FILE = "mileage.lua"
local CLIENT_VERSION_FILE = "versions/client.json"
local SERVER_VERSION_FILE = "versions/server.json"
local CLIENT_URL = RAW .. GITHUB_REPO .. BRANCH .. CLIENT_PATH .. CLIENT_FILE
local SERVER_URL = RAW .. GITHUB_REPO .. BRANCH .. SERVER_PATH .. SERVER_FILE
local CLIENT_UPDATE_URL = RAW .. GITHUB_REPO .. BRANCH .. SERVER_PATH .. CLIENT_VERSION_FILE
local SERVER_UPDATE_URL = RAW .. GITHUB_REPO .. BRANCH .. SERVER_PATH .. SERVER_VERSION_FILE

local configPath = "Resources/Server/Mileage/config/"

-- Where CareerMP, this mod's name before Mileage, kept its files. See moveFromCareerMP.
local OLD_SERVER_PATH = "Resources/Server/CareerMP/"
local OLD_PLUGIN = OLD_SERVER_PATH .. "careerMP.lua"
local OLD_CONFIG = OLD_SERVER_PATH .. "config/config.json"
local OLD_CLIENT = CLIENT_PATH .. "CareerMP.zip"
local OLD_VERSION_FILES = {
	OLD_SERVER_PATH .. "versions/client.json",
	OLD_SERVER_PATH .. "versions/server.json",
	OLD_SERVER_PATH .. "versions/.remote.json",
}
-- The last CareerMP plugin downloads Mileage's client mod here, outside Resources/Client/,
-- so BeamMP never offers it beside CareerMP.zip; the handoff moves it into place.
local HELD_CLIENT = SERVER_PATH .. CLIENT_FILE
-- CareerMP.zip waits here while the handoff removes the CareerMP plugin, so it can be put
-- back if that fails.
local SET_ASIDE_CLIENT = SERVER_PATH .. "CareerMP.zip.removed"

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
-- "Mileage failed to load!" when no settings request arrives within activationThreshold
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

-- Every connected player hears rxMileageAlive this often, in ticks of one second. A
-- client that hears nothing for ten seconds tells its player the server is gone.
local ALIVE_EVERY_TICKS = 2
local ticksSinceAlive = 0

local ledger = {
	send = {},
	receive = {}
}

--== Readout =================================================================
-- Every message the server sends goes through send, sendJson or notify, which count it
-- under one feature; every handler counts what it receives. `Mileage Stats` prints the
-- counts for the last STATS_SECONDS and since the server started (or the last reset).
-- Positions are BeamMP's own and are not counted here; the car count stands in for them.

local STATS_SECONDS = 60
local STATS_FEATURES = {"damage", "carStates", "trafficMarks", "trafficShare", "paint", "prefabs", "drag",
	"payments", "transfers", "alive", "trafficLights", "notifications", "config"}

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

-- Console-safe text from a client: control characters removed, length capped.
local function consoleText(text)
	return (tostring(text):gsub("%c", " "):sub(1, START_REASON_MAX_LENGTH))
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
		print("[Mileage] ---------- Mileage Update Download failed: " .. url)
		return false
	end

	local hadInstalled = FS.Exists(path)
	if hadInstalled then
		os.remove(backupPath)
		if not os.rename(path, backupPath) then
			os.remove(tempPath)
			print("[Mileage] ---------- Mileage Update Could not move " .. path .. " aside, nothing was changed")
			return false
		end
	end

	if not os.rename(tempPath, path) then
		if hadInstalled then
			os.rename(backupPath, path)
		end
		os.remove(tempPath)
		print("[Mileage] ---------- Mileage Update Could not replace " .. path .. ", the installed file was kept")
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
		print("[Mileage] ---------- Mileage Update " .. opts.label .. " not installed, downloading...")
		if not downloadFile(opts.fileUrl, opts.filePath) then
			print("[Mileage] ---------- Mileage Update " .. opts.label .. " could not be downloaded!")
			return false
		end
	end

	if not installedVersion then
		print("[Mileage] ---------- Mileage Update Applying self version!")
		installedVersion = opts.hardVersion
		WriteJson(SERVER_PATH .. opts.versionFile, opts.hardVersion)
	end

	local latest = fetchRemoteVersion(opts.updateUrl)
	if not latest then
		print("[Mileage] ---------- Mileage Update Failed to fetch latest " .. opts.label:lower() .. " version!")
		return false
	end

	if not lineageMatches(latest) then
		print("[Mileage] ---------- Mileage Update REFUSED for " .. opts.label .. ": remote is a different lineage")
		print("[Mileage] ----------   expected lineage: " .. LINEAGE)
		print("[Mileage] ----------   remote lineage:   " .. tostring(latest.lineage or "none (upstream Mileage?)"))
		print("[Mileage] ----------   Nothing was changed. Check that the update repository is correct,")
		print("[Mileage] ----------   or set server.autoUpdate to false while testing local changes.")
		return false
	end

	print("[Mileage] ---------- Mileage Update " .. opts.label .. " installed: " .. describeVersion(installedVersion))
	print("[Mileage] ---------- Mileage Update " .. opts.label .. " latest: " .. describeVersion(latest))

	if needsUpdate(installedVersion, latest) then
		print("[Mileage] ---------- Mileage Update Updating " .. opts.label:lower() .. "...")
		if not downloadFile(opts.fileUrl, opts.filePath) then
			print("[Mileage] ---------- Mileage Update " .. opts.label .. " update failed, staying on " .. describeVersion(installedVersion))
			return false
		end
		-- Record the new version only now that the file behind it is actually in place.
		WriteJson(SERVER_PATH .. opts.versionFile, latest)
		print("[Mileage] ---------- Mileage Update " .. opts.label .. " updated to " .. describeVersion(latest) .. "! Restart the server to apply the update!")
		return true
	end

	-- Same lineage but older: a rollback on the remote, or a stale branch. Never applied
	-- silently, because that would overwrite a working install with an older one.
	if needsUpdate(latest, installedVersion) then
		print("[Mileage] ---------- Mileage Update " .. opts.label .. " remote is OLDER than installed - refusing to downgrade")
		return false
	end

	print("[Mileage] ---------- Mileage Update " .. opts.label .. " up to date!")
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

local function readFile(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local data = file:read("*a")
	file:close()
	return data
end

local function moveLog(text)
	print("[Mileage] ---------- Moving from CareerMP: " .. text)
end

-- Copies the settings through a temporary file that is read back and compared before it
-- takes the real name, so a failed or partial copy never leaves a Mileage settings file.
-- Returns true, or false and why.
local function copySettings(from, to)
	local data = readFile(from)
	if not data then return false, "could not read " .. from end
	local dir = to:match("(.+)/[^/]+$")
	if dir and not FS.Exists(dir) then
		FS.CreateDirectory(dir)
	end
	local tempPath = to .. ".tmp"
	os.remove(tempPath)
	local file = io.open(tempPath, "wb")
	if not file then return false, "could not write " .. tempPath end
	local written = file:write(data)
	file:close()
	if not written or readFile(tempPath) ~= data then
		os.remove(tempPath)
		return false, tempPath .. " did not read back the same as " .. from
	end
	if not os.rename(tempPath, to) then
		os.remove(tempPath)
		return false, "could not rename " .. tempPath .. " to " .. to
	end
	return true
end

-- Removes each path that exists, logging any that cannot be. Returns whether all went.
local function removeAll(paths)
	local all = true
	for _, path in ipairs(paths) do
		if FS.Exists(path) then
			if os.remove(path) then
				moveLog("removed " .. path)
			else
				moveLog("could not remove " .. path .. ", delete it by hand")
				all = false
			end
		end
	end
	return all
end

-- Finishes moving a server from CareerMP, whether its last CareerMP update installed
-- Mileage or the owner unpacked Mileage over the old files. Runs before anything else
-- starts, in an order where every failure leaves CareerMP serving players:
--   1. CareerMP's settings are copied, through a checked temporary file, when Mileage
--      has none of its own yet.
--   2. While CareerMP.zip is in place, Mileage's client mod must be ready: a non-empty one
--      in place, held by the last CareerMP plugin, or downloaded now to the held path.
--   3. CareerMP.zip is set aside, the held client mod is moved into place, and only then
--      is the CareerMP plugin removed. Until the plugin is gone each move is undone when a
--      later one fails, so CareerMP.zip and the plugin go back as they were.
-- An empty Mileage.zip counts as none. Leftovers from an earlier move (version files, a
-- held or set-aside zip) are cleaned up.
-- The old settings stay where they were, for the owner to check and delete.
--
-- Returns "done" when CareerMP was removed this start and the server must restart to be
-- rid of it, "failed" when a step failed and CareerMP was left as it was, or "none".
local function moveFromCareerMP()
	local newConfig = configPath .. "config.json"
	if not FS.Exists(newConfig) and FS.Exists(OLD_CONFIG) then
		local ok, why = copySettings(OLD_CONFIG, newConfig)
		if not ok then
			moveLog("could not copy the settings: " .. why .. ". CareerMP stays as it was and the next start tries again")
			return "failed"
		end
		moveLog("copied the settings in " .. OLD_CONFIG .. " to " .. newConfig)
	end

	local newClient = CLIENT_PATH .. CLIENT_FILE
	local removedCareerMP = false
	if FS.Exists(OLD_CLIENT) then
		if fileSize(newClient) == 0 and fileSize(HELD_CLIENT) == 0 then
			if not downloadFile(CLIENT_URL, HELD_CLIENT) or fileSize(HELD_CLIENT) == 0 then
				moveLog("could not download Mileage's client mod. CareerMP stays as it was and the next start tries again")
				return "failed"
			end
		end
		os.remove(SET_ASIDE_CLIENT)
		if not os.rename(OLD_CLIENT, SET_ASIDE_CLIENT) then
			moveLog("could not remove " .. OLD_CLIENT .. ". CareerMP stays as it was and the next start tries again")
			return "failed"
		end
		local placed = false
		local function undo(why)
			if placed and not os.rename(newClient, HELD_CLIENT) then
				moveLog("could not move " .. newClient .. " back to " .. HELD_CLIENT .. "; move it back by hand")
			end
			if not os.rename(SET_ASIDE_CLIENT, OLD_CLIENT) then
				moveLog("could not put " .. OLD_CLIENT .. " back from " .. SET_ASIDE_CLIENT .. "; move it back by hand")
			end
			moveLog(why)
			return "failed"
		end
		if fileSize(newClient) == 0 then
			os.remove(newClient)
			if not os.rename(HELD_CLIENT, newClient) then
				return undo("could not move " .. HELD_CLIENT .. " to " .. newClient .. ". CareerMP stays as it was and the next start tries again")
			end
			placed = true
			moveLog("put Mileage's client mod in place at " .. newClient)
		end
		if FS.Exists(OLD_PLUGIN) and not os.remove(OLD_PLUGIN) then
			return undo("could not remove " .. OLD_PLUGIN .. ". CareerMP stays as it was; delete the file by hand, or the next start tries again")
		end
		moveLog("removed the old client mod " .. OLD_CLIENT .. " and the CareerMP plugin")
		removedCareerMP = true
	elseif FS.Exists(OLD_PLUGIN) then
		-- CareerMP.zip is already gone, so CareerMP serves no players; this plugin is only
		-- left over, and a restart is needed only when it might have run this start.
		removedCareerMP = removeAll({OLD_PLUGIN})
	end

	if FS.Exists(HELD_CLIENT) then
		if fileSize(newClient) > 0 then
			os.remove(HELD_CLIENT)
		else
			-- An empty Mileage.zip is no client mod; with it gone, the update check
			-- downloads one should the held copy fail to move.
			os.remove(newClient)
			if os.rename(HELD_CLIENT, newClient) then
				moveLog("put Mileage's client mod in place at " .. newClient)
			else
				moveLog("could not move " .. HELD_CLIENT .. " to " .. newClient .. "; Mileage's update check downloads it instead")
			end
		end
	end
	local leftovers = {SET_ASIDE_CLIENT}
	for _, path in ipairs(OLD_VERSION_FILES) do table.insert(leftovers, path) end
	removeAll(leftovers)

	if removedCareerMP and FS.Exists(OLD_CONFIG) then
		moveLog("the old settings stay in " .. OLD_CONFIG .. "; delete " .. OLD_SERVER_PATH .. " once you no longer need them")
	end
	return removedCareerMP and "done" or "none"
end

local function prepareConfig()
	print("[Mileage] ---------- Mileage Config Loading...")
	Config = ReadJson(configPath .. "config.json")
	if not Config then
		print("[Mileage] ---------- Mileage Config Initializing...")
		Config = defaultConfig
		for section, fields in pairs(defaultConfig) do
			for field, value in pairs(fields) do
				print("[Mileage] ---------- Mileage Config " .. section .. " " .. field .. " set to " .. tostring(value))
			end
		end
		WriteJson(configPath .. "config.json", Config)
	else
		local updateFound
		for section, fields in pairs(defaultConfig) do
			print("[Mileage] ---------- Mileage Config Checking " .. section)
			if Config[section] == nil then
				updateFound = true
				print("[Mileage] ---------- Mileage Config Adding: " .. section)
				Config[section] = {}
				for field, value in pairs(fields) do
					print("[Mileage] ---------- Mileage Config " .. section .. " " .. field .. " set to " .. tostring(value))
					Config[section][field] = value
				end
			else
				for field, value in pairs(fields) do
					if Config[section][field] == nil then
						print("[Mileage] ---------- Mileage Config " .. section .. " " .. field .. " not found")
						print("[Mileage] ---------- Mileage Config " .. section .. " " .. field .. " set to " .. tostring(value))
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
							print("[Mileage] ---------- Mileage Config " .. section .. " " .. field .. " removed: " .. retired)
						else
							print("[Mileage] ---------- Mileage Config " .. section .. " " .. field .. " is invalid, removing")
						end
						updateFound = true
						Config[section][field] = nil
					end
				end
			end
		end
		if updateFound then
			print("[Mileage] ---------- Mileage Config Updated!")
			WriteJson(configPath .. "config.json", Config)
		end
	end
	print("[Mileage] ---------- Mileage Config Loaded!")
end

--== Data files ==============================================================
-- What Mileage keeps about players between server starts: unfinished money transfers,
-- races holding stakes, the leaderboard and a scheduled event. Each file is written to
-- <name>.tmp and renamed over <name>, so a crash mid-write never leaves a half-written
-- file in place. A file that does not read is moved aside and never overwritten.

local DATA_PATH = SERVER_PATH .. "data/"

-- Names whose file could not be read nor moved aside: never written, so it is kept.
local unwritableData = {}

local function dataLog(text)
	print("[Mileage] ---------- Data: " .. text)
end

-- The decoded table in data/<name>, or nil when there is none (or it did not read).
local function readData(name)
	local path = DATA_PATH .. name
	local from = path
	local text = readFile(path)
	if text == nil then
		-- An interrupted write on a system where the rename needed the old file removed.
		from = path .. ".tmp"
		text = readFile(from)
		if text == nil then return nil end
	end
	local ok, value = pcall(Util.JsonDecode, text)
	if ok and type(value) == "table" then return value end
	local aside = path .. ".unreadable-" .. tostring(os.time())
	if os.rename(from, aside) then
		dataLog(from .. " could not be read; it is kept as " .. aside .. " and Mileage starts without it")
	else
		unwritableData[name] = true
		dataLog(from .. " could not be read nor moved aside; Mileage will not write " .. name
			.. " until it is fixed or removed")
	end
	return nil
end

-- Writes value to data/<name>. Returns true once the new file is in place.
local function writeData(name, value)
	if unwritableData[name] then return false end
	if not FS.Exists(DATA_PATH) then
		FS.CreateDirectory(DATA_PATH)
	end
	local ok, encoded = pcall(Util.JsonEncode, value)
	if not ok or type(encoded) ~= "string" then
		dataLog("could not encode " .. name)
		return false
	end
	local path = DATA_PATH .. name
	local tempPath = path .. ".tmp"
	local file = io.open(tempPath, "w")
	if not file then
		dataLog("could not write " .. tempPath)
		return false
	end
	local written = file:write(encoded)
	file:close()
	if not written then
		os.remove(tempPath)
		dataLog("could not write " .. tempPath)
		return false
	end
	if not os.rename(tempPath, path) then
		-- Windows does not rename over an existing file. Until the rename below, the new
		-- contents are in the .tmp file, which readData falls back to.
		os.remove(path)
		if not os.rename(tempPath, path) then
			dataLog("could not rename " .. tempPath .. " to " .. path)
			return false
		end
	end
	return true
end

-- Set by the sections below the handlers: each loads its data file and its state.
local startMoneyFeatures

function onInit()

	print("[Mileage] ---------- Mileage Loading...")

	-- While CareerMP is still installed it serves players, so a handoff start runs none
	-- of Mileage's features, writes no settings and checks for no update.
	local handoff = moveFromCareerMP()
	if handoff == "failed" then
		moveLog("Mileage did not start, CareerMP keeps serving players until the move succeeds on a later start")
		return
	end
	if handoff == "done" then
		local settings = ReadJson(configPath .. "config.json")
		if not (settings and settings.server and settings.server.autoExit == false) then
			moveLog("restarting to finish the move")
			willExit = true
			-- tick is what shuts the server down.
			MP.RegisterEvent("tick","tick")
			MP.CreateEventTimer("tick", 1000)
		else
			moveLog("restart the server to finish the move")
		end
		return
	end

	MP.RegisterEvent("perPartPainting","perPartPaintingHandler")
	MP.RegisterEvent("requestPartPaints","requestPartPaintsHandler")

	MP.RegisterEvent("payPlayer","payPlayer")
	MP.RegisterEvent("mileageReceipt","mileageReceipt")

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
	MP.RegisterEvent("Transfers","Transfers")

	MP.RegisterEvent("tick","tick")
	MP.CreateEventTimer("tick", 1000)

	prepareConfig()
	startMoneyFeatures()

	if Config.server.autoUpdate then
		checkForUpdates()
	end

	print("[Mileage] ---------- Mileage Loaded!")
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

--== Transfers ===============================================================
-- Every movement of money between players' careers (a payment, a race stake, its
-- refund, a race pot, a server prize) is one transfer. The server first asks the
-- payer's game to take the amount; that game takes it, records the transfer's id in the
-- same save as its money, and answers with a receipt once the save has finished. Only
-- then does the server ask the receiver's game to give it, the same way. A transfer from
-- the server starts at the giving step; one to the server (a stake) ends after taking.
--
-- data/transfers.json holds every unfinished transfer and is written before each step
-- is sent, so a server restart carries on where it stopped. A step goes to its player
-- only while their career runs: at once, again every TRANSFER_RESEND_SECONDS without a
-- receipt, and again as soon as their career starts on a later join. Nothing expires;
-- `Mileage Transfers` lists what is waiting. A game keeps the ids it applied until it
-- hears the transfer is settled (rxMileageSettled), so a step it already applied is
-- answered again without being applied twice.
--
-- transferData = {seq, transfers = {[id] = transfer}, settled = {[name] = {id, ...}}}
-- transfer = {id, kind, from, to, amount, labels = {take, give}, state, created, race, role}
-- state: "taking" (waiting for the payer's receipt) or "giving" (for the receiver's).

local SERVER_PARTY = "server"
local TRANSFER_RESEND_SECONDS = 10
local TRANSFER_SLOW_SECONDS = 60
local TRANSFER_TAGS = {"gameplay"}
local TRANSFERS_FILE = "transfers.json"

local transferData = {seq = 0, transfers = {}, settled = {}}
-- Not kept across starts: when each step was last sent, and which waits were logged.
local transferSentAt = {}
local transferSlowLogged = {}
-- True when the transfers changed but could not be written yet; nothing is sent until
-- they are.
local transfersUnsaved = false

-- Who is told when a transfer of theirs is taken, given or refused; set by the payment
-- and race sections below. transferOwners.payment(transfer, event), and so on.
local transferOwners = {}

local function saveTransfers()
	transfersUnsaved = not writeData(TRANSFERS_FILE, transferData)
	return not transfersUnsaved
end

local function playerIdByName(name)
	for id, playerName in pairs(MP.GetPlayers() or {}) do
		if playerName == name and MP.IsPlayerConnected(id) then return id end
	end
	return nil
end

local function careerStarted(player_id)
	local entry = pendingActivation[player_id]
	return entry ~= nil and entry.careerActive == true and not entry.dropped
end

-- The player the transfer waits on: the payer while taking, the receiver while giving.
local function waitingOn(transfer)
	if transfer.state == "taking" then return transfer.from end
	return transfer.to
end

local function sendStep(transfer)
	if transfersUnsaved then return false end
	local id = playerIdByName(waitingOn(transfer))
	if not id or not careerStarted(id) then return false end
	transferSentAt[transfer.id] = signalTimer:GetCurrent()
	local taking = transfer.state == "taking"
	sendJson("transfers", id, taking and "rxMileageTake" or "rxMileageGive", {
		id = transfer.id,
		kind = transfer.kind,
		amount = transfer.amount,
		label = taking and transfer.labels.take or transfer.labels.give,
		tags = TRANSFER_TAGS,
		from = transfer.from,
		to = transfer.to,
	})
	return true
end

-- Tells a player's game it may forget these ids; kept for a later join when it is away.
local function sendSettled(name, ids)
	if name == SERVER_PARTY or #ids == 0 then return end
	local id = playerIdByName(name)
	if id and careerStarted(id) then
		sendJson("transfers", id, "rxMileageSettled", {ids = ids})
		return
	end
	local waiting = transferData.settled[name] or {}
	for _, transferId in ipairs(ids) do table.insert(waiting, transferId) end
	transferData.settled[name] = waiting
end

local function tellOwner(transfer, event)
	local owner = transferOwners[transfer.race and "race" or transfer.kind]
	if owner then owner(transfer, event) end
end

local function describeTransfer(transfer)
	return string.format("%s (%s, $%d from %s to %s)", transfer.id, transfer.kind, transfer.amount,
		consoleText(transfer.from), consoleText(transfer.to))
end

-- Starts a transfer and sends its first step. spec: {kind, from, to, amount, takeLabel,
-- giveLabel, race, role}; from or to may be SERVER_PARTY. Returns its id.
local function startTransfer(spec)
	transferData.seq = transferData.seq + 1
	local transfer = {
		id = "t" .. transferData.seq,
		kind = spec.kind,
		from = spec.from,
		to = spec.to,
		amount = spec.amount,
		labels = {take = spec.takeLabel or "", give = spec.giveLabel or ""},
		state = spec.from == SERVER_PARTY and "giving" or "taking",
		created = os.time(),
		race = spec.race,
		role = spec.role,
	}
	transferData.transfers[transfer.id] = transfer
	if saveTransfers() then sendStep(transfer) end
	return transfer.id
end

-- The game of the player a transfer waits on answers {id, done = "taken" | "given" |
-- "refused"}. Only that player's receipt for the step under way counts. The owner hears
-- of it before the transfer itself moves on, so a restart in between repeats the step
-- (which the game answers again without applying it) rather than lose it.
function mileageReceipt(player_id, data)
	received("transfers")
	local receipt = decodeTable(data)
	if not receipt or type(receipt.id) ~= "string" then return end
	local transfer = transferData.transfers[receipt.id]
	if not transfer or MP.GetPlayerName(player_id) ~= waitingOn(transfer) then return end
	if transfer.state == "taking" and receipt.done == "taken" then
		tellOwner(transfer, "taken")
		if transfer.to == SERVER_PARTY then
			transferData.transfers[transfer.id] = nil
			sendSettled(transfer.from, {transfer.id})
			saveTransfers()
			return
		end
		transfer.state = "giving"
		transferSentAt[transfer.id] = nil
		if saveTransfers() then sendStep(transfer) end
	elseif transfer.state == "taking" and receipt.done == "refused" then
		print("[Mileage] Transfer " .. describeTransfer(transfer) .. " refused: " .. consoleText(transfer.from)
			.. " does not have the money")
		tellOwner(transfer, "refused")
		transferData.transfers[transfer.id] = nil
		sendSettled(transfer.from, {transfer.id})
		saveTransfers()
	elseif transfer.state == "giving" and receipt.done == "given" then
		tellOwner(transfer, "given")
		transferData.transfers[transfer.id] = nil
		sendSettled(transfer.to, {transfer.id})
		if transfer.from ~= SERVER_PARTY then sendSettled(transfer.from, {transfer.id}) end
		saveTransfers()
	end
end

-- A player's career started: the ids settled while they were away, then every step
-- waiting on them at once.
local function transfersCareerStarted(player_id)
	local name = MP.GetPlayerName(player_id)
	if not name then return end
	local settled = transferData.settled[name]
	if settled then
		transferData.settled[name] = nil
		sendSettled(name, settled)
		saveTransfers()
	end
	for _, transfer in pairs(transferData.transfers) do
		if waitingOn(transfer) == name then
			transferSentAt[transfer.id] = nil
			sendStep(transfer)
		end
	end
end

local function transfersTick()
	if transfersUnsaved and not saveTransfers() then return end
	local now = signalTimer:GetCurrent()
	for id, transfer in pairs(transferData.transfers) do
		if now - (transferSentAt[id] or -math.huge) >= TRANSFER_RESEND_SECONDS then
			sendStep(transfer)
		end
		if not transferSlowLogged[id] and os.time() - (transfer.created or 0) > TRANSFER_SLOW_SECONDS then
			transferSlowLogged[id] = true
			print("[Mileage] Transfer " .. describeTransfer(transfer) .. " has waited more than a minute for "
				.. consoleText(waitingOn(transfer)))
		end
	end
end

local function loadTransfers()
	local stored = readData(TRANSFERS_FILE)
	transferData = {seq = 0, transfers = {}, settled = {}}
	transferSentAt, transferSlowLogged = {}, {}
	if stored then
		transferData.seq = tonumber(stored.seq) or 0
		transferData.transfers = type(stored.transfers) == "table" and stored.transfers or {}
		transferData.settled = type(stored.settled) == "table" and stored.settled or {}
		-- Ids are made from seq; a damaged seq must not hand out an id still in use.
		for id in pairs(transferData.transfers) do
			local n = tonumber(tostring(id):match("^t(%d+)$"))
			if n and n > transferData.seq then transferData.seq = n end
		end
	end
	local waiting = 0
	for _ in pairs(transferData.transfers) do waiting = waiting + 1 end
	if waiting > 0 then
		print("[Mileage] ---------- " .. waiting .. " money transfer(s) waiting for players, see Mileage Transfers")
	end
end

local function ageText(seconds)
	seconds = math.max(0, math.floor(seconds))
	if seconds < 120 then return seconds .. " s" end
	if seconds < 7200 then return math.floor(seconds / 60) .. " min" end
	if seconds < 172800 then return math.floor(seconds / 3600) .. " h" end
	return math.floor(seconds / 86400) .. " days"
end

-- Set by the race section: prints the races still holding stakes.
local printRaces

function Transfers(arguments)
	local ids = {}
	for id in pairs(transferData.transfers) do table.insert(ids, id) end
	table.sort(ids, function(a, b)
		return (tonumber(a:match("%d+")) or 0) < (tonumber(b:match("%d+")) or 0)
	end)
	print(string.format("[Mileage] Transfers waiting: %d", #ids))
	for _, id in ipairs(ids) do
		local transfer = transferData.transfers[id]
		print(string.format("  %s, %s ago: %s %s", describeTransfer(transfer),
			ageText(os.time() - (transfer.created or os.time())),
			transfer.state == "taking" and "waiting to take from" or "waiting to give to",
			consoleText(waitingOn(transfer))))
	end
	if printRaces then printRaces() end
end

--== Payments ================================================================
-- A player pays another from the player list. The server checks the amount, the target
-- and the sender's limits, then pays it as a transfer. A payment the server turns down
-- bounces (rxBounce) or is denied (rxDeny) before any money moves.

-- The sender's game shows why a payment did not go: why is "limit" (the default), or
-- "money" when the sender's game refused to take it.
local function bounce(player_id, paymentData, why)
	paymentData.why = why or "limit"
	sendJson("payments", player_id, "rxBounce", paymentData)
end

function payPlayer(player_id, data)
	received("payments")
	local paymentData = decodeTable(data)
	if not paymentData then return end
	paymentData.sender = MP.GetPlayerName(player_id)
	if not Config.server.allowTransactions then
		sendJson("payments", player_id, "rxDeny", paymentData)
		return
	end
	if not isValidPayment(player_id, paymentData)
			or not attemptTransaction(player_id, paymentData.target_player_id, paymentData.money, signalTimer:GetCurrent()) then
		bounce(player_id, paymentData)
		return
	end
	local from, to = paymentData.sender, MP.GetPlayerName(paymentData.target_player_id)
	startTransfer({
		kind = "payment",
		from = from,
		to = to,
		amount = paymentData.money,
		takeLabel = "Paid player: " .. to,
		giveLabel = "Payment from player: " .. from,
	})
end

function transferOwners.payment(transfer, event)
	if event ~= "refused" then return end
	local id = playerIdByName(transfer.from)
	if id then
		bounce(id, {money = transfer.amount, target_player_name = transfer.to}, "money")
	end
end

startMoneyFeatures = function()
	loadTransfers()
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
			print("[Mileage] ---------- Drag authority for '" .. stripId .. "' is player " .. tostring(elected))
		else
			print("[Mileage] ---------- Drag strip '" .. stripId .. "' is empty")
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
	if envelope.msg == "mileageDragJoin" and d then
		noteArrival(player_id, d.stripId)
	elseif envelope.msg == "mileageDragLeave" and d then
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

local function describePlayer(player_id)
	return string.format("%s (%s)", consoleText(MP.GetPlayerName(player_id) or "?"), tostring(player_id))
end

local function dropUnstartedPlayer(player_id, why)
	local entry = pendingActivation[player_id]
	if not entry or entry.dropped then return end
	entry.dropped = true
	print("[Mileage] Dropping " .. describePlayer(player_id) .. ": " .. why)
	MP.DropPlayer(player_id, "Mileage failed to load!")
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
		transfersCareerStarted(player_id)
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
		print("[Mileage] " .. describePlayer(player_id) .. " started their career")
		transfersCareerStarted(player_id)
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

function validateMileageActivation()
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
			send("alive", id, "rxMileageAlive", "")
		end
	end
end

function tick()
	if willExit then
		exit()
	end
	validateMileageActivation()
	sendWantedVehicleLists()
	sendChangedShares()
	transfersTick()
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
	-- Compare against each prefix: `== "Mileage " or "CMP "` would always be truthy and
	-- treat every console line containing a space as a Mileage command. CareerMP and CMP
	-- are the commands from before the rename, still accepted for owners' scripts.
	if commandPrefix == "Mileage " or commandPrefix == "CareerMP " or commandPrefix == "CMP " then
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
		print("Usage: Mileage SetConfig <section> <key> <value>")
		return
	end
	Config = ReadJson(configPath .. "config.json")
	local section = arguments[1]
	local key = arguments[2]
	local value = arguments[3]
	if not Config[section] then
		print("[Mileage] ---------- Unknown section: " .. section)
		return
	end
	if Config[section][key] == nil then
		print("[Mileage] ---------- Unknown key: " .. section .. " " .. key)
		return
	end
	Config[section][key] = checkValue(value)
	print("[Mileage] ---------- Config:    " .. section .. " " .. tostring(key) .. " set to " .. tostring(Config[section][key]))
	WriteJson(configPath .. "config.json", Config)
	sendJson("config", -1, "rxClientConfigUpdate", Config.client)
	-- An amount, a switch or a total may have changed everyone's share.
	sharesChanged()
end

function Update(arguments)
	checkForUpdates()
end

function Help(arguments)
	print("Mileage GetConfig <section> <key>            - Displays Config, or section, or key")
	print("Mileage SetConfig <section*> <key*> <value*> - Sets Config section key to value, * = REQUIRED")
	print("Mileage Update                               - Checks for Mileage update")
	print("Mileage Stats [reset]                        - Shows what each part of Mileage sends, reset starts it again")
	print("Mileage Transfers                            - Lists money still waiting on a player, and races holding stakes")
	print("Mileage Help                                 - Displays Commands Usage")
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
	print(string.format("[Mileage] Stats - last %d s | since start (%d s ago)", STATS_SECONDS,
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
		print("[Mileage] Stats reset")
	else
		print("Usage: Mileage Stats [reset]")
	end
end

function ReadJson(path)
	if not path then
		print("[Mileage] ---------- ReadJson:  path is nil!")
		return
	end
	if not FS.Exists(path) then
		print("[Mileage] ---------- ReadJson:  " .. path .. " does not exist!")
		return
	end
	local jsonFile, err = io.open(path, "r")
	if not jsonFile then
		print("[Mileage] ---------- ReadJson:  failed to open " .. path .. ": " .. tostring(err))
		return
	end
	local jsonText = jsonFile:read("*a")
	jsonFile:close()
	if not jsonText or jsonText == "" then
		print("[Mileage] ---------- ReadJson:  " .. path .. " is empty!")
		return
	end
	local data = Util.JsonDecode(jsonText)
	if data == nil then
		print("[Mileage] ---------- ReadJson:  failed to decode " .. path)
		return
	end
	return data
end

function WriteJson(path, data)
	if not path then
		print("[Mileage] ---------- WriteJson: path is nil!")
		return
	end
	if data == nil then
		print("[Mileage] ---------- WriteJson: data is nil, aborting!")
		return
	end
	local checkDirectory = path:match("(.+)/[^/]+$")
	if checkDirectory and not FS.Exists(checkDirectory) then
		FS.CreateDirectory(checkDirectory)
		print("[Mileage] ---------- WriteJson: created directory " .. checkDirectory)
	end
	local encoded = Util.JsonEncode(data)
	if not encoded then
		print("[Mileage] ---------- WriteJson: failed to encode data!")
		return
	end
	local jsonFile, err = io.open(path, "w")
	if not jsonFile then
		print("[Mileage] ---------- WriteJson: failed to open " .. path .. ": " .. tostring(err))
		return
	end
	print("[Mileage] ---------- WriteJson: writing " .. path)
	jsonFile:write(Util.JsonPrettify(encoded))
	jsonFile:close()
	return true
end
