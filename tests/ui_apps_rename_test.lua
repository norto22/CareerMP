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
