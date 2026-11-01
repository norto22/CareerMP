-- Resources/Client/Mileage/lua/ge/extensions/mileageUIApps.lua: a player's saved UI
-- layouts from before the rename from CareerMP. The old player list gives way to
-- Mileage's, and a layout stamped for this game build is not rebuilt just because its
-- stamp has the old name.

local SOURCE = "Resources/Client/Mileage/lua/ge/extensions/mileageUIApps.lua"
local BUILD = "0.40.4.0.12345"
local USER_DEFAULT = "settings/ui_apps/layouts/default/"
local ORIGINAL_DEFAULT = "settings/ui_apps/originalLayouts/default/"

local files, written, logs

local function copy(t)
	if type(t) ~= "table" then return t end
	local r = {}
	for k, v in pairs(t) do r[k] = copy(v) end
	return r
end

-- A catalogue big enough for the module to trust (it ignores one under 10 apps).
local function catalogue()
	local apps = {}
	for i = 1, 12 do apps["gameApp" .. i] = {} end
	apps.mileageplayerlist = {}
	apps.multiplayerchat = {}
	apps.multiplayersession = {}
	return apps
end

local function loadModule(existing)
	files, written, logs = existing, {}, {}
	beamng_versionb = BUILD
	deepcopy = copy
	function log(level, tag, msg) table.insert(logs, level .. " " .. tag .. ": " .. msg) end
	function jsonReadFile(path) return copy(files[path]) end
	function jsonWriteFile(path, data) written[path] = copy(data) end
	function setExtensionUnloadMode() end
	ui_apps = {getUIAppsData = catalogue}
	return dofile(SOURCE)
end

local function names(layout)
	local out = {}
	for _, app in ipairs(layout.apps) do table.insert(out, app.appName) end
	return out
end

local function indexOf(list, wanted)
	for i, v in ipairs(list) do
		if v == wanted then return i end
	end
end

local function oldCareerLayout(stamp)
	return {
		careerMPBuild = stamp,
		apps = {
			{appName = "gameApp1", placement = {left = "0px"}},
			{appName = "careermpplayerlist", placement = {left = "10px", top = "200px"}},
			{appName = "gameApp2", placement = {left = "20px"}},
			{appName = "multiplayerchat"},
			{appName = "multiplayersession"},
		},
	}
end

test("the CareerMP player list in a saved layout becomes Mileage's, once", function()
	local M = loadModule({
		[USER_DEFAULT .. "career.uilayout.json"] = oldCareerLayout(BUILD),
		[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp1"}}},
	})
	M.migrateLayouts()
	local layout = written[USER_DEFAULT .. "career.uilayout.json"]
	expect(layout, "career layout written")
	local list = names(layout)
	same(indexOf(list, "careermpplayerlist"), nil, "old player list")
	local count = 0
	for _, name in ipairs(list) do
		if name == "mileageplayerlist" then count = count + 1 end
	end
	same(count, 1, "one Mileage player list")
end)

test("with no app catalogue the CareerMP player list is still swapped for Mileage's", function()
	local M = loadModule({
		[USER_DEFAULT .. "career.uilayout.json"] = oldCareerLayout(BUILD),
		[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp1"}}},
	})
	ui_apps = nil
	M.migrateLayouts()
	local list = names(written[USER_DEFAULT .. "career.uilayout.json"])
	same(indexOf(list, "careermpplayerlist"), nil, "old player list")
	same(indexOf(list, "mileageplayerlist"), 2, "swapped where it was")
end)

test("a layout stamped for this build under the old name keeps the player's own apps", function()
	local M = loadModule({
		[USER_DEFAULT .. "career.uilayout.json"] = oldCareerLayout(BUILD),
		[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp9"}}},
	})
	M.migrateLayouts()
	local layout = written[USER_DEFAULT .. "career.uilayout.json"]
	local list = names(layout)
	expect(indexOf(list, "gameApp2"), "player's own app kept")
	same(indexOf(list, "gameApp9"), nil, "not rebuilt from the original")
	same(layout.mileageBuild, BUILD, "stamped under the new name")
	same(countLines(logs, "rebuilding from this build's default"), 0, "no rebuild logged")
end)

test("a layout stamped for an older build is still rebuilt from this build's original", function()
	local M = loadModule({
		[USER_DEFAULT .. "career.uilayout.json"] = oldCareerLayout("0.39.2.1.0"),
		[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp9"}}},
	})
	M.migrateLayouts()
	local list = names(written[USER_DEFAULT .. "career.uilayout.json"])
	expect(indexOf(list, "gameApp9"), "rebuilt from the original")
	same(indexOf(list, "careermpplayerlist"), nil, "old player list")
	expect(indexOf(list, "mileageplayerlist"), "Mileage player list added")
	same(countLines(logs, "was written for build 0.39.2.1.0"), 1, "old stamp named in the log")
end)

local OLD_PLACEMENT = {position = "absolute", left = "10px", top = "200px", width = "320px", height = "410px"}

local function placedOldList()
	local layout = oldCareerLayout(BUILD)
	layout.apps[2].placement = copy(OLD_PLACEMENT)
	return layout
end

local function samePlacement(placement, wanted, what)
	for k, v in pairs(wanted) do same(placement[k], v, what .. " " .. k) end
	for k, v in pairs(placement) do same(wanted[k], v, what .. " " .. k) end
end

for _, withCatalogue in ipairs({true, false}) do
	local label = withCatalogue and "with" or "without"
	test("the CareerMP player list becomes Mileage's where the player put it, " .. label .. " the app catalogue", function()
		local M = loadModule({
			[USER_DEFAULT .. "career.uilayout.json"] = placedOldList(),
			[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp1"}}},
		})
		if not withCatalogue then ui_apps = nil end
		M.migrateLayouts()
		local layout = written[USER_DEFAULT .. "career.uilayout.json"]
		local list = names(layout)
		same(indexOf(list, "careermpplayerlist"), nil, "old player list")
		same(indexOf(list, "mileageplayerlist"), 2, "swapped where it was")
		samePlacement(layout.apps[2].placement, OLD_PLACEMENT, "placement")
		local count = 0
		for _, name in ipairs(list) do
			if name == "mileageplayerlist" then count = count + 1 end
		end
		same(count, 1, "one Mileage player list")
	end)
end

test("BeamMP's own player list is still replaced at Mileage's default place", function()
	local layout = oldCareerLayout(BUILD)
	layout.apps[2] = {appName = "beammpPlayerListVue", placement = copy(OLD_PLACEMENT)}
	local M = loadModule({
		[USER_DEFAULT .. "career.uilayout.json"] = layout,
		[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp1"}}},
	})
	M.migrateLayouts()
	local saved = written[USER_DEFAULT .. "career.uilayout.json"]
	local i = indexOf(names(saved), "mileageplayerlist")
	expect(i, "Mileage player list")
	same(saved.apps[i].placement.top, "240px", "Mileage's default top")
	same(saved.apps[i].placement.left, "", "Mileage's default left")
end)

test("an old careermp.uilayout.json naming the old player list goes on top of the shipped override", function()
	local M = loadModule({
		[USER_DEFAULT .. "mileage.uilayout.json"] = {
			apps = {{appName = "mileageplayerlist", placement = {left = "100px"}}},
		},
		[USER_DEFAULT .. "careermp.uilayout.json"] = {
			apps = {{appName = "careermpplayerlist", placement = {left = "777px"}}},
		},
		[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp1"}}},
	})
	M.migrateLayouts()
	local layout = written[USER_DEFAULT .. "career.uilayout.json"]
	local list = names(layout)
	same(indexOf(list, "careermpplayerlist"), nil, "old name never added")
	local i = indexOf(list, "mileageplayerlist")
	expect(i, "player list added")
	same(layout.apps[i].placement.left, "777px", "the player's old override")
end)

test("with no old override file the shipped override places the player list", function()
	local M = loadModule({
		[USER_DEFAULT .. "mileage.uilayout.json"] = {
			apps = {{appName = "mileageplayerlist", placement = {left = "100px"}}},
		},
		[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp1"}}},
	})
	M.migrateLayouts()
	local layout = written[USER_DEFAULT .. "career.uilayout.json"]
	local i = indexOf(names(layout), "mileageplayerlist")
	same(layout.apps[i].placement.left, "100px", "shipped override placement")
end)

test("an override saved as careermp.uilayout.json still places the player list", function()
	local M = loadModule({
		[USER_DEFAULT .. "careermp.uilayout.json"] = {
			apps = {{appName = "mileageplayerlist", placement = {left = "777px"}}},
		},
		[ORIGINAL_DEFAULT .. "career.uilayout.json"] = {apps = {{appName = "gameApp1"}}},
	})
	M.migrateLayouts()
	local layout = written[USER_DEFAULT .. "career.uilayout.json"]
	local i = indexOf(names(layout), "mileageplayerlist")
	expect(i, "player list added")
	same(layout.apps[i].placement.left, "777px", "override placement")
end)
